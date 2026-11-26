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
  for tool in sed head cat rm mktemp sleep kill grep git cut tr dirname sha256sum shasum perl date wc; do
    t=$(command -v "$tool") && ln -s "$t" "$bin/$tool"
  done
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
# The workspace of the repository (DR-0029.D1, DR-0037.D1) and the login proposal (DR-0036.D1).
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
idx="$HOME/.config/ergana/workspaces"
mkdir -p "$HOME/.config/ergana"
wsbin="$tmp/wsbin"
mkdir "$wsbin"
for tool in sed head cat rm mktemp sleep kill grep git cut tr dirname sha256sum shasum perl date wc tail; do
  t=$(command -v "$tool") && ln -s "$t" "$wsbin/$tool"
done

# ctx <repo> <LANG>: the hook's output for a session in that folder
ctx() { printf '{"session_id":"abc-1","cwd":"%s"}' "$1" | LANG=$2 PATH="$wsbin" /bin/sh "$script"; }
has() { case "$2" in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: lacks $3"; failed=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL $1: holds $3"; failed=1 ;; *) echo "ok   $1" ;; esac; }
# mkrepo <name> <yes: .ergana committed | no: .ergana untracked | none>
mkrepo() {
  r="$tmp/$1"
  git init -q -b main "$r"
  if [ "$2" != none ]; then printf 'workspace = acme\n' >"$r/.ergana"; fi
  if [ "$2" = yes ]; then git -C "$r" add .ergana; fi
  git -C "$r" commit -q --allow-empty -m init
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
trustline() { # <repo>: "<sha256 of the git common dir> <sha256 of its .ergana>"
  c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)
  if command -v sha256sum >/dev/null 2>&1; then k=$(printf '%s' "$c" | sha256sum | cut -c1-64); else k=$(printf '%s' "$c" | shasum -a 256 | cut -c1-64); fi
  printf '%s %s\n' "$k" "$(sha "$1/.ergana")"
}
gitpath() { git -C "$1" rev-parse --path-format=absolute --git-path "$2"; }

printf 'app.ergana.ai acme\n' >"$idx"
mkrepo local no
has local-fr "$(ctx "$tmp/local" fr_FR.UTF-8)" 'Espace Ergana : acme (fichier .ergana local)'
has local-en "$(ctx "$tmp/local" en_US.UTF-8)" 'Ergana workspace: acme (local .ergana file)'
mkrepo committed yes
has committed-fr "$(ctx "$tmp/committed" fr_FR.UTF-8)" 'Espace Ergana : acme (fichier .ergana committé)'
has committed-en "$(ctx "$tmp/committed" C)" 'Ergana workspace: acme (committed .ergana file)'
out=$(ctx "$tmp/committed" fr_FR.UTF-8)
hasnt one-space-no-confirmation "$out" "Envoyer ce dépôt"
hasnt connected-no-proposal "$out" '/ergana:login'
mkrepo none none
out=$(ctx "$tmp/none" fr_FR.UTF-8)
hasnt no-ergana-no-workspace-line "$out" 'Espace Ergana'
last=$(printf '%s\n' "$out" | tail -n 1)
if [ "$last" = 'GitHub: gh=missing' ]; then echo "ok   github-line-last"; else echo "FAIL github-line-last: $last"; failed=1; fi

# DR-0037.D1: 2+ workspaces and a committed .ergana: the exact question, until the answer is recorded.
printf 'app.ergana.ai acme\napp.ergana.ai other\n' >"$idx"
out=$(ctx "$tmp/committed" fr_FR.UTF-8)
has confirm-fr "$out" "Envoyer ce dépôt à l'espace acme ?"
has confirm-fr-tool "$out" 'AskUserQuestion'
has confirm-fr-mcp "$out" '/mcp'
has confirm-fr-labels "$out" 'Oui'
out=$(ctx "$tmp/committed" en_US.UTF-8)
has confirm-en "$out" 'Send this repository to the acme workspace?'
has confirm-en-labels "$out" 'Yes'
hasnt confirm-local "$(ctx "$tmp/local" fr_FR.UTF-8)" 'Envoyer ce dépôt'
# the old in-repository record is not a confirmation any more
mkdir -p "$(gitpath "$tmp/committed" info)"
sha "$tmp/committed/.ergana" >"$(gitpath "$tmp/committed" info/ergana-trusted)"
has confirm-old-record "$(ctx "$tmp/committed" fr_FR.UTF-8)" "Envoyer ce dépôt à l'espace acme ?"
trustline "$tmp/committed" >"$HOME/.config/ergana/trusted"
hasnt confirmed "$(ctx "$tmp/committed" fr_FR.UTF-8)" 'Envoyer ce dépôt'
printf '# edit\n' >>"$tmp/committed/.ergana"
has confirm-after-edit "$(ctx "$tmp/committed" fr_FR.UTF-8)" "Envoyer ce dépôt à l'espace acme ?"

