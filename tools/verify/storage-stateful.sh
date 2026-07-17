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

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The claims Route answers HTTP 200 on the readiness endpoint (also proves the app reached
# its datasource — readiness gates on the DB connection). parasol-claims is API-only, so "/"
# is 404 by design; probe /q/health/ready.
route_ready_200() {
  local ns="$1" host code
  host="$(oc get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# The name of the cluster's default StorageClass (annotation is-default-class=true), or empty.
default_sc() {
  oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1
}

# A default StorageClass is set — without one, a PVC that omits storageClassName cannot bind.
has_default_sc() { [[ -n "$(default_sc)" ]]; }

# A PVC exists and is Bound.
pvc_bound() {
  local name="$1" ns="$2" phase
  phase="$(oc get pvc "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Bound" ]]
}

# The claims-db Deployment's data volume is an emptyDir (ephemeral entry state).
claims_db_ephemeral() {
  oc get deploy claims-db -n "$NS" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].emptyDir}' 2>/dev/null | grep -q '{}'
}

# The claims-db Deployment's data volume is a PVC named claims-db-data (persistent end state).
claims_db_persistent() {
  local claim
  claim="$(oc get deploy claims-db -n "$NS" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}' 2>/dev/null || true)"
  [[ "$claim" == "claims-db-data" ]]
}

# There are zero PVCs in the namespace (entry state — persistence exercise not started).
no_pvcs_yet() {
  local n
  n="$(oc get pvc -n "$NS" --no-headers 2>/dev/null | grep -c . || true)"
  [[ "$n" -eq 0 ]]
}

# The StatefulSet has all replicas ready (readyReplicas == spec.replicas, and >= 2).
sts_ready() {
  local name="$1" ns="$2" want ready
  want="$(oc get statefulset "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ready="$(oc get statefulset "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$want" && -n "$ready" && "$ready" == "$want" && "$ready" -ge 2 ]]
}

# The pg-sts Service is headless (clusterIP: None).
headless_svc() {
  local ip
  ip="$(oc get svc pg-sts -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [[ "$ip" == "None" ]]
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
  check "a default StorageClass exists on this cluster" has_default_sc                               || hint "no default StorageClass — a PVC with no storageClassName cannot bind; set one as default"
  check "claims-db now backed by PVC claims-db-data"    claims_db_persistent                          || hint "add persistence: oc set volume deploy/claims-db --add --overwrite --name data -t pvc --claim-name=claims-db-data --claim-size=2Gi --mount-path=/var/lib/pgsql/data -n ${NS}"
  check "PVC claims-db-data is Bound"                   pvc_bound claims-db-data "$NS"                 || hint "PVC pending — WaitForFirstConsumer binds when a pod schedules; check: oc get pvc claims-db-data -n ${NS}"
  check "StatefulSet pg-sts is 2/2 ready"               sts_ready pg-sts "$NS"                         || hint "deploy the StatefulSet exercise; wait: oc rollout status statefulset/pg-sts -n ${NS}"
  check "per-pod PVC data-pg-sts-0 is Bound"            pvc_bound data-pg-sts-0 "$NS"                  || hint "StatefulSet volumeClaimTemplate PVC missing — check: oc get pvc -n ${NS}"
  check "per-pod PVC data-pg-sts-1 is Bound"            pvc_bound data-pg-sts-1 "$NS"                  || hint "StatefulSet volumeClaimTemplate PVC missing — check: oc get pvc -n ${NS}"
  check "pg-sts Service is headless (clusterIP None)"   headless_svc                                   || hint "headless Service missing — a StatefulSet needs a headless Service for stable DNS"
fi

verify_summary
