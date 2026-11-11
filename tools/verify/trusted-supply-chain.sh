#!/usr/bin/env bash
# Verify trusted-supply-chain — Trusted Software Supply Chain [ADS].
#   Entry: {user}-cicd exists · entry marker CM · the parasol-claims-supply-chain Pipeline present ·
#          the copied rox-api-token Secret (scan-gate contract) + chains-cosign-pub ConfigMap (verify
#          contract) · Gitea fork answers with its seed-vulnerable branch · the curated parasol-tasks
#          acs-image-check task is reachable · AND the PRE-SCANNED trust artifact: the install builds the
#          CLEAN main branch ONCE in ${TRUSTED_NS} (workshop-config trusted-image.yaml) and every prep copies
#          the Chains-signed image (with its .sig + .att tags) into {user}-cicd as parasol-claims-trusted, so the
#          image is present and the shared run passed the scan gate BEFORE the attendee starts — that
#          signed image is what the trust lab (cosign verify → attestation → admission)
#          reads, so it is asserted in BOTH modes (owner's 2026-07-18 pre-scanned-image rebalance).
#          Also in BOTH modes: the install's ClusterImagePolicy ogsr-signed-parasol-claims names this
#          attendee's parasol-claims-trusted (exercise 5 reads it; it is install state, never per-user).
#          ONLY in --entry-only mode: the fork's seed-vulnerable branch still carries the seeded log4j-core
#          CVE (the attendee's optional SBOM-fix beat removes it, so this entry-materialization check is
#          NOT run in full mode — template rule 14, mode-split).
#   End:   the trust end state SURVIVES a completed lab — the signed parasol-claims-trusted:latest, Chains signing,
#          and the scan-gate-passed run are all still present, so those three are asserted in both modes.
#          NB: "an image was built" alone is NOT the signal there: a scan-BLOCKED vulnerable run also
#          builds+signs an image, so assert a run that SUCCEEDED the gate (⟺ clean source) plus the signed
#          :latest, never the bare "image exists" proxy.
#          ON TOP OF THAT, full mode grades what the ATTENDEE added: the seeded-branch PipelineRun the
#          RHACS gate refused, the :candidate image it built before being refused, that image's own
#          Chains signature pair, and — when this script runs in the attendee's own terminal — the SBOM
#          and the keyless Rekor bundle exercises 1 and 4 leave in their home directory, and exercise 5's
#          two admission pods (claims-signed admitted, claims-unsigned refused at pull). Details and the
#          in-flight / not-my-shell / ws-solve carve-outs are at the end-state block below.
#
# FALSE-GREEN FIX (this file's own defect, 2026-08-05). Until this change the list above WAS the whole
# script: full mode asserted nothing an attendee does, so `ws verify trusted-supply-chain --user userN`
# printed "✅ all 11 checks passed" over a freshly-prepped namespace where nobody had opened the lab
# (measured on user6, 2026-08-05). The old header rationalized it as "entry and end assert
# the same trust outcome", which is true of the WARM artifact and false of the lab: exercise 1 leaves real,
# purgeable cluster state (a seeded-branch PipelineRun that the RHACS gate refused, and the :candidate
# image it built before being refused, signed by Chains like every build). A false ❌ costs an attendee
# twenty minutes; a false ✅ costs them the lesson silently, because nothing ever contradicts it.
# End checks are outcome-based (satisfied by a completed lab, not by a marker `ws solve` stamps).
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-cicd"
# The install-time build of the clean image (gitops/workshop-config/values.yaml trustedImage.namespace);
# attendees hold view on it.
TRUSTED_NS="ogsr-supply-chain"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# gitea_host() (route if readable, else derived from the cluster ingress domain — the attendee-safe
# pattern; attendees can't read the gitea route) is shared — tools/verify/_lib.sh. GLOBAL, not
# echo-shaped: call it bare and read $GITEA_HOST, never `$(gitea_host)`.

