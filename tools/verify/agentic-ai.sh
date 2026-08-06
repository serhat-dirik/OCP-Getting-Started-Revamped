#!/usr/bin/env bash
# Verify agentic-ai — Agentic AI on OpenShift.
#   Entry: {user}-ai holds the entry marker + MaaS config, and the full agent world is DEPLOYED from the
#          shared parasol-images — the two MCP servers (claims-db, policy-docs) and parasol-agent, with
#          the agent Ready (its /q/health/ready pings both MCP servers, so a Ready agent has proven its
#          tool wiring). What entry does NOT ship is a working GROUNDING: the parasol-agent-grounding
#          ConfigMap carries a weak first-draft system prompt that never mentions tools. No model token
#          is spent at entry.
#   End:   the attendee has STRENGTHENED that grounding and rolled the agent onto it — the ConfigMap
#          directs the model at its tools, and the running pod is serving that text (GET /agent/info).
#          Whether the model then elects get_claim is reported as CORROBORATION, not as the grade.
#
# WHY THE GRADE MOVED (false-pass audit F-01, 2026-08-05). This module's entry state WAS its finished
# state. All four agent tools are read-only, so the attendee changed nothing durable; `ws solve`
# rendered byte-identically to `ws prep` (34020 bytes each, empty diff — .Values.solve was referenced
# by zero templates); and this script manufactured an outcome by POSTing /agent/ask ITSELF. It graded
# the entry state's own health and called it a completed lab, and its own end-state banner had to say
# so out loud ("this check runs the query itself … so a ❌ below means something is genuinely wrong,
# not that you have yet to do the lab"). That banner was the defect describing itself.
#
# Entry chart 0.1.8 gives the module a real write-beat: the agent's system prompt is externalized to
# a ConfigMap, entry ships a weak draft, solve ships the strengthened one, and the agent's pod
# template carries a checksum of it so solve rolls the pods. This script now grades THE DECLARATION
# THE ATTENDEE WROTE, with the observed model behaviour kept only as corroboration — the pattern
# commit 75c92ad applied to ten other modules, arriving here.
#
# ONE DETECTOR, NEGATED EXACTLY. entry and end both key on `directs_tools` (does this prompt mention
# tools at all — by the word or by a tool name). Entry asserts its ABSENCE, end its PRESENCE, so the
# invariant `entry ⇒ ¬end` holds by construction and no world can read as both "complete" and "a
# clean slate" — the shape eventing-deep-dive needed a loose/strict pair to reach. It is deliberately
# GENEROUS about wording (rule 14): the lesson is that the prompt must tell the model it has tools,
# not that it must use the sample's sentences. The shipped weak draft contains no occurrence of
# "tool" and no tool name, which is what makes the negation exact rather than approximate.
#
# Runnable as the ATTENDEE: reads only {user}-ai objects (namespace admin) + the agent's own public edge
# Route over HTTPS (the URL is recorded in the marker — no cross-namespace reads). The G1 cockpit smoke
# runs `--entry-only` as {user}.
#
# MODEL-AGNOSTIC / PER-CLUSTER: maas-config carries the converged model (chart default llama-scout-17b,
# task #67; a cluster whose Lightspeed secret carries a different model key converges to that instead)
# — reported as INFO. SHORT-LIVED KEY: only the CORROBORATION calls the model, so an expired key no
# longer decides whether the lab is graded complete — both graded end-state checks (the ConfigMap, and
# the pod serving it via /agent/info) are token-free. A rejected key is still a hard ❌, from the
# credential checks below, which is where that fault belongs. The entry checks never call the model.
#
# CREDENTIAL CHECKS (added 2026-07-29). This script used to assert that maas-credentials EXISTED and
# stop there — which is exactly why M23 shipped green on a live cluster while every attendee's agent
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
  oc_read get deploy "$1" -n "$NS" -o jsonpath='{.status.availableReplicas}' || return 1
  [[ "${OC_OUT:-0}" -ge 1 ]]
}

# The agent's public Route URL, as recorded in the entry marker (attendee-safe: no gitea/route read
# cross-namespace — the URL was computed from the cluster domain at materialization).
# Sets AGENT_ROUTE rather than printing: its only caller used `route="$(agent_route)"`, and a command
# substitution would discard the verdict oc_read forms. An unreadable marker still leaves it empty,
# which the caller already treats as "cannot ask the agent" → ⚠, never a pass.
AGENT_ROUTE=""
agent_route() {
  AGENT_ROUTE=""
  oc_read get cm ws-entry-agentic-ai -n "$NS" -o jsonpath='{.data.agentRoute}' || return 1
  AGENT_ROUTE="$OC_OUT"
}

