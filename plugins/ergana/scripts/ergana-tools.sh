#!/bin/sh
# Ergana's own tools, called by an agent, carry what code knows rather than what the agent typed:
# - before_edit and session_state are for the plugin's hooks only (a hook's own call does not pass
#   through PreToolUse), so an agent's direct call is denied;
# - check_done is the Stop hook's, and the main agent's after a refused stop: the agent's call
#   carries the repository's fingerprint (fingerprint.sh) and the one the session started with
#   (session-context.sh), computed here; the server lets the next stop through when the
#   repository is as its last passing check, or with no check its start, left it;
# - begin_check and record_check are for the ergana:check subagent only;
# - session_id is this session's, from the hook input, whatever the agent typed;
# - record_check's base_sha and diff_sha256 are computed here: the base is
#   `git merge-base HEAD origin/HEAD` (else HEAD), the hash the repository's fingerprint, so a
#   stop's fingerprint equals its check's when nothing changed.
# The changed input goes back as updatedInput, which replaces the tool's whole input, so the
# input is rewritten as text: no jq. A key matched only after `{` or `,` cannot sit inside a JSON
# string (a quote there is escaped). The hook's own fields are read with the tool's input cut
# out, so the tool's input cannot pose as them. Input this script cannot read passes untouched,
# except on check_done and the two check tools, which are denied rather than sent with the
# agent's values.
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
  before_edit | session_state)
    deny "Ergana's $tool is called by Ergana's hooks only, never directly." ;;
  check_done)
    printf '%s' "$outer" | grep -Eq '[{,]"agent_type":"[^"]' &&
      deny "Ergana's check_done is for the main conversation only." ;;
  begin_check | record_check)
    printf '%s' "$outer" | grep -Eq '[{,]"agent_type":"ergana:check"' ||
      deny "Ergana's $tool is for the ergana:check subagent only: when Ergana refuses the stop, run that subagent as its instructions say." ;;
esac
# A check tool is never sent with the agent's own values.
fail() {
  case $tool in
    check_done) deny "Ergana could not read this call: $1. Run the ergana:check subagent instead." ;;
    begin_check | record_check) deny "Ergana could not read this call: $1. Try again." ;;
  esac
  exit 0
}

session=$(printf '%s' "$outer" | sed -n 's/^{"session_id":"\([A-Za-z0-9_-]*\)".*/\1/p')
[ -n "$session" ] && [ -n "$args" ] || fail "no session id"
# A tool that takes no session_id is left alone: its schema would refuse the extra field.
case $tool in
  check_done | begin_check | record_check) ;;
  *) printf '%s' "$args" | grep -Eq '[{,]"session_id":' || exit 0 ;;
esac

# Every key this script sets is removed, then written first.
strip() {
  sed -E 's/,"'"$1"'":("([^"\\]|\\.)*"|null)//; s/^\{"'"$1"'":("([^"\\]|\\.)*"|null),?/{/'
}
new=$(printf '%s' "$args" | strip session_id)
hex64() { printf '%s' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'; }
here=$(cd "$(dirname "$0")" && pwd)
if [ "$tool" = record_check ] || [ "$tool" = check_done ]; then
  cwd=$(printf '%s' "$outer" | sed -n 's/.*[{,]"cwd":"\([^"\\]*\)".*/\1/p')
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null || fail "no working folder"
fi
if [ "$tool" = record_check ]; then
  base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null) ||
    fail "no git repository"
  sum=$("$here/fingerprint.sh" .) && hex64 "$sum" || fail "no diff hash"
  new=$(printf '%s' "$new" | strip diff_sha256 | strip base_sha)
  new=$(printf '%s' "$new" | sed 's/^{/{"diff_sha256":"'"$sum"'","base_sha":"'"$base"'",/')
fi
if [ "$tool" = check_done ]; then
  # Only the fingerprints written here reach the server: the agent's are dropped, and a
  # repository the script cannot read is "unknown", which asks for the check.
  sum=$("$here/fingerprint.sh" .) && hex64 "$sum" || sum=unknown
  start=$(cat "${CLAUDE_PLUGIN_DATA:-/nonexistent}/start/$session" 2>/dev/null)
  hex64 "$start" && start=',"start_fingerprint":"'"$start"'"' || start=
  new=$(printf '%s' "$new" | strip fingerprint | strip start_fingerprint)
  new=$(printf '%s' "$new" | sed 's/^{/{"fingerprint":"'"$sum"'"'"$start"',/')
fi
new=$(printf '%s' "$new" | sed 's/^{/{"session_id":"'"$session"'",/; s/,}$/}/')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":%s}}\n' "$new"
