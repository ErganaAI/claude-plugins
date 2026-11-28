#!/usr/bin/env python3
"""One hook's call to Ergana, with headers taken fresh at that moment (DR-0059.D1).

    ergana-hook.py <tool> <timeout seconds> [key=value ...]     (run as python3 -I, the hook input on stdin)

An mcp_tool hook sends the headers the MCP connection got at its start, so a token renewed or rotated since
is not in them. A command hook runs workspace-headers.sh on each call (which renews the token under its
lock), then POSTs one tools/call to Ergana's /mcp (stateless, JSON answers, no initialize) and prints the
tool's text on stdout exactly as a command hook's output, so deny decisions, additionalContext and the Stop
block behave as before.

A value starting with `.` is a dotted path into the hook input (a missing one is left out); any other value
is a literal. session_id comes from the input (none: exit 0, nothing sent) and plugin_version from the
manifest. For session_state only, unattended is a boolean: CLAUDE_CODE_ENTRYPOINT is sdk-cli or ERGANA_UNATTENDED
is 1 (no environment value is sent); app and place are tokens of fixed sets read from the environment (where), and
host the machine's first name label, on the person's own machine or over SSH only. No Authorization header (no workspace): exit 0, nothing sent, the token never leaves this process.

One monotonic deadline covers the whole process: start + timeout - 1 s. The headers helper gets all of it and
is never cut short (it ends within about 8 s by itself, DR-0056.D1); the socket timeout and a SIGALRM watchdog
(armed after the helper, so it cannot kill a renewal) both use what is left. Every redirect is refused, so
the token never follows a Location. Python 3.9, standard library only. The origin is https://app.ergana.ai;
ERGANA_ORIGIN is read only with ERGANA_AUTH_TEST=1, which never reaches production: without a test
ERGANA_ORIGIN (none, invalid, or on app.ergana.ai) the hook fails before anything is sent.

Exit 0 with the text on stdout, or exit 1 with one line on stderr (at most 300 characters): the tool's own
error text, the error_description of a JSON error body, or a fixed line saying the cause (English, or French
when LANG starts with fr). No response content other than those is ever echoed.
"""
import http.client
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

PROD_ORIGIN = "https://app.ergana.ai"
MAX_ANSWER = 1024 * 1024
MIN_LEFT = 0.5


