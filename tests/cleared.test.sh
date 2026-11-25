#!/bin/sh
# plugins/ergana/scripts/cleared.sh: a through:true answer, plain or JSON-escaped, copies the
# fingerprint sent with the call to cleared/<session>:
#   sh tests/cleared.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/plugins/ergana/scripts/cleared.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
export CLAUDE_PLUGIN_DATA="$tmp/data"
sum=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# try <name> <tool> <tool_response JSON text> <want: cleared|none>
try() {
  rm -rf "$tmp/data"; mkdir -p "$tmp/data/sent"
  printf '%s\n' "$sum" >"$tmp/data/sent/s1.$2"
  printf '{"session_id":"s1","tool_name":"mcp__plugin_ergana_ergana__%s","tool_response":%s}' "$2" "$3" | sh "$script"
  if [ -s "$tmp/data/cleared/s1" ]; then got=cleared; else got=none; fi
  if [ "$got" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: got $got, want $4"; failed=1; fi
}
try plain-true check_done '{"structuredContent":{"through":true}}' cleared
try plain-spaced record_check '{"structuredContent":{"through": true}}' cleared
try escaped-true check_done '"{\"through\":true,\"x\":1}"' cleared
try escaped-spaced record_check '[{"type":"text","text":"{\"through\": true}"}]' cleared
try plain-false check_done '{"structuredContent":{"through":false}}' none
try escaped-false record_check '"{\"through\":false}"' none
try no-field check_done '{"ok":true}' none

# the copied value is the one sent
try copies-sent check_done '{"through":true}' cleared
[ "$(cat "$tmp/data/cleared/s1")" = "$sum" ] && echo "ok   copies-sent-value" || { echo "FAIL copies-sent-value"; failed=1; }
# nothing sent, nothing cleared
rm -rf "$tmp/data"; mkdir -p "$tmp/data/sent"
printf '{"session_id":"s1","tool_name":"mcp__plugin_ergana_ergana__check_done","tool_response":{"through":true}}' | sh "$script"
[ ! -e "$tmp/data/cleared/s1" ] && echo "ok   no-sent" || { echo "FAIL no-sent"; failed=1; }

# files older than 30 days are removed from the four folders
rm -rf "$tmp/data"; mkdir -p "$tmp/data/start" "$tmp/data/sent" "$tmp/data/cleared" "$tmp/data/refused"
for d in start sent cleared refused; do touch -t 202001010000 "$tmp/data/$d/old"; touch "$tmp/data/$d/new"; done
printf '{"session_id":"s1","tool_name":"mcp__plugin_ergana_ergana__check_done","tool_response":{}}' | sh "$script"
left=$(cd "$tmp/data" && ls */* | tr '\n' ' ')
[ "$left" = "cleared/new refused/new sent/new start/new " ] && echo "ok   cleanup" || { echo "FAIL cleanup: $left"; failed=1; }
exit $failed