# One key of maas-config, or empty. The attendee is admin on their own {user}-ai, so this is a
# self-namespace read (rule 10) — no cross-namespace reach. Still prints (its callers are `$(…)`
# interpolations into info strings and the ai_state/ai_reason variables); an unreadable ConfigMap
# yields empty exactly as before, and every consumer's empty branch is already a warn, not a pass.
# ALWAYS returns 0, like the `|| true` it replaces. Its callers are `ai_state="$(maas_cfg …)"` bare
# assignments, and under `set -e` an assignment whose command substitution exits non-zero kills the
# script outright — which it did, silently truncating the run after the Secret check (caught by
# diffing a full user99 run against HEAD, 2026-08-01). Emptiness is this function's failure signal.
maas_cfg() {
  oc_read get cm maas-config -n "$NS" -o jsonpath="{.data.$1}" || OC_OUT=""
  printf '%s' "$OC_OUT"
}

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
  # Every failure keeps mapping to 2 (warn-and-skip), unchanged: the separate "maas-credentials Secret
  # staged" check above is what turns a genuinely missing Secret red. OC_OUT is copied into a local and
  # cleared immediately — the staged key must never linger in a global this script also prints from.
  oc_read get secret maas-credentials -n "$NS" -o jsonpath='{.data.GENAI_API_KEY}' || { OC_OUT=""; return 2; }
  raw="$OC_OUT"; OC_OUT=""
  [[ -n "$raw" ]] || return 1                       # Secret exists but the key is blank = degraded
  tok="$(printf %s "$raw" | base64 -d 2>/dev/null)" || return 1
  [[ -n "$tok" ]] || return 1
  if [[ "$tok" == eyJ* ]] && [[ "$(printf '%s' "$tok" | tr -cd '.' | wc -c | tr -d ' ')" -ge 2 ]]; then
    return 3
  fi
  return 0
}

# ── GROUNDING: the one detector both modes key on ────────────────────────────────────────────────
#
# Does this system prompt TELL THE MODEL IT HAS TOOLS? That is the property the exercise teaches and
# the only thing graded — never the wording. A prompt earns it by using the word "tool"/"tools" or by
# naming one of the agent's four MCP tools; the shipped weak draft does neither, which is what makes
# entry's negation of this exact.
#
# GENEROUS ON PURPOSE (rule 14). An attendee who writes "always call your tools before answering",
# one who writes "use get_claim for claim numbers", and one who pastes the sample all pass. Tightening
# this to demand a particular verb, a particular tool, or a minimum length would trade a false ✅ for a
# false ❌ on a correct solution, which is the worse trade — and the corroborating model call below is
# what catches a prompt that satisfies the letter and grounds nothing.
directs_tools() {  # <text on stdin> → 0 when the prompt points the model at its tools
  grep -Eqi '\btools?\b|get_claim|search_policies|list_claims_by_status|get_claim_history'
}

# The grounding the attendee EDITED — the graded end-state outcome. Read from their own namespace.
# Empty output from a ConfigMap that exists is a real answer ("the key is blank"), not a skip, and
# blank grounding is not a strengthened one, so it correctly fails.
GROUNDING_TEXT=""
grounding_text() {  # → 0 + GROUNDING_TEXT; 1/2 exactly as oc_read (⚠ handled by the caller)
  GROUNDING_TEXT=""
  oc_read get cm parasol-agent-grounding -n "$NS" -o jsonpath='{.data.grounding-prompt}' || return 1
  GROUNDING_TEXT="$OC_OUT"
}
configmap_grounding_directs_tools() {
  grounding_text || return 1
  printf '%s' "$GROUNDING_TEXT" | directs_tools
}
# Entry clean-slate: the SAME predicate, negated. Requires the ConfigMap to be readable first —
# otherwise "no strengthened prompt" is vacuous (true on a cluster where nothing materialized), and a
# vacuous clean slate is what talks `ws prep` out of purging a half-finished world.
no_tool_directing_grounding() {
  grounding_text || return 1
  ! printf '%s' "$GROUNDING_TEXT" | directs_tools
}

