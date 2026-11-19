---
name: add-decision
description: Help the person write one decision an agent can follow, try it on this repository's code with Ergana's rules check, and record it in the company's decision catalogue.
argument-hint: "[the decision, in your words]"
disable-model-invocation: true
---

Call Ergana's `add_decision_guide` tool and follow the instructions it returns, step by step.

Their words so far: $ARGUMENTS

The trial runner: `${CLAUDE_SKILL_DIR}/trial.py`.

If Ergana's tools are not available, tell the person, in their language, that Ergana is not connected: run `/mcp`, choose ergana, then Authenticate.
