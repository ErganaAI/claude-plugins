#!/bin/sh
# Stop: the done gate's local half (DR-0028.D1). The stop goes through when the git checkout holding
# the session's folder is as it was at the session's start (start/<session>, session-context.sh) or
# as the last check the server cleared left it (cleared/<session>, cleared.sh). Otherwise it is
# refused once per fingerprint (DR-0033.D1): a continued stop passes only while the repository is
# exactly the one refused (refused/<session>); the agent's check_done then gates. Outside a git
# checkout, or in one with no commit, nothing is gated (DR-0032.D1), nor while the check agent runs.
# A fingerprint that cannot be computed is "unknown": changed, fail closed. No jq: the hook input is
# matched as text. The line follows LANG only (DR-0029.D1).
input=$(cat)
printf '%s' "$input" | grep -Eq '"agent_type"[[:space:]]*:[[:space:]]*"ergana:check"' && exit 0
session=$(printf '%s' "$input" | sed -n 's/.*[{,]"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,128\}\)".*/\1/p' | head -n 1)
cwd=$(printf '%s' "$input" | sed -n 's/.*[{,]"cwd"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1)
[ -n "$session" ] && [ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
git rev-parse --verify -q HEAD >/dev/null 2>&1 || exit 0

sum=$("$(cd "$(dirname "$0")" && pwd)/fingerprint.sh" .) &&
  printf '%s' "$sum" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || sum=unknown
# Without a data folder it can write, the stop cannot be refused once per fingerprint: it goes
# through rather than refuse forever (review R5).
data=${CLAUDE_PLUGIN_DATA:-}
[ -n "$data" ] && mkdir -p "$data/refused" 2>/dev/null || exit 0
[ "$(cat "$data/start/$session" 2>/dev/null)" = "$sum" ] && exit 0
[ "$(cat "$data/cleared/$session" 2>/dev/null)" = "$sum" ] && exit 0
if printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' &&
  [ "$(cat "$data/refused/$session" 2>/dev/null)" = "$sum" ]; then
  exit 0
fi
find "$data/refused" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
printf '%s\n' "$sum" >"$data/refused/$session" 2>/dev/null || exit 0
case ${LANG:-} in
  fr*) line='Ergana › Vérification du changement avant de terminer.' ;;
  *) line='Ergana › Checking the change before finishing.' ;;
esac
printf '{"decision":"block","reason":"%s"}\n' "$line"
exit 0
