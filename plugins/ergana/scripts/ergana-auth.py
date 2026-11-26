#!/usr/bin/env python3
"""Ergana's sign-in per workspace: login, status, logout, later, header.

    ergana-auth.py login [--workspace <slug>]   browser sign-in (PKCE), the token kept per workspace; the
                                                workspace is optional, the account signed in decides
    ergana-auth.py status                       the repository's workspace and whether it is connected
    ergana-auth.py logout [--workspace <slug>]  revoke, then forget the token
    ergana-auth.py later                        do not offer the sign-in again in this repository
    ergana-auth.py header <slug> <budget>       the access token for the MCP headers helper (renewed when
                                                it expires within 5 minutes); nothing but the token on stdout

Python 3.9, standard library only. The origin is https://app.ergana.ai; ERGANA_ORIGIN (and
ERGANA_AUTH_KEYCHAIN, ERGANA_LOGIN_WAIT) are read only when ERGANA_AUTH_TEST=1. Every secret is filed under its origin's host and
is renewed or revoked only at the origin filed with it. A secret never reaches stdout or stderr, except the
access token that `header` prints; errors are one line with no response content.
"""
import base64
import hashlib
import html
import http.client
import json
import os
import re
import secrets
import shutil
import socketserver
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

PROD_ORIGIN = "https://app.ergana.ai"
SLUG_RE = re.compile(r"^[a-z0-9]{3,30}$")
HOST_RE = re.compile(r"^[a-z0-9.-]+(:[0-9]{1,5})?$")
REFRESH_MARGIN = 300  # renew an access token that expires within 5 minutes
LOCK_STALE = 15  # a lock older than this many seconds is taken over
LOGIN_WAIT = 300


class Fail(Exception):
    """An error whose text is safe to show (no secret, no response content)."""

    def __init__(self, message, code=1):
        Exception.__init__(self, message)
        self.code = code


def fr():
    return os.environ.get("LANG", "").startswith("fr")


def t(french, english):
    return french if fr() else english


# ---- origin, host, paths

def test_mode():
    return os.environ.get("ERGANA_AUTH_TEST") == "1"


def origin():
    o = os.environ.get("ERGANA_ORIGIN", "") if test_mode() else ""
    o = (o or PROD_ORIGIN).rstrip("/")
    m = re.match(r"^(https?)://([A-Za-z0-9.-]+)(:[0-9]{1,5})?$", o)
    # outside the tests the origin is PROD_ORIGIN; in them, http only for the loopback
    if not m or (m.group(1) == "http" and m.group(2) not in ("127.0.0.1", "localhost")):
        raise Fail(t("origine invalide", "invalid origin"))
    return o


def host_of(o):
    host = urllib.parse.urlparse(o).netloc.lower()
    if not HOST_RE.match(host):
        raise Fail(t("hôte invalide", "invalid host"))
    return host


def check_slug(slug):
    if not isinstance(slug, str) or not SLUG_RE.fullmatch(slug):
        raise Fail(t("espace invalide (3 à 30 lettres minuscules ou chiffres)",
                     "invalid workspace (3 to 30 lowercase letters or digits)"), 2)
    return slug


def cfg_dir():
    return os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), ".config", "ergana")


def private_dir(path):
    if not os.path.isdir(path):
        parent = os.path.dirname(path)
        if not os.path.isdir(parent):
            os.makedirs(parent)
        os.mkdir(path, 0o700)
        os.chmod(path, 0o700)
    return path


def host_dir(host):
    private_dir(cfg_dir())
    return private_dir(os.path.join(cfg_dir(), host.replace(":", "_")))


def write_private(path, data):
    tmp = "%s.tmp%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


# ---- secret storage: macOS Keychain (service ergana, account <slug>@<host>), else a 0600 file

def use_keychain():
    if test_mode() and os.environ.get("ERGANA_AUTH_KEYCHAIN") in ("0", "1"):
        return os.environ["ERGANA_AUTH_KEYCHAIN"] == "1"
    return sys.platform == "darwin"