class Slow(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def load_texts():
    """`say` from texts.py beside this script, loaded by its path: `python3 -I` keeps this folder
    off sys.path, so it is never imported by name."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "texts.py")
    scope = {"__name__": "ergana_texts"}
    with open(path, encoding="utf-8") as f:
        exec(compile(f.read(), path, "exec"), scope)  # no __pycache__ in the plugin's folder
    return scope["say"]


say = load_texts()


def fail(line):
    # one line, no control character (a server-worded text could hold an escape sequence)
    line = "".join(c for c in " ".join(str(line).split()) if c.isprintable())
    sys.stderr.write(line[:300] + "\n")
    sys.exit(1)


def origin():
    if os.environ.get("ERGANA_AUTH_TEST") != "1":
        return PROD_ORIGIN
    # a test never reaches production: ERGANA_ORIGIN must name a test server, http only for the loopback
    o = os.environ.get("ERGANA_ORIGIN", "").rstrip("/")
    m = re.match(r"^(https?)://([A-Za-z0-9.-]+)(:[0-9]{1,5})?$", o)
    if not m or (m.group(1) == "http" and m.group(2) not in ("127.0.0.1", "localhost")) \
            or m.group(2).lower().rstrip(".") == "app.ergana.ai":
        fail(say("hook.test_mode_never_production"))
    return o


def dig(obj, path):
    for k in path.split("."):
        if not isinstance(obj, dict) or k not in obj:
            return None
        obj = obj[k]
    return obj


TERMINALS = {"iTerm.app": "iterm", "Apple_Terminal": "terminal", "ghostty": "ghostty",
             "WarpTerminal": "warp", "WezTerm": "wezterm"}


def where(env):
    """(app, place): the app the session runs in and the kind of machine, each one of a fixed set."""
    entry = env.get("CLAUDE_CODE_ENTRYPOINT", "")
    term = env.get("TERM_PROGRAM", "")
    if entry.startswith("sdk-"):
        app = "headless"
    elif entry == "claude-vscode" or term == "vscode":
        app = "cursor" if env.get("CURSOR_TRACE_ID") else "vscode"
    elif entry.startswith("claude-desktop"):
        app = "desktop"
    elif env.get("TERMINAL_EMULATOR", "").startswith("JetBrains"):
        app = "jetbrains"
    else:
        app = TERMINALS.get(term, "terminal")
    if env.get("CODESPACES") == "true":
        place = "codespace"
    elif env.get("REMOTE_CONTAINERS") == "true" or os.path.exists("/.dockerenv"):
        place = "devcontainer"
    elif env.get("WSL_DISTRO_NAME"):
        place = "wsl"
    elif env.get("SSH_CONNECTION") or env.get("SSH_TTY"):
        place = "ssh"
    else:
        place = "local"
    return app, place


def on_alarm(*_):
    raise Slow()


def main():
    start = time.monotonic()
    try:
        timeout = float(sys.argv[2])
    except (IndexError, ValueError):
        fail("usage: ergana-hook.py <tool> <timeout seconds> [key=value ...]")
    deadline = start + timeout - 1
    tool = sys.argv[1]
    try:
        hook = json.loads(sys.stdin.read())
    except ValueError:
        return 0
    sid = hook.get("session_id") if isinstance(hook, dict) else None
    if not isinstance(sid, str) or not sid:
        return 0
    arguments = {"session_id": sid}
    for pair in sys.argv[3:]:
        key, _, val = pair.partition("=")
        v = dig(hook, val[1:]) if val.startswith(".") else val
        if key and v is not None:
            arguments[key] = v
    if tool == "session_state":
        # whether nobody is at the terminal: claude -p (sdk-cli) or a launcher's ERGANA_UNATTENDED=1; a boolean only
        arguments["unattended"] = os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli" \
            or os.environ.get("ERGANA_UNATTENDED") == "1"
        # where it runs, so its person finds its window: fixed tokens, never an environment value; the
        # machine's name only on the person's own machine or over SSH (a container's is random)
        app, place = where(os.environ)
        arguments["app"], arguments["place"] = app, place
        if place in ("local", "ssh"):
            host = socket.gethostname().split(".", 1)[0]
            if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,62}", host):
                arguments["host"] = host.lower()
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        with open(os.path.join(here, "..", ".claude-plugin", "plugin.json")) as f:
            version = json.load(f)["version"]
        arguments["plugin_version"] = version
    except (OSError, ValueError, KeyError):
        version = "0"

    url = origin() + "/mcp"  # before the helper: a test fails here, before any token is read

    # The headers, fresh: the helper's own budget ends it, so it is never killed before the deadline.
    cwd = os.environ.get("CLAUDE_PROJECT_DIR") or hook.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        cwd = os.getcwd()
    try:
        r = subprocess.run(["/bin/sh", os.path.join(here, "workspace-headers.sh"), cwd], capture_output=True,
                           text=True, timeout=max(deadline - time.monotonic(), 0.1))
        headers = json.loads(r.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0
    if not isinstance(headers, dict) or not isinstance(headers.get("Authorization"), str):
        return 0  # no workspace: nothing is sent
    headers = {k: v for k, v in headers.items() if isinstance(v, str)}
    headers.update({"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                    "User-Agent": "ergana-plugin/" + version})

    left = deadline - time.monotonic()
    if left < MIN_LEFT:
        fail(say("hook.server_too_slow"))
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": tool, "arguments": arguments}}).encode()
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    del headers
    signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, left)
    status, err_body = 0, b""
    try:
        try:
            with urllib.request.build_opener(NoRedirect).open(req, timeout=left) as resp:
                status, raw = resp.status, resp.read(MAX_ANSWER + 1)
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read(65536)
    except Slow:
        fail(say("hook.server_too_slow"))
    except socket.timeout:
        fail(say("hook.server_too_slow"))
    except urllib.error.URLError as e:
        if isinstance(e.reason, socket.timeout):
            fail(say("hook.server_too_slow"))
        fail(say("hook.server_unreachable"))
    except OSError:
        fail(say("hook.server_unreachable"))
    except http.client.HTTPException:
        fail(say("hook.unreadable_answer"))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)

    unreadable = say("hook.unreadable_answer")
    if 300 <= status < 400:
        fail(say("hook.redirected_request_not_followed"))
    if len(raw) > MAX_ANSWER:
        fail(unreadable)
    try:
        data = json.loads(raw.decode("utf-8"))
    except ValueError:
        data = None
    if status != 200:
        desc = data.get("error_description") if isinstance(data, dict) else None
        if isinstance(desc, str) and desc.strip():
            fail(desc)
        if status == 401:
            fail(say("hook.sign_in_refused_ergana"))
        fail("Ergana › HTTP %d" % status)
    res = data.get("result") if isinstance(data, dict) else None
    err = data.get("error") if isinstance(data, dict) else None
    if res is None and isinstance(err, dict) and isinstance(err.get("message"), str) and err["message"].strip():
        fail("Ergana › " + err["message"])  # a JSON-RPC error: the server's own message
    items = res.get("content") if isinstance(res, dict) else None
    # isError is optional in MCP, false by default
    if not isinstance(items, list) or not isinstance(res.get("isError", False), bool):
        fail(unreadable)
    text = "\n".join(i["text"] for i in items if isinstance(i, dict) and i.get("type") == "text"
                     and isinstance(i.get("text"), str))
    if res.get("isError", False):
        fail(text or unreadable)
    sys.stdout.buffer.write(text.encode("utf-8", "replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
