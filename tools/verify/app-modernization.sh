#!/usr/bin/env bash
# Verify app-modernization — Application Modernization (MTA + AI).
#   Entry: {user}-modernize holds the entry marker + MaaS config, and the attendee has a Gitea fork
#          {user}/parasol-legacy-claims (the legacy Spring-on-Tomcat migration target MTA analyzes).
#          Nothing is deployed yet — the attendee assesses/analyzes/refactors/deploys by hand. The
#          shared MTA Hub (openshift-mta) is a platform-stack concern; {user}-modernize is workshop-layer.
#   End:   the MODERNIZED claims service (parasol-claims-modernized) is deployed to {user}-modernize —
#          the outcome of "fix issues → containerize → deploy to OpenShift".
# Runnable as the ATTENDEE: reads only {user}-modernize objects (namespace admin) + the attendee's own
# public Gitea fork over HTTPS (the URL is recorded in the marker — no cross-namespace reads). The G1
# cockpit smoke runs `--entry-only` as {user}.
#
# ENTITLEMENT SPLIT ([OCP] core / [ADS] Lightspeed): the MaaS credential (Developer Lightspeed for MTA)
# is OPTIONAL — reported as INFO, never failed. On a cluster without the [ADS] entitlement the [OCP]
# assess/analyze/replatform flow is unaffected (graceful degradation), so verify stays green.
# READINESS NOTE: parasol-claims-modernized runs a parasol-images image (parasol-claims, built by
# workshop-config parasol-images-build.yaml); at end state its Deployment is asserted READY (not merely
# present) so a crash-loop is CAUGHT. Grounded live 2026-07-19: the modernized deploy currently
# CrashLoopBackOffs (exit 1) — the parasol-claims image needs a DB and the solve-endstate does NOT set
# QUARKUS_DATASOURCE_ACTIVE=false the way the ai-assisted-development seed does, so it is RED for BOTH
# `ws solve` AND a hand build until that crash-loop fix lands (being fixed separately). That RED is
# correct and desired — the old deploy_present FALSELY passed on the crash-looping pod. This diverges
# from the service-mesh-advanced-gateways/serverless present-not-ready tier on purpose.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-modernize"

# --- helpers (oc + curl only) ------------------------------------------------

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.
# WHY READINESS AND NOT MERE PRESENCE, for this module: the Ex6 crash-loop content bug must be caught —
# a deployed-but-crashlooping modernized service fails here, which is correct and desired until that
# content fix lands. `>=1` is lab-exceedable.

# The attendee's legacy-repo fork URL, as recorded in the entry marker (attendee-safe: no gitea route
# read cross-namespace — the URL was computed from the cluster domain at materialization).
# ALWAYS returns 0 and signals failure with an empty string, exactly like the `|| true` it replaces:
# its caller assigns it (`u="$(legacy_repo)"`) and under `set -e` an assignment whose command
# substitution exits non-zero kills the script outright.
legacy_repo() {
  oc_read get cm ws-entry-app-modernization -n "$NS" -o jsonpath='{.data.legacyRepo}' || OC_OUT=""
  printf '%s' "$OC_OUT"
}

# The legacy fork is reachable (public repo → anonymous HTTPS GET returns 200). Network-tolerant caller.
repo_reachable() {
  local u; u="$(legacy_repo)"
  [[ -n "$u" ]] || return 1
  curl -ksf --max-time 10 "$u" >/dev/null 2>&1
}

# [ADS] MaaS credential present (Developer Lightspeed wired) — reported as INFO, never failed.
maas_secret_present() { oc_present get secret maas-credentials -n "$NS" -o name; }

# Entry clean-slate: the modernized service is NOT deployed yet (attendee hasn't finished the lab).
# Namespace must actually exist first — otherwise this is vacuously true on a cluster where nothing
# materialized at all, which is not evidence of a clean entry state.
# `! oc get … >/dev/null 2>&1` is the same blind read as `2>/dev/null`, spelled so the lint ratchet's
# detector does not match it — and in the one direction that matters most: it certifies a clean slate
# from an API that never answered, and a wrongly-green entry check sends `ws prep` down its "already
# prepared" fast path without purging.
no_modernized() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent get deploy parasol-claims-modernized -n "$NS" -o name
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                     oc get ns "$NS"                    || hint "run: ws prep app-modernization (or ws start app-modernization --user ${USER_NAME}); ${NS} is workshop-layer (per-user-modernize)"
check "entry marker ws-entry-app-modernization present"          oc get cm ws-entry-app-modernization -n "$NS"    || hint "entry app not synced — ws reset app-modernization --user ${USER_NAME}"
check "MaaS config carries the resolved model (configmap maas-config)" cm_key_set "$NS" maas-config model || hint "the MaaS copy hook did not fill maas-config — ws reset app-modernization --user ${USER_NAME}"
check "legacy fork parasol-legacy-claims reachable in Gitea" repo_reachable           || hint "the fork {user}/parasol-legacy-claims is missing — check the gitea-fork Job (ws reset app-modernization --user ${USER_NAME}); needs parasol/parasol-legacy-claims seeded (workshop-config app-repo-seed)"

