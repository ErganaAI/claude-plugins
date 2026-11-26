---
name: status
description: Show which Ergana workspace this repository is linked to, where that link comes from (committed or local .ergana file), and whether the workspace is signed in on this machine.
---

Run, with the Bash tool and the repository as the working folder: `python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/ergana-auth.py" status`.

Report what it prints in the person's language, in an impersonal form: the repository's workspace and the source of that link, whether the workspace is connected and until when its token is valid, and the other workspaces connected on this machine. When the workspace is not connected, point to `/ergana:login`. The command never prints a token; never look for one.
