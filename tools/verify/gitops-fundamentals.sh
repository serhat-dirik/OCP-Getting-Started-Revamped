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
# route read (attendees cannot read routes in gitea/student-gitops). Only student_argo_up below still
# uses this local helper directly — gitea_host() (shared, tools/verify/_lib.sh) does its own ingress
# read internally and no longer calls out to it.
# ALWAYS returns 0 and signals failure with an empty string — deliberately, and unchanged from the
# `|| true` it replaces. Its one remaining caller assigns it (`domain="$(ingress_domain)"`), and under
# `set -e` an assignment whose command substitution exits non-zero kills the script.
ingress_domain() {
  oc_read get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' || OC_OUT=""
  printf '%s' "$OC_OUT"
}

# gitea_host() (route if readable, else derived from the cluster ingress domain — attendees cannot
# read routes in the gitea namespace) is shared — tools/verify/_lib.sh. GLOBAL, not echo-shaped: call
# it bare and read $GITEA_HOST, never `$(gitea_host)` (that would strand VERIFY_INCONCLUSIVE in a
# subshell).

# The per-user promotion fork exists → the Gitea API answers 2xx for {user}/claims-config.
fork_exists() {
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${USER_NAME}/claims-config"
}

# The dev overlay was personalized by the fork job → its kustomization sets namespace {user}-dev.
overlay_personalized() {
  gitea_host || return 1
  curl -ksf "https://${GITEA_HOST}/api/v1/repos/${USER_NAME}/claims-config/raw/overlays/dev/kustomization.yaml?ref=main" 2>/dev/null \
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

# --- the attendee's Argo CD ACCESS PLANE, not just the objects ---------------
# `/healthz` answers 200 anonymously and the AppProject exists as an object — neither says the
# ATTENDEE can log in and see anything. What actually gates their UI is two ConfigMaps in
# ogsr-student-gitops: argocd-cm must carry `accounts.{user}` (the local account exists) and
# argocd-rbac-cm's policy.csv must carry policy lines for {user} (that account is bound to
# proj-{user}). Drop either and the attendee lands on an EMPTY Argo CD while every object-exists
# check stays green. Both ConfigMaps are cross-namespace for an attendee (measured 2026-07-29:
# `can-i get configmaps -n ogsr-student-gitops --as=user1 --as-group=workshop-attendees` -> no), so
# this is an instructor/CI-side check: unreadable => INCONCLUSIVE (⚠), never ❌ (rule 10 — verify
# scripts run as the attendee; docs/module-template/README.md).
ARGO_NS="ogsr-student-gitops"

# ASK THE OBJECT, NOT A BARE EXISTENCE PROBE. The guard here used to be
# `oc get cm argocd-rbac-cm >/dev/null 2>&1`, whose failure cannot distinguish "the attendee may not
# read it" (a legitimate ⚠ skip) from "it was DELETED" — and deletion is exactly the failure the two
# checks below exist to catch. Both landed in the ⚠ branch, so a wiped access plane reported as an
# inconclusive skip on a workshop where every attendee would have logged in to an empty Argo CD.
# Classify the server's answer instead (same pattern as jobs-batch-kueue's ClusterQueue guard):
# Forbidden => not this identity's check; anything else, NotFound included, means the caller CAN ask,
# so a missing ConfigMap falls through and fails loudly where it should.
argo_access_plane_err() { { oc get cm argocd-rbac-cm -n "$ARGO_NS" -o name >/dev/null; } 2>&1 || true; }

# Both reached only via the Forbidden-vs-anything-else guard above, so "unreadable" is already handled;
# what oc_read adds here is that a ConfigMap the API could not be asked about no longer reads as a
# DELETED access plane — which is the very distinction the guard's own comment says must not collapse.
argo_account_exists() {
  oc_read get cm argocd-cm -n "$ARGO_NS" -o jsonpath="{.data.accounts\\.${USER_NAME}}" || return 1
  [[ -n "$OC_OUT" ]]
}

argo_rbac_binds_user() {
  oc_read get cm argocd-rbac-cm -n "$ARGO_NS" -o jsonpath='{.data.policy\.csv}' || return 1
  [[ "$OC_OUT" == *"proj-${USER_NAME}"* ]]
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# deploy_ready_min (<deployment> <namespace> <n>) is shared — tools/verify/_lib.sh (>=, never ==).

# The Deployment carries the Argo CD tracking annotation → it is GitOps-managed by the student
# instance (annotation tracking), NOT applied by hand — the point of gitops-fundamentals vs the config-multienv hand-config.
deploy_gitops_managed() {
  oc_read get deploy "$1" -n "$2" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' || return 1
  [[ -n "$OC_OUT" ]]
}

# Deployment does NOT exist (entry-only: dev/stage start empty). Namespace must exist first —
# otherwise "absent" is vacuous, not evidence of a clean entry state.
# `! oc get … >/dev/null 2>&1` was the same blind read as `2>/dev/null`, just spelled differently, and
# in the one direction that matters most: it certified an empty dev/stage from an API that never
# answered, and a wrongly-green entry check sends `ws prep` down its "already prepared" fast path.
deploy_absent() {
  oc_present get ns "$2" -o name || return 1
  oc_absent get deploy "$1" -n "$2" -o name
}

# The claims Route answers HTTP 200 on the readiness endpoint (also proves DB connectivity, since
# readiness gates on the datasource). API-only service: "/" is 404 by design.
route_ready_200() {
  local ns="$1" host code
  oc_read get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# --- entry state (what `ws start gitops-fundamentals` materializes) --------------------------
check "namespace ${GITOPS} exists"                       oc get ns "$GITOPS"                                 || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-gitops-fundamentals in ${GITOPS}"           oc get cm ws-entry-gitops-fundamentals -n "$GITOPS"                 || hint "entry app not synced — ws start gitops-fundamentals --user ${USER_NAME}"
check "student-gitops Argo CD instance reachable"        student_argo_up                                     || hint "student instance missing — sync the workshop-config Argo app (student-argocd.yaml)"
check "AppProject proj-${USER_NAME} exists"              oc get appproject "proj-${USER_NAME}" -n ogsr-student-gitops || hint "per-user AppProject missing — sync workshop-config (student-appprojects.yaml)"
# The object above is not the outcome — the attendee LOGGING IN and seeing it is.
case "$(argo_access_plane_err)" in
  *orbidden*)
    warn "Argo CD access plane (account + RBAC policy) not readable as this identity"
    hint "argocd-cm/argocd-rbac-cm live in ogsr-student-gitops, which attendees cannot read — run this check as the instructor/CI identity, or confirm by logging in to the student Argo CD as ${USER_NAME}"
    ;;
  *)
    check "Argo CD account accounts.${USER_NAME} exists (attendee can log in)"  argo_account_exists  || hint "no local Argo account for ${USER_NAME} — the attendee's login is rejected; sync workshop-config (student-argocd.yaml, .spec.extraConfig accounts.${USER_NAME}: login)"
    check "Argo CD RBAC binds ${USER_NAME} to proj-${USER_NAME}"                argo_rbac_binds_user || hint "argocd-rbac-cm policy.csv has no proj-${USER_NAME} lines (or the ConfigMap is gone) — the attendee logs in to an EMPTY Argo CD; sync workshop-config (student-argocd.yaml rbac.policy)"
    ;;
esac
check "Gitea fork ${USER_NAME}/claims-config exists"     fork_exists                                         || hint "fork job didn't run — ws reset gitops-fundamentals --user ${USER_NAME} (or check gitea-fork-gitops-fundamentals-${USER_NAME} Job in ns gitea)"
check "dev overlay personalized to ${DEV}"               overlay_personalized                                || hint "fork not personalized — ws reset gitops-fundamentals --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove dev/stage start EMPTY (the attendee's Application deploys the app in the lab).
  check "no parasol-claims in ${DEV} yet (clean)"        deploy_absent parasol-claims "$DEV"                 || hint "dev already has the app — ws reset gitops-fundamentals --user ${USER_NAME} for a clean entry"
  check "no parasol-claims in ${STAGE} yet (clean)"      deploy_absent parasol-claims "$STAGE"               || hint "stage already has the app — ws reset gitops-fundamentals --user ${USER_NAME} for a clean entry"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  # The old wording here named the platform-enrollment failure ("managed-by is broken, see
  # troubleshooting") in the same breath as the ordinary not-done-yet case, on checks that are red for
  # everybody who has not written their Argo Application yet — which is the whole cohort at exercise 1.
  # Naming the alarming cause first is how a correct ❌ gets escalated to an instructor for nothing.
  check "claims-db ready in ${DEV}"                      deploy_ready claims-db "$DEV"                       || hint "not done yet? ${DEV} starts EMPTY on purpose — your Argo Application is what deploys claims-db, so this red is the expected state before you create it. If your Application EXISTS, look at it in the student Argo UI: Synced/Healthy means look at pods (oc get pods -n ${DEV}); OutOfSync/Degraded means the Application, not this check"
  check "parasol-claims ready in ${DEV}"                 deploy_ready parasol-claims "$DEV"                  || hint "not done yet? creating your Argo Application (overlays/dev) on student-gitops IS the lab, so this red is expected before you do it (ws solve gitops-fundamentals --user ${USER_NAME} creates it for you). If the Application exists and is stuck OutOfSync with a permissions error, that one is real — the platform enrollment (managed-by) may be missing; see the module's troubleshooting page"
  check "dev claims is GitOps-managed (Argo tracking)"   deploy_gitops_managed parasol-claims "$DEV"         || hint "the app is there but Argo is not tracking it — so it was applied by hand (oc apply / oc new-app) rather than deployed by an Application. Not broken, just not the lesson: delete it and let your Argo Application create it, which is the point of gitops-fundamentals"
  check "route parasol-claims answers 200 in ${DEV}"     route_ready_200 "$DEV"                              || hint "not done yet? until the app above is deployed there is nothing to answer, so this red follows from that one. If parasol-claims IS ready and the Route still does not answer 200, that one is real: oc get pods -n ${DEV}; oc get route parasol-claims -n ${DEV}"
  check "parasol-claims promoted to ${STAGE} (>=2 replicas)" deploy_ready_min parasol-claims "$STAGE" 2     || hint "not done yet — ${STAGE} starts EMPTY and promoting to it is a later exercise (add a second Application pointed at overlays/stage; ws solve gitops-fundamentals --user ${USER_NAME} does this), so this red is expected until you get there"
fi

verify_summary