# A Gitea repo/branch exists → the (public) API answers 2xx anonymously.
gitea_repo_exists() {
  local owner="$1" repo="$2"
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${owner}/${repo}"
}
gitea_branch_exists() {
  local owner="$1" repo="$2" branch="$3"
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${owner}/${repo}/branches/${branch}"
}
# A raw file on a branch contains a needle (the seeded flaw).
gitea_raw_contains() {
  local owner="$1" repo="$2" path="$3" ref="$4" needle="$5"
  gitea_host || return 1
  curl -ksf "https://${GITEA_HOST}/api/v1/repos/${owner}/${repo}/raw/${path}?ref=${ref}" 2>/dev/null | grep -q "$needle"
}

# Tekton Chains signed at least one TaskRun in this namespace (signature attached).
# oc_read, not `2>/dev/null | grep -q`: a silenced read hands grep an empty stream whether the
# namespace holds no signed TaskRun (a real ❌) or the API never answered (⚠) — and this check is
# asserted in BOTH modes, so a blip would tell an attendee the install-time build was never signed.
# Read in THIS shell, never `$(…)`: VERIFY_INCONCLUSIVE raised in a subshell never reaches check().
signed_taskrun_exists() {
  oc_read get taskruns.tekton.dev -n "$1" -o jsonpath='{range .items[*]}{.metadata.annotations.chains\.tekton\.dev/signed}{"\n"}{end}' || return 1
  grep -q 'true' <<<"$OC_OUT"
}
# A parasol-claims-supply-chain PipelineRun reached overall Succeeded. Tekton labels every run from a
# pipelineRef with tekton.dev/pipeline=<name>, so in ${TRUSTED_NS} this catches the install-time build.
# Overall Succeeded is the definitive clean-gate signal: the ACS gate ("Block Log4Shell at build", CVSS 10)
# fails the WHOLE run on a vulnerable source even though build-image + Chains-signing still complete — so a
# proxy like "image built" or "a signed TaskRun exists" greenlights a run that never passed the gate. The
# install builds the CLEAN main branch once in ${TRUSTED_NS}, so this passes from entry state onward.
# oc_read, not `2>/dev/null`: an empty answer from a silenced read cannot be told apart from an API that
# never answered, and this check is asserted in BOTH modes — a false ❌ here tells an attendee the install-time
# build failed when the cluster merely blipped. rc 0 with an empty OC_OUT is still a real ❌.
supply_chain_run_succeeded() {
  oc_read get pipelineruns.tekton.dev -n "$1" -l tekton.dev/pipeline=parasol-claims-supply-chain \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' || return 1
  grep -qx True <<<"$OC_OUT"
}
# The pre-scanned trust artifact is present: the parasol-claims-trusted ImageStream carries :latest PLUS the
# two Chains-emitted tags derived from its digest — sha256-<digest>.sig (signature) and .att (SLSA
# attestation). Its own repository, not parasol-claims: the install's ClusterImagePolicy scopes exactly
# this one (entry-state trusted-image-copy.yaml says why). This is what the trust lab's cosign verify /
# verify-attestation / admission beats read; the prep copy hook produces it at prep and a completed lab
# leaves it intact (the attendee's red beat builds parasol-claims:candidate, a different repository).
# Same three-outcome treatment, and for the same reason: `tags="$(oc … 2>/dev/null || true)"` makes an
# ImageStream that could not be read indistinguishable from one carrying no signed tags.
signed_latest_image_present() {
  oc_read get imagestream parasol-claims-trusted -n "$1" -o jsonpath='{range .status.tags[*]}{.tag}{"\n"}{end}' || return 1
  grep -qx 'latest' <<<"$OC_OUT" && grep -q '\.sig$' <<<"$OC_OUT" && grep -q '\.att$' <<<"$OC_OUT"
}

