#!/usr/bin/env bash
# Verify trusted-supply-chain — Trusted Software Supply Chain [ADS].
#   Entry: {user}-cicd exists · entry marker CM · the parasol-claims-supply-chain Pipeline present ·
#          the copied rox-api-token Secret (scan-gate contract) + chains-cosign-pub ConfigMap (verify
#          contract) · Gitea fork answers with its seed-vulnerable branch · the curated parasol-tasks
#          acs-image-check task is reachable · AND the PRE-SCANNED trust artifact: warm-clean-image.yaml
#          builds the CLEAN main branch at every prep, so a Chains-signed parasol-claims:latest (with its
#          .sig + .att tags) is present and a supply-chain run passed the scan gate BEFORE the attendee
#          starts — that warm signed image is what the trust lab (cosign verify → attestation → admission)
#          reads, so it is asserted in BOTH modes (owner's 2026-07-18 pre-scanned-image rebalance).
#          ONLY in --entry-only mode: the fork's seed-vulnerable branch still carries the seeded log4j-core
#          CVE (the attendee's optional SBOM-fix beat removes it, so this entry-materialization check is
#          NOT run in full mode — template rule 14, mode-split).
#   End:   the trust end state SURVIVES a completed lab — the signed parasol-claims:latest, Chains signing,
#          and the scan-gate-passed run are all still present. The rebalanced lab is verification-centric
#          (cosign verify / attestation / keyless sign-blob leave no destructive namespace mutation; the
#          attendee's own red beat builds a SEPARATE :candidate tag), so entry and end assert the same
#          trust outcome — entry-only just adds the seed. NB: "an image was built" alone is NOT the signal:
#          a scan-BLOCKED vulnerable run also builds+signs an image, so assert a run that SUCCEEDED the gate
#          (⟺ clean source) plus the signed :latest, never the bare "image exists" proxy.
# End checks are outcome-based (satisfied by the warm prep image AND by a completed lab).
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
  host="$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-ogsr-gitea.${domain}"
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
# pipelineRef with tekton.dev/pipeline=<name>, so this catches the warm prep run AND the attendee's re-run.
# Overall Succeeded is the definitive clean-gate signal: the ACS gate ("Block Log4Shell at build", CVSS 10)
# fails the WHOLE run on a vulnerable source even though build-image + Chains-signing still complete — so a
# proxy like "image built" or "a signed TaskRun exists" greenlights a run that never passed the gate. The
# warm-clean-image hook builds the CLEAN main branch at prep, so this passes from entry state onward.
supply_chain_run_succeeded() {
  oc get pipelineruns.tekton.dev -n "$1" -l tekton.dev/pipeline=parasol-claims-supply-chain \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' 2>/dev/null | grep -qx True
}
# The pre-scanned trust artifact is present: the ImageStream carries parasol-claims:latest PLUS the two
# Chains-emitted tags derived from its digest — sha256-<digest>.sig (signature) and .att (SLSA attestation).
# This is what the trust lab's cosign verify / verify-attestation / admission beats read; the warm hook
# produces it at prep and a completed lab leaves it intact (the attendee's red beat uses a :candidate tag).
signed_latest_image_present() {
  local tags
  tags="$(oc get imagestream parasol-claims -n "$1" -o jsonpath='{range .status.tags[*]}{.tag}{"\n"}{end}' 2>/dev/null || true)"
  grep -qx 'latest' <<<"$tags" && grep -q '\.sig$' <<<"$tags" && grep -q '\.att$' <<<"$tags"
}

# --- entry state that SURVIVES lab completion (checked in BOTH modes) --------
check "namespace ${NS} exists"                             oc get ns "$NS"                                     || hint "run: ws start trusted-supply-chain --user ${USER_NAME}"
check "entry marker ws-entry-trusted-supply-chain present"                  oc get cm ws-entry-trusted-supply-chain -n "$NS"                     || hint "entry app not synced — ws start trusted-supply-chain --user ${USER_NAME}"
check "Pipeline parasol-claims-supply-chain present"       oc get pipelines.tekton.dev parasol-claims-supply-chain -n "$NS" || hint "entry app not synced — ws start trusted-supply-chain --user ${USER_NAME}"
check "rox-api-token copied into ${NS} (scan-gate secret)" oc get secret rox-api-token -n "$NS"                || hint "the secrets hook copies it from stackrox — ws reset trusted-supply-chain --user ${USER_NAME} (needs the trust stack)"
check "chains-cosign-pub copied into ${NS} (verify key)"   oc get cm chains-cosign-pub -n "$NS"                || hint "the secrets hook copies it from openshift-pipelines — needs the trust-signing component"
check "Gitea fork ${USER_NAME}/parasol-claims answers"     gitea_repo_exists "$USER_NAME" parasol-claims       || hint "fork missing — re-run: ws start trusted-supply-chain --user ${USER_NAME} (fork job)"
check "fork branch seed-vulnerable exists"                 gitea_branch_exists "$USER_NAME" parasol-claims seed-vulnerable || hint "re-run the fork/seed job: ws reset trusted-supply-chain --user ${USER_NAME}"
check "curated library task acs-image-check reachable"     oc get tasks.tekton.dev acs-image-check -n ogsr-parasol-tasks        || hint "parasol-tasks library missing — sync the workshop-config Argo app"
# --- the pre-scanned trust artifact (warm-clean-image hook; present from prep, survives the lab) --------
check "warm supply-chain run PASSED the scan gate (a run Succeeded)" supply_chain_run_succeeded "$NS"          || hint "the warm-clean-image hook builds the CLEAN main branch at prep; if this is red the warm build is still running or failed — watch: tkn pipelinerun logs --last -n ${NS}, or ws prep trusted-supply-chain --user ${USER_NAME} --yes"
check "Tekton Chains signed the build (signed TaskRun present)"      signed_taskrun_exists "$NS"               || hint "Chains signs a few seconds after the build TaskRun completes — re-check, or ws prep trusted-supply-chain --user ${USER_NAME} --yes"
check "pre-scanned signed image parasol-claims:latest (+ .sig/.att)" signed_latest_image_present "$NS"         || hint "the warm signed image is missing — re-materialize: ws prep trusted-supply-chain --user ${USER_NAME} --yes (builds+signs the clean main branch)"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: the seeded flaw is asserted ONLY here. The trusted-supply-chain lab's optional SBOM-fix beat
  # REMOVES log4j-core from the fork, so in FULL mode this would false-FAIL an attendee who did that beat
  # (template rule 14) — it validates ENTRY materialization, not lab completion. Same mode-split as
  # gitops-fundamentals. Needle is the literal injected XML tag, NOT the bare word "log4j-core": the base
  # pom.xml's own SBOM-plugin comment mentions "log4j-core" in prose, and that comment forks onto
  # seed-vulnerable from main too — a bare-word needle here made this check a false-positive rubber stamp.
  check "seed-vulnerable carries the seeded log4j CVE"     gitea_raw_contains "$USER_NAME" parasol-claims pom.xml seed-vulnerable "<artifactId>log4j-core</artifactId>" || hint "re-run the fork/seed job: ws reset trusted-supply-chain --user ${USER_NAME}"
fi

verify_summary
