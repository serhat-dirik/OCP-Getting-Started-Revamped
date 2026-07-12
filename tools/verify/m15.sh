#!/usr/bin/env bash
# Verify M15 — Networking for Dev & DevOps.
#   Entry: {user}-dev holds the 3-tier claims app (parasol-web + parasol-claims + ephemeral
#          claims-db) on ClusterIP-only Services (NO Route/NodePort/HTTPRoute — the attendee builds
#          every exposure), a demo-client verification pod, and NO NetworkPolicies. {user}-partner
#          holds a Layer2 Primary UDN + a workload on it (native isolation). Entry marker set.
#   End:   the attendee ran the lab — default-deny + precise-allow NetworkPolicies are in place, an
#          edge Route exposes parasol-web, and an unauthorized pod (demo-client) can no longer reach
#          claims-db (the "db only from api" outcome).
# Runnable as the ATTENDEE: reads only {user}-dev|partner objects the attendee sees via namespace
# admin, plus the partner UDN via the platform-observer ClusterRole (which grants k8s.ovn.org read).
# The G1 cockpit smoke runs `--entry-only` as {user}.
#
# IMAGE-GAP NOTE: parasol-web/parasol-claims run the parasol-images/* images (populated by the
# workshop image-load step, like every dev module). Their Deployments are asserted PRESENT (the
# entry state's job is to materialize them correctly), while the tiers that run on always-present
# platform images (claims-db=postgresql, demo-client/partner-workload=tools) are asserted READY.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
PARTNER="${USER_NAME}-partner"

# --- helpers (oc only) -------------------------------------------------------

# A Deployment exists (materialized) in a namespace.
deploy_present() { oc get deploy "$1" -n "$2" >/dev/null 2>&1; }

# A Deployment has at least one ready replica.
deploy_ready() {
  local ready
  ready="$(oc get deploy "$1" -n "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# A NetworkPolicy exists in {user}-dev.
np_present() { oc get networkpolicy "$1" -n "$NS" >/dev/null 2>&1; }

# The partner UDN exists (proves the labeled namespace + UDN materialized).
udn_present() { oc get userdefinednetwork partner-udn -n "$PARTNER" >/dev/null 2>&1; }

# Entry-clean-slate helpers: return 0 when the solve object is ABSENT (nothing built yet).
no_default_deny() { ! oc get networkpolicy default-deny-all -n "$NS" >/dev/null 2>&1; }
no_web_route()    { ! oc get route parasol-web -n "$NS" >/dev/null 2>&1; }

# From the demo-client pod, is claims-db:5432 BLOCKED? Returns 0 (success) when the connection does
# NOT open — the "db only from api" outcome, since demo-client is not an app=parasol-claims pod. A
# netpol drop makes the connect time out (timeout → non-zero); an open connect exits 0 → NOT blocked.
db_blocked_from_demo_client() {
  ! oc exec deploy/demo-client -n "$NS" -- timeout 5 bash -c '</dev/tcp/claims-db/5432' >/dev/null 2>&1
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                          || hint "run: ws prep m15 (or ws start m15 --user ${USER_NAME})"
check "entry marker ws-entry-m15 present"               oc get cm ws-entry-m15 -n "$NS"          || hint "entry app not synced — ws reset m15 --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db "$NS"             || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment present"               deploy_present parasol-claims "$NS"      || hint "entry app not synced — ws reset m15 --user ${USER_NAME}"
check "parasol-web deployment present"                  deploy_present parasol-web "$NS"         || hint "entry app not synced — ws reset m15 --user ${USER_NAME}"
check "demo-client deployment has >=1 ready replica"    deploy_ready demo-client "$NS"           || hint "the in-cluster verification pod isn't up — oc get pods -l app=demo-client -n ${NS}"
check "partner UDN partner-udn present in ${PARTNER}"   udn_present                              || hint "partner namespace/UDN missing — ${PARTNER} must exist (workshop layer) and the entry app be synced"
check "partner-workload has >=1 ready replica (on UDN)" deploy_ready partner-workload "$PARTNER" || hint "the UDN-attached workload isn't up — oc get pods -n ${PARTNER} (a slow first attach is normal)"

# INFO: parasol-web/parasol-claims readiness needs the parasol-images imagestreams (workshop image-load
# step). Presence is asserted above; readiness is a cluster-provisioning concern, not an entry defect.
if ! deploy_ready parasol-claims "$NS" || ! deploy_ready parasol-web "$NS"; then
  info "(parasol-web/parasol-claims not Ready — expected until the parasol-images build populates the app images; the DB/demo-client/partner tiers use always-present platform images)"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — the attendee has built NO exposure and NO policy yet -------------
  check "no default-deny NetworkPolicy yet (attendee writes it)"  no_default_deny || hint "entry ships no NetworkPolicies; if present the lab already started — ws reset m15 --user ${USER_NAME}"
  check "no parasol-web Route yet (attendee exposes it)"          no_web_route    || hint "entry ships ClusterIP-only; if a Route exists the lab already started — ws reset m15 --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — micro-segmentation + exposure in place -----------------------
  # Assert OUTCOMES (a policy exists and blocks; a Route exists), never the exact rule wording, so any
  # correct solution stays green (template rule 14).
  check "default-deny NetworkPolicy present"              np_present default-deny-all             || hint "create a default-deny (ingress+egress) NetworkPolicy in ${NS} (see the lab)"
  check "DNS egress allowed (else the fix looks broken)"  np_present allow-dns-egress             || hint "add an egress allow to openshift-dns:53 — default-deny blocks DNS too"
  check "'api only from web' policy present"              np_present allow-claims-from-web        || hint "allow ingress to parasol-claims:8080 only from parasol-web pods"
  check "'db only from api' policy present"               np_present allow-db-from-claims         || hint "allow ingress to claims-db:5432 only from parasol-claims pods"
  check "parasol-web is exposed via a Route"              oc get route parasol-web -n "$NS"       || hint "expose parasol-web: oc create route edge parasol-web --service=parasol-web -n ${NS}"
  # Behavioural proof — only meaningful when the substrate (claims-db + demo-client) is up, which it is
  # on any cluster (platform images). demo-client is NOT app=parasol-claims, so default-deny + the
  # 'db only from api' allow must BLOCK it. A >= -style outcome check: it must be UNreachable.
  if deploy_ready claims-db "$NS" && deploy_ready demo-client "$NS"; then
    check "unauthorized pod CANNOT reach claims-db:5432 (policy blocks it)" db_blocked_from_demo_client || hint "the 'db only from api' policy must drop demo-client→claims-db; check default-deny + allow-db-from-claims"
  else
    info "(skipped the live db-block probe — claims-db/demo-client not both Ready)"
  fi
fi

verify_summary