# --- what the ATTENDEE leaves behind (full mode only) ------------------------
#
# Exercise 1 is the lab's ONLY cluster-mutating beat, and it is the one worth grading: the attendee
# starts the supply-chain Pipeline on their fork's SEEDED branch, to a throwaway :candidate tag, and
# watches the RHACS gate refuse it AFTER build-image already produced the image. Everything it leaves
# is inside {user}-cicd and is purged by `ws reset`/`ws prep`, so it cannot survive as stale evidence —
# measured, not assumed: `ws prep trusted-supply-chain --user user6 --yes` (2026-08-05) removed BOTH the
# seeded PipelineRun and the whole parasol-claims ImageStream, taking :candidate and its signature pair
# with it. That matters, because a check whose evidence outlives the reset is a false ✅ waiting to fire.
# KNOWN LIMIT, not engineered around: the Pipelines pruner (TektonConfig, daily) eventually reaps old
# PipelineRuns/TaskRuns, after which the run-based checks below go red while the :candidate image they
# built lives on. Within a workshop day — the only window in which "did this attendee do the lab?" is
# a live question, since `ws prep` resets the world before each run — it cannot fire.
#
# Exercises 2–4 (cosign verify · verify-attestation · keyless sign-blob + Rekor) are deliberately
# READ-ONLY against the cluster — that is the module's design, not an oversight — so their only trace
# is in the attendee's own terminal home directory. They are graded there when this script IS that
# terminal and skipped with a ⚠ when it is not; see attendee_shell() below.
# Exercise 5 (admission) leaves two pods in {user}-cicd, graded below: claims-signed (the trusted image,
# admitted) and claims-unsigned (an unsigned image in the guarded repository, refused at pull). The
# policy itself is install state, asserted in both modes; `ws prep` purges the pods with the rest.

