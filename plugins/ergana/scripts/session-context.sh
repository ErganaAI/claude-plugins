#!/bin/sh
# SessionStart: hand the agent its Claude Code session id and ask it to report its steps. The
# server's instructions say the same, but agents seldom act on them alone (John, 19 Nov 2026).
# No jq: the hook input is matched as text, and an id outside [A-Za-z0-9-]{1,128} prints nothing.
id=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]\{1,128\}\)".*/\1/p' | head -n 1)
[ -n "$id" ] || exit 0
echo "Ergana session id: $id."
echo "Report this session's progress with Ergana's report_step tool and this id: first the repository (its origin URL) and the task in one line, then the steps you will run, then each step's start and end."
