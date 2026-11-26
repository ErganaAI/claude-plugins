#!/bin/sh
# PostToolUse on AskUserQuestion (DR-0037.D1): when the person answered the question
# « Envoyer ce dépôt à l'espace <slug> ? » (or "Send this repository to the <slug> workspace?", exactly) with
# the agreeing option (« Oui » / "Yes"), the sha256 of the repository's tracked .ergana, which must name
# <slug>, is added to ~/.config/ergana/trusted (0600) as "<sha256 of the git common dir> <sha256 of the
# file>". Nothing else writes that file. Any other question or answer, a
# malformed input, or an untracked .ergana writes nothing. Silent, always exit 0.
here=$(cd "$(dirname "$0")" && pwd)
. "$here/ergana-repo.sh"
command -v python3 >/dev/null 2>&1 || exit 0

# The hook input is JSON: tool_response.answers maps each question's text to the chosen label.
input=$(cat)
found=$(printf '%s' "$input" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
    cwd = d["cwd"]
    questions = d["tool_input"]["questions"]
    answers = d["tool_response"]["answers"]
    assert isinstance(cwd, str) and "\n" not in cwd and isinstance(answers, dict)
except Exception:
    sys.exit(0)
forms = ((r"^Envoyer ce dépôt à l\x27espace ([a-z0-9]{3,30}) \?$", "Oui"),
         (r"^Send this repository to the ([a-z0-9]{3,30}) workspace\?$", "Yes"))
for q, a in answers.items():
    if not isinstance(q, str) or not isinstance(a, str):
        continue
    text = q.replace(" ", " ").replace(" ", " ")
    for pattern, agree in forms:
        m = re.match(pattern, text)
        if not (m and a == agree):
            continue
        # the question was asked in this call, and the answer is one of its options
        for asked in questions:
            if isinstance(asked, dict) and asked.get("question") == q and \
                    agree in [o.get("label") for o in asked.get("options", []) if isinstance(o, dict)]:
                print(cwd)
                print(m.group(1))
                sys.exit(0)
' 2>/dev/null)
[ -n "$found" ] || exit 0
dir=$(printf '%s\n' "$found" | sed -n 1p)
want=$(printf '%s\n' "$found" | sed -n 2p)
[ -d "$dir" ] || exit 0

top=$(git_ rev-parse --show-toplevel)
ergana_find
[ -n "$ergana" ] && [ "$tracked" = 1 ] || exit 0
[ "$(ergana_slug "$ergana")" = "$want" ] || exit 0
line=$(ergana_trust_line)
[ -n "$line" ] || exit 0
trusted=$(ergana_trusted)
grep -qxF "$line" "$trusted" 2>/dev/null && exit 0
(umask 077 && mkdir -p "${trusted%/*}" && chmod 700 "${trusted%/*}" && printf '%s\n' "$line" >>"$trusted" &&
  chmod 600 "$trusted") 2>/dev/null
exit 0