# Every PipelineRun of this Pipeline built from the SEEDED branch, as "<name>|<revision>|<Succeeded>".
# One read, reused by three predicates — the seeded runs are the spine of the whole end state.
SEED_RUNS=""
seed_runs_read() {  # → 0 the API ANSWERED (SEED_RUNS may be legitimately empty), 1 could not ask
  oc_read get pipelineruns.tekton.dev -n "$1" -l tekton.dev/pipeline=parasol-claims-supply-chain \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.params[?(@.name=="git-revision")].value}{"|"}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' || return 1
  # BOTH shapes are the seeded branch: the lab's manifest passes `git-revision: seed-vulnerable`
  # explicitly, but the Pipeline's own DEFAULT for that param is also seed-vulnerable, so a run created
  # without it (a console Start form, a hand-trimmed manifest) renders as an EMPTY field here. Matching
  # only the literal would tell such an attendee they never built the seeded branch. `main` — the warm
  # prep run — matches neither, which is the point: the warm run must never satisfy an end check.
  SEED_RUNS="$(grep -E '^[^|]+\|(seed-vulnerable)?\|' <<<"$OC_OUT" || true)"
  return 0
}
# Still running: Tekton reports Unknown while a run is in flight, and a just-created run has no
# condition at all (empty field). Either way the gate has NOT answered yet — a ⚠, never a ❌, because
# this build takes 6–12 minutes and an attendee who runs `ws verify` while watching the logs did
# nothing wrong.
seed_run_inflight() { grep -qE '\|(Unknown)?$' <<<"$SEED_RUNS"; }
# The gate REFUSED one of those runs. Keyed on the acs-scan TaskRun's own condition, not the
# PipelineRun's: a run can go red for reasons that are not the lesson (a killed build step, an evicted
# pod), and "the scan turned it red" is the outcome the lab's checkpoint actually claims.
seed_run_refused_by_gate() {
  oc_read get taskruns.tekton.dev -n "$1" -l tekton.dev/pipelineTask=acs-scan \
    -o jsonpath='{range .items[*]}{.metadata.labels.tekton\.dev/pipelineRun}{"|"}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' || return 1
  local line run
  while IFS= read -r line; do
    run="${line%%|*}"
    [[ -n "$run" ]] || continue
    if grep -qxF "${run}|False" <<<"$OC_OUT"; then return 0; fi
  done <<<"$SEED_RUNS"
  return 1
}
# The refused image itself reached the registry: exercise 1's whole point is that build-image SUCCEEDED
# and the scan is what stopped it, so :candidate exists beside the trusted :latest.
candidate_image_present() {
  oc_read get imagestream parasol-claims -n "$1" -o jsonpath='{range .status.tags[*]}{.tag}{"\n"}{end}' || return 1
  grep -qx 'candidate' <<<"$OC_OUT"
}
# …and Chains signed it too — the .sig/.att pair beside :candidate that exercise 3 has the attendee read
# ("Chains signs EVERY build, including the failed one — who-built-it is not is-it-clean"). The trusted
# image's pair lives in parasol-claims-trusted, so ANY pair here is the attendee's own build's.
# >=1, never ==1: the Challenge has the attendee rebuild :candidate, and any extra build adds a pair.
candidate_signed() {
  oc_read get imagestream parasol-claims -n "$1" -o jsonpath='{range .status.tags[*]}{.tag}{"\n"}{end}' || return 1
  local sigs atts
  # `|| true` on both: grep -c PRINTS 0 and EXITS 1 when nothing matches, and a failing command
  # substitution inside an assignment kills the script outright under the callers' `set -e`.
  sigs="$(grep -c '\.sig$' <<<"$OC_OUT" || true)"
  atts="$(grep -c '\.att$' <<<"$OC_OUT" || true)"
  # if/then, not a bare `(( … ))`: a false arithmetic expression returns 1, and as a function's LAST
  # statement that makes the function return 1 — fatal under `set -e` the day someone calls this bare.
  if (( sigs >= 1 && atts >= 1 )); then return 0; fi
  return 1
}
# All three facts exercise 1 leaves behind, together — the "is the outcome already there?" question the
# end-state block asks BEFORE deciding whether an in-flight run should defer the verdict. Deliberately
# NOT the thing that prints the ✅s: each fact is graded separately below so a failure names itself.
seed_outcome_complete() {
  seed_run_refused_by_gate "$1" || return 1
  candidate_image_present "$1" || return 1
  candidate_signed "$1" || return 1
}
# The install's signature policy guards THIS attendee's trusted repository. Exact line match on the scope:
# a prefix match would let user1's check pass on user10's scope.
policy_scopes_my_repo() {
  oc_read get clusterimagepolicy ogsr-signed-parasol-claims -o jsonpath='{range .spec.scopes[*]}{@}{"\n"}{end}' || return 1
  grep -qxF "image-registry.openshift-image-registry.svc:5000/${1}/parasol-claims-trusted" <<<"$OC_OUT"
}
# Exercise 5's pods, one read each: "<ready>|<waiting reason>|<waiting message>|<image>". Both must run
# an image from the GUARDED repository — a pod named claims-signed running some other image proves
# nothing about the policy. Read in THIS shell (OC_OUT), never `$(…)`, for the same reason as above.
admission_pod_read() {
  oc_read get pod "$2" -n "$1" -o jsonpath='{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"|"}{.status.containerStatuses[0].state.waiting.message}{"|"}{.spec.containers[0].image}' || return 1
  local repo="image-registry.openshift-image-registry.svc:5000/${1}/parasol-claims-trusted"
  [[ "${OC_OUT##*|}" == "${repo}:"* || "${OC_OUT##*|}" == "${repo}@"* ]]
}
# The signed image was admitted: its node verified the signature and the container is ready.
admission_signed_ran() {
  admission_pod_read "$1" claims-signed || return 1
  [[ "${OC_OUT%%|*}" == "true" ]]
}
# The unsigned image was refused BY THE POLICY: kubelet reports SignatureValidationFailed, as the reason
# while the pull fails and inside the message while it backs off (measured as user11, 2026-11-12:
# "Back-off pulling image …: SignatureValidationFailed: … A signature was required, but no signature
# exists"). Any other refusal — a typo'd tag, an unreachable registry — is not this lesson.
admission_unsigned_refused() {
  admission_pod_read "$1" claims-unsigned || return 1
  [[ "${OC_OUT%%|*}" != "true" ]] && grep -q 'SignatureValidationFailed' <<<"$OC_OUT"
}
# Is THIS shell the attendee's own terminal? Exercises 2–4 write only to their home directory, so the
# answer decides between grading them (❌ is meaningful: the files would be there) and skipping them
# with a ⚠ (an instructor/CI run from a laptop has no business grading someone else's home dir — that
# would be a false ❌ on a perfectly completed lab). oc_read_OPTIONAL: an unreadable identity must not
# raise the shared flag here, because we classify this ourselves — and it must fall to the ⚠ side.
attendee_shell() {
  oc_read_optional whoami || return 1
  [[ "$OC_OUT" == "$USER_NAME" ]]
}
# The keyless beat's receipt. cosign writes the Rekor log entry into the bundle beside the signature,
# so the bundle existing AND carrying a log entry is proof the transparency-log upload happened —
# checked without a network round-trip, and without needing the entry UUID the attendee saw.
# ${HOME:-} everywhere, never a bare ${HOME}: these scripts run under `set -u`, where an unset HOME
# (a bare container exec, a cron-ish context) is an abort rather than a check.
keyless_bundle_recorded() {
  [[ -n "${HOME:-}" && -s "${HOME}/sbom.bundle" ]] || return 1
  # Both bundle shapes carry the transparency-log receipt under a different key — cosign's legacy
  # bundle nests rekorBundle.Payload.logIndex, the Sigstore protobuf bundle uses tlogEntries.
  grep -qE 'logIndex|rekorBundle|tlogEntries' "${HOME}/sbom.bundle"
}

