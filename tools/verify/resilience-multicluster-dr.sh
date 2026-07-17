#!/usr/bin/env bash
# Verify resilience-multicluster-dr — Resilience, Multi-Cluster & DR (APPLICATION-LEVEL cross-site failover).
#   Entry: three per-user namespaces, all istio-discovery=enabled (mesh tenants). {user}-site-a and
#          {user}-site-b each run a RESILIENT claims service (parasol-claims: >=2 replicas + PDB + HPA +
#          topologySpread + probes, meshed), echoing SITE=A / SITE=B. {user}-client runs the external
#          curl-loop client and the mesh ingress gateway (the stable endpoint). NO failover routing yet —
#          the stable endpoint 404s until the attendee wires it. Entry marker set.
#   End:   the attendee built the cross-site failover routing on OSSM3 — a ServiceEntry + DestinationRule
#          (locality LB + outlier detection) + a VirtualService on the gateway (retries). The graded OUTCOME,
#          asserted ACTIVELY and mechanism-agnostic: with site-a scaled to 0 (the "site fails"), the client
#          is still served — by site-b — over the stable endpoint (rule 14: assert the outcome, not the CRs).
# Runnable as the ATTENDEE: reads/execs only client/site-a/site-b objects the attendee sees via namespace
# admin (istio CRDs aggregate to the admin role). The G1 cockpit smoke runs `--entry-only` as {user}.
#
# MESH NOTE: OSSM3 1.28 injects the sidecar as a NATIVE SIDECAR (istio-proxy is an initContainer). The
# claims responder + client run on always-present platform imagestreams (nodejs / tools), so readiness is
# asserted directly — there is no parasol-image build gap here.
# END-MODE MUTATION: the failover proof briefly scales site-a to 0 and restores it (with a trap so site-a
# is always restored). It runs LAST, only in full/end mode, never at --entry-only.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
CLIENT_NS="${USER_NAME}-client"
SITEA_NS="${USER_NAME}-site-a"
SITEB_NS="${USER_NAME}-site-b"
SITEA_RESTORE=""   # set by failover_proof; used by the EXIT trap to guarantee site-a is restored

# --- helpers (oc only) -------------------------------------------------------

# A Deployment exists (materialized) in a namespace: $1=name $2=namespace.
deploy_present() { oc get deploy "$1" -n "$2" >/dev/null 2>&1; }

