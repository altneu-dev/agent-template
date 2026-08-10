#!/usr/bin/env bash
# effects-test — prove the action ledger records every external effect, and refuses the ones
# it cannot record.
#
#   ci/effects-test.sh
#
# The ledger is the answer to "what did the agent change in our systems", which is the question
# asked after an incident and the one runs.jsonl cannot answer. Two properties have to hold or
# it is worse than nothing, because it would look complete while missing things:
#
#   1. every call through the extension leaves a start and an end line
#   2. a call whose start line cannot be written does not happen at all
#
# Driven by importing the real extension with a fake `pi` object and calling the tool it
# registers, against the helpdesk example's stub MCP server. No credentials, no model, no cost —
# the model is not involved in this code path at all.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok() { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
cp -r "$REPO"/{bin,agent,ci,knowledge,.env.example} "$WORK/" 2>/dev/null
cp -r "$REPO"/examples/helpdesk/agent/. "$WORK/agent/"
cp -r "$REPO"/examples/helpdesk/bin/.   "$WORK/bin/"
ln -s "$REPO/node_modules" "$WORK/node_modules"
mkdir -p "$WORK/data"
chmod +x "$WORK"/bin/*

export AGENT_APP="$WORK" AGENT_DATA="$WORK/data" AGENT_ENV_FILE="$WORK/data/.env"
export PATH="$WORK/bin:$PATH"
{ echo "ANTHROPIC_API_KEY=sk-ant-not-a-real-key"
  echo "HELPDESK_STORE=$WORK/data/work/helpdesk/tickets.json"
} > "$WORK/data/.env"

agent-init >/dev/null 2>&1 || { echo "agent-init failed"; exit 1; }
mkdir -p "$WORK/data/work/helpdesk"
cat > "$WORK/data/work/helpdesk/tickets.json" <<'JSON'
[{"id": 1, "subject": "Printer offline", "status": "open", "notes": []}]
JSON

MCP_CFG=$(AGENT_MCP_PID=$$ agent-mcp render) || { echo "agent-mcp render failed"; exit 1; }
export AGENT_MCP_CONFIG="$MCP_CFG"
export AGENT_MCP_SERVERS="helpdesk"
export AGENT_MCP_ALLOW="helpdesk__add_note,helpdesk__list_open"
export AGENT_RUN_ID="testrun00001" AGENT_JOB="commit"

# The harness: pi's extension contract is a default export taking an object with registerTool
# and on. Nothing here mocks the code under test — the extension, mcporter and the stub server
# are all real; only pi is replaced, because pi is what needs a model.
cat > "$WORK/harness.mjs" <<'JS'
import ext from "./agent/extensions/mcp-tools.ts";
const tools = new Map();
await ext({
  registerTool: (t) => tools.set(t.name, t),
  on: () => {},
});
const name = process.argv[2];
const tool = tools.get(name);
if (!tool) { console.error(`not registered: ${name} (have: ${[...tools.keys()]})`); process.exit(2); }
try {
  await tool.execute("call-1", JSON.parse(process.argv[3] ?? "{}"));
  console.log("CALL_OK");
} catch (err) {
  console.log("CALL_REFUSED:" + String(err?.message ?? err));
}
process.exit(0);
JS

cd "$WORK" || exit 1
LEDGER="$WORK/data/logs/effects.jsonl"

echo
echo "== a call is recorded, in two phases =="
export AGENT_EFFECTS_LOG="$LEDGER"
out=$(node --experimental-strip-types harness.mjs helpdesk__add_note \
        '{"id":1,"note":"routed to platform"}' 2>&1)
case "$out" in
  *CALL_OK*) ok "the tool ran through the extension" ;;
  *)         no "the call did not complete"; printf '%s\n' "$out" | sed 's/^/        /' | head -8 ;;
esac

starts=$(grep -c '"phase":"start"' "$LEDGER" 2>/dev/null || echo 0)
ends=$(grep -c '"phase":"end"'   "$LEDGER" 2>/dev/null || echo 0)
[ "$starts" = 1 ] && [ "$ends" = 1 ] \
  && ok "one start and one end line" \
  || no "expected 1 start and 1 end, got $starts and $ends"

python3 - "$LEDGER" <<'PY' && ok "the record identifies the run, job, server and tool" || no "the record is missing identifying fields"
import json, sys
s = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
start = next(e for e in s if e.get("phase") == "start")
end   = next(e for e in s if e.get("phase") == "end")
assert start["run"] == "testrun00001" and start["job"] == "commit", start
assert start["server"] == "helpdesk" and start["tool"] == "add_note", start
assert start["arg_keys"] == ["id", "note"], start
assert len(start["args_digest"]) == 12, start
assert end["call"] == start["call"] and end["outcome"] == "ok", end
assert isinstance(end["ms"], int), end
PY

echo
echo "== argument VALUES never reach the ledger =="
# They are the payload that reached the client's system, and this file lives in a volume that
# gets backed up. Keys and a digest answer what an audit actually asks.
if grep -q "routed to platform" "$LEDGER"; then
  no "an argument value was written to the ledger"
else
  ok "the note text is absent — only keys and a digest"
fi

AGENT_EFFECTS_VERBOSE=1 node --experimental-strip-types harness.mjs helpdesk__add_note \
  '{"id":1,"note":"verbose please"}' >/dev/null 2>&1
grep -q "verbose please" "$LEDGER" \
  && ok "AGENT_EFFECTS_VERBOSE=1 opts in, for building a vertical" \
  || no "AGENT_EFFECTS_VERBOSE=1 did not include the arguments"

echo
echo "== an effect that cannot be recorded does not happen =="
# The property the whole ledger rests on. Without it a full disk silently turns an audited
# deployment into an unaudited one, which is the worst of both.
before=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))[0]["notes"]))' \
         "$WORK/data/work/helpdesk/tickets.json")
export AGENT_EFFECTS_LOG="$WORK/data/logs/nowhere/effects.jsonl"   # unwritable: no such dir
out=$(node --experimental-strip-types harness.mjs helpdesk__add_note \
        '{"id":1,"note":"must never land"}' 2>&1)
case "$out" in
  *CALL_REFUSED*ledger*) ok "the call was refused, naming the ledger as the reason" ;;
  *CALL_REFUSED*)        ok "the call was refused" ;;
  *)                     no "the call was NOT refused with an unwritable ledger" ;;
esac
after=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))[0]["notes"]))' \
        "$WORK/data/work/helpdesk/tickets.json")
[ "$before" = "$after" ] \
  && ok "the ticket was not touched ($before note(s) before and after)" \
  || no "the refused call changed the ticket anyway: $before -> $after"

echo
echo "== the ledger proves the effect actually landed =="
# The ledger says a note was added; the store is where it either is or is not. Checking both
# is the point — a ledger that agrees with a server that did nothing is two records of the
# same lie.
python3 - "$WORK/data/work/helpdesk/tickets.json" <<'PY' && ok "the note reached the ticket store" || no "the ledger recorded a note the store never received"
import json, sys
t = json.load(open(sys.argv[1]))[0]
assert "routed to platform" in t["notes"], t
PY

echo
echo "== a failing call is recorded too =="
# A timeout says nothing about whether the far side committed, so a failure that left no trace
# would be the most dangerous gap of all. An unknown ticket id is a deterministic error from
# the server, rather than a timing race.
export AGENT_EFFECTS_LOG="$LEDGER"
node --experimental-strip-types harness.mjs helpdesk__add_note \
  '{"id":999,"note":"no such ticket"}' >/dev/null 2>&1
python3 - "$LEDGER" <<'PY' && ok "the failed call is in the ledger, with its error" || no "a failed call left no record"
import json, sys
ends = [json.loads(l) for l in open(sys.argv[1]) if '"phase":"end"' in l]
assert any(e.get("outcome") == "error" and e.get("error") for e in ends), ends
PY

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
