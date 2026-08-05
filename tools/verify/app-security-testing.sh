#!/usr/bin/env bash
# Verify app-security-testing — DevSecOps [OCP].
#   Entry: {user}-cicd exists · entry marker CM · the parasol-claims-devsecops Pipeline present · the
#          copied sonar-auth Secret (SAST-gate contract) + rox-api-token Secret (image/config-gate
#          contract) · an ephemeral claims-db (the deploy target) · the four curated app-security-testing tasks
#          (sonar-scan / trivy-scan / roxctl-deployment-check / zap-baseline) reachable in parasol-tasks
#          — AND, in --entry-only mode only, that the lab has NOT already been run here: no
#          parasol-claims-devsecops PipelineRun and no parasol-claims Route. That last pair is the
#          exact negation of the End pair below, and it is what lets `ws prep` tell a fresh world
#          from a finished one (audit F-05; see no_devsecops_run).
#   End:   a parasol-claims-devsecops PipelineRun reached overall Succeeded — because EVERY gate
#          (SAST/SCA/unit/image-scan/sign/config-check/DAST) must pass for the run to succeed, this
#          asserts the whole secured chain ran green — AND the deploy stage created the parasol-claims
#          edge Route (the browser-reachable app is the visible outcome).
# End checks are outcome-based (satisfied by an attendee's real capstone run AND by `ws solve`).
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-cicd"

# A parasol-claims-devsecops PipelineRun reached overall Succeeded. Tekton labels every run from a
# pipelineRef with tekton.dev/pipeline=<name>, so this catches the attendee's run AND `ws solve`'s run.
# Succeeded ⟺ EVERY gate passed (any red gate fails the whole run) ⟺ a clean, fully-secured build.
# oc_read, not `2>/dev/null`: an empty answer from a silenced read is indistinguishable from an API
# that never answered, and this is the module's single capstone verdict — a false ❌ here tells an
# attendee their fully-green pipeline failed. rc 0 with an empty OC_OUT stays a real ❌ (no run has
# Succeeded); "could not ask" becomes ⚠ via VERIFY_INCONCLUSIVE.
devsecops_run_succeeded() {
  oc_read get pipelineruns.tekton.dev -n "$1" -l tekton.dev/pipeline=parasol-claims-devsecops \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' || return 1
  grep -qx True <<<"$OC_OUT"
}

