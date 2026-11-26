#!/usr/bin/env python3
"""plugins/ergana/scripts/ergana-auth.py against a fake local OAuth server, a fake `security` on PATH and a
temporary HOME (the real Keychain and ~/.config are never touched, no real browser is opened):

    python3 tests/ergana-auth.test.py
"""
import base64
import hashlib
import importlib.util
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock
from urllib.parse import parse_qs, urlparse

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "plugins", "ergana", "scripts", "ergana-auth.py")

FAKE_SECURITY = r'''#!/usr/bin/env python3
import json, os, shlex, sys
d = os.environ["FAKE_SECURITY_DIR"]
log = open(os.path.join(d, "log"), "a")
def run(argv):
    log.write("ARGV " + json.dumps(argv) + "\n")
    cmd = argv[0]
    opts = {}
    i = 1
    while i < len(argv):
        if argv[i] in ("-s", "-a", "-w") and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            opts[argv[i]] = True
            i += 1
    path = os.path.join(d, "kc-" + opts.get("-a", "").replace("/", "_"))
    if cmd == "add-generic-password":
        if os.path.exists(path) and "-U" not in opts:
            sys.stderr.write("already exists\n")
            return 45
        open(path, "w").write(opts["-w"])
        return 0
    if cmd == "find-generic-password":
        if not os.path.exists(path):
            return 44
        print(open(path).read())
        return 0
    if cmd == "delete-generic-password":
        if not os.path.exists(path):
            return 44
        os.remove(path)
        return 0
    return 1
if sys.argv[1:2] == ["-i"]:
    rc = 0
    for line in sys.stdin:
        log.write("STDIN " + line)
        parts = shlex.split(line)
        if parts:
            rc = run(parts) or rc
    sys.exit(0)
sys.exit(run(sys.argv[1:]))
'''

# The browser stub: logs the URL and follows it (the fake authorize endpoint redirects to the loopback callback).
FAKE_OPEN = r'''#!/usr/bin/env python3
import os, sys, urllib.request
open(os.environ["OPEN_LOG"], "a").write(sys.argv[1] + "\n")
try:
    urllib.request.urlopen(sys.argv[1], timeout=10).read()
except Exception:
    pass
'''


