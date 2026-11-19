#!/bin/sh
# SessionStart: hand the agent its Claude Code session id; the server's instructions say what to
# do with it (the plugin carries no instruction text).
# No jq: the hook input is matched as text, and an id outside [A-Za-z0-9-]{1,128} prints nothing.
id=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]\{1,128\}\)".*/\1/p' | head -n 1)
[ -n "$id" ] || exit 0
echo "Ergana session id: $id."
