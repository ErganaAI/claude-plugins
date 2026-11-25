#!/bin/sh
# PostToolUse of check_done and record_check: when the server answers through, it names the
# fingerprint it cleared ("cleared": <64 hex>), and when that is the fingerprint this plugin sent
# with the call (sent/<session>.<tool>, ergana-tools.sh) it becomes the session's cleared one;
# stop.sh lets the stop through while the repository is still exactly that. Only the server's
# own field counts, never a "through" quoted in a verdict's free text (review R1). Claude Code's
# tool_response shape for an MCP tool is undocumented: the field is matched plain and
# JSON-escaped, with optional spaces after the colon. No jq.
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
sent=$(cat "$data/sent/$session.$tool" 2>/dev/null)
printf '%s' "$sent" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || exit 0
printf '%s' "$input" | grep -Eq '\\*"cleared\\*"[[:space:]]*:[[:space:]]*\\*"'"$sent"'\\*"' || exit 0
mkdir -p "$data/cleared" 2>/dev/null && printf '%s\n' "$sent" >"$data/cleared/$session"
exit 0
