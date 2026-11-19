#!/bin/sh
# Ergana's check agent is read-only: in the ergana:check subagent, Bash runs only git reads,
# optionally piped into `shasum -a 256`. Everything else is denied (exit 2, the reason on stderr).
# Other agents' Bash calls pass untouched. No jq: the hook input is matched as text, and a
# command holding a backslash, quote escape or shell metacharacter is denied (fails closed).
input=$(cat)
printf '%s' "$input" | grep -Eq '"agent_type"[[:space:]]*:[[:space:]]*"ergana:check"' || exit 0
command=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
deny() {
  echo "Ergana's check agent is read-only: only git diff, status, show, log, ls-files, merge-base and rev-parse, optionally piped into shasum -a 256. Denied: $command" >&2
  exit 2
}
[ -n "$command" ] || deny
case $command in
  *\\* | *\;* | *\&* | *\>* | *\<* | *\`* | *\$* | *\(* | *\)*) deny ;;
  *--output* | *--ext-diff* | *--exec* | *-c\ *) deny ;;
esac
old_ifs=$IFS
IFS='|'
for part in $command; do
  part=$(printf '%s' "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case $part in
    "shasum -a 256") ;;
    "git diff" | "git diff "* | "git status" | "git status "* | "git show "* | "git log "* | \
      "git ls-files" | "git ls-files "* | "git merge-base "* | "git rev-parse "*) ;;
    *) deny ;;
  esac
done
IFS=$old_ifs
exit 0
