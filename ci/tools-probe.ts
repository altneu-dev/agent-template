/**
 * tools-probe — print the tool surface a run would actually have, then stop.
 *
 * Loaded with -e in CI. It fires on session_start, which happens BEFORE any model request,
 * so the guardrail can be asserted without credentials, without network, and without cost.
 * That is what makes "the agent only has the tools its job declared" a test rather than a
 * claim.
 */
export default function (pi: any) {
  pi.on("session_start", async (_e: any, ctx: any) => {
    console.error("TOOLPROBE:" + JSON.stringify(pi.getActiveTools()));
    ctx.shutdown();
  });
}
