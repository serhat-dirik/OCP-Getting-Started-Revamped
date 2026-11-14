#!/usr/bin/env bash
# Verify jobs-batch-kueue — Jobs, Batch & Queued Workloads.
#   Entry: {user}-batch exists (labeled for Kueue), holds the claims-data dataset ConfigMap, a LocalQueue
#          (user-queue) bound to the per-user ClusterQueue, and MaaS batch-inference credentials;
#          entry marker + quota present — AND, in --entry-only mode only, that the lab has NOT
#          already been run here: no attendee-created Job, no nightly-statement CronJob, no admitted
#          Workload. That last group is the exact negation of the End group below, and it is what
#          lets `ws prep` tell a fresh world from a finished one (audit F-05; see no_attendee_jobs).
#   End:   the attendee ran the lab — at least one Job has Completed, the nightly-statement CronJob
#          exists, and a Kueue Workload carries Admitted=True (admission control was exercised).
# Runnable as the ATTENDEE: every check reads namespace-scoped objects the attendee can see
# (Jobs/CronJobs/Secret/ConfigMap via namespace admin; LocalQueues + Workloads via the
# kueue-batch-user-role bound in the entry state). The cluster-scoped ClusterQueue is NOT readable
# by attendees, so that check AUTO-SKIPS unless the caller has cluster read (admin/CI), mirroring
# the devspaces-inner-loop DevWorkspace pattern. See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-batch"
CQ="cq-${USER_NAME}"

# --- helpers (kept dependency-free: oc only) ---------------------------------

# The namespace carries the Kueue opt-in label, without which Kueue ignores labeled Jobs.
# An ABSENT label is rc 0 + empty output from a reachable API — still a ❌, exactly as before. Only a
# cluster that could not be asked changes verdict, from ❌ to ⚠.
ns_kueue_managed() {
  oc_read get ns "$NS" -o jsonpath='{.metadata.labels.kueue\.openshift\.io/managed}' || return 1
  [[ "$OC_OUT" == "true" ]]
}

# The LocalQueue exists and reports Active=True (its ClusterQueue accepts it).
# A missing kueue CRD ("the server doesn't have a resource type") is the server's own answer, so an
# uninstalled Kueue still fails loudly rather than skipping.
localqueue_active() {
  oc_present get localqueue user-queue -n "$NS" -o name || return 1
  oc_read get localqueue user-queue -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' || return 1
  [[ "$OC_OUT" == "True" ]]
}

# The dataset holds claim rows. It is chart-rendered (ConfigMap claims-data, key claims.csv, from the
# chart's files/claims.csv), so this reads the DATA itself rather than a proxy for it. Chart 0.1.11
# replaced a seeded PVC with that ConfigMap, and three checks went with the PVC — Bound, seed Job
# Complete, the seed's row-count marker — which existed only because a volume's contents cannot be
# read through the API. >= 1, never == 200: the size belongs to the chart file, not to this script.
dataset_rows() {
  local rows
  oc_read get cm claims-data -n "$NS" -o jsonpath='{.data.claims\.csv}' || return 1
  rows="$(printf '%s\n' "$OC_OUT" | sed 1d | grep -c . || true)"
  (( rows >= 1 ))
}

# An ATTENDEE-created Job has Completed (end state).
#
# This used to scan every Job in the namespace and pass if ANY had Complete=True. It could not fail:
# `ws start` itself materialized two Jobs that complete — claims-data-seed-… and maas-copy-… — so the
# check went green on a namespace where the attendee had done nothing, while the very Job its own hint
# names ("run the monthly-statement Job") did not exist. (The seed Job went away with the seeded PVC at
# chart 0.1.11; maas-copy-… remains.) Measured on a live cluster 2026-07-29:
#
#   claims-data-seed-jobs-batch-kueue-user1 -> Complete=True     <- ws start artifact
#   maas-copy-jobs-batch-kueue-user1        -> Complete=True     <- ws start artifact
#   Error from server (NotFound): jobs.batch "monthly-statement" not found
#
# An assertion is worth exactly what it DISTINGUISHES, and this one distinguished nothing. Both entry
# Jobs carry workshop.redhat.com/owner=ogsr, which the attendee's own Jobs do not — so excluding our
# own artifacts is the discriminator, and it was already in the data.
#
# Label-absence is expressed as a selector rather than filtered in shell: `!key` is a real selector,
# and letting the API server do it means a Job created by some future entry-state addition is excluded
# the moment it carries the owner label, without this function needing to learn its name.
any_attendee_job_complete() {
  oc_read get jobs -n "$NS" -l '!workshop.redhat.com/owner' \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Complete")].status}{"\n"}{end}' || return 1
  [[ "$OC_OUT" == *True* ]] && return 0
  # `adm solve` stands in for the attendee's Job with monthly-statement-solve. The chart owns it, so it
  # carries the owner label the selector above excludes; without this, verify after solve is always red.
  oc_read get job monthly-statement-solve -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' || return 1
  [[ "$OC_OUT" == *True* ]]
}

