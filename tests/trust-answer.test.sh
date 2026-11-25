#!/bin/sh
# plugins/ergana/scripts/trust-answer.sh (the PostToolUse hook on AskUserQuestion, DR-0037.D1): the
# repository's committed .ergana is recorded in ~/.config/ergana/trusted only when the person
# answered the exact question with the agreeing option:
#   sh tests/trust-answer.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/plugins/ergana/scripts/trust-answer.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HOME="$tmp/home"
mkdir "$HOME"

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

# mkrepo <name> <committed: yes|no>
mkrepo() {
  r="$tmp/$1"
  git init -q -b main "$r"
  printf 'workspace = acme\n' >"$r/.ergana"
  [ "$2" = yes ] && git -C "$r" add .ergana
  git -C "$r" commit -q --allow-empty -m init
  echo "$r"
}
trusted_file() { echo "$HOME/.config/ergana/trusted"; }
trustline() {
  c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)
  if command -v sha256sum >/dev/null 2>&1; then k=$(printf '%s' "$c" | sha256sum | cut -c1-64); else k=$(printf '%s' "$c" | shasum -a 256 | cut -c1-64); fi
  printf '%s %s' "$k" "$(sha "$1/.ergana")"
}

# run <repo> <question> <answer> [answers|string|none]: feeds the hook input
run() {
  python3 - "$1" "$2" "$3" "${4:-answers}" <<'PY' | sh "$script"
import json, sys
cwd, q, a, shape = sys.argv[1:5]
inp = {"cwd": cwd, "tool_name": "AskUserQuestion",
       "tool_input": {"questions": [{"question": q, "header": "Espace", "multiSelect": False,
                                     "options": [{"label": l} for l in (("Yes", "No") if q.startswith("Send") else ("Oui", "Non"))]}]}}
if shape == "answers":
    inp["tool_response"] = {"questions": inp["tool_input"]["questions"], "answers": {q: a}}
elif shape == "string":
    inp["tool_response"] = "User has answered your questions: \"%s\"=\"%s\"." % (q, a)
print(json.dumps(inp))
PY
}
expect_written() {
  f=$(trusted_file "$2")
  if [ -f "$f" ] && grep -qxF "$(trustline "$2")" "$f"; then echo "ok   $1"; else echo "FAIL $1: line not written"; failed=1; fi
}
expect_none() {
  f=$(trusted_file "$2")
  if [ -f "$f" ] && grep -qxF "$(trustline "$2")" "$f"; then echo "FAIL $1: wrote its line"; failed=1; else echo "ok   $1"; fi
}

r=$(mkrepo fr yes); run "$r" "Envoyer ce dépôt à l'espace acme ?" "Oui"; expect_written agree-fr "$r"
r=$(mkrepo en yes); run "$r" "Send this repository to the acme workspace?" "Yes"; expect_written agree-en "$r"
r=$(mkrepo nbsp yes); run "$r" "Envoyer ce dépôt à l'espace acme ?" "Oui"; expect_written agree-nbsp "$r"
r=$(mkrepo no yes); run "$r" "Envoyer ce dépôt à l'espace acme ?" "Non"; expect_none refused "$r"
r=$(mkrepo no-en yes); run "$r" "Send this repository to the acme workspace?" "No"; expect_none refused-en "$r"
r=$(mkrepo other-q yes); run "$r" "Continuer ?" "Oui"; expect_none other-question "$r"
r=$(mkrepo similar yes); run "$r" "Envoyer ce dépôt à l'espace acme ? Vraiment" "Oui"; expect_none similar-question "$r"
r=$(mkrepo slug yes); run "$r" "Envoyer ce dépôt à l'espace other ?" "Oui"; expect_none other-slug "$r"
r=$(mkrepo bad-slug yes); run "$r" "Envoyer ce dépôt à l'espace ../x ?" "Oui"; expect_none bad-slug "$r"
r=$(mkrepo untracked no); run "$r" "Envoyer ce dépôt à l'espace acme ?" "Oui"; expect_none untracked "$r"
r=$(mkrepo other-label yes); run "$r" "Envoyer ce dépôt à l'espace acme ?" "Oui, mais non"; expect_none other-label "$r"
r=$(mkrepo noanswer yes); run "$r" "Envoyer ce dépôt à l'espace acme ?" "Oui" none; expect_none no-answers "$r"
r=$(mkrepo string yes); run "$r" "Envoyer ce dépôt à l'espace acme ?" "Oui" string; expect_none string-response "$r"
# in HEAD but dropped from the index: still tracked
r=$(mkrepo head-only yes); git -C "$r" rm -q --cached .ergana
run "$r" "Envoyer ce dépôt à l'espace acme ?" "Oui"; expect_written in-head-not-index "$r"
# the record lives outside the repository, private, and the repository gets nothing
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
[ "$(mode "$HOME/.config/ergana/trusted")" = 600 ] && echo "ok   mode-600" || { echo "FAIL mode-600"; failed=1; }
[ "$(mode "$HOME/.config/ergana")" = 700 ] && echo "ok   dir-700" || { echo "FAIL dir-700"; failed=1; }
[ -e "$tmp/fr/.git/info/ergana-trusted" ] && { echo "FAIL nothing-in-repo"; failed=1; } || echo "ok   nothing-in-repo"
nr="$tmp/not-git"; mkdir "$nr"; printf 'workspace = acme\n' >"$nr/.ergana"
run "$nr" "Envoyer ce dépôt à l'espace acme ?" "Oui"; echo "ok   not-git"
printf 'not json' | sh "$script"; echo "ok   garbage-input"
exit $failed
