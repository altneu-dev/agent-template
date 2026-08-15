#!/usr/bin/env bash
# contract-test — prove the harness judges a run by what it produced, not by what it claimed.
#
#   ci/contract-test.sh
#
# Exit 0 used to mean "the model finished". A job can now declare what its work must leave
# behind, and agent-run checks it. That check is the difference between a client discovering a
# silent failure and a scheduler catching it, so it is asserted rather than assumed.
#
# Costs nothing and needs no credentials: `pi` is a test double from ci/fake-pi, placed on PATH
# by this script. agent-run has no test hook and cannot tell the difference — which is the
# point, because the code under test is the real code path.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok() { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$REPO"/{bin,agent,ci,knowledge,.env.example} "$WORK/" 2>/dev/null
[ -d "$REPO/node_modules" ] && ln -s "$REPO/node_modules" "$WORK/node_modules"

# The double goes in its own directory ahead of everything, named `pi`.
mkdir -p "$WORK/fake" "$WORK/data"
cp "$REPO/ci/fake-pi" "$WORK/fake/pi"
chmod +x "$WORK/fake/pi" "$WORK"/bin/*

export AGENT_APP="$WORK" AGENT_DATA="$WORK/data" AGENT_ENV_FILE="$WORK/data/.env"
export PATH="$WORK/fake:$WORK/bin:$PATH"
echo "ANTHROPIC_API_KEY=sk-ant-not-a-real-key" > "$WORK/data/.env"

job() {   # job <name> <front-matter...>
  local name="$1"; shift
  { echo "---"; printf '%s\n' "$@"; echo "---"; echo "do the thing"; } \
    > "$WORK/agent/jobs/$name.md"
}

# run <expected-exit> <label> <job> [env assignments...]
run() {
  local want="$1" label="$2" jobname="$3"; shift 3
  local got out
  out=$(env "$@" agent-run "$jobname" 2>&1); got=$?
  if [ "$got" = "$want" ]; then
    ok "$label (exit $got)"
  else
    no "$label — expected exit $want, got $got"
    printf '%s\n' "$out" | sed 's/^/        /' | head -6
  fi
}

agent-init >/dev/null 2>&1 || { echo "agent-init failed"; exit 1; }

echo
echo "== a declared artefact must actually appear =="

job produces-nothing 'description: writes nothing' 'tools: write' 'produces: work/out.txt'
run 31 "a job that produces nothing fails, it does not pass" produces-nothing

run 0 "the same job passes once the artefact is there" produces-nothing \
    FAKE_PI_WRITE="work/out.txt:real content"

job produces-empty 'description: writes an empty file' 'tools: write' 'produces: work/empty.txt'
run 31 "an empty artefact is not an artefact" produces-empty \
    FAKE_PI_WRITE="work/empty.txt:"

echo
echo "== yesterday's artefact must not pass as today's work =="
# The check that earns its keep: existence alone would let a run that did nothing inherit the
# previous run's success, which is exactly the silent failure this exists to catch.
mkdir -p "$WORK/data/work"
echo "written last year" > "$WORK/data/work/stale.txt"
touch -d '2020-01-01 00:00:00' "$WORK/data/work/stale.txt"
job produces-stale 'description: leaves it alone' 'tools: read' 'produces: work/stale.txt'
run 31 "an artefact older than the run is not evidence of the run" produces-stale

echo
echo "== a required input is checked before anything is spent =="
job needs-input 'description: needs a plan' 'tools: read' 'requires: work/plan.md'
run 10 "a missing input stops at preflight, not mid-run" needs-input
if [ -z "$(ls -A "$WORK/data/logs/runs/needs-input" 2>/dev/null | grep -v '^\.lock$')" ]; then
  ok "the refused run left no run record — nothing was started"
else
  no "a preflight refusal created a run record"
fi
echo "a plan" > "$WORK/data/work/plan.md"
run 0 "the same job runs once its input exists" needs-input

echo
echo "== the verify command is real, and its verdict is final =="
job bad-verify 'description: names a checker that does not exist' 'tools: read' \
               'verify: no-such-checker-anywhere'
run 10 "a missing checker is caught before spending, not after" bad-verify

cat > "$WORK/bin/checker-says-no" <<'SH'
#!/bin/sh
echo "the numbers do not add up" >&2
exit 1
SH
cat > "$WORK/bin/checker-says-yes" <<'SH'
#!/bin/sh
[ -d "$1" ] || { echo "verify was not given the run directory" >&2; exit 1; }
exit 0
SH
chmod +x "$WORK/bin/checker-says-no" "$WORK/bin/checker-says-yes"

job verify-no  'description: fails its own check' 'tools: read' 'verify: checker-says-no'
run 31 "a failing checker fails the run the model called a success" verify-no

job verify-yes 'description: passes its own check' 'tools: read' 'verify: checker-says-yes'
run 0 "a passing checker leaves the run successful, and is given the run directory" verify-yes

echo
echo "== the record says which of these happened =="
last="$WORK/data/logs/runs/verify-no/last.json"
if grep -q '"contract": *"verify failed' "$last" 2>/dev/null; then
  ok "meta.json records why the contract failed"
else
  no "meta.json does not record the contract verdict"; cat "$last" 2>/dev/null | sed 's/^/        /'
fi
if grep -q '"contract": *"none"' "$WORK/data/logs/runs/needs-input/last.json" 2>/dev/null; then
  ok "a job with no contract records 'none', not a false 'ok'"
else
  no "a job with no declared contract does not record 'none'"
fi

echo
echo "== a run that never produced anything is still 30, not 31 =="
# 30 and 31 need opposite responses from a scheduler — 30 is usually the provider, 31 is the
# agent — so the contract must not swallow the more informative code.
job silent 'description: says nothing at all' 'tools: read' 'produces: work/never.txt'
run 30 "no result at all stays 30, the contract does not overwrite it" silent FAKE_PI_SILENT=1

echo
echo "== a run cannot start another run =="
# The tool ceiling is declared per job, so propose/commit is only a guarantee while nesting is
# impossible. A job with a shell reaches /app/bin/agent-run — it is on PATH for every
# descendant — and agent-run re-derives the credential from /data/.env, so it needs nothing its
# parent was given. Without this refusal, one `bash` in one job would hand every job's tools to
# that job. Asserted here rather than reviewed, because the reviewer would be looking at a
# different file from the one that grants the shell.
job no-nesting 'description: a perfectly ordinary job' 'tools: read'
run 11 "agent-run refuses to start when the caller is itself a run" no-nesting \
    AGENT_RUN_ID=deadbeef1234 AGENT_JOB=the-parent
[ ! -d "$WORK/data/logs/runs/no-nesting" ] \
  && ok "the refused run left no record — it never started" \
  || no "a refused nested run created a run record"

# The other half, and the one that makes the first meaningful: a guard that refuses everything
# would also pass the test above.
run 0 "the same job runs normally when nothing is nesting it" no-nesting

# Read-only diagnostics stay usable from inside a run, which is why the guard sits where it
# does. They cannot start anything, and needing to leave the container to ask what a job
# declares is how people stop asking.
AGENT_RUN_ID=deadbeef1234 agent-run no-nesting --dry-run >/dev/null 2>&1 \
  && ok "--dry-run still answers from inside a run" \
  || no "the guard also blocked a read-only diagnostic"

echo
echo "== stopping to ask is not the same as failing =="
# Before this, "escalated" and "silently did nothing" produced identical runs: exit 0, no
# artefacts, a polite summary. The behaviour you most want to encourage looked exactly like
# the one you least want.
cat > "$WORK/bin/alert-me" <<SH
#!/bin/sh
echo "\$1" > "$WORK/alerted"
SH
chmod +x "$WORK/bin/alert-me"

job escalating 'description: stops and asks' 'tools: read, escalate' 'produces: work/never2.txt'
run 32 "an escalation is a deliberate stop, and outranks the unmet contract" escalating \
    FAKE_PI_ESCALATE="the routing rules do not cover this ticket" \
    AGENT_RUN_ALERT_CMD=alert-me
[ -f "$WORK/alerted" ] \
  && ok "the alert command fired — an escalation nobody sees is no escalation" \
  || no "AGENT_RUN_ALERT_CMD did not fire for an escalation"
grep -q "routing rules do not cover" "$WORK/data/logs/runs/escalating/last.json" \
  && ok "the reason is in the run record, not only in a file somewhere" \
  || no "the escalation reason was not recorded in meta.json"

job escalating-undeclared 'description: does not declare the tool' 'tools: read'
out=$(agent-run escalating-undeclared --dry-run 2>&1)
case "$out" in
  *escalate.ts*) no "the escalate extension loads for a job that did not declare the tool" ;;
  *)             ok "a job that did not declare escalate does not get the extension" ;;
esac

echo
echo "== the escalate tool itself writes what a human needs =="
# The extension has no dependencies, so it can be driven directly with a fake pi.
cat > "$WORK/esc.mjs" <<'JS'
import ext from "./agent/extensions/escalate.ts";
let tool;
await ext({ registerTool: (t) => { tool = t; }, on: () => {} });
if (!tool || tool.name !== "escalate") { console.error("not registered"); process.exit(2); }
const r = await tool.execute("c1", { reason: "needs a human", detail: "found two prices" });
console.log(JSON.stringify(r));
JS
export AGENT_ESCALATION_DIR="$WORK/data/work/escalations"
export AGENT_ESCALATION_MARKER="$WORK/data/marker"
export AGENT_RUN_ID="run000000001" AGENT_JOB="somejob"
if (cd "$WORK" && node --experimental-strip-types esc.mjs >/dev/null 2>&1); then
  ok "the extension registers and runs"
else
  no "the escalate extension did not run"
fi
python3 - "$WORK/data/work/escalations" <<'PY' && ok "the request names the run, the job and the reason" || no "the escalation file is missing or incomplete"
import glob, json, sys
f = sorted(glob.glob(sys.argv[1] + "/*.json"))
assert f, "no escalation written"
d = json.load(open(f[-1]))
assert d["run"] == "run000000001" and d["job"] == "somejob", d
assert d["reason"] == "needs a human" and "two prices" in d["detail"], d
PY
[ -s "$WORK/data/marker" ] \
  && ok "the run is marked, which is what agent-run acts on" \
  || no "no marker was written"
perm=$(stat -c %a "$(ls "$WORK/data/work/escalations"/*.json | head -1)")
[ "$perm" = 600 ] \
  && ok "the request is 0600 — it quotes whatever the agent was looking at" \
  || no "the escalation file is mode $perm, expected 600"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
