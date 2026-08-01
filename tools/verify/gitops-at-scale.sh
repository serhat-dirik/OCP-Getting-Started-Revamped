#!/usr/bin/env bash
# Verify gitops-at-scale — GitOps at Scale & Progressive Delivery.
#   Entry: {user}-gitops workspace ns + entry marker · the student-gitops Argo CD instance is
#          reachable · the attendee's proj-{user} AppProject exists · a per-user Gitea fork of
#          claims-config that ALSO carries the gitops-at-scale source (rollouts/ overlay personalized to
#          {user}-prod + applicationset.yaml) · the per-user analysis prereqs in {user}-prod
#          (claims-analysis SA + gitops-at-scale-canary-control knob) · AND the gitops-fundamentals END STATE materialized:
#          claims runs GitOps-managed in {user}-dev + {user}-stage (gitops-at-scale starts where gitops-fundamentals ended, so
#          gitops-at-scale is independent). Entry leaves {user}-prod WITHOUT the Rollout (converting prod to a
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

# Every oc read below goes through _lib.sh's oc_read/oc_present/oc_absent rather than `2>/dev/null`,
# which cannot tell "the object is not there" (a gradeable ❌) from "the cluster did not answer" (a ⚠
# that is never the attendee's fault). Predicates return 1 for both, and oc_read raises
# VERIFY_INCONCLUSIVE so check() picks the right one.

# Cluster ingress domain — attendee-readable; used to derive route hosts without a cross-namespace
# route read (attendees cannot read routes in gitea/student-gitops).
#
# GLOBAL, not echo-shaped, and that is the whole point. The old twin of this was
# `d="$(ingress_domain)"`, which runs the oc read inside a SUBSHELL: the VERIFY_INCONCLUSIVE oc_read
# raises in there dies with the subshell, so every caller downstream graded an unreachable cluster as
# a red ❌ on the attendee's work. Signal raised and dropped — the same trap SC2034 names, one costume
# over. Setting INGRESS_DOMAIN in the CALLER's shell is what keeps the flag where check() can see it.
# (It also removes the `set -e` hazard the echo shape was working around: nothing here is assigned
# from a command substitution any more.)
INGRESS_DOMAIN=""
read_ingress_domain() {  # → 0 + INGRESS_DOMAIN set; 1 with the flag raised when the API could not be asked
  oc_read get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' || return 1
  INGRESS_DOMAIN="$OC_OUT"
  [[ -n "$INGRESS_DOMAIN" ]]
}

# Gitea host: route if readable, else derived from the ingress domain (route "gitea" in ns "ogsr-gitea").
# Global for the same reason as above.
GITEA_HOST=""
read_gitea_host() {  # → 0 + GITEA_HOST set; 1 when the host could not be determined
  GITEA_HOST=""
  # oc_read_OPTIONAL, not oc_read: this route read is a best-effort SHORTCUT, and an attendee is
  # EXPECTED to be refused it (rule 10 — routes in ogsr-gitea are not theirs to read). Its refusal
  # must not become this check's verdict, because the ingress-domain fallback below answers the same
  # question perfectly well. See _lib.sh, oc_read_optional — a module clearing the shared flag itself
  # would be inventing a flag-lifecycle rule in the wrong file.
  if oc_read_optional get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' && [[ -n "$OC_OUT" ]]; then
    GITEA_HOST="$OC_OUT"
    return 0
  fi
  read_ingress_domain || return 1
  GITEA_HOST="gitea-ogsr-gitea.${INGRESS_DOMAIN}"
}

# Every HTTP probe below goes through _lib.sh's http_read, which gives curl the same three outcomes
# oc_read gives `oc`: a status code is a graded answer, a transport failure asks the cluster API
# whether it is only this app that is down (❌) or the whole cluster (⚠, never the attendee's fault).

# The per-user promotion fork exists → the Gitea API answers 2xx for {user}/claims-config.
fork_exists() {
  read_gitea_host || return 1
  http_read "https://${GITEA_HOST}/api/v1/repos/${USER_NAME}/claims-config" --max-time 15 || return 1
  # < 400 mirrors the `curl -f` this check used before, to the status code. A 404 — no fork — is the
  # graded ❌ this check exists to produce, and it stays one: a 404 IS the server answering.
  [[ "$HTTP_CODE" -lt 400 ]]
}

# The fork carries a raw file whose contents match a pattern (proves the gitops-at-scale source + personalization).
fork_file_matches() {
  local path="$1" pattern="$2"
  read_gitea_host || return 1
  http_read "https://${GITEA_HOST}/api/v1/repos/${USER_NAME}/claims-config/raw/${path}?ref=main" --max-time 15 || return 1
  [[ "$HTTP_CODE" -lt 400 ]] || return 1
  grep -q "$pattern" <<<"$HTTP_OUT"
}

