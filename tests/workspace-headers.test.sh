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

# check <name> <origin, or - for none> <want>
check() {
  repo="$tmp/$1"
  git init -q -b main "$repo"
  [ "$2" = - ] || git --git-dir="$repo/.git" remote add origin "$2"
  expect "$1" "$("$helper" "$repo")" "$3"
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
expect detached "$("$helper" "$tmp/detached")" '{"X-Ergana-Repo":"git@github.com:acme/api.git"}'

# A folder outside git sends nothing; an unexpanded ${CLAUDE_PROJECT_DIR} falls back to the
# variable, then to the working folder.
mkdir "$tmp/plain"
expect not-git "$("$helper" "$tmp/plain")" '{}'
expect unexpanded "$(cd "$tmp/plain" && CLAUDE_PROJECT_DIR='' "$helper" '${CLAUDE_PROJECT_DIR}')" '{}'
exit $failed
