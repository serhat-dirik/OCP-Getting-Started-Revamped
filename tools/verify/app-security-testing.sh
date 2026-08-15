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
#   End:   ONE parasol-claims-devsecops PipelineRun that BOTH reached Succeeded AND reports all six
#          Pipeline-level gate results (sast / sca / image-scan / config-check / dast / perf) as
#          "true". The run's overall status ALONE is not evidence of a completed lab — this module's
#          report-mode run succeeds with every finding still open (see devsecops_gates_all_green) —
#          AND the deploy stage created the parasol-claims edge Route (the browser-reachable app is
#          the visible outcome).
# End checks are outcome-based (satisfied by an attendee's real capstone run AND by `ws solve`).
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-cicd"

# ── the capstone verdict: ONE Succeeded run whose SIX gate results are ALL true ───────────────────
#
# "A PIPELINERUN SUCCEEDED" IS NOT "THE ATTENDEE FIXED ANYTHING", and this module's three-run shape
# makes that gap load-bearing rather than theoretical. Run 2 is a REPORT-MODE run: every gate
# executes and none of them BLOCKS, so the pipeline reaches Succeeded with every finding still
# unfixed. The check that stood here graded exactly one bit — `.status.conditions[Succeeded]=="True"`
# on any run carrying the pipeline label — so it went green the moment that report run finished, over
# an attendee who had not yet touched a single finding. That is this module's own worst failure mode
# (a verify script passing over an incomplete state) shipped inside its own verify script. The old
# comment's premise, "Succeeded ⟺ EVERY gate passed", is exactly what report mode falsifies.
#
# WHAT DISCRIMINATES, AND WHY IT IS THE GATES' OWN ANSWER. The Pipeline declares six results, one per
# gate, each wired to that gate task's boolean verdict:
#     oc get pipelines.tekton.dev parasol-claims-devsecops -n {user}-cicd -o jsonpath='{.spec.results[*].name}'
#     → sast-passed sca-passed image-scan-passed config-check-passed dast-passed perf-passed
# Tekton persists them ON THE RUN at `.status.results[]` as {name,value} — the v1 CRD's own field
# (`oc explain pipelineruns.tekton.dev.status.results`; the v1beta1 spelling `status.pipelineResults`
# does not exist on this cluster, so do not reach for it). That is what makes them a discriminator a
# report run cannot satisfy: the value is the GATE's verdict, not the run's exit status and not the
# enforcement setting, so it stays "false" however permissively the run was parameterized.
#
# MEASURED, NOT REASONED — twelve real archived runs of this exact Pipeline, read out of Tekton
# Results on cluster-m24jn 2026-08-16 (the runs themselves had been purged by `ws reset`; the archive
# kept their status):
#   Succeeded=True     gauntlet-green1-cqrx8, gauntlet-green2-rtvf2, gauntlet-nxfl4, p1-baseline-vbjkl,
#                      p1-after-b-q6jdz, p1-after-c-4fpt5, solve-devsecops-cr8jk
#                        → SIX results, every one "true"  (7 of 7, no exceptions)
#   Succeeded=False    p1-red-5fc4h, gauntlet-red1-g4q98, gauntlet-wmc77 → ONE result, sast-passed=false
#                      gauntlet-75chx                                    → TWO results, both true
#   Succeeded=Unknown  solve-devsecops-gvzcz (still Running)             → ZERO results
# solve-devsecops-cr8jk is a real `ws solve` end state, so this file's standing contract — end checks
# are satisfied by an attendee's own run AND by `ws solve` — is exercised here, not assumed.
#
# TWO LESSONS FROM THAT TABLE, both encoded below:
#   • A RESULT WHOSE TASK NEVER COMPLETED IS OMITTED, NOT "false" — the failed runs declare six
#     results and carry one or two. So ABSENCE MUST FAIL. A predicate phrased as "no gate says false"
#     would pass on a run that produced no results at all: the same false ✅, pointed a new direction.
#   • THE SIX ARE REQUIRED BY NAME, NEVER BY COUNT. If a seventh gate is added later this check still
#     passes on a genuinely green run — the suite's `>=`-not-`==` rule, applied to a set.
#
# BOTH HALVES MUST BE THE SAME RUN. "Some run Succeeded" AND "some run is all-green", evaluated
# separately, is satisfiable by a report run plus anything else — so the condition and the results are
# read per run, and only a single run carrying both counts.
#
# oc_read, never `2>/dev/null`: an empty answer from a silenced read is indistinguishable from an API
# that never answered, and this is the module's capstone verdict — a false ❌ here tells an attendee
# their fully-green pipeline failed. rc 0 with an empty OC_OUT stays a real ❌ (nothing has run);
# "could not ask" becomes ⚠ via VERIFY_INCONCLUSIVE, including when only SOME of the per-run reads
# fail: a run this suite could not read might have been the green one, so the run is inconclusive
# rather than red.
DEVSECOPS_GATE_DETAIL=""
devsecops_gates_all_green() {  # <namespace> <gate result name>… → 0 when ONE Succeeded run has every gate true
  local ns="$1"; shift
  local want=$# runs line name status results pairs rline rname rvalue gate red missing n best=-1 succeeded=0
  DEVSECOPS_GATE_DETAIL=""
  (( want > 0 )) || return 1   # a caller that names no gates would assert nothing
  oc_read get pipelineruns.tekton.dev -n "$ns" -l tekton.dev/pipeline=parasol-claims-devsecops \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' || return 1
  runs="$OC_OUT"
  if [[ -z "$runs" ]]; then
    DEVSECOPS_GATE_DETAIL="no PipelineRun of this capstone exists in ${ns} yet"
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%|*}"
    status="${line#*|}"
    # Only True is read further. False is a red run and Unknown is one still going — and a running run
    # legitimately carries no results yet (measured: solve-devsecops-gvzcz, zero results), so reading
    # its results would manufacture a "gates missing" diagnosis for a run that is simply not finished.
    if [[ "$status" != "True" ]]; then continue; fi
    succeeded=1
    # `continue`, NOT `return 1`: a per-run read that could not be asked must not mask a SIBLING run
    # that is green. oc_read has already raised VERIFY_INCONCLUSIVE and nothing here ever lowers it,
    # so if no green run is found afterwards the whole check still renders ⚠ (never ❌ — a run this
    # suite could not read might have been the completed one); but if a later run IS green we return
    # 0 and check() prints ✅, because the flag is only consulted on the failure path.
    if ! oc_read get pipelineruns.tekton.dev "$name" -n "$ns" \
      -o jsonpath='{range .status.results[*]}{.name}{"="}{.value}{"\n"}{end}'; then continue; fi
    results="$OC_OUT"
    # `|name=value|…` rather than an associative array: bash 3.2 (macOS, where maintainers run this)
    # has none. Result names are DNS-1123 labels and the values are the strings "true"/"false", so
    # neither can carry `|` or `=` and the membership tests below cannot alias.
    pairs="|"
    while IFS= read -r rline; do
      [[ -n "$rline" ]] || continue
      case "$rline" in *=*) ;; *) continue;; esac
      rname="${rline%%=*}"
      rvalue="${rline#*=}"
      # Trimmed, though all twelve measured runs wrote clean values: a gate task that ever emits its
      # result with `echo` instead of `echo -n` would otherwise read as red on a genuinely green run.
      # Trimming cannot manufacture a pass — whitespace off "false" is still "false".
      rvalue="${rvalue#"${rvalue%%[![:space:]]*}"}"
      rvalue="${rvalue%"${rvalue##*[![:space:]]}"}"
      # Case-folded for the SAME reason, and only for the two boolean spellings: all twelve measured
      # runs wrote lowercase, and the curated tasks' declared contract is "true"/"false", but a task
      # edited to emit "True" would otherwise turn a green capstone red — a false ❌ over a spelling.
      # Pure bash (no `tr` subprocess, no ${v,,} which bash 3.2 lacks), and it cannot manufacture a
      # pass: anything that is not a spelling of true/false is left untouched and still fails.
      case "$rvalue" in
        [Tt][Rr][Uu][Ee])     rvalue="true";;
        [Ff][Aa][Ll][Ss][Ee]) rvalue="false";;
      esac
      pairs="${pairs}${rname}=${rvalue}|"
    done <<<"$results"
    red=""; missing=""; n=0
    for gate in "$@"; do
      if [[ "$pairs" == *"|${gate}=true|"* ]]; then continue; fi
      n=$((n+1))
      # RED and MISSING are different problems with different next steps, so they are counted
      # together but reported apart: "the gate answered false" is the attendee's finding to fix,
      # "the gate never answered" means its task did not complete and is a pipeline/platform matter.
      if [[ "$pairs" == *"|${gate}="* ]]; then
        red="${red}${red:+, }${gate}"
      else
        missing="${missing}${missing:+, }${gate}"
      fi
    done
    if (( n == 0 )); then
      DEVSECOPS_GATE_DETAIL=""
      return 0
    fi
    # Report the CLOSEST run — fewest outstanding gates. In every realistic ordering that is the
    # attendee's latest attempt, and "two gates left, here they are" is a next step where "a run
    # failed" is not. Deliberately not "the newest run": creationTimestamp would be a third read per
    # run to order a list this check does not otherwise care about the order of.
    if (( best < 0 || n < best )); then
      best="$n"
      DEVSECOPS_GATE_DETAIL="run ${name} Succeeded but ${n} of ${want} gates are not green${red:+ — still RED: ${red}}${missing:+ — NEVER REPORTED (their task did not complete): ${missing}}"
    fi
  done <<<"$runs"
  if (( succeeded == 0 )); then
    DEVSECOPS_GATE_DETAIL="${ns} holds PipelineRun(s) of this capstone but none has Succeeded"
  fi
  return 1
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
# THE TWO ASSERTIONS MIRROR THE TWO END CHECKS — the capstone parasol-claims-devsecops PipelineRun,
# and the Route its deploy stage creates. Keep that one-for-one correspondence if either side changes:
# an entry check that negates a strict SUBSET of what the end check accepts leaves a world that is
# COMPLETE in full mode and A CLEAN SLATE in entry mode simultaneously, and prep then either skips the
# setup or offers to wipe a world it has just called finished.
#
# THE END CHECK GOT STRICTER AND THIS SIDE IS UNCHANGED, deliberately. It now requires all six gate
# verdicts green, not merely a Succeeded run, and that strengthening moves the two apart in the SAFE
# direction because this side is EXISTENCE-based: clean slate ⟹ no run at all ⟹ the end check cannot
# pass; the end check passes ⟹ a run exists ⟹ not a clean slate. The pair still cannot both be true.
# What WIDENED is the band between them, and that is the point — a namespace holding this module's own
# report-mode run is now neither complete nor clean, so `ws prep` purges it AND `ws verify` refuses to
# call it done. Under the old end check that same namespace was "complete", which is the defect.
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
# THE PIPELINE EXISTING IS NOT THE PIPELINE RUNNING. A 2026-08-07 regression gave `sast-sonar` AND
# `unit-test` a second PVC-backed workspace; under the operator's default Affinity Assistant mode
# every run of this capstone then died at its first Maven task in seconds with
# `TaskRunValidationFailed` / "[User error] more than one PersistentVolumeClaim is bound", while this
# script stayed fully green — it graded the Pipeline object and the cache CLAIM, both present. See
# pipeline_pvc_workspaces_ok in _lib.sh for the mechanism and the measurement.
#
# ONLY shared-workspace AND maven-cache ARE NAMED, and the omission is the interesting part: this
# Pipeline also declares `zap-work` and `k6-work`, which look identical at the Pipeline level and are
# bound `emptyDir: {}` by every runner in this repo (pipelines/pipelinerun/parasol-claims-devsecops-run.yaml
# and the solve hook). An emptyDir workspace is not a PVC and the assistant does not count it, so
# listing them here would be asserting something false about the run — and the day a task binds one
# of them ALONGSIDE the checkout (dast-zap and perf-k6 take only their own today, checked on the live
# object 2026-08-08) the check would fail a capstone that runs perfectly. Whether a workspace is
# PVC-backed is a property of the RUN, not of the Pipeline, so the caller is the one who can say.
# `maven-cache` stays named after its binding was retired, so this fires again if it comes back.
check "every task of the capstone is admissible (at most one PVC-backed workspace per TaskRun)" \
  pipeline_pvc_workspaces_ok parasol-claims-devsecops "$NS" shared-workspace maven-cache \
  || hint "task '${PIPELINE_PVC_CONFLICT:-?}' binds two PVC-backed workspaces, and this cluster's Affinity Assistant (\`oc get tektonconfigs.operator.tekton.dev config -o jsonpath='{.spec.pipeline.coschedule}'\` → workspaces, the operator default) allows one. The capstone will fail that stage in seconds with 'more than one PersistentVolumeClaim is bound' — before any step starts, so there are no logs and it reads as a broken gate rather than a broken Pipeline. This is a defect in the shipped Pipeline, not a gate you can fix by changing code: report it"
