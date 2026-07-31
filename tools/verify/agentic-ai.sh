#!/usr/bin/env bash
# Verify agentic-ai — Agentic AI on OpenShift.
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
# MODEL-AGNOSTIC / PER-CLUSTER: maas-config carries the converged model (chart default llama-scout-17b,
# task #67; a cluster whose Lightspeed secret carries a different model key converges to that instead)
# — reported as INFO. SHORT-LIVED KEY: the end-state model call needs a live MaaS key; if it has expired
# the agent returns a clean 502 authFailure and the end check fails with a key hint (correct — the end
# state genuinely requires a working model). The entry checks never call the model.
#
# CREDENTIAL CHECKS (added 2026-07-29). This script used to assert that maas-credentials EXISTED and
# stop there — which is exactly why M23 shipped green on cluster ksls5 while every attendee's agent
# 401'd: the entry hook had copied an adopted Lightspeed install's Azure AD JWT into it. Presence is
# not proof. Two independent assertions now stand in its place, and BOTH must hold:
#   1. SHAPE, checked here from the staged Secret: a 3-segment JWT is a control-plane bearer for some
#      other provider and can never be an OpenAI-compatible API key. Costs nothing, catches that exact
#      class outright. Never prints, logs or truncates the value.
#   2. VERDICT, read from maas-config's aiPathAvailable, which the entry hook writes after spending one
#      real token against the endpoint+model this module uses. true → ✅ · false → see the CHOICE-vs-
#      MISTAKE split below · unverified → ⚠ and skip (the cluster could not reach the endpoint —
#      inconclusive, never a false ❌).
# The honest live gate is spent ONCE, in the hook, not once per attendee per verify run.
#
# CHOICE vs MISTAKE (2026-07-29). `aiPathAvailable=false` has two very different causes, and the
# entry hook already distinguishes them in `aiPathReason` — this script must not flatten them:
#   · no-maas-credential .............. NO CREDENTIAL REACHED THE CLUSTER AT ALL — nothing to reject.
#     bootstrap/install.sh treats that as a supported install (`info "no MaaS key in vars.yaml — the
#     AI beats degrade to an explicit 'AI path unavailable' state"`), and its warn for a key its own
#     probe rejected says the same: the AI beats report "AI path unavailable" rather than fail at
#     workshop time; every other module is unaffected. Failing red on every MaaS-less cluster is
#     exactly the false ❌ that trains people to ignore ❌ — so: ⚠ warn-and-skip, and say WHY without
#     over-claiming (the hook cannot see whether the installer had a key and refused to stage it).
#   · credential-is-a-jwt-not-an-api-key / credential-rejected-by-endpoint … A CREDENTIAL WAS FOUND
#     AND IS UNUSABLE. Somebody meant to enable the AI path and it is broken — hard ❌, which is the
#     state that used to report all-green.
#   · endpoint-unreachable-from-cluster … inconclusive → ⚠ (aiPathAvailable is `unverified` there).
# The reason strings above are the literal ones written by gitops/entry-states/*/templates/
# maas-credentials.yaml (all four AI modules share the shape) — read from the hook, not invented.
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
agent_route() { oc get cm ws-entry-agentic-ai -n "$NS" -o jsonpath='{.data.agentRoute}' 2>/dev/null || true; }

# One key of maas-config, or empty. The attendee is admin on their own {user}-ai, so this is a
# self-namespace read (rule 10) — no cross-namespace reach.
maas_cfg() { oc get cm maas-config -n "$NS" -o jsonpath="{.data.$1}" 2>/dev/null || true; }

