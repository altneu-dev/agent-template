/**
 * mcp-tools — give the agent exactly the outside-system tools its job declared, and no others.
 *
 * Pi has no MCP of its own. This extension is the bridge: it reads the config that
 * `agent-mcp render` produced (with ${VAR} already resolved from the deployment's secrets),
 * asks each declared server what it offers, and registers those tools with pi.
 *
 * WHAT THIS DOES NOT DO — and must not:
 *
 *   It does not discover servers. It reads AGENT_MCP_SERVERS, which agent-run sets from the
 *   job's `mcp:` line. A server the job did not name is never contacted.
 *
 *   It does not widen the tool surface. Verified against pi 0.84: when `--tools` is set, a
 *   tool absent from that list is not merely inactive — it is absent from getAllTools(), and
 *   setActiveTools() cannot add it back. `--tools` is a ceiling this extension cannot
 *   escape, which is exactly the property that makes the job file the single source of truth
 *   about what an agent may do. Registering a tool here is a request, not a grant.
 *
 * Tool naming is `<server>__<tool>`, and agent-run puts those same names into `--tools`. If
 * the two ever disagree the tool simply does not exist for that run — a failure that is
 * visible and safe, rather than an unintended capability.
 */
import { createRuntime, type Runtime, type ServerToolInfo } from "mcporter";

const CONFIG = process.env.AGENT_MCP_CONFIG ?? "";
const SERVERS = (process.env.AGENT_MCP_SERVERS ?? "").split(/\s+/).filter(Boolean);
const ALLOW = new Set(
  (process.env.AGENT_MCP_ALLOW ?? "").split(",").map((s) => s.trim()).filter(Boolean),
);
const CALL_TIMEOUT_MS = Number(process.env.AGENT_MCP_CALL_TIMEOUT_MS ?? 120_000);

/** MCP servers describe parameters as JSON Schema; pi wants a schema object too. Passing it
 *  through unchanged keeps the server's own contract intact — rewriting it would silently
 *  change what the model is told a tool accepts. */
function schemaOf(tool: ServerToolInfo): unknown {
  const s = tool.inputSchema;
  if (s && typeof s === "object") return s;
  return { type: "object", properties: {} };
}

/** MCP returns loosely-typed content. Anything not already pi-shaped becomes text, so a
 *  server returning something unexpected degrades to a readable result instead of an error. */
function toContent(result: unknown): Array<{ type: "text"; text: string }> {
  if (result && typeof result === "object" && Array.isArray((result as any).content)) {
    const parts = (result as any).content
      .filter((p: any) => p && typeof p === "object")
      .map((p: any) => (typeof p.text === "string" ? p.text : JSON.stringify(p)))
      .filter(Boolean);
    if (parts.length) return [{ type: "text", text: parts.join("\n") }];
  }
  return [{ type: "text", text: typeof result === "string" ? result : JSON.stringify(result ?? null) }];
}

export default async function (pi: any) {
  if (!CONFIG || SERVERS.length === 0) return;   // no MCP for this job: nothing to do

  let runtime: Runtime;
  try {
    runtime = await createRuntime({
      configPath: CONFIG,
      clientInfo: { name: "agent-template", version: "1" },
    });
  } catch (err: any) {
    // Loud, because the alternative is an agent that starts happily and then cannot do the
    // one thing its job exists for.
    console.error(`mcp-tools: cannot start the MCP runtime: ${err?.message ?? err}`);
    return;
  }

  let registered = 0;
  for (const server of SERVERS) {
    let tools: ServerToolInfo[];
    try {
      // disableOAuth: nobody is at a browser. A server needing interactive authorisation
      // must fail here, at startup, rather than hang a scheduled run to its timeout.
      tools = await runtime.listTools(server, { includeSchema: true, disableOAuth: true });
    } catch (err: any) {
      console.error(`mcp-tools: server "${server}" did not answer: ${err?.message ?? err}`);
      continue;
    }

    for (const tool of tools) {
      const name = `${server}__${tool.name}`;
      if (ALLOW.size > 0 && !ALLOW.has(name)) continue;

      pi.registerTool({
        name,
        label: `${server}: ${tool.name}`,
        description: tool.description ?? `${tool.name} on ${server}`,
        parameters: schemaOf(tool),
        async execute(_id: string, params: Record<string, unknown>, signal?: AbortSignal) {
          if (signal?.aborted) throw new Error("cancelled");
          const result = await runtime.callTool(server, tool.name, {
            args: params ?? {},
            timeoutMs: CALL_TIMEOUT_MS,
            disableOAuth: true,
          });
          return { content: toContent(result) };
        },
      });
      registered++;
    }
  }

  // One line, on stderr, into the run's record: which tools this run actually had. A run
  // that behaved oddly is otherwise impossible to reconstruct after the fact.
  console.error(
    `mcp-tools: ${registered} tool(s) from ${SERVERS.length} server(s): ${SERVERS.join(", ")}`,
  );

  pi.on("session_shutdown", async () => {
    try {
      await runtime.close();
    } catch {
      /* the process is ending anyway; a failure to close cleanly must not mask the result */
    }
  });
}
