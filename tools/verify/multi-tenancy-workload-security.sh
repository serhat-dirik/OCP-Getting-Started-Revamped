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

# Every read below goes through _lib.sh's oc_read/oc_present/oc_absent rather than `2>/dev/null`, which
# cannot tell "the object is not there" (a gradeable ❌) from "the cluster did not answer" (a ⚠ that is
# never the attendee's fault). Predicates return 1 for both, and oc_read raises VERIFY_INCONCLUSIVE so
# check() picks the right one.

# A ServiceAccount exists in the team's home namespace.
sa_exists() { oc_present get sa "$1" -n "$NS" -o name; }

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# The Deployment exists but is NOT running yet (entry: scaled to 0, nothing admitted).
deploy_idle() {
  oc_present get deploy "$1" -n "$NS" -o name || return 1
  oc_read get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' || return 1
  [[ -z "$OC_OUT" || "$OC_OUT" == "0" ]]
}

# Can a teammate SA (in {user}-dev) do <verb> <resource> in <check-ns>? (impersonation — admin/CI only.)
# Returns oc_read's THREE outcomes verbatim: 0 = allowed · 1 = the server said no · 2 = it could not be
# asked. `oc auth can-i`'s plain "no" is rc 1 with only a namespace-scope Warning on stderr, which
# oc_read's allowlist deliberately does not recognise as a transport failure — so a denial stays a real
# answer (_lib.sh header).
sa_can() {  # sa check-ns verb resource
  oc_read auth can-i "$3" "$4" --as="system:serviceaccount:${NS}:$1" -n "$2"
}
# A negative RBAC assertion is only meaningful once the SA it's about actually exists — `oc auth
# can-i --as` evaluates hypothetically even for a nonexistent SA, so on a cluster where nothing
# materialized this would be vacuously true (denied because there is nothing to grant it, not
# because the entry state correctly left it ungoverned).
# rc 1 AND ONLY rc 1 certifies the denial. A bare `! sa_can` would return 0 — a green ✅ — whenever the
# API could not be asked at all, which is the exact defect a4c632f measured in another module's
# negation: a dead apiserver certifying a clean slate.
sa_cannot() {
  local rc=0
  oc_present get sa "$1" -n "$NS" -o name || return 1
  sa_can "$@" || rc=$?
  (( rc == 1 ))
}

# The FIXED workload is actually running as a NON-ROOT uid — asserted on the running Pod, not inferred
# from the Deployment being Ready. "Ready" alone cannot tell the taught fix from the [INSTRUCTOR-DEMO]
# alternative the content also teaches: grant root-demander a permissive SCC (anyuid) and the UNCHANGED
# root-demanding pod admits, goes Ready, and the old check called that "now runs non-root".
# The effective uid: a container-level securityContext.runAsUser wins over the pod-level one. When the
# attendee's fix pins no uid at all, restricted-v2's MustRunAsRange STAMPS one onto the container at
# admission (verified on-cluster 2026-08-01: a restricted-v2 pod carries
# .spec.containers[0].securityContext.runAsUser=1001420000 with the pod-level field empty). So an
# absent uid on a running pod means a RunAsAny SCC admitted it and it is running as the image's own
# user — root, for the tools image this workload uses. Either way: no non-zero uid = not the fix.
# Mechanism-agnostic: any securityContext that yields a non-root uid passes (template rule 14).
# Reads go through oc_read directly, NOT through `$(oc get … )`: `$( )` is a subshell, so the
# VERIFY_INCONCLUSIVE flag oc_read raises inside one would die with it and check() would print ❌ for a
# cluster that simply did not answer. OC_OUT is read in this shell instead.
root_demander_runs_nonroot() {
  local pod uid
  oc_read get pods -n "$NS" -l app=root-demander --field-selector=status.phase=Running -o name || return 1
  pod="${OC_OUT%%$'\n'*}"
  [[ -n "$pod" ]] || return 1
  oc_read get "$pod" -n "$NS" -o jsonpath='{.spec.containers[0].securityContext.runAsUser}' || return 1
  uid="$OC_OUT"
  if [[ -z "$uid" ]]; then
    oc_read get "$pod" -n "$NS" -o jsonpath='{.spec.securityContext.runAsUser}' || return 1
    uid="$OC_OUT"
  fi
  [[ -n "$uid" && "$uid" != "0" ]]
}

