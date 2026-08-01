#!/usr/bin/env bash
# Verify devspaces-inner-loop — Dev Spaces & the Inner Loop.
#   Entry: {user}-dev has the claims app + PostgreSQL (build-deliver end state, composed directly);
#          a per-user Gitea fork of parasol-claims exists; entry marker + quota present.
#   End:   the attendee started a Dev Spaces workspace — it lives in {user}-devspaces.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
WS_NS="${USER_NAME}-devspaces"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea host discovered from the cluster ingress domain so the script stays
# environment-agnostic and needs no cross-namespace route read (attendees can't
# read routes in the gitea namespace): route "gitea" in ns "ogsr-gitea" → gitea-ogsr-gitea.<domain>.
gitea_host() {
  local host domain
  host="$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-ogsr-gitea.${domain}"
  fi
  echo "$host"
}

# The per-user fork exists → the Gitea API answers 2xx for {user}/parasol-claims.
fork_exists() {
  local host; host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${USER_NAME}/parasol-claims"
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# The claims Route answers HTTP 200 on the readiness endpoint. NOTE: parasol-claims is an
# API-only service — "/" returns 404 by design, so we probe /q/health/ready (and it also
# proves the app reached its datasource, since readiness gates on the DB connection).
# The Route read is oc_present in THIS shell (never `$(…)`, which would strand VERIFY_INCONCLUSIVE in a
# subshell): a Route the API could not be asked about is not a missing Route, and grading it ❌ blames
# the attendee for a cluster blip.
route_ready_200() {
  local ns="$1" host code
  oc_present get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# --- did the attendee actually START a workspace? ----------------------------
# THE NAMESPACE IS NOT THE END STATE. Dev Spaces auto-provisions {user}-devspaces on first DASHBOARD
# LOGIN — CheCluster/devspaces carries devEnvironments.defaultNamespace.autoProvision=true with
# template `<username>-devspaces` (read off the cluster 2026-08-01) — so an attendee who opened the
# dashboard and did nothing else collected a full green for a lab they never ran.
# What appears only when a workspace is STARTED is the DevWorkspace object and what its controller
# creates for it: a Deployment, its pod, and the per-user home PVC (persistUserHome is enabled,
# pvcStrategy per-user). ConfigMaps/Secrets/ServiceAccounts are deliberately NOT in that list — Che
# provisions several of those at namespace-creation time, so they exist before any workspace runs.
# Rights in that namespace come from Dev Spaces, not from the workshop's per-user RBAC (which covers
# only {user}-dev|stage|prod|cicd) — but the attendee DOES hold them, so all four signals below are
# readable as {user}. Grounded on cluster 2026-08-01: cm/che in openshift-devspaces sets
# CHE_INFRA_KUBERNETES_USER__CLUSTER__ROLES=openshift-devspaces-cheworkspaces-clusterrole,
# openshift-devspaces-cheworkspaces-devworkspace-clusterrole, and Che RoleBinds exactly those two into
# {user}-devspaces when it auto-provisions it. The first carries `list` on pods, apps/deployments and
# PVCs (plus events, which the troubleshooting page tells attendees to read); the second carries
# get/list/watch/create/update/patch/delete on devworkspaces AND devworkspacetemplates.
# NOT devspaces-edit / devspaces-view: those two ship with the operator but have ZERO bindings on the
# cluster (0 ClusterRoleBindings, 0 RoleBindings) and are named nowhere in the Che config, so they
# grant nobody anything. An earlier revision of this comment named them as the source of the rights
# and inferred from that a refusal which cannot happen.
# So the rc=2 branch below is NOT an expected-refusal path. Reaching it means the API could not be
# asked, or Dev Spaces never provisioned that namespace's RBAC — both real problems worth surfacing.
# It stays, because a read that could not be answered has to be an explicit "cannot grade", never a
# silent pass; it just must not tell the attendee that being refused here is normal.

# Read one resource in the workspace namespace and CLASSIFY the server's answer. Deliberately not
# `oc auth can-i`: run by an instructor or CI the caller is cluster-admin, so can-i would answer for
# THEM and skip (or mis-grade) the check on the attendee's behalf.
# stdout: object names, possibly empty. return: 0 = read succeeded · 1 = Forbidden · 2 = other error.
ws_ns_read() {  # ws_ns_read <resource>
  local rc=0 tmp="/tmp/.devspaces-read.$$"
  oc get "$1" -n "$WS_NS" -o name 2>"$tmp" || rc=$?
  if (( rc != 0 )); then
    if grep -qi forbidden "$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"; return 2
  fi
  rm -f "$tmp"
  return 0
}

# 0 = a workspace was started · 1 = the namespace holds no workspace artefact at all (dashboard opened,
# nothing started) · 2 = none of the signals is readable as this identity, so the end state is not
# gradeable from here.
workspace_started() {
  local kind names rc readable=0
  for kind in devworkspaces.workspace.devfile.io deployments pods persistentvolumeclaims; do
    rc=0; names="$(ws_ns_read "$kind")" || rc=$?
    if (( rc == 0 )); then
      readable=1
      if [[ -n "$names" ]]; then return 0; fi
    fi
  done
  if (( readable == 0 )); then return 2; fi
  return 1
}

# --- entry state (what `ws start devspaces-inner-loop` materializes) --------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                              || hint "run: ws start devspaces-inner-loop --user ${USER_NAME}"
check "entry marker ws-entry-devspaces-inner-loop present"            oc get cm ws-entry-devspaces-inner-loop -n "$NS"              || hint "entry app not synced — ws start devspaces-inner-loop --user ${USER_NAME}"
check "workshop quota present in ${NS}"              oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea fork ${USER_NAME}/parasol-claims exists" fork_exists                                 || hint "fork job didn't run — ws reset devspaces-inner-loop --user ${USER_NAME} (or check the gitea-fork-devspaces-inner-loop-${USER_NAME} Job in ns gitea)"
check "claims-db deployment has >=1 ready replica"   deploy_ready claims-db "$NS"                 || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica" deploy_ready parasol-claims "$NS"         || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "route parasol-claims answers 200 (/q/health/ready)" route_ready_200 "$NS"                  || hint "claims app not ready — check: oc get pods -n ${NS}"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab looks like) ---------------------------
  # Two separate facts, reported separately: the namespace proves only that you SIGNED IN (it is
  # auto-provisioned), and the workspace is the lab's actual outcome. See the helpers above.
  WS_DESC="a Dev Spaces workspace was started in ${WS_NS}"
  if check "Dev Spaces namespace ${WS_NS} exists (you signed in to the dashboard)" oc get ns "$WS_NS"; then
    ws_rc=0; workspace_started || ws_rc=$?
    case "$ws_rc" in
      0) check "$WS_DESC" true ;;
      1) check "$WS_DESC" false \
           || hint "${WS_NS} exists but holds no workspace — signing in to the dashboard creates that namespace on its own, so this is the 'opened it and stopped' state. Start a workspace from ${USER_NAME}/parasol-claims (lab exercise 1)" ;;
      *) warn "the end state is not gradeable from here — none of the workspace signals in ${WS_NS} (DevWorkspaces, Deployments, Pods, PVCs) is readable as this identity"
         hint "you normally CAN read all four — Dev Spaces grants them to you when it provisions ${WS_NS}. Landing here means the API could not be asked, or that grant is missing: retry, then show your instructor 'oc get rolebinding -n ${WS_NS}'. Meanwhile confirm in the dashboard that your parasol-claims workspace is running" ;;
    esac
  else
    hint "open the Dev Spaces dashboard and start ${USER_NAME}/parasol-claims (lab exercise 1) — the namespace is created on your first sign-in"
  fi
fi

verify_summary