def security(args, stdin=None):
    exe = (shutil.which("security") if test_mode() else None) or "/usr/bin/security"
    try:
        return subprocess.run([exe] + args, input=stdin, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise Fail(t("Trousseau inaccessible", "Keychain unavailable"))


def secret_file(slug, host):
    return os.path.join(cfg_dir(), host.replace(":", "_"), slug)


def valid_secret(s):
    return (isinstance(s, dict) and isinstance(s.get("access"), str) and isinstance(s.get("refresh"), str)
            and isinstance(s.get("origin"), str) and isinstance(s.get("expires_at"), (int, float))
            and not isinstance(s.get("expires_at"), bool))


def load_secret(slug, host=None):
    check_slug(slug)
    host = host or host_of(origin())
    if use_keychain():
        r = security(["find-generic-password", "-s", "ergana", "-a", "%s@%s" % (slug, host), "-w"])
        if r.returncode != 0:
            return None
        try:
            data = json.loads(base64.b64decode(r.stdout.strip()).decode("utf-8"))
        except ValueError:
            return None
    else:
        try:
            with open(secret_file(slug, host)) as f:
                data = json.load(f)
        except (OSError, ValueError):
            return None
    return data if valid_secret(data) else None


def store_secret(slug, secret, host=None):
    check_slug(slug)
    host = host or host_of(origin())
    if use_keychain():
        # On the standard input of `security -i`, never on its command line.
        b64 = base64.b64encode(json.dumps(secret).encode("utf-8")).decode("ascii")
        security(["-i"], "add-generic-password -U -s ergana -a %s@%s -w %s\n" % (slug, host, b64))
        if load_secret(slug, host) != secret:
            raise Fail(t("jeton non rangé dans le Trousseau", "token not stored in the Keychain"))
    else:
        host_dir(host)
        write_private(secret_file(slug, host), json.dumps(secret))


def delete_secret(slug, host=None):
    check_slug(slug)
    host = host or host_of(origin())
    if use_keychain():
        security(["delete-generic-password", "-s", "ergana", "-a", "%s@%s" % (slug, host)])
    else:
        try:
            os.remove(secret_file(slug, host))
        except OSError:
            pass


# ---- the index of connected workspaces: one "<host> <slug>" line each, no secret

def index_path():
    return os.path.join(cfg_dir(), "workspaces")


def index_lines():
    try:
        with open(index_path()) as f:
            return [l.strip() for l in f if l.strip()]
    except OSError:
        return []


def index_write(lines):
    if lines:
        private_dir(cfg_dir())
        write_private(index_path(), "".join(l + "\n" for l in lines))
    elif os.path.exists(index_path()):
        os.remove(index_path())


def index_add(slug, host=None):
    line = "%s %s" % (host or host_of(origin()), check_slug(slug))
    lines = index_lines()
    if line not in lines:
        index_write(lines + [line])


def index_remove(slug, host=None):
    line = "%s %s" % (host or host_of(origin()), check_slug(slug))
    lines = index_lines()
    if line in lines:
        index_write([l for l in lines if l != line])


# ---- git and the .ergana file (the same lookup as workspace-headers.sh)

def git(args, cwd):
    try:
        r = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return r.returncode, r.stdout.strip()


def main_of(common):
    return os.path.dirname(common) if os.path.basename(common) == ".git" else None


def find_ergana(start):
    """(path, tracked) of the repository's .ergana: the folder's, the main checkout's of a linked worktree,
    the root's, then git's main checkout when none; the first one git tracks wins, else the first."""
    cands = []

    def add(p):
        if os.path.lexists(p) and p not in cands:
            cands.append(p)

    add(os.path.join(start, ".ergana"))
    gitfile = os.path.join(start, ".git")
    if os.path.isfile(gitfile):
        try:
            with open(gitfile) as f:
                m = re.search(r"^gitdir: *(.+)$", f.read(), re.M)
            gd = os.path.join(start, m.group(1).strip())
            with open(os.path.join(gd, "commondir")) as f:
                common = os.path.realpath(os.path.join(gd, f.read().split("\n")[0].strip()))
            if main_of(common):
                add(os.path.join(main_of(common), ".ergana"))
        except (OSError, AttributeError):
            pass
    rc, top = git(["rev-parse", "--show-toplevel"], start)
    if rc == 0 and top:
        add(os.path.join(top, ".ergana"))
        if not cands:
            rc, common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], start)
            if rc == 0 and main_of(common):
                add(os.path.join(main_of(common), ".ergana"))
    for c in cands:
        d = os.path.dirname(c)
        # tracked: in the index, or still in HEAD (git rm --cached must not hide it)
        if (git(["ls-files", "--error-unmatch", "--", ".ergana"], d)[0] == 0
                or git(["cat-file", "-e", "HEAD:./.ergana"], d)[0] == 0):
            return c, True
    return (cands[0], False) if cands else (None, False)


