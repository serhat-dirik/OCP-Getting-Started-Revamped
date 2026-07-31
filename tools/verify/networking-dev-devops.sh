#!/usr/bin/env bash
# Verify networking-dev-devops — Networking for Dev & DevOps.
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

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# A NetworkPolicy exists in {user}-dev.
np_present() { oc get networkpolicy "$1" -n "$NS" >/dev/null 2>&1; }

# The partner UDN exists (proves the labeled namespace + UDN materialized).
udn_present() { oc get userdefinednetwork partner-udn -n "$PARTNER" >/dev/null 2>&1; }

# Entry-clean-slate helpers: return 0 when the solve object is ABSENT (nothing built yet).
# Namespace must exist first — otherwise "absent" is vacuous, not evidence of a clean entry state.
no_default_deny() {
  oc get ns "$NS" >/dev/null 2>&1 || return 1
  ! oc get networkpolicy default-deny-all -n "$NS" >/dev/null 2>&1
}
no_web_route() {
  oc get ns "$NS" >/dev/null 2>&1 || return 1
  ! oc get route parasol-web -n "$NS" >/dev/null 2>&1
}

# A Route somewhere in the namespace terminates re-encrypt — the exercise-2 outcome, matched on the
# termination mode rather than on a Route name, so an attendee who names theirs differently still
# passes. Completion-mode only: the entry state ships no Routes at all.
reencrypt_route() {
  [ -n "$(oc get route -n "$NS" \
            -o jsonpath='{.items[?(@.spec.tls.termination=="reencrypt")].metadata.name}' 2>/dev/null)" ]
}

# --- the db-block probe and its CONTROLS -------------------------------------
# Proving micro-segmentation by a command FAILING is only evidence if the same machinery SUCCEEDS
# where it should. `! oc exec … </dev/tcp/claims-db/5432` returns "blocked" for a pod that is
# restarting, an exec the API refuses, an image without bash or timeout, a broken DNS path, a deleted
# claims-db Service and a claims-db that simply is not listening — every one of which would have
# certified the lesson on a namespace where nothing was ever blocked. So three controls run first,
# and the block is graded ONLY behind them. Images verified on-cluster 2026-08-01: the RHEL tools
# image (demo-client) carries bash + timeout + getent, and the parasol-claims runtime
# (ubi9/openjdk-21-runtime) carries bash + timeout.

# Does a TCP connection OPEN from <deployment>'s pod to host:port? Same shape the lab teaches.
tcp_open_from() {  # tcp_open_from <deployment> <host> <port>
  oc exec "deploy/$1" -n "$NS" -- timeout 5 bash -c "</dev/tcp/$2/$3" >/dev/null 2>&1
}

# CONTROL 1 — the probe machinery itself: exec works, and bash+timeout exist in the image.
probe_machinery_ok() {
  oc exec deploy/demo-client -n "$NS" -- timeout 5 bash -c 'exit 0' >/dev/null 2>&1
}

# CONTROL 2 — the NAME resolves from the probing pod: cluster DNS answers (the lab's allow-dns-egress
# is doing its job) and a claims-db Service still exists. Without this, "no route to a name that does
# not resolve" reads identically to "policy dropped the packet".
db_name_resolves_from_demo_client() {
  oc exec deploy/demo-client -n "$NS" -- timeout 5 getent hosts claims-db >/dev/null 2>&1
}

# CONTROL 3 (strongest, needs a Ready parasol-claims) — the POSITIVE control: the same connection
# OPENS from the one identity allow-db-from-claims admits. This is what tells "the policy blocks the
# unauthorized pod" from "nothing can reach this database at all".
db_open_from_allowed_pod() { tcp_open_from parasol-claims claims-db 5432; }

