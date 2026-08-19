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
requires: work/inbox/plan.md       # must already exist, or the run stops before spending
produces: work/reports/weekly.md   # must exist, be non-empty and be written by this run
verify: check-refunds              # a command that must exit 0 afterwards
timeout_s: 900
---

The prompt. Written as an instruction to the agent, not a description of the job.
```

## The guardrail: what it may do

**`tools` and `allow`** are enforced by pi itself rather than by convention. Both are combined
into pi's `--tools`, which is a hard ceiling — verified: a tool absent from it is missing from
the runtime entirely, and an extension cannot add it back. So a tool you did not list cannot be
called, misconfigured, or talked into existence by hostile input reaching the model.

`agent-mcp tools` prints the `<server>__<tool>` names to put in `allow:`.

Start from the smallest set that works. Widening a job later is a one-line change; noticing
that it was too wide usually is not.

### `bash` is not one more tool

Every other name in `tools:` widens the surface by one thing. `bash` ends the idea of a
surface, and it does so for the whole container rather than for this job:

- `/app/bin` is on `PATH` for everything a run spawns, so `agent-run` is reachable.
- `agent-run` re-derives the credential from `/data/.env` itself. It does not need anything
  its parent was given.

So a job that declares `bash` can start *any other job* — and get that job's tools, including
the mutating ones its own `allow:` deliberately withheld. The propose/commit split below stops
being a guarantee the moment either half has a shell.

The harness refuses the nesting: `agent-run` exits `11` when it is called from inside a run.
That closes the *accident* — and only that. The guard is one environment variable, so a shell
that means to nest can `unset AGENT_RUN_ID` and nest, and there is no way from in here to tell
an injected instruction from a deliberate one. It does not make `bash` safe in any other sense
either: a shell reads every file in the volume, including `/data/.env`, inherits the provider
credential from the process it runs under, and reaches every network the container reaches.
Treat one line as the whole security review of a job:

```
tools: read, write, bash
                   ^^^^ this is the review
```

Most jobs that seem to need a shell do not. A command that must run **after** the agent belongs
in `verify:`, and a fork's own checkers belong in its `bin/` — both run in the harness, outside
the model's reach, which is the point.

## The contract: what it must have done

The tool ceiling bounds the damage. It cannot tell you the work happened — an agent that reads
everything, writes a confident summary and produces nothing still exits 0. That is the failure
`AGENTS.md` calls the worst kind, and these three fields are how the harness catches it instead
of the client catching it.

| | |
|---|---|
| `requires:` | paths that must exist **before** the run. Missing → exit `10`, before any model call, so it costs nothing. |
| `produces:` | paths that must exist, be non-empty, and have been **written during this run**. |
| `verify:` | a command run afterwards with the run directory as its argument. Non-zero fails the run. |

A failed contract is exit **`31`** — "claimed to be done, but was not". It is deliberately not
`30` (produced nothing at all): `30` is usually the provider, `31` is the agent.

Freshness is the part of `produces:` that earns its keep. Last week's report still sitting on
disk makes a run that did nothing look successful. If a job's output legitimately may not
change, say so with a `verify:` command instead of `produces:`.

`verify:` is where a vertical puts real checks — schemas, invariants, row counts, totals. A
fork ships its checkers in its own `bin/`, next to its jobs. Anything expressible as a command
is expressible here, which is why there is no invariant syntax to learn.

## The pattern: propose, then commit

For anything that changes a client's system, use two jobs rather than one careful one:

```
propose.md    tools: read, write      allow: <server>__list_*     produces: work/plan.md
commit.md     tools: read             allow: <server>__<mutate>   requires: work/plan.md
```

The propose job **cannot** touch the outside system — not because it was told not to, but
because the mutating tool does not exist in its runtime. No prompt injection, no
misunderstanding and no model error can change that. What it writes is inspectable before
anything happens, and `requires:` means the commit job cannot run against a plan that was never
written.

This is worth more than a confirmation step, because it does not depend on anyone reading the
confirmation.
