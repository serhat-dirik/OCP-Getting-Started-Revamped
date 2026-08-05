#!/usr/bin/env bash
# Verify deployment-targets-scheduling — Deployment Targets & Scheduling.
#   Entry: {user}-dev holds the multi-component claims app (parasol-web + parasol-claims @ N replicas +
#          ephemeral claims-db), a statement-batch worker with NO toleration/nodeSelector, and a load
#          generator — all with DEFAULT scheduling (no affinity/TSC/PDB, batch unpinned). The dedicated
#          batch pool (a bootstrap-labeled+tainted worker) exists cluster-wide. Entry marker set.
#   End:   the attendee ran the lab — parasol-claims DECLARES a spread constraint (podAntiAffinity
#          and/or topologySpreadConstraints) and its replicas do sit on distinct nodes, a
#          PodDisruptionBudget protects it, and statement-batch now runs ON the dedicated batch pool
#          node (toleration + nodeSelector). The declaration is what is graded; the observed layout
#          corroborates it (see claims_spread_constraint — the layout ALONE was a false ✅, because the
#          default scheduler already spreads replicas by soft preference on the untouched entry state).
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

# A Deployment exists (materialized) in {user}-dev. oc_present, not `oc get … 2>/dev/null`: NotFound is
# still a ❌ (the entry state really did not materialize it), but a cluster that could not be asked is a ⚠.
deploy_present() { oc_present get deploy "$1" -n "$NS" -o name; }

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# The dedicated batch pool node LABEL exists: at least one node carries workshop.redhat.com/pool=batch.
# Cluster-scoped bootstrap substrate (Rule 13 — never chart-owned); fail closed so a missing/recycled
# label is LOUD. Label-only is NOT the same claim as "the pool is real" — see batch_pool_tainted below.
batch_pool_labeled() {
  # An empty label selector result is rc 0 with empty stdout — a REAL "no such node", still a ❌.
  oc_read get nodes -l "${POOL_KEY}=${POOL_VALUE}" -o name || return 1
  [[ -n "$OC_OUT" ]]
}

# The labeled batch pool node ALSO carries the matching NoSchedule taint. This is the 40th instance of
# the "tick that passes without inspecting the thing that matters" defect class (see the 39 fixed
# 2026-07-31 across 19 sibling scripts): a check named batch_pool_exists() used to test the label alone,
# so `ws verify` returned green on a cluster where exercise 4's whole break-and-fix cannot happen — the
# nodeSelector-only pod schedules cleanly in ~11s instead of going Pending, and the attendee concludes
# the opposite of the lesson (nodeSelector alone is sufficient). bootstrap/install.sh withholds the
# taint below its MIN_BATCH_POOL_FOR_TAINT=3 floor (tainting one of two workers starved RHACS
# central-db for 4h+, 2026-07-30) — that is a REAL, deliberate state on small clusters, not a bootstrap
# defect, so this must still fail closed: a green check here is a promise that the toleration half of
# the lesson is actually live on THIS cluster, and that promise must not be made when it's false.
batch_pool_tainted() {
  local node
  # `{.items[0]…}` on an empty list is an oc ERROR, not empty output (measured on 4.20, 2026-08-01) —
  # oc_read classifies it as the server's real answer, so "no labeled node" stays a ❌ exactly as before.
  oc_read get nodes -l "${POOL_KEY}=${POOL_VALUE}" -o jsonpath='{.items[0].metadata.name}' || return 1
  node="$OC_OUT"
  [[ -n "$node" ]] || return 1
  # A node with no matching taint yields rc 0 + empty — the real "labeled but not tainted" ❌ this
  # cluster is actually in (below bootstrap's MIN_BATCH_POOL_FOR_TAINT floor).
  oc_read get node "$node" -o jsonpath="{.spec.taints[?(@.key=='${POOL_KEY}')].effect}" || return 1
  [[ "$OC_OUT" == "NoSchedule" ]]
}