# The staged GENAI_API_KEY is NON-EMPTY and is NOT a JSON Web Token. A JWT (3 dot-separated segments,
# `eyJ` prefix) is a bearer minted for another provider's control plane — an adopted Azure-OpenAI
# OpenShift Lightspeed writes one into its `Bearer` key, and that is what the entry hook used to copy.
# The value is decoded into a local, compared, and discarded: never echoed, never truncated for
# display, never written anywhere.
# 0 = plausible API key · 1 = BLANK (which the hook writes deliberately when it had nothing usable to
# stage — the caller must consult aiPathReason to tell "nobody configured a key" from "the key we
# found was refused") · 2 = unreadable (caller has no rights → warn-and-skip) · 3 = a JWT, i.e. a
# credential of the wrong KIND actually sitting in the Secret (only pre-validation entry states).
staged_key_shape_ok() {
  local raw tok
  raw="$(oc get secret maas-credentials -n "$NS" -o jsonpath='{.data.GENAI_API_KEY}' 2>/dev/null)" || return 2
  [[ -n "$raw" ]] || return 1                       # Secret exists but the key is blank = degraded
  tok="$(printf %s "$raw" | base64 -d 2>/dev/null)" || return 1
  [[ -n "$tok" ]] || return 1
  if [[ "$tok" == eyJ* ]] && [[ "$(printf '%s' "$tok" | tr -cd '.' | wc -c | tr -d ' ')" -ge 2 ]]; then
    return 3
  fi
  return 0
}

