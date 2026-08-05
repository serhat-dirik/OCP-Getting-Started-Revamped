#!/usr/bin/env bash
# Verify pipelines-fundamentals — Pipelines Fundamentals & Task Libraries.
#   Entry: {user}-cicd exists · entry marker CM · claims-db Deployment ready · the
#          parasol-claims-build-test-deploy Pipeline present · Gitea fork answers ·
#          .tekton/pull-request.yaml seeded in the fork · the curated parasol-tasks
#          library is reachable (image-size-report present) — AND, in --entry-only mode only, that
#          the lab has NOT already been run here: no parasol-claims Deployment/ImageStream/Route.
#          That last group is the exact negation of the End group below, and it is what lets
#          `ws prep` tell a fresh world from a finished one (audit F-05; see obj_absent).
#   End:   parasol-claims Deployment ready (the pipeline built it AND it is wired to
#          claims-db, so it is up — no CrashLoop) · a parasol-claims image was built
#          (ImageStream present) · the pipeline created the browser Route itself
#          (edge Route present — the attendee never runs `oc expose`).
# End checks are outcome-based (satisfied by an attendee's real pipeline run AND by
# `ws solve`'s launched run) — they assert a running, DB-backed, pipeline-built app.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-cicd"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Attendee-visibility of the curated Task library. `--as` needs impersonation rights (admin/CI only);
# when the attendee runs this in their own cockpit terminal their SelfSubjectAccessReview IS the
# attendee answer. Flags stay LITERAL in both branches — an --as string built from a variable
# silently reviews the wrong subject (measured 2026-07-29).
# Every read goes through oc_read, in the CALLER's own shell: `$(oc whoami 2>/dev/null)` and a silenced
# `can-i impersonate` both answer "" on an unreachable API, which dropped this into the self branch
# whose can-i then failed for the SAME transport reason and printed ❌ at the attendee.
attendee_reads_task_library() {
  local who_rc=0 imp_rc=0 impersonate="false"
  oc_read whoami || who_rc=$?
  if (( who_rc != 0 )) || [[ "$OC_OUT" != "$USER_NAME" ]]; then
    oc_read auth can-i impersonate users || imp_rc=$?
    # 0 OR 2, the same open-on-"could not ask" as multi-tenancy-workload-security's IMPERSONATE_OK: a
    # transport failure must not quietly re-point the review at the CALLER's own rights. A genuine
    # "no" from the server is rc 1 and still closes the guard.
    case "$imp_rc" in 0|2) impersonate="true";; esac
  fi
  if [[ "$impersonate" == "true" ]]; then
    oc_read auth can-i get tasks.tekton.dev -n ogsr-parasol-tasks --as="$USER_NAME" --as-group=workshop-attendees
  else
    oc_read auth can-i get tasks.tekton.dev -n ogsr-parasol-tasks
  fi
}

# gitea_host() (route if readable, else derived from the cluster ingress domain — the attendee-safe
# pattern; attendees can't read the gitea route) is shared — tools/verify/_lib.sh. GLOBAL, not
# echo-shaped: call it bare and read $GITEA_HOST, never `$(gitea_host)`.

# A Gitea repo exists → the (public) repo API answers 2xx anonymously.
gitea_repo_exists() {
  local owner="$1" repo="$2"
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${owner}/${repo}"
}

# A file exists in a (public) Gitea repo → the contents API answers 2xx anonymously.
gitea_file_exists() {
  local owner="$1" repo="$2" path="$3"
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${owner}/${repo}/contents/${path}"
}

