#!/usr/bin/env bash
# Verify ai-assisted-development — AI-Assisted Development on OpenShift (vibe coding, safely).
#   Entry: {user}-dev holds the entry marker; the scoped mcp-agent SA + its read-only `view`
#          RoleBinding (and NO write grant yet); the digest-pinned MCP server (Ready); the MaaS
#          credentials (ConfigMap + Secret); the Dev Spaces workspace; AND the seeded broken
#          parasol-claims — Running 0/1 with the WRONG readinessProbe path (the diagnosis target).
#   End:   the seeded deployment is FIXED — its readinessProbe path patched to the correct value, so
#          parasol-claims is Running 1/1 (the outcome after the agent's attendee-granted scoped write).
# Runnable as the ATTENDEE: reads only {user}-dev objects (namespace admin) — no impersonation, no
# cross-namespace reads. (The SA read-works / cross-namespace-DENIED proof is an admin-run RBAC check,
# not an attendee check.) The G1 cockpit smoke runs `--entry-only` as {user}.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
SA="mcp-agent"
SEED="parasol-claims"

# --- helpers (oc only; no jq — the cockpit UDI + CI runner may not ship it) ---------------------

# A Deployment exists AND has an available replica (readiness passing). `>=1` is lab-exceedable.
deploy_available() {
  oc_read get deploy "$1" -n "$NS" -o jsonpath='{.status.availableReplicas}' || return 1
  [[ "${OC_OUT:-0}" -ge 1 ]]
}

# The seeded deployment is BROKEN: it exists but has NO available replica (Running 0/1, readiness 404).
# ASSERTING A FAULT IS A NEGATION. The old silenced read made an unanswerable API read as availableReplicas=0
# and therefore certify "yes, the fault is live" — a green ENTRY check on a cluster nobody could talk to,
# which is exactly the wrongly-green entry that sends `ws prep` down its "already prepared" fast path.
seed_broken() {
  oc_present get deploy "$SEED" -n "$NS" -o name || return 1
  oc_read get deploy "$SEED" -n "$NS" -o jsonpath='{.status.availableReplicas}' || return 1
  [[ "${OC_OUT:-0}" -lt 1 ]]
}

# The seed carries the SPECIFIC injected fault: readinessProbe path == the marker's badProbePath.
seed_probe_is_bad() {
  local want
  oc_read get cm ws-entry-ai-assisted-development -n "$NS" -o jsonpath='{.data.badProbePath}' || return 1
  want="$OC_OUT"
  oc_read get deploy "$SEED" -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' || return 1
  [[ -n "$want" && "$OC_OUT" == "$want" ]]
}

# The seed still carries the image the entry state gave it. Exercise 3 grants the agent a scoped
# write, and a tool-calling model can hand-author a REPLACEMENT manifest with a placeholder in the
# image field (`image: <image>` — seen twice on 2026-07-31) → InvalidImageName, the app can never
# reach 1/1, and NOTHING else in this script explains why. Compared against the marker, never a
# literal. Older markers (chart < 0.1.8) carry no seedImage: with nothing to compare against this
# passes rather than emitting a false ❌ — an unearned red destroys trust in every other ✅.
seed_image_intact() {
  local want rc=0
  oc_read get cm ws-entry-ai-assisted-development -n "$NS" -o jsonpath='{.data.seedImage}' || rc=$?
  # rc 2 ONLY. A marker that is genuinely absent (rc 1) must keep passing exactly as it did before —
  # "nothing to compare against" is the documented behaviour for pre-0.1.8 markers, and the separate
  # entry-marker check above is what fails when the ConfigMap itself is gone.
  if (( rc == 2 )); then return 1; fi
  want="$OC_OUT"
  if [[ -z "$want" ]]; then return 0; fi
  oc_read get deploy "$SEED" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' || return 1
  [[ "$OC_OUT" == "$want" ]]
}