def s256(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


class FakeOAuth:
    def __init__(self):
        self.reset()
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _json(self, code, body):
                data = body if isinstance(body, bytes) else json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                u = urlparse(self.path)
                q = {k: v[0] for k, v in parse_qs(u.query).items()}
                outer.requests.append(("GET", u.path, q))
                if u.path != "/oauth/authorize":
                    return self._json(404, {})
                outer.authorize.append(q)
                code = "code-%d" % len(outer.authorize)
                outer.codes[code] = q
                state = outer.state_override or q.get("state", "")
                self.send_response(302)
                self.send_header("Location", "%s?code=%s&state=%s" % (q["redirect_uri"], code, state))
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_POST(self):
                u = urlparse(self.path)
                body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
                f = {k: v[0] for k, v in parse_qs(body).items()}
                outer.requests.append(("POST", u.path, f))
                if u.path == "/oauth/revoke":
                    outer.revoked.append(f)
                    return self._json(200, {})
                if u.path != "/oauth/token":
                    return self._json(404, {})
                if outer.token_raw is not None:
                    return self._json(200, outer.token_raw)
                if f.get("grant_type") == "authorization_code":
                    q = outer.codes.get(f.get("code"))
                    if (
                        q is None
                        or s256(f.get("code_verifier", "")) != q.get("code_challenge")
                        or f.get("client_id") != outer.origin + "/oauth/clients/ergana-cli"
                        or f.get("resource") != outer.origin + "/mcp"
                        or f.get("redirect_uri") != q.get("redirect_uri")
                    ):
                        outer.bad_exchanges.append(f)
                        return self._json(400, {"error": "invalid_grant", "marker": "RAW-BODY-MARKER"})
                    outer.exchanged.append(f)
                    return self._json(200, outer.pair(outer.answer_ws or q.get("workspace", "acme")))
                if f.get("grant_type") == "refresh_token":
                    outer.refreshes.append(f)
                    # decide first: a slow answer left over from an earlier test must not touch a later one's state
                    good = not outer.refresh_fail and f.get("refresh_token") in outer.valid_refresh
                    delay = outer.refresh_delay
                    outer.valid_refresh.discard(f.get("refresh_token"))
                    body = outer.pair("acme") if good else None
                    if delay:
                        time.sleep(delay)
                    if not good:
                        return self._json(400, {"error": "invalid_grant", "marker": "RAW-BODY-MARKER"})
                    return self._json(200, body)
                return self._json(400, {})

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.origin = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        self.host = "127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def reset(self):
        self.requests, self.authorize, self.codes = [], [], {}
        self.exchanged, self.bad_exchanges, self.refreshes, self.revoked = [], [], [], []
        self.state_override = None
        self.answer_ws = None
        self.token_raw = None
        self.refresh_delay = 0
        self.refresh_fail = False
        self.valid_refresh = set()
        self.n = 0

    def pair(self, ws):
        self.n += 1
        refresh = "REFRESH-%d" % self.n
        self.valid_refresh.add(refresh)
        return {
            "access_token": "ACCESS-%d" % self.n,
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": refresh,
            "scope": "mcp",
            "ergana_workspace": ws,
        }

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class Base(unittest.TestCase):
    keychain = "0"

    @classmethod
    def setUpClass(cls):
        cls.server = FakeOAuth()
        spec = importlib.util.spec_from_file_location("ergana_auth", SCRIPT)
        cls.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.mod)

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def setUp(self):
        self.server.reset()
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.tmp, "bin")
        self.secdir = os.path.join(self.tmp, "sec")
        for d in (self.home, self.bin, self.secdir):
            os.mkdir(d)
        for name, body in (("security", FAKE_SECURITY), ("open", FAKE_OPEN), ("xdg-open", FAKE_OPEN)):
            p = os.path.join(self.bin, name)
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, 0o755)
        self.open_log = os.path.join(self.tmp, "open.log")
        self.saved = dict(os.environ)
        self.env = {
            "HOME": self.home,
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
            "ERGANA_AUTH_TEST": "1",
            "ERGANA_ORIGIN": self.server.origin,
            "ERGANA_AUTH_KEYCHAIN": self.keychain,
            "FAKE_SECURITY_DIR": self.secdir,
            "OPEN_LOG": self.open_log,
            "LANG": "en_US.UTF-8",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        os.environ.pop("CLAUDE_PROJECT_DIR", None)
        os.environ.update(self.env)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers
    def repo(self, name="repo"):
        d = os.path.join(self.tmp, name)
        subprocess.run(["git", "init", "-q", "-b", "main", d], check=True, env=dict(os.environ))
        subprocess.run(
            ["git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i"],
            check=True,
            env=dict(os.environ),
        )
        return d

    def run_auth(self, args, cwd=None, env=None, timeout=60):
        e = dict(os.environ)
        e.update(env or {})
        return subprocess.run(
            [sys.executable, SCRIPT] + args,
            cwd=cwd or self.tmp,
            env=e,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def popen_auth(self, args, cwd=None):
        return subprocess.Popen(
            [sys.executable, SCRIPT] + args,
            cwd=cwd or self.tmp,
            env=dict(os.environ),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def cfg(self, *p):
        return os.path.join(self.home, ".config", "ergana", *p)

    def secret_file(self, slug="acme", host=None):
        return self.cfg((host or self.server.host).replace(":", "_"), slug)

    def put(self, slug="acme", access="OLD-ACCESS", refresh="REFRESH-OLD", expires_in=3600, origin=None, host=None):
        """A stored secret, through the module's own writer (or by hand for another host key)."""
        origin = origin or self.server.origin
        self.server.valid_refresh.add(refresh)
        secret = {"access": access, "refresh": refresh, "expires_at": int(time.time()) + expires_in, "origin": origin}
        self.mod.store_secret(slug, secret, host=host)
        if host is None:
            self.mod.index_add(slug)
        return secret

    def get(self, slug="acme"):
        return self.mod.load_secret(slug)

    def assert_clean(self, r, *forbidden):
        out = r.stdout + r.stderr
        self.assertNotIn("Traceback", out)
        for s in ("ACCESS-", "REFRESH-", "RAW-BODY-MARKER", "code-1") + forbidden:
            self.assertNotIn(s, out)

    def trusted(self, repo):
        p = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "info/ergana-trusted"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        return os.path.exists(p) or os.path.exists(self.cfg("trusted"))

    def exclude(self, repo):
        p = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        return open(p).read() if os.path.exists(p) else ""


class LoginTest(Base):
    def test_callback_server_skips_reverse_dns(self):
        with mock.patch.object(socket, "getfqdn", side_effect=AssertionError("getfqdn called")) as f:
            srv = self.mod.CallbackServer(("127.0.0.1", 0), self.mod.Callback)
        try:
            self.assertGreater(srv.server_address[1], 0)
            f.assert_not_called()
        finally:
            srv.server_close()

    def test_1_pkce_and_state(self):
        repo = self.repo()
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.server.authorize), 1)
        a = self.server.authorize[0]
        self.assertEqual(a["code_challenge_method"], "S256")
        self.assertEqual(a["workspace"], "acme")
        self.assertEqual(a["resource"], self.server.origin + "/mcp")
        self.assertEqual(a["client_id"], self.server.origin + "/oauth/clients/ergana-cli")
        self.assertRegex(a["redirect_uri"], r"^http://127\.0\.0\.1:\d+/callback$")
        self.assertGreaterEqual(len(a["state"]), 16)
        # the exchange carried the verifier whose S256 is the challenge (the fake server rejects otherwise)
        self.assertEqual(len(self.server.exchanged), 1)
        self.assertEqual(self.server.bad_exchanges, [])
        self.assertEqual(self.get()["access"], "ACCESS-1")
        self.assertIn("/mcp", r.stdout)
        self.assert_clean(r)

    def test_1_wrong_state_refused(self):
        repo = self.repo()
        self.server.state_override = "evil-state"
        t = time.time()
        # a wrong state does not end the login (F5): it waits for the real callback until the deadline
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo, env={"ERGANA_LOGIN_WAIT": "3"})
        self.assertNotEqual(r.returncode, 0)
        self.assertGreaterEqual(time.time() - t, 2.5)
        self.assertLess(time.time() - t, 30)
        self.assertEqual(self.server.exchanged, [])
        self.assertIsNone(self.get())
        self.assertFalse(os.path.exists(os.path.join(repo, ".ergana")))
        self.assert_clean(r)

    def test_2_other_workspace_stores_nothing(self):
        repo = self.repo()
        self.server.answer_ws = "other"
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(self.get())
        self.assertIsNone(self.get("other"))
        self.assertFalse(os.path.exists(self.cfg("workspaces")))
        self.assertFalse(os.path.exists(os.path.join(repo, ".ergana")))
        self.assert_clean(r)

    def test_8_writes_ergana_and_absolute_exclude_from_subfolder(self):
        repo = self.repo()
        sub = os.path.join(repo, "apps", "admin")
        os.makedirs(sub)
        r = self.run_auth(["login", "--workspace", "acme"], cwd=sub)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(repo, ".ergana")) as f:
            self.assertEqual(f.read().strip(), "workspace = acme")
        self.assertFalse(os.path.exists(os.path.join(sub, ".ergana")))
        self.assertIn("/.ergana", self.exclude(repo).splitlines())
        with open(self.cfg("workspaces")) as f:
            self.assertEqual(f.read().split("\n")[0], "%s acme" % self.server.host)
        # a second login does not duplicate the exclusion
        self.run_auth(["login", "--workspace", "acme"], cwd=sub)
        self.assertEqual(self.exclude(repo).splitlines().count("/.ergana"), 1)

    def test_8_uses_ergana_workspace_without_argument(self):
        repo = self.repo()
        with open(os.path.join(repo, ".ergana"), "w") as f:
            f.write("workspace = acme\n")
        r = self.run_auth(["login"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.server.authorize[0]["workspace"], "acme")

    def test_9_contrary_ergana_refused(self):
        repo = self.repo()
        with open(os.path.join(repo, ".ergana"), "w") as f:
            f.write("workspace = other\n")
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.open_log))
        self.assertEqual(self.server.requests, [])
        self.assertIsNone(self.get())

    def test_9_connected_workspace_needs_no_browser(self):
        repo = self.repo()
        self.put()
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.open_log))
        self.assertEqual(self.server.requests, [])
        with open(os.path.join(repo, ".ergana")) as f:
            self.assertEqual(f.read().strip(), "workspace = acme")
        self.assertIn("/.ergana", self.exclude(repo).splitlines())

    def test_10_bad_slug_refused_before_any_file(self):
        repo = self.repo()
        for args in (["login", "--workspace", "../x"], ["logout", "--workspace", "../x"], ["header", "../x", "5"]):
            r = self.run_auth(args, cwd=repo)
            self.assertNotEqual(r.returncode, 0, args)
            self.assertEqual(r.stdout, "")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config")))
        self.assertFalse(os.path.exists(os.path.join(self.home, "x")))
        self.assertFalse(os.path.exists(os.path.join(repo, ".ergana")))
        with open(os.path.join(repo, ".ergana"), "w") as f:
            f.write("workspace = ../x\n")
        for args in (["login"], ["logout"], ["status"]):
            r = self.run_auth(args, cwd=repo)
            self.assertNotEqual(r.returncode, 0, args)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config")))
        self.assertEqual(self.server.requests, [])
        self.assertFalse(os.path.exists(self.open_log))

    def test_12_errors_are_one_quiet_line(self):
        repo = self.repo()
        self.server.token_raw = b"not json RAW-BODY-MARKER"
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertNotEqual(r.returncode, 0)
        self.assert_clean(r)
        self.assertLessEqual(len(r.stderr.strip().splitlines()), 2)
        self.assertIsNone(self.get())
        # the server refuses the exchange
        self.server.token_raw = None
        self.server.state_override = None
        orig = self.server.pair
        self.server.pair = lambda ws: {"error": "x", "marker": "RAW-BODY-MARKER"}
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.server.pair = orig
        self.assertNotEqual(r.returncode, 0)
        self.assert_clean(r)

    def test_12_network_error_on_refresh(self):
        self.put(expires_in=60, origin="http://127.0.0.1:1", host="127.0.0.1:1")
        self.mod.index_add("acme", host="127.0.0.1:1")
        r = self.run_auth(["header", "acme", "5"], env={"ERGANA_ORIGIN": "http://127.0.0.1:1"})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assert_clean(r, "OLD-ACCESS", "REFRESH-OLD")
        self.assertLessEqual(len(r.stderr.strip().splitlines()), 1)


