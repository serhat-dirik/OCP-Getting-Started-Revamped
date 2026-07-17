#!/usr/bin/env bash
# Verify deployment-targets-scheduling — Deployment Targets & Scheduling.
#   Entry: {user}-dev holds the multi-component claims app (parasol-web + parasol-claims @ N replicas +
#          ephemeral claims-db), a statement-batch worker with NO toleration/nodeSelector, and a load
#          generator — all with DEFAULT scheduling (no affinity/TSC/PDB, batch unpinned). The dedicated
#          batch pool (a bootstrap-labeled+tainted worker) exists cluster-wide. Entry marker set.
#   End:   the attendee ran the lab — parasol-claims replicas are spread across distinct nodes
#          (anti-affinity/TSC), a PodDisruptionBudget protects it, and statement-batch now runs ON the
#          dedicated batch pool node (toleration + nodeSelector).
# Runnable as the ATTENDEE: reads only {user}-dev objects the attendee sees via namespace admin, plus
# nodes via the platform-observer ClusterRole (get/list/watch nodes). The G1 cockpit smoke runs
# `--entry-only` as {user}.
#
# IMAGE-GAP NOTE: parasol-web/parasol-claims run the parasol-images/* images (populated by the workshop
# image-load step, like every dev module). parasol-claims is asserted PRESENT here (the entry state's job
# is to materialize it correctly); readiness-dependent END checks (node spread) are GUARDED on it being
# Ready. The tiers on always-present platform images (claims-db=postgresql, statement-batch/claims-load=
# tools) are asserted READY.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
POOL_KEY="workshop.redhat.com/pool"
POOL_VALUE="batch"

# --- helpers (oc only) -------------------------------------------------------

# A Deployment exists (materialized) in {user}-dev.
deploy_present() { oc get deploy "$1" -n "$NS" >/dev/null 2>&1; }

