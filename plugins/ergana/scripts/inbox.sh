#!/bin/sh
# Stop (async, asyncRewake): the session's listener. While the session is idle, it holds Ergana's
# GET /v1/relay/listen with the session's relay key (inbox/<session>.key, made by relay-key.sh).
# When another agent writes to the session's person, Ergana answers 200 with a fixed signal: it is
# printed on stderr and the script exits 2, which wakes Claude with it, so it calls get_messages.
# Any other end exits 0, which wakes nothing.
#   204  nothing in 240 s: call again after a pause     401/410/400  stop (unknown key, ended, bad call)
#   503, a network error: back off 5 s, doubling to 5 min
# One listener per session: inbox/<session>.pid; a live one makes a new start exit 0 at once. The
# key goes to curl in a 0600 header file (-H @file), never on its command line, and is never
# printed. No jq: the hook input is matched as text.
# The base URL is fixed (the MCP server's origin); ERGANA_ORIGIN overrides it only with
# ERGANA_AUTH_TEST=1, as in ergana-auth.py, and a test never reaches production: with ERGANA_AUTH_TEST=1
# and no ERGANA_ORIGIN, or one on app.ergana.ai, the listener exits at once. ERGANA_INBOX_PAUSE and ERGANA_INBOX_BACKOFF (seconds)
# are for the tests.
input=$(cat)
session=$(printf '%s' "$input" | sed -n 's/.*[{,]"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,128\}\)".*/\1/p' | head -n 1)
[ -n "$session" ] && [ -n "${CLAUDE_PLUGIN_DATA:-}" ] || exit 0
dir=$CLAUDE_PLUGIN_DATA/inbox
key=$(cat "$dir/$session.key" 2>/dev/null)
printf '%s' "$key" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$' || exit 0
base=https://app.ergana.ai
. "$(cd "$(dirname "$0")" && pwd)/ergana-repo.sh"
if test_off_prod; then
  echo "Ergana › test mode: never production, ERGANA_ORIGIN must name a test server" >&2
  exit 0
fi
[ "${ERGANA_AUTH_TEST:-}" = 1 ] && base=${ERGANA_ORIGIN%/}
pause=${ERGANA_INBOX_PAUSE:-2}
backoff=${ERGANA_INBOX_BACKOFF:-5}
cap=300

pidfile=$dir/$session.pid
old=$(cat "$pidfile" 2>/dev/null)
case $old in
  '' | *[!0-9]*) ;;
  *) kill -0 "$old" 2>/dev/null && exit 0 ;;
esac
umask 077
rm -f "$pidfile"
# noclobber: of two starts racing, one creates the file and the other exits.
(set -C; printf '%s\n' "$$" >"$pidfile") 2>/dev/null || exit 0

hdr=$dir/$session.hdr
body=$dir/$session.body
cpid=
cleanup() {
  [ -z "$cpid" ] || kill "$cpid" 2>/dev/null
  rm -f "$hdr" "$body"
  [ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
printf 'Authorization: Bearer %s\n' "$key" >"$hdr" || exit 0
chmod 600 "$hdr" 2>/dev/null
key=

# A sleep that a signal can interrupt.
nap() { sleep "$1" & cpid=$!; wait "$cpid"; cpid=; }

while :; do
  rm -f "$body"
  # A little over the server's 240 s hold.
  curl -sS -o "$body" -w '%{http_code}' --max-time 260 -H @"$hdr" "$base/v1/relay/listen" >"$body.code" 2>/dev/null &
  cpid=$!
  wait "$cpid"
  rc=$?
  cpid=
  code=$(cat "$body.code" 2>/dev/null)
  rm -f "$body.code"
  [ "$rc" -eq 0 ] || code=000
  case $code in
    200)
      # Ergana's fixed signal, capped.
      head -c 2000 "$body" >&2
      printf '\n' >&2
      exit 2 ;;
    204) backoff=${ERGANA_INBOX_BACKOFF:-5}; nap "$pause" ;;
    401 | 410 | 400) exit 0 ;;
    *)
      nap "$backoff"
      backoff=$((backoff * 2))
      [ "$backoff" -le "$cap" ] || backoff=$cap ;;
  esac
done
