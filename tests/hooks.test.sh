#!/bin/sh
# plugins/ergana/hooks/hooks.json: no mcp_tool hook; every call to Ergana is a command hook running
# ergana-hook.py with today's tool, fields, values and timeout; no hook sends the working folder, the only
# path any hook sends is before_edit's file_path (DR-0038.D1, DR-0059.D1):
#   sh tests/hooks.test.sh
here=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$here/plugins/ergana/hooks/hooks.json" <<'PY'
import json, shlex, sys
allowed = {"agent_type", "file_path", "state", "name", "background_tasks", "questions"}
tools = {"before_edit", "session_state", "check_done"}
# today's calls: (event, matcher) -> (tool, timeout, {field: literal, or a dotted path into the hook input})
expected = {
    ("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit"): ("before_edit", 30, {"agent_type": ".agent_type", "file_path": ".tool_input.file_path"}),
    ("PreToolUse", "AskUserQuestion"): ("session_state", 10, {"state": "waiting", "questions": ".tool_input.questions"}),
    ("Stop", None): ("check_done", 30, {"background_tasks": ".background_tasks"}),
    ("PostToolUse", "AskUserQuestion"): ("session_state", 10, {"state": "working"}),
    ("Notification", "permission_prompt"): ("session_state", 10, {"state": "waiting"}),
    ("UserPromptSubmit", None): ("session_state", 10, {"state": "working", "name": ".session_title"}),
    ("SessionEnd", "clear"): ("session_state", 10, {"state": "stopped"}),
}
bad = []
found = {}
for event, groups in json.load(open(sys.argv[1]))["hooks"].items():
    for g in groups:
        for h in g["hooks"]:
            if h["type"] == "mcp_tool":
                bad.append(f"{event}: mcp_tool hook {h.get('tool')}")
                continue
            if "ergana-hook.py" not in h["command"]:
                continue
            argv = shlex.split(h["command"])
            if "cwd" in h["command"]:
                bad.append(f"{event}: cwd in {h['command']}")
            tool, timeout, pairs = argv[3], argv[4], argv[5:]
            if tool not in tools:
                bad.append(f"{event}: unknown tool {tool}")
            if str(h.get("timeout")) != timeout:
                bad.append(f"{event}/{tool}: argv timeout {timeout} != hook timeout {h.get('timeout')}")
            fields = dict(p.split("=", 1) for p in pairs)
            for k in fields:
                if k not in allowed:
                    bad.append(f"{event}/{tool}: field {k} not allowed")
            found[(event, g.get("matcher"))] = (tool, h.get("timeout"), fields)
if found != expected:
    bad.append(f"calls differ from today's:\n    found    {found}\n    expected {expected}")
if bad:
    print("FAIL hooks:", *bad, sep="\n  ")
    sys.exit(1)
print(f"ok   {len(found)} Ergana calls are command hooks with today's tool, fields, values and timeout, no cwd")
PY
# skills/login/SKILL.md: no question before the browser, login runs with no --workspace (DR-0040.D1)
skill="$here/plugins/ergana/skills/login/SKILL.md"
if grep -q AskUserQuestion "$skill" || ! grep -qF 'ergana-auth.py" login' "$skill"; then
  echo "FAIL login skill: AskUserQuestion present or bare login command missing"
  exit 1
fi
echo "ok   login skill asks nothing and runs login at once"
# I8: the connection is checked before the browser line, so a connected workspace hears only « déjà connecté »
c=$(grep -nF 'ergana-auth.py" connected' "$skill" | head -n 1 | cut -d: -f1)
b=$(grep -n 'browser opens' "$skill" | head -n 1 | cut -d: -f1)
if [ -z "$c" ] || [ -z "$b" ] || [ "$c" -ge "$b" ]; then
  echo "FAIL login skill: the connected check does not come before the browser sentence"
  exit 1
fi
echo "ok   login skill checks the connection before the browser sentence"
