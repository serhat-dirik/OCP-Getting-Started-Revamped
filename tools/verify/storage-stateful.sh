#!/usr/bin/env bash
# Verify storage-stateful — Storage & Stateful Apps.
#   Entry: {user}-dev has the claims app + an EPHEMERAL PostgreSQL (emptyDir, NO PVC yet);
#          entry marker + quota present.
#   End:   the claims DB is backed by a bound PVC, and a 2-replica PostgreSQL StatefulSet
#          (pg-sts) with a headless Service and per-pod PVCs (data-pg-sts-0/1) is running.
# Portable across clusters: the default StorageClass is DETECTED, never hardcoded (the build
# cluster is ODF/Ceph; another cluster may default to EBS/other — the checks assert behavior,
# not a class name). Runnable as the attendee (oc + curl only). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# Every oc read in the helpers below goes through oc_read (_lib.sh) rather than `2>/dev/null`, so a
# cluster that could not be asked reports ⚠ SKIP instead of blaming the attendee's storage work.
# curl probes stay graded on purpose: "the app does not answer" IS an outcome these checks measure.

# The claims Route answers HTTP 200 on the readiness endpoint (also proves the app reached
# its datasource — readiness gates on the DB connection). parasol-claims is API-only, so "/"
# is 404 by design; probe /q/health/ready.
route_ready_200() {
  local ns="$1" host code
  oc_read get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# A default StorageClass is set — without one, a PVC that omits storageClassName cannot bind.
has_default_sc() {
  oc_read get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' || return 1
  [[ -n "${OC_OUT%%$'\n'*}" ]]
}

# A PVC exists and is Bound.
pvc_bound() {
  oc_read get pvc "$1" -n "$2" -o jsonpath='{.status.phase}' || return 1
  [[ "$OC_OUT" == "Bound" ]]
}

# The claims-db Deployment's data volume is an emptyDir (ephemeral entry state).
claims_db_ephemeral() {
  oc_read get deploy claims-db -n "$NS" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].emptyDir}' || return 1
  [[ "$OC_OUT" == *'{}'* ]]
}

# The claims-db Deployment's data volume is a PVC named claims-db-data (persistent end state).
claims_db_persistent() {
  oc_read get deploy claims-db -n "$NS" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}' || return 1
  [[ "$OC_OUT" == "claims-db-data" ]]
}

# There are zero PVCs in the namespace (entry state — persistence exercise not started). Namespace
# must actually exist first — otherwise a zero count is vacuous, not evidence of a clean entry.
# An UNANSWERABLE list must not read as "zero": that is the one way this fix could invent a pass.
no_pvcs_yet() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent  get pvc -n "$NS" -o name
}

# The StatefulSet has all replicas ready (readyReplicas == spec.replicas, and >= 2).
sts_ready() {
  local name="$1" ns="$2" want
  oc_read get statefulset "$name" -n "$ns" -o jsonpath='{.spec.replicas}' || return 1
  want="$OC_OUT"
  oc_read get statefulset "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' || return 1
  [[ -n "$want" && -n "$OC_OUT" && "$OC_OUT" == "$want" && "$OC_OUT" -ge 2 ]]
}

# The pg-sts Service is headless (clusterIP: None).
headless_svc() {
  oc_read get svc pg-sts -n "$NS" -o jsonpath='{.spec.clusterIP}' || return 1
  [[ "$OC_OUT" == "None" ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                              || hint "run: ws start storage-stateful --user ${USER_NAME}"
check "entry marker ws-entry-storage-stateful present"               oc get cm ws-entry-storage-stateful -n "$NS"              || hint "entry app not synced — ws start storage-stateful --user ${USER_NAME}"
check "workshop quota present in ${NS}"                 oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db "$NS"                 || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica" deploy_ready parasol-claims "$NS"            || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "route parasol-claims answers 200 (/q/health/ready)" route_ready_200 "$NS"                     || hint "claims app not ready — check: oc get pods -n ${NS}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the DB is EPHEMERAL and no PVC exists yet ----------------
  check "claims-db data volume is emptyDir (ephemeral)" claims_db_ephemeral                          || hint "entry DB should be ephemeral — ws reset storage-stateful --user ${USER_NAME}"
  check "no PVC in ${NS} yet (persistence exercise not started)" no_pvcs_yet                          || hint "entry state has no PVCs — ws reset storage-stateful --user ${USER_NAME}"
else
  # --- end state: persistent claims DB + the StatefulSet ---------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  # The first one is NOT an attendee outcome — it is a property of the cluster, red whether or not the
  # lab was done, and the only line in this section where "tell your instructor" is the right advice.
  check "a default StorageClass exists on this cluster" has_default_sc                               || hint "this one is broken, not undone — nothing you do in the lab creates a StorageClass. Without a default, a PVC that names no storageClassName can never bind, so the exercises below cannot succeed on this cluster: show your instructor 'oc get storageclass'"
  check "claims-db now backed by PVC claims-db-data"    claims_db_persistent                          || hint "not done yet — the entry state ships claims-db on an emptyDir on purpose, and giving it a PVC IS the lab: oc set volume deploy/claims-db --add --overwrite --name data -t pvc --claim-name=claims-db-data --claim-size=2Gi --mount-path=/var/lib/pgsql/data -n ${NS}"
  check "PVC claims-db-data is Bound"                   pvc_bound claims-db-data "$NS"                 || hint "not done yet? if the PVC does not exist yet this follows from the check above and is equally expected. If it EXISTS and is Pending, that is usually normal: WaitForFirstConsumer binds only when a pod schedules — oc get pvc claims-db-data -n ${NS} and look at its events before treating it as broken"
  check "StatefulSet pg-sts is 2/2 ready"               sts_ready pg-sts "$NS"                         || hint "not done yet? deploying pg-sts is the StatefulSet exercise, so this red is expected before you get there. If it EXISTS and is short of 2/2, that one is real: oc rollout status statefulset/pg-sts -n ${NS}"
  check "per-pod PVC data-pg-sts-0 is Bound"            pvc_bound data-pg-sts-0 "$NS"                  || hint "not done yet — this PVC is created by pg-sts's volumeClaimTemplate, so it is expected to be missing until you deploy the StatefulSet: oc get pvc -n ${NS}"
  check "per-pod PVC data-pg-sts-1 is Bound"            pvc_bound data-pg-sts-1 "$NS"                  || hint "not done yet — same volumeClaimTemplate as the pod above; it appears with the second replica, so expected red until pg-sts is deployed and scaled: oc get pvc -n ${NS}"
  check "pg-sts Service is headless (clusterIP None)"   headless_svc                                   || hint "not done yet — you create the headless Service alongside the StatefulSet (it is what gives the pods stable DNS), so it is expected to be missing before that exercise"
fi

verify_summary
