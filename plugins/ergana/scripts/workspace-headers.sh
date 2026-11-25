#!/bin/sh
# The MCP server's headersHelper: the session's repository and git branch as X-Ergana-Repo and
# X-Ergana-Branch, so the Sessions page names them without the agent reporting them, and the sha256
# of the checkout's root folder as X-Ergana-Root-Hash, so Ergana finds the root among an edited
# file's folders and knows which part of the repository (which area) the file is in. The root, a
# local path, is never sent. A .ergana file (workspace = <slug>, DR-0035.D1) in the project folder,
# else in the main checkout of a linked worktree (read without git from .git and commondir, then
# with git), adds X-Ergana-Workspace and Accept-Language (fr when LANG starts with fr, else en); a
# .ergana that is unreadable or malformed adds "Authorization: Bearer ergana-not-connected" instead,
# never a silent fall back to the shared sign-in. Without .ergana the output is unchanged. A hook cannot
# hand a command's output to an mcp_tool hook; a headersHelper runs at each MCP connection (session
# start, reconnect), so the branch is the one at connection time.
# Silent on any failure (not a git repository, no origin, git missing, over a second): it prints
# at least {} and exits 0, so the connection never fails on it. Never a credential: userinfo is
# stripped from an https or ssh:// URL, and anything but an http(s), ssh:// or scp-style git URL
# (a file path, file://, ext::) is not sent.
dir=${1:-}
case "$dir" in '' | *'${'*) dir=${CLAUDE_PROJECT_DIR:-$PWD} ;; esac

# git, cut off after about a second when perl is there to time it.
git_() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm 1; exec @ARGV or exit 1' git -C "$dir" "$@" 2>/dev/null
  else
    git -C "$dir" "$@" 2>/dev/null
  fi
}

# The remote URL without credentials, or nothing. Only plain ASCII URL characters pass, so the
# value needs no JSON escaping.
remote() {
  url=$1
  printf '%s' "$url" | LC_ALL=C grep -Eq '^[A-Za-z0-9._~:/@%+-]+$' || return 0
  case "$url" in
    http://* | https://* | ssh://*)
      scheme=${url%%://*}
      rest=${url#*://}
      # Userinfo ends at the authority's last @ (a password may hold an @).
      auth=${rest%%/*}
      rest=${auth##*@}${rest#"$auth"}
      # An @ left anywhere is a credential cut wrong (a password holding a /): send nothing.
      case "$rest" in *@*) return 0 ;; esac
      case "$rest" in */?*) printf '%s://%s' "$scheme" "$rest" ;; esac
      ;;
    *://* | *::*) ;;
    *)
      # scp-style user@host:owner/name, the user a bare name (a password is never in this form).
      printf '%s' "$url" | LC_ALL=C grep -Eq '^([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+:[^/][^:]*$' &&
        printf '%s' "$url"
      ;;
  esac
}

repo=$(remote "$(git_ remote get-url origin)")
branch=$(git_ branch --show-current)
# A branch outside printable ASCII, or with a quote or a backslash, is not sent (no escaping).
printf '%s' "$branch" | LC_ALL=C grep -Eq '^[ -~]+$' && ! printf '%s' "$branch" | grep -q '["\\]' ||
  branch=

# The root's sha256 (git prints it with forward slashes, C:/... on Windows), or nothing.
top=$(git_ rev-parse --show-toplevel)
hash=
if [ -n "$top" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$top" | sha256sum 2>/dev/null | cut -c1-64)
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$top" | shasum -a 256 2>/dev/null | cut -c1-64)
  fi
  printf '%s' "$hash" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || hash=
fi

# The .ergana file: the project folder, then the main checkout of a linked worktree (.git is a file
# "gitdir: <path>", <path>/commondir the common git dir), then git's root and main checkout.
main_of() { # the main checkout of a common git dir, when it is a checkout's .git
  [ "${1##*/}" = .git ] && printf '%s' "${1%/*}"
}
ergana=
[ -e "$dir/.ergana" ] && ergana=$dir/.ergana
if [ -z "$ergana" ] && [ -f "$dir/.git" ]; then
  gd=$(sed -n 's/^gitdir: *//p' "$dir/.git" 2>/dev/null | head -n 1)
  case "$gd" in /*) ;; *) gd=$dir/$gd ;; esac
  cd_=$(head -n 1 "$gd/commondir" 2>/dev/null)
  case "$cd_" in /*) ;; *) cd_=$gd/$cd_ ;; esac
  common=$(cd "$cd_" 2>/dev/null && pwd)
  m=$(main_of "$common")
  [ -n "$m" ] && [ -e "$m/.ergana" ] && ergana=$m/.ergana
fi
if [ -z "$ergana" ]; then
  [ -n "$top" ] && [ -e "$top/.ergana" ] && ergana=$top/.ergana
fi
if [ -z "$ergana" ] && [ -n "$top" ]; then
  common=$(git_ rev-parse --path-format=absolute --git-common-dir)
  m=$(main_of "$common")
  [ -n "$m" ] && [ -e "$m/.ergana" ] && ergana=$m/.ergana
fi

out=
[ -n "$repo" ] && out="\"X-Ergana-Repo\":\"$repo\""
[ -n "$branch" ] && out="${out:+$out,}\"X-Ergana-Branch\":\"$branch\""
[ -n "$hash" ] && out="${out:+$out,}\"X-Ergana-Root-Hash\":\"$hash\""
if [ -n "$ergana" ]; then
  # The first workspace line outside # comments, spaces around = and the value cut off.
  slug=$(grep -v '^[[:space:]]*#' "$ergana" 2>/dev/null | grep -E '^[[:space:]]*workspace[[:space:]]*=' | head -n 1 |
    sed 's/^[^=]*=//; s/^[[:space:]]*//; s/[[:space:]]*$//')
  if printf '%s' "$slug" | LC_ALL=C grep -Eq '^[a-z0-9]{3,30}$'; then
    case "${LANG:-}" in fr*) lang=fr ;; *) lang=en ;; esac
    out="${out:+$out,}\"X-Ergana-Workspace\":\"$slug\",\"Accept-Language\":\"$lang\""
  else
    out="${out:+$out,}\"Authorization\":\"Bearer ergana-not-connected\""
  fi
fi
printf '{%s}\n' "$out"
exit 0