# --- entry state that SURVIVES lab completion (checked in BOTH modes) --------
check "namespace ${NS} exists"                             oc get ns "$NS"                                     || hint "run: ws prep trusted-supply-chain (or ws start trusted-supply-chain --user ${USER_NAME})"
check "entry marker ws-entry-trusted-supply-chain present"                  oc get cm ws-entry-trusted-supply-chain -n "$NS"                     || hint "entry app not synced — ws prep trusted-supply-chain (or ws start trusted-supply-chain --user ${USER_NAME})"
check "Pipeline parasol-claims-supply-chain present"       oc get pipelines.tekton.dev parasol-claims-supply-chain -n "$NS" || hint "entry app not synced — ws prep trusted-supply-chain (or ws start trusted-supply-chain --user ${USER_NAME})"
check "rox-api-token copied into ${NS} (scan-gate secret)" oc get secret rox-api-token -n "$NS"                || hint "the secrets hook copies it from stackrox — ws reset trusted-supply-chain --user ${USER_NAME} (needs the trust stack)"
check "chains-cosign-pub copied into ${NS} (verify key)"   oc get cm chains-cosign-pub -n "$NS"                || hint "the secrets hook copies it from openshift-pipelines — needs the trust-signing component"
check "Gitea fork ${USER_NAME}/parasol-claims answers"     gitea_repo_exists "$USER_NAME" parasol-claims       || hint "fork missing — re-run: ws prep trusted-supply-chain (or ws start trusted-supply-chain --user ${USER_NAME}) (fork job)"
check "fork branch seed-vulnerable exists"                 gitea_branch_exists "$USER_NAME" parasol-claims seed-vulnerable || hint "re-run the fork/seed job: ws reset trusted-supply-chain --user ${USER_NAME}"
check "curated library task acs-image-check reachable"     oc get tasks.tekton.dev acs-image-check -n ogsr-parasol-tasks        || hint "parasol-tasks library missing — sync the workshop-config Argo app"
# --- the pre-scanned trust artifact (built once at install, copied in at prep; survives the lab) ---------
check "install-time supply-chain run PASSED the scan gate (${TRUSTED_NS})" supply_chain_run_succeeded "$TRUSTED_NS" || hint "the install builds the CLEAN main branch once in ${TRUSTED_NS}; if this is red that build is still running or failed — watch: tkn pipelinerun logs --last -n ${TRUSTED_NS} (instructor: re-sync the workshop-config app to retry it)"
check "Tekton Chains signed that build (signed TaskRun present)"   signed_taskrun_exists "$TRUSTED_NS"       || hint "Chains signs a few seconds after the build TaskRun completes — re-check in a moment"
check "pre-scanned signed image parasol-claims-trusted:latest (+ .sig/.att)" signed_latest_image_present "$NS"         || hint "the signed image was not copied into ${NS} — re-materialize: ws prep trusted-supply-chain --user ${USER_NAME} --yes (copies it from ${TRUSTED_NS} in seconds)"
check "cluster signature policy ogsr-signed-parasol-claims guards ${NS}/parasol-claims-trusted" policy_scopes_my_repo "$NS" || hint "the install applies this ClusterImagePolicy (workshop-config trusted-image-policy) with one scope per attendee — tell your instructor; they re-sync workshop-config (adding attendees re-renders the scopes)"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: the seeded flaw is asserted ONLY here. The trusted-supply-chain lab's optional SBOM-fix beat
  # REMOVES log4j-core from the fork, so in FULL mode this would false-FAIL an attendee who did that beat
  # (template rule 14) — it validates ENTRY materialization, not lab completion. Same mode-split as
  # gitops-fundamentals. Needle is the literal injected XML tag, NOT the bare word "log4j-core": the base
  # pom.xml's own SBOM-plugin comment mentions "log4j-core" in prose, and that comment forks onto
  # seed-vulnerable from main too — a bare-word needle here made this check a false-positive rubber stamp.
  check "seed-vulnerable carries the seeded log4j CVE"     gitea_raw_contains "$USER_NAME" parasol-claims pom.xml seed-vulnerable "<artifactId>log4j-core</artifactId>" || hint "re-run the fork/seed job: ws reset trusted-supply-chain --user ${USER_NAME}"
