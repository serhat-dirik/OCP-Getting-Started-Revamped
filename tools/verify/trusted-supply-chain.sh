#!/usr/bin/env bash
# Verify trusted-supply-chain — Trusted Software Supply Chain [ADS].
#   Entry (both modes — none of it is consumed by the lab):
#          {user}-cicd exists · entry marker CM · Pipeline parasol-claims-trusted-build present and
#          admissible (one PVC-backed workspace) · {user}-cicd opted into the RHTAS policy controller
#          (policy.rhtas.com/include=true — admission enforces image policies only there) · the copied
#          rox-api-token Secret (the scan task's contract) · the attendee's Gitea fork with `main` and
#          `seed-vulnerable` · the four shared Tasks the Pipeline resolves (git-clone + buildah in
#          openshift-pipelines; acs-image-check + verify-conforma in ogsr-parasol-tasks) · the cluster's
#          SPIFFE OIDC issuer answers (the local `cosign verify` names Chains' keyless identity by it) ·
#          the cluster image policy ogsr-parasol-claims-keyless guards parasol-claims-secure (cluster
#          state, but readable by the attendee and the thing the admission exercise depends on).
#          ONLY --entry-only: seed-vulnerable still carries the seeded log4j-core (template rule 14 —
#          an attendee may legitimately change that branch).
#   End:   a Succeeded run of the Pipeline · Deployment parasol-claims available on a DIGEST of this
#          namespace's parasol-claims-secure repository (the one the cluster image policy guards) · that
#          digest came from a build-image TaskRun Tekton Chains signed. Plain full mode (not --solve) also grades the admission exercise: the
#          out-of-chain image parasol-claims-secure:unsigned exists and is not what runs.
#          While a run is in flight and none has succeeded yet, the end facts are ⚠, never ❌.
#   Not graded: the local checks (cosign verify / verify-attestation / ec validate) read the registry
#          and Rekor and change nothing, so there is nothing to grade.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-cicd"
PIPELINE="parasol-claims-trusted-build"
REPO="image-registry.openshift-image-registry.svc:5000/${NS}/parasol-claims-secure"

# --- helpers (oc + curl only) -------------------------------------------------
# gitea_host() is shared (tools/verify/_lib.sh): call it bare and read $GITEA_HOST.

gitea_repo_exists() {
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${1}/${2}"
}
gitea_branch_exists() {
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${1}/${2}/branches/${3}"
}
gitea_raw_contains() {  # owner repo path ref needle
  gitea_host || return 1
  curl -ksf "https://${GITEA_HOST}/api/v1/repos/${1}/${2}/raw/${3}?ref=${4}" 2>/dev/null | grep -q "$5"
}
# The policy controller's opt-in label. Read in THIS shell (OC_OUT), never `$(…)`, so a blip is ⚠.
ns_opted_in() {
  oc_read get namespace "$1" -o jsonpath='{.metadata.labels.policy\.rhtas\.com/include}' || return 1
  [[ "$OC_OUT" == "true" ]]
}
# The issuer is READ from the install (platform-observer grant), never computed.
oidc_issuer_answers() {
  oc_read get spireoidcdiscoveryprovider cluster -o jsonpath='{.spec.jwtIssuer}' || return 1
  local issuer="$OC_OUT"
  [[ -n "$issuer" ]] || return 1
  http_read "${issuer}/.well-known/openid-configuration" || return 1
  [[ "$HTTP_CODE" == "200" ]] && grep -q '"jwks_uri"' <<<"$HTTP_OUT"
}

# The admission policy (workshop-config) exists and scopes this module's repository in every -cicd.
policy_guards_repo() {
  oc_read get clusterimagepolicies.policy.sigstore.dev ogsr-parasol-claims-keyless \
    -o jsonpath='{range .spec.images[*]}{.glob}{"\n"}{end}' || return 1
  grep -qF -- "-cicd/parasol-claims-secure" <<<"$OC_OUT"
}

