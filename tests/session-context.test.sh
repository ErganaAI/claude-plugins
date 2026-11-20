#!/bin/sh
# plugins/ergana/scripts/session-context.sh's GitHub line, with a stub gh on PATH:
#   sh tests/session-context.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/plugins/ergana/scripts/session-context.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

# check <name> <stub gh body, or - for no gh> <want>
check() {
  bin="$tmp/$1"
  mkdir "$bin"
  for tool in sed head cat rm mktemp sleep kill; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  [ "$2" = - ] || { printf '#!/bin/sh\n%s\n' "$2" >"$bin/gh"; chmod +x "$bin/gh"; }
  got=$(echo '{"session_id":"abc-1"}' | PATH="$bin" /bin/sh "$script" | tail -n 1)
  if [ "$got" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $got, want $3"; failed=1; fi
}

ok='{"hosts":{"github.com":[{"state":"success","active":true,"login":"octo","scopes":"repo, project, read:org"}]}}'
check ok "echo '$ok'" 'GitHub: gh=ok login=octo'
check no-project "echo '$(echo "$ok" | sed 's/ project,//')'" 'GitHub: gh=ok_no_project login=octo'
check no-scopes "echo '$(echo "$ok" | sed 's/"scopes":"[^"]*"/"scopes":""/')'" 'GitHub: gh=unknown login=octo'
check signed-out "echo '{\"hosts\":{}}'" 'GitHub: gh=signed_out'
check failing 'exit 1' 'GitHub: gh=unknown'
check slow 'sleep 5' 'GitHub: gh=unknown'
check missing - 'GitHub: gh=missing'
exit $failed
