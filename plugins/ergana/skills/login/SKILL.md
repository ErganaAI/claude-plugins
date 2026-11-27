---
name: login
description: Sign in to Ergana in the browser and link this repository to the workspace of the account chosen there (writes .ergana). Use when the person asks to connect or sign in, or accepts the sign-in offered at session start.
argument-hint: "[workspace]"
---

Sign the person in to Ergana. The token is kept per workspace on this machine (macOS Keychain, else a private file), and this repository's `.ergana` file names the workspace. The account signed in at the browser decides the workspace.

1. Never ask the person anything before the browser, and never guess a workspace. First run, with the Bash tool and the repository as the working folder: `python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/ergana-auth.py" connected`. When $ARGUMENTS is not empty, add `--workspace <argument>` as given, so that the helper refuses what is not a workspace name. It reads only this machine's sign-in, with no network. When it exits 0, the workspace is already connected: report the one line it prints, in the person's language, and stop, with nothing else (no browser, no other sentence). When it exits with another code than 0 or 3, it refused: go to step 3.
2. When it exits 3, tell the person, in one sentence, that the browser opens and the account chosen there decides the workspace. Then run, and wait for it: `python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/ergana-auth.py" login`, with the same `--workspace <argument>` when there is one. It opens the person's default browser and waits up to 5 minutes for the sign-in to finish. Never open a browser yourself, never choose a profile, and never read or print a token.
3. Report its last lines in the person's language, in an impersonal form. When it refuses (a `.ergana` or an argument naming another workspace, an argument that is not a workspace name, a sign-in not finished), say the line's reason in one sentence and stop: never edit `.ergana` or retry with another workspace to get round it.
4. After a sign-in at the browser, end with the line it prints: Ergana's tools work in this session from their next call, with nothing to do; only if a call still says the server is not connected, in `/mcp`, choose `plugin:ergana:ergana`, then `Reconnect`, its labels kept as Claude Code shows them.

Write every sentence to the person in their language, in an impersonal form, with no English label quoted inside a French sentence, except `plugin:ergana:ergana` and `Reconnect`, quoted as Claude Code shows them, in code style, untranslated.