# --- end state ------------------------------------------------------------------
# Every run of the Pipeline as "<name>|<Succeeded>". One read, reused by the predicates below.
RUNS=""
runs_read() {  # → 0 the API answered (RUNS may be legitimately empty), 1 could not ask
  oc_read get pipelineruns.tekton.dev -n "$1" -l "tekton.dev/pipeline=${PIPELINE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' || return 1
  RUNS="$OC_OUT"
}
run_succeeded() { grep -q '|True$' <<<"$RUNS"; }
# Unknown while running; a just-created run has no condition yet (empty field).
run_inflight() { grep -qE '\|(Unknown)?$' <<<"$RUNS"; }
# The deploy task's outcome: available, and pinned by digest to this namespace's repository.
DEPLOYED_DIGEST=""
deployed_by_digest() {
  DEPLOYED_DIGEST=""
  oc_read get deployment parasol-claims -n "$1" \
    -o jsonpath='{.spec.template.spec.containers[0].image}{"|"}{.status.availableReplicas}' || return 1
  local img="${OC_OUT%%|*}" avail="${OC_OUT##*|}"
  [[ "$img" == "${REPO}@sha256:"* ]] || return 1
  DEPLOYED_DIGEST="${img##*@}"
  [[ "${avail:-0}" -ge 1 ]]
}
# That digest was produced by a build-image TaskRun of this Pipeline, and Chains marked it signed.
digest_signed_by_chains() {
  [[ -n "$DEPLOYED_DIGEST" ]] || return 1
  oc_read get taskruns.tekton.dev -n "$1" -l "tekton.dev/pipeline=${PIPELINE},tekton.dev/pipelineTask=build-image" \
    -o jsonpath='{range .items[*]}{.status.results[?(@.name=="IMAGE_DIGEST")].value}{"|"}{.metadata.annotations.chains\.tekton\.dev/signed}{"\n"}{end}' || return 1
  grep -qxF "${DEPLOYED_DIGEST}|true" <<<"$OC_OUT"
}
# The admission exercise's out-of-chain build exists in the guarded repository, and it is not what runs.
unsigned_image_present() {
  oc_read get imagestreamtag parasol-claims-secure:unsigned -n "$1" -o jsonpath='{.image.metadata.name}' || return 1
  [[ -n "$OC_OUT" && "$OC_OUT" != "$DEPLOYED_DIGEST" ]]
}

# --- entry state (both modes) ----------------------------------------------------
PREP_HINT="ws prep trusted-supply-chain (or adm start trusted-supply-chain --user ${USER_NAME})"
check "namespace ${NS} exists"                                  oc get ns "$NS"                                  || hint "run: ${PREP_HINT}"
check "entry marker ws-entry-trusted-supply-chain present"      oc get cm ws-entry-trusted-supply-chain -n "$NS" || hint "entry app not synced — ${PREP_HINT}"
check "Pipeline ${PIPELINE} present"                            oc get pipelines.tekton.dev "$PIPELINE" -n "$NS" || hint "entry app not synced — ${PREP_HINT}"
check "Pipeline ${PIPELINE} admissible (one PVC-backed workspace per task)" pipeline_pvc_workspaces_ok "$PIPELINE" "$NS" shared-workspace \
  || hint "${PIPELINE_PVC_CONFLICT:+task ${PIPELINE_PVC_CONFLICT} binds more than one PVC workspace — }re-materialize: ${PREP_HINT}"
check "${NS} opted into the RHTAS policy controller (policy.rhtas.com/include=true)" ns_opted_in "$NS" \
  || hint "the entry state's label hook sets it — re-materialize: ${PREP_HINT}"
