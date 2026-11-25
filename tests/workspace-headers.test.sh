#!/bin/sh
# plugins/ergana/scripts/workspace-headers.sh on throwaway repositories:
#   sh tests/workspace-headers.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
helper="$here/plugins/ergana/scripts/workspace-headers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

# expect <name> <got> <want>
expect() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, want $3"; failed=1; fi
}

# rooted <repository folder> <json>: the json with the root's hash added, as the helper sends it.
rooted() {
  top=$(git -C "$1" rev-parse --show-toplevel)
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(printf '%s' "$top" | sha256sum | cut -c1-64)
  else
    h=$(printf '%s' "$top" | shasum -a 256 | cut -c1-64)
  fi
  printf '%s,"X-Ergana-Root-Hash":"%s"}' "${2%\}}" "$h"
}

# check <name> <origin, or - for none> <want, without the root's hash>
check() {
  repo="$tmp/$1"
  git init -q -b main "$repo"
  [ "$2" = - ] || git --git-dir="$repo/.git" remote add origin "$2"
  expect "$1" "$("$helper" "$repo")" "$(rooted "$repo" "$3")"
}

check https-token 'https://x-access-token:abc123@github.com/acme/web.git' \
  '{"X-Ergana-Repo":"https://github.com/acme/web.git","X-Ergana-Branch":"main"}'
check https-user 'https://someone@github.com/acme/web' \
  '{"X-Ergana-Repo":"https://github.com/acme/web","X-Ergana-Branch":"main"}'
check https-plain 'https://github.com/acme/web.git' \
  '{"X-Ergana-Repo":"https://github.com/acme/web.git","X-Ergana-Branch":"main"}'
check scp 'git@github.com:acme/api.git' \
  '{"X-Ergana-Repo":"git@github.com:acme/api.git","X-Ergana-Branch":"main"}'
check ssh-url 'ssh://git:secret@github.com:22/acme/api.git' \
  '{"X-Ergana-Repo":"ssh://github.com:22/acme/api.git","X-Ergana-Branch":"main"}'
check password-at 'https://user:p@ss@github.com/acme/web.git' \
  '{"X-Ergana-Repo":"https://github.com/acme/web.git","X-Ergana-Branch":"main"}'
check password-slash 'https://user:pa/ss@github.com/acme/web.git' '{"X-Ergana-Branch":"main"}'
check ssh-password-at 'ssh://git:a@b@github.com/acme/api.git' \
  '{"X-Ergana-Repo":"ssh://github.com/acme/api.git","X-Ergana-Branch":"main"}'
check file-path '/srv/git/web.git' '{"X-Ergana-Branch":"main"}'
check file-url 'file:///srv/git/web.git' '{"X-Ergana-Branch":"main"}'
check ext 'ext::sh -c touch% /tmp/pwned' '{"X-Ergana-Branch":"main"}'
check no-origin - '{"X-Ergana-Branch":"main"}'

# A detached HEAD sends no branch.
git init -q -b main "$tmp/detached"
git --git-dir="$tmp/detached/.git" remote add origin 'git@github.com:acme/api.git'
git --git-dir="$tmp/detached/.git" -c user.name=t -c user.email=t@t \
  commit-tree -m one "$(git --git-dir="$tmp/detached/.git" mktree </dev/null)" >"$tmp/sha"
git --git-dir="$tmp/detached/.git" update-ref --no-deref HEAD "$(cat "$tmp/sha")"
expect detached "$("$helper" "$tmp/detached")" \
  "$(rooted "$tmp/detached" '{"X-Ergana-Repo":"git@github.com:acme/api.git"}')"

# A subfolder of the checkout sends the root's hash, not the subfolder's; the hash is never the
# path itself.
mkdir -p "$tmp/https-plain/apps/admin"
sub=$("$helper" "$tmp/https-plain/apps/admin")
expect subfolder "$sub" "$(rooted "$tmp/https-plain" '{"X-Ergana-Repo":"https://github.com/acme/web.git","X-Ergana-Branch":"main"}')"
case "$sub" in *"$tmp"*) expect no-local-path leaked none ;; *) expect no-local-path none none ;; esac