# END-STATE OUTCOME: the agent answered a TOOL-GROUNDED query. POST a claim question and assert the
# agent ACTUALLY EXECUTED the claims-db get_claim tool — a real (structured) tool call serializes as
# "tool":"get_claim" inside a NON-empty toolCalls array; a model that merely ECHOES the call as text
# leaves toolCalls EMPTY (and only the answer string carries get_claim(...)). Grepping the executed-tool
# field, not a bare substring, is what tells true grounding from an echo.
# PROMPT CHOICE (verified live, 2026-07-13): the imperative "use your tools" phrasing makes
# llama-scout-17b (the chart-default, key-scoped model — task #67) deterministically EXECUTE get_claim,
# whereas the terse "what is the status of CLM-1001?" makes it deterministically emit [get_claim(...)]
# as plain text with an EMPTY toolCalls (ungrounded) instead. The imperative phrasing is the robust
# choice designed to stay deterministic on other models too. Temperature 0. Needs a live MaaS key
# (short-lived on RHDP).
# 0 = grounded · 1 = the agent answered but did NOT execute the tool · 2 = the agent could not be
# asked at all (route missing/unreachable → inconclusive, ⚠ not ❌). The response body is CLASSIFIED,
# never printed: a 502 from the model gateway echoes the whole Bearer token back inside its message.
tool_grounded_answer() {
  local route body code out="/tmp/.agentic-ask.$$"
  route="$(agent_route)"
  [[ -n "$route" ]] || return 2
  code="$(curl -ksS -o "$out" -w '%{http_code}' --max-time 90 -X POST "${route}/agent/ask" \
    -H 'content-type: application/json' \
    -d '{"question":"Use your tools to look up claim CLM-1001 and report its status."}' 2>/dev/null || echo 000)"
  body="$(cat "$out" 2>/dev/null || true)"; rm -f "$out"
  # 000 = the Route did not answer at all. A 5xx from the AGENT is a real failure of this end state
  # (usually the model gateway rejecting the key), so it stays a ❌, not a skip. Written as an `if`
  # rather than `[[ … ]] && return 2`: under `set -e` a false AND-list as a function's own statement
  # is the shape that silently kills a script, and this file is sourced-adjacent to `set -euo pipefail`.
  if [[ "$code" == "000" ]]; then return 2; fi
  printf '%s' "$body" | grep -Eq '"tool"[[:space:]]*:[[:space:]]*"get_claim"'
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                     oc get ns "$NS"                    || hint "run: ws prep agentic-ai (or ws start agentic-ai --user ${USER_NAME}); ${NS} is workshop-layer (per-user-ai)"
check "entry marker ws-entry-agentic-ai present"          oc get cm ws-entry-agentic-ai -n "$NS"    || hint "entry app not synced — ws reset agentic-ai --user ${USER_NAME}"
check "MaaS config carries the resolved model (configmap maas-config)" cm_key_set "$NS" maas-config model || hint "the MaaS copy hook did not fill maas-config — ws reset agentic-ai --user ${USER_NAME}"
check "MCP server claims-db deployed + ready"      deploy_available claims-db         || hint "claims-db not ready — check pods in ${NS} (ws reset agentic-ai --user ${USER_NAME}); pulls the shared parasol-images/claims-db:1.0"
check "MCP server policy-docs deployed + ready"    deploy_available policy-docs       || hint "policy-docs not ready — check pods in ${NS} (ws reset agentic-ai --user ${USER_NAME}); pulls the shared parasol-images/policy-docs:1.0"
# A Ready parasol-agent means its readiness probe passes — and that probe pings BOTH MCP servers, so
# this single check proves the agent + its tool wiring are up (the entry-state outcome).
check "parasol-agent deployed + Ready (both MCP clients OK)" deploy_available parasol-agent \
  || hint "the agent is not Ready — its /q/health/ready pings both MCP servers; check pods in ${NS} (ws reset agentic-ai --user ${USER_NAME})"

# INFO: the per-cluster converged model + where its credential came from.
info "agent model (maas-config): $(maas_cfg model | grep . || echo '?') · credential source: $(maas_cfg credentialSource | grep . || echo '?')"

# --- the MaaS credential actually works (not merely: exists) ------------------
check "maas-credentials Secret staged"             oc get secret maas-credentials -n "$NS" \
  || hint "the entry hook did not run — ws reset agentic-ai --user ${USER_NAME} (check Job maas-copy-agentic-ai-${USER_NAME} in ${NS})"

# WHY the credential is missing decides ❌-vs-⚠ for both checks below, so read the hook's verdict
# first. `no-maas-credential` is the only reason that means "absent by choice" (see CHOICE vs MISTAKE
# in the header); everything else means a credential was found and could not be made to work.
ai_state="$(maas_cfg aiPathAvailable)"
ai_reason="$(maas_cfg aiPathReason)"
ai_by_choice=false
if [[ "$ai_reason" == "no-maas-credential" ]]; then ai_by_choice=true; fi
maasless_fix="no credential reached this cluster — either none was configured, or the installer refused to stage one its own probe rejected (both are supported, degraded installs; check the ./bootstrap/install.sh output). To enable the AI path: set a working maas.api_key + maas.endpoint in bootstrap/vars.yaml, re-run ./bootstrap/install.sh (writes ogsr-system/ogsr-maas-credentials), then ws reset agentic-ai --user ${USER_NAME}"

# 1. SHAPE. Cheap, decisive, and independent of anything the hook recorded.
shape_rc=0; staged_key_shape_ok || shape_rc=$?
case "$shape_rc" in
  0) echo "✅ staged GENAI_API_KEY is a plausible API key (present, not a JWT)"; VERIFY_PASS=$((VERIFY_PASS+1)) ;;
  1) if [[ "$ai_by_choice" == "true" ]]; then
       warn "staged GENAI_API_KEY is deliberately blank — no MaaS credential reached this cluster (aiPathReason=no-maas-credential), so the hook had nothing to stage"
       hint "$maasless_fix"
     else
       echo "❌ staged GENAI_API_KEY is blank — the entry hook found a credential and REFUSED to stage it (aiPathReason=${ai_reason:-unrecorded}); the agent cannot authenticate"
       VERIFY_FAIL=$((VERIFY_FAIL+1))
       hint "the hook stages nothing when the credential it resolved cannot work: it was the wrong kind (a JWT from an adopted OpenShift Lightspeed wired to another provider) or the endpoint refused it. Put a working OpenAI-compatible key in bootstrap/vars.yaml (maas.api_key + maas.endpoint), re-run ./bootstrap/install.sh (writes ogsr-system/ogsr-maas-credentials — preferred over any adopted secret), then: ws reset agentic-ai --user ${USER_NAME}"
     fi ;;
  3) echo "❌ staged GENAI_API_KEY is a JSON Web Token, not an OpenAI-compatible API key — the agent cannot authenticate"
     VERIFY_FAIL=$((VERIFY_FAIL+1))
     hint "a JWT here means the hook fell back to an adopted OpenShift Lightspeed secret wired to another provider (pre-validation entry states staged it; the current hook refuses to). Set maas.api_key + maas.endpoint in bootstrap/vars.yaml, re-run ./bootstrap/install.sh, then: ws reset agentic-ai --user ${USER_NAME}" ;;
  *) warn "staged GENAI_API_KEY not readable from here"
     hint "run as ${USER_NAME} (namespace admin on ${NS}) or as the instructor/CI identity" ;;