# At least one Kueue Workload carries Admitted=True (admission control was exercised).
any_workload_admitted() {
  oc_read get workloads -n "$NS" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Admitted")].status}{"\n"}{end}' || return 1
  [[ "$OC_OUT" == *True* ]]
}

# --- the entry-mode clean slate (audit F-05) ---------------------------------
#
# WHY THESE EXIST. `ws prep` reads `<script> --entry-only`'s rc as the boolean "is this world already
# prepared?" (tools/ws/ws cmd_prep). Until these three predicates existed there was no entry branch
# at all — --entry-only ran the shared block above and stopped — so it graded ONLY what a COMPLETED
# lab still satisfies: the namespace, its Kueue label, the quota, the LocalQueue, the dataset, the
# MaaS credentials. A namespace holding a finished lab returned rc 0, prep printed "already
# prepared — nothing to do", DID NOT PURGE, and the attendee started exercise 1 on top of the
# previous pass's Jobs and CronJob. Because this lab's objects use FIXED names, that is a COLLISION
# and not merely residue: `oc apply` onto an existing Job whose pod template differs is rejected
# outright (pod templates are immutable), so the attendee's very first command hard-fails on a world
# a green ✅ had just told them was ready.
#
# Two fixes for this same defect are already in this tree and both say why it matters:
# config-multienv.sh's obj_absent and serverless-zero-to-hero.sh's single_revision.
#
# THE THREE ASSERTIONS ARE THE EXACT MIRROR OF THE THREE END CHECKS — a Completed attendee Job, the
# nightly-statement CronJob, an Admitted Workload — negated one for one. Preserve that correspondence
# if either side changes: an entry check negating a strict SUBSET of what the end check accepts
# leaves a world that reads COMPLETE in full mode and CLEAN SLATE in entry mode at the same time.
#
# no_attendee_jobs is one step stronger than the literal negation of any_attendee_job_complete —
# "no attendee Job exists" rather than "none Completed" — deliberately: a Job the attendee ran that
# failed, or one still running, is not a completed lab and is not a clean slate either, and it is the
# exact object that will collide on the next pass. It cannot false-red a correct entry state: the
# selector is the SAME `!workshop.redhat.com/owner` discriminator the end check uses, so the entry
# state's own hook Job (maas-copy-…) is excluded by the API server, and any
# future entry-state Job is excluded the moment it carries the owner label — nothing here restates a
# name.
#
# oc_absent, NEVER `! oc get … 2>/dev/null`: a negation is the one direction where a silenced read
# certifies a clean slate from an API that never answered, and a wrongly-green entry check is what
# sends prep past the purge. The namespace is proven PRESENT first, or the assertion is vacuously
# true on a cluster where nothing materialized at all.
no_attendee_jobs() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent  get jobs -n "$NS" -l '!workshop.redhat.com/owner' -o name
}

# Same name and signature as config-multienv.sh's copy on purpose: when this is hoisted into _lib.sh
# (three scripts carry it after this change) the collapse should be mechanical.
obj_absent() {  # <type> <name> <namespace> → 0 only when the API ANSWERED and it is not there
  oc_present get ns "$3" -o name || return 1
  oc_absent  get "$1" "$2" -n "$3" -o name
}

# The EXACT negation of any_workload_admitted — the same predicate, called and inverted, rather than a
# second reading of the same fact that could drift away from it.
#
# "No Workload at all" is the tempting stronger form and it is NOT taken. Kueue mints a Workload for
# every Job it manages, and what a Workload's mere existence proves depends on operator config this
# script does not own (whether jobs without a queue-name label are managed). The lab's outcome, and
# the only thing the end check grades, is an ADMITTED one — so that is what the clean slate denies.
# Betting the purge on a stricter claim than the end check makes would trade this false ✅ for a
# false ❌ on a correctly-materialized world, which is not a win.
#
# The VERIFY_INCONCLUSIVE re-read is the whole reason it is written this way (the shape
# serverless-zero-to-hero.sh's no_traffic_split already uses): NEGATING a predicate turns "the cluster
# could not be asked" into a PASS, and a wrongly-green entry check is precisely what makes prep skip
# the purge. Fail closed here and let check() render the ⚠ from the flag oc_read already raised.
no_workload_admitted() {
  local rc=0
  oc_present get ns "$NS" -o name || return 1
  any_workload_admitted || rc=$?
  if (( VERIFY_INCONCLUSIVE == 1 )); then return 1; fi
  (( rc != 0 ))
}

