#!/usr/bin/env bash
# Verify M01 — Platform Orientation & First App.
#   Entry: {user}-dev exists · entry marker CM · workshop quota · Gitea account answers.
#   End:   parasol-web Deployment ready · Route answers HTTP 200 on / .
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea account exists → API returns 2xx. Host is discovered from the cluster so
# the script stays environment-agnostic (no hardcoded URLs). Instructors/CI read the
# route directly; an attendee (userN) cannot read routes in the gitea namespace, so
# we fall back to the conventional host derived from the cluster ingress domain
# (route "gitea" in namespace "gitea" → gitea-gitea.<domain>), which every
# authenticated user can resolve.
gitea_user_exists() {
  local user="$1" host domain
  host="$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-gitea.${domain}"
  fi
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/users/${user}"
}

# Deployment has at least one ready replica (attendee may leave it at 1 or 3).
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# Route resolves and answers HTTP 200 on / (the app's landing page).
route_answers_200() {
  local ns="$1" host code
  host="$(oc get route parasol-web -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/" || true)"
  [[ "$code" == "200" ]]
}

# --- entry state (what `ws start m01` materializes) --------------------------
check "namespace ${NS} exists"                 oc get ns "$NS"                      || hint "run: ws start m01 --user ${USER_NAME}"
check "entry marker ws-entry-m01 present"       oc get cm ws-entry-m01 -n "$NS"      || hint "entry app not synced — ws start m01 --user ${USER_NAME}"
check "workshop quota present in ${NS}"         oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea account ${USER_NAME} answers (API 200)" gitea_user_exists "$USER_NAME" || hint "Gitea seeding incomplete — check the workshop layer / ws git-refresh"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab looks like) ---------------------------
  check "parasol-web deployment exists"         oc get deploy parasol-web -n "$NS"   || hint "deploy the image — lab exercise 2 (oc new-app --image=…/parasol-web:1.0 --name=parasol-web)"
  check "parasol-web has >=1 ready replica"     deploy_ready parasol-web "$NS"       || hint "wait for rollout: oc rollout status deploy/parasol-web -n ${NS}"
  check "route parasol-web answers 200 on /"    route_answers_200 "$NS"              || hint "publish the app — lab exercise 5 (oc expose service/parasol-web --port=8080)"
fi

verify_summary