# A folder outside git sends nothing; an unexpanded ${CLAUDE_PROJECT_DIR} falls back to the
# variable, then to the working folder.
mkdir "$tmp/plain"
expect not-git "$("$helper" "$tmp/plain")" '{}'
expect unexpanded "$(cd "$tmp/plain" && CLAUDE_PROJECT_DIR='' "$helper" '${CLAUDE_PROJECT_DIR}')" '{}'

# .ergana (DR-0035.D1): the workspace header, the language, and the refusal when the file is bad.
# has <name> <json> <fragment>, hasnt <name> <json> <fragment>; valid <name> <json>
has() { case "$2" in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: $2 lacks $3"; failed=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL $1: $2 holds $3"; failed=1 ;; *) echo "ok   $1" ;; esac; }
valid() {
  if printf '%s' "$2" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then echo "ok   $1 json"; else echo "FAIL $1: invalid json $2"; failed=1; fi
}
# A PATH with the tools the helper needs but no git.
nogit="$tmp/nogit"
mkdir "$nogit"
for t in sh sed grep head cut tr cat dirname basename sha256sum shasum perl; do
  p=$(command -v "$t") && [ -x "$p" ] && ln -s "$p" "$nogit/$t"
done

mk() { git init -q -b main "$1" && (cd "$1" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init); }

mk "$tmp/ws1"
printf 'workspace = john\n' >"$tmp/ws1/.ergana"
out=$("$helper" "$tmp/ws1")
has ergana-root "$out" '"X-Ergana-Workspace":"john"'
valid ergana-root "$out"

mk "$tmp/main2"
printf '# the workspace\n  workspace=john  \n' >"$tmp/main2/.ergana"
(cd "$tmp/main2" && git worktree add -q "$tmp/wt2" -b wt2)
out=$("$helper" "$tmp/wt2")
has linked-main "$out" '"X-Ergana-Workspace":"john"'
valid linked-main "$out"
out=$(PATH="$nogit" "$helper" "$tmp/wt2")
has linked-main-no-git "$out" '"X-Ergana-Workspace":"john"'
valid linked-main-no-git "$out"

printf 'workspace = other\n' >"$tmp/wt2/.ergana"
out=$("$helper" "$tmp/wt2")
has linked-own "$out" '"X-Ergana-Workspace":"other"'
hasnt linked-own "$out" '"john"'

for bad in 'Ergana' 'a/b' 'x"y' 'ab' ''; do
  printf 'workspace = %s\n' "$bad" >"$tmp/ws1/.ergana"
  out=$("$helper" "$tmp/ws1")
  hasnt "malformed[$bad]" "$out" 'X-Ergana-Workspace'
  has "malformed[$bad]" "$out" '"Authorization":"Bearer ergana-not-connected"'
  valid "malformed[$bad]" "$out"
done
printf 'nothing here\n' >"$tmp/ws1/.ergana"
out=$("$helper" "$tmp/ws1")
has no-line "$out" '"Authorization":"Bearer ergana-not-connected"'

out=$("$helper" "$tmp/https-plain")
hasnt no-ergana "$out" 'Ergana-Workspace'
hasnt no-ergana "$out" 'Authorization'
hasnt no-ergana "$out" 'Accept-Language'

mkdir "$tmp/plainws"
printf 'workspace = john\n' >"$tmp/plainws/.ergana"
out=$(PATH="$nogit" "$helper" "$tmp/plainws")
has no-git-root "$out" '"X-Ergana-Workspace":"john"'
valid no-git-root "$out"

printf 'workspace = john\n' >"$tmp/ws1/.ergana"
for l in fr_FR.UTF-8:fr en_US.UTF-8:en :en 'x"y:en'; do
  out=$(LANG=${l%:*} "$helper" "$tmp/ws1")
  has "lang[${l%:*}]" "$out" "\"Accept-Language\":\"${l##*:}\""
  valid "lang[${l%:*}]" "$out"
done
exit $failed