# Pre-lab RBAC shape: the attendee has NOT yet granted the mcp-agent SA a write role. Ask the API
# DIRECTLY (SubjectAccessReview) whether the SA can WRITE. The old name-based rolebinding grep only saw
# the stock edit/admin/cluster-admin ClusterRoles and MISSED custom Roles (e.g. Ex3's mcp-agent-deployer),
# false-greening while a real write grant existed. `oc auth can-i --as=<sa>` catches ANY write grant —
# custom Role, ClusterRoleBinding, or aggregation. Runs as the attendee (the namespace admin ClusterRole
# carries impersonate on serviceaccounts — proven live) and as cluster-admin in CI. `patch deployments`
# is the write the lab grants (the agent fixes the seed's readinessProbe).
#
# THE HIGHEST-RISK NEGATION IN THIS FILE. `! oc auth can-i … 2>/dev/null` returns TRUE — "no write
# grant exists" — whenever the question could not be put at all: an unreachable apiserver, an expired
# token, or a caller without the impersonate right the comment above assumes. The entry state's whole
# security claim ("the sandbox is read-only") was therefore certified by silence. can-i's own plain
# "no" (rc 1, stderr only a namespace-scope Warning) is NOT in oc_read's could-not-ask allowlist, so
# the real negative answer still passes this check exactly as before.
scoped_write_absent() {
  local rc=0
  oc_present get sa "$SA" -n "$NS" -o name || return 1   # SA absent = nothing materialized to assert about
  oc_read auth can-i patch deployments --as="system:serviceaccount:${NS}:${SA}" -n "$NS" || rc=$?
  if (( rc == 2 )); then return 1; fi   # could not ask → ⚠ via the flag, never a certified clean slate
  (( rc != 0 ))                          # rc 1 = the API answered NO → the grant is genuinely absent
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                        || hint "run: ws prep ai-assisted-development (or ws start ai-assisted-development --user ${USER_NAME}); ${NS} is workshop-layer (per-user-namespaces)"
check "entry marker ws-entry-ai-assisted-development present"            oc get cm ws-entry-ai-assisted-development -n "$NS"        || hint "entry app not synced — ws reset ai-assisted-development --user ${USER_NAME}"
check "scoped ServiceAccount mcp-agent present"      oc get sa "$SA" -n "$NS"               || hint "the MCP server's least-privilege SA is missing — ws reset ai-assisted-development --user ${USER_NAME}"
check "mcp-agent read-only RoleBinding (view) present" oc get rolebinding "${SA}-view" -n "$NS" || hint "the namespaced view grant is missing — ws reset ai-assisted-development --user ${USER_NAME}"
check "MCP server deployed + Ready"                  deploy_available kubernetes-mcp-server || hint "kubernetes-mcp-server not Ready — check pods in ${NS} (ws reset ai-assisted-development --user ${USER_NAME}); pulls the digest-pinned ghcr.io/containers/kubernetes-mcp-server"
check "MaaS config carries the resolved model (configmap maas-config)" cm_key_set "$NS" maas-config model || hint "the MaaS copy hook did not fill maas-config — ws reset ai-assisted-development --user ${USER_NAME}"
check "MaaS credentials Secret present"              oc get secret maas-credentials -n "$NS" || hint "the MaaS copy hook did not run — ws reset ai-assisted-development --user ${USER_NAME}"
# The workspace's own env surface, which nothing checked before. It is now hook-written like maas-config
# (the chart renders metadata only), and the DevWorkspace mounts EVERY key of it as an env var — so a
# hook that stopped before this patch would hand the attendee a CLI agent with no GENAI_MODEL and no
# error anywhere. That is precisely the failure this check exists to make loud.
check "DevWorkspace env config carries GENAI_MODEL (configmap maas-config-env)" cm_key_set "$NS" maas-config-env GENAI_MODEL \
  || hint "the MaaS copy hook did not fill maas-config-env — ws reset ai-assisted-development --user ${USER_NAME}"
# Resolved BEFORE the check, not nested inside its argument list: a `$(…)` there runs in a subshell, so
# any verdict oc_read forms about the inner read is discarded. The fallback fires on a FAILED read only
# — a marker that answers with an empty name still yields an empty name, and the outer `check` (which
# oc_read classifies for us) is what reports it either way.
DW_NAME="parasol-ai-assist"
if oc_read get cm ws-entry-ai-assisted-development -n "$NS" -o jsonpath='{.data.devWorkspaceName}'; then
  DW_NAME="$OC_OUT"
fi
check "Dev Spaces workspace present"                 oc get devworkspaces.workspace.devfile.io "$DW_NAME" -n "$NS" \
  || hint "the DevWorkspace is missing — ws reset ai-assisted-development --user ${USER_NAME}"
check "parasol-claims still carries the entry-state container image"   seed_image_intact \
  || hint "the image field was overwritten (an agent write can put a placeholder there — check 'oc get pods -n ${NS} -l app=${SEED}' for InvalidImageName). Restore it in place: oc set image deploy/${SEED} ${SEED}=\"\$(oc get cm ws-entry-ai-assisted-development -n ${NS} -o jsonpath='{.data.seedImage}')\" -n ${NS}"

# INFO: the pinned MCP image + converged model (proves digest-pin + per-cluster secret-sourcing).
# Informational only — an unreadable value still prints '?', exactly as the old `|| echo '?'` did.
MCP_IMAGE='?'
if oc_read get cm ws-entry-ai-assisted-development -n "$NS" -o jsonpath='{.data.mcpServerImage}'; then MCP_IMAGE="$OC_OUT"; fi
AGENT_MODEL='?'
if oc_read get cm maas-config -n "$NS" -o jsonpath='{.data.model}'; then AGENT_MODEL="$OC_OUT"; fi
info "MCP server image: ${MCP_IMAGE}"
info "agent model (maas-config): ${AGENT_MODEL}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the fault is LIVE and the sandbox is read-only (no scoped write yet) -------------
  check "seeded parasol-claims is BROKEN (Running 0/1, readiness failing)" seed_broken \
    || hint "the diagnosis target should be 0/1 at entry; if it is Ready the seed did not materialize with the fault — ws reset ai-assisted-development --user ${USER_NAME}"
  check "the injected fault is the wrong readinessProbe path"              seed_probe_is_bad \
    || hint "the seed's readinessProbe path is not the marker's badProbePath — ws reset ai-assisted-development --user ${USER_NAME}"
  check "scoped write NOT yet granted to mcp-agent (read-only pre-lab)"    scoped_write_absent \
    || hint "an edit/admin RoleBinding for mcp-agent already exists — entry state should be read-only; ws reset ai-assisted-development --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — the probe is fixed, so the app is Ready ------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "seeded parasol-claims FIXED + Ready (probe patched to the correct path)" deploy_available "$SEED" \
    || hint "not done yet? parasol-claims is still 0/1 because the entry state ships it DELIBERATELY broken and repairing the readinessProbe path IS the lab — so this red is the expected state before you start, not a broken environment. Fix the probe path (or let the agent patch it, or: ws solve ai-assisted-development --user ${USER_NAME}), then re-run this verify. If you HAVE patched it and it is still 0/1, that one is real: oc get pods -n ${NS} and oc describe deploy/${SEED} -n ${NS}"
fi

verify_summary
