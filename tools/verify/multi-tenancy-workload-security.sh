#!/usr/bin/env bash
# Verify multi-tenancy-workload-security — Multi-Tenancy & Workload Security.
#   Entry: {user}-dev holds the "payments team" sandbox seed — 3 ServiceAccounts (payments-ci,
#          payments-ops, root-demander), all UNGOVERNED, plus a root-demanding Deployment
#          (root-demander) scaled to 0 (the attendee scales it up to watch restricted-v2 reject it).
#          The standing workshop quota/limits (workshop layer) are present to read. Entry marker set.
#   End:   the attendee ran the lab — the workload is FIXED and running non-root, payments-ci holds
#          edit-in-dev + view-in-prod, and payments-ops holds a custom `deployer` Role (Deployments
#          yes, Secrets no).
# Runnable as the ATTENDEE end-to-end: the shared/namespace checks read only {user}-dev|prod objects the
# attendee sees via namespace admin. The RBAC-outcome checks impersonate the teammate SAs — and the stock
# OpenShift `admin` ClusterRole every attendee holds on their own namespaces GRANTS `impersonate` on
# serviceaccounts, so IMPERSONATE_OK is true for the attendee too: these checks RUN and grade correctly for
# the attendee, `ws prep`/`ws verify`, and CI alike (verified live as a cockpit attendee 2026-07-18). The
# guard is defensive — it would only skip for a caller with NO namespace-admin, which this workshop never
# produces — so there is no silent admin-only skip for real attendees, at entry or end.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
PROD="${USER_NAME}-prod"

# --- helpers (oc only) -------------------------------------------------------

# A ServiceAccount exists in the team's home namespace.
sa_exists() { oc get sa "$1" -n "$NS" >/dev/null 2>&1; }

# The Deployment has at least one ready replica (the fixed workload is running).
deploy_ready() {
  local ready
  ready="$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The Deployment exists but is NOT running yet (entry: scaled to 0, nothing admitted).
deploy_idle() {
  oc get deploy "$1" -n "$NS" >/dev/null 2>&1 || return 1
  local ready
  ready="$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -z "$ready" || "$ready" == "0" ]]
}

# Can a teammate SA (in {user}-dev) do <verb> <resource> in <check-ns>? (impersonation — admin/CI only.)
sa_can() {  # sa check-ns verb resource
  oc auth can-i "$3" "$4" --as="system:serviceaccount:${NS}:$1" -n "$2" >/dev/null 2>&1
}
sa_cannot() { ! sa_can "$@"; }

# Guard for the RBAC-outcome checks: only a caller who can impersonate SAs (admin/CI) can evaluate them.
IMPERSONATE_OK="false"
oc auth can-i impersonate serviceaccounts >/dev/null 2>&1 && IMPERSONATE_OK="true"

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                              || hint "run: ws prep multi-tenancy-workload-security (or ws start multi-tenancy-workload-security --user ${USER_NAME})"
check "entry marker ws-entry-multi-tenancy-workload-security present"               oc get cm ws-entry-multi-tenancy-workload-security -n "$NS"              || hint "entry app not synced — ws reset multi-tenancy-workload-security --user ${USER_NAME}"
check "teammate SA payments-ci present"                 sa_exists payments-ci                        || hint "entry app not synced — ws reset multi-tenancy-workload-security --user ${USER_NAME}"
check "teammate SA payments-ops present"                sa_exists payments-ops                       || hint "entry app not synced — ws reset multi-tenancy-workload-security --user ${USER_NAME}"
check "workload SA root-demander present"               sa_exists root-demander                      || hint "entry app not synced — ws reset multi-tenancy-workload-security --user ${USER_NAME}"
check "standing workshop quota present in ${NS}"        oc get resourcequota workshop-quota -n "$NS" || hint "workshop-layer quota missing — run bootstrap/install.sh (quotas are NOT chart-owned)"
check "root-demander Deployment present"                oc get deploy root-demander -n "$NS"         || hint "entry app not synced — ws reset multi-tenancy-workload-security --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the workload has NOT been run and the teammates are UNGOVERNED -----------------
  check "root-demander is not running yet (scaled to 0)" deploy_idle root-demander                   || hint "entry ships it at 0 replicas; if it is running, the lab already started — ws reset multi-tenancy-workload-security --user ${USER_NAME}"
  if [[ "$IMPERSONATE_OK" == "true" ]]; then
    # A leftover lab binding would fail these — makes a not-fully-clean reset VISIBLE (see ws-meta note).
    check "payments-ci is ungoverned in ${NS} (no edit yet)"   sa_cannot payments-ci "$NS" update deployments   || hint "a leftover RoleBinding governs payments-ci — remove lab-created bindings, then ws reset multi-tenancy-workload-security --user ${USER_NAME}"
    check "payments-ops is ungoverned in ${NS} (no deployer yet)" sa_cannot payments-ops "$NS" create deployments || hint "a leftover RoleBinding governs payments-ops — remove lab-created bindings, then ws reset multi-tenancy-workload-security --user ${USER_NAME}"
  fi
else
  # --- end state: the lab's OUTCOME — workload fixed + the team RBAC in place ----------------------
  # Assert OUTCOMES (the workload runs; effective permissions), never the mechanism (which RoleBinding
  # name / which securityContext field), so any correct solution stays green (template rule 14).
  check "root-demander now runs non-root (>=1 ready replica)" deploy_ready root-demander             || hint "fix the image (drop runAsUser:0) and scale up — or ws solve multi-tenancy-workload-security --user ${USER_NAME}"
  if [[ "$IMPERSONATE_OK" == "true" ]]; then
    check "payments-ci can update Deployments in ${NS} (edit)"     sa_can payments-ci "$NS" update deployments      || hint "grant payments-ci edit in ${NS}: oc adm policy add-role-to-user edit -z payments-ci -n ${NS}"
    check "payments-ci can read pods in ${PROD} (view)"            sa_can payments-ci "$PROD" get pods              || hint "grant payments-ci view in ${PROD}: oc adm policy add-role-to-user view -z payments-ci -n ${PROD}"
    check "payments-ci CANNOT create Deployments in ${PROD} (view is read-only)" sa_cannot payments-ci "$PROD" create deployments || hint "in ${PROD} payments-ci must be view-only — do not grant it edit there"
    check "payments-ops can create Deployments in ${NS} (deployer Role)"  sa_can payments-ops "$NS" create deployments   || hint "bind the custom deployer Role to payments-ops in ${NS} (see the lab)"
    check "payments-ops CANNOT read Secrets in ${NS} (deployer excludes secrets)" sa_cannot payments-ops "$NS" get secrets || hint "the deployer Role must NOT grant secrets read — that's the least-privilege point"
  else
    info "(RBAC-outcome checks skipped — caller cannot impersonate ServiceAccounts; run as admin/CI to grade them)"
  fi
fi

verify_summary
