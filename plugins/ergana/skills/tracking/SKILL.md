---
name: tracking
description: Set where this repository's tickets go, which GitHub board shows them, its columns and the issue types its tickets and tasks get. For an owner, admin or architect.
disable-model-invocation: true
---

Call Ergana's `repo_tracking_guide` tool with this session's id (from the Ergana line at session start) and follow the instructions it returns, step by step.

If Ergana's tools are not available, tell the person, in their language: when this session's start asked to confirm the repository's workspace and it was declined or not answered, Ergana is not used in this repository (on a pending confirmation, ask that question again); else, when the repository has a `.ergana` file, run `/ergana:login`, then in `/mcp` choose `plugin:ergana:ergana`, then `Reconnect`; otherwise run `/mcp`, choose `plugin:ergana:ergana`, then `Authenticate`. These labels stay as Claude Code shows them, in code style, untranslated.
