#!/usr/bin/env bash
# Verify trusted-supply-chain — Trusted Software Supply Chain [ADS].
#   Entry: {user}-cicd exists · entry marker CM · the parasol-claims-supply-chain Pipeline present ·
#          the copied rox-api-token Secret (scan-gate contract) + chains-cosign-pub ConfigMap (verify
#          contract) · Gitea fork answers with its seed-vulnerable branch · the curated parasol-tasks
#          acs-image-check task is reachable. ONLY in --entry-only mode: the fork's seed-vulnerable
#          branch still carries the seeded log4j-core CVE (the lab's fix removes it, so this check is
#          NOT run in full mode — it validates entry materialization, not lab completion).
#   End:   a supply-chain PipelineRun reached overall Succeeded — the ACS scan gate ("Block Log4Shell
#          at build") only passes on a CLEAN source, so this asserts the FIX actually happened — AND
#          Tekton Chains signed a build TaskRun (chains.tekton.dev/signed=true). NB: "an image was
#          built" / "a TaskRun is signed" are NOT sufficient on their own — a scan-BLOCKED vulnerable
#          run still builds + signs an image (only the gate fails it), so those alone false-green an
#          UNFIXED attendee (G4 SEV2). Succeeded ⟺ log4j-core removed (or `ws solve`'s clean main).
# End checks are outcome-based (satisfied by an attendee's real pipeline run AND by `ws solve`).
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-cicd"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea host, discovered environment-agnostically (route if readable, else derived from the cluster
# ingress domain — the attendee-safe pattern; attendees can't read the gitea route).
gitea_host() {
  local host domain
  host="$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-gitea.${domain}"
  fi
  echo "$host"
}

# A Gitea repo/branch exists → the (public) API answers 2xx anonymously.
gitea_repo_exists() {
  local owner="$1" repo="$2" host
  host="$(gitea_host)"; [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${owner}/${repo}"
}
gitea_branch_exists() {
  local owner="$1" repo="$2" branch="$3" host
  host="$(gitea_host)"; [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${owner}/${repo}/branches/${branch}"
}
# A raw file on a branch contains a needle (the seeded flaw).
gitea_raw_contains() {
  local owner="$1" repo="$2" path="$3" ref="$4" needle="$5" host
  host="$(gitea_host)"; [[ -n "$host" ]] || return 1
  curl -ksf "https://${host}/api/v1/repos/${owner}/${repo}/raw/${path}?ref=${ref}" 2>/dev/null | grep -q "$needle"
}

# Tekton Chains signed at least one TaskRun in this namespace (signature attached).
signed_taskrun_exists() {
  oc get taskruns.tekton.dev -n "$1" -o jsonpath='{range .items[*]}{.metadata.annotations.chains\.tekton\.dev/signed}{"\n"}{end}' 2>/dev/null | grep -q 'true'
}
# A parasol-claims-supply-chain PipelineRun reached overall Succeeded. Tekton labels every run from a
# pipelineRef with tekton.dev/pipeline=<name>, so this catches the attendee's re-run AND `ws solve`'s
# run. Succeeded is the definitive fix signal: the ACS gate ("Block Log4Shell at build", CVSS 10) fails
# the WHOLE run on a vulnerable source even though build-image + Chains-signing still complete — so a
# proxy like "image built" or "a signed TaskRun exists" greenlights an attendee who never removed
# log4j-core (G4 SEV2, reproduced on user3-cicd). Overall Succeeded ⟺ the scan passed ⟺ clean source.
supply_chain_run_succeeded() {
  oc get pipelineruns.tekton.dev -n "$1" -l tekton.dev/pipeline=parasol-claims-supply-chain \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' 2>/dev/null | grep -qx True
}

# --- entry state that SURVIVES lab completion (checked in BOTH modes) --------
check "namespace ${NS} exists"                             oc get ns "$NS"                                     || hint "run: ws start trusted-supply-chain --user ${USER_NAME}"
check "entry marker ws-entry-trusted-supply-chain present"                  oc get cm ws-entry-trusted-supply-chain -n "$NS"                     || hint "entry app not synced — ws start trusted-supply-chain --user ${USER_NAME}"
check "Pipeline parasol-claims-supply-chain present"       oc get pipelines.tekton.dev parasol-claims-supply-chain -n "$NS" || hint "entry app not synced — ws start trusted-supply-chain --user ${USER_NAME}"
check "rox-api-token copied into ${NS} (scan-gate secret)" oc get secret rox-api-token -n "$NS"                || hint "the secrets hook copies it from stackrox — ws reset trusted-supply-chain --user ${USER_NAME} (needs the trust stack)"
check "chains-cosign-pub copied into ${NS} (verify key)"   oc get cm chains-cosign-pub -n "$NS"                || hint "the secrets hook copies it from openshift-pipelines — needs the trust-signing component"
check "Gitea fork ${USER_NAME}/parasol-claims answers"     gitea_repo_exists "$USER_NAME" parasol-claims       || hint "fork missing — re-run: ws start trusted-supply-chain --user ${USER_NAME} (fork job)"
check "fork branch seed-vulnerable exists"                 gitea_branch_exists "$USER_NAME" parasol-claims seed-vulnerable || hint "re-run the fork/seed job: ws reset trusted-supply-chain --user ${USER_NAME}"
check "curated library task acs-image-check reachable"     oc get tasks.tekton.dev acs-image-check -n parasol-tasks        || hint "parasol-tasks library missing — sync the workshop-config Argo app"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: the seeded flaw exists ONLY in the fresh entry state. The trusted-supply-chain lab's fix REMOVES
  # log4j-core from the fork, so in FULL mode this would false-FAIL a successful attendee (G3
  # finding) — it validates ENTRY materialization, not lab completion. Same mode-split as gitops-fundamentals.
  check "seed-vulnerable carries the seeded log4j CVE"     gitea_raw_contains "$USER_NAME" parasol-claims pom.xml seed-vulnerable "log4j-core" || hint "re-run the fork/seed job: ws reset trusted-supply-chain --user ${USER_NAME}"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  # The seeded CVE is expected to be GONE here — removing log4j-core IS the lab's fix (success), so
  # the seeded-CVE check above is deliberately NOT run in this mode. Assert the ACTUAL fixed outcome
  # (a run that PASSED the scan gate), not the proxy "an image was built" — a blocked vulnerable run
  # builds + signs an image too, so the proxy false-greens an attendee who never removed log4j (SEV2).
  check "supply-chain run PASSED the scan gate (a run Succeeded)" supply_chain_run_succeeded "$NS"             || hint "the ACS gate blocks log4j-core: remove its <dependency> from seed-vulnerable's pom.xml and re-run the pipeline (or ws solve trusted-supply-chain --user ${USER_NAME} builds the clean main). A scan-blocked run stays Failed even though it built + signed an image."
  check "Tekton Chains signed the build (signed TaskRun present)" signed_taskrun_exists "$NS"                  || hint "Chains signs a few seconds after the build TaskRun completes — re-check, or run the pipeline"
fi

verify_summary
