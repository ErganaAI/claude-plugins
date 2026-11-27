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

# --empty: exit 0 only when the checkout has nothing to check (no diff from the base, no untracked
# file git does not ignore), 1 otherwise, outside git and before the first commit included.
# empty|changed <name> <folder>
empty() { if "$fp" --empty "$2"; then echo "ok   $1"; else echo "FAIL $1: changed"; failed=1; fi; }
changed() { if "$fp" --empty "$2"; then echo "FAIL $1: empty"; failed=1; else echo "ok   $1"; fi; }
git -C "$clone" reset -q --hard origin/HEAD
empty "--empty: at the base" "$clone"
mkdir -p "$clone/build" && printf 'x' >"$clone/build/out.bin"
empty "--empty: an ignored file" "$clone"
printf 'print(5)\n' >"$clone/app.py"
changed "--empty: edited" "$clone"
git -C "$clone" commit -qam five
changed "--empty: committed on the branch" "$clone"
git -C "$clone" reset -q --hard origin/HEAD
printf 'x\n' >"$clone/notes.md"
mkdir -p "$clone/sub"
changed "--empty: untracked, from a subfolder" "$clone/sub"
rm "$clone/notes.md"
changed "--empty: outside git" "$tmp/plain"
changed "--empty: no commit" "$tmp/empty"
# Without a real merge base with origin/HEAD, --empty cannot tell committed work from none: a change
# (review R1, R2). The fingerprint itself keeps its HEAD fallback, byte for byte.
changed "--empty: no remote, clean" "$repo"
nohead="$tmp/nohead"
git clone -q "$repo" "$nohead"
withhead=$("$fp" "$nohead")
git -C "$nohead" remote set-head origin -d
if git -C "$nohead" rev-parse -q --verify refs/remotes/origin/HEAD >/dev/null; then
  echo "FAIL setup: origin/HEAD still there"; failed=1
fi
same "no origin/HEAD: the base falls back on HEAD" "$withhead" "$("$fp" "$nohead")"
changed "--empty: no origin/HEAD, clean at origin's commit" "$nohead"
git -C "$nohead" switch -q -c feature
printf 'print(6)\n' >"$nohead/app.py" && git -C "$nohead" commit -qam six
changed "--empty: no origin/HEAD, committed on a branch" "$nohead"
related=$("$fp" "$clone")
unrelated=$(git -C "$clone" commit-tree "$(git -C "$clone" mktree </dev/null)" -m unrelated)
git -C "$clone" update-ref refs/remotes/origin/HEAD "$unrelated"
same "no merge base: the base falls back on HEAD" "$related" "$("$fp" "$clone")"
changed "--empty: no merge base with origin/HEAD" "$clone"
exit $failed
