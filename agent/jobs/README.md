# jobs/

One file per task this agent performs. A job is the unit of automation: `agent-run <name>`
reads `<name>.md`, builds the run from its front matter, and records what happened.

```markdown
---
description: One line. What this job does and when it should run.
tools: read, grep, ls              # built-in tools this job may use
mcp: <server>                      # MCP servers this job may reach (see mcp/)
allow: <server>__<tool>, ...       # exactly which MCP tools; omit to allow all of that server
skills: <name>, ...                # skills to load
timeout_s: 900
---

The prompt. Written as an instruction to the agent, not a description of the job.
```

**`tools` and `allow` are the guardrail**, and they are enforced by pi itself rather than by
convention. Both are combined into pi's `--tools`, which is a hard ceiling — verified: a tool
absent from it is missing from the runtime entirely, and an extension cannot add it back. So
a tool you did not list cannot be called, misconfigured, or talked into existence by hostile
input reaching the model.

`agent-mcp tools` prints the `<server>__<tool>` names to put in `allow:`.

Start from the smallest set that works. Widening a job later is a one-line change; noticing
that it was too wide usually is not.
