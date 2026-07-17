#!/usr/bin/env bash
# Verify build-deliver — Ways to Build & Deliver Apps.
#   Entry: {user}-dev exists · entry marker CM · workshop quota · both Gitea forks
#          answer · Parasol PostgreSQL catalog Template present.
#   End:   claims-db Deployment ready · parasol-claims Deployment ready · Route answers
#          HTTP 200 · zero DeploymentConfig objects (banned-tech guard).
# End checks are mechanism-agnostic (satisfied by the attendee's S2I build AND by
# `ws solve`'s prebuilt image) — they assert the OUTCOME (a running, DB-backed claims
# app), matching the platform-orientation verify philosophy and the "verify runs after solve" contract.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea host, discovered environment-agnostically. Instructors/CI can read the route;
# an attendee (userN) cannot read routes in the gitea namespace, so fall back to the
# conventional host derived from the cluster ingress domain (route "gitea" in namespace
# "gitea" → gitea-gitea.<domain>).
gitea_host() {
  local host domain
  host="$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-gitea.${domain}"
  fi
  echo "$host"
}

# A Gitea repo exists → the (public) repo API answers 2xx anonymously.
gitea_repo_exists() {
  local owner="$1" repo="$2" host
  host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${owner}/${repo}"
}

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# Route resolves and answers HTTP 200 on the claims readiness endpoint.
route_answers_200() {
  local ns="$1" host code
  host="$(oc get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# No DeploymentConfig objects anywhere in the namespace (every Parasol workload is a
# Deployment; the custom PostgreSQL Template exists precisely to avoid the stock DC).
no_deploymentconfig() {
  local ns="$1" n
  n="$(oc get deploymentconfig -n "$ns" -o name 2>/dev/null | grep -c . || true)"
  [[ "$n" == "0" ]]
}

# --- entry state (what `ws start build-deliver` materializes) --------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                            || hint "run: ws start build-deliver --user ${USER_NAME}"
check "entry marker ws-entry-build-deliver present"            oc get cm ws-entry-build-deliver -n "$NS"            || hint "entry app not synced — ws start build-deliver --user ${USER_NAME}"
check "workshop quota present in ${NS}"              oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea fork ${USER_NAME}/parasol-claims answers"        gitea_repo_exists "$USER_NAME" parasol-claims        || hint "fork missing — re-run: ws start build-deliver --user ${USER_NAME} (fork job)"
check "Gitea fork ${USER_NAME}/parasol-notifications answers" gitea_repo_exists "$USER_NAME" parasol-notifications || hint "fork missing — re-run: ws start build-deliver --user ${USER_NAME} (fork job)"
check "Parasol PostgreSQL catalog Template present"  oc get template parasol-postgresql-ephemeral -n openshift || hint "template missing — sync the workshop-config Argo app"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab looks like) ---------------------------
  check "claims-db deployment ready"            deploy_ready claims-db "$NS"        || hint "deploy the database — lab: Parasol PostgreSQL (ephemeral) from the catalog"
  check "parasol-claims deployment ready"       deploy_ready parasol-claims "$NS"   || hint "build & wire claims — lab exercises 1 and 5 (S2I import, then oc set env --from=secret/claims-db)"
  check "route parasol-claims answers 200"      route_answers_200 "$NS"             || hint "expose claims and wire its DB env — lab exercise 5"
  check "no DeploymentConfig objects in ${NS}"  no_deploymentconfig "$NS"           || hint "a DeploymentConfig leaked in — Parasol uses Deployments only (redeploy the DB from the Parasol template)"
fi

verify_summary
