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
import { appendFileSync } from "node:fs";
import { createHash, randomUUID } from "node:crypto";

const CONFIG = process.env.AGENT_MCP_CONFIG ?? "";
const SERVERS = (process.env.AGENT_MCP_SERVERS ?? "").split(/\s+/).filter(Boolean);
const ALLOW = new Set(
  (process.env.AGENT_MCP_ALLOW ?? "").split(",").map((s) => s.trim()).filter(Boolean),
);
const CALL_TIMEOUT_MS = Number(process.env.AGENT_MCP_CALL_TIMEOUT_MS ?? 120_000);

/* ---------------------------------------------------------------- the action ledger
 *
 * Every external effect this deployment has goes through callTool below. That is not a
 * convention: built-in tools cannot leave the container, so an MCP call is the only way for
 * anything to reach a client's systems. The ledger is therefore complete by construction
 * rather than by diligence — there is no code path that could change something without
 * passing through here.
 *
 * `agent-status` shows runs. After an incident the question is not "what ran" but "what did
 * it change", and runs.jsonl cannot answer that.
 *
 * TWO LINES PER CALL, on purpose. The `start` line is written BEFORE the call and, if it
 * cannot be written, the call is refused — an effect that cannot be recorded must not happen,
 * and at that moment it still hasn't. The `end` line records the outcome. A `start` with no
 * `end` is the case worth being able to see: something was sent to a client's system and we
 * do not know whether it landed.
 *
 * Argument VALUES are not recorded. They are the payload that reaches the client's systems and
 * routinely carry personal data; a log at 0600 in a volume that gets backed up is the wrong
 * home for it. Keys and a digest of the values are enough to answer "was this the same call
 * twice" and "which record did it touch", which is what an audit actually asks.
 * AGENT_EFFECTS_VERBOSE=1 opts into full arguments while building a vertical.
 */
const EFFECTS = process.env.AGENT_EFFECTS_LOG ?? "";
const EFFECTS_VERBOSE = process.env.AGENT_EFFECTS_VERBOSE === "1";
const RUN_ID = process.env.AGENT_RUN_ID ?? "";
const JOB = process.env.AGENT_JOB ?? "";

function digestOf(args: Record<string, unknown>): string {
  try {
    return createHash("sha256").update(JSON.stringify(args)).digest("hex").slice(0, 12);
  } catch {
    return "undigestible";
  }
}

/** Returns false when the line could not be written. Never throws: the caller decides what a
 *  failed write means, and that differs between the two phases. */
function record(entry: Record<string, unknown>): boolean {
  if (!EFFECTS) return true;            // no ledger configured (a probe, or a bare pi run)
  // The compact stamp the rest of the volume uses (boots.jsonl, runs.jsonl), so the two can be
  // read side by side and compared as strings.
  const utc = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  try {
    appendFileSync(EFFECTS, JSON.stringify({ utc, ...entry }) + "\n", { mode: 0o600 });
    return true;
  } catch (err: any) {
    console.error(`mcp-tools: cannot write the action ledger: ${err?.message ?? err}`);
    return false;
  }
}

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
          const args = params ?? {};
          const call = randomUUID().slice(0, 12);

          const opened = record({
            phase: "start", call, run: RUN_ID, job: JOB, server, tool: tool.name,
            arg_keys: Object.keys(args).sort(),
            args_digest: digestOf(args),
            ...(EFFECTS_VERBOSE ? { args } : {}),
          });
          if (!opened) {
            // Refused, not degraded. The effect has not happened yet, and an effect nobody can
            // account for afterwards is worse than a failed tool call the model can react to.
            throw new Error(
              `refusing to call ${server}__${tool.name}: the action ledger is not writable, ` +
              `so this change could not be accounted for afterwards`,
            );
          }

          const started = Date.now();
          try {
            const result = await runtime.callTool(server, tool.name, {
              args,
              timeoutMs: CALL_TIMEOUT_MS,
              disableOAuth: true,
            });
            record({ phase: "end", call, outcome: "ok", ms: Date.now() - started });
            return { content: toContent(result) };
          } catch (err: any) {
            // A failed call still changed something often enough to matter — a timeout says
            // nothing about whether the far side committed. Recorded, then re-thrown unchanged
            // so the model sees exactly what it would have seen.
            record({
              phase: "end", call, outcome: "error", ms: Date.now() - started,
              error: String(err?.message ?? err).slice(0, 300),
            });
            throw err;
          }
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