# DR-0036.D1: /ergana:login is offered for a .ergana without token, or with no .ergana when the machine holds
# a token, unless "Plus tard" was chosen for this repository.
rm -f "$idx"
mkrepo notoken no
out=$(ctx "$tmp/notoken" fr_FR.UTF-8)
has offer-ergana-no-token "$out" '/ergana:login'
has offer-ergana-no-token-later "$out" 'Plus tard'
has offer-ergana-no-token-slug "$out" 'acme'
printf 'app.ergana.ai other\n' >"$idx"
has offer-ergana-other-token "$(ctx "$tmp/notoken" fr_FR.UTF-8)" '/ergana:login'
mkrepo bare none
out=$(ctx "$tmp/bare" fr_FR.UTF-8)
has offer-bare "$out" '/ergana:login'
has offer-bare-space "$out" 'other'
has offer-bare-autre "$out" 'Autre'
has offer-bare-later "$out" 'Plus tard'
has offer-bare-marker "$out" 'ergana-auth.py" later'
has offer-bare-en "$(ctx "$tmp/bare" en_US.UTF-8)" 'Later'
rm -f "$idx"
hasnt bare-no-token-no-offer "$(ctx "$tmp/bare" fr_FR.UTF-8)" '/ergana:login'
printf 'app.ergana.ai other\n' >"$idx"
for n in bare notoken; do
  mkdir -p "$(dirname "$(gitpath "$tmp/$n" info/ergana-later)")"
  : >"$(gitpath "$tmp/$n" info/ergana-later)"
done
hasnt later-bare "$(ctx "$tmp/bare" fr_FR.UTF-8)" '/ergana:login'
hasnt later-ergana "$(ctx "$tmp/notoken" fr_FR.UTF-8)" '/ergana:login'
has later-still-names-workspace "$(ctx "$tmp/notoken" fr_FR.UTF-8)" 'Espace Ergana : acme'

# The relay key (inbox/<session>.key): 43 base64url characters, mode 0600, made once and kept, one per
# session, and the output never shows it. The full PATH: the key needs base64 and od-free tools.
kd="$tmp/keydata"
keyrun() { printf '{"session_id":"%s"}' "$1" | CLAUDE_PLUGIN_DATA="$kd" /bin/sh "$script"; }
kout=$(keyrun abc-1)
k1=$(cat "$kd/inbox/abc-1.key" 2>/dev/null)
if printf '%s' "$k1" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$'; then echo "ok   key-43-base64url"; else echo "FAIL key-43-base64url: '$k1'"; failed=1; fi
mode=$(ls -l "$kd/inbox/abc-1.key" | cut -c1-10)
if [ "$mode" = '-rw-------' ]; then echo "ok   key-mode-0600"; else echo "FAIL key-mode-0600: $mode"; failed=1; fi
keyrun abc-1 >/dev/null
if [ "$(cat "$kd/inbox/abc-1.key")" = "$k1" ]; then echo "ok   key-stable"; else echo "FAIL key-stable"; failed=1; fi
keyrun abc-2 >/dev/null
if [ -s "$kd/inbox/abc-2.key" ] && [ "$(cat "$kd/inbox/abc-2.key")" != "$k1" ]; then echo "ok   key-per-session"; else echo "FAIL key-per-session"; failed=1; fi
hasnt key-not-printed "$kout" "$k1"
printf 'bad\n' >"$kd/inbox/abc-3.key"
keyrun abc-3 >/dev/null
if LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$' "$kd/inbox/abc-3.key"; then echo "ok   key-malformed-replaced"; else echo "FAIL key-malformed-replaced"; failed=1; fi
exit $failed