# A raw file on a branch contains a needle — used to assert the Ex3 break-fix TARGET is present
# (fork liveness alone false-passed a stale fork whose ClaimResourceTest.java lacked the toggle, G4).
gitea_raw_contains() {
  local owner="$1" repo="$2" path="$3" ref="$4" needle="$5"
  gitea_host || return 1
  curl -ksf "https://${GITEA_HOST}/api/v1/repos/${owner}/${repo}/raw/${path}?ref=${ref}" 2>/dev/null | grep -q "$needle"
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# --- the entry-mode clean slate (audit F-05) ---------------------------------
#
# WHY THIS EXISTS. `ws prep` reads `<script> --entry-only`'s rc as the boolean "is this world already
# prepared?" (tools/ws/ws cmd_prep). Until this predicate existed, --entry-only graded ONLY the entry
# artefacts — the namespace, the marker, claims-db, the Pipeline, the fork — and a COMPLETED lab
# satisfies every single one of them. So a namespace holding a finished run returned rc 0, prep took
# its "already prepared — nothing to do" fast path, DID NOT PURGE, and the attendee started the lab
# on top of the previous pass: parasol-claims already deployed, already imaged, already routed. The
# module's whole outcome was standing there before they ran anything.
#
# This is the third instance of one defect. The two fixes already in this tree say the same thing:
# config-multienv.sh's obj_absent ("an attendee who did ex 2-3 and stopped passed every entry check,
# so ws prep's fast path returned 'already prepared' WITHOUT purging") and serverless-zero-to-hero.sh's
# single_revision (an orphaned revision survived prep and made exercise 3 fail RevisionNameTaken).
#
# THE ENTRY ASSERTIONS ARE THE EXACT MIRROR OF THE END ONES — the same three objects the end block
# grades (parasol-claims Deployment ready · ImageStream present · Route present), negated one for
# one. That correspondence is the property to preserve when either side changes: if entry negates a
# strict subset of what end accepts, a world in the gap reads as COMPLETE in full mode and as A CLEAN
# SLATE in entry mode at the same time, and prep will happily offer to wipe it or skip setting it up.
#
# ABSENCE, not "not ready". The entry chart materializes claims-db and nothing else app-side (the
# only Deployment in gitops/entry-states/pipelines-fundamentals/templates/ is claims-db; all three
# graded artefacts are produced by the PipelineRun, which is wholly `.Values.solve`-gated in
# solve-endstate.yaml). So absence cannot false-red a correctly-materialized entry state — and it
# additionally catches a run that went red half-way, which is dirty rather than clean, exactly as
# prep should report it.
#
# oc_absent, NEVER `! oc get … 2>/dev/null`. A negation is the one direction where a silenced read
# certifies a clean slate from an API that never answered — and a wrongly-green entry check is what
# makes prep skip the purge. The namespace is proven PRESENT first, or the assertion is vacuously
# true on a cluster where nothing materialized at all.
#
# Same name and signature as config-multienv.sh's copy on purpose: when this is hoisted into
# _lib.sh (three scripts carry it after this change) the collapse should be mechanical.
obj_absent() {  # <type> <name> <namespace> → 0 only when the API ANSWERED and it is not there
  oc_present get ns "$3" -o name || return 1
  oc_absent  get "$1" "$2" -n "$3" -o name
}

# --- entry state (what `ws start pipelines-fundamentals` materializes) --------------------------
check "namespace ${NS} exists"                            oc get ns "$NS"                                    || hint "run: ws start pipelines-fundamentals --user ${USER_NAME}"
check "entry marker ws-entry-pipelines-fundamentals present"                 oc get cm ws-entry-pipelines-fundamentals -n "$NS"                    || hint "entry app not synced — ws start pipelines-fundamentals --user ${USER_NAME}"
check "claims-db deployment ready in ${NS}"               deploy_ready claims-db "$NS"                       || hint "the ephemeral DB is entry state — ws reset pipelines-fundamentals --user ${USER_NAME}"
check "Pipeline parasol-claims-build-test-deploy present" oc get pipelines.tekton.dev parasol-claims-build-test-deploy -n "$NS" || hint "entry app not synced — ws start pipelines-fundamentals --user ${USER_NAME}"
check "Gitea fork ${USER_NAME}/parasol-claims answers"    gitea_repo_exists "$USER_NAME" parasol-claims      || hint "fork missing — re-run: ws start pipelines-fundamentals --user ${USER_NAME} (fork job)"
check "fork carries the Ex3 break-fix target (ClaimResourceTest toggle)" gitea_raw_contains "$USER_NAME" parasol-claims "src/test/java/com/parasol/claims/ClaimResourceTest.java" main "assignAdjusterBeforeApproval" || hint "stale fork — Ex3 is unperformable; ws reset pipelines-fundamentals --user ${USER_NAME} re-asserts the fork's app content from the mirror"
check ".tekton/pull-request.yaml seeded in the fork"      gitea_file_exists "$USER_NAME" parasol-claims ".tekton/pull-request.yaml" || hint "re-run the fork/seed job: ws reset pipelines-fundamentals --user ${USER_NAME}"
check "curated library task image-size-report reachable"  oc get tasks.tekton.dev image-size-report -n ogsr-parasol-tasks    || hint "parasol-tasks library missing — sync the workshop-config Argo app"
# The Task existing is not the outcome: lab.adoc's step has the ATTENDEE run this exact `oc get`
# cross-namespace, which only works through the per-user parasol-tasks-readers RoleBinding. Read as
# admin it is green even with that binding gone. Impersonate where we can; the attendee's own run is
# already the attendee answer (same idiom as observability-health-scale).
check "attendee can read the curated task library (parasol-tasks-readers)" attendee_reads_task_library || hint "the graded cross-namespace read in the lab returns Forbidden — the ${USER_NAME} parasol-tasks-readers RoleBinding in ogsr-parasol-tasks is missing; sync workshop-config"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the clean slate — the pipeline's own three artefacts must NOT exist yet -----
  # Exactly the three objects the end block grades, negated. Read the obj_absent comment above for
  # why this block is load-bearing: without it `ws prep` calls a COMPLETED lab "already prepared".
  info "entry state — these checks assert a CLEAN SLATE: they fail when the lab has already been run here, which is what tells 'ws prep' to purge and re-materialize"
  check "no parasol-claims Deployment yet (the pipeline deploys it)"      obj_absent deploy parasol-claims "$NS"      || hint "this is LEFTOVER from an earlier run, not a broken environment — the entry state ships only claims-db, and parasol-claims appears when the build-test-deploy pipeline deploys it. Clear it: ws reset pipelines-fundamentals --user ${USER_NAME}"
  check "no parasol-claims ImageStream yet (the pipeline builds it)"      obj_absent imagestream parasol-claims "$NS" || hint "this is LEFTOVER from an earlier run — the build-image step pushes this ImageStream, so a fresh entry state has none. Clear it: ws reset pipelines-fundamentals --user ${USER_NAME}"
  check "no parasol-claims Route yet (the pipeline creates it)"           obj_absent route parasol-claims "$NS"       || hint "this is LEFTOVER from an earlier run — the deploy step creates this edge Route itself, so a fresh entry state has none. Clear it: ws reset pipelines-fundamentals --user ${USER_NAME}"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "parasol-claims deployment ready in ${NS}"        deploy_ready parasol-claims "$NS"                  || hint "not done yet? the pipeline is what deploys and wires this app to claims-db, so before you run it this red is expected, not a broken environment (or: ws solve pipelines-fundamentals --user ${USER_NAME}). If a run already Succeeded and the app is still not ready, that one is real: oc get pods -n ${NS}; tkn pr list -n ${NS}"
  check "parasol-claims image built (ImageStream present)" oc get imagestream parasol-claims -n "$NS"        || hint "not done yet — the build-image step pushes here, so no ImageStream before you run the build-test-deploy pipeline is expected"
  check "parasol-claims Route created by the pipeline in ${NS}" oc get route parasol-claims -n "$NS"         || hint "not done yet — the deploy step creates the edge Route itself, so it appears only once the pipeline has run (or: ws solve pipelines-fundamentals --user ${USER_NAME}); attendees never run oc expose here"
fi

verify_summary