# A Deployment has at least one ready replica: $1=name $2=namespace.
deploy_ready() {
  local ready
  ready="$(oc get deploy "$1" -n "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# A namespace carries istio-discovery=enabled (the shared-istiod discoverySelectors label): $1=namespace.
ns_discovery_labeled() {
  [[ "$(oc get ns "$1" -o jsonpath='{.metadata.labels.istio-discovery}' 2>/dev/null || true)" == "enabled" ]]
}

# A site's claims service is RESILIENT: the Deployment is present with >=2 desired replicas, a PDB, and an
# HPA (the observability-health-scale/deployment-targets-scheduling primitives the in-site resiliency beat leans on): $1=namespace.
site_resilient() {
  local ns="$1" reps
  oc get deploy parasol-claims -n "$ns" >/dev/null 2>&1 || return 1
  oc get poddisruptionbudget parasol-claims -n "$ns" >/dev/null 2>&1 || return 1
  oc get horizontalpodautoscaler parasol-claims -n "$ns" >/dev/null 2>&1 || return 1
  reps="$(oc get deploy parasol-claims -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  [[ -n "$reps" && "$reps" -ge 2 ]]
}

# Failover routing CRs the attendee builds (namespaced in the client ns; attendee admin reads them).
se_present() { oc get serviceentry "$1" -n "$CLIENT_NS" >/dev/null 2>&1; }
vs_present() { oc get virtualservice "$1" -n "$CLIENT_NS" >/dev/null 2>&1; }
dr_present() { oc get destinationrule "$1" -n "$CLIENT_NS" >/dev/null 2>&1; }

# Any ServiceEntry AND any VirtualService exist in the client ns (mechanism-agnostic: don't pin the names).
failover_routing_present() {
  [[ -n "$(oc get serviceentry -n "$CLIENT_NS" -o name 2>/dev/null || true)" ]] &&
  [[ -n "$(oc get virtualservice -n "$CLIENT_NS" -o name 2>/dev/null || true)" ]]
}
# Entry clean-slate: NO failover routing yet (attendee builds the ServiceEntry + VirtualService).
no_failover_routing() {
  [[ -z "$(oc get serviceentry,virtualservice -n "$CLIENT_NS" -o name 2>/dev/null || true)" ]]
}

# The stable endpoint (the ingress gateway) serves HTTP 200 to the client (routing is wired).
stable_serves() {
  local code
  code="$(oc exec deploy/claims-client -n "$CLIENT_NS" -- \
    curl -s -m5 -o /dev/null -w '%{http_code}' http://claims-stable/ 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

# Which SITE (A/B) the stable endpoint currently returns (empty on any failure).
served_site() {
  oc exec deploy/claims-client -n "$CLIENT_NS" -- curl -s -m3 http://claims-stable/ 2>/dev/null \
    | sed -n 's/.*"site":"\([AB]\)".*/\1/p' 2>/dev/null || true
}

# ACTIVE failover proof (mechanism-agnostic, rule-14 outcome): save site-a's replica count, scale it to 0
# ("the site fails"), and confirm the client is STILL served — by site-b — through the stable endpoint
# within a generous window; then restore site-a and wait for it healthy. >= semantics: a single site-b
# response is a pass. Always restores site-a (also via the EXIT trap) so a false ❌ never leaves it down.
failover_proof() {
  local orig site deadline got_b=0
  orig="$(oc get deploy parasol-claims -n "$SITEA_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 3)"
  [[ -z "$orig" || "$orig" -lt 1 ]] && orig=3
  SITEA_RESTORE="$orig"
  oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas=0 >/dev/null 2>&1 || true
  deadline=$(( $(date +%s) + 45 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    site="$(served_site)"
    [[ "$site" == "B" ]] && { got_b=1; break; }
    sleep 3
  done
  oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas="$orig" >/dev/null 2>&1 || true
  oc rollout status deploy/parasol-claims -n "$SITEA_NS" --timeout=60s >/dev/null 2>&1 || true
  [[ "$got_b" == "1" ]]
}

# Solve marker (end-state only) lives in the client ns.
solved() { oc get cm ws-solve-resilience-multicluster-dr -n "$CLIENT_NS" >/dev/null 2>&1; }
not_solved() { ! solved; }

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${CLIENT_NS} exists"                  oc get ns "$CLIENT_NS"                   || hint "run: ws prep resilience-multicluster-dr (or ws start resilience-multicluster-dr --user ${USER_NAME}); the three namespaces are workshop-layer (per-user-resilience)"
check "namespace ${SITEA_NS} exists"                   oc get ns "$SITEA_NS"                    || hint "the ${SITEA_NS} namespace is workshop-layer — sync gitops/workshop-config (per-user-resilience.yaml)"
check "namespace ${SITEB_NS} exists"                   oc get ns "$SITEB_NS"                    || hint "the ${SITEB_NS} namespace is workshop-layer — sync gitops/workshop-config (per-user-resilience.yaml)"
check "${CLIENT_NS} is istio-discovery=enabled (mesh tenant)" ns_discovery_labeled "$CLIENT_NS" || hint "the workshop layer must label ${CLIENT_NS} istio-discovery=enabled — sync per-user-resilience.yaml"
check "${SITEA_NS} is istio-discovery=enabled (mesh tenant)"  ns_discovery_labeled "$SITEA_NS"  || hint "the workshop layer must label ${SITEA_NS} istio-discovery=enabled — sync per-user-resilience.yaml"
check "${SITEB_NS} is istio-discovery=enabled (mesh tenant)"  ns_discovery_labeled "$SITEB_NS"  || hint "the workshop layer must label ${SITEB_NS} istio-discovery=enabled — sync per-user-resilience.yaml"
check "entry marker ws-entry-resilience-multicluster-dr present"              oc get cm ws-entry-resilience-multicluster-dr -n "$CLIENT_NS"   || hint "entry app not synced — ws reset resilience-multicluster-dr --user ${USER_NAME}"
check "site-a claims service is RESILIENT (>=2 replicas + PDB + HPA)" site_resilient "$SITEA_NS" || hint "the primary site must be resilient — ws reset resilience-multicluster-dr --user ${USER_NAME}"
check "site-b claims service is RESILIENT (>=2 replicas + PDB + HPA)" site_resilient "$SITEB_NS" || hint "the secondary site must be resilient — ws reset resilience-multicluster-dr --user ${USER_NAME}"
check "site-a claims has >=1 ready replica"            deploy_ready parasol-claims "$SITEA_NS"   || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${SITEA_NS}"
check "site-b claims has >=1 ready replica"            deploy_ready parasol-claims "$SITEB_NS"   || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${SITEB_NS}"
check "external client (claims-client) has >=1 ready replica" deploy_ready claims-client "$CLIENT_NS" || hint "the client loop isn't up — oc get pods -l app=claims-client -n ${CLIENT_NS}"
check "mesh ingress gateway (claims-gateway) has >=1 ready replica" deploy_ready claims-gateway "$CLIENT_NS" || hint "the stable endpoint isn't up — oc get pods -l istio=claims-gateway -n ${CLIENT_NS}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — sites up, gateway up, but NO failover routing wired yet ----------------
  check "no failover routing yet (attendee builds ServiceEntry + VirtualService)" no_failover_routing \
    || hint "entry ships no failover routing; if a ServiceEntry/VirtualService exists the lab already ran — ws reset resilience-multicluster-dr --user ${USER_NAME}"
  check "no solve marker yet (ws-solve-resilience-multicluster-dr absent)"    not_solved \
    || hint "a solve/end marker exists; the lab already ran — ws reset resilience-multicluster-dr --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — cross-site failover configured AND proven -------------------------
  # Restore site-a on ANY exit so an interrupted probe never leaves the primary scaled down.
  trap 'oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas="${SITEA_RESTORE:-3}" >/dev/null 2>&1 || true' EXIT
  check "failover routing present (ServiceEntry + VirtualService on the gateway)" failover_routing_present \
    || hint "build the failover routing: a ServiceEntry spanning both sites, a DestinationRule (locality LB + outlier detection), and a VirtualService with retries on claims-gateway (see the lab)"
  check "the stable endpoint serves HTTP 200"          stable_serves \
    || hint "the ingress gateway isn't routing — check the VirtualService is bound to gateway claims-gateway and the ServiceEntry host matches"
  check "solve marker present (ws-solve-resilience-multicluster-dr)"          solved \
    || hint "mark the failover exercise done — or: ws solve resilience-multicluster-dr --user ${USER_NAME}"
  info "failover drill: briefly scaling site-a to 0 to prove the client fails over to site-b (auto-restores)…"
  check "FAILOVER proven: site-a down -> the client is served by site-b" failover_proof \
    || hint "with site-a scaled to 0 the client should be served by site-b within ~30s — check the DestinationRule outlierDetection + locality LB and the VirtualService retries"
fi

verify_summary