check "rox-api-token copied into ${NS} (the scan task reads it)" oc get secret rox-api-token -n "$NS"            || hint "the token hook copies it from stackrox — ws reset trusted-supply-chain (needs the trust stack)"
check "Gitea fork ${USER_NAME}/parasol-claims answers"           gitea_repo_exists "$USER_NAME" parasol-claims  || hint "fork missing — re-run: ${PREP_HINT} (fork job)"
check "fork branch main exists"                                  gitea_branch_exists "$USER_NAME" parasol-claims main            || hint "re-run the fork job: ws reset trusted-supply-chain"
check "fork branch seed-vulnerable exists"                       gitea_branch_exists "$USER_NAME" parasol-claims seed-vulnerable || hint "re-run the fork job: ws reset trusted-supply-chain"
check "shared Task git-clone resolvable (openshift-pipelines)"   oc get tasks.tekton.dev git-clone -n openshift-pipelines        || hint "OpenShift Pipelines' bundled Tasks are missing — tell your instructor (check the TektonConfig addon)"
check "shared Task buildah resolvable (openshift-pipelines)"     oc get tasks.tekton.dev buildah -n openshift-pipelines          || hint "OpenShift Pipelines' bundled Tasks are missing — tell your instructor (check the TektonConfig addon)"
check "shared Task acs-image-check resolvable (ogsr-parasol-tasks)" oc get tasks.tekton.dev acs-image-check -n ogsr-parasol-tasks || hint "parasol-tasks library missing — tell your instructor (sync the workshop-config Argo app)"
check "shared Task verify-conforma resolvable (ogsr-parasol-tasks)" oc get tasks.tekton.dev verify-conforma -n ogsr-parasol-tasks || hint "parasol-tasks library missing — tell your instructor (sync the workshop-config Argo app)"
check "the cluster's SPIFFE OIDC issuer answers (Chains' keyless identity)" oidc_issuer_answers \
  || hint "the trust stack's workload-identity component publishes it — tell your instructor; they check: oc get spireoidcdiscoveryprovider cluster"
check "cluster image policy ogsr-parasol-claims-keyless guards */parasol-claims-secure" policy_guards_repo \
  || hint "the workshop layer applies it (workshop-config) — tell your instructor; they re-sync the workshop-config Argo app"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # The literal injected XML tag, not the bare word: main's pom mentions "log4j-core" in a comment.
  check "seed-vulnerable carries the seeded log4j CVE" gitea_raw_contains "$USER_NAME" parasol-claims pom.xml seed-vulnerable "<artifactId>log4j-core</artifactId>" \
    || hint "re-run the fork job: ws reset trusted-supply-chain"
else
  # ── END STATE ─────────────────────────────────────────────────────────────────────────────────────
  if ! runs_read "$NS"; then
    warn "could not check: your pipeline runs — the cluster API did not answer (${OC_ERR:0:120})"
    hint "not graded: re-run the same ws verify in a moment; if it keeps happening, check 'oc whoami' and tell your instructor"
  elif ! run_succeeded && run_inflight; then
    # A run takes several minutes; verifying while it streams is not a mistake.
    warn "could not check: the pipeline's outcome (Succeeded run · deployed digest · Chains signature) — a run is still in flight"
    hint "not graded yet: tkn pipelinerun logs --last -f -n ${NS}, then re-run ws verify trusted-supply-chain"
  else
    check "a run of ${PIPELINE} Succeeded" run_succeeded \
      || hint "start it: Pipelines → ${PIPELINE} → Actions → Start (shared-workspace: VolumeClaimTemplate), or: tkn pipeline start ${PIPELINE} -n ${NS} --use-param-defaults --workspace name=shared-workspace,volumeClaimTemplateFile=/tmp/vct.yaml — a red run: tkn pipelinerun logs --last -n ${NS}"
    check "Deployment parasol-claims available, pinned to a digest of ${NS}/parasol-claims-secure" deployed_by_digest "$NS" \
      || hint "the pipeline's deploy task creates it — read: oc get deployment parasol-claims -n ${NS} -o jsonpath='{.spec.template.spec.containers[0].image}'"
    check "that digest was built by build-image and signed by Tekton Chains" digest_signed_by_chains "$NS" \
      || hint "Chains marks the build-image TaskRun chains.tekton.dev/signed=true seconds after it ends — read: oc get taskruns -n ${NS} -l tekton.dev/pipelineTask=build-image -o custom-columns=NAME:.metadata.name,SIGNED:.metadata.annotations.chains\\.tekton\\.dev/signed"
  fi
  if [[ "$SOLVE_MODE" == "true" ]]; then
    # `ws solve` runs the pipeline only; the out-of-chain build is the attendee's own beat.
    na "the admission exercise (the out-of-chain parasol-claims-secure:unsigned build) — \`ws solve\` runs the pipeline and deliberately nothing else"
  else
    check "admission exercise: your out-of-chain build parasol-claims-secure:unsigned exists and is not what runs" unsigned_image_present "$NS" \
      || hint "build it outside the pipeline with a BuildConfig into parasol-claims-secure:unsigned (the lab's admission exercise), then try to deploy it"
  fi
fi

verify_summary
