# Deploying this agent

Onto a client's own server, from the repo, in about ten minutes. Coolify is assumed; Dokploy
is the same and plain `docker compose up` works unchanged.

## What you need

- A fork of this repo with `agent/context/`, `agent/jobs/` and (if it reaches anything)
  `agent/mcp/` filled in.
- A server running Coolify — the client's own box, or a Hetzner instance.
- One provider API key. There is no browser step anywhere in this deploy.

## 1. Create the resource

**New Resource → Docker Compose**, connect the repo and branch, compose path `/compose.yml`,
Deploy.

No domain and no port: this agent reaches out, nothing reaches in. Coolify will note that no
domain is configured — that is correct for a worker, not a problem to fix.

## 2. Set the variables

Paste the names marked `<required>` in `.env.example`. Everything else has a working default
and can be left alone.

A vertical's own variables go in the single `AGENT_ENV` field, as `NAME=value` lines:

```
AGENT_ENV=HELPDESK_STORE=/data/work/tickets.json
          HELPDESK_TOKEN=...
```

They live in one field because a platform only passes variables that `compose.yml` names, and
`compose.yml` is frozen against verticals. If the client would rather their credentials never
touch the platform's database, the alternative is `/data/.env` inside the volume — invisible
to the UI, and rotating a value means opening a terminal in the container.

## 3. Verify it landed — two minutes, once

Coolify → Terminal, or `docker exec -it <container> bash`:

```bash
agent-status --memory      # record the volume id. It must never change.
agent-secret check         # "all N required variable(s) are set"
agent-run --list           # the jobs this deployment defines
agent-run <job> --probe-tools   # the tool surface, from pi itself. Costs nothing.
agent-status --health      # ok
```

`--probe-tools` is worth running even when you are confident: it asks pi what the job can
actually do, rather than what the job file says it should.

Then confirm the platform did not quietly drop a guardrail while rewriting the compose file:

```bash
docker inspect <container> --format '{{.HostConfig.Memory}} {{.HostConfig.PidsLimit}} {{.HostConfig.ReadonlyRootfs}}'
# want: 2147483648 512 true
```

## 4. Prove it keeps its memory — deploy twice

**This is the step that matters, and one deploy cannot do it.** A wiped `/data` and a healthy
one look identical from inside: the layout is recreated either way, and an agent with no
memory looks exactly like an agent that has not learned anything yet.

Before redeploying:

```bash
kb add "deploy check" <<< "written before the second deploy"
kb index
agent-status --memory        # note the volume id, boots and builds
```

Now push a trivial commit (or press Redeploy) and wait for healthy — allow 30–60 seconds for
the healthcheck's start period. Then:

```bash
agent-status --memory        # SAME volume id; boots >= 2; builds >= 2;
                             # verdict must name the redeploy, not just a restart
kb search "deploy check"     # the note written before the redeploy is still there
```

Both checks matter and they test different things: `--memory` reports the evidence, `kb`
exercises the real memory path — the FTS5 index living in the volume. Evidence surviving
while the knowledge base is corrupt is a different fault, and you want to see it.

**Do not put a client's work on a deployment that has not passed this.**

## 5. If the volume id changed, or it says NOT persisting

The agent is running on a different volume than before. Work through this in order:

1. **Coolify → Storages** — is anything mounted at `/data` at all?
2. `docker inspect <container> --format '{{json .Mounts}}'` — is `/data` a `volume` mount, and
   what is its name?
3. `docker volume ls` — is there a second, now-orphaned volume with a similar name? A changed
   prefix means the **resource** was recreated rather than redeployed. Use Redeploy; never
   delete and re-add the resource.
4. **Server → Docker Cleanup** — make sure it cannot prune volumes. The gap between the old
   container going away and the new one starting is exactly when the volume is unused.

**Recovery:** the old data is usually orphaned rather than gone. Stop the resource, copy the
old volume into the new one with a throwaway container, and re-verify:

```bash
docker run --rm -v <old>:/from -v <new>:/to alpine sh -c 'cp -a /from/. /to/'
```

## 6. Back it up

Detection is what this repo can give you; it cannot stop a platform from losing a volume.
A host-side cron is the part that makes the failure survivable:

```bash
0 3 * * * docker run --rm -v <volume>:/data -v /opt/backups:/out alpine \
            tar czf /out/agent-$(date +\%F).tgz -C /data .
```

Keep it off the same disk as the data. A backup that dies with the machine is a copy, not a
backup.

## 7. Running jobs on a schedule

Coolify → Scheduled Tasks, container command `agent-run <job>`. Exit codes are the interface:

| code | meaning | what a scheduler should do |
|---|---|---|
| 0 | ran, produced a result | nothing |
| 10 | misconfigured — **nothing was run, nothing spent** | alert; never retry, the config is wrong |
| 11 | another run of this job is in progress | ignore |
| 20 | provider or auth error | alert; do not retry |
| 21 | provider busy or rate limited | retry later |
| 22 | timed out | alert |
| 30 | ran but produced no result | alert |

Host cron with `docker exec` works identically if you would rather not depend on the
platform's scheduler.

## 8. Day two

- **Rotate a secret:** change it in the UI → Redeploy → `agent-secret check`.
- **Upgrade:** `git push`. `/app` is replaced, `/data` is not.
- **Read-only rootfs:** only `/data` and `/tmp` are writable. `apt install` in a terminal will
  fail; that is the design, not a fault.
- **Watch cost:** `agent-status` shows per-run cost and a total. A real number in week one is
  worth more than an estimate.

### Never do these

- **Rename the service key or the volume key in `compose.yml`.** The platform derives the real
  volume name from them; a rename orphans every existing deployment's memory.
- **Add `name:` or `external: true` to the volume.** Coolify ignores both (issue #3954), so
  they read as a guarantee that is not there.
- **Delete and re-add the resource** to change a setting. New resource, new UUID, new volume,
  no memory. Redeploy instead.
- **Enable volume pruning** on the server.

## Dokploy, and plain Docker

Dokploy reads the same `compose.yml` and the same caveats apply — it also derives volume
names. On a bare server with no platform at all:

```bash
git clone <fork> && cd <fork>
cp .env.example .env    # fill in the <required> values
docker compose up -d --build
```

The verification in sections 3 and 4 is identical, and the volume is yours to name.
