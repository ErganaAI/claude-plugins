#!/bin/sh
# Sourced by workspace-headers.sh and session-context.sh: the repository's .ergana file (DR-0035.D1),
# whether git tracks it, and whether DR-0037.D1 still wants the person's confirmation. The caller sets
# $dir (the session's folder) and, for the root, $top (git's top level, or empty); everything is silent
# and every git call is cut off after about a second when perl is there to time it.

# gitc <folder> <git args>
gitc() {
  d=$1
  shift
  if command -v perl >/dev/null 2>&1; then
    { perl -e 'alarm 1; exec @ARGV or exit 1' git -C "$d" "$@"; } 2>/dev/null
  else
    git -C "$d" "$@" 2>/dev/null
  fi
}
git_() { gitc "$dir" "$@"; }

main_of() { # the main checkout of a common git dir, when it is a checkout's .git
  [ "${1##*/}" = .git ] && printf '%s' "${1%/*}"
}

# add_cand <file>: a candidate .ergana, once
add_cand() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  case "
$cands" in
    *"
$1
"*) ;;
    *) cands="$cands$1
" ;;
  esac
}

# ergana_find: the project folder's .ergana, the main checkout's of a linked worktree (read without git
# from .git and commondir), the root's, then git's main checkout when nothing was found. The first
# candidate git tracks wins, else the first. Sets $ergana (empty when none) and $tracked: 1 tracked,
# 0 not, 2 unknown (git hung or failed).
ergana_find() {
  ergana=
  tracked=0
  cands=
  add_cand "$dir/.ergana"
  if [ -f "$dir/.git" ]; then
    gd=$(sed -n 's/^gitdir: *//p' "$dir/.git" 2>/dev/null | head -n 1)
    case "$gd" in /*) ;; *) gd=$dir/$gd ;; esac
    cd_=$(head -n 1 "$gd/commondir" 2>/dev/null)
    case "$cd_" in /*) ;; *) cd_=$gd/$cd_ ;; esac
    common=$(cd "$cd_" 2>/dev/null && pwd)
    m=$(main_of "$common")
    [ -n "$m" ] && add_cand "$m/.ergana"
  fi
  [ -n "${top:-}" ] && add_cand "$top/.ergana"
  if [ -z "$cands" ] && [ -n "${top:-}" ]; then
    common=$(git_ rev-parse --path-format=absolute --git-common-dir)
    m=$(main_of "$common")
    [ -n "$m" ] && add_cand "$m/.ergana"
  fi
  [ -n "$cands" ] || return 0
  first=
  firstrc=
  oldifs=$IFS
  IFS='
'
  for c in $cands; do
    gitc "${c%/*}" ls-files --error-unmatch -- .ergana >/dev/null
    rc=$?
    # in the index, or still in HEAD (git rm --cached must not hide it); a cut-off ls-files is final
    if [ "$rc" -ne 0 ] && [ "$rc" -le 128 ]; then
      gitc "${c%/*}" cat-file -e HEAD:./.ergana >/dev/null
      rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      ergana=$c
      tracked=1
      break
    fi
    [ -n "$first" ] || { first=$c; firstrc=$rc; }
  done
  IFS=$oldifs
  if [ -z "$ergana" ]; then
    ergana=$first
    # 128 is "not a repository" or no such file in one: not tracked. Above that, git was cut off.
    if [ "$firstrc" -gt 128 ]; then tracked=2; else tracked=0; fi
  fi
}

# ergana_slug <file>: the first workspace line outside # comments, spaces around = and the value cut
# off; the value only when it is a valid slug.
ergana_slug() {
  s=$(grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -E '^[[:space:]]*workspace[[:space:]]*=' | head -n 1 |
    sed 's/^[^=]*=//; s/^[[:space:]]*//; s/[[:space:]]*$//')
  printf '%s' "$s" | LC_ALL=C grep -Eq '^[a-z0-9]{3,30}$' && printf '%s' "$s"
}

ergana_sha() { # <file>: its sha256, or nothing
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -c1-64
  fi
}

ergana_index() { printf '%s' "${HOME:-/nonexistent}/.config/ergana/workspaces"; }
ergana_trusted() { printf '%s' "${HOME:-/nonexistent}/.config/ergana/trusted"; }

ergana_sha_str() { # <string>: its sha256, or nothing
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-64
  fi
}

# ergana_trust_line: "<sha256 of the absolute git common dir> <sha256 of the .ergana>", or nothing.
ergana_trust_line() {
  common=$(git_ rev-parse --path-format=absolute --git-common-dir)
  [ -n "$common" ] || return 0
  k=$(ergana_sha_str "$common")
  sum=$(ergana_sha "$ergana")
  [ -n "$k" ] && [ -n "$sum" ] && printf '%s %s' "$k" "$sum"
}

# ergana_needs_confirm: DR-0037.D1, true when 2+ workspaces are connected on this machine and the .ergana
# git tracks (or may track) is not one whose line is in ~/.config/ergana/trusted (outside the repository,
# which neither the repository nor a git command can change).
ergana_needs_confirm() {
  [ "$tracked" = 0 ] && return 1
  n=$(grep -c . "$(ergana_index)" 2>/dev/null)
  [ "${n:-0}" -ge 2 ] || return 1
  line=$(ergana_trust_line)
  [ -n "$line" ] && grep -qxF "$line" "$(ergana_trusted)" 2>/dev/null && return 1
  return 0
}