# Is this cluster BELOW the floor at which bootstrap applies the taint at all?
#
# The comment above is right that a GREEN tick here must never be handed out when the toleration half
# of the lesson isn't live — but ❌ is the wrong way to say so, and it broke a promise of its own. An
# attendee on a sub-floor cluster who read the lab's honest "no taint here, and here's why" note and
# then did every exercise correctly still ended on `❌ 1 of 15 checks failed` (measured as user4,
# 2026-08-02). This check also runs in --entry-only mode, where `ws prep` reads the script's rc as a
# boolean "is this world prepared?" — so the same false ❌ was offering to WIPE a perfectly healthy
# environment, the exact destructive false alarm _lib.sh's exit-code comment exists to prevent.
#
# ⚠ SKIP satisfies both requirements at once: no green tick is issued (the promise is still withheld),
# the reason is printed where the attendee reads it, and nothing that the attendee actually controls is
# marked failed. Mirrors bootstrap/install.sh's own count exactly — dedicated workers, falling back to
# all nodes when no node carries the worker role separately — so the two cannot drift apart in meaning.
BATCH_TAINT_FLOOR=3   # bootstrap/install.sh MIN_BATCH_POOL_FOR_TAINT
batch_pool_below_taint_floor() {
  local raw count
  oc_read get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[*].metadata.name}' || return 1
  raw="$OC_OUT"
  if [[ -z "${raw// /}" ]]; then
    oc_read get nodes -o jsonpath='{.items[*].metadata.name}' || return 1
    raw="$OC_OUT"
  fi
  count="$(printf '%s' "$raw" | wc -w | tr -d ' ')"
  # 0 means we learned nothing about the topology — NOT a licence to skip. Fall through to the hard
  # check, which fails closed exactly as it always did.
  [[ "$count" -gt 0 && "$count" -lt "$BATCH_TAINT_FLOOR" ]]
}

# Does node $1 carry the batch-pool label? (attendee reads nodes via platform-observer.)
node_is_batch_pool() {
  oc_read get node "$1" -o jsonpath="{.metadata.labels.${POOL_KEY//./\\.}}" || return 1
  [[ "$OC_OUT" == "$POOL_VALUE" ]]
}

# END outcome: a Running statement-batch pod is placed ON the dedicated batch pool node.
# The node lookup is INLINE and not a value-returning batch_node(): `n="$(batch_node)"` runs the read in
# a SUBSHELL, so the VERIFY_INCONCLUSIVE the helper raises there dies with it and check() would print a
# ❌ for an API that never answered. Every predicate below reads OC_OUT in the caller's own shell.
batch_on_pool() {
  local n
  oc_read get pods -n "$NS" -l app=statement-batch --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].spec.nodeName}' || return 1
  n="$OC_OUT"
  [[ -n "$n" ]] || return 1
  node_is_batch_pool "$n"
}

# THE ATTENDEE'S ARTEFACT: parasol-claims carries an explicit spread constraint on its pod template.
#
# This replaces a check that graded observed node spread ALONE ("replicas span >= 2 distinct nodes"),
# which returned a FALSE ✅ on the untouched entry state — measured on user4, 2026-08-05: `ws prep`
# then `ws verify` printed `✅ parasol-claims replicas span >=2 distinct nodes (anti-affinity/TSC)`
# with the two entry replicas sitting on control-plane-…-2 and worker-…-3 and NO affinity or TSC on the
# Deployment at all. The default scheduler spreads replicas of a ReplicaSet by SOFT preference
# (SelectorSpread scoring), so on any multi-node cluster the lucky layout is the NORMAL one — the lab's
# own exercise 2 opens by saying exactly that ("Your two parasol-claims replicas *happen* to be on
# different nodes — but that's the scheduler's soft preference, not a guarantee"). The check was
# therefore congratulating an attendee for the one thing the exercise exists to teach them is missing,
# and nothing later in the run contradicts it. A false ✅ costs the lesson silently.
#
# So grade the DECLARATION, which only the attendee can have made, and keep the observed layout as a
# secondary signal at the call site. Still an outcome check, not a wording check (template rule 14):
# either mechanism the lab teaches counts — podAntiAffinity (required OR preferred) or
# topologySpreadConstraints — on any topologyKey, since the lab drives the key from hostname to
# workshop.redhat.com/zone and back. What is NOT accepted is an empty pod template, which is precisely
# what the entry state ships and precisely what the old check waved through.
#
# Sets CLAIMS_SPREAD_KIND (a global, read by the call site — a `$(…)` caller would run this in a
# SUBSHELL and lose the VERIFY_INCONCLUSIVE that an unanswerable API raises).
CLAIMS_SPREAD_KIND=""
claims_spread_constraint() {
  CLAIMS_SPREAD_KIND=""
  # ONE read, three ranges. A `{range}` over a path that does not exist is rc 0 + EMPTY, not an error
  # (measured on this 4.22 cluster against the untouched entry state, 2026-08-05) — so a Deployment
  # with no shaping at all is the API's real answer "none", still a ❌, exactly as oc_read intends.
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath=\
'{range .spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[*]}podAntiAffinity/required on {.topologyKey}{"\n"}{end}'\
'{range .spec.template.spec.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[*]}podAntiAffinity/preferred on {.podAffinityTerm.topologyKey}{"\n"}{end}'\
'{range .spec.template.spec.topologySpreadConstraints[*]}topologySpreadConstraints on {.topologyKey}{"\n"}{end}' || return 1
  # Drop any term whose topologyKey came back empty — an unkeyed term spreads across nothing.
  CLAIMS_SPREAD_KIND="$(printf '%s\n' "$OC_OUT" | grep -v ' on $' | grep '[^[:space:]]' \
    | awk 'NR>1{printf "; "}{printf "%s", $0}' || true)"
  [[ -n "$CLAIMS_SPREAD_KIND" ]]
}

