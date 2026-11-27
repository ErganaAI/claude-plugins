#!/usr/bin/env python3
"""plugins/ergana/scripts/ergana-hook.py against loopback fake servers, a throwaway HOME (no Keychain), a git
repository with .ergana and a stored secret:

    python3 tests/ergana-hook.test.py
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "plugins", "ergana", "scripts", "ergana-hook.py")
VERSION = json.load(open(os.path.join(ROOT, "plugins", "ergana", ".claude-plugin", "plugin.json")))["version"]
TMP = tempfile.mkdtemp()
HOME = os.path.join(TMP, "home")
os.mkdir(HOME)
failed = []


def check(name, cond, detail=""):
    if cond:
        print("ok   " + name)
    else:
        print("FAIL %s: %s" % (name, detail))
        failed.append(name)


def last(srv):
    return srv.calls[-1] if srv.calls else {"body": {"params": {"arguments": {}}}, "headers": {}}


class Fake:
    """An /mcp and /oauth/token server. `mcp` is (status, body bytes, extra headers) or a function of the handler."""

    def __init__(self):
        self.calls = []
        self.token_calls = 0
        self.mcp = None
        self.renew_delay = 0
        self.next_access = "NEW-1"
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def reply(self, code, body, headers=()):
                self.send_response(code)
                self.send_header("Content-Length", str(len(body)))
                for k, v in headers:
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(n)
                if self.path == "/oauth/token":
                    outer.token_calls += 1
                    time.sleep(outer.renew_delay)
                    return self.reply(200, json.dumps({
                        "access_token": outer.next_access, "refresh_token": "REFRESH-%d" % outer.token_calls,
                        "expires_in": 3600}).encode(), [("Content-Type", "application/json")])
                outer.calls.append({"path": self.path, "headers": dict(self.headers), "body": json.loads(raw)})
                m = outer.mcp
                if callable(m):
                    return m(self)
                self.reply(*m)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        self.origin = "http://127.0.0.1:%d" % self.port
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()


def ok_body(text="{}", is_error=False):
    return json.dumps({"jsonrpc": "2.0", "id": 1, "result": {
        "content": [{"type": "text", "text": text}], "isError": is_error}}).encode()


def json_reply(code, obj):
    return (code, json.dumps(obj).encode(), [("Content-Type", "application/json")])


def store(origin, slug="acme", access="TOKEN-1", expires_in=3600):
    d = os.path.join(HOME, ".config", "ergana", origin.split("//")[1].replace(":", "_"))
    os.makedirs(d, mode=0o700, exist_ok=True)
    with open(os.path.join(d, slug), "w") as f:
        json.dump({"access": access, "refresh": "REFRESH-0", "expires_at": int(time.time()) + expires_in,
                   "origin": origin}, f)


def repo(workspace="acme"):
    p = tempfile.mkdtemp(dir=TMP)
    subprocess.run(["git", "init", "-q", "-b", "main", p], check=True)
    if workspace:
        with open(os.path.join(p, ".ergana"), "w") as f:
            f.write("workspace = %s\n" % workspace)
    return p


def run(origin, cwd, args, lang="en", timeout=10, hook=None, extra_env=None):
    env = {"PATH": os.environ["PATH"], "HOME": HOME, "ERGANA_AUTH_TEST": "1", "ERGANA_AUTH_KEYCHAIN": "0",
           "ERGANA_ORIGIN": origin, "LANG": lang, "GIT_CONFIG_GLOBAL": "/dev/null", "CLAUDE_PROJECT_DIR": cwd}
    env.update(extra_env or {})
    hook = {"session_id": "s1", "cwd": cwd, "tool_input": {"file_path": "/x/y.py"}, "agent_type": "main"} \
        if hook is None else hook
    t0 = time.monotonic()
    p = subprocess.run([sys.executable, "-I", SCRIPT, "before_edit", str(timeout)] + args,
                       input=json.dumps(hook), capture_output=True, text=True, env=env, cwd=cwd,
                       timeout=timeout + 10)
    return p, time.monotonic() - t0


EDIT = ["agent_type=.agent_type", "file_path=.tool_input.file_path"]
srv = Fake()
srv.mcp = (200, ok_body("hello"), [("Content-Type", "application/json")])
store(srv.origin)
r = repo()

# 1 before_edit: arguments, headers, text unchanged
p, _ = run(srv.origin, r, EDIT)
c = srv.calls[-1] if srv.calls else {"body": {}, "headers": {}, "path": ""}
args = c["body"].get("params", {}).get("arguments")
check("call-shape", c["path"] == "/mcp" and c["body"].get("method") == "tools/call"
      and c["body"]["params"]["name"] == "before_edit" and c["body"].get("jsonrpc") == "2.0", c)
check("call-arguments", args == {"session_id": "s1", "agent_type": "main", "file_path": "/x/y.py",
                                 "plugin_version": VERSION}, args)
h = {k.lower(): v for k, v in c["headers"].items()}
check("call-headers", h.get("x-ergana-workspace") == "acme" and h.get("authorization") == "Bearer TOKEN-1", h)
check("call-branch", h.get("x-ergana-branch") == "main", h)
check("call-content-type", h.get("content-type") == "application/json"
      and h.get("accept") == "application/json, text/event-stream"
      and h.get("user-agent") == "ergana-plugin/" + VERSION, h)
check("stdout-text", p.returncode == 0 and p.stdout == "hello" and p.stderr == "", (p.returncode, p.stdout, p.stderr))

# 2 missing agent_type, 3 list passes as a list, literal value
run(srv.origin, r, EDIT, hook={"session_id": "s1", "tool_input": {"file_path": "/a"}})
a = last(srv)["body"]["params"]["arguments"]
check("missing-left-out", a.get("file_path") == "/a" and "agent_type" not in a, a)
run(srv.origin, r, ["background_tasks=.background_tasks", "state=working"],
    hook={"session_id": "s1", "background_tasks": [{"id": "a"}, {"id": "b"}]})
a = last(srv)["body"]["params"]["arguments"]
check("list-and-literal", a.get("background_tasks") == [{"id": "a"}, {"id": "b"}] and a.get("state") == "working", a)
n = len(srv.calls)
p, _ = run(srv.origin, r, EDIT, hook={"agent_type": "x"})
check("no-session", p.returncode == 0 and p.stdout == "" and p.stderr == "" and len(srv.calls) == n)

# 4 expired token renewed, then a rotation between two calls
store(srv.origin, access="OLD", expires_in=-10)
srv.token_calls = 0
p, _ = run(srv.origin, r, EDIT)
check("renewed", p.returncode == 0 and srv.token_calls == 1
      and last(srv)["headers"].get("Authorization") == "Bearer NEW-1", (p.stderr, srv.token_calls))
store(srv.origin, access="ROTATED", expires_in=3600)
run(srv.origin, r, EDIT)
check("second-rotation", last(srv)["headers"].get("Authorization") == "Bearer ROTATED")

# 4b three hooks at once on one expired token: one renewal
store(srv.origin, access="OLD", expires_in=-10)
srv.token_calls = 0
srv.renew_delay = 0.5
n = len(srv.calls)
res = []
ths = [threading.Thread(target=lambda: res.append(run(srv.origin, r, EDIT, timeout=15))) for _ in range(3)]
[x.start() for x in ths]
[x.join() for x in ths]
srv.renew_delay = 0
auths = [x["headers"].get("Authorization") for x in srv.calls[n:]]
check("parallel-renewal", srv.token_calls == 1 and auths == ["Bearer NEW-1"] * 3
      and all(x[0].returncode == 0 for x in res), (srv.token_calls, auths, [x[0].stderr for x in res]))

# 5 errors
store(srv.origin)
srv.mcp = json_reply(401, {"error": "invalid_token", "error_description": "Jeton refusé par Ergana"})
p, _ = run(srv.origin, r, EDIT)
check("401-description", p.returncode == 1 and p.stderr.strip() == "Jeton refusé par Ergana" and p.stdout == "", p.stderr)
srv.mcp = json_reply(401, {"error": "invalid_token"})
p, _ = run(srv.origin, r, EDIT)
check("401-fixed-en", p.returncode == 1 and p.stderr.strip() == "Ergana › sign-in refused: /ergana:login", p.stderr)
p, _ = run(srv.origin, r, EDIT, lang="fr_FR.UTF-8")
check("401-fixed-fr", p.returncode == 1 and p.stderr.strip() == "Ergana › connexion refusée : /ergana:login", p.stderr)
srv.mcp = (401, b"Unauthorized", [])
p, _ = run(srv.origin, r, EDIT)
check("401-bare", p.returncode == 1 and "sign-in refused" in p.stderr, p.stderr)
srv.mcp = json_reply(403, {"error": "workspace_mismatch", "error_description": "Autre espace"})
p, _ = run(srv.origin, r, EDIT)
check("403-description", p.returncode == 1 and p.stderr.strip() == "Autre espace", p.stderr)
srv.mcp = (500, b"boom", [])
p, _ = run(srv.origin, r, EDIT)
check("http-status", p.returncode == 1 and "500" in p.stderr and "boom" not in p.stderr, p.stderr)
# a workspace with no token: the call is made with the not-connected bearer
srv.mcp = json_reply(401, {"error": "invalid_token", "error_description": "Espace non connecté"})
n = len(srv.calls)
p, _ = run(srv.origin, repo("nobody"), EDIT)
check("not-connected", p.returncode == 1 and p.stderr.strip() == "Espace non connecté" and len(srv.calls) == n + 1
      and last(srv)["headers"].get("Authorization") == "Bearer ergana-not-connected", (p.stderr, srv.calls[n:]))
# no .ergana, no workspace: nothing is sent
shutil.rmtree(os.path.join(HOME, ".config"))
n = len(srv.calls)
p, _ = run(srv.origin, repo(None), EDIT)
check("no-workspace", p.returncode == 0 and p.stdout == "" and p.stderr == "" and len(srv.calls) == n, (p.stderr, len(srv.calls) - n))
store(srv.origin)

# 6 isError
srv.mcp = (200, ok_body("Règle refusée", True), [])
p, _ = run(srv.origin, r, EDIT)
check("is-error", p.returncode == 1 and p.stderr.strip() == "Règle refusée" and p.stdout == "", (p.stdout, p.stderr))
srv.mcp = (200, ok_body("x" * 1000, True), [])
p, _ = run(srv.origin, r, EDIT)
check("cut-300", len(p.stderr.strip()) == 300, len(p.stderr))

# 7 down, stalled, trickling
s = socket.socket()
s.bind(("127.0.0.1", 0))
dead = "http://127.0.0.1:%d" % s.getsockname()[1]
s.close()
store(dead)
p, _ = run(dead, r, EDIT)
check("unreachable", p.returncode == 1 and p.stderr.strip() == "Ergana › server unreachable", p.stderr)


def stall(hd):
    time.sleep(8)


def trickle(hd):
    hd.send_response(200)
    hd.send_header("Content-Length", "100000")
    hd.end_headers()
    for _ in range(40):
        try:
            hd.wfile.write(b"x")
            hd.wfile.flush()
        except OSError:
            return
        time.sleep(0.3)


for name, fn in (("stalled", stall), ("trickling", trickle)):
    srv.mcp = fn
    p, dt = run(srv.origin, r, EDIT, timeout=5)
    check("too-slow-" + name, p.returncode == 1 and p.stderr.strip() == "Ergana › server too slow" and dt < 5.5,
          (p.stderr, dt))
p, _ = run(srv.origin, r, EDIT, lang="fr", timeout=5)
check("too-slow-fr", "trop lent" in p.stderr, p.stderr)

# 8 unreadable
srv.mcp = (200, b"<html>SECRET-BODY</html>", [])
p, _ = run(srv.origin, r, EDIT)
check("non-json", p.returncode == 1 and p.stderr.strip() == "Ergana › unreadable answer", p.stderr)
srv.mcp = (200, ok_body("y" * (1024 * 1024 + 10)), [])
p, _ = run(srv.origin, r, EDIT)
check("over-1mb", p.returncode == 1 and p.stderr.strip() == "Ergana › unreadable answer" and p.stdout == "", (p.stderr[:80], len(p.stdout)))

# 9 the token never leaks; a redirect is not followed
other = Fake()
other.mcp = (200, ok_body(), [])
srv.mcp = (302, b"", [("Location", other.origin + "/mcp")])
p, _ = run(srv.origin, r, EDIT)
check("redirect-not-followed", p.returncode == 1 and p.stderr.strip() == "Ergana › redirected, request not followed"
      and not other.calls and p.stdout == "", (p.stderr, other.calls))
srv.mcp = (200, ok_body("fine"), [])
store(srv.origin, access="SECRET-TOKEN-XYZ")
# the script's children are watched from outside: sample the process table while a slow call runs
srv.mcp = lambda hd: (time.sleep(1.5), hd.reply(200, ok_body("fine")))
seen = []
done = threading.Event()


def sample():
    while not done.is_set():
        seen.append(subprocess.run(["ps", "-axww", "-o", "args="], capture_output=True, text=True).stdout)
        time.sleep(0.1)


th = threading.Thread(target=sample)
th.start()
p, _ = run(srv.origin, r, EDIT)
done.set()
th.join()
check("token-not-in-argv", p.stdout == "fine" and "SECRET-TOKEN-XYZ" not in "".join(seen) and bool(seen))
check("token-not-in-output", "SECRET-TOKEN-XYZ" not in p.stdout + p.stderr and p.stdout == "fine", (p.stdout, p.stderr))
check("token-sent", last(srv)["headers"].get("Authorization") == "Bearer SECRET-TOKEN-XYZ")

shutil.rmtree(TMP, ignore_errors=True)
sys.exit(1 if failed else 0)
