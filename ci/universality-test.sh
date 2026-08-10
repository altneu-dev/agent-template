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
FRAMEWORK=(
  bin/agent-init bin/agent-run bin/agent-mcp bin/agent-secret bin/agent-status
  bin/agent-entrypoint agent/extensions/mcp-tools.ts agent/AGENTS.md
  Dockerfile compose.yml package.json
)

fingerprint() {
  local root="$1" f
  for f in "${FRAMEWORK[@]}"; do
    [ -f "$root/$f" ] && printf '%s  %s\n' "$(md5sum < "$root/$f" | cut -d' ' -f1)" "$f"
  done
}

BASE_FP="$(fingerprint "$REPO")"

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
