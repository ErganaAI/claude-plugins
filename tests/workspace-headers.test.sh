#!/bin/sh
# plugins/ergana/scripts/workspace-headers.sh on throwaway repositories:
#   sh tests/workspace-headers.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
helper="$here/plugins/ergana/scripts/workspace-headers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
# The helper reads ~/.config/ergana (the index, the stored tokens): a throwaway HOME, no real Keychain.
export HOME="$tmp/home" ERGANA_AUTH_TEST=1 ERGANA_AUTH_KEYCHAIN=0 GIT_CONFIG_GLOBAL=/dev/null
unset ERGANA_ORIGIN
mkdir "$HOME"

# expect <name> <got> <want>
expect() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, want $3"; failed=1; fi
}

# rooted <repository folder> <json> [folder name]: the json with the root's hash and the folder's name added, as the
# helper sends them (the name of the repository folder unless given).
rooted() {
  top=$(git -C "$1" rev-parse --show-toplevel)
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(printf '%s' "$top" | sha256sum | cut -c1-64)
  else
    h=$(printf '%s' "$top" | shasum -a 256 | cut -c1-64)
  fi
  printf '%s,"X-Ergana-Root-Hash":"%s","X-Ergana-Folder":"%s"}' "${2%\}}" "$h" "${3:-${1##*/}}"
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
expect subfolder "$sub" "$(rooted "$tmp/https-plain" '{"X-Ergana-Repo":"https://github.com/acme/web.git","X-Ergana-Branch":"main"}' admin)"
case "$sub" in *"$tmp"*) expect no-local-path leaked none ;; *) expect no-local-path none none ;; esac

# A folder outside git sends only its name; an unexpanded ${CLAUDE_PROJECT_DIR} falls back to the
# variable, then to the working folder.
mkdir "$tmp/plain"
expect not-git "$("$helper" "$tmp/plain")" '{"X-Ergana-Folder":"plain"}'
expect unexpanded "$(cd "$tmp/plain" && CLAUDE_PROJECT_DIR='' "$helper" '${CLAUDE_PROJECT_DIR}')" '{"X-Ergana-Folder":"plain"}'

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
# Tokens (DR-0035.D1, DR-0051.D1): a stored token is sent as Authorization; without one, ergana-not-connected,
# never the shared sign-in. A committed .ergana applies like a local one, with no confirmation.
cfg="$HOME/.config/ergana"
putsecret() { # <slug>: a valid token TOK-<slug> for the production host, listed in the index
  mkdir -p "$cfg/app.ergana.ai"
  printf '{"access":"TOK-%s","refresh":"r","expires_at":%s,"origin":"https://app.ergana.ai"}' "$1" "$(( $(date +%s) + 3600 ))" \
    >"$cfg/app.ergana.ai/$1"
  printf 'app.ergana.ai %s\n' "$1" >>"$cfg/workspaces"
}
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mk "$tmp/tok"
printf 'workspace = acme\n' >"$tmp/tok/.ergana"
out=$("$helper" "$tmp/tok")
has no-token "$out" '"Authorization":"Bearer ergana-not-connected"'
has no-token "$out" '"X-Ergana-Workspace":"acme"'
hasnt no-token "$out" 'TOK-'
putsecret acme
out=$("$helper" "$tmp/tok")
has token "$out" '"Authorization":"Bearer TOK-acme"'
has token "$out" '"X-Ergana-Workspace":"acme"'
has token "$out" '"Accept-Language":'
hasnt token "$out" 'not-connected'
valid token "$out"
mk "$tmp/tok-none"
hasnt no-ergana-with-tokens "$("$helper" "$tmp/tok-none")" 'Authorization'

