#!/usr/bin/env bash
# Verify M23 — Agentic AI on OpenShift.
#   Entry: {user}-ai holds the entry marker + MaaS config, and the full agent world is DEPLOYED from the
#          shared parasol-images — the two MCP servers (claims-db, policy-docs) and parasol-agent, with
#          the agent Ready (its /q/health/ready pings both MCP servers, so a Ready agent has proven its
#          tool wiring). No model token is spent at entry.
#   End:   the agent actually ANSWERED a tool-grounded query — POST /agent/ask "status of claim
#          CLM-1001?" makes the model call the claims-db get_claim tool (grounded, not hallucinated).
# Runnable as the ATTENDEE: reads only {user}-ai objects (namespace admin) + the agent's own public edge
# Route over HTTPS (the URL is recorded in the marker — no cross-namespace reads). The G1 cockpit smoke
# runs `--entry-only` as {user}.
#
# MODEL-AGNOSTIC / PER-CLUSTER: maas-config carries the converged model (llama-scout-17b on C2,
# qwen3-14b on C1) — reported as INFO. SHORT-LIVED KEY: the end-state model call needs a live MaaS key;
# if it has expired the agent returns a clean 502 authFailure and the end check fails with a key hint
# (correct — the end state genuinely requires a working model). The entry checks never call the model.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-ai"

# --- helpers (oc + curl only) ------------------------------------------------

# A Deployment exists AND has an available replica (readiness passing). `>=1` is lab-exceedable (scale up).
deploy_available() {
  [[ "$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)" -ge 1 ]]
}

# The agent's public Route URL, as recorded in the entry marker (attendee-safe: no gitea/route read
# cross-namespace — the URL was computed from the cluster domain at materialization).
agent_route() { oc get cm ws-entry-m23 -n "$NS" -o jsonpath='{.data.agentRoute}' 2>/dev/null || true; }

# END-STATE OUTCOME: the agent answered a TOOL-GROUNDED query. POST a claim question and assert the
# agent ACTUALLY EXECUTED the claims-db get_claim tool — a real (structured) tool call serializes as
# "tool":"get_claim" inside a NON-empty toolCalls array; a model that merely ECHOES the call as text
# leaves toolCalls EMPTY (and only the answer string carries get_claim(...)). Grepping the executed-tool
# field, not a bare substring, is what tells true grounding from an echo.
# PROMPT CHOICE (verified live on C2, 2026-07-13): the imperative "use your tools" phrasing is
# deterministic across models — qwen3-14b (C1) and llama-scout-17b (C2) both EXECUTE get_claim for it,
# whereas the terse "what is the status of CLM-1001?" makes llama-scout-17b deterministically emit
# [get_claim(...)] as plain text with an EMPTY toolCalls (ungrounded). Model-agnostic + deterministic
# (temperature 0). Needs a live MaaS key (short-lived on RHDP).
tool_grounded_answer() {
  local route body
  route="$(agent_route)"
  [[ -n "$route" ]] || return 1
  body="$(curl -ksS --max-time 90 -X POST "${route}/agent/ask" \
    -H 'content-type: application/json' \
    -d '{"question":"Use your tools to look up claim CLM-1001 and report its status."}' 2>/dev/null || true)"
  echo "$body" | grep -Eq '"tool"[[:space:]]*:[[:space:]]*"get_claim"'
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                     oc get ns "$NS"                    || hint "run: ws prep m23 (or ws start m23 --user ${USER_NAME}); ${NS} is workshop-layer (per-user-ai)"
check "entry marker ws-entry-m23 present"          oc get cm ws-entry-m23 -n "$NS"    || hint "entry app not synced — ws reset m23 --user ${USER_NAME}"
check "MaaS config present (endpoint + model)"     oc get cm maas-config -n "$NS"     || hint "entry app not synced — ws reset m23 --user ${USER_NAME}"
check "MCP server claims-db deployed + ready"      deploy_available claims-db         || hint "claims-db not ready — check pods in ${NS} (ws reset m23 --user ${USER_NAME}); pulls the shared parasol-images/claims-db:1.0"
check "MCP server policy-docs deployed + ready"    deploy_available policy-docs       || hint "policy-docs not ready — check pods in ${NS} (ws reset m23 --user ${USER_NAME}); pulls the shared parasol-images/policy-docs:1.0"
# A Ready parasol-agent means its readiness probe passes — and that probe pings BOTH MCP servers, so
# this single check proves the agent + its tool wiring are up (the entry-state outcome).
check "parasol-agent deployed + Ready (both MCP clients OK)" deploy_available parasol-agent \
  || hint "the agent is not Ready — its /q/health/ready pings both MCP servers; check pods in ${NS} (ws reset m23 --user ${USER_NAME})"

# INFO: the per-cluster converged model (proves the M22-style secret-sourcing — llama-scout-17b on C2).
info "agent model (maas-config): $(oc get cm maas-config -n "$NS" -o jsonpath='{.data.model}' 2>/dev/null || echo '?')"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the full agent world is deployed + Ready; no model token spent ---------------------
  info "entry state: agent world deployed (claims-db + policy-docs + parasol-agent Ready) — no model call made"
else
  # --- end state: the lab's OUTCOME — the agent answered a TOOL-GROUNDED query ------------------------
  # Assert the OUTCOME (the agent invoked the claims-db get_claim tool), not exact answer wording, so any
  # correct run stays green (rule 14). Needs a live MaaS key (short-lived on RHDP).
  check "agent executed a tool-grounded query (get_claim on CLM-1001)" tool_grounded_answer \
    || hint "POST /agent/ask did not EXECUTE get_claim (empty toolCalls) — the MaaS key (GENAI_API_KEY) may be expired (agent returns 502 authFailure), the agent is not Ready, or the model text-echoed the call; ws solve m23 --user ${USER_NAME} then retry"
fi

verify_summary
