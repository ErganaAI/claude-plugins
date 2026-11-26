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

# DR-0051.D1: 2+ workspaces and a committed .ergana: the workspace line, no confirmation question.
printf 'app.ergana.ai acme\napp.ergana.ai other\n' >"$idx"
out=$(ctx "$tmp/committed" fr_FR.UTF-8)
has two-committed-fr "$out" 'Espace Ergana : acme (fichier .ergana committé)'
hasnt two-committed-fr-no-question "$out" 'Envoyer ce dépôt'
out=$(ctx "$tmp/committed" en_US.UTF-8)
has two-committed-en "$out" 'Ergana workspace: acme (committed .ergana file)'
hasnt two-committed-en-no-question "$out" 'Send this repository'
# no token for the slug: the sign-in offer
printf 'app.ergana.ai other\napp.ergana.ai third\n' >"$idx"
out=$(ctx "$tmp/committed" en_US.UTF-8)
has two-committed-no-token-offer "$out" 'has no sign-in on this machine'
hasnt two-committed-no-token-no-question "$out" 'Send this repository'

# DR-0036.D1 / DR-0041.D1: /ergana:login is offered for a .ergana without token, or with no .ergana in a git repository, unless "Plus tard" was chosen for this repository.
rm -f "$idx"
mkrepo notoken no
out=$(ctx "$tmp/notoken" fr_FR.UTF-8)
has offer-ergana-no-token "$out" '/ergana:login'
has offer-ergana-no-token-later "$out" 'Plus tard'
has offer-ergana-no-token-slug "$out" 'acme'
printf 'app.ergana.ai other\n' >"$idx"
has offer-ergana-other-token "$(ctx "$tmp/notoken" fr_FR.UTF-8)" '/ergana:login'
mkrepo bare none
rm -f "$idx"
out=$(ctx "$tmp/bare" fr_FR.UTF-8)
has offer-bare-empty "$out" 'Se connecter à Ergana ?'
has offer-bare-empty-go "$out" '"Se connecter" first'
has offer-bare-empty-later "$out" '"Plus tard" second'
has offer-bare-empty-login "$out" '/ergana:login skill with no argument'
has offer-bare-marker "$out" 'ergana-auth.py" later'
out=$(ctx "$tmp/bare" en_US.UTF-8)
has offer-bare-en "$out" 'Sign in to Ergana?'
has offer-bare-en-go "$out" '"Sign in" first'
has offer-bare-en-later "$out" '"Later" second'
printf 'app.ergana.ai other\n' >"$idx"
out=$(ctx "$tmp/bare" fr_FR.UTF-8)
has offer-bare-ws "$out" 'Se connecter à Ergana ?'
hasnt offer-bare-ws-slug "$out" '"other"'
mkdir "$tmp/nogit"
hasnt offer-outside-git "$(ctx "$tmp/nogit" fr_FR.UTF-8)" '/ergana:login'
printf 'app.ergana.ai other\n' >"$idx"
for n in bare notoken; do
  mkdir -p "$(dirname "$(gitpath "$tmp/$n" info/ergana-later)")"
  : >"$(gitpath "$tmp/$n" info/ergana-later)"
done
hasnt later-bare "$(ctx "$tmp/bare" fr_FR.UTF-8)" '/ergana:login'
hasnt later-ergana "$(ctx "$tmp/notoken" fr_FR.UTF-8)" '/ergana:login'
has later-still-names-workspace "$(ctx "$tmp/notoken" fr_FR.UTF-8)" 'Espace Ergana : acme'
exit $failed
