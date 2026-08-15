# The agent image: a harness, its tools, and nothing about any particular domain.
#
# Two directories matter and the split is the whole design:
#
#   /app    repo content — AGENTS.md, context, skills, jobs, mcp definitions, extensions.
#           Replaced wholesale on every deploy. Never written to at runtime.
#   /data   the volume — knowledge notes, run logs, work area, pi sessions.
#           Survives redeploys. This is the agent's memory.
#
# A `git push` changes /app. Nothing a push does can lose /data.
FROM node:22-slim

# Versions are pinned so two deployments of one commit are the same agent. `@latest` here
# would mean a client's agent silently changes behaviour on an unrelated redeploy.
ARG PI_VERSION=0.84.1
ARG MCPORTER_VERSION=0.13.2

# uid/gid are build args rather than literals: OpenShell and some platforms expect a
# specific non-root uid, and hard-coding one makes the image unusable there. 1000 is the
# common default.
ARG AGENT_UID=1000
ARG AGENT_GID=1000

# python3  — bin/agent-mcp and bin/kb parse JSON/JSONC and drive SQLite through it
# sqlite3  — the knowledge base (FTS5)
# iproute2 — required by OpenShell for network-namespace management; also the only way to
#            answer "what can this container actually reach" from inside
# ripgrep  — the agent's own search tool
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git jq python3 ripgrep sqlite3 iproute2 tini \
 && rm -rf /var/lib/apt/lists/*

# pi is global: it is the runtime, invoked as a command.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force

# mcporter is a LOCAL dependency of /app, not a global one. pi resolves an extension's
# imports from the node_modules beside it, so a global install would leave the extension's
# `import { createRuntime } from "mcporter"` unresolvable — and only at the moment a job
# first declared an MCP server, which is the worst time to find out.
WORKDIR /app
COPY package.json package-lock.json* /app/
RUN npm install --omit=dev --ignore-scripts --no-audit --no-fund \
 && npm cache clean --force \
 && test -d /app/node_modules/mcporter

# node:22-slim already ships uid/gid 1000 as `node`. Reuse it when the args match, create a
# new account when they do not, so any uid works without a conditional mess at run time.
RUN if [ "${AGENT_GID}" != "1000" ]; then groupadd -g "${AGENT_GID}" agent; fi \
 && if [ "${AGENT_UID}" != "1000" ]; then \
      useradd -u "${AGENT_UID}" -g "${AGENT_GID}" -m -s /bin/bash agent; \
    fi

COPY bin/ /app/bin/
COPY agent/ /app/agent/
COPY knowledge/ /app/knowledge/
# The deploy checklist. Without it in the image, agent-secret cannot say what this
# deployment requires, so preflight passes on a container that is not configured at all and
# the exit-10 promise ("nothing was run and nothing was spent") never fires.
COPY .env.example /app/.env.example
RUN chmod +x /app/bin/*

# A build identity, so a deployment can tell a restart from a redeploy.
#
# A content digest, deliberately not a timestamp: a `date` in a RUN is frozen by the layer
# cache when nothing changed and thawed by an unrelated change, so it reports difference
# exactly when there is none. A digest changes when — and only when — the thing a deploy
# replaces changes. The pinned versions fold in, so bumping pi counts as a redeploy too.
RUN set -e; \
    { find /app -path /app/node_modules -prune -o -type f -print0 \
        | LC_ALL=C sort -z | xargs -0 sha256sum; \
      echo "pi=${PI_VERSION} mcporter=${MCPORTER_VERSION}"; } \
    | sha256sum | cut -c1-12 > /app/.build-id

# PATH twice over, because the two ways in resolve it differently. `ENV PATH` covers direct
# exec (`docker compose exec agent agent-status`). A LOGIN shell — which is what you get from
# `docker compose exec agent bash -l`, the natural way to look around inside a deployment —
# rebuilds PATH from /etc/profile and drops it again. Without this line the commands are
# missing in exactly the situation where a human is looking for them, on an image that is
# otherwise healthy.
RUN printf 'PATH=/app/bin:$PATH\n' > /etc/profile.d/10-agent-path.sh

# /data is a mountpoint. Creating it here with the right owner means the container also
# works with no volume attached at all — useful for CI and for `docker run` smoke tests.
RUN mkdir -p /data && chown "${AGENT_UID}:${AGENT_GID}" /data

# NODE_OPTIONS caps V8's old space, because nothing else will. Node is not cgroup-aware: it
# sizes the heap from /proc/meminfo, which reports the HOST's RAM, so inside a 2 GiB
# container it still plans for a ~1 GB heap and refuses to collect below it. That is one
# process; a session is several (pi, its MCP servers, the tools they spawn), all charged to
# one cgroup, so one long transcript is enough to reach the limit. The kernel then resolves
# it with SIGKILL — no stack, no log line, `docker ps` still green.
#
# The cap is not about saving memory. It converts a silent kill into a catchable JS heap
# error, which is the difference between a run that reports failure and a container that
# quietly restarts a loop. Raising mem_limit alone does not fix it; it moves the wall.
#
# 768 MB against compose.yml's 4g leaves room for the sibling processes and the young
# generation. Change it together with mem_limit, never on its own. As an ENV rather than a
# shell profile it also reaches `docker exec` without `-l`, which is how most tooling and
# every healthcheck enters the container.
ENV AGENT_APP=/app \
    AGENT_DATA=/data \
    HOME=/data \
    PATH=/app/bin:$PATH \
    NODE_OPTIONS=--max-old-space-size=768 \
    PI_CODING_AGENT_DIR=/data/.pi/agent

USER ${AGENT_UID}:${AGENT_GID}
WORKDIR /data
VOLUME ["/data"]

# Reports unhealthy when the last run failed. A container whose agent is broken but whose
# process is alive is the failure mode worth catching — "the process is up" is not health.
HEALTHCHECK --interval=60s --timeout=10s --start-period=20s --retries=2 \
  CMD agent-status --health || exit 1

# tini reaps the MCP server subprocesses pi spawns; without an init, killed servers become
# zombies and eventually hit the pid limit.
#
# agent-init runs here AND is callable on its own, because a platform supervisor may replace
# the start command (OpenShell does). Anything load-bearing that only ever ran from an
# entrypoint would silently not run there.
ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/agent-entrypoint"]
CMD ["idle"]