def read_slug(path):
    """The validated slug a .ergana names; a file with none, or a bad one, is an error."""
    try:
        with open(path) as f:
            lines = f.read().split("\n")
    except OSError:
        raise Fail(t("fichier .ergana illisible", "unreadable .ergana file"), 2)
    for line in lines:
        if line.lstrip().startswith("#"):
            continue
        m = re.match(r"^\s*workspace\s*=(.*)$", line)
        if m:
            return check_slug(m.group(1).strip())
    raise Fail(t("fichier .ergana sans ligne workspace", "no workspace line in the .ergana file"), 2)


def slug_arg(args):
    """The --workspace value of a subcommand's arguments, validated, or None."""
    if not args:
        return None
    if len(args) == 2 and args[0] == "--workspace":
        return check_slug(args[1])
    raise Fail("usage: ergana-auth.py <login|logout> [--workspace <slug>]", 2)


def write_ergana(start, slug):
    rc, top = git(["rev-parse", "--show-toplevel"], start)
    root = top if rc == 0 and top else start
    path = os.path.join(root, ".ergana")
    try:  # never through a symlink or over an existing file
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    except OSError:
        fd = None
    if fd is not None:
        with os.fdopen(fd, "w") as f:
            f.write("workspace = %s\n" % slug)
        rc, excl = git(["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], start)
        if rc == 0 and excl:
            os.makedirs(os.path.dirname(excl), exist_ok=True)
            try:
                with open(excl) as f:
                    text = f.read()
            except OSError:
                text = ""
            if "/.ergana" not in text.split("\n"):
                with open(excl, "a") as f:
                    f.write(("" if text == "" or text.endswith("\n") else "\n") + "/.ergana\n")


# ---- HTTP: form posts to the origin, never following a redirect

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def post_form(o, path, fields, timeout, deadline=None):
    """(status, parsed JSON object or None); errors are summarised without any response content. With a
    monotonic `deadline` the whole exchange (not each socket wait) ends by then."""
    if deadline is not None:
        box = []

        def work():
            try:
                box.append(post_form(o, path, fields, max(0.1, deadline - time.monotonic())))
            except Fail as e:
                box.append(e)

        th = threading.Thread(target=work, daemon=True)
        th.start()
        th.join(max(0.0, deadline - time.monotonic()))
        if not box:
            raise Fail(t("serveur injoignable", "server unreachable"))
        if isinstance(box[0], Fail):
            raise box[0]
        return box[0]
    req = urllib.request.Request(o + path, data=urllib.parse.urlencode(fields).encode("ascii"),
                                 headers={"Accept": "application/json"})
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=timeout) as r:
            status, body = r.status, r.read(65536)
    except urllib.error.HTTPError as e:
        raise Fail(t("refusé par le serveur (HTTP %d)", "refused by the server (HTTP %d)") % e.code)
    except (OSError, http.client.HTTPException):
        raise Fail(t("serveur injoignable", "server unreachable"))
    try:
        data = json.loads(body.decode("utf-8"))
    except ValueError:
        data = None
    return status, data if isinstance(data, dict) else None


def token_request(o, fields, timeout, deadline=None):
    _, data = post_form(o, "/oauth/token", fields, timeout, deadline)
    if (not data or not isinstance(data.get("access_token"), str) or not data["access_token"]
            or not isinstance(data.get("refresh_token"), str) or not data["refresh_token"]):
        raise Fail(t("réponse du serveur invalide", "invalid server response"))
    exp = data.get("expires_in", 3600)
    if not isinstance(exp, (int, float)) or isinstance(exp, bool) or exp <= 0:
        raise Fail(t("réponse du serveur invalide", "invalid server response"))
    return data, {"access": data["access_token"], "refresh": data["refresh_token"],
                  "expires_at": int(time.time() + exp), "origin": o}


def client_id(o):
    return o + "/oauth/clients/ergana-cli"


# ---- login

# The page the browser shows after /connect: tokens and markup of Ergana's /connect pages (card.css), self-contained
# (system fonts, inline SVG, nothing from the network), dark by default, light through prefers-color-scheme.
PAGE_CSS = """
:root{color-scheme:dark;--primary:#8b7bf0;--bg:#0a0e16;--card:#131822;--muted:#1e2530;--line:#2f3744;
--muted-fg:#98a2b2;--fg:#f7f9fb;--logo-top:#8b7bf0;--logo-mid:#c4baf8;--logo-bot:#6a55dd;--logo-eye:#46359c;
--attention:#ff8a3d;--attention-soft:color-mix(in oklab,var(--attention) 11%,var(--card))}
@media (prefers-color-scheme:light){:root{color-scheme:light;--primary:#5847c9;--bg:#f4f4f5;--card:#fff;
--muted:#ececef;--line:#e4e4e7;--muted-fg:#4b5563;--fg:#0e131c;--logo-top:#5847c9;--logo-mid:#8f7eec;
--logo-bot:#3f3095;--logo-eye:#d3ccf9;--attention:#a35200}}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;background:var(--bg);color:var(--fg)}
body{font:.875rem/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
main{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:48px 16px}
.column{width:100%;max-width:480px}
svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
svg.logo{display:block;height:32px;width:auto;margin:0 auto 24px;stroke:none}
.logo-top{fill:var(--logo-top)}.logo-mid{fill:var(--logo-mid)}.logo-bot{fill:var(--logo-bot)}.logo-eye{fill:var(--logo-eye)}
.steps{display:flex;justify-content:center;gap:6px;margin:0 0 14px;padding:0;list-style:none;font-size:12px;
color:var(--muted-fg)}
.steps li{display:flex;align-items:center;gap:6px}
.steps li+li::before{content:"";width:18px;height:1px;background:var(--line)}
.steps b{display:grid;place-items:center;width:18px;height:18px;border-radius:50%;border:1px solid var(--line);
font-size:11px;font-weight:600}
.steps .now{color:var(--fg);font-weight:600}
.steps .now b{background:var(--primary);color:var(--bg);border-color:transparent}
.steps .done b{background:var(--muted);color:var(--muted-fg)}
.card{background:var(--card);border:1px solid var(--line);border-radius:.75rem;padding:32px;text-align:center}
.card>*+*{margin-top:20px}
.icon{display:flex;align-items:center;justify-content:center;width:48px;height:48px;margin:0 auto;border-radius:50%;
background:var(--muted);color:var(--primary)}
.icon.attention{background:var(--attention-soft);color:var(--attention)}
.icon svg{width:24px;height:24px}
h1{font-size:1.5rem;line-height:1.25;font-weight:600;letter-spacing:-.01em;margin:0;text-wrap:balance}
p{margin:6px auto 0;max-width:40ch;font-size:15px;color:var(--muted-fg);text-wrap:balance}
.copy{display:flex;align-items:center;gap:8px;border:1px solid var(--line);border-radius:.5rem;text-align:left;
background:color-mix(in oklab,var(--muted) 40%,transparent);padding:4px 4px 4px 12px}
.copy code{flex:1;min-width:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:14px}
.copy button{display:inline-flex;align-items:center;gap:6px;height:30px;padding:0 10px;border:0;border-radius:.5rem;
background:none;color:var(--fg);font:inherit;font-size:13px;font-weight:500;cursor:pointer}
.copy button:hover{background:var(--muted)}
.copy svg{width:14px;height:14px}
:focus-visible{outline:2px solid var(--primary);outline-offset:2px}
@media (max-width:520px){.card{padding:24px}}
"""
MARK = ('<svg class="logo" viewBox="0 0 34 42" role="img" aria-label="Ergana"><rect class="logo-top" y="2" width="34" '
        'height="8" rx="4"/><rect class="logo-mid" y="17" width="17" height="8" rx="4"/><circle class="logo-eye" '
        'cx="27" cy="21" r="4.5"/><rect class="logo-bot" y="32" width="34" height="8" rx="4"/></svg>')
ICON = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">%s</svg>'  # Lucide (ISC licence)
ICON_CHECK = ICON % '<path d="M20 6 9 17l-5-5"/>'
ICON_ALERT = ICON % '<circle cx="12" cy="12" r="10"/><path d="M12 8v4"/><path d="M12 16h.01"/>'
ICON_COPY = ICON % ('<rect width="14" height="14" x="8" y="8" rx="2"/>'
                    '<path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>')
COPY_JS = ("var b=document.querySelector('.copy button');b.onclick=function(){navigator.clipboard.writeText("
           "'/ergana:login').then(function(){b.lastChild.textContent=b.dataset.done})}")


def callback_page(workspace, reason, nonce):
    """The HTML answer to /callback: connected to `workspace`, or nothing connected for `reason` (plain text)."""
    esc = html.escape
    now = 3 if workspace else 2
    names = (t("Connexion", "Sign in"), t("Autorisation", "Allow"), t("Retour à Claude Code", "Back to Claude Code"))
    steps = "".join('<li class="%s"%s><b>%s</b>%s</li>' % (
        "now" if i == now else "done" if i < now else "", ' aria-current="step"' if i == now else "",
        "✓" if i < now else i, n) for i, n in enumerate(names, 1))
    if workspace:
        title = t("Claude Code est connecté", "Claude Code is connected")
        card = '<div class="icon">%s</div><div><h1>%s</h1><p>%s</p></div>' % (
            ICON_CHECK, title, t("Ce dépôt utilise désormais <strong>%s</strong>. Revenir au terminal ; cet onglet "
                                 "peut être fermé.", "This repository now uses <strong>%s</strong>. Go back to your "
                                 "terminal; you can close this tab.") % esc(workspace))
        script = ""
    else:
        title = t("Rien n'a été connecté", "Nothing was connected")
        card = ('<div class="icon attention">%s</div><div><h1>%s</h1><p>%s %s</p></div><div class="copy">'
                '<code>/ergana:login</code><button type="button" data-done="%s">%s<span>%s</span></button></div>') % (
            ICON_ALERT, title, esc(reason), t("Pour réessayer, lancer ceci dans le dépôt :",
                                              "To try again, run this in the repository:"),
            t("Copié", "Copied"), ICON_COPY, t("Copier", "Copy"))
        script = '<script nonce="%s">%s</script>' % (nonce, COPY_JS)
    return ('<!doctype html><html lang="%s"><head><meta charset="utf-8"><meta name="viewport" content="width=device-'
            'width, initial-scale=1"><title>%s · Ergana</title><style nonce="%s">%s</style></head><body><main><div '
            'class="column">%s<ol class="steps" aria-label="%s">%s</ol><section class="card">%s</section></div></main>'
            '%s</body></html>') % (t("fr", "en"), title, nonce, PAGE_CSS, MARK, t("Étapes", "Steps"), steps, card,
                                   script)


class Callback(BaseHTTPRequestHandler):
    timeout = 5  # an idle connection must not hold the single-threaded server

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path != "/callback":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        srv = self.server
        if not secrets.compare_digest(q.get("state", "").encode(), srv.state.encode()):
            body = b"Ergana: unexpected state."  # not the browser's answer: keep waiting for the real one
            self.send_response(400)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        elif q.get("code"):
            # The exchange runs here so the page can name the workspace; any error is kept for browser_login.
            try:
                srv.result = {"workspace": srv.exchange(q["code"])}
            except Exception as e:
                srv.result = {"error": e}
        else:
            srv.result = {"error": Fail(t("connexion refusée dans le navigateur", "sign-in refused in the browser"))}
        ws = srv.result.get("workspace")
        if ws:
            reason = None
        elif q.get("code"):
            e = srv.result["error"]
            reason = str(e).replace("\n", " ") if isinstance(e, Fail) else t("erreur interne", "internal error")
            reason = reason[:1].upper() + reason[1:] + ("" if reason.endswith(".") else ".")
        else:
            reason = t("L'accès a été refusé dans le navigateur.", "Access was denied in the browser.")
        nonce = secrets.token_urlsafe(16)
        body = callback_page(ws, reason, nonce).encode("utf-8")
        self.send_response(200 if ws else 400)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'nonce-%s'; script-src 'nonce-%s'; base-uri 'none'; "
                         "form-action 'none'; frame-ancestors 'none'" % (nonce, nonce))
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def open_browser(url):
    exe = shutil.which("open" if sys.platform == "darwin" else "xdg-open")
    if exe:
        try:
            subprocess.Popen([exe, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        except OSError:
            pass


class CallbackServer(HTTPServer):
    # HTTPServer.server_bind calls socket.getfqdn, a reverse DNS lookup that takes 35 s on a slow resolver.
    server_bind = socketserver.TCPServer.server_bind


def browser_login(o, slug, fslug=None):
    """Sign in at the browser; the pair is stored under the workspace the token names, which is returned."""
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode()
    srv = CallbackServer(("127.0.0.1", 0), Callback)
    srv.state = secrets.token_urlsafe(24)
    srv.result = None
    redirect = "http://127.0.0.1:%d/callback" % srv.server_address[1]

    def exchange(code):
        """The code for the pair, stored under the workspace the token names, which is returned."""
        host = host_of(o)
        # From the exchange until the pair is stored nothing may kill this process: the server has superseded
        # the previous grant, and a pair lost here locks the person out.
        old = {s: signal.signal(s, signal.SIG_IGN)
               for s in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            data, secret = token_request(o, {
                "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                "client_id": client_id(o), "code_verifier": verifier, "resource": o + "/mcp"}, 15)
            got = data.get("ergana_workspace")
            refusal = None
            if not isinstance(got, str) or not SLUG_RE.fullmatch(got):
                refusal = t("réponse du serveur invalide", "invalid server response")
            elif slug and got != slug:
                refusal = (t("Ce dépôt est lié à l'espace %s ; le compte connecté appartient à l'espace %s.",
                             "This repository is linked to the %s workspace; the account signed in belongs to the %s workspace.")
                           if fslug else
                           t("Connexion demandée à l'espace %s ; le compte connecté appartient à l'espace %s.",
                             "Sign-in asked for the %s workspace; the account signed in belongs to the %s workspace.")
                           ) % (slug, got)
                delete_secret(got, host)  # the server superseded it
                index_remove(got, host)
            if refusal:
                try:
                    post_form(o, "/oauth/revoke", {"token": secret["refresh"], "token_type_hint": "refresh_token",
                                                   "client_id": client_id(o)}, 5)
                except Fail as e:
                    refusal += "\n" + t("Révocation non confirmée : %s", "Revocation not confirmed: %s") % e
                raise Fail(refusal)
            lock = secret_file(got, host) + ".lock"
            host_dir(host)
            acquire(lock, time.monotonic() + 10)
            try:
                store_secret(got, secret, host)
            finally:
                shutil.rmtree(lock, ignore_errors=True)
        finally:
            for sig, h in old.items():
                signal.signal(sig, h)
        return got

    srv.exchange = exchange
    url = o + "/oauth/authorize?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": client_id(o), "redirect_uri": redirect,
        "code_challenge": challenge, "code_challenge_method": "S256", "state": srv.state,
        "resource": o + "/mcp", **({"workspace": slug} if slug else {})})
    print(t("Ouverture du navigateur pour la connexion à Ergana. Sans ouverture, ouvrir ce lien : %s",
            "Opening the browser to sign in to Ergana. If nothing opens, open this link: %s") % url)
    sys.stdout.flush()
    open_browser(url)
    wait = float(os.environ.get("ERGANA_LOGIN_WAIT") or LOGIN_WAIT) if test_mode() else LOGIN_WAIT
    deadline = time.monotonic() + wait
    try:
        while srv.result is None:
            left = deadline - time.monotonic()
            if left <= 0:
                raise Fail(t("connexion non terminée après 5 minutes", "sign-in not finished after 5 minutes"))
            srv.timeout = min(left, 1.0)
            srv.handle_request()
    finally:
        srv.server_close()
    if "error" in srv.result:
        raise srv.result["error"]
    return srv.result["workspace"]


def cmd_login(args):
    arg = slug_arg(args)
    start = os.getcwd()
    path, _ = find_ergana(start)
    fslug = read_slug(path) if path else None
    if arg and fslug and arg != fslug:
        raise Fail(t("ce dépôt est lié à l'espace %s par son fichier .ergana : connexion à %s refusée",
                     "this repository is linked to the %s workspace by its .ergana file: sign-in to %s refused")
                   % (fslug, arg))
    slug = arg or fslug
    o = origin()
    host = host_of(o)
    have = load_secret(slug, host) if slug else None
    if have and have["origin"] == o and have["expires_at"] - time.time() > 60:
        print(t("L'espace %s est déjà connecté.", "The %s workspace is already connected.") % slug)
    else:
        slug = browser_login(o, slug, fslug)
        print(t("Connecté à l'espace %s.", "Signed in to the %s workspace.") % slug)
    index_add(slug, host)
    if not path:
        write_ergana(start, slug)
    print(t("Reconnecter ergana dans /mcp, ou ouvrir une nouvelle session.",
            "Reconnect ergana in /mcp, or open a new session."))
    return 0


# ---- header: the access token, renewed under a lock

def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def lock_stale(lock):
    try:
        if time.time() - os.stat(lock).st_mtime > LOCK_STALE:
            return True
        with open(os.path.join(lock, "owner")) as f:
            return not pid_alive(int(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return False


def acquire(lock, deadline):
    # ponytail: two reclaimers of one stale lock can race; the 30 s reuse grace of the server covers it.
    while True:
        try:
            os.mkdir(lock, 0o700)
            with open(os.path.join(lock, "owner"), "w") as f:
                f.write("%d %d\n" % (os.getpid(), int(time.time())))
            return
        except FileExistsError:
            pass
        if lock_stale(lock):
            gone = "%s.stale%d" % (lock, os.getpid())
            try:
                os.rename(lock, gone)
                shutil.rmtree(gone, ignore_errors=True)
            except OSError:
                pass
            continue
        if time.monotonic() >= deadline:
            raise Fail(t("renouvellement déjà en cours", "renewal already in progress"))
        time.sleep(0.05)


def usable(sec, o):
    """The stored secret, only when its origin is exactly the origin in use (scheme included)."""
    return bool(sec) and sec["origin"] == o


def cmd_header(args):
    start = time.monotonic()
    if len(args) != 2:
        raise Fail("usage: ergana-auth.py header <slug> <budget>", 2)
    slug = check_slug(args[0])
    try:
        budget = float(args[1])
    except ValueError:
        raise Fail("usage: ergana-auth.py header <slug> <budget>", 2)
    deadline = start + budget - 0.3
    o = origin()
    host = host_of(o)
    sec = load_secret(slug, host)
    if not usable(sec, o):
        raise Fail(t("espace non connecté", "workspace not connected"))
    if sec["expires_at"] - time.time() > REFRESH_MARGIN:
        sys.stdout.write(sec["access"] + "\n")
        return 0
    lock = secret_file(slug, host) + ".lock"
    host_dir(host)
    acquire(lock, deadline)
    try:
        sec = load_secret(slug, host)  # another session may have renewed it while this one waited
        if not usable(sec, o):
            raise Fail(t("espace non connecté", "workspace not connected"))
        if sec["expires_at"] - time.time() <= REFRESH_MARGIN:
            if deadline - time.monotonic() < 2.0:  # the POST and the store both need room
                raise Fail(t("délai dépassé", "out of time"))
            # From the POST until the new pair is stored (read-back included) nothing may kill this process:
            # the server has rotated the refresh token, and a pair lost here locks the person out.
            old = {s: signal.signal(s, signal.SIG_IGN)
                   for s in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
            try:
                _, new = token_request(sec["origin"], {
                    "grant_type": "refresh_token", "refresh_token": sec["refresh"],
                    "client_id": client_id(sec["origin"]), "resource": sec["origin"] + "/mcp"}, 4.0,
                    deadline - 1.5)
                store_secret(slug, new, host)
            finally:
                for s, h in old.items():
                    signal.signal(s, h)
            sec = new
    finally:
        shutil.rmtree(lock, ignore_errors=True)
    sys.stdout.write(sec["access"] + "\n")
    return 0


# ---- logout, status, later

def repo_slug():
    path, tracked = find_ergana(os.getcwd())
    return (read_slug(path), path, tracked) if path else (None, None, False)


def cmd_logout(args):
    arg = slug_arg(args)
    fslug, _, _ = repo_slug()
    slug = arg or fslug
    if not slug:
        raise Fail(t("espace à indiquer : logout --workspace <espace>", "workspace needed: logout --workspace <slug>"), 2)
    o = origin()
    host = host_of(o)
    sec = load_secret(slug, host)
    warn = None
    if sec:
        if sec["origin"] == o:
            try:
                post_form(sec["origin"], "/oauth/revoke", {
                    "token": sec["refresh"], "token_type_hint": "refresh_token",
                    "client_id": client_id(sec["origin"])}, 5)
            except Fail as e:
                warn = str(e)
        else:
            warn = t("origine du jeton différente", "token origin differs")
        delete_secret(slug, host)
    index_remove(slug, host)
    print(t("Déconnecté de l'espace %s.", "Signed out of the %s workspace.") % slug)
    if warn:
        print(t("Révocation non confirmée : %s", "Revocation not confirmed: %s") % warn)
    return 0


def cmd_status(args):
    if args:
        raise Fail("usage: ergana-auth.py status", 2)
    slug, path, tracked = repo_slug()
    o = origin()
    host = host_of(o)
    if slug:
        source = t("fichier .ergana committé", "committed .ergana file") if tracked else \
            t("fichier .ergana local", "local .ergana file")
        print(t("Espace du dépôt : %s (%s)", "Repository workspace: %s (%s)") % (slug, source))
        sec = load_secret(slug, host)
        if sec and sec["origin"] == o:
            until = time.strftime("%Y-%m-%d %H:%M", time.localtime(sec["expires_at"]))
            if sec["expires_at"] > time.time():
                print(t("Connecté, jeton valable jusqu'à %s (renouvelé seul ensuite).",
                        "Connected, token valid until %s (renewed on its own after that).") % until)
            else:
                print(t("Connecté, jeton échu depuis %s (renouvelé à la prochaine connexion).",
                        "Connected, token expired at %s (renewed at the next connection).") % until)
        else:
            print(t("Non connecté : /ergana:login", "Not connected: /ergana:login"))
    else:
        print(t("Aucun fichier .ergana dans ce dépôt.", "No .ergana file in this repository."))
    others = [l.split(" ", 1)[1] for l in index_lines() if l.split(" ", 1)[0] == host]
    if others:
        print(t("Espaces connectés sur cette machine : %s", "Workspaces connected on this machine: %s")
              % ", ".join(others))
    return 0


def cmd_later(args):
    if args:
        raise Fail("usage: ergana-auth.py later", 2)
    rc, p = git(["rev-parse", "--path-format=absolute", "--git-path", "info/ergana-later"], os.getcwd())
    if rc != 0 or not p:
        raise Fail(t("pas dans un dépôt git", "not in a git repository"))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write("later\n")
    print(t("Connexion non reproposée dans ce dépôt.", "Sign-in not offered again in this repository."))
    return 0


COMMANDS = {"login": cmd_login, "status": cmd_status, "logout": cmd_logout, "later": cmd_later, "header": cmd_header}


def main(argv):
    try:
        if not argv or argv[0] not in COMMANDS:
            raise Fail("usage: ergana-auth.py <%s> ..." % "|".join(COMMANDS), 2)
        return COMMANDS[argv[0]](argv[1:])
    except Fail as e:
        sys.stderr.write("".join("ergana: %s\n" % l for l in str(e).split("\n")))
        return e.code
    except KeyboardInterrupt:
        return 130
    except Exception as e:  # no trace: it could carry a secret
        sys.stderr.write("ergana: %s (%s)\n" % (t("erreur interne", "internal error"), type(e).__name__))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