# Attendee-visibility of the curated Task library. The four `oc get tasks -n ogsr-parasol-tasks`
# checks below read as the CALLER — green as admin even if the per-user parasol-tasks-readers
# RoleBinding is gone, in which case the attendee's pipeline fails at task resolution mid-run with no
# earlier signal. `--as` needs impersonation rights (admin/CI); the attendee's own
# SelfSubjectAccessReview is the attendee answer. Flags stay LITERAL — an --as built from a variable
# reviews the wrong subject.
# The two identity PROBES go through oc_read as well — they pick which question to ask, and a silenced
# probe answers "not the attendee, cannot impersonate" for an unreachable API exactly as it does for a
# genuine attendee-run, so the graded can-i below would be asked in the wrong identity.
# --- the entry-mode clean slate (audit F-05) ---------------------------------
#
# WHY THESE EXIST. `ws prep` reads `<script> --entry-only`'s rc as the boolean "is this world already
# prepared?" (tools/ws/ws cmd_prep). Until this pair existed, --entry-only ran the shared block above
# and then hit a bare `:` — an explicit no-op — so it graded ONLY things a COMPLETED lab still
# satisfies: the namespace, the marker, the Pipeline, the two copied Secrets, claims-db, the task
# library. A namespace holding a finished capstone therefore returned rc 0, prep printed "already
# prepared — nothing to do", DID NOT PURGE, and the attendee began the DevSecOps module with a green
# capstone run and a deployed, routed parasol-claims already sitting in {user}-cicd. `ws verify`'s
# full mode would have gone green for them immediately, on somebody else's run.
#
# Two fixes for this same defect are already in this tree and both say why it matters:
# config-multienv.sh's obj_absent and serverless-zero-to-hero.sh's single_revision.
#
# THE TWO ASSERTIONS ARE THE EXACT MIRROR OF THE TWO END CHECKS — a Succeeded parasol-claims-devsecops
# PipelineRun, and the Route its deploy stage creates. Keep that one-for-one correspondence if either
# side changes: an entry check that negates a strict SUBSET of what the end check accepts leaves a
# world that is COMPLETE in full mode and A CLEAN SLATE in entry mode simultaneously, and prep then
# either skips the setup or offers to wipe a world it has just called finished.
#
# EXISTENCE, not "Succeeded". no_devsecops_run is one step stronger than the literal negation of
# devsecops_run_succeeded, deliberately: a run that executed and went RED is not a completed lab and
# is not a clean slate either. It is the residue of somebody's attempt — plus a per-run workspace PVC
# against the namespace quota — and prep is exactly the thing that should clear it. It cannot
# false-red a correct entry state, because the entry chart contains no PipelineRun at all (the only
# one in gitops/entry-states/app-security-testing/ is inside solve-endstate.yaml, wholly
# `.Values.solve`-gated), and `ws reset` purges the namespace with `oc delete all,pvc`.
#
# THE LABEL IS TEKTON'S OWN, matching the end check byte for byte: Tekton stamps
# tekton.dev/pipeline=<name> on every run made from a pipelineRef, which is why this catches an
# attendee's `tkn pipeline start`, a console-launched run, and `ws solve`'s generateName'd
# solve-devsecops- run alike, without this script restating a single run name.
#
# oc_absent, NEVER `! oc get … 2>/dev/null`: a negation is the one direction in which a silenced read
# certifies a clean slate from an API that never answered, and a wrongly-green entry check is what
# sends prep past the purge. The namespace is proven PRESENT first, or the whole assertion is
# vacuously true on a cluster where nothing materialized.
no_devsecops_run() {  # <namespace> → 0 only when the API ANSWERED and no devsecops run exists at all
  oc_present get ns "$1" -o name || return 1
  oc_absent  get pipelineruns.tekton.dev -n "$1" -l tekton.dev/pipeline=parasol-claims-devsecops -o name
}

# Same name and signature as config-multienv.sh's copy on purpose: when this is hoisted into _lib.sh
# (three scripts carry it after this change) the collapse should be mechanical.
obj_absent() {  # <type> <name> <namespace> → 0 only when the API ANSWERED and it is not there
  oc_present get ns "$3" -o name || return 1
  oc_absent  get "$1" "$2" -n "$3" -o name
}

attendee_reads_task_library() {
  local me imp_rc=0
  oc_read whoami || OC_OUT=""
  me="$OC_OUT"
  oc_read auth can-i impersonate users || imp_rc=$?
  if [[ "$me" != "$USER_NAME" && "$imp_rc" -eq 0 ]]; then
    oc auth can-i get tasks.tekton.dev -n ogsr-parasol-tasks --as="$USER_NAME" --as-group=workshop-attendees
  else
    oc auth can-i get tasks.tekton.dev -n ogsr-parasol-tasks
  fi
}