# The graded outcome: from demo-client (NOT app=parasol-claims), claims-db:5432 must NOT open.
db_blocked_from_demo_client() { ! tcp_open_from demo-client claims-db 5432; }

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                          || hint "run: ws prep networking-dev-devops (or ws start networking-dev-devops --user ${USER_NAME})"
check "entry marker ws-entry-networking-dev-devops present"               oc get cm ws-entry-networking-dev-devops -n "$NS"          || hint "entry app not synced — ws reset networking-dev-devops --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db "$NS"             || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment present"               deploy_present parasol-claims "$NS"      || hint "entry app not synced — ws reset networking-dev-devops --user ${USER_NAME}"
check "parasol-web deployment present"                  deploy_present parasol-web "$NS"         || hint "entry app not synced — ws reset networking-dev-devops --user ${USER_NAME}"
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
  check "no default-deny NetworkPolicy yet (attendee writes it)"  no_default_deny || hint "entry ships no NetworkPolicies; if present the lab already started — ws reset networking-dev-devops --user ${USER_NAME}"
  check "no parasol-web Route yet (attendee exposes it)"          no_web_route    || hint "entry ships ClusterIP-only; if a Route exists the lab already started — ws reset networking-dev-devops --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — micro-segmentation + exposure in place -----------------------
  # Assert OUTCOMES (a policy exists and blocks; a Route exists), never the exact rule wording, so any
  # correct solution stays green (template rule 14).
  check "default-deny NetworkPolicy present"              np_present default-deny-all             || hint "create a default-deny (ingress+egress) NetworkPolicy in ${NS} (see the lab)"
  check "DNS egress allowed (else the fix looks broken)"  np_present allow-dns-egress             || hint "add an egress allow to openshift-dns:53 — default-deny blocks DNS too"
  check "'api only from web' policy present"              np_present allow-claims-from-web        || hint "allow ingress to parasol-claims:8080 only from parasol-web pods"
  check "'db only from api' policy present"               np_present allow-db-from-claims         || hint "allow ingress to claims-db:5432 only from parasol-claims pods"
  check "parasol-web is exposed via a Route"              oc get route parasol-web -n "$NS"       || hint "expose parasol-web: oc create route edge parasol-web --service=parasol-web -n ${NS}"
  check "a re-encrypt Route exists (last hop encrypted)"  reencrypt_route                         || hint "the edge Route leaves router→pod in plaintext; re-encrypt it: oc create route reencrypt parasol-web-secure --service=parasol-web --port=https -n ${NS}"
  # Behavioural proof, gated behind its controls (see the helpers above). demo-client is NOT
  # app=parasol-claims, so default-deny + the 'db only from api' allow must BLOCK it — but a probe
  # that has not been shown to work must never be allowed to certify that.
  if ! deploy_ready claims-db "$NS" || ! deploy_ready demo-client "$NS"; then
    warn "the live db-block probe — claims-db/demo-client not both Ready"
  elif ! probe_machinery_ok; then
    warn "cannot grade the db-block outcome — the probe machinery itself does not run (oc exec into demo-client, or bash/timeout in its image)"
    hint "a probe that cannot run proves nothing about what is blocked: oc exec deploy/demo-client -n ${NS} -- timeout 5 bash -c 'exit 0'"
  elif ! db_name_resolves_from_demo_client; then
    warn "cannot grade the db-block outcome — 'claims-db' does not RESOLVE from demo-client, so a failed connect would only prove the name is gone, not that a policy dropped it"
    hint "check the Service and cluster DNS (default-deny blocks DNS too — that is what allow-dns-egress is for): oc get svc claims-db -n ${NS}; oc get networkpolicy allow-dns-egress -n ${NS}"
  elif deploy_ready parasol-claims "$NS" && ! db_open_from_allowed_pod; then
    warn "cannot grade the db-block outcome — the POSITIVE CONTROL failed: claims-db:5432 does not open even from an app=parasol-claims pod, which 'db only from api' is supposed to ALLOW"
    hint "usually the missing EGRESS counterpart — default-deny denies egress too, so parasol-claims needs an egress allow to claims-db:5432 as well as the ingress allow. Reproduce: oc exec deploy/parasol-claims -n ${NS} -- timeout 5 bash -c '</dev/tcp/claims-db/5432'"
  else
    if ! deploy_ready parasol-claims "$NS"; then
      info "(the strongest control could not run — parasol-claims is not Ready, so the allowed-path connection was not proven; grading the block on the machinery + name-resolution controls only)"
    fi
    check "unauthorized pod CANNOT reach claims-db:5432 (allowed path proven first)" db_blocked_from_demo_client \
      || hint "the 'db only from api' policy must drop demo-client→claims-db, and the controls above show the probe works — check default-deny-all + allow-db-from-claims in ${NS}"
  fi
fi

verify_summary
