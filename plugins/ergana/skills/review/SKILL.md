---
name: review
description: Run Ergana's independent review of this branch's change before it lands - a fresh reviewer and a security pass, defects fixed and checked again, and the pull request kept a draft while one of the team's rules is still broken.
disable-model-invocation: true
---

Call Ergana's `review_guide` tool with this session's id (from the Ergana line at session start) and follow the instructions it returns, step by step.

If Ergana's tools are not available, tell the person, in their language: when this session's start asked to confirm the repository's workspace and it was declined or not answered, Ergana is not used in this repository (on a pending confirmation, ask that question again); else, when the repository has a `.ergana` file, run `/ergana:login`, then in `/mcp` choose `plugin:ergana:ergana`, then `Reconnect`; otherwise run `/mcp`, choose `plugin:ergana:ergana`, then `Authenticate`. These labels stay as Claude Code shows them, in code style, untranslated.