# The per-user ClusterQueue is Active (only checkable with cluster read — admin/CI). The Forbidden
# case never reaches here: the caller's `cq_err` probe below routes an attendee identity to warn().
cq_active() {
  oc_read get clusterqueue "$CQ" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' || return 1
  [[ "$OC_OUT" == "True" ]]
}

# --- entry state (what `ws start jobs-batch-kueue` materializes) --------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                              || hint "run: ws prep jobs-batch-kueue (or ws start jobs-batch-kueue --user ${USER_NAME})"
check "entry marker ws-entry-jobs-batch-kueue present"               oc get cm ws-entry-jobs-batch-kueue -n "$NS"              || hint "entry app not synced — ws prep jobs-batch-kueue (or ws start jobs-batch-kueue --user ${USER_NAME})"
check "workshop quota present in ${NS}"                 oc get resourcequota workshop-quota -n "$NS" || hint "entry app not synced — ws reset jobs-batch-kueue --user ${USER_NAME}"
check "namespace opted into Kueue (kueue.openshift.io/managed=true)" ns_kueue_managed                || hint "without this label Kueue ignores labeled Jobs — ws reset jobs-batch-kueue --user ${USER_NAME}"
check "LocalQueue user-queue is Active (bound to ${CQ})" localqueue_active                            || hint "LocalQueue missing/inactive — check the workshop layer created ${CQ}: ws reset jobs-batch-kueue --user ${USER_NAME}"
check "dataset ConfigMap claims-data holds claim rows (/data/claims.csv in every lab Job)" dataset_rows \
  || hint "actually broken, not a step you skipped: the dataset ConfigMap is missing or holds no claim rows, so every lab Job's Pods sit in ContainerCreating (or read nothing). It is part of your entry state, so re-materialize: ws reset jobs-batch-kueue --user ${USER_NAME}"
check "MaaS credentials present (secret maas-credentials)" oc get secret maas-credentials -n "$NS"    || hint "the copy Job didn't run — ws reset jobs-batch-kueue --user ${USER_NAME} (check maas-copy-jobs-batch-kueue-${USER_NAME})"
check "MaaS config carries the resolved model (configmap maas-config)" cm_key_set "$NS" maas-config model || hint "the MaaS copy hook did not fill maas-config — ws reset jobs-batch-kueue --user ${USER_NAME}"
# PRESENCE IS NOT PROOF: the check above says the Secret exists, not that its key works. The entry hook
# validates the credential against the endpoint before staging it and records the verdict here. Reported
# as INFO because this module's graded outcome is the Kueue queueing behaviour, not the inference —
# but a `false` here means the batch inference itself will 401. (Reported, not asserted: whether a dead
# AI path should fail this module's entry state is the module owner's call, not this script's.)
# CHOICE vs MISTAKE: `no-maas-credential` means nobody configured a key — bootstrap/install.sh
# supports that install and the documented consequence is exactly this degraded AI beat. A credential
# that was FOUND and refused (wrong kind / rejected by the endpoint) is somebody's mistake. Both are
# INFO here, but they must not read the same. Reason strings are the literal ones written by
# gitops/entry-states/jobs-batch-kueue/templates/maas-credentials.yaml.
# Both reads are informational. An unreadable ConfigMap leaves both empty and falls to the `*)` arm,
# which is what an unrecorded verdict already meant — no verdict changes, no counter is touched.
ai_reason=""
if oc_read get cm maas-config -n "$NS" -o jsonpath='{.data.aiPathReason}'; then ai_reason="$OC_OUT"; fi
ai_available=""
if oc_read get cm maas-config -n "$NS" -o jsonpath='{.data.aiPathAvailable}'; then ai_available="$OC_OUT"; fi
case "$ai_available" in
  true)       info "MaaS credential accepted by the model endpoint (live probe at materialization)" ;;
  unverified) info "MaaS credential staged but UNPROVEN — the cluster could not reach the endpoint when this namespace materialized; batch inference may 401" ;;
  false)      if [[ "$ai_reason" == "no-maas-credential" ]]; then
                info "no MaaS credential reached this cluster — a supported, degraded install, not a fault of this module; the batch-inference beat reports the AI path unavailable and the queueing/admission beats are unaffected"
              else
                info "MaaS credential NOT usable (${ai_reason:-reason unrecorded}) — batch inference will fail its model call; queueing/admission beats are unaffected"
              fi ;;
  *)          info "MaaS credential UNVALIDATED (entry state predates the credential-validation hook) — ws reset jobs-batch-kueue --user ${USER_NAME} for a verdict" ;;
esac

