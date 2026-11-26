---
name: plan
description: Plan this change with Ergana before writing code - a plan written from the request and validated by independent reviewers, or the full plan with your decisions when something is unclear or risky - then run its tasks one at a time and land it as a pull request.
argument-hint: "[the change, in your words]"
disable-model-invocation: true
---

The person asked for a plan: this change takes path 2 or path 3, never 0 or 1.

1. Call Ergana's `next_step` tool with this session's id (from the Ergana line at session start) and `branch` set to `git branch --show-current`. If it answers a step, this branch's change is already open: follow its instructions.
2. If it answers `no_change`, it gives the path rules: pick path 2 or 3 with them, call `open_change` with the path, your reasons, the ticket and the branch, and follow its answer, one step at a time.

The change, in the person's words: $ARGUMENTS

If Ergana's tools are not available, tell the person, in their language: when the repository has a `.ergana` file, run `/ergana:login`, then in `/mcp` choose `plugin:ergana:ergana`, then `Reconnect`; otherwise run `/mcp`, choose `plugin:ergana:ergana`, then `Authenticate`. These labels stay as Claude Code shows them, in code style, untranslated.