# --- entry state that SURVIVES lab completion (checked in BOTH modes) --------
check "namespace ${NS} exists"                              oc get ns "$NS"                                        || hint "run: ws start app-security-testing --user ${USER_NAME}"
check "entry marker ws-entry-app-security-testing present"                   oc get cm ws-entry-app-security-testing -n "$NS"                        || hint "entry app not synced — ws start app-security-testing --user ${USER_NAME}"
check "Pipeline parasol-claims-devsecops present"           oc get pipelines.tekton.dev parasol-claims-devsecops -n "$NS"      || hint "entry app not synced — ws start app-security-testing --user ${USER_NAME}"
check "sonar-auth copied into ${NS} (SAST-gate secret)"     oc get secret sonar-auth -n "$NS"                      || hint "the secrets hook copies it from sonarqube/sonar-ci-token — ws reset app-security-testing --user ${USER_NAME} (needs the appsec stack)"
check "rox-api-token copied into ${NS} (scan-gate secret)"  oc get secret rox-api-token -n "$NS"                   || hint "the secrets hook copies it from stackrox — ws reset app-security-testing --user ${USER_NAME} (needs the trust stack)"
check "ephemeral claims-db present (deploy target)"         oc get deploy claims-db -n "$NS"                       || hint "entry app not synced — ws start app-security-testing --user ${USER_NAME}"
check "curated task sonar-scan reachable"                   oc get tasks.tekton.dev sonar-scan -n ogsr-parasol-tasks                || hint "parasol-tasks library missing the app-security-testing tasks — sync the workshop-config Argo app"
check "curated task trivy-scan reachable"                   oc get tasks.tekton.dev trivy-scan -n ogsr-parasol-tasks                || hint "parasol-tasks library missing the app-security-testing tasks — sync the workshop-config Argo app"
check "curated task roxctl-deployment-check reachable"      oc get tasks.tekton.dev roxctl-deployment-check -n ogsr-parasol-tasks   || hint "parasol-tasks library missing the app-security-testing tasks — sync the workshop-config Argo app"
check "curated task zap-baseline reachable"                 oc get tasks.tekton.dev zap-baseline -n ogsr-parasol-tasks              || hint "parasol-tasks library missing the app-security-testing tasks — sync the workshop-config Argo app"
# The Tasks existing is not the outcome — the attendee's PipelineRun resolving them is.
check "attendee can read the curated task library (parasol-tasks-readers)" attendee_reads_task_library || hint "the devsecops PipelineRun will fail at task resolution — the ${USER_NAME} parasol-tasks-readers RoleBinding in ogsr-parasol-tasks is missing; sync workshop-config"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the clean slate ------------------------------------------
  # This block used to be a bare `:` whose comment ASSERTED the thing it declined to check — "no
  # PipelineRun has run yet on a fresh entry state" — which is true of a fresh entry state and says
  # nothing at all about the world actually in front of it. Now it is checked. See no_devsecops_run
  # above for why an unchecked clean slate costs `ws prep` its purge.
  info "entry state — these checks assert a CLEAN SLATE: they fail when the lab has already been run here, which is what tells 'ws prep' to purge and re-materialize"
  check "no parasol-claims-devsecops PipelineRun yet (running it IS the lab)" no_devsecops_run "$NS" || hint "this is LEFTOVER from an earlier run, not a broken environment — a fresh entry state carries the Pipeline but no runs of it. Clear it (this also frees the per-run workspace PVCs against your quota): ws reset app-security-testing --user ${USER_NAME}"
  check "no parasol-claims Route yet (the deploy stage creates it)"           obj_absent route parasol-claims "$NS" || hint "this is LEFTOVER from an earlier run — only a Succeeded capstone creates this edge Route, so a fresh entry state has none. Clear it: ws reset app-security-testing --user ${USER_NAME}"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  # Every gate must pass for the run to Succeed, so this single check asserts the whole secured chain
  # ran green (a proxy like "an image was built" would false-green a run blocked at a later gate).
  # The old hint opened with "fix the flagged issue", which presumes a run happened AND went red. On a
  # fresh entry state no PipelineRun exists at all, and that phrasing read as a broken environment to
  # somebody who had simply not started yet. Name the no-run case first, since it is the common one.
  check "capstone run PASSED all gates (a run Succeeded)"   devsecops_run_succeeded "$NS"                          || hint "not done yet? no PipelineRun in ${NS} has Succeeded — before you start, that is the expected state, because RUNNING the secured pipeline IS the lab (or: ws solve app-security-testing --user ${USER_NAME} runs the clean main). If a run DID execute and went red, that is a real gate failure and the flagged issue is worth fixing: tkn pr list -n ${NS}"
  check "deploy stage created the parasol-claims Route"     oc get route parasol-claims -n "$NS"                   || hint "not done yet — the deploy stage creates this Route ('oc create route edge parasol-claims') and it appears only after a Succeeded run, so it is expected to be missing until you run the pipeline"
fi

verify_summary