# The student-gitops Argo CD instance is reachable on its route (derived host; /healthz → 200).
student_argo_up() {
  read_ingress_domain || return 1
  http_read "https://student-gitops-server-student-gitops.${INGRESS_DOMAIN}/healthz" --max-time 15 || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# --- the attendee's Argo CD ACCESS PLANE, not just the objects ---------------
# `/healthz` answers 200 anonymously and the AppProject exists as an object — neither says the
# ATTENDEE can log in and see anything. The real gates are argocd-cm's `accounts.{user}` (the local
# account) and argocd-rbac-cm's policy.csv lines binding it to proj-{user}. Drop either and the
# attendee lands on an EMPTY Argo CD while every object-exists check stays green. Both ConfigMaps are
# cross-namespace for an attendee (measured 2026-07-29), so unreadable => INCONCLUSIVE (⚠), never ❌
# (rule 10 — verify scripts run as the attendee; docs/module-template/README.md).
ARGO_NS="ogsr-student-gitops"

# ASK THE OBJECT, NOT A BARE EXISTENCE PROBE. The guard here used to be
# `oc get cm argocd-rbac-cm >/dev/null 2>&1`, whose failure cannot distinguish "the attendee may not
# read it" (a legitimate ⚠ skip) from "it was DELETED" — and deletion is exactly the failure the two
# checks below exist to catch. Both landed in the ⚠ branch, so a wiped access plane reported as an
# inconclusive skip on a workshop where beat 1's `argocd login` would have been rejected outright.
# Classify the server's answer instead (same pattern as jobs-batch-kueue's ClusterQueue guard):
# Forbidden => not this identity's check; anything else, NotFound included, means the caller CAN ask,
# so a missing ConfigMap falls through and fails loudly where it should.
argo_access_plane_err() { { oc get cm argocd-rbac-cm -n "$ARGO_NS" -o name >/dev/null; } 2>&1 || true; }

argo_account_exists() {
  oc_read get cm argocd-cm -n "$ARGO_NS" -o jsonpath="{.data.accounts\\.${USER_NAME}}" || return 1
  [[ -n "$OC_OUT" ]]
}

argo_rbac_binds_user() {
  oc_read get cm argocd-rbac-cm -n "$ARGO_NS" -o jsonpath='{.data.policy\.csv}' || return 1
  grep -q "proj-${USER_NAME}" <<<"$OC_OUT"
}

# The student server serves its own argocd CLI (gitops-at-scale beat 1 downloads it — Argo 3.4 has no appset UI,
# so the attendee creates the ApplicationSet via the CLI). A byte-range probe, not a ~300MB pull.
cli_download_ready() {
  read_ingress_domain || return 1
  # -r 0-1 is what keeps this a byte-range probe rather than a ~300MB pull — and, with http_read
  # slurping the body into HTTP_OUT, what keeps that variable two bytes wide.
  http_read "https://student-gitops-server-student-gitops.${INGRESS_DOMAIN}/download/argocd-linux-amd64" \
    --max-time 15 -r 0-1 || return 1
  [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "206" ]]
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# deploy_ready_min (<deployment> <namespace> <n>) is shared — tools/verify/_lib.sh (>=, never ==).

# The Deployment carries the Argo CD tracking annotation → it is GitOps-managed by the student instance.
deploy_gitops_managed() {
  oc_read get deploy "$1" -n "$2" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' || return 1
  [[ -n "$OC_OUT" ]]
}

# A named Rollout is present AND Healthy (also proves the cluster RolloutManager is serving it).
rollout_healthy() {
  local name="$1" ns="$2"
  oc_read get rollout "$name" -n "$ns" -o jsonpath='{.status.phase}' || return 1
  [[ "$OC_OUT" == "Healthy" ]]
}

# A named Rollout is ABSENT (entry-only: prod starts without the Rollout — converting it is the lab).
# Namespace must exist first — otherwise "absent" is vacuous, not evidence of a clean entry state.
# oc_absent, never `! oc get … 2>/dev/null`: a negation built on a silenced read certifies a clean slate
# from an API that never answered, and a wrongly-green ENTRY check sends `ws prep` down its
# "already prepared" fast path (_lib.sh, oc_absent's own header).
rollout_absent() {
  oc_present get ns "$2" -o name || return 1
  oc_absent get rollout "$1" -n "$2" -o name
}

# The claims Route answers HTTP 200 on the readiness endpoint (also proves DB connectivity).
route_ready_200() {
  local ns="$1" host
  oc_read get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  http_read "http://${host}/q/health/ready" --max-time 15 || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# --- entry state (what `ws start gitops-at-scale` materializes) --------------------------
check "namespace ${GITOPS} exists"                       oc get ns "$GITOPS"                                 || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-gitops-at-scale in ${GITOPS}"           oc get cm ws-entry-gitops-at-scale -n "$GITOPS"                 || hint "entry app not synced — ws start gitops-at-scale --user ${USER_NAME}"
check "student-gitops Argo CD instance reachable"        student_argo_up                                     || hint "student instance missing — sync workshop-config (student-argocd.yaml)"
check "argocd CLI served for the appset-create beat"     cli_download_ready                                   || hint "server not serving /download/argocd-linux-amd64 — check the student-gitops server route"
check "AppProject proj-${USER_NAME} exists"              oc get appproject "proj-${USER_NAME}" -n ogsr-student-gitops || hint "per-user AppProject missing — sync workshop-config (student-appprojects.yaml)"
# The object above is not the outcome — the attendee logging in AND being able to create the
# ApplicationSet into proj-{user} is (this module's whole beat 1).
case "$(argo_access_plane_err)" in
  *orbidden*)
    warn "Argo CD access plane (account + RBAC policy) not readable as this identity"
    hint "argocd-cm/argocd-rbac-cm live in ogsr-student-gitops, which attendees cannot read — run this check as the instructor/CI identity, or confirm by running the beat-1 argocd login as ${USER_NAME}"
    ;;
  *)
    check "Argo CD account accounts.${USER_NAME} exists (attendee can log in)"  argo_account_exists  || hint "no local Argo account for ${USER_NAME} — the argocd CLI login in beat 1 is rejected; sync workshop-config (student-argocd.yaml, .spec.extraConfig accounts.${USER_NAME}: login)"
    check "Argo CD RBAC binds ${USER_NAME} to proj-${USER_NAME}"                argo_rbac_binds_user || hint "argocd-rbac-cm policy.csv has no proj-${USER_NAME} lines (or the ConfigMap is gone) — the ApplicationSet create is denied and the UI is empty; sync workshop-config (student-argocd.yaml rbac.policy)"
    ;;