# ClusterQueue is cluster-scoped — attendees can't read it. Assert it only when the caller can
# (admin/CI); attendees see the same fact via the LocalQueue Active check above.
#
# ASK THE OBJECT, NOT `can-i`. This guard used to be `oc auth can-i get clusterqueues…`, and it
# returned the WRONG ANSWER for exactly the identity it exists to protect. Measured 2026-07-31:
#
#     can-i (context -n default     ) -> no
#     can-i (context -n user6-batch ) -> yes     <- the attendee's OWN namespace
#     the real GET                   -> Forbidden, either way
#
# `<user>-admin` is a NAMESPACED RoleBinding to the stock `admin` ClusterRole, and that ClusterRole
# carries a get/list/watch rule for clusterqueues. A namespaced binding can never actually authorize
# a cluster-scoped resource — but `can-i`, evaluated from inside that namespace, reports the rule as
# granted anyway. An attendee's terminal runs in their own namespace, so the guard said "yes", the
# read was refused, and every attendee saw a red ❌ on a ClusterQueue that was Active the whole time.
# The old hint then told them to run bootstrap/install.sh: a maintainer-only cluster installer they
# have no access to and must never run. A false ❌ destroys trust in every other ✅ on the page.
#
# This is a THIRD can-i trap for this repo's collection, and the nastiest, because the other two
# (`--as` without `--as-group`; `resource/name` parsing as TYPE/NAME) produce fabricated BLOCKERS
# while this one produces false FAILURES.
#
# So: attempt the read and branch on what actually comes back. Forbidden means the caller is an
# attendee and the check is not theirs to run — skip, and say so, because a silent skip and a pass
# look identical. Anything else (including NotFound) means the caller CAN ask, so a missing or
# inactive ClusterQueue still fails loudly for admin/CI, which is the case this check exists for.
cq_err="$(oc get clusterqueue "$CQ" -o name 2>&1 >/dev/null || true)"
case "$cq_err" in
  *orbidden*)
    warn "ClusterQueue ${CQ} check — cluster-scoped and not readable as this identity"
    hint "not yours to fix: the LocalQueue Active check above asserts the same health from inside your namespace (Kueue marks a LocalQueue inactive when its ClusterQueue is missing or inactive)"
    ;;
  *)
    check "ClusterQueue ${CQ} is Active (admits workloads)" cq_active                                 || hint "the workshop layer's per-user ClusterQueue is missing or inactive. This is a PLATFORM check, not an attendee one — an SA should confirm the workshop-config Argo app is Synced: oc get clusterqueue ${CQ}"
    ;;
esac

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the clean slate — the lab's own artefacts must NOT exist yet ----------------
  # Exactly the three objects the end block grades, negated. See no_attendee_jobs above for why an
  # unchecked clean slate costs `ws prep` its purge — and why, in THIS module, that costs the
  # attendee their very first `oc apply` to an immutable-name collision.
  info "entry state — these checks assert a CLEAN SLATE: they fail when the lab has already been run here, which is what tells 'ws prep' to purge and re-materialize"
  check "no attendee-created Job yet (you create the first in exercise 1)"     no_attendee_jobs                       || hint "this is LEFTOVER from an earlier run, not a broken environment — the entry state's own copy Job is excluded by label, so what is here is yours from last time. The lab's Job names are fixed, so re-applying over it fails on an immutable pod template. Clear it: ws reset jobs-batch-kueue --user ${USER_NAME}"
  check "no nightly-statement CronJob yet (you create it in exercise 4)"       obj_absent cronjob nightly-statement "$NS" || hint "this is LEFTOVER from an earlier run (or from adm solve) — the entry state ships no CronJob. Clear it: ws reset jobs-batch-kueue --user ${USER_NAME}"
  check "no admitted Kueue Workload yet (exercises 5/6 submit the first)"      no_workload_admitted                   || hint "this is LEFTOVER from an earlier run — a Workload reaches Admitted only after a Job is submitted through LocalQueue user-queue, which the entry state never does. Clear it: ws reset jobs-batch-kueue --user ${USER_NAME}"
else
  # --- end state (what a completed lab / `ws solve jobs-batch-kueue` looks like) -----------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "an attendee-created Job has Completed"          any_attendee_job_complete                    || hint "not done yet — you run the monthly-statement Job in lab exercise 1, so no completed Job before then is expected, not a fault (or: adm solve jobs-batch-kueue --user ${USER_NAME}). If you DID run it and it never Completed, that one is real: oc get jobs -n ${NS}"
  check "nightly-statement CronJob exists"               oc get cronjob nightly-statement -n "$NS"    || hint "not done yet — you create this CronJob in lab exercise 4, so it is expected to be missing before then (or: adm solve jobs-batch-kueue --user ${USER_NAME})"
  check "a Kueue Workload shows Admitted=True"           any_workload_admitted                        || hint "not done yet — you submit a Job through the LocalQueue in lab exercises 5/6, so no admitted Workload before then is expected (or: adm solve jobs-batch-kueue --user ${USER_NAME}). If you DID submit one and it is still not Admitted, that one is real — it is queued behind the ClusterQueue's quota: oc get workloads -n ${NS}"
fi

verify_summary