# Guard for the RBAC-outcome checks: only a caller who can impersonate SAs (admin/CI) can evaluate them.
# "Could not ask" (rc 2) keeps the guard OPEN on purpose. A closed guard makes the three entry-state RBAC
# checks vanish from the output with no line at all — and a check that silently disappears on an
# unreachable API is worse than one that says ⚠ SKIPPED, because the run still ends "all N passed".
# Only a real "no" from the server (rc 1 — this caller genuinely may not impersonate) closes it.
IMPERSONATE_OK="false"
imp_rc=0
oc_read auth can-i impersonate serviceaccounts || imp_rc=$?
case "$imp_rc" in 0|2) IMPERSONATE_OK="true";; esac

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
    # PROD too — the lab governs BOTH namespaces (edit in dev, view in prod), so an entry state that
    # only asserts dev is half a check. This one was missing, and it was exactly the half that broke:
    # {user}-prod was not in purgeNamespaces, so the lab's `view` binding survived every reset and
    # payments-ci could still read pods in prod on the next run — while this script reported 10/10.
    # A green tick that only looks where the leftover isn't is the failure mode, not the leftover.
    check "payments-ci is ungoverned in ${PROD} (no view yet)" sa_cannot payments-ci "$PROD" get pods || hint "a leftover RoleBinding governs payments-ci in ${PROD} — ws reset multi-tenancy-workload-security --user ${USER_NAME} (purgeRbac now removes it)"
  fi
else
  # --- end state: the lab's OUTCOME — workload fixed + the team RBAC in place ----------------------
  # Assert OUTCOMES (the workload runs; effective permissions), never the mechanism (which RoleBinding
  # name / which securityContext field), so any correct solution stays green (template rule 14).
  check "root-demander is running (>=1 ready replica)"        deploy_ready root-demander             || hint "fix the workload (drop runAsUser:0) and scale up — or ws solve multi-tenancy-workload-security --user ${USER_NAME}"
  check "root-demander's pod actually runs as a NON-ROOT uid" root_demander_runs_nonroot            || hint "the pod runs, but not as a non-root uid — that is the scoped-SCC route ([INSTRUCTOR-DEMO]), not the fix. Drop runAsUser:0 from the pod spec so restricted-v2 assigns a uid from the namespace range: oc get pod -l app=root-demander -n ${NS} -o jsonpath='{.items[0].spec.containers[0].securityContext}'"
  if [[ "$IMPERSONATE_OK" == "true" ]]; then
    check "payments-ci can update Deployments in ${NS} (edit)"     sa_can payments-ci "$NS" update deployments      || hint "grant payments-ci edit in ${NS}: oc adm policy add-role-to-user edit -z payments-ci -n ${NS}"
    check "payments-ci can read pods in ${PROD} (view)"            sa_can payments-ci "$PROD" get pods              || hint "grant payments-ci view in ${PROD}: oc adm policy add-role-to-user view -z payments-ci -n ${PROD}"
    check "payments-ci CANNOT create Deployments in ${PROD} (view is read-only)" sa_cannot payments-ci "$PROD" create deployments || hint "in ${PROD} payments-ci must be view-only — do not grant it edit there"
    check "payments-ops can create Deployments in ${NS} (deployer Role)"  sa_can payments-ops "$NS" create deployments   || hint "bind the custom deployer Role to payments-ops in ${NS} (see the lab)"
    check "payments-ops CANNOT read Secrets in ${NS} (deployer excludes secrets)" sa_cannot payments-ops "$NS" get secrets || hint "the deployer Role must NOT grant secrets read — that's the least-privilege point"
  else
    warn "RBAC-outcome checks — caller cannot impersonate ServiceAccounts; run as admin/CI to grade them"
  fi
fi

verify_summary