esac
check "Gitea fork ${USER_NAME}/claims-config exists"     fork_exists                                         || hint "fork job didn't run — ws reset gitops-at-scale --user ${USER_NAME} (or check gitea-fork-gitops-at-scale-${USER_NAME} Job in ns gitea)"
check "fork carries rollouts/ overlay (prod-personalized)" fork_file_matches "rollouts/kustomization.yaml" "namespace: ${PROD}" || hint "fork missing gitops-at-scale source — ws reset gitops-at-scale --user ${USER_NAME}"
check "fork carries applicationset.yaml (personalized)"  fork_file_matches "applicationset.yaml" "proj-${USER_NAME}"            || hint "fork missing the ApplicationSet source — ws reset gitops-at-scale --user ${USER_NAME}"
check "analysis SA claims-analysis in ${PROD}"           oc get sa claims-analysis -n "$PROD"                || hint "analysis prereq missing — ws reset gitops-at-scale --user ${USER_NAME}"
check "canary knob gitops-at-scale-canary-control in ${PROD}"        oc get cm gitops-at-scale-canary-control -n "$PROD"             || hint "analysis knob missing — ws reset gitops-at-scale --user ${USER_NAME}"
# gitops-at-scale entry = the gitops-fundamentals END STATE: claims GitOps-managed in dev + stage (gitops-at-scale starts where gitops-fundamentals ended).
check "claims-db ready in ${DEV}"                        deploy_ready claims-db "$DEV"                       || hint "gitops-fundamentals end state not materialized — ws reset gitops-at-scale --user ${USER_NAME}"
check "parasol-claims ready in ${DEV}"                   deploy_ready parasol-claims "$DEV"                  || hint "gitops-fundamentals end state not materialized — ws reset gitops-at-scale --user ${USER_NAME}"
check "dev claims is GitOps-managed (Argo tracking)"     deploy_gitops_managed parasol-claims "$DEV"         || hint "dev claims should be deployed by the student instance — ws reset gitops-at-scale --user ${USER_NAME}"
check "parasol-claims ready in ${STAGE} (>=2 replicas)"  deploy_ready_min parasol-claims "$STAGE" 2          || hint "gitops-fundamentals end state not materialized in stage — ws reset gitops-at-scale --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove {user}-prod does NOT yet run the Rollout (converting prod is the lab).
  check "no parasol-claims Rollout in ${PROD} yet (clean)" rollout_absent parasol-claims "$PROD"             || hint "prod already has the Rollout — ws reset gitops-at-scale --user ${USER_NAME} for a clean entry"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  check "parasol-claims runs as a Rollout in ${PROD} (Healthy)" rollout_healthy parasol-claims "$PROD"       || hint "convert prod to a Rollout (rollouts/ overlay); ws solve gitops-at-scale does this — needs the cluster RolloutManager"
  check "route parasol-claims answers 200 in ${PROD}"     route_ready_200 "$PROD"                            || hint "prod claims not ready — check the Rollout: oc argo rollouts get rollout parasol-claims -n ${PROD}"
fi

verify_summary
