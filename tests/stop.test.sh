#!/bin/sh
# plugins/ergana/scripts/stop.sh against real git repositories:
#   sh tests/stop.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/plugins/ergana/scripts/stop.sh"
fp="$here/plugins/ergana/scripts/fingerprint.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CLAUDE_PLUGIN_DATA="$tmp/data"
repo="$tmp/repo"
git init -q "$repo" && git -C "$repo" commit -q --allow-empty -m init && echo a >"$repo/f"
mkdir "$tmp/plain" "$tmp/empty" && git init -q "$tmp/empty"

# run <cwd> <stop_hook_active> [background task JSON]: prints the hook's output
run() {
  printf '{"session_id":"s1","cwd":"%s","stop_hook_active":%s,"background_tasks":[%s]}' "$1" "$2" "${3:-}" |
    LANG="${LANG_FOR_TEST:-en_US.UTF-8}" sh "$script"
}
# expect <name> <got> <want>
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; failed=1; fi; }
en='{"decision":"block","reason":"Ergana › Checking the change before finishing."}'
fr='{"decision":"block","reason":"Ergana › Vérification du changement avant de terminer."}'
reset() { rm -rf "$tmp/data"; mkdir -p "$tmp/data/start" "$tmp/data/cleared" "$tmp/data/refused"; }

reset
"$fp" "$repo" >"$tmp/data/start/s1"
expect unchanged "$(run "$repo" false)" ""
echo b >"$repo/g"
expect changed-en "$(run "$repo" false)" "$en"
expect changed-fr "$(LANG_FOR_TEST=fr_FR.UTF-8 run "$repo" false)" "$fr"
if run "$repo" false | python3 -c 'import json,sys; json.load(sys.stdin)'; then echo "ok   valid-json"; else echo "FAIL valid-json"; failed=1; fi
# a continued stop on the refused fingerprint passes; a newer one is refused again
expect continued-same "$(run "$repo" true)" ""
echo c >"$repo/h"
expect continued-newer "$(run "$repo" true)" "$en"
expect continued-newer-then-same "$(run "$repo" true)" ""
# a stop that is not a continuation is refused again, even on the refused fingerprint
expect not-continued "$(run "$repo" false)" "$en"
# a cleared fingerprint passes
"$fp" "$repo" >"$tmp/data/cleared/s1"
expect cleared "$(run "$repo" false)" ""
# a running check agent
reset
expect check-agent "$(run "$repo" false '{"agent_type":"ergana:check"}')" ""
# outside a checkout, and a checkout with no commit
expect no-checkout "$(run "$tmp/plain" false)" ""
echo x >"$tmp/empty/f"
expect no-commit "$(run "$tmp/empty" false)" ""
# a fingerprint that fails inside a checkout: block (fail closed)
fake="$tmp/fake/plugins/ergana/scripts"
mkdir -p "$fake"
cp "$script" "$fake/stop.sh"
printf '#!/bin/sh\nexit 1\n' >"$fake/fingerprint.sh"
chmod +x "$fake"/*.sh
got=$(printf '{"session_id":"s1","cwd":"%s","stop_hook_active":false}' "$repo" | LANG=en_US.UTF-8 sh "$fake/stop.sh")
expect fingerprint-fails "$got" "$en"
# no data folder it can write: never refused, so never refused forever (review R5)
got=$(printf '{"session_id":"s1","cwd":"%s","stop_hook_active":true}' "$repo" | CLAUDE_PLUGIN_DATA= LANG=en_US.UTF-8 sh "$script")
expect no-data-folder "$got" ""
touch "$tmp/notadir"
got=$(printf '{"session_id":"s1","cwd":"%s","stop_hook_active":false}' "$repo" | CLAUDE_PLUGIN_DATA="$tmp/notadir" LANG=en_US.UTF-8 sh "$script")
expect unwritable-data-folder "$got" ""
exit $failed
