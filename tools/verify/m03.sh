#!/usr/bin/env bash
# Verify M03 — Dev Spaces & the Inner Loop.
#   Entry: {user}-dev has the claims app + PostgreSQL (M02 end state, composed directly);
#          a per-user Gitea fork of parasol-claims exists; entry marker + quota present.
#   End:   the attendee started a Dev Spaces workspace — it lives in {user}-devspaces.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
WS_NS="${USER_NAME}-devspaces"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea host discovered from the cluster ingress domain so the script stays
# environment-agnostic and needs no cross-namespace route read (attendees can't
# read routes in the gitea namespace): route "gitea" in ns "gitea" → gitea-gitea.<domain>.
gitea_host() {
  local host domain
  host="$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-gitea.${domain}"
  fi
  echo "$host"
}

# The per-user fork exists → the Gitea API answers 2xx for {user}/parasol-claims.
fork_exists() {
  local host; host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${USER_NAME}/parasol-claims"
}

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The claims Route answers HTTP 200 on the readiness endpoint. NOTE: parasol-claims is an
# API-only service — "/" returns 404 by design, so we probe /q/health/ready (and it also
# proves the app reached its datasource, since readiness gates on the DB connection).
route_ready_200() {
  local ns="$1" host code
  host="$(oc get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# --- entry state (what `ws start m03` materializes) --------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                              || hint "run: ws start m03 --user ${USER_NAME}"
check "entry marker ws-entry-m03 present"            oc get cm ws-entry-m03 -n "$NS"              || hint "entry app not synced — ws start m03 --user ${USER_NAME}"
check "workshop quota present in ${NS}"              oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea fork ${USER_NAME}/parasol-claims exists" fork_exists                                 || hint "fork job didn't run — ws reset m03 --user ${USER_NAME} (or check the gitea-fork-m03-${USER_NAME} Job in ns gitea)"
check "claims-db deployment has >=1 ready replica"   deploy_ready claims-db "$NS"                 || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica" deploy_ready parasol-claims "$NS"         || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "route parasol-claims answers 200 (/q/health/ready)" route_ready_200 "$NS"                  || hint "claims app not ready — check: oc get pods -n ${NS}"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab looks like) ---------------------------
  # The workspace lives in {user}-devspaces, auto-provisioned by the Dev Spaces dashboard on
  # first login. An ATTENDEE cannot `oc get devworkspaces` there (the dashboard grants
  # workspace RBAC per workspace, not blanket list — verified on 4.21 / Dev Spaces 3.29),
  # so the attendee-safe end signal is the namespace existing. When this runs with admin/CI
  # rights (or after the dashboard grants list rights), we additionally assert a DevWorkspace.
  check "workspace namespace ${WS_NS} exists"        oc get ns "$WS_NS"                           || hint "open ${USER_NAME}/parasol-claims in Dev Spaces (lab exercise 1) to provision your workspace"
  if oc auth can-i list devworkspaces.workspace.devfile.io -n "$WS_NS" >/dev/null 2>&1; then
    check "a DevWorkspace exists in ${WS_NS}"        bash -c "oc get devworkspaces -n '$WS_NS' -o name 2>/dev/null | grep -q ." || hint "start a workspace from the repo (lab exercise 1)"
  fi
fi

verify_summary
