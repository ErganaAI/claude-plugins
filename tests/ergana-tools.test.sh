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

# report_step carries the session's relay key from inbox/s1.key, and only report_step does; the agent's own
# relay_key is dropped; a malformed key file is replaced by a good one.
KEY=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ
mkdir -p "$tmp/data/inbox"
step() { printf '{"session_id":"s1","cwd":"%s","tool_name":"mcp__plugin_ergana_ergana__%s","tool_input":%s}' "$repo" "$1" "$2" | sh "$script"; }
hasnt() { case $2 in *"$3"*) echo "FAIL $1: '$2' holds '$3'"; failed=1 ;; *) echo "ok   $1" ;; esac; }
printf '%s\n' "$KEY" >"$tmp/data/inbox/s1.key"
has relay-added "$(step report_step '{"session_id":"x","task":"t"}')" '{"session_id":"s1","relay_key":"'"$KEY"'","task":"t"}'
has relay-agent-key-replaced "$(step report_step '{"session_id":"x","relay_key":"evil","task":"t"}')" '{"session_id":"s1","relay_key":"'"$KEY"'","task":"t"}'
hasnt relay-agent-key-gone "$(step report_step '{"session_id":"x","task":"t","relay_key":"evil"}')" evil
hasnt relay-other-tool "$(step get_messages '{"session_id":"x"}')" relay_key
hasnt relay-not-check-done "$(call check_done "")" relay_key
printf 'short\n' >"$tmp/data/inbox/s1.key"
has relay-malformed-replaced "$(step report_step '{"session_id":"x","task":"t"}')" '"relay_key":"'
printf '%s' "$(cat "$tmp/data/inbox/s1.key")" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$' && echo "ok   relay-malformed-file-fixed" || { echo "FAIL relay-malformed-file-fixed"; failed=1; }
# A report_step with no key file makes it: 43 base64url characters, mode 0600, in the call, never on stderr; an
# existing key is kept.
rm -f "$tmp/data/inbox/s1.key"
out=$(step report_step '{"session_id":"x","task":"t"}' 2>"$tmp/err")
made=$(cat "$tmp/data/inbox/s1.key" 2>/dev/null)
printf '%s' "$made" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$' && echo "ok   relay-created" || { echo "FAIL relay-created: '$made'"; failed=1; }
has relay-created-in-call "$out" '{"session_id":"s1","relay_key":"'"$made"'","task":"t"}'
case $(ls -l "$tmp/data/inbox/s1.key" 2>/dev/null) in -rw-------*) echo "ok   relay-created-0600" ;; *) echo "FAIL relay-created-0600"; failed=1 ;; esac
hasnt relay-created-quiet "$(cat "$tmp/err")" "$made"
out=$(step report_step '{"session_id":"x","task":"t"}')
expect relay-kept "$(cat "$tmp/data/inbox/s1.key")" "$made"
has relay-kept-in-call "$out" '"relay_key":"'"$made"'"'
# Several report_step at once with no key file: the first writer wins, and every call carries the key the file
# keeps (else the server could store a key the listener does not hold).
rm -f "$tmp/data/inbox/s1.key"
for i in 1 2 3 4 5 6 7 8; do step report_step '{"session_id":"x","task":"t"}' >"$tmp/race.$i" 2>/dev/null & done
wait
kept=$(cat "$tmp/data/inbox/s1.key" 2>/dev/null)
race=ok
for i in 1 2 3 4 5 6 7 8; do case $(cat "$tmp/race.$i") in *'"relay_key":"'"$kept"'"'*) ;; *) race=bad ;; esac; done
expect relay-race-one-key "$race" ok
# An agent's call never carries the working folder (cwd): stripped with or without session_id.
# raw <tool> <tool_input>
raw() {
  printf '{"session_id":"s1","cwd":"%s","agent_type":"","tool_name":"mcp__plugin_ergana_ergana__%s","tool_input":%s}' \
    "$repo" "$1" "$2" | sh "$script"
}
expect cwd-stripped-with-session "$(CLAUDE_PLUGIN_DATA= raw report_step '{"session_id":"x","cwd":"/Users/a/r","task":"x"}')" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"session_id":"s1","task":"x"}}}'
expect cwd-stripped-no-session "$(raw find_decisions '{"repository":"r","cwd":"/Users/a/r"}')" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"repository":"r"}}}'
expect no-cwd-untouched "$(raw find_decisions '{"repository":"r"}')" ''
exit $failed
