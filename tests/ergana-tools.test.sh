#!/bin/sh
# plugins/ergana/scripts/ergana-tools.sh: the fingerprints kept for cleared.sh, record_check denied
# when the repository moved since begin_check, and check_done's origin flag:
#   sh tests/ergana-tools.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/plugins/ergana/scripts/ergana-tools.sh"
fp="$here/plugins/ergana/scripts/fingerprint.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CLAUDE_PLUGIN_DATA="$tmp/data"
repo="$tmp/repo"
git init -q "$repo" && git -C "$repo" commit -q --allow-empty -m init
mkdir -p "$tmp/data"

# call <tool> [agent_type]
call() {
  printf '{"session_id":"s1","cwd":"%s","agent_type":"%s","tool_name":"mcp__plugin_ergana_ergana__%s","tool_input":{"x":"y"}}' \
    "$repo" "${2-ergana:check}" "$1" | sh "$script"
}
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; failed=1; fi; }
has() { case $2 in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: '$2' lacks '$3'"; failed=1 ;; esac; }

sum=$("$fp" "$repo")
call begin_check >/dev/null
expect begin-writes-sent "$(cat "$tmp/data/sent/s1.begin_check")" "$sum"
has record-same "$(call record_check)" '"updatedInput"'
expect record-writes-sent "$(cat "$tmp/data/sent/s1.record_check")" "$sum"
echo changed >"$repo/new"
has record-moved "$(call record_check)" 'The repository changed while the check ran: call begin_check again and judge the new diff.'
has record-moved-denied "$(call record_check)" '"permissionDecision":"deny"'
call begin_check >/dev/null
has record-after-new-begin "$(call record_check)" '"updatedInput"'

has origin-false "$(call check_done "")" '"origin":false'
git -C "$repo" remote add origin https://example.com/r.git
has origin-true "$(call check_done "")" '"origin":true'
expect check-done-writes-sent "$(cat "$tmp/data/sent/s1.check_done")" "$("$fp" "$repo")"
exit $failed
