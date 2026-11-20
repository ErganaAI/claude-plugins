#!/bin/sh
# The MCP server's headersHelper: the session's repository and git branch as X-Ergana-Repo and
# X-Ergana-Branch, so the Sessions page names them without the agent reporting them. A hook cannot
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
      hostpath=${rest#*@}
      # An @ after the first / belongs to the path, not to userinfo.
      case "${rest%%/*}" in *@*) rest=$hostpath ;; esac
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

out=
[ -n "$repo" ] && out="\"X-Ergana-Repo\":\"$repo\""
[ -n "$branch" ] && out="${out:+$out,}\"X-Ergana-Branch\":\"$branch\""
printf '{%s}\n' "$out"
exit 0
