#!/usr/bin/env bash
# Verify M23 — Jobs, Batch & Queued Workloads.
#   Entry: {user}-batch exists (labeled for Kueue), holds the seeded claims-data PVC, a LocalQueue
#          (user-queue) bound to the per-user ClusterQueue, and MaaS batch-inference credentials;
#          entry marker + quota present.
#   End:   the attendee ran the lab — at least one Job has Completed, the nightly-statement CronJob
#          exists, and a Kueue Workload carries Admitted=True (admission control was exercised).
# Runnable as the ATTENDEE: every check reads namespace-scoped objects the attendee can see
# (Jobs/CronJobs/PVC/Secret/ConfigMap via namespace admin; LocalQueues + Workloads via the
# kueue-batch-user-role bound in the entry state). The cluster-scoped ClusterQueue is NOT readable
# by attendees, so that check AUTO-SKIPS unless the caller has cluster read (admin/CI), mirroring
# the m03 DevWorkspace pattern. See tools/verify/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-batch"
CQ="cq-${USER_NAME}"

# --- helpers (kept dependency-free: oc only) ---------------------------------

# The namespace carries the Kueue opt-in label, without which Kueue ignores labeled Jobs.
ns_kueue_managed() {
  [[ "$(oc get ns "$NS" -o jsonpath='{.metadata.labels.kueue\.openshift\.io/managed}' 2>/dev/null || true)" == "true" ]]
}

# A PVC exists and is Bound.
pvc_bound() {
  [[ "$(oc get pvc "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Bound" ]]
}

# The LocalQueue exists and reports Active=True (its ClusterQueue accepts it).
localqueue_active() {
  oc get localqueue user-queue -n "$NS" >/dev/null 2>&1 || return 1
  [[ "$(oc get localqueue user-queue -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)" == "True" ]]
}

# The dataset seed succeeded. The seed Job is a Sync hook: after `ws start`/`ws reset` it is
# present and Complete, but a completed hook can be cleaned up later — so absence is treated as
# "ran and cleaned up" (the PVC-Bound check covers the volume). A seed Job that is PRESENT but not
# Complete (Failed/Running) is a real problem and fails the check. Gate on the namespace first:
# with the namespace itself missing, "job absent" must read as FAILURE, not cleanup (G3-M23 F4
# false-positive — the check printed green while nothing existed at all).
seed_ok() {
  local job="claims-data-seed-m23-${USER_NAME}"
  oc get ns "$NS" >/dev/null 2>&1 || return 1
  oc get job "$job" -n "$NS" >/dev/null 2>&1 || return 0
  oc get job "$job" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q True
}

# At least one Job in the namespace has Completed (end state).
any_job_complete() {
  oc get jobs -n "$NS" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Complete")].status}{"\n"}{end}' 2>/dev/null | grep -q True
}

# At least one Kueue Workload carries Admitted=True (admission control was exercised).
any_workload_admitted() {
  oc get workloads -n "$NS" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Admitted")].status}{"\n"}{end}' 2>/dev/null | grep -q True
}

# The per-user ClusterQueue is Active (only checkable with cluster read — admin/CI).
cq_active() {
  [[ "$(oc get clusterqueue "$CQ" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)" == "True" ]]
}

# --- entry state (what `ws start m23` materializes) --------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                              || hint "run: ws start m23 --user ${USER_NAME}"
check "entry marker ws-entry-m23 present"               oc get cm ws-entry-m23 -n "$NS"              || hint "entry app not synced — ws start m23 --user ${USER_NAME}"
check "workshop quota present in ${NS}"                 oc get resourcequota workshop-quota -n "$NS" || hint "entry app not synced — ws reset m23 --user ${USER_NAME}"
check "namespace opted into Kueue (kueue.openshift.io/managed=true)" ns_kueue_managed                || hint "without this label Kueue ignores labeled Jobs — ws reset m23 --user ${USER_NAME}"
check "LocalQueue user-queue is Active (bound to ${CQ})" localqueue_active                            || hint "LocalQueue missing/inactive — check the workshop layer created ${CQ}: ws reset m23 --user ${USER_NAME}"
check "claims-data PVC is Bound"                        pvc_bound claims-data                        || hint "dataset PVC not bound — needs an RWX StorageClass; check: oc get pvc claims-data -n ${NS}"
check "claims-data seed Job succeeded (or cleaned up)"  seed_ok                                      || hint "seed Job present but not Complete — ws reset m23 --user ${USER_NAME} (check the claims-data-seed-m23-${USER_NAME} Job)"
check "MaaS credentials present (secret maas-credentials)" oc get secret maas-credentials -n "$NS"    || hint "the copy Job didn't run — ws reset m23 --user ${USER_NAME} (check maas-copy-m23-${USER_NAME})"
check "MaaS endpoint/model present (configmap maas-config)" oc get cm maas-config -n "$NS"            || hint "entry app not synced — ws reset m23 --user ${USER_NAME}"

# ClusterQueue is cluster-scoped — attendees can't read it. Assert it only when the caller can
# (admin/CI); attendees see the same fact via the LocalQueue Active check above.
if oc auth can-i get clusterqueues.kueue.x-k8s.io >/dev/null 2>&1; then
  check "ClusterQueue ${CQ} is Active (admits workloads)" cq_active                                   || hint "workshop layer's per-user ClusterQueue missing/inactive — run bootstrap/install.sh"
fi

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab / `ws solve m23` looks like) -----------
  check "at least one Job has Completed"                 any_job_complete                             || hint "run the monthly-statement Job (lab exercise 1) — or ws solve m23 --user ${USER_NAME}"
  check "nightly-statement CronJob exists"               oc get cronjob nightly-statement -n "$NS"    || hint "create the CronJob (lab exercise 4) — or ws solve m23 --user ${USER_NAME}"
  check "a Kueue Workload shows Admitted=True"           any_workload_admitted                        || hint "submit a Job through the LocalQueue (lab exercise 5/6) — or ws solve m23 --user ${USER_NAME}"
fi

verify_summary
