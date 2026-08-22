/**
 * escalate — give the agent a way to stop and ask, instead of improvising.
 *
 * agent/AGENTS.md tells the agent to escalate rather than guess when a task falls outside what
 * context/ describes. Until this existed, that instruction had no mechanism behind it: there
 * was no channel, so "stopped and escalated" and "silently did nothing" produced exactly the
 * same run — exit 0, no artefacts, a polite summary. The one behaviour you most want to
 * encourage was the one you could not distinguish from the one you least want.
 *
 * Calling this writes a request to work/escalations/ and marks the run. agent-run turns that
 * marker into exit 32 and fires AGENT_RUN_ALERT_CMD, so a scheduler sees a deliberate stop
 * rather than a success.
 *
 * IT IS A DECLARABLE TOOL, like every other. A job that wants it lists `escalate` in `tools:`.
 * Making it implicit would have been one word shorter in a job file and would have punched a
 * hole in the single claim this repo rests on: that a job's declaration is the whole truth
 * about what the agent can do. A tool that appears without being declared is exactly the class
 * of surprise the --tools ceiling exists to make impossible.
 */
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const DIR = process.env.AGENT_ESCALATION_DIR ?? "";
const MARKER = process.env.AGENT_ESCALATION_MARKER ?? "";
const RUN_ID = process.env.AGENT_RUN_ID ?? "";
const JOB = process.env.AGENT_JOB ?? "";

export default async function (pi: any) {
  pi.registerTool({
    name: "escalate",
    label: "escalate to a human",
    description:
      "Stop and hand this to a person. Use when the task is outside what context/ describes, " +
      "when the instructions conflict, when acting would need a judgement nobody delegated to " +
      "you, or when you would otherwise have to guess at something that matters. Preferred " +
      "over improvising. Calling this ends the run: say what you need decided, and stop.",
    parameters: {
      type: "object",
      properties: {
        reason: {
          type: "string",
          description: "One line: what decision is needed, and why you cannot make it.",
        },
        detail: {
          type: "string",
          description: "What you found, what you already did, and what you were about to do.",
        },
      },
      required: ["reason"],
    },
    async execute(_id: string, params: Record<string, unknown>) {
      const reason = String(params?.reason ?? "").trim() || "(no reason given)";
      const detail = String(params?.detail ?? "").trim();
      const utc = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");

      if (DIR) {
        try {
          mkdirSync(DIR, { recursive: true });
          // 0600: an escalation quotes whatever the agent was looking at when it stopped,
          // which is usually the most sensitive thing it saw all run.
          writeFileSync(
            join(DIR, `${utc}-${RUN_ID || "norun"}.json`),
            JSON.stringify({ utc, run: RUN_ID, job: JOB, reason, detail }, null, 2) + "\n",
            { mode: 0o600 },
          );
        } catch (err: any) {
          console.error(`escalate: cannot write the escalation: ${err?.message ?? err}`);
        }
      }

      // The marker is what agent-run reads. Written separately and last: if the request above
      // failed to land, the run must still be reported as an escalation rather than quietly
      // succeeding — the exit code is the part a scheduler acts on.
      if (MARKER) {
        try {
          mkdirSync(dirname(MARKER), { recursive: true });
          appendFileSync(MARKER, reason + "\n", { mode: 0o600 });
        } catch (err: any) {
          console.error(`escalate: cannot mark the run as escalated: ${err?.message ?? err}`);
        }
      }

      // What this says to the model is a claim about the world, so it has to be one this
      // extension can actually make. "A human has been notified" was not: notifying happens
      // in agent-run, after this returns, and only if the deployment has an alert path that
      // works. In a deployment with none it was simply false — and a model told its question
      // has reached someone has no reason to phrase it as if it might not have.
      return {
        content: [{
          type: "text",
          text: "Escalated. The request has been recorded for a human and this run is over. " +
                "Do not attempt the task another way, and do not continue: stop here.",
        }],
      };
    },
  });
}
