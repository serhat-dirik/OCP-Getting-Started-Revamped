#!/usr/bin/env bash
# Verify service-mesh-advanced-gateways — Service Mesh 3 & Advanced Gateways.
#   Entry: {user}-mesh holds the UN-MESHED chain parasol-web -> parasol-claims -> parasol-fraud ->
#          ephemeral claims-db on ClusterIP-only Services, a demo-client verification pod (pinned OUT of
#          the mesh), and a legacy-partner raw-TCP backend. The namespace carries istio-discovery=enabled
#          (workshop layer) but NOT istio-injection — no pod has a sidecar, and there are no mesh CRs.
#          Entry marker set.
#   End:   the attendee enrolled + shaped the mesh — the app tier (web/claims/fraud) carries istio-proxy
#          sidecars, a DestinationRule (subsets + circuit breaker) and a weighted/header VirtualService
#          route claims->fraud, an AuthorizationPolicy lets only claims call fraud, and a fraud v2 exists.
# Runnable as the ATTENDEE: reads only {user}-mesh objects the attendee sees via namespace admin (istio
# CRDs aggregate to the admin role). The G1 cockpit smoke runs `--entry-only` as {user}.
#
# MESH NOTE: OSSM3 1.28 injects the sidecar as a NATIVE SIDECAR — istio-proxy is an initContainer
# (restartPolicy Always), NOT a regular container — so "meshed?" checks BOTH initContainers/containers
# and the sidecar.istio.io/status annotation (verified live 2026-07-13).
# IMAGE-GAP NOTE: parasol-web/claims/fraud run parasol-images/* (workshop image-load step). Their
# Deployments are asserted PRESENT (materialization is the entry state's job); the tiers on always-present
# platform images (claims-db=postgresql, demo-client/partner-tcp-backend=tools) are asserted READY.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-mesh"

# --- helpers (oc only) -------------------------------------------------------

# Every read below goes through _lib.sh's oc_read/oc_present/oc_absent rather than `2>/dev/null` or
# `>/dev/null 2>&1`, which cannot tell "the object is not there" (a gradeable ❌) from "the cluster did
# not answer" (a ⚠ that is never the attendee's fault). oc_read raises VERIFY_INCONCLUSIVE so check()
# picks the right one; the predicates only have to stop turning "could not ask" into an answer.

# A Deployment exists (materialized) in {user}-mesh.
deploy_present() { oc_present get deploy "$1" -n "$NS" -o name; }

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# The {user}-mesh namespace carries istio-discovery=enabled (workshop-layer per-user-mesh contract — the
# label that scopes the shared OSSM3 istiod's discoverySelectors to this tenant). Fail-loud if missing.
ns_discovery_labeled() {
  oc_read get ns "$NS" -o jsonpath='{.metadata.labels.istio-discovery}' || return 1
  [[ "$OC_OUT" == "enabled" ]]
}

# The namespace is NOT injection-labelled (the attendee enrolls it in the first lab beat). Namespace
# must actually exist first — otherwise an empty label read is vacuous, not evidence of a clean entry.
# The label read is now graded too: an EMPTY string used to mean both "no such label" and "the API never
# answered", and this check reads the second as a clean entry state — which sends `ws prep` down its
# "already prepared" fast path on a world nobody could inspect.
ns_not_injection_labeled() {
  oc_present get ns "$NS" -o name || return 1
  oc_read get ns "$NS" -o jsonpath='{.metadata.labels.istio-injection}' || return 1
  [[ -z "$OC_OUT" ]]
}