# INFO: [ADS] Developer Lightspeed for MTA wiring (optional — never fails the entry state).
# PRESENCE IS NOT PROOF: the entry hook validates the credential against the endpoint before staging
# it and records the verdict in maas-config (aiPathAvailable). Report the VERDICT, not the Secret's
# existence — reporting existence is what let a wrong-provider credential read as "wired" while every
# model call 401'd (the same defect that broke M23 on a live cluster, 2026-07-29).
# Read into a variable first: an unreadable ConfigMap leaves it empty and falls to the `*)` arm, which
# is what an unrecorded verdict already meant. Every arm here is INFO — no counter is touched either way.
ads_state=""
if oc_read get cm maas-config -n "$NS" -o jsonpath='{.data.aiPathAvailable}'; then ads_state="$OC_OUT"; fi
case "$ads_state" in
  true)
    info "[ADS] maas-credentials staged AND accepted by the model endpoint — Developer Lightspeed for MTA is wired (the lab exports GENAI_API_KEY/GENAI_MODEL/GENAI_ENDPOINT from ${NS} in the Dev Spaces workspace terminal; workspaces live in {user}-devspaces, so nothing automounts)" ;;
  unverified)
    info "[ADS] maas-credentials staged but UNPROVEN — the cluster could not reach the model endpoint when this namespace materialized; Developer Lightspeed may 401 (oc logs job/maas-copy-app-modernization-${USER_NAME} -n ${NS})" ;;
  false)
    # CHOICE vs MISTAKE: `no-maas-credential` means nobody configured a key (a supported install —
    # bootstrap/install.sh's no-credential path); anything else means a credential was FOUND and
    # refused. Both leave [ADS] off, but they must not read the same. Reason strings are the literal
    # ones written by gitops/entry-states/app-modernization/templates/maas-credentials.yaml.
    ads_reason=""
    if oc_read get cm maas-config -n "$NS" -o jsonpath='{.data.aiPathReason}'; then ads_reason="$OC_OUT"; fi
    if [[ "$ads_reason" == "no-maas-credential" ]]; then
      info "[ADS] Developer Lightspeed disabled — no MaaS credential reached this cluster (a supported, degraded install, not a fault of this module); the [OCP] MTA assess/analyze/replatform flow is unaffected"
    else
      info "[ADS] Developer Lightspeed disabled — the MaaS credential this cluster carries is not usable (${ads_reason:-reason unrecorded}); the [OCP] MTA assess/analyze/replatform flow is unaffected"
    fi ;;
  *)
    if maas_secret_present; then
      info "[ADS] maas-credentials present but UNVALIDATED (entry state predates the credential-validation hook) — re-materialize to get a verdict: ws reset app-modernization --user ${USER_NAME}"
    else
      info "[ADS] maas-credentials absent — Developer Lightspeed disabled (graceful degradation); the [OCP] MTA assess/analyze/replatform flow is unaffected"
    fi ;;
esac
# INFO: the shared MTA Hub is a platform-stack concern (openshift-mta), not per-user state.
# Informational; each value keeps its old default when the marker cannot be read. Resolved into
# variables rather than nested `$(…)` in the info string, so oc_read runs in this shell, not a subshell.
MTA_NS="openshift-mta"
if oc_read get cm ws-entry-app-modernization -n "$NS" -o jsonpath='{.data.mtaNamespace}'; then MTA_NS="$OC_OUT"; fi
MTA_TARGETS="cloud-readiness,openshift,containerization"
if oc_read get cm ws-entry-app-modernization -n "$NS" -o jsonpath='{.data.analysisTargets}'; then MTA_TARGETS="$OC_OUT"; fi
info "shared MTA Hub namespace: ${MTA_NS} (installed by the platform-portfolio mta stack; analysis targets ${MTA_TARGETS})"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — nothing modernized/deployed yet -------------------------------------
  check "no modernized service deployed yet (attendee builds it)" no_modernized || hint "parasol-claims-modernized exists; the lab already finished — ws reset app-modernization --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — the modernized service deployed to {user}-modernize -------------
  # The one line every end-state section in tools/verify/ now opens with, worded identically. An
  # attendee who runs `ws verify <module>` BEFORE doing the lab meets a wall of ❌ that is entirely
  # correct, and three of these scripts used to phrase that red as if the environment were broken —
  # which sends people to an instructor for nothing. Say up front what the red means, then let each
  # hint say which KIND of red it is.
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  # Assert the OUTCOME (a modernized claims service is deployed AND Ready), never exact wording, so any
  # correct solution stays green (rule 14). READY, not just present: a crash-looping modernized deploy
  # (see the READINESS NOTE — it currently does) fails HERE, which deploy_present missed. RED until the
  # crash-loop fix lands is correct and desired.
  # The hint DISCRIMINATES, because one red had two entirely different causes and the reader could not
  # tell them apart: the deployment being ABSENT (the attendee simply has not done the lab — expected,
  # not a fault) versus PRESENT-BUT-NOT-READY (something is actually broken, e.g. the known crash-loop).
  # Offering both hypotheses in one hint made the reader do the triage the script was able to do for
  # them — and no_modernized() was already sitting three functions up, used only in the entry branch.
  # Naming the wrong cause first is how a correct ❌ gets ignored.
  check "modernized service parasol-claims-modernized deployed + Ready" deploy_ready parasol-claims-modernized \
    || { if no_modernized; then
           hint "parasol-claims-modernized does not exist — the lab has not been done yet. That is the expected state on a fresh entry, not a fault (ws solve app-modernization --user ${USER_NAME} materializes it)"
         else
           hint "parasol-claims-modernized EXISTS but is not Ready — this one is broken, not undone. If it CrashLoops it needs QUARKUS_DATASOURCE_ACTIVE=false (DB-free); check: oc logs deploy/parasol-claims-modernized -n ${NS}"
         fi; }
fi

verify_summary
