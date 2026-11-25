#!/bin/sh
# plugins/ergana/scripts/fingerprint.sh on throwaway repositories:
#   sh tests/fingerprint.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fp="$here/plugins/ergana/scripts/fingerprint.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t \
  GIT_COMMITTER_EMAIL=t@t

# same|differs <name> <before> <after>
same() {
  if [ -n "$2" ] && [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: $2 != $3"; failed=1; fi
}
differs() {
  if [ -n "$3" ] && [ "$2" != "$3" ]; then echo "ok   $1"; else echo "FAIL $1: $2 = $3"; failed=1; fi
}

repo="$tmp/repo"
git init -q -b main "$repo"
printf 'print(1)\n' >"$repo/app.py"
printf 'build/\n' >"$repo/.gitignore"
git -C "$repo" add . && git -C "$repo" commit -qm one
start=$("$fp" "$repo")

same unchanged "$start" "$("$fp" "$repo")"
mkdir -p "$repo/sub"
same "same from a subfolder" "$start" "$("$fp" "$repo/sub")"

printf 'print(2)\n' >"$repo/app.py"
edited=$("$fp" "$repo")
differs edited "$start" "$edited"
printf 'print(1)\n' >"$repo/app.py"
same "edit then revert" "$start" "$("$fp" "$repo")"

mkdir -p "$repo/build" && printf 'x' >"$repo/build/out.bin"
same "ignored file added" "$start" "$("$fp" "$repo")"

mkdir -p "$tmp/scratchpad/audio" && printf 'RIFF' >"$tmp/scratchpad/audio/a.wav"
same "write outside the repository" "$start" "$("$fp" "$repo")"

printf 'new\n' >"$repo/notes.md"
untracked=$("$fp" "$repo")
differs "untracked file added" "$start" "$untracked"
printf 'other\n' >"$repo/notes.md"
differs "untracked file's content changed" "$untracked" "$("$fp" "$repo")"
rm "$repo/notes.md"

printf '\001\002' >"$repo/logo.bin" && git -C "$repo" add logo.bin && git -C "$repo" commit -qm bin
binary=$("$fp" "$repo")
printf '\001\003' >"$repo/logo.bin"
first=$("$fp" "$repo")
printf '\001\004' >"$repo/logo.bin"
differs "a binary rewritten again" "$first" "$("$fp" "$repo")"
git -C "$repo" checkout -q logo.bin
same "binary restored" "$binary" "$("$fp" "$repo")"

printf 'print(3)\n' >"$repo/app.py" && git -C "$repo" commit -qam three
differs "commit, no origin/HEAD" "$binary" "$("$fp" "$repo")"

clone="$tmp/clone"
git clone -q "$repo" "$clone"
differs "another checkout of the same commit" "$("$fp" "$repo")" "$("$fp" "$clone")"
before=$("$fp" "$clone")
printf 'print(4)\n' >"$clone/app.py"
pending=$("$fp" "$clone")
differs "edit in a clone of origin" "$before" "$pending"
git -C "$clone" commit -qam four
same "the same change committed (the base is origin's)" "$pending" "$("$fp" "$clone")"
git -C "$clone" update-ref refs/remotes/origin/HEAD HEAD
differs "origin/HEAD moved onto the commit" "$pending" "$("$fp" "$clone")"

mkdir "$tmp/plain"
if "$fp" "$tmp/plain" >/dev/null; then echo "FAIL outside git: printed"; failed=1; else echo "ok   outside git"; fi
git init -q "$tmp/empty"
if "$fp" "$tmp/empty" >/dev/null; then echo "FAIL no commit: printed"; failed=1; else echo "ok   no commit"; fi
exit $failed
