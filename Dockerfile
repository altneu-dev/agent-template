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
RUN chmod +x /app/bin/*

# /data is a mountpoint. Creating it here with the right owner means the container also
# works with no volume attached at all — useful for CI and for `docker run` smoke tests.
RUN mkdir -p /data && chown "${AGENT_UID}:${AGENT_GID}" /data

ENV AGENT_APP=/app \
    AGENT_DATA=/data \
    HOME=/data \
    PATH=/app/bin:$PATH \
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
