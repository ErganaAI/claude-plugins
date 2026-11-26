#!/bin/sh
# plugins/ergana/hooks/hooks.json: no mcp_tool hook sends the working folder; the only path any hook
# sends is before_edit's file_path (DR-0038.D1):
#   sh tests/hooks.test.sh
here=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$here/plugins/ergana/hooks/hooks.json" <<'PY'
import json, sys
allowed = {"session_id", "agent_type", "file_path", "state", "name", "background_tasks", "plugin_version"}
bad = []
n = 0
for event, groups in json.load(open(sys.argv[1]))["hooks"].items():
    for g in groups:
        for h in g["hooks"]:
            if h["type"] != "mcp_tool":
                continue
            n += 1
            for k, v in h["input"].items():
                if "${cwd}" in str(v) or k not in allowed:
                    bad.append(f"{event}/{h['tool']}: {k}={v}")
if n == 0:
    bad.append("no mcp_tool hook found")
if bad:
    print("FAIL hooks:", *bad, sep="\n  ")
    sys.exit(1)
print(f"ok   {n} mcp_tool hooks send no cwd")
PY
# skills/login/SKILL.md: no question before the browser, login runs with no --workspace (DR-0040.D1)
skill="$here/plugins/ergana/skills/login/SKILL.md"
if grep -q AskUserQuestion "$skill" || ! grep -qF 'ergana-auth.py" login' "$skill"; then
  echo "FAIL login skill: AskUserQuestion present or bare login command missing"
  exit 1
fi
echo "ok   login skill asks nothing and runs login at once"