# The OBSERVED layout of the Running parasol-claims pods → CLAIMS_RUNNING (how many) and CLAIMS_NODES
# (how many DISTINCT nodes they sit on). Globals, not echoed, for the subshell reason above — and read
# once so the two questions the call site asks ("is there anything to observe?" and "did it spread?")
# cannot see two different worlds.
CLAIMS_RUNNING=0
CLAIMS_NODES=0
claims_placement() {
  oc_read get pods -n "$NS" -l app=parasol-claims --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' || return 1
  CLAIMS_RUNNING="$(printf '%s\n' "$OC_OUT" | grep -c '[^[:space:]]' || true)"
  CLAIMS_NODES="$(printf '%s\n' "$OC_OUT" | grep '[^[:space:]]' | sort -u | grep -c . || true)"
}
# Grades the ALREADY-READ placement (see above) — touches no API, so its ❌ is never a cluster blip.
claims_nodes_at_least() { [[ "${CLAIMS_NODES:-0}" -ge "$1" ]]; }

# A PodDisruptionBudget guards parasol-claims.
pdb_present() { oc_present get pdb parasol-claims -n "$NS" -o name; }

# Entry-clean-slate helpers: return 0 when the solve shaping is ABSENT (nothing built yet).
# Each requires the underlying Deployment to actually exist first — otherwise "absent" is vacuous
# (true on a cluster where the entry state never materialized at all), not evidence of a clean entry.
# These three are the NEGATIONS, the direction where this conversion could invent a pass: the old
# `! oc get … 2>/dev/null` / `[[ -z "$(oc get …)" ]]` certify a clean slate from an API that never
# answered, and a wrongly-green ENTRY check sends `ws prep` down its "already prepared" fast path.
# oc_absent answers only when the API did; a missing FIELD on an existing object is still rc 0 + empty
# (measured, 2026-08-01), so the genuine "not shaped yet" pass is unchanged.
no_claims_pdb() {
  deploy_present parasol-claims || return 1
  oc_absent get pdb parasol-claims -n "$NS" -o name
}
# The MIRROR of the same defect, pointed the other way: this used to read podAntiAffinity ONLY, so an
# environment where the attendee had added a topologySpreadConstraints (exercise 3) still certified a
# clean slate — and a wrongly-green ENTRY check sends `ws prep` down its "already prepared" fast path,
# leaving them a half-shaped world. It now negates exactly the constraint the END check grades, so the
# two directions cannot disagree about what "shaped" means.
no_claims_spread_constraint() {
  deploy_present parasol-claims || return 1
  # Shaped already → NOT a clean entry.
  if claims_spread_constraint; then return 1; fi
  # claims_spread_constraint also returns 1 for "the API could not be asked", where it raises
  # VERIFY_INCONCLUSIVE. Return 1 there too so check() prints ⚠ instead of certifying a clean slate
  # from a read that never happened.
  if (( VERIFY_INCONCLUSIVE == 1 )); then return 1; fi
  return 0
}
batch_unpinned() {
  # No batch-pool nodeSelector on statement-batch yet (the attendee adds it).
  oc_present get deploy statement-batch -n "$NS" -o name || return 1
  oc_read get deploy statement-batch -n "$NS" -o jsonpath="{.spec.template.spec.nodeSelector.${POOL_KEY//./\\.}}" || return 1
  [[ -z "$OC_OUT" ]]
}

