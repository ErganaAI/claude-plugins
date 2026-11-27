#!/bin/sh
# Sourced by workspace-headers.sh, session-context.sh and inbox.sh: the repository's .ergana file (DR-0035.D1),
# and whether git tracks it (DR-0051.D1: it applies like a local one, with no confirmation). The caller sets
# $dir (the session's folder) and, for the root, $top (git's top level, or empty); everything is silent
# and every git call is cut off after about a second when perl is there to time it.

# gitc <folder> <git args>
# test_off_prod: true when ERGANA_AUTH_TEST=1 has no test origin to call (no ERGANA_ORIGIN, or one on
# app.ergana.ai): a test never reaches production, as in ergana-auth.py and ergana-hook.py.
test_off_prod() {
  [ "${ERGANA_AUTH_TEST:-}" = 1 ] || return 1
  o=$(printf '%s' "${ERGANA_ORIGIN:-}" | tr 'A-Z' 'a-z')
  case "$o" in '' | *://app.ergana.ai | *://app.ergana.ai. | *://app.ergana.ai[.:/]*) return 0 ;; esac
  return 1
}

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
    # A .git (a file in a linked worktree) in the folder or a parent that git cannot read (dubious ownership,
    # git missing) is unknown, never "not tracked".
    if [ "$tracked" = 0 ] && [ -n "$ergana" ]; then
      g=${ergana%/*}
      while :; do
        if [ -e "$g/.git" ]; then
          gitc "${ergana%/*}" rev-parse --git-dir >/dev/null || tracked=2
          break
        fi
        case "$g" in */*) g=${g%/*} ;; *) break ;; esac
      done
    fi
  fi
}

# ergana_slug <file>: the first workspace line outside # comments, spaces around = and the value cut
# off; the value only when it is a valid slug.
ergana_slug() {
  s=$(grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -E '^[[:space:]]*workspace[[:space:]]*=' | head -n 1 |
    sed 's/^[^=]*=//; s/^[[:space:]]*//; s/[[:space:]]*$//')
  printf '%s' "$s" | LC_ALL=C grep -Eq '^[a-z0-9]{3,30}$' && printf '%s' "$s"
}

ergana_index() { printf '%s' "${HOME:-/nonexistent}/.config/ergana/workspaces"; }
