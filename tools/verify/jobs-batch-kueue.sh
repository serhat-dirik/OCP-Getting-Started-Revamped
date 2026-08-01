#!/usr/bin/env bash
# Verify jobs-batch-kueue — Jobs, Batch & Queued Workloads.
#   Entry: {user}-batch exists (labeled for Kueue), holds the seeded claims-data PVC, a LocalQueue
#          (user-queue) bound to the per-user ClusterQueue, and MaaS batch-inference credentials;
#          entry marker + quota present.
#   End:   the attendee ran the lab — at least one Job has Completed, the nightly-statement CronJob
#          exists, and a Kueue Workload carries Admitted=True (admission control was exercised).
# Runnable as the ATTENDEE: every check reads namespace-scoped objects the attendee can see
# (Jobs/CronJobs/PVC/Secret/ConfigMap via namespace admin; LocalQueues + Workloads via the
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

# A PVC exists and is Bound.
pvc_bound() {
  oc_read get pvc "$1" -n "$NS" -o jsonpath='{.status.phase}' || return 1
  [[ "$OC_OUT" == "Bound" ]]
}

# The LocalQueue exists and reports Active=True (its ClusterQueue accepts it).
# A missing kueue CRD ("the server doesn't have a resource type") is the server's own answer, so an
# uninstalled Kueue still fails loudly rather than skipping.
localqueue_active() {
  oc_present get localqueue user-queue -n "$NS" -o name || return 1
  oc_read get localqueue user-queue -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' || return 1
  [[ "$OC_OUT" == "True" ]]
}

# The dataset seed succeeded. ABSENCE IS NOT SUCCESS. This check used to `return 0` when the Job was
# missing, calling that "ran and was cleaned up" — which made a Sync hook that NEVER FIRED
# indistinguishable from one that completed, and the companion PVC-Bound check cannot cover the gap
# because an EMPTY volume Binds exactly as well as a seeded one.
# The Job is annotated `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation`
# (gitops/entry-states/jobs-batch-kueue/templates/claims-data.yaml): Argo deletes it only when it is
# about to create the NEXT one, so a successful seed LEAVES THE JOB BEHIND. Verified on-cluster
# 2026-08-01 — the namespaces whose entry state had synced still carried
# claims-data-seed-jobs-batch-kueue-<user> with Complete=True; the ones it had never synced into
# carried no Job at all. So absence means "never seeded", and it must fail.
# 0 = seeded · 1 = Job present but not Complete · 2 = Job ABSENT · 3 = namespace missing · 4 = the API
# could not be asked. State 4 is NEW and it is why this function reads the rc rather than a bare
# `|| return`: its caller drives a `case`, so `check` never sees an oc invocation here and could not
# classify anything on its own. Without 4 an unreachable cluster fell through to 3 and told the
# attendee their namespace does not exist — a false ❌ with a hint that sends them to re-run `ws start`.
seed_state() {
  local job="claims-data-seed-jobs-batch-kueue-${USER_NAME}" rc=0
  oc_read get ns "$NS" -o name || rc=$?
  if (( rc == 2 )); then return 4; fi
  if (( rc != 0 )); then return 3; fi
  rc=0; oc_read get job "$job" -n "$NS" -o name || rc=$?
  if (( rc == 2 )); then return 4; fi
  if (( rc != 0 )); then return 2; fi
  rc=0; oc_read get job "$job" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' || rc=$?
  if (( rc == 2 )); then return 4; fi
  if (( rc != 0 )); then return 1; fi
  [[ "$OC_OUT" == *True* ]] || return 1
  return 0
}

