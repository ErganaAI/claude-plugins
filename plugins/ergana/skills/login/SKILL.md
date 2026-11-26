---
name: login
description: Sign in to an Ergana workspace in the browser and link this repository to it (writes .ergana). Use when the person asks to connect, sign in or switch to a workspace, or accepts the sign-in offered at session start.
argument-hint: "[workspace]"
---

Sign the person in to one Ergana workspace. The token is kept per workspace on this machine (macOS Keychain, else a private file), and this repository's `.ergana` file names the workspace.

1. Settle the workspace, with its slug: 3 to 30 lowercase letters or digits.
   - Start from the argument: $ARGUMENTS
   - Without one, use the workspace this repository's `.ergana` names, if it has one.
   - Otherwise ask the person with `AskUserQuestion`, one option per workspace already connected on this machine (the second column of `~/.config/ergana/workspaces`) and « Autre » (or "Other") to type another. Never guess a workspace.
2. Run, with the Bash tool and the repository as the working folder, and wait for it: `python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/ergana-auth.py" login --workspace <slug>`. It opens the person's default browser and waits up to 5 minutes for the sign-in to finish. Tell the person, before running it, that the browser will open. Never open a browser yourself, never choose a profile, and never read or print a token.
3. Report its last lines in the person's language, in an impersonal form. When it refuses (another workspace than the one asked for, a `.ergana` naming a different workspace, a sign-in not finished), say why in one sentence and stop: never edit `.ergana` or retry with another workspace to get round it.
4. End with the instruction it prints: reconnect ergana in `/mcp`, or open a new session.

Write every sentence to the person in their language, in an impersonal form, with no English label quoted inside a French sentence.
