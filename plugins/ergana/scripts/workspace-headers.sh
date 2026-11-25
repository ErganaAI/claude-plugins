#!/bin/sh
# The MCP server's headersHelper: the session's repository and git branch as X-Ergana-Repo and
# X-Ergana-Branch, so the Sessions page names them without the agent reporting them, and the sha256
# of the checkout's root folder as X-Ergana-Root-Hash, so Ergana finds the root among an edited
# file's folders and knows which part of the repository (which area) the file is in. The root, a
# local path, is never sent. A .ergana file (workspace = <slug>, DR-0035.D1) in the project folder,
# else in the main checkout of a linked worktree (read without git from .git and commondir, then
# with git), adds X-Ergana-Workspace and Accept-Language (fr when LANG starts with fr, else en); a
# .ergana that is unreadable or malformed adds "Authorization: Bearer ergana-not-connected" instead,
# never a silent fall back to the shared sign-in. A valid .ergana adds "Authorization: Bearer <token>" with
# the workspace's own token (ergana-auth.py header, what is left of 8 s once git has answered; Claude Code
# stops a helper at 10 s), or ergana-not-connected when there is none, when the budget is spent, or when
# DR-0037.D1 wants a confirmation not given yet (2+ connected workspaces and a .ergana git tracks whose
# sha256 is not in ~/.config/ergana/trusted). Without .ergana the output is unchanged. A hook cannot
# hand a command's output to an mcp_tool hook; a headersHelper runs at each MCP connection (session
# start, reconnect), so the branch is the one at connection time.
# Silent on any failure (not a git repository, no origin, git missing, over a second): it prints
# at least {} and exits 0, so the connection never fails on it. Never a credential: userinfo is
# stripped from an https or ssh:// URL, and anything but an http(s), ssh:// or scp-style git URL
# (a file path, file://, ext::) is not sent.
t0=$(date +%s 2>/dev/null)
dir=${1:-}
case "$dir" in '' | *'${'*) dir=${CLAUDE_PROJECT_DIR:-$PWD} ;; esac
here=$(cd "$(dirname "$0")" && pwd)
# git_ (each call cut off after about a second), the .ergana lookup and the confirmation check.
. "$here/ergana-repo.sh"

# budget_left: $left, the whole seconds left of the 8 s (the clock counts whole seconds: one is held back), 0
# when there is no clock.
budget_left() {
  left=0
  now=$(date +%s 2>/dev/null)
  case "$t0$now" in '' | *[!0-9]*) return 0 ;; esac
  left=$((7 - (now - t0)))
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

ergana_find

out=
[ -n "$repo" ] && out="\"X-Ergana-Repo\":\"$repo\""
[ -n "$branch" ] && out="${out:+$out,}\"X-Ergana-Branch\":\"$branch\""
[ -n "$hash" ] && out="${out:+$out,}\"X-Ergana-Root-Hash\":\"$hash\""
if [ -n "$ergana" ]; then
  slug=$(ergana_slug "$ergana")
  if [ -n "$slug" ]; then
    case "${LANG:-}" in fr*) lang=fr ;; *) lang=en ;; esac
    out="${out:+$out,}\"X-Ergana-Workspace\":\"$slug\",\"Accept-Language\":\"$lang\""
    # The workspace's token, within what is left of 8 s (the clock counts whole seconds: one is held back).
    token=
    budget_left
    if [ "$left" -ge 1 ] && ! ergana_needs_confirm; then
      budget_left
      if [ "$left" -ge 1 ] && command -v python3 >/dev/null 2>&1; then
        if command -v perl >/dev/null 2>&1; then
          token=$({ perl -e 'alarm shift; exec @ARGV or exit 1' "$left" python3 -I "$here/ergana-auth.py" header "$slug" "$left"; } 2>/dev/null)
        else
          token=$(python3 -I "$here/ergana-auth.py" header "$slug" "$left" 2>/dev/null)
        fi
      fi
    fi
    if [ "${#token}" -le 4096 ] && printf '%s' "$token" | LC_ALL=C grep -Eq '^[A-Za-z0-9._~+/=-]+$'; then
      out="$out,\"Authorization\":\"Bearer $token\""
    else
      out="$out,\"Authorization\":\"Bearer ergana-not-connected\""
    fi
  else
    out="${out:+$out,}\"Authorization\":\"Bearer ergana-not-connected\""
  fi
fi
printf '{%s}\n' "$out"
exit 0
