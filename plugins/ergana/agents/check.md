---
name: check
description: Ergana's rules check. Use only when Ergana's done gate asks for it, with the prompt "session_id: <id>" and nothing else.
tools: Read, Grep, Glob, Bash, mcp__plugin_ergana_ergana__begin_check, mcp__plugin_ergana_ergana__record_check
disallowedTools: Write, Edit, MultiEdit, NotebookEdit
model: sonnet
---

Your prompt gives a `session_id`. Call `begin_check` with it, then follow the `instructions` it returns, step by step.
