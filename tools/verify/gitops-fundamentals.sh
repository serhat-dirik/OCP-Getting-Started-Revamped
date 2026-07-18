#!/usr/bin/env bash
# Verify gitops-fundamentals — GitOps Fundamentals.
#   Entry: {user}-gitops workspace ns + entry marker · the student-gitops Argo CD instance is
#          reachable · the attendee's proj-{user} AppProject exists · a per-user Gitea fork of
#          claims-config with its dev overlay personalized to {user}-dev. Entry leaves dev/stage
#          EMPTY (the attendee's first Application is the lab).
#   End:   claims runs GitOps-managed in {user}-dev (claims-db + app ready, app route answers 200,
#          and the Deployment carries the Argo tracking annotation — proving it was deployed by the
#          student instance, not applied by hand) AND promoted to {user}-stage (>=2 replicas: solve
#          leaves 2, the completed lab's Exercise D scales to 3 — both pass).
# End checks are outcome-based: they pass for BOTH the attendee's own Application AND `ws solve`'s
# two Applications. Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
GITOPS="${USER_NAME}-gitops"
DEV="${USER_NAME}-dev"
STAGE="${USER_NAME}-stage"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Cluster ingress domain — attendee-readable; used to derive route hosts without a cross-namespace
# route read (attendees cannot read routes in gitea/student-gitops).
ingress_domain() {
  oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true
}

# Gitea host: route if readable, else derived from the ingress domain (route "gitea" in ns "ogsr-gitea").
gitea_host() {
  local host domain
  host="$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(ingress_domain)"
    [[ -n "$domain" ]] && host="gitea-ogsr-gitea.${domain}"
  fi
  echo "$host"
}

# The per-user promotion fork exists → the Gitea API answers 2xx for {user}/claims-config.
fork_exists() {
  local host; host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${USER_NAME}/claims-config"
}

# The dev overlay was personalized by the fork job → its kustomization sets namespace {user}-dev.
overlay_personalized() {
  local host; host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf "https://${host}/api/v1/repos/${USER_NAME}/claims-config/raw/overlays/dev/kustomization.yaml?ref=main" 2>/dev/null \
    | grep -q "namespace: ${DEV}"
}

# The student-gitops Argo CD instance is reachable on its route (derived host; /healthz → 200).
student_argo_up() {
  local domain code
  domain="$(ingress_domain)"
  [[ -n "$domain" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 \
    "https://student-gitops-server-student-gitops.${domain}/healthz" || true)"
  [[ "$code" == "200" ]]
}

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# Deployment reports AT LEAST N ready replicas. Stage starts at 2 (the overlay's canonical count,
# which `ws solve` produces) but the completed lab deliberately ends at 3 (Exercise D scales up) —
# so the end check must accept >= 2, not == 2, or a correct attendee gets a false red.
deploy_ready_min() {
  local name="$1" ns="$2" want="$3" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge "$want" ]]
}

# The Deployment carries the Argo CD tracking annotation → it is GitOps-managed by the student
# instance (annotation tracking), NOT applied by hand — the point of gitops-fundamentals vs the config-multienv hand-config.
deploy_gitops_managed() {
  oc get deploy "$1" -n "$2" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null | grep -q .
}

# Deployment does NOT exist (entry-only: dev/stage start empty).
deploy_absent() {
  ! oc get deploy "$1" -n "$2" >/dev/null 2>&1
}

# The claims Route answers HTTP 200 on the readiness endpoint (also proves DB connectivity, since
# readiness gates on the datasource). API-only service: "/" is 404 by design.
route_ready_200() {
  local ns="$1" host code
  host="$(oc get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# --- entry state (what `ws start gitops-fundamentals` materializes) --------------------------
check "namespace ${GITOPS} exists"                       oc get ns "$GITOPS"                                 || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-gitops-fundamentals in ${GITOPS}"           oc get cm ws-entry-gitops-fundamentals -n "$GITOPS"                 || hint "entry app not synced — ws start gitops-fundamentals --user ${USER_NAME}"
check "student-gitops Argo CD instance reachable"        student_argo_up                                     || hint "student instance missing — sync the workshop-config Argo app (student-argocd.yaml)"
check "AppProject proj-${USER_NAME} exists"              oc get appproject "proj-${USER_NAME}" -n ogsr-student-gitops || hint "per-user AppProject missing — sync workshop-config (student-appprojects.yaml)"
check "Gitea fork ${USER_NAME}/claims-config exists"     fork_exists                                         || hint "fork job didn't run — ws reset gitops-fundamentals --user ${USER_NAME} (or check gitea-fork-gitops-fundamentals-${USER_NAME} Job in ns gitea)"
check "dev overlay personalized to ${DEV}"               overlay_personalized                                || hint "fork not personalized — ws reset gitops-fundamentals --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove dev/stage start EMPTY (the attendee's Application deploys the app in the lab).
  check "no parasol-claims in ${DEV} yet (clean)"        deploy_absent parasol-claims "$DEV"                 || hint "dev already has the app — ws reset gitops-fundamentals --user ${USER_NAME} for a clean entry"
  check "no parasol-claims in ${STAGE} yet (clean)"      deploy_absent parasol-claims "$STAGE"               || hint "stage already has the app — ws reset gitops-fundamentals --user ${USER_NAME} for a clean entry"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  check "claims-db ready in ${DEV}"                      deploy_ready claims-db "$DEV"                       || hint "your Argo Application should deploy claims-db — check it Synced/Healthy in the student UI"
  check "parasol-claims ready in ${DEV}"                 deploy_ready parasol-claims "$DEV"                  || hint "create your Argo Application (overlays/dev) on student-gitops; ws solve gitops-fundamentals does this — or the platform enrollment (managed-by) is broken, see troubleshooting"
  check "dev claims is GitOps-managed (Argo tracking)"   deploy_gitops_managed parasol-claims "$DEV"         || hint "deploy it via an Argo Application, not oc apply — that is the gitops-fundamentals lesson"
  check "route parasol-claims answers 200 in ${DEV}"     route_ready_200 "$DEV"                              || hint "claims app not ready — check pods: oc get pods -n ${DEV}"
  check "parasol-claims promoted to ${STAGE} (>=2 replicas)" deploy_ready_min parasol-claims "$STAGE" 2     || hint "promote — add a second Application pointed at overlays/stage (ws solve gitops-fundamentals does this)"
fi

verify_summary
