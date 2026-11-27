#!/bin/sh
# plugins/ergana/scripts/inbox.sh, with a stub curl on PATH that records its arguments and answers
# the next status of a script (a line "<status> <body>" each call, the last one repeated):
#   sh tests/inbox.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/plugins/ergana/scripts/inbox.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
export CLAUDE_PLUGIN_DATA="$tmp/data" ERGANA_INBOX_PAUSE=0 ERGANA_INBOX_BACKOFF=0
dir="$tmp/data/inbox"
mkdir -p "$dir" "$tmp/bin"
KEY=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ
printf '%s\n' "$KEY" >"$dir/s1.key"

# The stub: argv to $STUB/argv (one call per line), the n-th line of $STUB/script answers call n.
cat >"$tmp/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB/argv"
n=$(wc -l <"$STUB/argv" | tr -d ' ')
line=$(sed -n "${n}p" "$STUB/script")
[ -n "$line" ] || line=$(tail -n 1 "$STUB/script")
code=${line%% *}
body=
case $line in *' '*) body=${line#* } ;; esac
out=
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; esac; shift; done
[ -z "$out" ] || printf '%s' "$body" >"$out"
[ "$code" = fail ] && exit 7
printf '%s' "$code"
STUB
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"

expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; failed=1; fi; }
# run <session> <script lines...>: runs the listener, sets $rc, $out (stdout), $err (stderr), $STUB
run() {
  s=$1; shift
  runs=$((${runs:-0} + 1)); STUB="$tmp/stub.$runs"; export STUB
  mkdir -p "$STUB"; : >"$STUB/argv"
  printf '%s\n' "$@" >"$STUB/script"
  out=$(printf '{"session_id":"%s"}' "$s" | sh "$script" 2>"$STUB/err"); rc=$?
  err=$(cat "$STUB/err")
}

run s1 '200 Ergana: a message is waiting. Call get_messages.'
expect 200-exit-2 "$rc" 2
expect 200-body-on-stderr "$err" 'Ergana: a message is waiting. Call get_messages.'
expect 200-stdout-empty "$out" ''
expect 200-pid-removed "$(ls "$dir" | grep -c pid)" 0
expect 200-header-removed "$(ls "$dir" | grep -c hdr)" 0
expect 200-one-call "$(wc -l <"$STUB/argv" | tr -d ' ')" 1
case $(cat "$STUB/argv") in *"https://app.ergana.ai/v1/relay/listen"*) echo "ok   url" ;; *) echo "FAIL url"; failed=1 ;; esac
case $(cat "$STUB/argv") in *"--max-time 260"*) echo "ok   max-time" ;; *) echo "FAIL max-time"; failed=1 ;; esac
case $(cat "$STUB/argv") in *"$KEY"*) echo "FAIL key-in-argv"; failed=1 ;; *) echo "ok   key-not-in-argv" ;; esac
case $(cat "$STUB/argv") in *" -H @"*"/s1.hdr "*) echo "ok   header-file" ;; *) echo "FAIL header-file: $(cat "$STUB/argv")"; failed=1 ;; esac
case $err$out in *"$KEY"*) echo "FAIL key-printed"; failed=1 ;; *) echo "ok   key-not-printed" ;; esac

# H2: a test never reaches production: ERGANA_AUTH_TEST=1 with no ERGANA_ORIGIN, or one on app.ergana.ai,
# exits at once without calling curl; a test origin is the one called.
for o in '' https://app.ergana.ai https://APP.ergana.ai:443/; do
  ERGANA_AUTH_TEST=1 ERGANA_ORIGIN=$o run s1 '200 x'
  expect "test-mode-no-prod-$o" "$rc:$(wc -l <"$STUB/argv" | tr -d ' ')" 0:0
done
ERGANA_AUTH_TEST=1 ERGANA_ORIGIN=https://ergana.test/ run s1 '200 x'
case $(cat "$STUB/argv") in *"https://ergana.test/v1/relay/listen"*) echo "ok   test-origin-url" ;; *) echo "FAIL test-origin-url"; failed=1 ;; esac

