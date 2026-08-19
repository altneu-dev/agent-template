#!/usr/bin/env bash
# universality-test — prove the template is a framework and not one vertical in disguise.
#
#   ci/universality-test.sh
#
# The claim under test: a vertical is configuration. Installing one must not require editing
# bin/, agent/extensions/, agent/AGENTS.md, Dockerfile, compose.yml or package.json.
#
# This is the gate, and it is deliberately mechanical: it hashes those files before and after
# installing each example and fails if a single byte moved. "It felt clean" is how a universal
# template quietly becomes a mail tool — the point of a hash is that it cannot be persuaded.
#
# Each example is checked twice over:
#   1. it installs without touching the framework
#   2. it actually works — jobs parse, MCP servers answer, and the tool surface pi reports
#      matches exactly what the job declared
#
# The second check runs against a real pi session that stops before any model request, so the
# whole thing needs no credentials, no network and costs nothing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# Everything a vertical must never need to change.
#
# DERIVED from the repository, not typed out. It was a hand-maintained list, and a list is a
# second copy of "what is the framework" that someone has to remember to update. Nobody did:
# the commit that added bin/agent-alert — a framework file, carrying the property that an
# escalation reaches a human — did not add it here, so the gate that exists to protect
# framework files quietly stopped protecting the newest one. agent/extensions/escalate.ts had
# been unprotected for longer. A glob cannot be forgotten.
#
# Read from $REPO and then used for BOTH fingerprints, rather than re-globbed per example: a
# vertical is allowed to ADD scripts to bin/ (the helpdesk example ships its own), and globbing
# the installed tree would fingerprint those and fail every example for growing.
mapfile -t FRAMEWORK < <(cd "$REPO" && ls bin/* agent/extensions/*.ts 2>/dev/null)
FRAMEWORK+=(agent/AGENTS.md Dockerfile compose.yml package.json)

fingerprint() {
  local root="$1" f
  for f in "${FRAMEWORK[@]}"; do
    [ -f "$root/$f" ] && printf '%s  %s\n' "$(md5sum < "$root/$f" | cut -d' ' -f1)" "$f"
  done
}

BASE_FP="$(fingerprint "$REPO")"

# The gate is only worth what it covers, and it silently covered less than it claimed: two
# framework files were absent from the list this replaced. Assert membership and assert
# detection, because "the glob is right" and "tampering is caught" are different claims.
echo
echo "== the framework freeze covers the framework =="
for must in bin/agent-run bin/agent-alert bin/agent-secret agent/extensions/escalate.ts \
            agent/extensions/mcp-tools.ts compose.yml; do
  case " ${FRAMEWORK[*]} " in
    *" $must "*) ok "frozen: $must" ;;
    *)           no "$must is NOT frozen — a vertical could replace it and CI would pass" ;;
  esac
done

tamper="$(mktemp -d)"
cp -r "$REPO"/{bin,agent,Dockerfile,compose.yml,package.json} "$tamper/" 2>/dev/null
printf '\n# a vertical was here\n' >> "$tamper/bin/agent-alert"
[ "$(fingerprint "$tamper")" != "$BASE_FP" ] \
  && ok "and an edit to one of them is actually detected" \
  || no "bin/agent-alert was edited and the fingerprint did not move"
rm -rf "$tamper"

for example in "$REPO"/examples/*/; do
  name="$(basename "$example")"
  echo
  echo "== $name =="

  work="$(mktemp -d)"
  data="$work/data"
  cp -r "$REPO"/{bin,agent,ci,knowledge,Dockerfile,compose.yml,package.json,.env.example} "$work/" 2>/dev/null
  [ -d "$REPO/node_modules" ] && ln -s "$REPO/node_modules" "$work/node_modules"
  mkdir -p "$data"

  # --- install the vertical, exactly as a fork would: overlay files, append env ---------
  [ -d "$example/agent" ] && cp -r "$example/agent/." "$work/agent/"
  [ -d "$example/bin" ]   && cp -r "$example/bin/."   "$work/bin/"
  [ -f "$example/env.example.append" ] && cat "$example/env.example.append" >> "$work/.env.example"
  chmod +x "$work"/bin/* 2>/dev/null

  if [ "$(fingerprint "$work")" = "$BASE_FP" ]; then
    ok "installs without touching the framework"
  else
    no "installing $name changed framework files:"
    diff <(printf '%s\n' "$BASE_FP") <(fingerprint "$work") | sed 's/^/        /'
  fi

  export AGENT_APP="$work" AGENT_DATA="$data" AGENT_ENV_FILE="$data/.env"
  export PATH="$work/bin:$PATH"

  # A credential that is present but invalid: enough to pass preflight, never used, because
  # every check below stops before a model request.
  { echo "ANTHROPIC_API_KEY=sk-ant-not-a-real-key"
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*=.*' "$example/env.example.append" 2>/dev/null \
      | sed "s|/data|$data|g"
  } > "$data/.env"

  agent-init >/dev/null 2>&1 && ok "agent-init prepares a fresh volume" \
                             || no "agent-init failed"

  agent-secret check -q && ok "deployment reports itself configured" \
                        || no "agent-secret check failed"

  # An example is a worked fork, so it must satisfy the same readiness gate a client deployment
  # does — jobs present, context written, every job actually buildable. If an example cannot
  # pass this, the gate is asking forks for something the framework's own examples do not do.
  # An example is a finished VERTICAL and an unfinished DEPLOYMENT, and --ready is right to
  # say so: both examples ship example.invalid as the webhook, because a placeholder that can
  # never resolve is the only safe default, and a deployment whose escalations reach nobody is
  # not ready. So the assertion is not "clean" — it is "the alert path is the ONLY thing
  # outstanding". That is a stronger claim than the one it replaces, which passed while the
  # webhook pointed nowhere, and would have gone on passing if the vertical were missing its
  # context, its jobs, or a skill it names.
  ready_out="$(agent-status --ready 2>&1)"
  # --ready prints its own tally; parsing that rather than counting lines keeps this
  # assertion from breaking every time a note gains a line of explanation.
  ready_gaps="$(printf '%s\n' "$ready_out" | sed -n 's/^\([0-9]\+\) thing(s) to finish.*/\1/p')"
  case "$ready_out" in
    *"still example.invalid"*|*"alert path incomplete"*)
      if [ "$ready_gaps" = 1 ]; then
        ok "the vertical is complete; the only gap is the webhook nobody has set yet"
      else
        no "the example has $ready_gaps unfinished items, expected only the webhook"
        printf '%s\n' "$ready_out" | sed 's/^/        /'
      fi ;;
    *)
      no "agent-status --ready did not flag the placeholder webhook"
      printf '%s\n' "$ready_out" | sed 's/^/        /' ;;
  esac

  # AGENTS.md instructs the agent to use kb. A documented command that does not exist is the
  # exact failure this repo was written to stop repeating, so it is asserted rather than assumed.
  if kb add "gate probe" </dev/null >/dev/null 2>&1 && kb index >/dev/null 2>&1 \
     && kb search "gate probe" >/dev/null 2>&1; then
    ok "memory works: kb add / index / search"
  else
    no "kb round trip failed — AGENTS.md tells the agent to use it"
  fi

  # A fact that changed has to be retirable. Without it the knowledge base can only accumulate,
  # and in a company where prices and contacts move, something retired eventually gets quoted
  # back to a client as current.
  probe="$(basename "$(ls "$data"/knowledge/notes/*gate-probe*.md 2>/dev/null | head -1)" .md)"
  printf -- '---\nsupersedes: %s\n---\n# corrected probe\n\nthe replacement fact\n' "$probe" \
    > "$data/knowledge/notes/zz-corrected-probe.md"
  kb index >/dev/null 2>&1
  if ! grep -q '\[gate probe\]' "$data/knowledge/INDEX.md" 2>/dev/null \
     && grep -q '\[corrected probe\]' "$data/knowledge/INDEX.md" 2>/dev/null \
     && kb search "gate probe" 2>/dev/null | grep -q 'superseded'; then
    ok "a superseded note leaves INDEX.md but stays findable"
  else
    no "supersedes: did not retire the old note"
  fi

  if [ -n "$(find "$work/agent/mcp" -name '*.json' 2>/dev/null)" ]; then
    agent-mcp check >/dev/null 2>&1 && ok "MCP definitions resolve" || no "agent-mcp check failed"
    agent-mcp probe >/dev/null 2>&1 && ok "MCP servers complete a handshake" || no "agent-mcp probe failed"
  else
    ok "no MCP declared (nothing to reach)"
  fi

  # --- every job: parses, and gets exactly the tools it declared -----------------------
  for jobfile in "$work"/agent/jobs/*.md; do
    [ -e "$jobfile" ] || continue
    job="$(basename "$jobfile" .md)"; [ "$job" = README ] && continue

    agent-run "$job" --dry-run >/dev/null 2>&1 \
      && ok "job '$job' builds a command" || { no "job '$job' does not build"; continue; }

    want="$(python3 - "$jobfile" <<'PY'
import re, sys
raw = open(sys.argv[1], encoding='utf-8').read()
m = re.match(r'^---\s*\n(.*?)\n---', raw, re.S)
meta = {}
for line in (m.group(1).splitlines() if m else []):
    if ':' in line:
        k, v = line.split(':', 1); meta[k.strip()] = v.strip()
def lv(k):
    return [x.strip() for x in meta.get(k, '').split(',') if x.strip()]
print(','.join(sorted(lv('tools') + lv('allow'))))
PY
)"
    got="$(agent-run "$job" --probe-tools 2>/dev/null \
           | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)"

    if [ "$got" = "$want" ]; then
      ok "job '$job' gets exactly its declared tools: ${want:-<none>}"
    else
      no "job '$job' tool surface differs — declared [${want}] but pi reports [${got}]"
    fi
  done

  rm -rf "$work"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