# The maven-cache PVC check that stood here was removed 2026-08-08 with the claim it graded — see
# the equivalent note in tools/verify/pipelines-fundamentals.sh. It asserted the cache CLAIM existed,
# which was true, while the workspace binding that claim was created for was what made every run of
# this capstone fail validation. The admissibility check above is its replacement.
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
  # THE SIX GATE NAMES LIVE AT THE CALL SITE, not inside the predicate — the same convention
  # pipeline_pvc_workspaces_ok follows two screens up, and for the same reason: the contract being
  # asserted should be readable next to the sentence that describes it, and the predicate stays a
  # generic "one Succeeded run reports every named result true". They are the Pipeline's own
  # spec.results names; if that list changes, this line is what has to change with it.
  # The hint leads with DEVSECOPS_GATE_DETAIL because only the predicate knows WHICH of the three
  # states this is (nothing has run · runs exist but none Succeeded · a run Succeeded with gates still
  # red or unreported), and an attendee mid-lab needs the gate names, not a bare ❌.
  check "capstone run drove EVERY gate green (one Succeeded run, all six gate results true)" \
    devsecops_gates_all_green "$NS" sast-passed sca-passed image-scan-passed config-check-passed dast-passed perf-passed \
    || hint "${DEVSECOPS_GATE_DETAIL:-no verdict could be read}. Not done yet? Before you start, this red is EXPECTED — driving the secured pipeline until every gate is green IS the lab (or: ws solve app-security-testing --user ${USER_NAME} runs the clean main end to end). NOTE a run that merely SUCCEEDS is not the finish line: the report-mode run succeeds with findings still open, which is why this grades the six gate verdicts and not the run's overall status. Read your own runs' verdicts with: oc get pipelineruns.tekton.dev -n ${NS} -l tekton.dev/pipeline=parasol-claims-devsecops -o jsonpath='{range .items[*]}{.metadata.name}{\": \"}{range .status.results[*]}{.name}{\"=\"}{.value}{\" \"}{end}{\"\\n\"}{end}' — a gate MISSING from that line never produced a verdict at all (its task did not complete), which is a different problem from a gate that answered false: fix the false ones, report the missing ones"
  check "deploy stage created the parasol-claims Route"     oc get route parasol-claims -n "$NS"                   || hint "not done yet — the deploy stage creates this Route ('oc create route edge parasol-claims') and it appears only after a Succeeded run, so it is expected to be missing until you run the pipeline"
fi

verify_summary