# 2+ workspaces: an untracked or a committed .ergana is sent with its workspace's token, no confirmation.
putsecret second
has two-untracked "$("$helper" "$tmp/tok")" '"Authorization":"Bearer TOK-acme"'
comtok() { # <name> <json>: the acme token and the four repository headers
  has "$1" "$2" '"Authorization":"Bearer TOK-acme"'
  for hd in X-Ergana-Repo X-Ergana-Branch X-Ergana-Root-Hash X-Ergana-Folder; do has "$1 $hd" "$2" "$hd"; done
}
mk "$tmp/com"
git -C "$tmp/com" remote add origin https://github.com/acme/web.git
printf 'workspace = acme\n' >"$tmp/com/.ergana"
git -C "$tmp/com" add .ergana
git -C "$tmp/com" commit -q -m ergana
comtok two-committed "$("$helper" "$tmp/com")"
printf '# changed\n' >>"$tmp/com/.ergana"
git -C "$tmp/com" commit -q -am changed
comtok two-committed-modified "$("$helper" "$tmp/com")"
# a linked worktree of that repository
(cd "$tmp/com" && git worktree add -q "$tmp/comwt" -b comwt)
comtok two-committed-worktree "$("$helper" "$tmp/comwt")"
# committed, then dropped from the index only: still HEAD's
mk "$tmp/com-rm"
git -C "$tmp/com-rm" remote add origin https://github.com/acme/web.git
printf 'workspace = acme\n' >"$tmp/com-rm/.ergana"
git -C "$tmp/com-rm" add .ergana
git -C "$tmp/com-rm" commit -q -m ergana
git -C "$tmp/com-rm" rm -q --cached .ergana
comtok two-in-head-not-index "$("$helper" "$tmp/com-rm")"
# a dangling .ergana symlink names no workspace
mk "$tmp/dangling"
ln -s "$tmp/nowhere" "$tmp/dangling/.ergana"
out=$("$helper" "$tmp/dangling")
has dangling-symlink "$out" '"Authorization":"Bearer ergana-not-connected"'
hasnt dangling-symlink "$out" 'X-Ergana-Workspace'
# a committed .ergana with one workspace on the machine needs no confirmation
mkdir -p "$tmp/home1/.config/ergana"
cp -R "$cfg/app.ergana.ai" "$tmp/home1/.config/ergana/"
printf 'app.ergana.ai acme\n' >"$tmp/home1/.config/ergana/workspaces"
mk "$tmp/com1"
printf 'workspace = acme\n' >"$tmp/com1/.ergana"
git -C "$tmp/com1" add .ergana
git -C "$tmp/com1" commit -q -m ergana
has one-committed "$(HOME="$tmp/home1" "$helper" "$tmp/com1")" '"Authorization":"Bearer TOK-acme"'

# A slow git (every call hangs): the whole helper still answers in under 8 s, with the token.
mkdir -p "$tmp/slow/bin" "$tmp/home3/.config/ergana"
printf '#!/bin/sh\nexec sleep 3\n' >"$tmp/slow/bin/git"
chmod +x "$tmp/slow/bin/git"
printf 'workspace = acme\n' >"$tmp/slow/.ergana"
cp -R "$cfg/app.ergana.ai" "$tmp/home3/.config/ergana/"
printf 'app.ergana.ai acme\n' >"$tmp/home3/.config/ergana/workspaces"
t0=$(date +%s)
out=$(PATH="$tmp/slow/bin:$PATH" HOME="$tmp/home3" "$helper" "$tmp/slow")
t1=$(date +%s)
if [ $((t1 - t0)) -lt 8 ]; then echo "ok   slow-git in $((t1 - t0)) s"; else echo "FAIL slow-git: $((t1 - t0)) s"; failed=1; fi
has slow-git "$out" '"Authorization":"Bearer TOK-acme"'
valid slow-git "$out"

# X-Ergana-Folder: the project folder's name, percent-encoded byte by byte; none for a home folder
# or a root; none without a token within the budget (DR-0039.D1).
mk "$tmp/mono"
has folder "$("$helper" "$tmp/mono")" '"X-Ergana-Folder":"mono"'
mk "$tmp/données-clients"
has folder-encoded "$("$helper" "$tmp/données-clients")" '"X-Ergana-Folder":"donn%C3%A9es-clients"'
mk "$tmp/home/john"
hasnt folder-user-home "$("$helper" "$tmp/home/john")" 'X-Ergana-Folder'
mkdir -p "$tmp/Users"
mk "$tmp/Users/john"
hasnt folder-users "$("$helper" "$tmp/Users/john")" 'X-Ergana-Folder'
mk "$HOME"
hasnt folder-home "$("$helper" "$HOME")" 'X-Ergana-Folder'
hasnt folder-root "$("$helper" /)" 'X-Ergana-Folder'
# a committed .ergana: the folder goes with the token
has folder-committed "$("$helper" "$tmp/comwt")" '"X-Ergana-Folder":"comwt"'
# no token within the budget: no repository headers. A date that jumps 100 s after the helper's start leaves
# nothing of its 8 s
mk "$tmp/slowcom"
printf 'workspace = acme\n' >"$tmp/slowcom/.ergana"
(cd "$tmp/slowcom" && git add .ergana && git commit -q -m ergana)
mkdir -p "$tmp/clock"
printf '#!/bin/sh\nif [ -e "%s/seen" ]; then echo 1100; else : >"%s/seen"; echo 1000; fi\n' "$tmp/clock" "$tmp/clock" >"$tmp/clock/date"
chmod +x "$tmp/clock/date"
slowrun=$(PATH="$tmp/clock:$PATH" HOME="$tmp/home3" "$helper" "$tmp/slowcom")
for hd in X-Ergana-Repo X-Ergana-Branch X-Ergana-Root-Hash X-Ergana-Folder; do hasnt "folder-budget-spent $hd" "$slowrun" "$hd"; done
has folder-budget-spent "$slowrun" 'ergana-not-connected'
# the same repository on the real clock sends the folder with the token
has folder-budget-left "$(HOME="$tmp/home3" "$helper" "$tmp/slowcom")" '"X-Ergana-Folder":"slowcom"'

