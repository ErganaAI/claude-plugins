#!/bin/sh
# SessionStart: hand the agent its Claude Code session id and ask it to report its steps. The
# server's instructions say the same, but agents seldom act on them alone (John, 19 Nov 2026).
# No jq: the hook input is matched as text, and an id outside [A-Za-z0-9-]{1,128} prints nothing.
# The workspace lines (DR-0029.D1 language, DR-0036.D1 named-workspace offer, DR-0041.D1 offer with no
# .ergana, DR-0051.D1 no confirmation) come before the GitHub line, which stays the last one.
input=$(cat)
id=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]\{1,128\}\)".*/\1/p' | head -n 1)
[ -n "$id" ] || exit 0
echo "Ergana session id: $id."
echo "Report this session's progress with Ergana's report_step tool and this id: first the repository (its origin URL) and the task in one line, with gh and gh_login from the GitHub line below, then the steps you will run, then each step's start and end."
echo "When Ergana refuses your stop, first call Ergana's check_done tool yourself, with no arguments and without a word to the developer: it answers whether the repository changed since its last check, and what to do."

cwd=$(printf '%s' "$input" | sed -n 's/.*[{,]"cwd":"\([^"\\]*\)".*/\1/p')
here=$(cd "$(dirname "$0")" && pwd)

# The repository's workspace and its source, and the sign-in offer.
workspace_lines() {
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 0
  . "$here/ergana-repo.sh"
  dir=$cwd
  top=$(git_ rev-parse --show-toplevel)
  ergana_find
  case "${LANG:-}" in
    fr*) fr=1; later="Plus tard" ;;
    *) fr=0; later=Later ;;
  esac
  idx=$(ergana_index)
  marker=$(git_ rev-parse --path-format=absolute --git-path info/ergana-later)
  offer=1
  [ -n "$marker" ] && [ -e "$marker" ] && offer=0
  auth="$here/ergana-auth.py"
  slug=
  [ -n "$ergana" ] && slug=$(ergana_slug "$ergana")
  if [ -n "$slug" ]; then
    if [ "$tracked" = 1 ]; then
      if [ "$fr" = 1 ]; then src="fichier .ergana committé"; else src="committed .ergana file"; fi
    else
      if [ "$fr" = 1 ]; then src="fichier .ergana local"; else src="local .ergana file"; fi
    fi
    if [ "$fr" = 1 ]; then echo "Espace Ergana : $slug ($src)"; else echo "Ergana workspace: $slug ($src)"; fi
    if [ "$offer" = 1 ] && ! grep -q " $slug\$" "$idx" 2>/dev/null; then
      echo "The $slug workspace has no sign-in on this machine. Ask the person with AskUserQuestion whether to sign in now, with the options \"$slug\" and \"$later\". On \"$slug\", start the /ergana:login skill for it. On \"$later\", run: python3 -I \"$auth\" later (the offer is not repeated in this repository)."
    fi
  elif [ -z "$ergana" ] && [ "$offer" = 1 ] && [ -n "$top" ]; then
    if [ "$fr" = 1 ]; then q="Se connecter à Ergana ?"; go="Se connecter"; else q="Sign in to Ergana?"; go="Sign in"; fi
    echo "This repository has no .ergana file. Ask the person with AskUserQuestion this exact question: \"$q\", with exactly two options, \"$go\" first and \"$later\" second. On \"$go\", start the /ergana:login skill with no argument. On \"$later\", run: python3 -I \"$auth\" later (the offer is not repeated in this repository)."
  fi
}
workspace_lines

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

# The repository's fingerprint at the session's start (fingerprint.sh), kept once per session in
# the plugin's data folder: after a refused stop, the agent's check_done sends it (ergana-tools.sh),
# so a session that changed nothing in the repository finishes without a check (server
# docs/done-gate.md, A1). Written after the lines above, so a slow repository never costs them.
# Files older than 30 days are removed.
data=${CLAUDE_PLUGIN_DATA:-}
if [ -n "$data" ] && [ -n "$cwd" ] && mkdir -p "$data/start" 2>/dev/null; then
  find "$data/start" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
  if [ ! -s "$data/start/$id" ]; then
    sum=$("$(cd "$(dirname "$0")" && pwd)/fingerprint.sh" "$cwd") &&
      printf '%s' "$sum" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' &&
      printf '%s\n' "$sum" >"$data/start/$id"
  fi
fi
exit 0