# WHAT THE SEED ACTUALLY WROTE — not "did the Job that was supposed to write it finish".
#
# `Complete=True` above and "the dataset exists" are DIFFERENT CLAIMS, and the check used to make
# the second one out of the first. A Job can reach Complete having written nothing — a changed base
# image, an empty source, an error swallowed inside the container — and the attendee then starts the
# lab against an empty world with a ✅ telling them it is ready. A Bound PVC cannot close the gap
# either: an empty volume Binds exactly as well as a seeded one.
#
# So the seed counts the rows it wrote and patches that count into the entry marker as `seededRows`
# (gitops/entry-states/jobs-batch-kueue/templates/claims-data.yaml, chart 0.1.8+). The number is
# DERIVED from the artifact — `wc -l` of the file it just wrote to the PVC — never a constant
# restated here, so a seed that grows or shrinks the dataset keeps passing without this script
# having to learn its size. Proven on-cluster 2026-08-01 (user5, cluster-s7hkp): the marker read
# 200 and an independent pod mounting claims-data counted 200 data rows in /data/claims.csv.
#
# The MARKER is the durable record on purpose. This used to be a best-effort `oc logs … | grep
# '^seeded '`, printed as INFO and asserted on by nothing, because a completed Job keeps its
# Complete condition long after its pod's logs are garbage-collected — so the log went silent
# exactly on the namespaces old enough that you most want to know. The marker outlives the pod.
#
# Sets SEEDED_ROWS for the caller's message.
# 0 = a real, non-zero count is recorded · 1 = recorded but zero or non-numeric (the seed ran and
# produced nothing usable) · 2 = the KEY is absent from a marker that does exist — an entry state
# materialized by a pre-0.1.8 seed · 3 = the marker ConfigMap itself is not there · 4 = the API
# could not be asked.
SEEDED_ROWS=""
seeded_rows_state() {
  local rc=0
  oc_read get cm ws-entry-jobs-batch-kueue -n "$NS" -o jsonpath='{.data.seededRows}' || rc=$?
  if (( rc == 2 )); then return 4; fi
  if (( rc != 0 )); then return 3; fi   # NotFound on the ConfigMap; the marker check above owns that ❌
  SEEDED_ROWS="$OC_OUT"
  # rc 0 with an empty string is the API's real answer that the KEY is absent — a pre-0.1.8 marker,
  # not a missing dataset. Kept distinct from state 1 because the two deserve opposite verdicts.
  [[ -n "$SEEDED_ROWS" ]] || return 2
  [[ "$SEEDED_ROWS" =~ ^[0-9]+$ ]] || return 1
  # >= 1, never == 200: "the seed wrote something" is the assertion, and the size of the dataset
  # belongs to the seed. Pinning the number here would put the checker back in the business of
  # restating a constant, which is the whole defect this predicate exists to remove.
  (( SEEDED_ROWS >= 1 ))
}

# An ATTENDEE-created Job has Completed (end state).
#
# This used to scan every Job in the namespace and pass if ANY had Complete=True. It could not fail:
# `ws start` itself materializes two Jobs that complete — claims-data-seed-… and maas-copy-… — so the
# check went green on a namespace where the attendee had done nothing, while the very Job its own hint
# names ("run the monthly-statement Job") did not exist. Measured on ksls5 2026-07-29:
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
  [[ "$OC_OUT" == *True* ]]
}

# At least one Kueue Workload carries Admitted=True (admission control was exercised).
any_workload_admitted() {
  oc_read get workloads -n "$NS" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Admitted")].status}{"\n"}{end}' || return 1
  [[ "$OC_OUT" == *True* ]]
}

# The per-user ClusterQueue is Active (only checkable with cluster read — admin/CI). The Forbidden
# case never reaches here: the caller's `cq_err` probe below routes an attendee identity to warn().
cq_active() {
  oc_read get clusterqueue "$CQ" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' || return 1
  [[ "$OC_OUT" == "True" ]]
}

# --- entry state (what `ws start jobs-batch-kueue` materializes) --------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                              || hint "run: ws start jobs-batch-kueue --user ${USER_NAME}"
check "entry marker ws-entry-jobs-batch-kueue present"               oc get cm ws-entry-jobs-batch-kueue -n "$NS"              || hint "entry app not synced — ws start jobs-batch-kueue --user ${USER_NAME}"
check "workshop quota present in ${NS}"                 oc get resourcequota workshop-quota -n "$NS" || hint "entry app not synced — ws reset jobs-batch-kueue --user ${USER_NAME}"
check "namespace opted into Kueue (kueue.openshift.io/managed=true)" ns_kueue_managed                || hint "without this label Kueue ignores labeled Jobs — ws reset jobs-batch-kueue --user ${USER_NAME}"
check "LocalQueue user-queue is Active (bound to ${CQ})" localqueue_active                            || hint "LocalQueue missing/inactive — check the workshop layer created ${CQ}: ws reset jobs-batch-kueue --user ${USER_NAME}"
check "claims-data PVC is Bound"                        pvc_bound claims-data                        || hint "dataset PVC not bound — needs an RWX StorageClass; check: oc get pvc claims-data -n ${NS}"
# This check now claims ONLY what a Job condition can support: the seed hook ran to completion. The
# dataset's own existence is asserted by the seededRows check below, which reads a number the seed
# derived from the file it wrote. Two claims, two checks — conflating them was the defect.
SEED_DESC="claims-data seed Job Completed (the seed hook ran)"
seed_rc=0; seed_state || seed_rc=$?
case "$seed_rc" in
  0) check "$SEED_DESC" true ;;
  1) check "$SEED_DESC" false \
       || hint "the seed Job exists but has not Completed — read it, then re-materialize: oc describe job/claims-data-seed-jobs-batch-kueue-${USER_NAME} -n ${NS}; ws reset jobs-batch-kueue --user ${USER_NAME}" ;;
  2) check "$SEED_DESC" false \
       || hint "there is NO claims-data seed Job in ${NS} — the Sync hook never ran, so claims-data is an empty volume (a Bound PVC says nothing about its contents) and every lab Job that reads /data/claims.csv will fail. A successful seed leaves its Job behind, so this is not cleanup: ws reset jobs-batch-kueue --user ${USER_NAME}" ;;
  4) warn "$SEED_DESC — the cluster API did not answer"
     hint "not your lab, and not graded: the cluster could not be asked whether the seed Job ran. Re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor" ;;
  *) check "$SEED_DESC" false \
       || hint "namespace ${NS} does not exist — ws start jobs-batch-kueue --user ${USER_NAME}" ;;