# The header file holds the key, mode 0600, while the listener runs: a stub that looks at it.
cp "$tmp/bin/curl" "$tmp/bin/curl.real"
cat >"$tmp/bin/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do case $a in @*) f=${a#@} ;; esac; done
printf '%s %s\n' "$(cat "$f")" "$(ls -l "$f" | cut -c1-10)" >"$STUB/hdr"
exec "$(dirname "$0")/curl.real" "$@"
STUB
run s1 '410'
expect header-content "$(cut -d' ' -f1-3 "$STUB/hdr")" "Authorization: Bearer $KEY"
expect header-mode "$(cut -d' ' -f4 "$STUB/hdr")" '-rw-------'
mv "$tmp/bin/curl.real" "$tmp/bin/curl"

run s1 '410'
expect 410-exit-0 "$rc" 0
expect 410-silent "$err" ''
expect 410-pid-removed "$(ls "$dir" | grep -c pid)" 0
run s1 '401'
expect 401-exit-0 "$rc" 0
run s1 '400'
expect 400-exit-0 "$rc" 0

run s1 '204' '204' '204' '200 wake'
expect 204-reconnects "$(wc -l <"$STUB/argv" | tr -d ' ')" 4
expect 204-then-200-exit-2 "$rc" 2
expect 204-then-200-body "$err" wake

run s1 '503' 'fail' '204' '200 later'
expect backoff-keeps-trying "$(wc -l <"$STUB/argv" | tr -d ' ')" 4
expect backoff-then-200 "$rc" 2

# No key file, a malformed one, no session: exits 0 at once without calling curl.
run nokey '200 x'
expect no-key-exit "$rc" 0
expect no-key-no-call "$(wc -l <"$STUB/argv" | tr -d ' ')" 0
printf 'short\n' >"$dir/bad.key"
run bad '200 x'
expect bad-key-no-call "$(wc -l <"$STUB/argv" | tr -d ' ')" 0
STUB="$tmp/none"; mkdir -p "$STUB"; : >"$STUB/argv"; : >"$STUB/script"; export STUB
printf '{}' | sh "$script" 2>/dev/null; expect no-session-exit "$?" 0

# The lock: a live listener makes a second start exit 0 at once, and its pid file stays.
sleep 30 & live=$!
printf '%s\n' "$live" >"$dir/s1.pid"
run s1 '200 x'
expect lock-second-exits-0 "$rc" 0
expect lock-no-call "$(wc -l <"$STUB/argv" | tr -d ' ')" 0
expect lock-pid-kept "$(cat "$dir/s1.pid")" "$live"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
# A stale pid file (no such process) is replaced.
printf '%s\n' "$live" >"$dir/s1.pid"
run s1 '200 x'
expect stale-pid-listens "$rc" 2

# A real second start while the first holds a request: the first is stuck in a slow curl.
cat >"$tmp/bin/curl" <<'STUB'
#!/bin/sh
printf 'x\n' >>"$STUB/argv"
sleep 30
STUB
STUB="$tmp/stub.lock"; export STUB; mkdir -p "$STUB"; : >"$STUB/argv"
printf '{"session_id":"s1"}' | sh "$script" 2>/dev/null & first=$!
i=0; while [ ! -s "$STUB/argv" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
printf '{"session_id":"s1"}' | sh "$script" 2>/dev/null; expect lock-live-second-exits-0 "$?" 0
expect lock-live-one-curl "$(wc -l <"$STUB/argv" | tr -d ' ')" 1
kill "$first" 2>/dev/null; wait "$first" 2>/dev/null
sleep 0.3
expect killed-pid-removed "$(ls "$dir" | grep -c 's1.pid')" 0
expect killed-header-removed "$(ls "$dir" | grep -c 's1.hdr')" 0
exit $failed
