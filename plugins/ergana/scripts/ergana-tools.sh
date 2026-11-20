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
# string (a quote there is escaped). The hook's own fields are read with the tool's input cut
# out, so the tool's input cannot pose as them. Input this script cannot read passes untouched,
# except on the two check tools, which are denied rather than sent with the agent's values.
input=$(cat)
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}
# The tool's input: the object after "tool_input", its braces counted outside strings; and the
# hook input without it (`outer`), where the hook's own fields are read.
split=$(printf '%s' "$input" | awk '{
  start = index($0, ",\"tool_input\":{")
  if (!start) exit
  s = substr($0, start + 14); depth = 0; quoted = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (quoted) { if (c == "\\") i++; else if (c == "\"") quoted = 0; continue }
    if (c == "\"") quoted = 1
    else if (c == "{") depth++
    else if (c == "}" && --depth == 0) {
      print substr(s, 1, i); print substr($0, 1, start + 13) "{}" substr(s, i + 1); exit
    }
  }
}')
args=$(printf '%s\n' "$split" | sed -n 1p)
outer=$(printf '%s\n' "$split" | sed -n 2p)
[ -n "$outer" ] || outer=$input
tool=$(printf '%s' "$outer" | sed -n 's/.*[{,]"tool_name":"mcp__plugin_ergana_ergana__\([a-z_]*\)".*/\1/p')
case $tool in
  before_edit | check_done | session_state)
    deny "Ergana's $tool is called by Ergana's hooks only, never directly." ;;
  begin_check | record_check)
    printf '%s' "$outer" | grep -Eq '[{,]"agent_type":"ergana:check"' ||
      deny "Ergana's $tool is for the ergana:check subagent only: when Ergana refuses the stop, run that subagent as its instructions say." ;;
esac
# A check tool is never sent with the agent's own values.
fail() {
  case $tool in begin_check | record_check) deny "Ergana could not read this call: $1. Try again." ;; esac
  exit 0
}

session=$(printf '%s' "$outer" | sed -n 's/^{"session_id":"\([A-Za-z0-9_-]*\)".*/\1/p')
[ -n "$session" ] && [ -n "$args" ] || fail "no session id"
# A tool that takes no session_id is left alone: its schema would refuse the extra field.
case $tool in
  begin_check | record_check) ;;
  *) printf '%s' "$args" | grep -Eq '[{,]"session_id":' || exit 0 ;;
esac

# Every key this script sets is removed, then written first.
strip() {
  sed -E 's/,"'"$1"'":("([^"\\]|\\.)*"|null)//; s/^\{"'"$1"'":("([^"\\]|\\.)*"|null),?/{/'
}
new=$(printf '%s' "$args" | strip session_id)
if [ "$tool" = record_check ]; then
  cwd=$(printf '%s' "$outer" | sed -n 's/.*[{,]"cwd":"\([^"\\]*\)".*/\1/p')
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null || fail "no working folder"
  base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null) ||
    fail "no git repository"
  sum=$(git diff "$base" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-64)
  case $sum in *[!0-9a-f]* | "") fail "no diff hash" ;; esac
  new=$(printf '%s' "$new" | strip diff_sha256 | strip base_sha)
  new=$(printf '%s' "$new" | sed 's/^{/{"diff_sha256":"'"$sum"'","base_sha":"'"$base"'",/')
fi
new=$(printf '%s' "$new" | sed 's/^{/{"session_id":"'"$session"'",/; s/,}$/}/')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":%s}}\n' "$new"