esac
# THE DATASET ITSELF — graded, and on a number the seed derived from the file it wrote (see
# seeded_rows_state). Runs unconditionally, NOT gated on seed_rc: the marker is durable and the Job
# is not, so a namespace whose seed Job was somehow removed can still prove its data was seeded.
ROWS_DESC="claims-data holds a seeded dataset (row count recorded by the seed itself)"
rows_rc=0; seeded_rows_state || rows_rc=$?
case "$rows_rc" in
  0) check "${ROWS_DESC} — marker records ${SEEDED_ROWS} rows" true ;;
  1) check "$ROWS_DESC" false \
       || hint "the seed recorded '${SEEDED_ROWS}' rows — it completed WITHOUT writing a usable dataset, so every lab Job that reads /data/claims.csv will find nothing. A green seed Job does not contradict this: reaching Complete and writing data are different things. Re-materialize: ws reset jobs-batch-kueue --user ${USER_NAME}" ;;
  # DELIBERATE ⚠, not ❌. This namespace was materialized by a seed that predates the row-count
  # record, so there is genuinely nothing here to check — the dataset may be perfectly fine. Failing
  # it would red-flag healthy pre-existing worlds (measured: user1 and user7 on cluster-s7hkp,
  # 2026-08-01, both correctly seeded, both on markers without the key) and send an attendee to a
  # `ws reset` that destroys the lab they are in the middle of. The precedent in this suite is
  # seed_image_intact, which PASSES on an older marker for the same reason — but a silent pass is
  # the trust bug this whole change is about, so this says out loud that it checked nothing: warn()
  # counts a skip, verify_summary then prints "did NOT fully verify", and CI (VERIFY_STRICT=1)
  # exits 3 rather than a clean 0.
  2) warn "$ROWS_DESC — this entry state predates the seed's row-count record"
     hint "not your lab, and not graded: your namespace was materialized before the seed began recording what it wrote, so this check has nothing to read. The seed Job check above still applies. For a real verdict on the data, re-materialize when you are between exercises: ws reset jobs-batch-kueue --user ${USER_NAME}" ;;
  3) check "$ROWS_DESC" false \
       || hint "the entry marker ConfigMap is missing entirely, so nothing recorded what was seeded — see the marker check above: ws start jobs-batch-kueue --user ${USER_NAME}" ;;
  *) warn "$ROWS_DESC — the cluster API did not answer"
     hint "not your lab, and not graded: the cluster could not be asked what the seed recorded. Re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor" ;;
esac
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

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab / `ws solve jobs-batch-kueue` looks like) -----------
  check "an attendee-created Job has Completed"          any_attendee_job_complete                    || hint "run the monthly-statement Job (lab exercise 1) — or ws solve jobs-batch-kueue --user ${USER_NAME}"
  check "nightly-statement CronJob exists"               oc get cronjob nightly-statement -n "$NS"    || hint "create the CronJob (lab exercise 4) — or ws solve jobs-batch-kueue --user ${USER_NAME}"
  check "a Kueue Workload shows Admitted=True"           any_workload_admitted                        || hint "submit a Job through the LocalQueue (lab exercise 5/6) — or ws solve jobs-batch-kueue --user ${USER_NAME}"
fi

verify_summary