# Is the app=$1 tier MESHED? Returns 0 if ANY pod for app=$1 carries the istio-proxy sidecar. Scans ALL
# matching pods (not head -1) on purpose: app=parasol-fraud matches BOTH the v1 and v2 Deployments, and a
# rolling update can briefly leave an old un-injected ReplicaSet pod alongside the new injected one — a
# head -1 check would flake on either. OSSM3 1.28 native sidecar → istio-proxy is an initContainer; the
# sidecar.istio.io/status annotation is the most robust signal (present iff injected).
#
# THREE outcomes, not two, and that is what claims_unmeshed() below needs: rc 1 ("the API answered and
# nothing carries a sidecar") and rc 2 ("the API could not be asked") were the same empty pod list
# before, so negating this predicate certified an UN-meshed entry state from a cluster that never
# replied. check() reads the VERIFY_INCONCLUSIVE flag rather than the rc, so rc 2 still renders as ⚠
# at the positive call sites with no change there.
pod_meshed() {  # <app> → 0 meshed · 1 the API answered, no sidecar · 2 the API could not be asked
  local app="$1" pods pod rc
  rc=0; oc_read get pod -n "$NS" -l "app=${app}" -o name || rc=$?
  if (( rc == 2 )); then return 2; fi
  pods="$OC_OUT"
  # while/here-string, not `for pod in $(…)`: a here-string runs the body in THIS shell, so `return 0`
  # from inside the loop actually leaves the function (a pipeline would fork a subshell and lose it).
  while read -r pod; do
    [[ -n "$pod" ]] || continue
    rc=0; oc_read get "$pod" -n "$NS" -o jsonpath='{.metadata.annotations.sidecar\.istio\.io/status}' || rc=$?
    if (( rc == 2 )); then return 2; fi
    if printf '%s' "$OC_OUT" | grep -q istio-proxy; then return 0; fi
    rc=0; oc_read get "$pod" -n "$NS" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' || rc=$?
    if (( rc == 2 )); then return 2; fi
    if printf '%s' "$OC_OUT" | grep -q istio-proxy; then return 0; fi
  done <<< "$pods"
  return 1
}

# Mesh config CRs in {user}-mesh (namespaced; attendee admin reads them via the aggregated admin role).
vs_present() { oc_present get virtualservice "$1" -n "$NS" -o name; }
dr_present() { oc_present get destinationrule "$1" -n "$NS" -o name; }
ap_present() { oc_present get authorizationpolicy "$1" -n "$NS" -o name; }

# Entry-clean-slate helpers: return 0 when the solve object is ABSENT (attendee has built nothing).
# Each requires the namespace to actually exist first — otherwise "absent" is vacuous (true on a
# cluster where nothing materialized at all), not evidence of a clean, correctly-seeded entry state.
claims_unmeshed() {
  local rc=0
  oc_present get ns "$NS" -o name || return 1
  # NOT `! pod_meshed …`: that negation turned "could not ask" into "definitely un-meshed". Branch on
  # pod_meshed's third outcome instead, so an unreachable API leaves VERIFY_INCONCLUSIVE set and check()
  # reports ⚠ rather than a green entry state nobody was able to observe.
  pod_meshed parasol-claims || rc=$?
  if (( rc == 2 )); then return 1; fi
  (( rc == 1 ))
}
no_mesh_config() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent get virtualservice,destinationrule,authorizationpolicy -n "$NS" -o name
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                          || hint "run: ws prep service-mesh-advanced-gateways (or ws start service-mesh-advanced-gateways --user ${USER_NAME}); the ${NS} namespace is workshop-layer (per-user-mesh)"
check "${NS} is istio-discovery=enabled (mesh tenant)"  ns_discovery_labeled                     || hint "the workshop layer must label ${NS} istio-discovery=enabled — sync gitops/workshop-config (per-user-mesh.yaml)"
check "entry marker ws-entry-service-mesh-advanced-gateways present"               oc get cm ws-entry-service-mesh-advanced-gateways -n "$NS"          || hint "entry app not synced — ws reset service-mesh-advanced-gateways --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db                   || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-fraud deployment present"                deploy_present parasol-fraud             || hint "entry app not synced — ws reset service-mesh-advanced-gateways --user ${USER_NAME}"
check "parasol-claims deployment present"               deploy_present parasol-claims            || hint "entry app not synced — ws reset service-mesh-advanced-gateways --user ${USER_NAME}"
check "parasol-web deployment present"                  deploy_present parasol-web               || hint "entry app not synced — ws reset service-mesh-advanced-gateways --user ${USER_NAME}"
check "demo-client deployment has >=1 ready replica"    deploy_ready demo-client                 || hint "the in-cluster verification pod isn't up — oc get pods -l app=demo-client -n ${NS}"
check "partner-tcp-backend has >=1 ready replica"       deploy_ready partner-tcp-backend         || hint "the legacy-partner raw-TCP backend isn't up — oc get pods -l app=partner-tcp-backend -n ${NS}"

