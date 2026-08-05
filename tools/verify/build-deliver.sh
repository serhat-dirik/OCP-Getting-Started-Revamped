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

# gitea_host() (route if readable, else derived from the cluster ingress domain — attendees cannot
# read routes in the gitea namespace) is shared — tools/verify/_lib.sh. GLOBAL, not echo-shaped: call
# it bare and read $GITEA_HOST, never `$(gitea_host)` (that would strand VERIFY_INCONCLUSIVE in a
# subshell).

# Attendee-visibility of the catalog Templates in the shared `openshift` namespace. `--as` needs
# impersonation rights (admin/CI only); when the attendee runs this themselves their own
# SelfSubjectAccessReview IS the attendee answer. Flags stay LITERAL in both branches — an --as
# string built from a variable silently reviews the wrong subject.
# Every read here goes through oc_read, in the CALLER's own shell: `$(oc whoami 2>/dev/null)` and a
# silenced `can-i impersonate` both answer "" on an unreachable API, which used to drop this into the
# self branch whose can-i then failed for the SAME transport reason — and printed ❌ at the attendee.
attendee_reads_catalog_templates() {
  local who_rc=0 imp_rc=0 impersonate="false"
  oc_read whoami || who_rc=$?
  if (( who_rc != 0 )) || [[ "$OC_OUT" != "$USER_NAME" ]]; then
    oc_read auth can-i impersonate users || imp_rc=$?
    # 0 OR 2, the same open-on-"could not ask" as multi-tenancy-workload-security's IMPERSONATE_OK: a
    # transport failure must not quietly re-point the review at the CALLER's own rights. A genuine
    # "no" from the server is rc 1 and still closes the guard.
    case "$imp_rc" in 0|2) impersonate="true";; esac
  fi
  if [[ "$impersonate" == "true" ]]; then
    oc_read auth can-i get templates.template.openshift.io -n openshift --as="$USER_NAME" --as-group=workshop-attendees
  else
    oc_read auth can-i get templates.template.openshift.io -n openshift
  fi
}

# A Gitea repo exists → the (public) repo API answers 2xx anonymously.
gitea_repo_exists() {
  local owner="$1" repo="$2"
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${owner}/${repo}"
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# Route resolves and answers HTTP 200 on the claims readiness endpoint. The Route read is oc_present in
# THIS shell: a Route the API could not be asked about is not an unexposed app, and the hint below tells
# the attendee to redo exercise 5 they may already have done correctly.
route_answers_200() {
  local ns="$1" host code
  oc_present get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# No DeploymentConfig objects anywhere in the namespace (every Parasol workload is a
# Deployment; the custom PostgreSQL Template exists precisely to avoid the stock DC).
# Namespace must actually exist first — otherwise a zero count is vacuous, not evidence.
# NEGATION IS THE DANGEROUS DIRECTION: a silenced `oc get deploymentconfig | grep -c .` counts zero
# just as readily from an API that never answered, certifying a banned-tech clean bill nobody checked.
# oc_absent returns 0 only when the API ANSWERED — including "the server doesn't have a resource type
# deploymentconfig", which is a real answer meaning there are none and must stay a pass.
no_deploymentconfig() {
  local ns="$1"
  oc_present get ns "$ns" -o name || return 1
  oc_absent get deploymentconfig -n "$ns" -o name
}

# --- entry state (what `ws start build-deliver` materializes) --------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                            || hint "run: ws start build-deliver --user ${USER_NAME}"
check "entry marker ws-entry-build-deliver present"            oc get cm ws-entry-build-deliver -n "$NS"            || hint "entry app not synced — ws start build-deliver --user ${USER_NAME}"
check "workshop quota present in ${NS}"              oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea fork ${USER_NAME}/parasol-claims answers"        gitea_repo_exists "$USER_NAME" parasol-claims        || hint "fork missing — re-run: ws start build-deliver --user ${USER_NAME} (fork job)"
check "Gitea fork ${USER_NAME}/parasol-notifications answers" gitea_repo_exists "$USER_NAME" parasol-notifications || hint "fork missing — re-run: ws start build-deliver --user ${USER_NAME} (fork job)"
check "Parasol PostgreSQL catalog Template present"  oc get template parasol-postgresql-ephemeral -n openshift || hint "template missing — sync the workshop-config Argo app"
# The Template object existing is not the outcome — the attendee FINDING it in the Software Catalog
# is. The catalog lists namespace-visible templates from openshift/, so the attendee needs the read.
# NOTE ON WHAT THIS CHECK CAN AND CANNOT TELL YOU (measured 2026-07-31 on a cluster that had never
# had the workshop installed). The capability is real and worth asserting — without it the Software
# Catalog tile the lab sends attendees to simply is not there. But it is NOT evidence that our RBAC
# landed: stock OpenShift ships a `shared-resource-viewer` Role in the `openshift` namespace bound by
# `shared-resource-viewers` to the group `system:authenticated`, so EVERY authenticated user already
# has this read. Verified on bare CRC: `platform-observer` did not exist at all, and this same
# can-i returned `yes`. So it passes with platform-observer deleted entirely, and the old hint sent
# you to inspect a ClusterRole that has nothing to do with the outcome. Exactly the trap CLAUDE.md
# records — stock cluster roles carry more than anyone remembers. Keep the check, believe it only as
# a statement about the tile.
check "attendee can read catalog Templates (Software Catalog tile)" attendee_reads_catalog_templates || hint "the Software Catalog tile the lab tells them to open will not appear — the attendee cannot read templates in the openshift namespace. NOTE this read normally comes from STOCK OpenShift (Role shared-resource-viewer, bound to system:authenticated in the openshift namespace), not from platform-observer — so a failure here means that stock binding is missing or the identity is not authenticated, and inspecting platform-observer will not explain it"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab looks like) ---------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "claims-db deployment ready"            deploy_ready claims-db "$NS"        || hint "not done yet? deploying the database is lab exercise 1 (Parasol PostgreSQL, ephemeral, from the catalog), so a red here before you start is expected and not a broken environment. If you HAVE deployed it and it is still not ready, that one is real: oc get pods -n ${NS} and oc describe deploy/claims-db -n ${NS}"
  check "parasol-claims deployment ready"       deploy_ready parasol-claims "$NS"   || hint "not done yet? building and wiring claims is lab exercises 1 and 5 (S2I import, then oc set env --from=secret/claims-db) — expected red until you do them. If it IS deployed and still not ready, that one is real: oc get pods -n ${NS} and oc describe deploy/parasol-claims -n ${NS}"
  check "route parasol-claims answers 200"      route_answers_200 "$NS"             || hint "not done yet? exposing claims and wiring its DB env is lab exercise 5 — expected red before that. If the Route exists and answers non-200, that one is real: check the pod is Ready and the DB env is set"
  check "no DeploymentConfig objects in ${NS}"  no_deploymentconfig "$NS"           || hint "this one is broken, not undone — nothing in the lab creates a DeploymentConfig, so one being here means a deprecated object leaked in. Parasol uses Deployments only: redeploy the DB from the Parasol template"
fi

verify_summary
