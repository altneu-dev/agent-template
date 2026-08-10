# agent-template

A deployable agent in one repository. Fork it, describe what the agent is for, point a
platform at it. What arrives is the whole package: harness, tools, guardrails, memory and
observability — not a runtime you then have to assemble.

## Deploy

```bash
# 1. fork this repo, then fill in the four things a vertical is made of:
#      agent/context/   what this agent is for
#      agent/jobs/      the tasks it performs
#      agent/mcp/       the outside systems it may reach   (optional)
#      agent/skills/    knowledge it loads on demand       (optional)

# 2. point Coolify / Dokploy at the repo, paste the variables from .env.example, deploy.
#    Or, on any Linux box with Docker:
docker compose up -d --build

# 3. check it landed
docker compose exec agent agent-secret check     # is it configured?
docker compose exec agent agent-run --list       # what can it do?
docker compose exec agent agent-run <job>        # do it
docker compose exec agent agent-status           # what has it been doing?
```

`git push` redeploys. Nothing a push does can lose the agent's memory.

## The two halves

| | |
|---|---|
| **`/app`** | the repo — context, jobs, skills, mcp definitions, the harness. Replaced entirely on every deploy. |
| **`/data`** | the volume — knowledge notes, run logs, work area, sessions. **This is the memory. It survives redeploys.** |

`agent-init` links the first into the second, so a deploy updates the agent's instructions
without touching anything it has learned.

## Guardrails

The rule is not *restrict what the agent may do*. It is: **the agent only ever has the tools
its job declared.**

A job names its built-in tools in `tools:` and its MCP tools in `allow:`. Both go into pi's
`--tools`, which is a hard ceiling — verified against pi 0.84: a tool absent from it is
missing from the runtime entirely, and an extension cannot add it back. So a tool you did not
list cannot be called, cannot be misconfigured, and cannot be talked into existence by
hostile input reaching the model.

That makes the strongest guardrail free: **do not give the agent the dangerous tool.** A
support agent that ships a ticket server with no `delete_ticket` cannot delete a ticket in
any failure mode, including prompt injection, with no runtime policy engine involved.

```bash
agent-run <job> --probe-tools    # ask pi what this job really gets. Costs nothing.
agent-mcp probe                  # start each server and list what it actually offers
```

Containers bound the blast radius; the tool surface bounds the capability. They are different
layers and neither substitutes for the other — a perfectly isolated container holding valid
credentials can still misuse them.

## Observability

Files in the volume, read on demand. No daemon, no port, nothing published.

```bash
agent-status                  # recent runs: when, how long, cost, outcome, why it failed
agent-status --health         # exit 1 if the last run of any job failed (the HEALTHCHECK)
agent-status --json           # for a host-side check
```

Every run writes `logs/runs.jsonl` (one line), `logs/runs/<job>/last.json`, and a per-run
directory at mode 0700 holding the prompt, the full result stream and stderr. Retention is
capped by `AGENT_RUN_KEEP`, because run records hold whatever the agent read.

Exit codes are the scheduler's interface — `10` means the deployment is misconfigured and
**nothing was spent**, `20` is a credential fault that must not be retried, `21` is a busy
provider that should be.

## Adding a vertical

Four directories and a variable list. Nothing in `bin/`, `agent/extensions/`, `Dockerfile` or
`compose.yml` should ever need to change — and `ci/universality-test.sh` fails the build if it
does. Two worked examples live in `examples/`, deliberately opposite in shape: one is MCP-only
with no file access at all, the other uses only built-in tools and reaches nothing.

```bash
ci/universality-test.sh   # installs each example and asserts the framework was untouched
```

## What is inside

| | |
|---|---|
| `pi` | the agent runtime, pinned |
| `mcporter` | MCP client, a local dependency so extension imports resolve |
| `agent-init` | prepares `/data`; idempotent, and callable outside the entrypoint |
| `agent-run` | runs one job unattended: preflight, lock, artefacts, exit codes |
| `agent-mcp` | resolves `${VAR}` from secrets into an MCP config, 0600, in tmpfs |
| `agent-secret` | reads one value from env or file — parsed, never sourced |
| `agent-status` | what the agent has been doing |

Secrets are read one at a time and reach the model process through its own environment only —
never `--api-key` (which would put them in `ps`), never a wholesale `source` (which would put
them in every descendant's `/proc/<pid>/environ`).
