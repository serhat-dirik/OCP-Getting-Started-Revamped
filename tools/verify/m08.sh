#!/usr/bin/env bash
# Verify M08 — Trusted Software Supply Chain [ADS].
#   Entry: {user}-cicd exists · entry marker CM · the parasol-claims-supply-chain Pipeline present ·
#          the copied rox-api-token Secret (scan-gate contract) + chains-cosign-pub ConfigMap (verify
#          contract) · Gitea fork answers · the fork's seed-vulnerable branch carries the seeded
#          log4j-core CVE · the curated parasol-tasks acs-image-check task is reachable.
#   End:   a parasol-claims image was built (ImageStream present) AND Tekton Chains signed a build
#          TaskRun (chains.tekton.dev/signed=true) — i.e. the pipeline built + signed an image.
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

# Deployment / imagestream / signed-taskrun presence.
imagestream_exists() { oc get imagestream "$1" -n "$2" >/dev/null 2>&1; }
signed_taskrun_exists() {
  oc get taskrun -n "$1" -o jsonpath='{range .items[*]}{.metadata.annotations.chains\.tekton\.dev/signed}{"\n"}{end}' 2>/dev/null | grep -q 'true'
}

# --- entry state (what `ws start m08` materializes) --------------------------
check "namespace ${NS} exists"                             oc get ns "$NS"                                     || hint "run: ws start m08 --user ${USER_NAME}"
check "entry marker ws-entry-m08 present"                  oc get cm ws-entry-m08 -n "$NS"                     || hint "entry app not synced — ws start m08 --user ${USER_NAME}"
check "Pipeline parasol-claims-supply-chain present"       oc get pipeline parasol-claims-supply-chain -n "$NS" || hint "entry app not synced — ws start m08 --user ${USER_NAME}"
check "rox-api-token copied into ${NS} (scan-gate secret)" oc get secret rox-api-token -n "$NS"                || hint "the secrets hook copies it from stackrox — ws reset m08 --user ${USER_NAME} (needs the trust stack)"
check "chains-cosign-pub copied into ${NS} (verify key)"   oc get cm chains-cosign-pub -n "$NS"                || hint "the secrets hook copies it from openshift-pipelines — needs the trust-signing component"
check "Gitea fork ${USER_NAME}/parasol-claims answers"     gitea_repo_exists "$USER_NAME" parasol-claims       || hint "fork missing — re-run: ws start m08 --user ${USER_NAME} (fork job)"
check "fork branch seed-vulnerable exists"                 gitea_branch_exists "$USER_NAME" parasol-claims seed-vulnerable || hint "re-run the fork/seed job: ws reset m08 --user ${USER_NAME}"
check "seed-vulnerable carries the seeded log4j CVE"       gitea_raw_contains "$USER_NAME" parasol-claims pom.xml seed-vulnerable "log4j-core" || hint "re-run the fork/seed job: ws reset m08 --user ${USER_NAME}"
check "curated library task acs-image-check reachable"     oc get task acs-image-check -n parasol-tasks        || hint "parasol-tasks library missing — sync the workshop-config Argo app"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab / solve looks like) -------------------
  check "parasol-claims image built (ImageStream present)" imagestream_exists parasol-claims "$NS"             || hint "run the pipeline (ws solve m08 --user ${USER_NAME}); build-image pushes here"
  check "Tekton Chains signed a build TaskRun"             signed_taskrun_exists "$NS"                         || hint "Chains signs a few seconds after the build TaskRun completes — re-check, or run the pipeline"
fi

verify_summary
