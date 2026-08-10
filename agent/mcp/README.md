# mcp/

Which outside systems this agent may reach. One JSON file per connection.

```json
{
  "mcpServers": {
    "example": {
      "command": "npx",
      "args": ["-y", "@vendor/example-mcp"],
      "env": { "EXAMPLE_TOKEN": "${EXAMPLE_TOKEN}" }
    }
  }
}
```

**Reference variables, never values.** `${VAR}` and `${VAR:-default}` are resolved at launch
from the environment or a mounted secrets file, into a config written to container-local
memory at mode 0600. A literal token here would be committed to the repository and baked
into the image layer — permanently, including after it is deleted.

Every `${VAR}` used here must also appear in `.env.example`. A variable that is referenced
but not set stops the agent **before it starts**, naming what is missing, rather than
surfacing later as an authentication error inside a run.

## Which tools the agent actually gets

This file says *which servers exist*. A job's `allow:` line says *which of their tools the
agent may use* — and that is the guardrail, because those names go into pi's `--tools`,
which is a hard ceiling: a tool missing from it does not exist for the run, and no extension
can add it back.

So a third-party server growing a destructive tool in some future release does not silently
reach your agent: it is not in `allow:`, so it is never registered.

```bash
agent-mcp tools     # <server>__<tool> per line — paste the ones you want into allow:
```

A job with `mcp:` but no `allow:` gets every tool its servers offer, and says so loudly on
every run. That is fine while building a job and wrong for a deployment: an explicit list
does not change when a server is upgraded.

Check your wiring without starting an agent:

```bash
agent-mcp check     # what is defined, which variables it needs, where each value came from
agent-mcp probe     # start each server and list the tools it actually offers
agent-mcp print     # the merged config, with secret values redacted
```
