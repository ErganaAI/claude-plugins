#!/usr/bin/env python3
"""impeccable on this machine, as the company set it on Ergana's Integrations page (server docs/review.md and
docs/plugin.md, "impeccable"; Fabien, 28 Nov 2026).

    impeccable.py refresh            (SessionStart, in the background, the hook input on stdin) the company's
                                     setting from Ergana (plugin_settings, through ergana-hook.py), cached, then applied
    impeccable.py install <version>  (the review, when its design pass needs impeccable now) on, at `latest` or x.y.z

impeccable (pbakaus/impeccable, https://impeccable.style) is a third party's tool: it is installed as its author
intends, as a Claude Code plugin from its own marketplace, hooks included, never copied, changed or configured.
Claude Code's own commands do the work, with the binary running the session ($CLAUDE_CODE_EXECPATH, else `claude`
on PATH), so the VS Code extension's works too:

- on and absent: `plugin marketplace add pbakaus/impeccable` (`#skill-v<version>` when pinned, impeccable's release
  tags), then `plugin install impeccable@impeccable --scope user`. At `latest`, the marketplace's
  extraKnownMarketplaces entry in the user's settings gets "autoUpdate": true, so Claude Code updates it itself.
- on, at another version than the one installed here: the marketplace is removed (which uninstalls the plugin)
  and added again at the new version.
- off: the marketplace and the plugin are removed, only when this script installed them.

What this script installed is written in a marker (impeccable/installed in the plugin's data folder): an
impeccable the person installed themselves (its marketplace, or a skill in ~/.claude/skills) is never touched.
Claude Code loads plugins at a session's start: an install applies at the next session or after /reload-plugins.

The setting is cached in impeccable/setting.json and asked again after CACHE_SECONDS; when Ergana cannot be
reached, the cached one applies, and with none nothing changes. One run at a time (a lock folder, taken over
after LOCK_STALE seconds). `refresh` is silent; `install` prints one line for the agent and exits 1 when
impeccable could not be installed. Python 3.9, standard library only.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

MARKETPLACE = "impeccable"
PLUGIN = "impeccable@impeccable"
SOURCE = "pbakaus/impeccable"
LATEST = "latest"
VERSION = re.compile(r"^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$")
CACHE_SECONDS = 600
LOCK_STALE = 300
STEP_TIMEOUT = 120


def data_dir():
    base = os.environ.get("CLAUDE_PLUGIN_DATA", "")
    if not base:
        return None
    path = os.path.join(base, "impeccable")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def claude():
    path = os.environ.get("CLAUDE_CODE_EXECPATH", "")
    if path and os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    return shutil.which("claude")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, value):
    tmp = "%s.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def valid(setting):
    """The setting as {"enabled": bool, "version": "latest" | "x.y.z"}, or None."""
    if not isinstance(setting, dict):
        return None
    enabled, version = setting.get("enabled"), setting.get("version")
    if not isinstance(enabled, bool) or not isinstance(version, str):
        return None
    if version != LATEST and not VERSION.match(version):
        return None
    return {"enabled": enabled, "version": version}


class Lock:
    def __init__(self, folder):
        self.path = os.path.join(folder, "lock")
        self.held = False

    def __enter__(self):
        for _ in range(2):
            try:
                os.mkdir(self.path)
                self.held = True
                return self
            except FileExistsError:
                try:
                    if time.time() - os.stat(self.path).st_mtime < LOCK_STALE:
                        return self
                    os.rmdir(self.path)
                except OSError:
                    return self
        return self

    def __exit__(self, *exc):
        if self.held:
            try:
                os.rmdir(self.path)
            except OSError:
                pass


def run(binary, *args):
    """One `claude plugin …` command: (exit code, its --json answer or None)."""
    try:
        p = subprocess.run([binary, "plugin", *args], capture_output=True, text=True, timeout=STEP_TIMEOUT,
                           stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return 1, None
    # `list --json` prints one indented document; the other commands one JSON line after their messages.
    try:
        return p.returncode, json.loads(p.stdout)
    except ValueError:
        pass
    answer = None
    for line in reversed(p.stdout.strip().splitlines()):
        try:
            answer = json.loads(line)
            break
        except ValueError:
            continue
    return p.returncode, answer


def state(binary):
    """What this machine holds: the impeccable marketplace and whether a plugin or a skill is there; None when
    Claude Code cannot say (nothing is then changed)."""
    code, plugins = run(binary, "list", "--json")
    code2, markets = run(binary, "marketplace", "list", "--json")
    if code != 0 or code2 != 0 or not isinstance(plugins, list) or not isinstance(markets, list):
        return None
    plugin = any(isinstance(p, dict) and str(p.get("id", "")).startswith("impeccable@") for p in plugins)
    market = next((m for m in markets if isinstance(m, dict) and m.get("name") == MARKETPLACE), None)
    skill = os.path.isdir(os.path.join(config_dir(), "skills", "impeccable"))
    return {"plugin": plugin, "marketplace": market, "skill": skill}


def auto_update(on):
    """The marketplace's extraKnownMarketplaces entry in the user's settings says autoUpdate (Claude Code's own
    switch, the one /plugin's Marketplaces tab writes). An unreadable settings file is left as it is."""
    path = os.path.join(config_dir(), "settings.json")
    settings = read_json(path)
    if not isinstance(settings, dict):
        return
    entry = (settings.get("extraKnownMarketplaces") or {}).get(MARKETPLACE)
    if not isinstance(entry, dict) or bool(entry.get("autoUpdate")) == on:
        return
    if on:
        entry["autoUpdate"] = True
    else:
        entry.pop("autoUpdate", None)
    write_json(path, settings)


def add(binary, version):
    source = SOURCE if version == LATEST else "%s#skill-v%s" % (SOURCE, version)
    code, _ = run(binary, "marketplace", "add", source, "--scope", "user", "--json")
    if code != 0:
        return False
    code, _ = run(binary, "install", PLUGIN, "--scope", "user", "--json")
    if code != 0:
        run(binary, "marketplace", "remove", MARKETPLACE, "--json")
        return False
    if version == LATEST:
        auto_update(True)
    return True


def remove(binary):
    code, _ = run(binary, "marketplace", "remove", MARKETPLACE, "--json")
    if code != 0:
        run(binary, "uninstall", PLUGIN, "--scope", "user", "--json")


def apply(folder, setting):
    """Make the machine match the setting. Returns installed, unchanged, absent, removed, theirs or failed."""
    binary = claude()
    if binary is None:
        return "failed"
    marker_path = os.path.join(folder, "installed")
    marker = read_json(marker_path)
    ours = isinstance(marker, dict) and isinstance(marker.get("version"), str)
    held = state(binary)
    if held is None:
        return "failed"
    if not setting["enabled"]:
        if not ours:
            return "absent"
        if held["marketplace"] is not None or held["plugin"]:
            remove(binary)
        os.remove(marker_path)
        return "removed"
    if not ours and (held["plugin"] or held["marketplace"] is not None or held["skill"]):
        return "theirs"
    if ours and held["plugin"] and marker["version"] == setting["version"]:
        if setting["version"] == LATEST:
            auto_update(True)
        return "unchanged"
    if held["marketplace"] is not None:
        remove(binary)
    # The marker is written first: an install cut off halfway is still Ergana's to finish or remove.
    write_json(marker_path, {"version": setting["version"], "at": int(time.time())})
    if add(binary, setting["version"]):
        return "installed"
    os.remove(marker_path)
    return "failed"


def fetch(hook):
    """The company's setting from Ergana (plugin_settings), or None."""
    here = os.path.dirname(os.path.realpath(__file__))
    try:
        p = subprocess.run([sys.executable, "-I", os.path.join(here, "ergana-hook.py"), "plugin_settings", "20"],
                           input=hook, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    try:
        return valid(json.loads(p.stdout).get("impeccable"))
    except (ValueError, AttributeError):
        return None


def refresh(folder):
    hook = sys.stdin.read()
    cache_path = os.path.join(folder, "setting.json")
    cached = read_json(cache_path)
    setting = valid(cached)
    fresh = isinstance(cached, dict) and isinstance(cached.get("at"), (int, float)) \
        and time.time() - cached["at"] < CACHE_SECONDS
    if setting is None or not fresh:
        found = fetch(hook)
        if found is not None:
            setting = found
            write_json(cache_path, dict(found, at=int(time.time())))
    if setting is None:
        return 0
    with Lock(folder) as lock:
        if lock.held:
            apply(folder, setting)
    return 0


def install(folder, version):
    if version != LATEST and not VERSION.match(version):
        print("impeccable: the version is `latest` or three numbers, such as 4.11.1.")
        return 1
    with Lock(folder) as lock:
        if not lock.held:
            print("impeccable: another session is installing it; try again in a minute.")
            return 1
        outcome = apply(folder, {"enabled": True, "version": version})
    lines = {
        "installed": "impeccable %s is installed: run /reload-plugins to load it in this session." % version,
        "unchanged": "impeccable is installed: run /reload-plugins if this session does not list its skill.",
        "theirs": "impeccable is already on this machine, installed outside Ergana: run /reload-plugins if this "
                  "session does not list its skill.",
        "failed": "impeccable could not be installed (no Claude Code command, or its marketplace did not answer).",
    }
    print(lines.get(outcome, lines["failed"]))
    return 1 if outcome == "failed" else 0


def main():
    folder = data_dir()
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if folder is None:
        if command == "install":
            print("impeccable: no plugin data folder: run this from a Claude Code session with Ergana's plugin.")
            return 1
        return 0
    if command == "refresh":
        return refresh(folder)
    if command == "install" and len(sys.argv) == 3:
        return install(folder, sys.argv[2])
    sys.stderr.write("usage: impeccable.py refresh | install <latest|x.y.z>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