# The parasol-claims Hibernate schema-management strategy from the running container env (empty if unset →
# the image default, which is drop-and-create). Central to deployment-targets-scheduling's zero-downtime re-diagnosis: at entry the
# app reseeds the SHARED claims-db on every boot (drop-and-create), so a rolling-update pod wipes the DB
# out from under the serving pod; the fix flips it OFF drop-and-create so pods stop reseeding on boot.
# Sets CLAIMS_SCHEMA (a global) rather than printing — a `$(…)` caller would lose VERIFY_INCONCLUSIVE.
claims_schema_strategy() {
  oc_read get deploy parasol-claims -n "$NS" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' || return 1
  CLAIMS_SCHEMA="$(printf '%s\n' "$OC_OUT" \
    | grep '^QUARKUS_HIBERNATE_ORM_SCHEMA_MANAGEMENT_STRATEGY=' | head -1 | cut -d= -f2- || true)"
}
# ENTRY fault-present: the app reseeds on boot (drop-and-create explicitly, or unset → same image default).
# Requires the Deployment to exist — an absent Deployment also reads as "unset" and must not pass.
claims_schema_is_reseed() {
  deploy_present parasol-claims || return 1
  claims_schema_strategy || return 1
  [[ -z "$CLAIMS_SCHEMA" || "$CLAIMS_SCHEMA" == "drop-and-create" ]]
}
# END fix-applied: the app is OFF drop-and-create (none/validate/…) so a new pod boot no longer reseeds.
claims_schema_not_reseed() {
  claims_schema_strategy || return 1
  [[ -n "$CLAIMS_SCHEMA" && "$CLAIMS_SCHEMA" != "drop-and-create" ]]
}
# END fix-applied: the parasol-claims CPU limit is raised above the 500m entry floor that throttled the
# JVM cold-start (measured 27s→14-15s when raised to 1). Any limit >500m passes (accepts 1, 2, 1500m, …)
# — the check grades the OUTCOME, not the exact value. NOTE the lab teaches 1 and not more: at 2 the
# 3 replicas + maxSurge pod exceed the namespace limits.cpu quota of 6 and the rollout can never finish.
claims_cpu_limit_raised() {
  local cpu m
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' || return 1
  cpu="$OC_OUT"
  [[ -n "$cpu" ]] || return 1
  if [[ "$cpu" == *m ]]; then m="${cpu%m}"; else m=$(( ${cpu%.*} * 1000 )); fi
  [[ "${m:-0}" -gt 500 ]]
}
# END fix-applied: no ReplicaSet of parasol-claims is being REFUSED its pods. Guards the exact false pass
# that shipped as a defect (2026-07-28): a CPU limit large enough to breach the namespace limits.cpu quota
# leaves the new ReplicaSet at ReplicaFailure=True/FailedCreate ("exceeded quota: workshop-quota") and the
# rollout never starts — while maxUnavailable:0 keeps the OLD pods serving, so availableReplicas still
# reads N/N and the lab's capacity sampler prints full capacity throughout. Deliberately NOT a
# "rollout is complete" check: updatedReplicas lags transiently during any healthy roll and would fire a
# false ❌ on an attendee who verifies mid-rollout. ReplicaFailure only appears when creation is actually
# being refused, so this is stable. Same signature covers a quota breach on pods/memory, not just CPU.
# NOTE this one reads like a pass by default — "no ReplicaFailure found" — so a silenced read made an
# unanswerable API certify a healthy rollout. oc_read makes that a ⚠ instead; an EMPTY answer from a
# reachable API still passes, which is the genuine "no failing ReplicaSet" case.
claims_no_replica_failure() {
  local n
  oc_read get rs -n "$NS" -l app=parasol-claims \
    -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="ReplicaFailure")]}{.status}{"\n"}{end}{end}' || return 1
  n="$(printf '%s\n' "$OC_OUT" | grep -c '^True$' || true)"
  [[ "${n:-0}" -eq 0 ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                     || hint "run: ws prep deployment-targets-scheduling (or ws start deployment-targets-scheduling --user ${USER_NAME})"
check "entry marker ws-entry-deployment-targets-scheduling present"               oc get cm ws-entry-deployment-targets-scheduling -n "$NS"     || hint "entry app not synced — ws reset deployment-targets-scheduling --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db              || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment present"               deploy_present parasol-claims       || hint "entry app not synced — ws reset deployment-targets-scheduling --user ${USER_NAME}"
check "parasol-web deployment present"                  deploy_present parasol-web          || hint "entry app not synced — ws reset deployment-targets-scheduling --user ${USER_NAME}"
check "statement-batch worker has >=1 ready replica"    deploy_ready statement-batch        || hint "the batch worker isn't up — oc get pods -l app=statement-batch -n ${NS}"
check "load generator has >=1 ready replica"            deploy_ready claims-load            || hint "the load generator isn't up — oc get pods -l app=claims-load -n ${NS}"
check "dedicated batch pool node exists (labeled ${POOL_KEY}=${POOL_VALUE})" batch_pool_labeled || hint "no node carries the label at all — run the bootstrap node-shaping step (bootstrap/install.sh labels+taints one worker ${POOL_KEY}=${POOL_VALUE})"
if batch_pool_below_taint_floor; then
  # Designed state, not a defect: below the floor bootstrap labels the node and deliberately withholds
  # the taint. Nothing the attendee did or can do affects this, so it is not graded either way.
  # na(), not warn() (U8-F-03): there is nowhere else this could be answered and nothing is unknown —
  # the condition it grades correctly does not exist on a sub-floor cluster. As a warn() it dragged an
  # otherwise perfectly graded run into "this run did NOT fully verify the lab", which is what user8
  # reported. The nodeSelector half IS still graded below, so the lesson keeps its real check.
  na "batch pool node is labeled but deliberately NOT tainted — this cluster has fewer than ${BATCH_TAINT_FLOOR} dedicated workers, and bootstrap withholds the taint below that floor (tainting one of only two workers starved a platform component for 4h+ on 2026-07-30). Exercise 4's nodeSelector half works and IS graded below; its toleration half cannot be demonstrated here until a 3rd worker joins. Do NOT hand-taint the node to turn this green — that recreates the outage"
else
  check "dedicated batch pool node is TAINTED (a toleration is actually required to land there)" batch_pool_tainted || hint "labeled but NOT tainted, on a cluster at or above the ${BATCH_TAINT_FLOOR}-worker floor where bootstrap SHOULD have tainted it — this is a DIFFERENT problem than a missing pool, and a real one (see bootstrap/install.sh MIN_BATCH_POOL_FOR_TAINT). Exercise 4's toleration half cannot be taught until it is fixed; the nodeSelector half still works. Do NOT hand-taint the node to force this green — re-run the bootstrap node-shaping step so the cluster and the installer agree."
fi

# INFO: parasol-web/parasol-claims readiness needs the parasol-images imagestreams (workshop image-load
# step). Presence is asserted above; readiness is a cluster-provisioning concern, not an entry defect.
if ! deploy_ready parasol-claims || ! deploy_ready parasol-web; then
  info "(parasol-web/parasol-claims not Ready — expected until the parasol-images build populates the app images; the DB/batch/load tiers use always-present platform images)"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — the attendee has shaped NOTHING yet ------------------------------
  check "statement-batch is NOT pinned to the batch pool yet (attendee pins it)" batch_unpinned      || hint "entry ships it unpinned; if a batch-pool nodeSelector is set the lab already started — ws reset deployment-targets-scheduling --user ${USER_NAME}"
  check "parasol-claims has NO spread constraint yet (attendee adds anti-affinity/TSC)" no_claims_spread_constraint || hint "entry ships default scheduling; if a podAntiAffinity or a topologySpreadConstraints is set the lab already started — ws reset deployment-targets-scheduling --user ${USER_NAME}"
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
    warn "the batch-placement outcome — statement-batch not Ready"
  fi
  # THE SPREAD BEAT, graded in two parts — the attendee's DECLARATION first, the observed layout only
  # as corroboration. Grading the layout alone was a false ✅ on the untouched entry state (see
  # claims_spread_constraint): the default scheduler spreads ReplicaSet replicas by soft preference, so
  # "they are on two nodes" is the cluster's normal behaviour, not evidence that anybody constrained
  # anything. Node spread that happens to be true is not evidence of a constraint that makes it true.
  # Guarded on Ready (image-gap) as before; `>=`, not `==`, on the node count (lab-exceedable — the lab
  # scales past the entry replica count and more nodes is fine).
  if deploy_ready parasol-claims; then
    check "parasol-claims carries the spread constraint you added (podAntiAffinity and/or topologySpreadConstraints)" claims_spread_constraint \
      || hint "the Deployment's pod template has neither — the replicas may LOOK spread, but that is the scheduler's soft preference, not your rule, and it stops holding the moment the cluster gets busy. Add it: oc patch deploy parasol-claims -n ${NS} --type=merge -p '{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"podAntiAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":[{\"labelSelector\":{\"matchLabels\":{\"app\":\"parasol-claims\"}},\"topologyKey\":\"kubernetes.io/hostname\"}]}}}}}}' (see the lab's exercise 2/3)"
    # SECOND, and only once the constraint is real: does the running world match it? This is where the
    # old check's question still earns its place — it catches "declared but not in effect" (a rollout
    # that never rolled, replicas stuck Pending because no eligible node is left).
    if claims_placement; then
      if [[ -n "$CLAIMS_SPREAD_KIND" ]]; then
        info "(spread constraint in place: ${CLAIMS_SPREAD_KIND})"
        if [[ "${CLAIMS_RUNNING:-0}" -ge 2 ]]; then
          check "…and the ${CLAIMS_RUNNING} Running replicas really do sit on >=2 distinct nodes" claims_nodes_at_least 2 \
            || hint "the constraint is declared but the pods have not moved onto distinct nodes — the rollout may not have rolled (oc rollout status deploy/parasol-claims -n ${NS}) or an old ReplicaSet may still be serving (oc get pods -n ${NS} -l app=parasol-claims -o wide)"
        else
          # Genuinely UNKNOWN, so warn() and not na(): one replica cannot span two nodes, and a second
          # replica that is Pending rather than Running is not a fine state — it just is not this
          # check's verdict to give. The constraint itself is graded above either way.
          warn "the observed node spread — only ${CLAIMS_RUNNING} parasol-claims replica(s) are Running, so a distinct-node layout cannot be observed (check for Pending pods: oc get pods -n ${NS} -l app=parasol-claims -o wide)"
        fi
      elif [[ "${CLAIMS_NODES:-0}" -ge 2 ]]; then
        # Deliberately an info and NOT a ✅ — this is the exact sentence the old check turned into a
        # green tick. Say what is true (they are apart) and what is not (nothing is keeping them apart).
        info "(the ${CLAIMS_RUNNING} Running replicas do currently sit on ${CLAIMS_NODES} distinct nodes — but with no constraint declared that is the scheduler's soft preference doing it, not your work, so it is not graded)"
      fi
    else
      warn "the observed node spread — the pod list could not be read${OC_ERR:+ (${OC_ERR:0:120})}"
    fi
  else
    warn "the claims spread outcome — parasol-claims not Ready; needs the parasol-images build"
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
      || hint "give cold-starting pods headroom so the roll's capacity dip is brief: oc set resources deployment/parasol-claims --limits=cpu=1 --requests=cpu=200m (do NOT go above 1 — the namespace limits.cpu quota is 6 and 3 replicas + the surge pod would exceed it)"
    check "no parasol-claims ReplicaSet is being refused its pods (no ReplicaFailure)" claims_no_replica_failure \
      || hint "a ReplicaSet cannot create pods — read it: oc describe rs -n ${NS} \$(oc get rs -n ${NS} -l app=parasol-claims --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}'). 'exceeded quota: workshop-quota' means the CPU limit you set is too large for the namespace cap (use cpu=1); the roll is wedged even though availableReplicas still reads N/N"
  else
    warn "the zero-downtime outcomes — parasol-claims not Ready; needs the parasol-images build"
  fi
fi

verify_summary
