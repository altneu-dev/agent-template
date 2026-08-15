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

`git push` redeploys. Nothing a push does can lose the agent's memory — and the deployment
can prove that itself, which matters because a platform that silently recreated the volume
would look identical to a healthy one:

```bash
docker compose exec agent agent-status --memory
```

**[DEPLOY.md](DEPLOY.md)** is the runbook: Coolify steps, the variables, and the deploy-twice
check that is the only real proof of persistence.

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

**For anything that changes a client's system, use two jobs rather than one careful one.** A
*propose* job declares only read tools and `write`; it cannot touch the outside system in any
failure mode, including a successful prompt injection, because the mutating tool does not exist
in its runtime. A *commit* job declares the mutating tool and `requires:` the proposal. That is
worth more than a confirmation step, because it does not depend on anyone reading the
confirmation. `examples/helpdesk/` is the worked version.

The ceiling is per job, so the split holds only while a run cannot start another run. It
cannot: `agent-run` exits `11` when called from inside one. Without that, a job declaring
`bash` would reach `/app/bin/agent-run`, which is on `PATH` for everything a run spawns and
re-derives the credential from `/data/.env` on its own — and one shell in one job would hand
every job's tools to that job. `bash` in a `tools:` line is therefore the whole security review
of a job; `agent/jobs/README.md` says what it costs.

## Proof that the work happened

The tool ceiling bounds the damage. It cannot tell you the work was done — an agent that reads
everything, writes a confident summary and produces nothing still exits 0. So a job declares
what its work must leave behind, and the harness checks it:

```yaml
requires: work/plan.md               # must exist BEFORE the run — missing is exit 10, unspent
produces: work/reports/weekly.md     # must exist, be non-empty, and be written by THIS run
verify: check-refunds                # a command that must exit 0 afterwards
```

Freshness is the part that earns its keep: last week's report still on disk makes a run that
did nothing look successful. A failed contract is exit **`31`**, deliberately not `30` — a
scheduler must respond to them differently, because `30` is usually the provider and `31` is
the agent.

`verify:` is a command, not an invariant syntax to learn. A vertical ships its checkers in its
own `bin/`, so anything expressible as a command is expressible here.

And when a task falls outside what `context/` describes, the agent has somewhere to go: a job
that declares the `escalate` tool can stop and ask, which writes a request to
`work/escalations/`, fires the alert command and exits **`32`**. Before that, "escalated" and
"silently did nothing" produced identical runs.

## Observability

Files in the volume, read on demand. No daemon, no port, nothing published.

```bash
agent-status                  # recent runs: when, how long, cost, outcome, why it failed
agent-status --effects        # what it changed OUTSIDE the container
agent-status --ready          # exit 1 if this fork is not finished
agent-status --memory         # did /data survive the last redeploy? exit 1 if unproven
agent-status --health         # exit 1 if a job is failing NOW (the HEALTHCHECK)
agent-status --json           # for a host-side check
```

Every run writes `logs/runs.jsonl` (one line), `logs/runs/<job>/last.json`, and a per-run
directory at mode 0700 holding the prompt, the full result stream and stderr. Retention is
capped by `AGENT_RUN_KEEP`, because run records hold whatever the agent read.

**`--effects` is the one that matters after an incident.** Nobody asks what ran; they ask what
was touched, and `runs.jsonl` cannot answer that. Every external effect is an MCP call — built-in
tools cannot leave the container — so `logs/effects.jsonl` is complete by construction rather
than by diligence. It records two lines per call: an effect whose *start* cannot be written is
refused rather than performed, and a start with no end is shown as `UNFINISHED`, because
"we sent it and do not know whether it landed" is a different fact from "it failed". Argument
values are not stored; keys and a digest are. It is never trimmed — an audit trail that rotates
is not one.

`--ready` catches the other silent failure: a half-filled fork deploys, reports healthy, and
idles politely forever. It names what is missing, and the idle container prints it into the
platform's log tab. It is deliberately not part of `--health`, because a deployment nobody has
configured yet is not sick, and making it unhealthy would block the deploy that carries the
configuration.

Exit codes are the scheduler's interface — `10` means the deployment is misconfigured and
**nothing was spent**, `20` is a credential fault that must not be retried, `21` is a busy
provider that should be, `31` means it claimed to be done and was not, and `32` means it
stopped and asked for a human.

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
| `agent-status` | what the agent has been doing, changed, and whether it is finished |
| `kb` | the memory: FTS5 over `knowledge/`, `context/` and `work/`, plus a one-line-per-document index |

Notes are append-only, which is what makes concurrent writers safe — but a knowledge base that
can only accumulate will eventually quote a retired price back to a client as current. A new
note carrying `supersedes: <slug>` retires an old one: it drops out of `INDEX.md`, which is read
every run, while `kb search` still finds it and labels it as replaced.

The image ships no `curl` or `wget` — deliberately, and it surprises fork authors exactly once.
`git`, `jq`, `ripgrep`, `sqlite3` and `python3` are there. Outbound HTTP is node's `fetch`, or
a declared MCP server, which is the path that gets audited.

## About the provider key

`agent-secret` reads one value at a time and `agent-run` hands the credential to the model
process alone — never `--api-key` (which would put it in `ps`), never a wholesale `source`
(which would put it in every descendant's `/proc/<pid>/environ`).

**That care is undone if the key arrives as a platform environment variable**, which is the
default and what makes the deploy one click. A value in the container's config is readable by
every process in the container and by every `docker exec`, whatever the harness does with it
afterwards. This is not preventable while a platform injects configuration, so the deployment
reports it instead — `agent-secret check` names the source of every required variable and says
plainly when one is exposed this way.

`/data/.env` (mode 0600, inside the volume) avoids it entirely: read on demand, never exported,
never in the platform's database. The cost is that rotating a value means opening a terminal in
the container. Pick per client; `DEPLOY.md` §2 has both recipes.
