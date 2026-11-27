#!/bin/sh
# The repository's fingerprint: the sha256 of its working state as Ergana's rules check judges it,
# so the done gate lets a stop through when nothing changed since the last passing check (server
# docs/done-gate.md, F1). Usage: fingerprint.sh [folder]. It hashes, from the checkout's top level:
# the top level's path and the base's sha (base: `git merge-base HEAD origin/HEAD`, else HEAD),
# one per line, then `git diff --binary <base>` (committed on the branch and not committed yet),
# then the untracked files git does not ignore: their names, then their blob hashes. A write
# outside the checkout, or to an ignored file, leaves it as it was. It prints the 64 hex digits,
# or nothing and exits 1: outside a git repository, before the first commit, or after 5 s (when
# perl is there to time it). Nothing of the repository leaves the machine but the hash.
# With --empty first, it prints nothing and exits 0 only when the checkout has nothing to check:
# no diff from the base and no untracked file git does not ignore (DR-0028.D1, amended); a
# difference, a git error or the 5 s exits 1, so a stop.sh that cannot tell refuses.
set -u
if [ "${1:-}" = --timed ]; then
  shift
elif command -v perl >/dev/null 2>&1; then
  # Its own process group, killed whole at the deadline, so no git is left writing to the pipe.
  exec perl -e 'setpgrp(0, 0); $SIG{ALRM} = sub { kill "KILL", -$$ }; alarm shift;
    exit(system(@ARGV) >> 8)' 5 /bin/sh "$0" --timed "$@"
fi
empty=
if [ "${1:-}" = --empty ]; then
  empty=1
  shift
fi
cd "${1:-.}" 2>/dev/null || exit 1
top=$(git rev-parse --show-toplevel 2>/dev/null) && cd "$top" || exit 1
base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git rev-parse --verify -q HEAD) || exit 1
if [ -n "$empty" ]; then
  # git diff --quiet exits 1 on a difference and above 1 on an error: both count as a change.
  git diff --quiet --no-ext-diff --no-textconv "$base" 2>/dev/null || exit 1
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null) || exit 1
  [ -z "$untracked" ] || exit 1
  exit 0
fi
state=$(mktemp) || exit 1
trap 'rm -f "$state"' EXIT
{
  printf '%s\n%s\n' "$top" "$base" &&
    git diff --binary --no-ext-diff --no-textconv "$base" &&
    git ls-files --others --exclude-standard &&
    git ls-files --others --exclude-standard -z | xargs -0 git hash-object --
} >"$state" 2>/dev/null || exit 1
sum=$({ shasum -a 256 2>/dev/null || sha256sum; } <"$state" | cut -c1-64)
case $sum in *[!0-9a-f]* | "") exit 1 ;; esac
[ ${#sum} -eq 64 ] || exit 1
printf '%s\n' "$sum"