# DR-0039.D1: the repository's headers go only with a workspace token, or with no .ergana.
mko() { mk "$1" && git -C "$1" remote add origin https://github.com/acme/web.git; }
gitless() { # <name> <json>: the token and the folder, none of what git supplies
  for hd in X-Ergana-Repo X-Ergana-Branch X-Ergana-Root-Hash; do hasnt "$1 $hd" "$2" "$hd"; done
  has "$1 folder" "$2" X-Ergana-Folder
  has "$1" "$2" '"Authorization":"Bearer TOK-acme"'
  valid "$1" "$2"
}
norepo() { # <name> <json>: no repository header, the not-connected bearer
  for hd in X-Ergana-Repo X-Ergana-Branch X-Ergana-Root-Hash X-Ergana-Folder; do hasnt "$1 $hd" "$2" "$hd"; done
  has "$1 bearer" "$2" '"Authorization":"Bearer ergana-not-connected"'
  hasnt "$1 token" "$2" 'TOK-'
  valid "$1" "$2"
}
# two workspaces are connected here, none of them acme: a committed .ergana naming acme has no token
mkdir -p "$tmp/home4/.config/ergana"
cp -R "$cfg/app.ergana.ai" "$tmp/home4/.config/ergana/"
rm "$tmp/home4/.config/ergana/app.ergana.ai/acme"
printf 'app.ergana.ai second\napp.ergana.ai third\n' >"$tmp/home4/.config/ergana/workspaces"
mko "$tmp/r-unc"
printf 'workspace = acme\n' >"$tmp/r-unc/.ergana"
git -C "$tmp/r-unc" add .ergana
git -C "$tmp/r-unc" commit -q -m ergana
out=$(HOME="$tmp/home4" "$helper" "$tmp/r-unc")
norepo no-token-committed "$out"
has no-token-committed "$out" '"X-Ergana-Workspace":"acme"'
has no-token-committed "$out" '"Accept-Language":'
mko "$tmp/r-notok"
printf 'workspace = nobody\n' >"$tmp/r-notok/.ergana"
norepo no-token-no-repo "$("$helper" "$tmp/r-notok")"
mko "$tmp/r-bad"
printf 'workspace = Bad\n' >"$tmp/r-bad/.ergana"
out=$("$helper" "$tmp/r-bad")
norepo malformed-no-repo "$out"
hasnt malformed-no-repo "$out" 'X-Ergana-Workspace'
mko "$tmp/r-budget"
printf 'workspace = acme\n' >"$tmp/r-budget/.ergana"
git -C "$tmp/r-budget" add .ergana
git -C "$tmp/r-budget" commit -q -m ergana
rm -f "$tmp/clock/seen"
norepo budget-no-repo "$(PATH="$tmp/clock:$PATH" "$helper" "$tmp/r-budget")"
# git cut off or refused: the .ergana still applies with its token (DR-0051.D1); git supplies no repo, branch or hash
mko "$tmp/r-slow"
printf 'workspace = acme\n' >"$tmp/r-slow/.ergana"
gitless unknown-token "$(PATH="$tmp/slow/bin:$PATH" "$helper" "$tmp/r-slow")"
mkdir -p "$tmp/refuse"
printf '#!/bin/sh\nexit 128\n' >"$tmp/refuse/git"
chmod +x "$tmp/refuse/git"
mko "$tmp/r-ref"
printf 'workspace = acme\n' >"$tmp/r-ref/.ergana"
gitless git-refused-root-token "$(PATH="$tmp/refuse:$PATH" "$helper" "$tmp/r-ref")"
mkdir -p "$tmp/r-ref/apps/web"
printf 'workspace = acme\n' >"$tmp/r-ref/apps/web/.ergana"
gitless git-refused-subfolder-token "$(PATH="$tmp/refuse:$PATH" "$helper" "$tmp/r-ref/apps/web")"
# a token: all four headers; no .ergana: repo, branch, hash
mko "$tmp/r-ok"
printf 'workspace = acme\n' >"$tmp/r-ok/.ergana"
out=$("$helper" "$tmp/r-ok")
for hd in X-Ergana-Repo X-Ergana-Branch X-Ergana-Root-Hash X-Ergana-Folder; do has "token-repo $hd" "$out" "$hd"; done
has token-repo "$out" '"Authorization":"Bearer TOK-acme"'
mko "$tmp/r-none"
out=$("$helper" "$tmp/r-none")
for hd in X-Ergana-Repo X-Ergana-Branch X-Ergana-Root-Hash; do has "no-ergana-repo $hd" "$out" "$hd"; done
exit $failed
