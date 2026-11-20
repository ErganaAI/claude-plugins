#!/bin/sh
# UserPromptSubmit: give the session Claude's own title as its name, so the prompt hook's
# session_state sends it to Ergana as ${session_title} (the only title a hook can pass on; Claude
# Code hands hooks a custom name, never its ai-title). The name is what the Claude app and Orca
# show. A name the person set (/rename, -n, Remote Control) is never replaced: this script only
# renames a session it named itself, kept in a per-session state file, when the ai-title changes.
# No jq: the transcript is matched as text; a title is kept JSON-escaped, as the transcript has it.
input=$(cat)
id=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]\{1,128\}\)".*/\1/p' | head -n 1)
transcript=$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1)
[ -n "$id" ] && [ -f "$transcript" ] || exit 0

# The latest value of a transcript entry's string field (JSON-escaped), empty when none.
latest() {
  grep -o "\"$1\":\"\\([^\"\\\\]\\|\\\\.\\)*\"" "$transcript" 2>/dev/null | tail -n 1 |
    sed "s/^\"$1\":\"//; s/\"\$//"
}
ai=$(latest aiTitle)
[ -n "$ai" ] || exit 0
name=$(latest customTitle)
[ "$ai" = "$name" ] && exit 0

state="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/ergana-plugin}/session-names"
mkdir -p "$state" 2>/dev/null || exit 0
ours=$(cat "$state/$id" 2>/dev/null)
# A name that is not the one this script gave is the person's.
[ -z "$name" ] || [ "$name" = "$ours" ] || exit 0

printf '%s' "$ai" > "$state/$id" || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"%s"}}\n' "$ai"
