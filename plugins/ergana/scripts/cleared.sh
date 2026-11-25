#!/bin/sh
# PostToolUse of check_done and record_check: when the server answers through:true, the fingerprint
# this plugin sent with that call (sent/<session>.<tool>, ergana-tools.sh) is the one cleared, and
# stop.sh lets the stop through while the repository is still exactly that. Claude Code's
# tool_response shape for an MCP tool is undocumented: "through":true is matched plain and
# JSON-escaped (\"through\":true), with optional spaces after the colon. No jq.
# Files of start/, sent/, cleared/ and refused/ older than 30 days are removed.
input=$(cat)
data=${CLAUDE_PLUGIN_DATA:-}
[ -n "$data" ] || exit 0
for d in start sent cleared refused; do
  find "$data/$d" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
done
session=$(printf '%s' "$input" | sed -n 's/.*[{,]"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,128\}\)".*/\1/p' | head -n 1)
tool=$(printf '%s' "$input" | sed -nE 's/.*[{,]"tool_name"[[:space:]]*:[[:space:]]*"mcp__plugin_ergana_ergana__(check_done|record_check)".*/\1/p' | head -n 1)
[ -n "$session" ] && [ -n "$tool" ] || exit 0
printf '%s' "$input" | grep -Eq '\\*"through\\*"[[:space:]]*:[[:space:]]*true' || exit 0
sent=$(cat "$data/sent/$session.$tool" 2>/dev/null)
[ -n "$sent" ] || exit 0
mkdir -p "$data/cleared" 2>/dev/null && printf '%s\n' "$sent" >"$data/cleared/$session"
exit 0
