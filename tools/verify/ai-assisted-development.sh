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
  local avail
  avail="$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  [[ "${avail:-0}" -ge 1 ]]
}

# The seeded deployment is BROKEN: it exists but has NO available replica (Running 0/1, readiness 404).
seed_broken() {
  oc get deploy "$SEED" -n "$NS" >/dev/null 2>&1 || return 1
  local avail
  avail="$(oc get deploy "$SEED" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  [[ "${avail:-0}" -lt 1 ]]
}

# The seed carries the SPECIFIC injected fault: readinessProbe path == the marker's badProbePath.
seed_probe_is_bad() {
  local want got
  want="$(oc get cm ws-entry-ai-assisted-development -n "$NS" -o jsonpath='{.data.badProbePath}' 2>/dev/null || true)"
  got="$(oc get deploy "$SEED" -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null || true)"
  [[ -n "$want" && "$got" == "$want" ]]
}

# Pre-lab RBAC shape: the attendee has NOT yet granted the mcp-agent SA a write role. Assert no
# RoleBinding in NS pairs a write-capable ClusterRole (edit/admin/cluster-admin) with mcp-agent.
scoped_write_absent() {
  local lines
  lines="$(oc get rolebinding -n "$NS" \
    -o jsonpath='{range .items[*]}{.roleRef.name}{" "}{range .subjects[*]}{.name}{","}{end}{"\n"}{end}' \
    2>/dev/null || true)"
  ! echo "$lines" | grep -E '^(edit|admin|cluster-admin) ' | grep -qw "$SA"
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                        || hint "run: ws prep ai-assisted-development (or ws start ai-assisted-development --user ${USER_NAME}); ${NS} is workshop-layer (per-user-namespaces)"
check "entry marker ws-entry-ai-assisted-development present"            oc get cm ws-entry-ai-assisted-development -n "$NS"        || hint "entry app not synced — ws reset ai-assisted-development --user ${USER_NAME}"
check "scoped ServiceAccount mcp-agent present"      oc get sa "$SA" -n "$NS"               || hint "the MCP server's least-privilege SA is missing — ws reset ai-assisted-development --user ${USER_NAME}"
check "mcp-agent read-only RoleBinding (view) present" oc get rolebinding "${SA}-view" -n "$NS" || hint "the namespaced view grant is missing — ws reset ai-assisted-development --user ${USER_NAME}"
check "MCP server deployed + Ready"                  deploy_available kubernetes-mcp-server || hint "kubernetes-mcp-server not Ready — check pods in ${NS} (ws reset ai-assisted-development --user ${USER_NAME}); pulls the digest-pinned ghcr.io/containers/kubernetes-mcp-server"
check "MaaS config present (endpoint + model)"       oc get cm maas-config -n "$NS"         || hint "entry app not synced — ws reset ai-assisted-development --user ${USER_NAME}"
check "MaaS credentials Secret present"              oc get secret maas-credentials -n "$NS" || hint "the MaaS copy hook did not run — ws reset ai-assisted-development --user ${USER_NAME}"
check "Dev Spaces workspace present"                 oc get devworkspaces.workspace.devfile.io "$(oc get cm ws-entry-ai-assisted-development -n "$NS" -o jsonpath='{.data.devWorkspaceName}' 2>/dev/null || echo parasol-ai-assist)" -n "$NS" \
  || hint "the DevWorkspace is missing — ws reset ai-assisted-development --user ${USER_NAME}"

# INFO: the pinned MCP image + converged model (proves digest-pin + per-cluster secret-sourcing).
info "MCP server image: $(oc get cm ws-entry-ai-assisted-development -n "$NS" -o jsonpath='{.data.mcpServerImage}' 2>/dev/null || echo '?')"
info "agent model (maas-config): $(oc get cm maas-config -n "$NS" -o jsonpath='{.data.model}' 2>/dev/null || echo '?')"

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
  check "seeded parasol-claims FIXED + Ready (probe patched to the correct path)" deploy_available "$SEED" \
    || hint "parasol-claims is still 0/1 — the readinessProbe path was not fixed; ws solve ai-assisted-development --user ${USER_NAME} (or let the agent patch it), then retry"
fi

verify_summary