else
  # ── END STATE: what a COMPLETED lab looks like ────────────────────────────────────────────────
  if [[ "$SOLVE_MODE" == "true" ]]; then
    # `ws solve trusted-supply-chain` is NOT a machine-completed lab, and this is a property of the
    # chart, not of this script: values.yaml says so out loud — "solve is kept for ws-solve
    # compatibility (it still lands on the same warm end state); it no longer toggles a distinct
    # hook" — and the module has no solve-only template. The demo flavor depends on that: its
    # presenter arc STARTS the seeded build live in front of the room (demo beat 2), so a solve that
    # pre-built :candidate would spoil the one moment the demo exists for.
    # ➖ and not ⚠: this is not "unknown, ask elsewhere", it is known, correct, and unanswerable
    # anywhere — nothing produced this state, so there is nothing to grade. The banner stays green
    # and honest, and the line below is why. (If `ws solve` ever gains a hook that runs the seeded
    # build, delete this branch and let the checks below run — they already grade exactly that.)
    na "the attendee-side beats (the seeded :candidate build, the SBOM, the keyless Rekor receipt, the two admission pods) — \`ws solve\` for this module materializes the copied signed-image end state and deliberately nothing else, so they are correctly absent here"
  else
    # Exercise 1 — the seeded build. One read, then three verdicts off it, because "you never started
    # it" (❌), "it is still building" (⚠) and "the gate answered" (graded) are three different things.
    if ! seed_runs_read "$NS"; then
      warn "could not check: exercise 1's seeded build — the cluster API did not answer (${OC_ERR:0:120})"
      hint "not your lab, and not graded: re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor"
    else
      check "exercise 1: you built the seeded branch yourself (a seed-vulnerable PipelineRun)" test -n "$SEED_RUNS" \
        || hint "exercise 1: create the PipelineRun from the lab's manifest (git-revision: seed-vulnerable → parasol-claims:candidate) — the install-time build of main does not count"
      if [[ -n "$SEED_RUNS" ]]; then
        # GRADE OPTIMISTICALLY, DEFER PESSIMISM WHILE A BUILD IS RUNNING. All three facts below are
        # produced by the SAME run, minutes apart — build-image pushes :candidate, Chains signs it
        # seconds later, acs-scan refuses it minutes after that. Grading them independently red-flagged
        # an attendee who had done everything right and simply ran `ws verify` while the logs were
        # still streaming (measured on user6 two minutes into a real seeded build, 2026-08-05: the gate
        # correctly ⚠'d and the two image checks ❌'d underneath it). So: if the whole outcome is
        # already there, grade it — a completed lab is green even with an extra build in flight; if it
        # is not there AND a run is still in flight, the honest answer is ⚠ for all three at once.
        if seed_outcome_complete "$NS" || ! seed_run_inflight; then
          check "exercise 1: the scan gate REFUSED that build (its acs-scan step Failed)" seed_run_refused_by_gate "$NS" \
            || hint "the seeded build concluded without the gate failing it. If you did the optional SBOM-fix beat and rebuilt, the gate now legitimately passes — re-seed with: ws reset trusted-supply-chain --user ${USER_NAME}. Otherwise read the run: tkn pipelinerun logs --last -n ${NS}"
          check "exercise 1: the refused image reached your registry as parasol-claims:candidate" candidate_image_present "$NS" \
            || hint "build-image must succeed before acs-scan can refuse it — if your run died earlier than the scan, start it again from the lab's manifest (it raises per-Task memory; a run started from the console's Start form is killed mid-build)"
          check "exercise 3: Chains signed the refused build too (a .sig/.att pair beside :candidate)" candidate_signed "$NS" \
            || hint "Chains signs a few seconds after each build TaskRun completes — re-check: oc get imagestream parasol-claims -n ${NS} -o jsonpath='{range .status.tags[*]}{.tag}{\"\\n\"}{end}'"
        else
          # 6–12 minutes, longer on a cold node. An attendee who verifies while the logs stream is not
          # wrong, and the gate has genuinely not answered yet — ⚠ is the honest verdict, and one line
          # rather than three because it is one unfinished build, not three separate unknowns.
          warn "could not check: your seeded build's outcome (the gate's verdict · the :candidate image · its Chains signature) — a run is still in flight, so none of the three exists yet"
          hint "not graded yet: watch it finish (tkn pipelinerun logs --last -f -n ${NS}) — it takes 6–12 minutes — then re-run ws verify trusted-supply-chain --user ${USER_NAME}"
        fi
      fi
    fi

    # Exercise 5 — admission. Two pods, graded separately so a failure names itself.
    check "exercise 5: the node admitted your signed image (pod claims-signed is Running)" admission_signed_ran "$NS" \
      || hint "exercise 5: oc run claims-signed -n ${NS} --image=image-registry.openshift-image-registry.svc:5000/${NS}/parasol-claims-trusted:latest --image-pull-policy=Always --command -- sleep infinity"
    check "exercise 5: the node refused your unsigned image (claims-unsigned: SignatureValidationFailed)" admission_unsigned_refused "$NS" \
      || hint "exercise 5: tag ubi-minimal as parasol-claims-trusted:unsigned, then oc run claims-unsigned from it with --image-pull-policy=Always. If it is Running, the policy did not apply — check: oc get clusterimagepolicy ogsr-signed-parasol-claims"

    # Exercises 2–4 leave nothing on the cluster BY DESIGN (cosign verify / verify-attestation read the
    # registry; sign-blob writes to Rekor and to a local bundle). Graded only from the attendee's own
    # terminal — see attendee_shell(). KNOWN LIMIT, stated rather than hidden: a home directory
    # survives `ws prep`, so an attendee who completed the lab and then re-warmed their namespace keeps
    # these two ✅ while the cluster-side checks above correctly go ❌. The banner is still not green,
    # which is what matters; grading file age instead would need creationTimestamp parsed portably
    # across BSD and GNU date, a second failure mode bought for very little (see _lib.sh deploy_ready).
    if attendee_shell; then
      check "exercise 1: you generated the CycloneDX SBOM by hand (target/parasol-claims-sbom.json)" test -s "${HOME:-}/parasol-claims/target/parasol-claims-sbom.json" \
        || hint "exercise 1: clone your fork's seed-vulnerable branch to ~/parasol-claims and run the cyclonedx makeBom command"
      check "exercise 4: your SBOM is signed keylessly and Rekor holds the receipt (~/sbom.bundle)" keyless_bundle_recorded \
        || hint "exercise 4: cosign initialize --mirror=\$TUF, mint the token, then cosign sign-blob -y --identity-token=\"\$TOKEN\" --bundle ~/sbom.bundle target/parasol-claims-sbom.json"
    else
      # ⚠, never ❌: exercises 2–4 mutate nothing, so from anywhere but the attendee's own shell there
      # is no evidence to read — and grading absent evidence would fail a lab that was done perfectly.
      warn "could not check: exercises 2–4 (cosign verify · SLSA attestation · keyless signing + Rekor) — they change nothing on the cluster by design, and their only trace is in ${USER_NAME}'s own terminal home directory, which this shell is not"
      hint "not graded here: run 'ws verify trusted-supply-chain --user ${USER_NAME}' from ${USER_NAME}'s own Showroom terminal, where ~/parasol-claims/target/parasol-claims-sbom.json and ~/sbom.bundle live"
    fi
  fi
fi

verify_summary
