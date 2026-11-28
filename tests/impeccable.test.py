#!/usr/bin/env python3
"""plugins/ergana/scripts/impeccable.py with a fake `claude` (its plugin commands kept in a JSON state, as Claude
Code keeps them), a throwaway Claude config folder and plugin data folder, and a loopback fake Ergana for the
setting (ERGANA_AUTH_TEST=1):

    python3 tests/impeccable.test.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "plugins", "ergana", "scripts")
SCRIPT = os.path.join(SCRIPTS, "impeccable.py")
TMP = tempfile.mkdtemp()
failed = []

# The fake `claude plugin …`: what the real one does to settings.json, installed plugins and marketplaces.
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_STATE"]
config = os.environ["CLAUDE_CONFIG_DIR"]
st = json.load(open(state_path)) if os.path.exists(state_path) else {"plugins": [], "markets": {}}
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
if os.environ.get("FAKE_BROKEN") == "1":
    sys.exit(1)
args = [a for a in sys.argv[2:] if a not in ("--json",)]
settings_path = os.path.join(config, "settings.json")
settings = json.load(open(settings_path)) if os.path.exists(settings_path) else {}
def save():
    json.dump(st, open(state_path, "w"))
    json.dump(settings, open(settings_path, "w"))
if args[:1] == ["list"]:
    print(json.dumps([{"id": p} for p in st["plugins"]], indent=2)); sys.exit(0)  # indented, as the real one
if args[:2] == ["marketplace", "list"]:
    print(json.dumps([{"name": n, "repo": s} for n, s in st["markets"].items()], indent=2)); sys.exit(0)
if args[:2] == ["marketplace", "add"]:
    source = args[2]
    if os.environ.get("FAKE_ADD_FAILS") == "1":
        print(json.dumps({"outcome": "failed"})); sys.exit(1)
    if "impeccable" in st["markets"]:
        print(json.dumps({"outcome": "failed", "failureCode": "declared"})); sys.exit(1)
    repo, _, ref = source.partition("#")
    st["markets"]["impeccable"] = source
    entry = {"source": {"source": "github", "repo": repo}}
    if ref:
        entry["source"]["ref"] = ref
    settings.setdefault("extraKnownMarketplaces", {})["impeccable"] = entry
    save(); print(json.dumps({"outcome": "ok"})); sys.exit(0)
if args[:1] == ["install"]:
    if args[1].split("@")[1] not in st["markets"]:
        print(json.dumps({"outcome": "failed"})); sys.exit(1)
    st["plugins"].append(args[1]); settings.setdefault("enabledPlugins", {})[args[1]] = True
    save(); print(json.dumps({"outcome": "ok"})); sys.exit(0)
if args[:2] == ["marketplace", "remove"]:
    name = args[2]
    if name not in st["markets"]:
        print(json.dumps({"outcome": "failed"})); sys.exit(1)
    del st["markets"][name]
    st["plugins"] = [p for p in st["plugins"] if not p.endswith("@" + name)]
    settings.get("extraKnownMarketplaces", {}).pop(name, None)
    settings.get("enabledPlugins", {}).pop("impeccable@" + name, None)
    save(); print(json.dumps({"outcome": "ok"})); sys.exit(0)
if args[:1] == ["uninstall"]:
    st["plugins"] = [p for p in st["plugins"] if p != args[1]]
    save(); print(json.dumps({"outcome": "ok"})); sys.exit(0)
sys.exit(2)
'''


def check(name, cond, detail=""):
    if cond:
        print("ok   " + name)
    else:
        print("FAIL %s: %s" % (name, detail))
        failed.append(name)


class World:
    """A machine: a Claude config folder, the plugin's data folder and the fake claude's state and log."""

    def __init__(self, name):
        self.dir = os.path.join(TMP, name)
        self.config = os.path.join(self.dir, "claude")
        self.data = os.path.join(self.dir, "data")
        os.makedirs(self.config)
        os.makedirs(self.data)
        self.bin = os.path.join(self.dir, "claude-bin")
        with open(self.bin, "w") as f:
            f.write(FAKE)
        os.chmod(self.bin, 0o755)
        self.state = os.path.join(self.dir, "state.json")
        self.log = os.path.join(self.dir, "log")
        open(self.log, "w").close()

    def env(self, **extra):
        env = {"PATH": os.environ["PATH"], "HOME": self.dir, "CLAUDE_CONFIG_DIR": self.config,
               "CLAUDE_PLUGIN_DATA": self.data, "CLAUDE_CODE_EXECPATH": self.bin, "FAKE_STATE": self.state,
               "FAKE_LOG": self.log, "ERGANA_AUTH_TEST": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        env.update(extra)
        return env

    def run(self, *args, stdin="", **extra):
        return subprocess.run([sys.executable, "-I", SCRIPT, *args], input=stdin, capture_output=True, text=True,
                              env=self.env(**extra), timeout=60)

    def calls(self):
        return [line for line in open(self.log).read().splitlines() if not line.startswith(("plugin list",
                                                                                              "plugin marketplace list"))]

    def settings(self):
        p = os.path.join(self.config, "settings.json")
        return json.load(open(p)) if os.path.exists(p) else {}

    def market(self):
        return (self.settings().get("extraKnownMarketplaces") or {}).get("impeccable")

    def marker(self):
        p = os.path.join(self.data, "impeccable", "installed")
        return json.load(open(p)) if os.path.exists(p) else None

    def cache(self, enabled, version, age=0):
        os.makedirs(os.path.join(self.data, "impeccable"), exist_ok=True)
        with open(os.path.join(self.data, "impeccable", "setting.json"), "w") as f:
            json.dump({"enabled": enabled, "version": version, "at": int(time.time()) - age}, f)

    def reset_log(self):
        open(self.log, "w").close()


# 1 install at latest: its marketplace, its plugin, Claude Code's own auto-update, the marker
w = World("latest")
p = w.run("install", "latest")
check("latest-installed", p.returncode == 0 and "/reload-plugins" in p.stdout, (p.returncode, p.stdout, p.stderr))
check("latest-commands", w.calls() == ["plugin marketplace add pbakaus/impeccable --scope user --json",
                                       "plugin install impeccable@impeccable --scope user --json"], w.calls())
check("latest-auto-update", w.market() == {"source": {"source": "github", "repo": "pbakaus/impeccable"},
                                           "autoUpdate": True}, w.market())
check("latest-marker", (w.marker() or {}).get("version") == "latest", w.marker())

# 2 again: nothing to do
w.reset_log()
p = w.run("install", "latest")
check("again-unchanged", p.returncode == 0 and w.calls() == [], (p.stdout, w.calls()))

# 3 pinned: removed, then added again at impeccable's release tag, without auto-update
w.reset_log()
p = w.run("install", "4.10.0")
check("pinned-commands", w.calls() == ["plugin marketplace remove impeccable --json",
                                       "plugin marketplace add pbakaus/impeccable#skill-v4.10.0 --scope user --json",
                                       "plugin install impeccable@impeccable --scope user --json"], w.calls())
check("pinned-no-auto-update", w.market() == {"source": {"source": "github", "repo": "pbakaus/impeccable",
                                                         "ref": "skill-v4.10.0"}}, w.market())
check("pinned-marker", (w.marker() or {}).get("version") == "4.10.0", w.marker())

# 4 off (the cached setting, at session start): what Ergana installed is removed, the marker too
w.reset_log()
w.cache(False, "4.10.0")
p = w.run("refresh", stdin='{"session_id":"s1"}')
check("off-removed", p.returncode == 0 and w.calls() == ["plugin marketplace remove impeccable --json"]
      and w.market() is None and w.marker() is None, (w.calls(), w.market(), w.marker()))
w.reset_log()
w.run("refresh", stdin='{"session_id":"s1"}')
check("off-again-nothing", w.calls() == [], w.calls())

# 5 the person's own impeccable is never touched: their marketplace, or a skill npx installed
mine = World("theirs")
with open(mine.state, "w") as f:
    json.dump({"plugins": ["impeccable@impeccable"], "markets": {"impeccable": "pbakaus/impeccable"}}, f)
mine.cache(False, "latest")
mine.run("refresh", stdin='{"session_id":"s1"}')
check("theirs-not-removed", mine.calls() == [], mine.calls())
p = mine.run("install", "4.10.0")
check("theirs-not-replaced", p.returncode == 0 and mine.calls() == [] and "outside Ergana" in p.stdout,
      (mine.calls(), p.stdout))
skill = World("skill")
os.makedirs(os.path.join(skill.config, "skills", "impeccable"))
skill.cache(True, "latest")
skill.run("refresh", stdin='{"session_id":"s1"}')
check("skill-not-doubled", skill.calls() == [], skill.calls())

# 6 a version that is no release, no Claude Code, a marketplace that does not answer
w = World("refusals")
p = w.run("install", "4.11")
check("bad-version", p.returncode == 1 and w.calls() == [] and open(w.log).read() == "", p.stdout)
p = w.run("install", "latest", CLAUDE_CODE_EXECPATH="/nonexistent", PATH="/usr/bin:/bin")
check("no-claude", p.returncode == 1 and "could not be installed" in p.stdout, p.stdout)
p = w.run("install", "latest", FAKE_ADD_FAILS="1")
check("add-fails", p.returncode == 1 and w.marker() is None, (p.stdout, w.marker()))
w.reset_log()
p = w.run("install", "latest", FAKE_BROKEN="1")
check("claude-cannot-say", p.returncode == 1 and w.marker() is None
      and all(c.startswith("plugin list") or c.startswith("plugin marketplace list")
              for c in open(w.log).read().splitlines()), open(w.log).read())
p = w.run("install", "latest", CLAUDE_PLUGIN_DATA="")
check("no-data-folder", p.returncode == 1 and "no plugin data folder" in p.stdout, p.stdout)


# 7 the setting from Ergana: plugin_settings through ergana-hook.py, cached, applied; Ergana unreachable: the cache
class Fake:
    def __init__(self):
        self.calls = []
        self.answer = {"impeccable": {"enabled": True, "version": "latest"}}
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                outer.calls.append(json.loads(raw))
                body = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"content": [
                    {"type": "text", "text": json.dumps(outer.answer)}], "isError": False}}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.httpd.daemon_threads = True
        self.origin = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()


srv = Fake()
w = World("refresh")
repo = os.path.join(w.dir, "repo")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
with open(os.path.join(repo, ".ergana"), "w") as f:
    f.write("workspace = acme\n")
tokens = os.path.join(w.dir, ".config", "ergana", srv.origin.split("//")[1].replace(":", "_"))
os.makedirs(tokens, mode=0o700)
with open(os.path.join(tokens, "acme"), "w") as f:
    json.dump({"access": "TOKEN-1", "refresh": "R", "expires_at": int(time.time()) + 3600, "origin": srv.origin}, f)
hook = json.dumps({"session_id": "s1", "cwd": repo})
env = {"ERGANA_ORIGIN": srv.origin, "ERGANA_AUTH_KEYCHAIN": "0", "CLAUDE_PROJECT_DIR": repo}
p = w.run("refresh", stdin=hook, **env)
call = srv.calls[-1] if srv.calls else {}
check("fetch-call", call.get("params", {}).get("name") == "plugin_settings"
      and call["params"]["arguments"].get("session_id") == "s1", call)
cached = json.load(open(os.path.join(w.data, "impeccable", "setting.json")))
check("fetch-cached", cached.get("enabled") is True and cached.get("version") == "latest", cached)
check("fetch-applied", w.calls()[:1] == ["plugin marketplace add pbakaus/impeccable --scope user --json"], w.calls())
n = len(srv.calls)
w.run("refresh", stdin=hook, **env)
check("fresh-cache-no-call", len(srv.calls) == n, len(srv.calls))
# a stale cache is asked again; an answer Ergana cannot give leaves the cached setting in force
w.cache(True, "latest", age=3600)
srv.answer = {"impeccable": {"enabled": True, "version": "not a version"}}
w.reset_log()
w.run("refresh", stdin=hook, **env)
check("bad-answer-keeps-cache", len(srv.calls) == n + 1 and w.calls() == [], (len(srv.calls), w.calls()))
srv.answer = {"impeccable": {"enabled": False, "version": "latest"}}
w.run("refresh", stdin=hook, **env)
check("turned-off-from-ergana", w.marker() is None and w.market() is None, (w.marker(), w.market()))
# never production: test mode with no test origin sends nothing and changes nothing
quiet = World("never-production")
p = quiet.run("refresh", stdin=hook)
check("no-origin-nothing", p.returncode == 0 and open(quiet.log).read() == ""
      and not os.path.exists(os.path.join(quiet.data, "impeccable", "setting.json")), open(quiet.log).read())

# 8 session start: the installer's path for the agent's shell, and the refresh started without waiting on it
w = World("session")
envfile = os.path.join(w.dir, "env")
started = time.monotonic()
p = subprocess.run(["/bin/sh", os.path.join(SCRIPTS, "session-context.sh")], input='{"session_id":"abc-1"}',
                   capture_output=True, text=True, timeout=30,
                   env=w.env(CLAUDE_ENV_FILE=envfile, PATH="/usr/bin:/bin:" + os.environ["PATH"]))
check("env-file", open(envfile).read() == "export ERGANA_IMPECCABLE='%s'\n" % os.path.join(SCRIPTS, "impeccable.sh"),
      open(envfile).read() if os.path.exists(envfile) else None)
check("session-start-fast", p.returncode == 0 and time.monotonic() - started < 8, time.monotonic() - started)

shutil.rmtree(TMP, ignore_errors=True)
if failed:
    print("%d failed: %s" % (len(failed), ", ".join(failed)))
    sys.exit(1)
print("all passed")
