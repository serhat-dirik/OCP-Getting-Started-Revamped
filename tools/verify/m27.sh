#!/usr/bin/env bash
# Verify M27 — DevSecOps [OCP].
#   Entry: {user}-cicd exists · entry marker CM · the parasol-claims-devsecops Pipeline present · the
#          copied sonar-auth Secret (SAST-gate contract) + rox-api-token Secret (image/config-gate
#          contract) · an ephemeral claims-db (the deploy target) · the four curated M27 tasks
#          (sonar-scan / trivy-scan / roxctl-deployment-check / zap-baseline) reachable in parasol-tasks.
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
devsecops_run_succeeded() {
  oc get pipelinerun -n "$1" -l tekton.dev/pipeline=parasol-claims-devsecops \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' 2>/dev/null | grep -qx True
}

# --- entry state that SURVIVES lab completion (checked in BOTH modes) --------
check "namespace ${NS} exists"                              oc get ns "$NS"                                        || hint "run: ws start m27 --user ${USER_NAME}"
check "entry marker ws-entry-m27 present"                   oc get cm ws-entry-m27 -n "$NS"                        || hint "entry app not synced — ws start m27 --user ${USER_NAME}"
check "Pipeline parasol-claims-devsecops present"           oc get pipeline parasol-claims-devsecops -n "$NS"      || hint "entry app not synced — ws start m27 --user ${USER_NAME}"
check "sonar-auth copied into ${NS} (SAST-gate secret)"     oc get secret sonar-auth -n "$NS"                      || hint "the secrets hook copies it from sonarqube/sonar-ci-token — ws reset m27 --user ${USER_NAME} (needs the appsec stack)"
check "rox-api-token copied into ${NS} (scan-gate secret)"  oc get secret rox-api-token -n "$NS"                   || hint "the secrets hook copies it from stackrox — ws reset m27 --user ${USER_NAME} (needs the trust stack)"
check "ephemeral claims-db present (deploy target)"         oc get deploy claims-db -n "$NS"                       || hint "entry app not synced — ws start m27 --user ${USER_NAME}"
check "curated task sonar-scan reachable"                   oc get task sonar-scan -n parasol-tasks                || hint "parasol-tasks library missing the M27 tasks — sync the workshop-config Argo app"
check "curated task trivy-scan reachable"                   oc get task trivy-scan -n parasol-tasks                || hint "parasol-tasks library missing the M27 tasks — sync the workshop-config Argo app"
check "curated task roxctl-deployment-check reachable"      oc get task roxctl-deployment-check -n parasol-tasks   || hint "parasol-tasks library missing the M27 tasks — sync the workshop-config Argo app"
check "curated task zap-baseline reachable"                 oc get task zap-baseline -n parasol-tasks              || hint "parasol-tasks library missing the M27 tasks — sync the workshop-config Argo app"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  :  # entry-only stops here — no PipelineRun has run yet on a fresh entry state.
else
  # --- end state (what a completed lab / solve looks like) -------------------
  # Every gate must pass for the run to Succeed, so this single check asserts the whole secured chain
  # ran green (a proxy like "an image was built" would false-green a run blocked at a later gate).
  check "capstone run PASSED all gates (a run Succeeded)"   devsecops_run_succeeded "$NS"                          || hint "a red gate fails the whole run — fix the flagged issue and re-run the pipeline (or ws solve m27 --user ${USER_NAME} runs the clean main). Inspect: tkn pr list -n ${NS}"
  check "deploy stage created the parasol-claims Route"     oc get route parasol-claims -n "$NS"                   || hint "the deploy stage runs 'oc create route edge parasol-claims' — it appears after a Succeeded run"
fi

verify_summary