# The grounding the RUNNING POD is serving, from GET /agent/info — which makes no model call, so this
# costs nothing and works on a cluster with no MaaS credential at all. This is the second half of the
# exercise and a genuinely separate outcome from the ConfigMap: an env var cannot change under a
# running pod, so an attendee who edits the ConfigMap and never rolls the Deployment has an agent
# still running the weak draft. Grading only the ConfigMap would call that done.
# 0 = the live prompt directs the model at its tools · 1 = it does not (still the weak draft, or the
# rollout has not happened) · 2 = the agent could not be asked at all (route missing/unreachable →
# inconclusive, ⚠ not ❌). The body is CLASSIFIED, never printed.
live_grounding_directs_tools() {
  local route code out="/tmp/.agentic-info.$$" rc=0
  agent_route || true
  route="$AGENT_ROUTE"
  if [[ -z "$route" ]]; then return 2; fi
  code="$(curl -ksS -o "$out" -w '%{http_code}' --max-time 30 "${route}/agent/info" 2>/dev/null || echo 000)"
  # Written as an `if`, not `[[ … ]] && return 2`: under `set -euo pipefail` a false AND-list as a
  # function's own last statement kills the sourcing script outright (see the note on
  # tool_grounded_answer below — same trap, same file).
  if [[ "$code" != "200" ]]; then rm -f "$out"; return 2; fi
  # The prompt is echoed inside a JSON string, so its newlines arrive as literal \n and the whole
  # value is one line. Scoped to the groundingPrompt FIELD rather than grepping the whole body: the
  # neighbouring fields happen to carry no tool name today, and "happens to" is the kind of luck that
  # rots. No jq — the cockpit UDI and the CI runner may not ship it (same constraint as
  # ai-assisted-development.sh), so this is a JSON-string matcher, not a parser.
  # `([^"\]|\\.)*` and not `[^"]*`: an ATTENDEE's prompt may well contain a double quote (it is
  # prose they wrote), which arrives escaped as \" — a naive matcher stops dead there and would
  # report a false ❌ on a correct prompt whose tool instruction sits after the quotation.
  if grep -oE '"groundingPrompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' "$out" | directs_tools; then rc=0; else rc=1; fi
  rm -f "$out"
  return "$rc"
}

