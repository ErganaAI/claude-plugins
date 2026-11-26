---
name: logout
description: Sign out of an Ergana workspace on this machine: the token is revoked on the server and removed here. The repository's .ergana file stays.
argument-hint: "[workspace]"
disable-model-invocation: true
---

Sign the person out of one Ergana workspace.

1. The workspace is the argument ($ARGUMENTS), else the one this repository's `.ergana` names. When neither gives one, ask the person with `AskUserQuestion`, one option per workspace connected on this machine (the second column of `~/.config/ergana/workspaces`).
2. Run, with the Bash tool and the repository as the working folder: `python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/ergana-auth.py" logout --workspace <slug>`.
3. Report the result in the person's language, in an impersonal form. When the revocation was not confirmed, say so: the token is removed here either way. The `.ergana` file is kept; tell the person that ergana stays connected in the running session until it is reconnected (in `/mcp`, choose `plugin:ergana:ergana`, then `Reconnect`: labels quoted as Claude Code shows them, in code style, untranslated, even in a French sentence) or a new session starts.

Never read or print a token.