# INFO: parasol app tiers need the parasol-images imagestreams (workshop image-load step). Presence is
# asserted above; readiness is a cluster-provisioning concern, not an entry defect.
if ! deploy_ready parasol-claims || ! deploy_ready parasol-web || ! deploy_ready parasol-fraud; then
  info "(parasol-web/claims/fraud not all Ready — expected until the parasol-images build populates the app images; the db/demo-client/partner tiers use always-present platform images)"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — UN-MESHED, no enrollment, no mesh config ------------------------------
  check "${NS} NOT istio-injection-labelled yet (attendee enrolls it)" ns_not_injection_labeled       || hint "entry ships un-enrolled; if istio-injection is set the lab already started — ws reset service-mesh-advanced-gateways --user ${USER_NAME}"
  check "parasol-claims is UN-meshed (no sidecar yet)"                 claims_unmeshed                  || hint "a sidecar is present; the lab already enrolled the namespace — ws reset service-mesh-advanced-gateways --user ${USER_NAME}"
  check "no mesh config CRs yet (attendee creates VS/DR/AuthorizationPolicy)" no_mesh_config            || hint "entry ships no istio CRs; if VirtualService/DestinationRule/AuthorizationPolicy exist the lab already started — ws reset service-mesh-advanced-gateways --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOMES — enrolled + traffic-managed + secured ------------------------------
  # Assert OUTCOMES (app meshed; a weighted route, a circuit-breaker DR, an authz policy, a v2 exist),
  # never the exact CR wording, so any correct solution stays green (rule 14).
  check "parasol-claims is MESHED (istio-proxy sidecar)"        pod_meshed parasol-claims      || hint "enroll per WORKLOAD, not the namespace — namespace-level istio-injection is cluster-admin-only (you'll get Forbidden, see exercise 1): oc patch deploy parasol-claims -n ${NS} --type=merge -p '{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"sidecar.istio.io/inject\":\"true\"}}}}}' && oc rollout status deploy/parasol-claims -n ${NS}"
  check "parasol-fraud is MESHED (istio-proxy sidecar)"         pod_meshed parasol-fraud       || hint "same per-workload fix as claims (not the namespace): oc patch deploy parasol-fraud -n ${NS} --type=merge -p '{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"sidecar.istio.io/inject\":\"true\"}}}}}' && oc rollout status deploy/parasol-fraud -n ${NS}"
  check "fraud v2 Deployment present (weighted-shift target)"   deploy_present parasol-fraud-v2 || hint "deploy a distinguishable parasol-fraud v2 (version:v2 label) for the 90/10 shift"
  check "DestinationRule parasol-fraud present (subsets + circuit breaker)" dr_present parasol-fraud \
    || hint "create a DestinationRule on host parasol-fraud with v1/v2 subsets + outlierDetection (see the lab)"
  check "VirtualService parasol-fraud present (weighted / header route)"    vs_present parasol-fraud \
    || hint "create a VirtualService on host parasol-fraud with a 90/10 v1/v2 split (see the lab)"
  check "AuthorizationPolicy present (only claims may call fraud)"          ap_present fraud-allow-claims \
    || hint "create an ALLOW AuthorizationPolicy on app=parasol-fraud scoped to claims' ServiceAccount principal"
fi

verify_summary
