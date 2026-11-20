#!/bin/sh
# SessionStart: hand the agent its Claude Code session id and ask it to report its steps. The
# server's instructions say the same, but agents seldom act on them alone (John, 19 Nov 2026).
# No jq: the hook input is matched as text, and an id outside [A-Za-z0-9-]{1,128} prints nothing.
id=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]\{1,128\}\)".*/\1/p' | head -n 1)
[ -n "$id" ] || exit 0
echo "Ergana session id: $id."
echo "Report this session's progress with Ergana's report_step tool and this id: first the repository (its origin URL) and the task in one line, with gh and gh_login from the GitHub line below, then the steps you will run, then each step's start and end."

# GitHub: what the ticket steps can do with this person's own gh (tickets design D6). One call,
# at most 2 s (it checks the token over the network), that never prints the token:
# ok, ok_no_project (no project scope: no board), signed_out, missing, or unknown (a timeout, a
# network error, or a token whose scopes gh cannot list, such as a fine-grained GH_TOKEN).
gh_state() {
  command -v gh >/dev/null 2>&1 || { echo missing; return; }
  out=$(mktemp) || { echo unknown; return; }
  gh auth status --active --json hosts >"$out" 2>/dev/null &
  pid=$!
  (sleep 2 && kill "$pid") >/dev/null 2>&1 &
  watch=$!
  wait "$pid"
  code=$?
  kill "$watch" 2>/dev/null
  status=$(cat "$out")
  rm -f "$out"
  [ "$code" -eq 0 ] || { echo unknown; return; }
  case $status in
  *'"state":"success"'*)
    login=$(printf '%s' "$status" | sed -n 's/.*"login":"\([A-Za-z0-9-]\{1,39\}\)".*/\1/p')
    scopes=$(printf '%s' "$status" | sed -n 's/.*"scopes":"\([^"]*\)".*/\1/p')
    case ", $scopes," in
    ', ,') echo "unknown $login" ;;
    *', project,'*) echo "ok $login" ;;
    *) echo "ok_no_project $login" ;;
    esac
    ;;
  *'"hosts":{}'* | *'401 Unauthorized'*) echo signed_out ;;
  *) echo unknown ;;
  esac
}
found=$(gh_state)
login=${found#* }
line="GitHub: gh=${found%% *}"
[ "$login" = "$found" ] || [ -z "$login" ] || line="$line login=$login"
echo "$line"