# CORROBORATION (no longer the grade): the agent answered a TOOL-GROUNDED query. POST a claim question and assert the
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
#
# AND IT IS DELIBERATELY KEPT IMPERATIVE NOW THAT THIS IS CORROBORATION. A terse question would be the
# tempting change — it would exercise the attendee's own prompt rather than the wording of the query —
# but that is exactly what makes it a bad probe here: the terse question's outcome is model-dependent
# (2026-08-06: the lab NO LONGER documents both outcomes — it was re-measured 3/3 per cell and the
# terse question does not ground in EITHER prompt state on {maas_model}), so it would warn on correct
# work as often as not.
# The imperative query corroborates the END-TO-END TOOL PATH (model reachable, MCP servers answering,
# tool actually executed). The attendee's grounding is graded from the ConfigMap and from what the pod
# is serving — both of which are decided without asking a model anything.
# 0 = grounded · 1 = the agent answered but did NOT execute the tool · 2 = the agent could not be
# asked at all (route missing/unreachable → inconclusive, ⚠ not ❌). The response body is CLASSIFIED,
# never printed: a 502 from the model gateway echoes the whole Bearer token back inside its message.
tool_grounded_answer() {
  local route body code out="/tmp/.agentic-ask.$$"
  agent_route || true
  route="$AGENT_ROUTE"
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
# The object the lab writes to. EXISTENCE only here — what it CONTAINS is the entry/end split below.
# A missing ConfigMap is a materialization failure, not an attendee mistake: the agent would fall back
# to its strong built-in prompt and quietly ground, hiding the whole exercise.
check "grounding ConfigMap parasol-agent-grounding present" cm_key_set "$NS" parasol-agent-grounding grounding-prompt \
  || hint "the agent's system prompt is not in the namespace — entry app not synced, or the chart predates 0.1.8: ws reset agentic-ai --user ${USER_NAME}"

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
  # --- entry state: the agent world is deployed + Ready, and its grounding is still the weak draft ----
  # The EXACT negation of the end-state predicate below (see ONE DETECTOR, NEGATED EXACTLY in the
  # header). `ws prep` reads this mode's rc as "is this world already prepared?" and skips its purge on
  # rc 0, so a world whose prompt has already been strengthened must NOT certify as a clean slate —
  # otherwise the next attendee inherits a finished lab and never sees the exercise.
  check "grounding is still the weak entry draft (attendee has not engineered it yet)" no_tool_directing_grounding \
    || hint "entry ships a deliberately weak system prompt in cm/parasol-agent-grounding — one that never mentions tools. If it already directs the model at its tools, this world has been worked on: ws reset agentic-ai --user ${USER_NAME}"
  info "entry state: the agent world is deployed and Ready above — no model call made, no token spent"
else
  # --- end state: the lab's OUTCOME — the attendee ENGINEERED the grounding and rolled the agent ------
  info "end state — these checks grade a COMPLETED lab; both are token-free, so they hold even on a cluster with no MaaS credential"
  # 1. THE DECLARATION THE ATTENDEE WROTE. This is the grade: the system prompt in their namespace now
  #    tells the model it has tools. Graded on that property, never on wording (rule 14).
  check "grounding prompt directs the model at its tools (your edit to cm/parasol-agent-grounding)" configmap_grounding_directs_tools \
    || hint "not done yet — the entry state deliberately ships a weak prompt that never mentions tools, and rewriting it is the lab, so this red is expected before you start. Edit it (oc edit cm parasol-agent-grounding -n ${NS}) so it tells the model it has tools and when to call them. To see a worked answer: ws solve agentic-ai --user ${USER_NAME}"
  # 2. AND IT REACHED THE WORKLOAD. A separate outcome, not a restatement: PARASOL_AGENT_GROUNDING_PROMPT
  #    is an environment variable, and an env var cannot change under a running pod. An attendee who
  #    edited the ConfigMap and never rolled the Deployment still has an agent running the weak draft —
  #    grading only step 1 would call that finished. GET /agent/info makes no model call.
  live_rc=0; live_grounding_directs_tools || live_rc=$?
  case "$live_rc" in
    0) echo "✅ the running agent is serving that grounding (GET /agent/info)"; VERIFY_PASS=$((VERIFY_PASS+1)) ;;
    1) echo "❌ the running agent is still serving the OLD grounding — your ConfigMap edit has not reached the pod"
       VERIFY_FAIL=$((VERIFY_FAIL+1))
       hint "the prompt is an environment variable, so a running pod keeps the value it started with: oc rollout restart deploy/parasol-agent -n ${NS} && oc rollout status deploy/parasol-agent -n ${NS}. Then confirm with: curl -ksS \$AGENT/agent/info | jq -r .groundingPrompt" ;;
    *) warn "the agent Route did not answer /agent/info — cannot tell which grounding the pod is serving from here"
       hint "the Route is reachable from the cockpit terminal and from the cluster; re-run there, or check: oc get route parasol-agent -n ${NS}" ;;
  esac
  # 3. CORROBORATION, NOT A GRADE. Whether the model then ELECTS get_claim depends on the model as much
  #    as on the prompt (2026-08-06: on {maas_model} it is deterministic, not a toss-up — the terse
  #    question typed the call out as text 0/10 times across both prompt states and three pods, which
  #    is why the lab and this probe both use the imperative phrasing), so it is
  #    reported and never counted: a ❌ here would fail correct work on a model that simply chooses
  #    differently. What it genuinely proves when it passes is the whole path end to end — model
  #    reachable, MCP servers answering, a tool actually executed.
  if [[ "$ai_by_choice" == "true" ]]; then
    # NOT warn(): nothing is missing from this run. Both graded outcomes above were evaluated in full
    # without a model, so telling the reader the lab "did NOT fully verify" would be a caveat printed
    # over a complete result — the exact defect na() exists for.
    na "model corroboration: no MaaS credential reached this cluster (aiPathReason=no-maas-credential), so there is no model to ask — the graded checks above did not need one"
  else
    ask_rc=0; tool_grounded_answer || ask_rc=$?
    case "$ask_rc" in
      0) info "corroboration ✔ — the agent executed a real tool call (get_claim on CLM-1001) end to end" ;;
      1) warn "corroboration: the agent answered but did NOT execute a tool on this run — not graded, and not necessarily your prompt"
         hint "an empty toolCalls means the MODEL declined to call one. If the two graded checks above are green your grounding is in place: retry once (see the model-choice table in apps/parasol-agent/README.md — some models never emit a tool call at all), or check whether the MaaS key was rejected (a 502 authFailure shows up in the credential checks above). If they are RED, fix those first — this line is downstream of them" ;;
      *) warn "corroboration: the agent Route did not answer POST /agent/ask — cannot run the end-to-end tool call from here"
         hint "the Route is reachable from the cockpit terminal and from the cluster; re-run there, or check: oc get route parasol-agent -n ${NS}" ;;
    esac
  fi
fi

verify_summary