# A Deployment has at least one ready replica.
deploy_ready() {
  local ready
  ready="$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The dedicated batch pool exists: at least one node carries the pool label. Cluster-scoped bootstrap
# substrate (Rule 13 — never chart-owned); fail closed so a missing/recycled pool is LOUD, not a silent
# "the toleration exercise schedules anywhere and the lesson is lost" (build note open risk).
batch_pool_exists() {
  local c
  c="$(oc get nodes -l "${POOL_KEY}=${POOL_VALUE}" -o name 2>/dev/null | grep -c . || true)"
  [[ "${c:-0}" -ge 1 ]]
}

# The node a Running statement-batch pod landed on (empty if none Running).
batch_node() {
  oc get pods -n "$NS" -l app=statement-batch --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true
}

# Does node $1 carry the batch-pool label? (attendee reads nodes via platform-observer.)
node_is_batch_pool() {
  [[ "$(oc get node "$1" -o jsonpath="{.metadata.labels.${POOL_KEY//./\\.}}" 2>/dev/null || true)" == "$POOL_VALUE" ]]
}

# END outcome: a Running statement-batch pod is placed ON the dedicated batch pool node.
batch_on_pool() {
  local n; n="$(batch_node)"
  [[ -n "$n" ]] && node_is_batch_pool "$n"
}

# Count of DISTINCT nodes hosting Running parasol-claims pods (the anti-affinity/spread outcome).
claims_distinct_nodes() {
  oc get pods -n "$NS" -l app=parasol-claims --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -c . || true
}

# A PodDisruptionBudget guards parasol-claims.
pdb_present() { oc get pdb parasol-claims -n "$NS" >/dev/null 2>&1; }

# Entry-clean-slate helpers: return 0 when the solve shaping is ABSENT (nothing built yet).
no_claims_pdb() { ! oc get pdb parasol-claims -n "$NS" >/dev/null 2>&1; }
no_claims_antiaffinity() {
  [[ -z "$(oc get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}' 2>/dev/null || true)" ]]
}
batch_unpinned() {
  # No batch-pool nodeSelector on statement-batch yet (the attendee adds it).
  [[ -z "$(oc get deploy statement-batch -n "$NS" -o jsonpath="{.spec.template.spec.nodeSelector.${POOL_KEY//./\\.}}" 2>/dev/null || true)" ]]
}

# The parasol-claims Hibernate schema-management strategy from the running container env (empty if unset →
# the image default, which is drop-and-create). Central to deployment-targets-scheduling's zero-downtime re-diagnosis: at entry the
# app reseeds the SHARED claims-db on every boot (drop-and-create), so a rolling-update pod wipes the DB
# out from under the serving pod; the fix flips it OFF drop-and-create so pods stop reseeding on boot.
claims_schema_strategy() {
  oc get deploy parasol-claims -n "$NS" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
    | grep '^QUARKUS_HIBERNATE_ORM_SCHEMA_MANAGEMENT_STRATEGY=' | head -1 | cut -d= -f2- || true
}
# ENTRY fault-present: the app reseeds on boot (drop-and-create explicitly, or unset → same image default).
claims_schema_is_reseed() { local v; v="$(claims_schema_strategy)"; [[ -z "$v" || "$v" == "drop-and-create" ]]; }
# END fix-applied: the app is OFF drop-and-create (none/validate/…) so a new pod boot no longer reseeds.
claims_schema_not_reseed() { local v; v="$(claims_schema_strategy)"; [[ -n "$v" && "$v" != "drop-and-create" ]]; }
# END fix-applied: the parasol-claims CPU limit is raised above the 500m entry floor that throttled the
# JVM cold-start (measured 27s→17s when raised to 2). Any limit >500m passes (accepts 1, 2, 1500m, …).
claims_cpu_limit_raised() {
  local cpu m
  cpu="$(oc get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)"
  [[ -n "$cpu" ]] || return 1
  if [[ "$cpu" == *m ]]; then m="${cpu%m}"; else m=$(( ${cpu%.*} * 1000 )); fi
  [[ "${m:-0}" -gt 500 ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                     || hint "run: ws prep deployment-targets-scheduling (or ws start deployment-targets-scheduling --user ${USER_NAME})"
check "entry marker ws-entry-deployment-targets-scheduling present"               oc get cm ws-entry-deployment-targets-scheduling -n "$NS"     || hint "entry app not synced — ws reset deployment-targets-scheduling --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db              || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment present"               deploy_present parasol-claims       || hint "entry app not synced — ws reset deployment-targets-scheduling --user ${USER_NAME}"
check "parasol-web deployment present"                  deploy_present parasol-web          || hint "entry app not synced — ws reset deployment-targets-scheduling --user ${USER_NAME}"
check "statement-batch worker has >=1 ready replica"    deploy_ready statement-batch        || hint "the batch worker isn't up — oc get pods -l app=statement-batch -n ${NS}"
check "load generator has >=1 ready replica"            deploy_ready claims-load            || hint "the load generator isn't up — oc get pods -l app=claims-load -n ${NS}"
check "dedicated batch pool exists (a node is labeled ${POOL_KEY}=${POOL_VALUE})" batch_pool_exists || hint "no batch pool — run the bootstrap node-shaping step (bootstrap/install.sh labels+taints one worker ${POOL_KEY}=${POOL_VALUE})"

# INFO: parasol-web/parasol-claims readiness needs the parasol-images imagestreams (workshop image-load
# step). Presence is asserted above; readiness is a cluster-provisioning concern, not an entry defect.
if ! deploy_ready parasol-claims || ! deploy_ready parasol-web; then
  info "(parasol-web/parasol-claims not Ready — expected until the parasol-images build populates the app images; the DB/batch/load tiers use always-present platform images)"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — the attendee has shaped NOTHING yet ------------------------------
  check "statement-batch is NOT pinned to the batch pool yet (attendee pins it)" batch_unpinned      || hint "entry ships it unpinned; if a batch-pool nodeSelector is set the lab already started — ws reset deployment-targets-scheduling --user ${USER_NAME}"
  check "parasol-claims has NO anti-affinity yet (attendee adds it)"             no_claims_antiaffinity || hint "entry ships default scheduling; if podAntiAffinity is set the lab already started — ws reset deployment-targets-scheduling --user ${USER_NAME}"
  check "no PodDisruptionBudget on parasol-claims yet (attendee creates it)"     no_claims_pdb        || hint "entry ships no PDB; if one exists the lab already started — ws reset deployment-targets-scheduling --user ${USER_NAME}"
  check "parasol-claims ships the reseed fault (schema-management drop-and-create)" claims_schema_is_reseed || hint "the reseed fault should be present at entry; if schema-management is already off drop-and-create the lab started — ws reset deployment-targets-scheduling --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — placement + spread + availability in place -------------------
  # Assert OUTCOMES (a PDB exists; batch runs on the pool; claims span >=2 nodes), never the exact field
  # wording, so any correct solution stays green (template rule 14).
  check "PodDisruptionBudget protects parasol-claims"    pdb_present                          || hint "create a PDB (minAvailable 1) selecting app=parasol-claims (see the lab)"
  # statement-batch runs on always-present images, so this outcome is gradeable on any cluster: with the
  # toleration + nodeSelector it must land ON the dedicated batch pool node.
  if deploy_ready statement-batch; then
    check "statement-batch runs ON the dedicated batch pool node" batch_on_pool                || hint "pin it: add a toleration for ${POOL_KEY}=${POOL_VALUE}:NoSchedule AND nodeSelector ${POOL_KEY}=${POOL_VALUE} to statement-batch"
  else
    info "(skipped the batch-placement outcome — statement-batch not Ready)"
  fi
  # Node-spread outcome needs the parasol-claims image running; guard on Ready (image-gap) and use `>=`
  # (lab-exceedable — more replicas/nodes is fine).
  if deploy_ready parasol-claims; then
    check "parasol-claims replicas span >=2 distinct nodes (anti-affinity/TSC)" test "$(claims_distinct_nodes)" -ge 2 || hint "spread the replicas: add podAntiAffinity on kubernetes.io/hostname (and/or topologySpreadConstraints) so no two claims pods share a node"
  else
    info "(skipped the claims node-spread outcome — parasol-claims not Ready; needs the parasol-images build)"
  fi
  # Zero-downtime is a real, gradeable OUTCOME (deployment-targets-scheduling re-diagnosis 2026-07-16). The fault: the shared
  # claims-db is reseeded on EVERY parasol-claims boot (Hibernate drop-and-create), so a rolling-update
  # pod drops the DB out from under the still-serving pod — compounded by a 500m cold-start CPU throttle.
  # Assert the two fix outcomes on the running deployment (never exact wording — any schema value that
  # stops the reseed passes, any CPU limit above the throttle floor passes).
  if deploy_ready parasol-claims; then
    check "parasol-claims no longer reseeds the DB on boot (schema-management off drop-and-create)" claims_schema_not_reseed \
      || hint "stop the per-boot reseed of the shared DB: oc set env deployment/parasol-claims QUARKUS_HIBERNATE_ORM_SCHEMA_MANAGEMENT_STRATEGY=none"
    check "parasol-claims CPU limit raised above the cold-start-throttle floor (>500m)" claims_cpu_limit_raised \
      || hint "give cold-starting pods headroom so the roll's capacity dip is brief: oc set resources deployment/parasol-claims --limits=cpu=2 --requests=cpu=200m"
  else
    info "(skipped the zero-downtime outcomes — parasol-claims not Ready; needs the parasol-images build)"
  fi
fi

verify_summary