esac

# 2. VERDICT of the hook's live probe. A reachable endpoint that REJECTS the key is a hard ❌ — that
# is a broken module, and it is precisely the state that used to report all-green. A cluster that was
# never given a key is a different animal: ⚠, per the CHOICE-vs-MISTAKE split in the header.
case "$ai_state" in
  true)  echo "✅ MaaS endpoint accepted the staged credential (live probe at entry-state materialization)"
         VERIFY_PASS=$((VERIFY_PASS+1)) ;;
  false) if [[ "$ai_by_choice" == "true" ]]; then
           warn "AI path unavailable BY CONFIGURATION — no MaaS credential reached this cluster (aiPathReason=no-maas-credential); the module deploys and the agent stays Ready, but its model call returns a clean 502 authFailure"
           hint "$maasless_fix"
         else
           echo "❌ AI path unavailable — the MaaS endpoint did not accept a usable credential"
           VERIFY_FAIL=$((VERIFY_FAIL+1))
           hint "reason recorded by the entry hook: ${ai_reason:-unknown}. Full detail: oc logs job/maas-copy-agentic-ai-${USER_NAME} -n ${NS}"
         fi ;;
  unverified)
         warn "MaaS endpoint was unreachable from the cluster when the entry state materialized — credential staged but unproven"
         hint "check cluster egress to $(maas_cfg endpoint | grep . || echo 'the MaaS endpoint'), then: ws reset agentic-ai --user ${USER_NAME}" ;;
  *)     warn "maas-config carries no aiPathAvailable verdict (entry state predates the credential-validation hook)"
         hint "re-materialize with the current chart: ws reset agentic-ai --user ${USER_NAME}" ;;
esac

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the full agent world is deployed + Ready; no model token spent ---------------------
  info "entry state: asserting the agent-world deployments below — no model call made"
elif [[ "$ai_by_choice" == "true" ]]; then
  # The lab's outcome is a MODEL answer. On a cluster deliberately installed without a MaaS credential
  # there is no model to answer, so this is not evaluable here — ⚠, same doctrine as the two checks
  # above. (A cluster that HAS a key and rejects it still runs the query below and still fails ❌.)
  warn "end state not evaluable: no MaaS credential reached this cluster (aiPathReason=no-maas-credential), so the agent has no model to call"
  hint "$maasless_fix — then re-run: ws verify agentic-ai --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — the agent answered a TOOL-GROUNDED query ------------------------
  # Assert the OUTCOME (the agent invoked the claims-db get_claim tool), not exact answer wording, so any
  # correct run stays green (rule 14). Needs a live MaaS key (short-lived on RHDP). A route that does not
  # answer at all is ⚠ (the caller may simply be off-cluster); an answering agent that did not ground is ❌.
  ask_rc=0; tool_grounded_answer || ask_rc=$?
  case "$ask_rc" in
    0) echo "✅ agent executed a tool-grounded query (get_claim on CLM-1001)"; VERIFY_PASS=$((VERIFY_PASS+1)) ;;
    1) echo "❌ agent answered WITHOUT executing a tool — get_claim was never called for CLM-1001 (ungrounded)"
       VERIFY_FAIL=$((VERIFY_FAIL+1))
       hint "POST /agent/ask did not EXECUTE get_claim (empty toolCalls) — the MaaS key may be rejected (agent returns 502 authFailure; see the credential checks above), the agent is not Ready, or the model text-echoed the call; ws solve agentic-ai --user ${USER_NAME} then retry" ;;
    *) warn "the agent Route did not answer — cannot evaluate the tool-grounded query from here"
       hint "the Route is reachable from the cockpit terminal and from the cluster; re-run there, or check: oc get route -n ${NS}" ;;
  esac
fi

verify_summary
