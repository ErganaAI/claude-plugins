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
set -u
if [ "${1:-}" = --timed ]; then
  shift
elif command -v perl >/dev/null 2>&1; then
  # Its own process group, killed whole at the deadline, so no git is left writing to the pipe.
  exec perl -e 'setpgrp(0, 0); $SIG{ALRM} = sub { kill "KILL", -$$ }; alarm shift;
    exit(system(@ARGV) >> 8)' 5 /bin/sh "$0" --timed "$@"
fi
cd "${1:-.}" 2>/dev/null || exit 1
top=$(git rev-parse --show-toplevel 2>/dev/null) && cd "$top" || exit 1
base=$(git merge-base HEAD origin/HEAD 2>/dev/null || git rev-parse --verify -q HEAD) || exit 1
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
