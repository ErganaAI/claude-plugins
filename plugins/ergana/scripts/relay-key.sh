#!/bin/sh
# The session's relay key (server docs/relay.md): 32 random bytes in base64url without padding (43
# characters), kept once per session in inbox/<session>.key, mode 0600. ergana-tools.sh puts it in
# the agent's report_step calls (never typed by the model) and inbox.sh listens with it, so Ergana
# can wake this session when another agent writes to its person. Only a hash of it is stored there.
# Sourced by session-context.sh (SessionStart) and ergana-tools.sh (report_step, for a session that
# started before the key existed): relay_key <session id> creates the key when it is missing.
# Silent on any failure (no key, no listener); the key is never printed.
relay_key() {
  [ -n "${CLAUDE_PLUGIN_DATA:-}" ] || return 0
  dir=$CLAUDE_PLUGIN_DATA/inbox
  file=$dir/$1.key
  [ -s "$file" ] && LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$' "$file" && return 0
  (
    umask 077
    mkdir -p "$dir" || exit 1
    find "$dir" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
    key=$(head -c 32 /dev/urandom | base64 | LC_ALL=C tr '+/' '-_' | LC_ALL=C tr -d '=\n') || exit 1
    printf '%s' "$key" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$' || exit 1
    tmp=$file.$$
    printf '%s\n' "$key" >"$tmp" || { rm -f "$tmp"; exit 1; }
    # A missing key: ln fails when another hook made it first, whose key is kept (as is one that became valid
    # meanwhile). Only a malformed one is replaced.
    if [ -e "$file" ] && ! LC_ALL=C grep -Eq '^[A-Za-z0-9_-]{43}$' "$file"; then
      mv -f "$tmp" "$file"
    else
      ln "$tmp" "$file" 2>/dev/null
      rm -f "$tmp"
    fi
  ) 2>/dev/null
  return 0
}
