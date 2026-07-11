#!/usr/bin/env bash
# Verify M10 — GitOps at Scale & Progressive Delivery.
#   Entry: {user}-gitops workspace ns + entry marker · the student-gitops Argo CD instance is
#          reachable · the attendee's proj-{user} AppProject exists · a per-user Gitea fork of
#          claims-config that ALSO carries the M10 source (rollouts/ overlay personalized to
#          {user}-prod + applicationset.yaml) · the per-user analysis prereqs in {user}-prod
#          (claims-analysis SA + m10-canary-control knob) · AND the M09 END STATE materialized:
#          claims runs GitOps-managed in {user}-dev + {user}-stage (M10 starts where M09 ended, so
#          M10 is independent). Entry leaves {user}-prod WITHOUT the Rollout (converting prod to a
#          Rollout is the lab).
#   End:   {user}-prod runs claims as an Argo Rollout (canary), Healthy, route answers 200 (also
#          proves the cluster RolloutManager is serving — a Rollout only goes Healthy if the
#          controller processes it).
# End checks are outcome-based: they pass for BOTH the attendee's own lab result AND `ws solve`'s
# prod Application. Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
GITOPS="${USER_NAME}-gitops"
DEV="${USER_NAME}-dev"
STAGE="${USER_NAME}-stage"
PROD="${USER_NAME}-prod"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Cluster ingress domain — attendee-readable; used to derive route hosts without a cross-namespace
# route read (attendees cannot read routes in gitea/student-gitops).
ingress_domain() {
  oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true
}

# Gitea host: route if readable, else derived from the ingress domain (route "gitea" in ns "gitea").
gitea_host() {
  local host domain
  host="$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(ingress_domain)"
    [[ -n "$domain" ]] && host="gitea-gitea.${domain}"
  fi
  echo "$host"
}

# The per-user promotion fork exists → the Gitea API answers 2xx for {user}/claims-config.
fork_exists() {
  local host; host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${USER_NAME}/claims-config"
}

# The fork carries a raw file whose contents match a pattern (proves the M10 source + personalization).
fork_file_matches() {
  local path="$1" pattern="$2" host; host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf "https://${host}/api/v1/repos/${USER_NAME}/claims-config/raw/${path}?ref=main" 2>/dev/null \
    | grep -q "$pattern"
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

# Deployment reports AT LEAST N ready replicas (stage starts at 2; a completed promotion may exceed).
deploy_ready_min() {
  local name="$1" ns="$2" want="$3" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge "$want" ]]
}

# The Deployment carries the Argo CD tracking annotation → it is GitOps-managed by the student instance.
deploy_gitops_managed() {
  oc get deploy "$1" -n "$2" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null | grep -q .
}

# A named Rollout is present AND Healthy (also proves the cluster RolloutManager is serving it).
rollout_healthy() {
  local name="$1" ns="$2" phase
  phase="$(oc get rollout "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Healthy" ]]
}

# A named Rollout is ABSENT (entry-only: prod starts without the Rollout — converting it is the lab).
rollout_absent() {
  ! oc get rollout "$1" -n "$2" >/dev/null 2>&1
}

# The claims Route answers HTTP 200 on the readiness endpoint (also proves DB connectivity).
route_ready_200() {
  local ns="$1" host code
  host="$(oc get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# --- entry state (what `ws start m10` materializes) --------------------------
check "namespace ${GITOPS} exists"                       oc get ns "$GITOPS"                                 || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-m10 in ${GITOPS}"           oc get cm ws-entry-m10 -n "$GITOPS"                 || hint "entry app not synced — ws start m10 --user ${USER_NAME}"
check "student-gitops Argo CD instance reachable"        student_argo_up                                     || hint "student instance missing — sync workshop-config (student-argocd.yaml)"
check "AppProject proj-${USER_NAME} exists"              oc get appproject "proj-${USER_NAME}" -n student-gitops || hint "per-user AppProject missing — sync workshop-config (student-appprojects.yaml)"
check "Gitea fork ${USER_NAME}/claims-config exists"     fork_exists                                         || hint "fork job didn't run — ws reset m10 --user ${USER_NAME} (or check gitea-fork-m10-${USER_NAME} Job in ns gitea)"
check "fork carries rollouts/ overlay (prod-personalized)" fork_file_matches "rollouts/kustomization.yaml" "namespace: ${PROD}" || hint "fork missing M10 source — ws reset m10 --user ${USER_NAME}"
check "fork carries applicationset.yaml (personalized)"  fork_file_matches "applicationset.yaml" "proj-${USER_NAME}"            || hint "fork missing the ApplicationSet source — ws reset m10 --user ${USER_NAME}"
check "analysis SA claims-analysis in ${PROD}"           oc get sa claims-analysis -n "$PROD"                || hint "analysis prereq missing — ws reset m10 --user ${USER_NAME}"
check "canary knob m10-canary-control in ${PROD}"        oc get cm m10-canary-control -n "$PROD"             || hint "analysis knob missing — ws reset m10 --user ${USER_NAME}"
# M10 entry = the M09 END STATE: claims GitOps-managed in dev + stage (M10 starts where M09 ended).
check "claims-db ready in ${DEV}"                        deploy_ready claims-db "$DEV"                       || hint "M09 end state not materialized — ws reset m10 --user ${USER_NAME}"
check "parasol-claims ready in ${DEV}"                   deploy_ready parasol-claims "$DEV"                  || hint "M09 end state not materialized — ws reset m10 --user ${USER_NAME}"
check "dev claims is GitOps-managed (Argo tracking)"     deploy_gitops_managed parasol-claims "$DEV"         || hint "dev claims should be deployed by the student instance — ws reset m10 --user ${USER_NAME}"
check "parasol-claims ready in ${STAGE} (>=2 replicas)"  deploy_ready_min parasol-claims "$STAGE" 2          || hint "M09 end state not materialized in stage — ws reset m10 --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove {user}-prod does NOT yet run the Rollout (converting prod is the lab).
  check "no parasol-claims Rollout in ${PROD} yet (clean)" rollout_absent parasol-claims "$PROD"             || hint "prod already has the Rollout — ws reset m10 --user ${USER_NAME} for a clean entry"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  check "parasol-claims runs as a Rollout in ${PROD} (Healthy)" rollout_healthy parasol-claims "$PROD"       || hint "convert prod to a Rollout (rollouts/ overlay); ws solve m10 does this — needs the cluster RolloutManager"
  check "route parasol-claims answers 200 in ${PROD}"     route_ready_200 "$PROD"                            || hint "prod claims not ready — check the Rollout: oc argo rollouts get rollout parasol-claims -n ${PROD}"
fi

verify_summary
