#!/bin/sh
# Ergana's own tools, called by an agent, carry what code knows rather than what the agent typed:
# - before_edit, check_done and session_state are for the plugin's hooks only (a hook's own call
#   does not pass through PreToolUse), so an agent's direct call is denied;
# - begin_check and record_check are for the ergana:check subagent only;
# - session_id is this session's, from the hook input, whatever the agent typed;
# - record_check's base_sha and diff_sha256 are computed here, as the check's instructions say:
#   the base is `git merge-base HEAD origin/HEAD` (else HEAD), the hash `git diff <base> | shasum`.
# The changed input goes back as updatedInput, which replaces the tool's whole input, so the
# input is rewritten as text: no jq. A key matched only after `{` or `,` cannot sit inside a JSON
# string (a quote there is escaped). Input this script cannot read passes untouched.
input=$(cat)
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}
tool=$(printf '%s' "$input" | sed -n 's/.*[{,]"tool_name":"mcp__plugin_ergana_ergana__\([a-z_]*\)".*/\1/p')
case $tool in
  before_edit | check_done | session_state)
    deny "Ergana's $tool is called by Ergana's hooks only, never directly." ;;
  begin_check | record_check)
    printf '%s' "$input" | grep -Eq '[{,]"agent_type":"ergana:check"' ||
      deny "Ergana's $tool is for the ergana:check subagent only: when Ergana refuses the stop, run that subagent as its instructions say." ;;
esac

session=$(printf '%s' "$input" | sed -n 's/^{"session_id":"\([A-Za-z0-9_-]*\)".*/\1/p')
# The tool's input: the object after "tool_input", its braces counted outside strings.
args=$(printf '%s' "$input" | awk '{
  start = index($0, ",\"tool_input\":{")
  if (!start) exit
  s = substr($0, start + 14); depth = 0; quoted = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (quoted) { if (c == "\\") i++; else if (c == "\"") quoted = 0; continue }
    if (c == "\"") quoted = 1
    else if (c == "{") depth++
    else if (c == "}" && --depth == 0) { print substr(s, 1, i); exit }
  }
}')
[ -n "$session" ] && [ -n "$args" ] || exit 0
# A tool that takes no session_id is left alone: its schema would refuse the extra field.
case $tool in
  begin_check | record_check) ;;
  *) printf '%s' "$args" | grep -Eq '[{,]"session_id":' || exit 0 ;;
esac

# Every key this script sets is removed, then written first.
strip() {
  sed -E 's/,"'"$1"'":("[^"]*"|null)//; s/^\{"'"$1"'":("[^"]*"|null),?/{/'
}
new=$(printf '%s' "$args" | strip session_id)
if [ "$tool" = record_check ]; then
  cwd=$(printf '%s' "$input" | sed -n 's/.*[{,]"cwd":"\([^"\\]*\)".*/\1/p')
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0
  base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null) || exit 0
  sum=$(git diff "$base" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-64)
  case $sum in *[!0-9a-f]* | "") exit 0 ;; esac
  new=$(printf '%s' "$new" | strip diff_sha256 | strip base_sha)
  new=$(printf '%s' "$new" | sed 's/^{/{"diff_sha256":"'"$sum"'","base_sha":"'"$base"'",/')
fi
new=$(printf '%s' "$new" | sed 's/^{/{"session_id":"'"$session"'",/; s/,}$/}/')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":%s}}\n' "$new"