class StoreTest(Base):
    keychain = "1"

    def test_3_secret_only_on_stdin_base64(self):
        repo = self.repo()
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assert_clean(r)
        lines = open(os.path.join(self.secdir, "log")).read().splitlines()
        argv = [l for l in lines if l.startswith("ARGV ")]
        stdin = [l for l in lines if l.startswith("STDIN ")]
        for l in argv:
            self.assertNotIn("ACCESS-1", l)
            self.assertNotIn("REFRESH-1", l)
        self.assertEqual(len(stdin), 1)
        m = stdin[0]
        self.assertTrue(m.startswith("STDIN add-generic-password -U -s ergana -a acme@%s -w " % self.server.host), m)
        b64 = m.rsplit(" -w ", 1)[1]
        self.assertRegex(b64, r"^[A-Za-z0-9+/=]+$")
        data = json.loads(base64.b64decode(b64))
        self.assertEqual(data["access"], "ACCESS-1")
        self.assertEqual(data["refresh"], "REFRESH-1")
        self.assertEqual(data["origin"], self.server.origin)
        self.assertFalse(os.path.exists(self.secret_file()))  # nothing on disk besides the index

    def test_3_awkward_token_roundtrip(self):
        secret = {"access": 'a"b\nc\\d\'e', "refresh": "r\"\n", "expires_at": 1, "origin": self.server.origin}
        self.mod.store_secret("acme", secret)
        self.assertEqual(self.mod.load_secret("acme"), secret)
        self.mod.store_secret("acme", secret)  # -U: a second write replaces
        self.assertEqual(self.mod.load_secret("acme"), secret)

    def test_4_refresh_stores_with_update_flag(self):
        self.put(expires_in=100)
        r = self.run_auth(["header", "acme", "6"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "ACCESS-1")
        self.assertEqual(len(self.server.refreshes), 1)
        self.assertEqual(self.server.refreshes[0]["refresh_token"], "REFRESH-OLD")
        self.assertEqual(self.server.refreshes[0]["client_id"], self.server.origin + "/oauth/clients/ergana-cli")
        self.assertEqual(self.get()["refresh"], "REFRESH-1")
        stdin = [l for l in open(os.path.join(self.secdir, "log")) if l.startswith("STDIN ")]
        self.assertTrue(all(" -U " in l for l in stdin))
        self.assertGreaterEqual(len(stdin), 2)

    def test_7_logout_revokes_and_deletes(self):
        repo = self.repo()
        self.put()
        with open(os.path.join(repo, ".ergana"), "w") as f:
            f.write("workspace = acme\n")
        r = self.run_auth(["logout"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.server.revoked), 1)
        self.assertEqual(self.server.revoked[0]["token"], "REFRESH-OLD")
        self.assertEqual(self.server.revoked[0]["token_type_hint"], "refresh_token")
        self.assertEqual(self.server.revoked[0]["client_id"], self.server.origin + "/oauth/clients/ergana-cli")
        self.assertIsNone(self.get())
        idx = self.cfg("workspaces")
        self.assertTrue(not os.path.exists(idx) or "acme" not in open(idx).read())
        self.assertTrue(os.path.exists(os.path.join(repo, ".ergana")))
        self.assert_clean(r, "OLD-ACCESS")


class FileStoreTest(Base):
    def test_3_file_modes(self):
        self.mod.store_secret("acme", {"access": "A", "refresh": "R", "expires_at": 1, "origin": self.server.origin})
        self.mod.index_add("acme")
        f = self.secret_file()
        self.assertEqual(stat.S_IMODE(os.stat(f).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(f)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.cfg()).st_mode), 0o700)
        self.assertEqual(self.mod.load_secret("acme")["access"], "A")

    def test_3_file_awkward_token(self):
        secret = {"access": 'a"b\nc', "refresh": "r", "expires_at": 1, "origin": self.server.origin}
        self.mod.store_secret("acme", secret)
        self.assertEqual(self.mod.load_secret("acme"), secret)

    def test_4_valid_token_no_network(self):
        self.put(access="VALID-ACCESS", expires_in=3600)
        r = self.run_auth(["header", "acme", "6"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "VALID-ACCESS")
        self.assertEqual(self.server.requests, [])

    def test_header_without_secret_fails_silently(self):
        r = self.run_auth(["header", "acme", "6"])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")

    def test_5_concurrent_headers_refresh_once(self):
        self.put(expires_in=100)
        self.server.refresh_delay = 0.6
        procs = [self.popen_auth(["header", "acme", "7"]) for _ in range(2)]
        outs = [p.communicate(timeout=30) for p in procs]
        self.assertEqual([p.returncode for p in procs], [0, 0], outs)
        self.assertEqual({o[0].strip() for o in outs}, {"ACCESS-1"})
        self.assertEqual(len(self.server.refreshes), 1)

    def _stale_lock(self, owner):
        lock = self.secret_file() + ".lock"
        os.makedirs(lock)
        if owner is not None:
            with open(os.path.join(lock, "owner"), "w") as f:
                f.write(owner)
        return lock

    def test_5b_dead_pid_lock_taken_over(self):
        self.put(expires_in=100)
        p = subprocess.Popen([sys.executable, "-c", "pass"])
        p.wait()
        self._stale_lock("%d %d\n" % (p.pid, int(time.time())))
        r = self.run_auth(["header", "acme", "6"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "ACCESS-1")
        self.assertEqual(len(self.server.refreshes), 1)
        self.assertFalse(os.path.exists(self.secret_file() + ".lock"))

    def test_5b_old_lock_taken_over(self):
        self.put(expires_in=100)
        lock = self._stale_lock("%d %d\n" % (os.getpid(), int(time.time()) - 60))
        old = time.time() - 60
        os.utime(lock, (old, old))
        r = self.run_auth(["header", "acme", "6"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "ACCESS-1")

    def test_5b_ownerless_old_lock_taken_over(self):
        self.put(expires_in=100)
        lock = self._stale_lock(None)
        old = time.time() - 60
        os.utime(lock, (old, old))
        r = self.run_auth(["header", "acme", "6"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "ACCESS-1")

    def test_5c_slow_server_stays_in_budget(self):
        self.put(expires_in=100)
        self.server.refresh_delay = 8
        t = time.time()
        r = self.run_auth(["header", "acme", "3"])
        took = time.time() - t
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertLess(took, 3.5)
        self.assert_clean(r, "OLD-ACCESS")
        self.assertFalse(os.path.exists(self.secret_file() + ".lock"))

    def test_5c_held_lock_stays_in_budget(self):
        self.put(expires_in=100)
        self._stale_lock("%d %d\n" % (os.getpid(), int(time.time())))
        t = time.time()
        r = self.run_auth(["header", "acme", "2"])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertLess(time.time() - t, 3)
        self.assertEqual(self.server.refreshes, [])

    def test_6_refused_refresh_is_empty_and_nonzero(self):
        self.put(expires_in=100)
        self.server.refresh_fail = True
        r = self.run_auth(["header", "acme", "6"])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assert_clean(r, "OLD-ACCESS")
        self.assertEqual(len(self.server.refreshes), 1)

    def test_11_origin_ignored_without_test_flag(self):
        self.put(expires_in=100)
        r = self.run_auth(["header", "acme", "5"], env={"ERGANA_AUTH_TEST": ""})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertEqual(self.server.requests, [])
        # a secret filed under the production host that names another origin is never refreshed there
        os.environ["ERGANA_AUTH_KEYCHAIN"] = "1" if sys.platform == "darwin" else "0"  # what a non-test run uses
        self.put(slug="evil", expires_in=100, host="app.ergana.ai")
        self.mod.index_add("evil", host="app.ergana.ai")
        r = self.run_auth(["header", "evil", "5"], env={"ERGANA_AUTH_TEST": ""})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        r = self.run_auth(["logout", "--workspace", "evil"], env={"ERGANA_AUTH_TEST": ""})
        self.assertEqual(self.server.requests, [])

    def test_11_secret_of_one_host_never_goes_to_another(self):
        other = FakeOAuth()
        try:
            self.put(expires_in=100)
            r = self.run_auth(["header", "acme", "5"], env={"ERGANA_ORIGIN": other.origin})
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, "")
            self.assertEqual(other.requests, [])
            self.assertEqual(self.server.requests, [])
            # even a secret filed under the other host's key but naming this origin is refused
            self.put(slug="tampered", expires_in=100, origin=self.server.origin, host=other.host)
            r = self.run_auth(["header", "tampered", "5"], env={"ERGANA_ORIGIN": other.origin})
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, "")
            self.assertEqual(self.server.requests + other.requests, [])
        finally:
            other.close()

    # -- F5: the loopback server
    def _stub(self, body):
        p = os.path.join(self.bin, "open")
        with open(p, "w") as f:
            f.write("#!/usr/bin/env python3\nimport os, sys, socket, urllib.request, urllib.parse, urllib.error\n"
                    "url = sys.argv[1]\nlog = open(os.environ['OPEN_LOG'], 'a')\n"
                    "redirect = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)['redirect_uri'][0]\n"
                    "port = urllib.parse.urlparse(redirect).port\n"
                    "def status(u):\n"
                    "    try:\n        return urllib.request.urlopen(u, timeout=20).status\n"
                    "    except urllib.error.HTTPError as e:\n        return e.code\n" + body)
        os.chmod(p, 0o755)

    def test_f5_idle_connection_does_not_block_the_login(self):
        self._stub("idle = socket.create_connection(('127.0.0.1', port))\nimport time; time.sleep(0.5)\n"
                   "urllib.request.urlopen(url, timeout=30).read()\n")
        repo = self.repo()
        t = time.time()
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo, timeout=40)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(time.time() - t, 15)
        self.assertEqual(self.get()["access"], "ACCESS-1")

    def test_f5_wrong_state_then_real_callback(self):
        self._stub("base = 'http://127.0.0.1:%d' % port\n"
                   "log.write('%s %s %s %s\\n' % (status(base + '/callback?code=x&state=bad'),"
                   " status(base + '/callback?code=x'), status(base + '/nope'), status(base + '/callback')))\n"
                   "log.flush()\nurllib.request.urlopen(url, timeout=30).read()\n")
        repo = self.repo()
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo, timeout=40)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(open(self.open_log).read().splitlines()[0], "400 400 404 400")
        self.assertEqual(self.get()["access"], "ACCESS-1")
        self.assertEqual(self.server.bad_exchanges, [])

    # -- F4: a symlinked .ergana is never written through
    def test_f4_dangling_symlink_not_written_through(self):
        repo = self.repo()
        target = os.path.join(self.tmp, "victim")
        os.symlink(target, os.path.join(repo, ".ergana"))
        r = self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.lexists(target))
        self.assertEqual(self.server.requests, [])
        self.mod.write_ergana(repo, "acme")  # the writer itself, whatever the lookup did
        self.assertFalse(os.path.lexists(target))
        self.assertTrue(os.path.islink(os.path.join(repo, ".ergana")))

    # -- F3: the origin
    def test_f3_test_mode_http_only_for_loopback(self):
        r = self.run_auth(["header", "acme", "5"], env={"ERGANA_ORIGIN": "http://app.ergana.ai"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("origin", r.stderr)
        r = self.run_auth(["login", "--workspace", "acme"], env={"ERGANA_ORIGIN": "http://evil.example"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("origin", r.stderr)
        self.assertEqual(self.server.requests, [])

    def test_f3_stored_origin_scheme_must_match(self):
        https = "https://" + self.server.host
        self.put(origin=self.server.origin, expires_in=3600)
        r = self.run_auth(["header", "acme", "5"], env={"ERGANA_ORIGIN": https})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        r = self.run_auth(["logout", "--workspace", "acme"], env={"ERGANA_ORIGIN": https})
        self.assertEqual(self.server.requests, [])
        self.put(origin=self.server.origin, expires_in=3600)  # logout forgot it
        r = self.run_auth(["header", "acme", "5"])  # the exact origin still works
        self.assertEqual(r.returncode, 0, r.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "the Keychain is macOS only")
    def test_f3_security_by_absolute_path_outside_tests(self):
        r = self.run_auth(["header", "acme", "5"], env={"ERGANA_AUTH_TEST": "", "ERGANA_AUTH_KEYCHAIN": "1"})
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.secdir, "log")))  # the fake on PATH was never run

    # -- F1: a refresh is not killed once the server has rotated the token
    def _driver(self, budget, delay=0.0):
        self.server.refresh_delay = delay
        code = (
            "import importlib.util, os, signal, sys\nsys.dont_write_bytecode = True\n"
            "spec = importlib.util.spec_from_file_location('ea', %r)\n"
            "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
            "orig = m.store_secret\n"
            "def store(*a, **k):\n"
            "    os.kill(os.getpid(), signal.SIGALRM); os.kill(os.getpid(), signal.SIGTERM)\n"
            "    os.kill(os.getpid(), signal.SIGHUP); os.kill(os.getpid(), signal.SIGINT)\n"
            "    return orig(*a, **k)\n"
            "m.store_secret = store\n"
            "rc = m.cmd_header(['acme', %r])\n"
            "print('survived', signal.getsignal(signal.SIGALRM) is signal.SIG_DFL)\n"
        ) % (SCRIPT, str(budget))
        return subprocess.run([sys.executable, "-c", code], env=dict(os.environ), capture_output=True, text=True,
                              timeout=30)

    def test_f1_signals_ignored_while_storing_then_restored(self):
        self.put(expires_in=100)
        r = self._driver(6)
        self.assertEqual(r.returncode, 0, (r.returncode, r.stderr))
        self.assertIn("ACCESS-1", r.stdout)
        self.assertIn("survived True", r.stdout)  # handlers back to the default afterwards
        self.assertEqual(self.get()["refresh"], "REFRESH-1")

    def test_f1_answer_just_inside_the_post_deadline_is_stored(self):
        self.put(expires_in=100)
        r = self._driver(6, delay=4.0)  # budget deadline 5.7 s, POST deadline 4.2 s
        self.assertEqual(r.returncode, 0, (r.returncode, r.stderr))
        self.assertEqual(self.get()["refresh"], "REFRESH-1")

    def test_f1_post_has_an_overall_deadline(self):
        self.put(expires_in=100)
        self.server.refresh_delay = 8
        t = time.time()
        r = self.run_auth(["header", "acme", "4"])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertLess(time.time() - t, 2.9)  # 4 - 0.3 - 1.5 = 2.2 s, plus start-up

    def test_f1_no_refresh_with_less_than_2s_left(self):
        self.put(expires_in=100)
        r = self.run_auth(["header", "acme", "2"])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertEqual(self.server.refreshes, [])

    def test_status_names_workspace_and_source_never_the_token(self):
        repo = self.repo()
        self.put(access="SECRET-ACCESS-VALUE")
        with open(os.path.join(repo, ".ergana"), "w") as f:
            f.write("workspace = acme\n")
        r = self.run_auth(["status"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("acme", r.stdout)
        self.assertIn(".ergana", r.stdout)
        self.assertNotIn("SECRET-ACCESS-VALUE", r.stdout + r.stderr)
        self.assertNotIn("REFRESH-OLD", r.stdout + r.stderr)

    def test_later_writes_marker(self):
        repo = self.repo()
        r = self.run_auth(["later"], cwd=repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        p = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "info/ergana-later"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertTrue(os.path.exists(p))

    def test_13_no_subcommand_writes_the_confirmation(self):
        repo = self.repo()
        with open(os.path.join(repo, ".ergana"), "w") as f:
            f.write("workspace = acme\n")
        subprocess.run(["git", "-C", repo, "add", ".ergana"], check=True)
        self.put(expires_in=100)
        self.put(slug="other1", access="O", refresh="REFRESH-O1")
        for args in (["login"], ["status"], ["later"], ["header", "acme", "5"], ["logout"]):
            self.run_auth(args, cwd=repo)
        self.run_auth(["login", "--workspace", "acme"], cwd=repo)
        self.assertFalse(self.trusted(repo))


if __name__ == "__main__":
    unittest.main(verbosity=2)
