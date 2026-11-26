---
name: add-decision
description: Help the person write one decision an agent can follow, try it on this repository's code with Ergana's rules check, and record it in the company's decision catalogue. Start it only when the person asks to record or add a decision, with their words as the argument; it asks the person for every approval.
argument-hint: "[the decision, in your words]"
---

Call Ergana's `add_decision_guide` tool and follow the instructions it returns, step by step.

Every approval in this flow is the person's: ask them each question, and never answer one for them.

Their words so far: $ARGUMENTS

The trial runner: `${CLAUDE_SKILL_DIR}/trial.py`.

If Ergana's tools are not available, tell the person, in their language: when the repository has a `.ergana` file, run `/ergana:login`, then in `/mcp` choose `plugin:ergana:ergana`, then `Reconnect`; otherwise run `/mcp`, choose `plugin:ergana:ergana`, then `Authenticate`. These labels stay as Claude Code shows them, in code style, untranslated.
