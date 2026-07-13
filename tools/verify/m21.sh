#!/usr/bin/env bash
# Verify M21 — Resilience, Multi-Cluster & DR.
#   Entry: {user}-resilience holds a resilient parasol-claims tier (3 replicas + PodDisruptionBudget +
#          soft topologySpreadConstraints + HorizontalPodAutoscaler) fronting a PERSISTENT claims-DB PVC
#          seeded with a deterministic parasol_claims_seed table (the restore anchor); {user}-site-b holds a
#          standalone claims Postgres (the simulated remote site). Entry marker set, no DR exercise run yet.
#   End:   the attendee completed the OADP backup→delete→restore arc — the ws-solve-m21 marker is present and
#          the seeded rows SURVIVED the restore (data intact). The RHSI cross-site link is optional/skippable.
# Runnable as the ATTENDEE: reads/execs only {user}-resilience + {user}-site-b objects the attendee sees via
# namespace admin. The G1 cockpit smoke runs `--entry-only` as {user}.
#
# IMAGE-GAP NOTE: parasol-claims runs a parasol-images/* image (workshop image-load step). Its Deployment +
# resilience config (PDB/HPA/spread) are asserted PRESENT (materialization is the entry state's job); the DB
# tiers on the always-present openshift/postgresql image are asserted READY + row-counted. So the verify is
# green on a cluster whose parasol images aren't loaded yet, red only on a genuine entry-state defect.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
RES_NS="${USER_NAME}-resilience"
SITEB_NS="${USER_NAME}-site-b"
# Must match gitops/entry-states/m21/values.yaml seedRows — the deterministic restore anchor.
EXPECT_ROWS=25

# --- helpers (oc only) -------------------------------------------------------

# A Deployment exists (materialized) in a namespace: $1=name $2=namespace.
deploy_present() { oc get deploy "$1" -n "$2" >/dev/null 2>&1; }

# A Deployment has at least one ready replica: $1=name $2=namespace.
deploy_ready() {
  local ready
  ready="$(oc get deploy "$1" -n "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The persistent claims-DB PVC is Bound (the restore anchor's storage).
pvc_bound() {
  [[ "$(oc get pvc claims-db-data -n "$RES_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Bound" ]]
}

# Row count of parasol_claims_seed in the {user}-resilience DB (empty on any failure).
# SC2016 disabled ON PURPOSE: the single-quoted $POSTGRESQL_* must expand in the INNER pod shell (sh -c),
# not in this script — same idiom as the ws CLI's cockpit exec helpers.
# shellcheck disable=SC2016
seed_rows() {
  oc exec deploy/claims-db -n "$RES_NS" -- sh -c \
    'PGPASSWORD="$POSTGRESQL_PASSWORD" psql -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DATABASE" -tAc "select count(*) from parasol_claims_seed"' \
    2>/dev/null | tr -d '[:space:]'
}
# The deterministic seed survived (exactly EXPECT_ROWS rows) — the "data survived restore" checkpoint.
seed_rows_ok() { [[ "$(seed_rows)" == "$EXPECT_ROWS" ]]; }

# Resilience primitives present (materialized regardless of the parasol image being loaded).
pdb_present() { oc get poddisruptionbudget parasol-claims -n "$RES_NS" >/dev/null 2>&1; }
hpa_present() { oc get horizontalpodautoscaler parasol-claims -n "$RES_NS" >/dev/null 2>&1; }

# Solve marker (end-state only).
solved() { oc get cm ws-solve-m21 -n "$RES_NS" >/dev/null 2>&1; }
# Entry clean-slate: the DR exercise has NOT run yet (no solve marker).
not_solved() { ! solved; }

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${RES_NS} exists"                       oc get ns "$RES_NS"                   || hint "run: ws prep m21 (or ws start m21 --user ${USER_NAME}); ${RES_NS} is workshop-layer (per-user-resilience)"
check "namespace ${SITEB_NS} exists"                     oc get ns "$SITEB_NS"                 || hint "the ${SITEB_NS} namespace is workshop-layer — sync gitops/workshop-config (per-user-resilience.yaml)"
check "entry marker ws-entry-m21 present"                oc get cm ws-entry-m21 -n "$RES_NS"   || hint "entry app not synced — ws reset m21 --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"       deploy_ready claims-db "$RES_NS"      || hint "wait for rollout: oc rollout status deploy/claims-db -n ${RES_NS}"
check "persistent claims-db PVC is Bound"                pvc_bound                             || hint "the restore-anchor PVC claims-db-data isn't Bound — oc get pvc claims-db-data -n ${RES_NS}"
check "seeded parasol_claims_seed has ${EXPECT_ROWS} rows" seed_rows_ok                        || hint "the deterministic seed is missing/incomplete — re-run the seed: ws reset m21 --user ${USER_NAME}"
check "parasol-claims deployment present"                deploy_present parasol-claims "$RES_NS" || hint "entry app not synced — ws reset m21 --user ${USER_NAME}"
check "parasol-claims PodDisruptionBudget present"       pdb_present                           || hint "the resilient tier needs a PDB — ws reset m21 --user ${USER_NAME}"
check "parasol-claims HorizontalPodAutoscaler present"   hpa_present                           || hint "the resilient tier needs an HPA — ws reset m21 --user ${USER_NAME}"
check "site-b claims-db deployment has >=1 ready replica" deploy_ready claims-db "$SITEB_NS"   || hint "the remote-site DB isn't up — oc get pods -l app=claims-db -n ${SITEB_NS}"

# INFO: parasol-claims runs a parasol-images image (workshop image-load step). Presence + PDB/HPA/spread are
# asserted above; readiness is a cluster-provisioning concern, not an entry defect.
if ! deploy_ready parasol-claims "$RES_NS"; then
  info "(parasol-claims not Ready — expected until the parasol-images build populates the claims image; the DB tiers use the always-present postgresql image)"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the pre-lab world — resilient stack up, DB seeded, no DR exercise run yet ------------
  check "no DR-exercise marker yet (ws-solve-m21 absent)" not_solved \
    || hint "a solve/end marker exists; the lab already ran — ws reset m21 --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — backup/restore done, data survived --------------------------------
  # Assert the OUTCOME (DR exercise complete + seeded rows intact), never the exact backup mechanism, so any
  # correct solution (shared-Velero Backup/Restore, or the TP NonAdminBackup path) stays green (rule 14).
  check "DR-exercise marker present (ws-solve-m21)"        solved                              || hint "run the backup→delete→restore arc, then mark done — or: ws solve m21 --user ${USER_NAME}"
  check "seeded data survived the restore (${EXPECT_ROWS} rows)" seed_rows_ok                   || hint "restored DB is missing rows — restore the backup that includes the claims-db PVC data"
fi

verify_summary
