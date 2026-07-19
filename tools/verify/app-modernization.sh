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

# A Deployment is READY (>=1 ready replica) in {user}-modernize. Readiness — not mere presence — so the
# Ex6 crash-loop content bug is caught (a deployed-but-crashlooping modernized service fails here, which
# is correct and desired until that content fix lands). `>=1` is lab-exceedable.
deploy_ready() {
  local ready
  ready="$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The attendee's legacy-repo fork URL, as recorded in the entry marker (attendee-safe: no gitea route
# read cross-namespace — the URL was computed from the cluster domain at materialization).
legacy_repo() { oc get cm ws-entry-app-modernization -n "$NS" -o jsonpath='{.data.legacyRepo}' 2>/dev/null || true; }

# The legacy fork is reachable (public repo → anonymous HTTPS GET returns 200). Network-tolerant caller.
repo_reachable() {
  local u; u="$(legacy_repo)"
  [[ -n "$u" ]] || return 1
  curl -ksf --max-time 10 "$u" >/dev/null 2>&1
}

# [ADS] MaaS credential present (Developer Lightspeed wired) — reported as INFO, never failed.
maas_secret_present() { oc get secret maas-credentials -n "$NS" >/dev/null 2>&1; }

# Entry clean-slate: the modernized service is NOT deployed yet (attendee hasn't finished the lab).
no_modernized() { ! oc get deploy parasol-claims-modernized -n "$NS" >/dev/null 2>&1; }

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                     oc get ns "$NS"                    || hint "run: ws prep app-modernization (or ws start app-modernization --user ${USER_NAME}); ${NS} is workshop-layer (per-user-modernize)"
check "entry marker ws-entry-app-modernization present"          oc get cm ws-entry-app-modernization -n "$NS"    || hint "entry app not synced — ws reset app-modernization --user ${USER_NAME}"
check "MaaS config present (endpoint + model)"     oc get cm maas-config -n "$NS"     || hint "entry app not synced — ws reset app-modernization --user ${USER_NAME}"
check "legacy fork parasol-legacy-claims reachable in Gitea" repo_reachable           || hint "the fork {user}/parasol-legacy-claims is missing — check the gitea-fork Job (ws reset app-modernization --user ${USER_NAME}); needs parasol/parasol-legacy-claims seeded (workshop-config app-repo-seed)"

# INFO: [ADS] Developer Lightspeed for MTA wiring (optional — never fails the entry state).
if maas_secret_present; then
  info "[ADS] maas-credentials present — Developer Lightspeed for MTA is wired (auto-mounts into the Dev Spaces workspace as GENAI_API_KEY)"
else
  info "[ADS] maas-credentials absent — Developer Lightspeed disabled (graceful degradation); the [OCP] MTA assess/analyze/replatform flow is unaffected"
fi
# INFO: the shared MTA Hub is a platform-stack concern (openshift-mta), not per-user state.
info "shared MTA Hub namespace: $(oc get cm ws-entry-app-modernization -n "$NS" -o jsonpath='{.data.mtaNamespace}' 2>/dev/null || echo openshift-mta) (installed by the platform-portfolio mta stack; analysis targets $(oc get cm ws-entry-app-modernization -n "$NS" -o jsonpath='{.data.analysisTargets}' 2>/dev/null || echo 'cloud-readiness,openshift,containerization'))"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — nothing modernized/deployed yet -------------------------------------
  check "no modernized service deployed yet (attendee builds it)" no_modernized || hint "parasol-claims-modernized exists; the lab already finished — ws reset app-modernization --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — the modernized service deployed to {user}-modernize -------------
  # Assert the OUTCOME (a modernized claims service is deployed AND Ready), never exact wording, so any
  # correct solution stays green (rule 14). READY, not just present: a crash-looping modernized deploy
  # (see the READINESS NOTE — it currently does) fails HERE, which deploy_present missed. RED until the
  # crash-loop fix lands is correct and desired.
  check "modernized service parasol-claims-modernized deployed + Ready" deploy_ready parasol-claims-modernized \
    || hint "parasol-claims-modernized is not Ready — if it CrashLoops it needs QUARKUS_DATASOURCE_ACTIVE=false (DB-free), the crash-loop fix; otherwise deploy it (ws solve app-modernization --user ${USER_NAME})"
fi

verify_summary
