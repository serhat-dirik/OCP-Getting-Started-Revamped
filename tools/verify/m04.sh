#!/usr/bin/env bash
# Verify M04 — Config, Secrets & Multi-Environment.
#   Entry: {user}-dev has the claims app + PostgreSQL (naive: inline env, no probes/resources);
#          entry markers in dev/stage/prod; workshop quota; a per-user Gitea fork of the
#          claims-config promotion repo. With --entry-only, also asserts stage/prod start empty.
#   End:   dev claims app is externalized (references a claims-config ConfigMap AND a
#          claims-creds Secret), carries all three probes and explicit resource requests; the
#          app is promoted to stage (2 replicas, APP_ENV=stage) and prod (3 replicas,
#          APP_ENV=prod). End checks are mechanism-agnostic: they pass for BOTH the attendee's
#          `oc set env --from` wiring (per-key valueFrom) AND `ws solve`'s envFrom wiring.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
DEV="${USER_NAME}-dev"
STAGE="${USER_NAME}-stage"
PROD="${USER_NAME}-prod"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea host discovered from the cluster ingress domain so the script stays
# environment-agnostic and needs no cross-namespace route read (attendees cannot
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

# The per-user promotion fork exists → the Gitea API answers 2xx for {user}/claims-config.
fork_exists() {
  local host; host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${USER_NAME}/claims-config"
}

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# Deployment reports exactly N ready replicas (proves the per-env replica delta).
deploy_ready_count() {
  local name="$1" ns="$2" want="$3" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ "$ready" == "$want" ]]
}

# Deployment does NOT exist (entry-only: stage/prod start empty).
deploy_absent() {
  ! oc get deploy "$1" -n "$2" >/dev/null 2>&1
}

# The claims Route answers HTTP 200 on the readiness endpoint (also proves DB connectivity,
# since readiness gates on the datasource). API-only service: "/" is 404 by design.
route_ready_200() {
  local ns="$1" host code
  host="$(oc get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# The dev Deployment references a resource (ConfigMap/Secret) by name anywhere in its
# container env/envFrom — matches both `envFrom` (solve) and per-key `valueFrom` (attendee).
deploy_references() {
  local name="$1" ns="$2" ref="$3"
  oc get deploy "$name" -n "$ns" -o json 2>/dev/null \
    | grep -q "\"name\": \"${ref}\""
}

# The dev Deployment carries all three probes.
deploy_has_all_probes() {
  local name="$1" ns="$2" p
  for p in startupProbe readinessProbe livenessProbe; do
    oc get deploy "$name" -n "$ns" -o jsonpath="{.spec.template.spec.containers[0].${p}}" 2>/dev/null | grep -q . || return 1
  done
}

# The dev Deployment sets an explicit CPU request (not just the LimitRange default).
deploy_has_requests() {
  oc get deploy "$1" -n "$2" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null | grep -q .
}

# The claims-config ConfigMap in a namespace carries APP_ENV=<want> (the per-env config marker).
cm_app_env() {
  local ns="$1" want="$2" got
  got="$(oc get configmap claims-config -n "$ns" -o jsonpath='{.data.APP_ENV}' 2>/dev/null || true)"
  [[ "$got" == "$want" ]]
}

# --- entry state (what `ws start m04` materializes) --------------------------
check "namespace ${DEV} exists"                        oc get ns "$DEV"                            || hint "run: ws start m04 --user ${USER_NAME}"
check "namespace ${STAGE} exists"                      oc get ns "$STAGE"                          || hint "workshop layer not applied — run bootstrap/install.sh"
check "namespace ${PROD} exists"                       oc get ns "$PROD"                           || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-m04 in ${DEV}"            oc get cm ws-entry-m04 -n "$DEV"            || hint "entry app not synced — ws start m04 --user ${USER_NAME}"
check "entry marker ws-entry-m04 in ${STAGE}"          oc get cm ws-entry-m04 -n "$STAGE"          || hint "entry app not synced — ws start m04 --user ${USER_NAME}"
check "entry marker ws-entry-m04 in ${PROD}"           oc get cm ws-entry-m04 -n "$PROD"           || hint "entry app not synced — ws start m04 --user ${USER_NAME}"
check "workshop quota present in ${DEV}"               oc get resourcequota workshop-quota -n "$DEV" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea fork ${USER_NAME}/claims-config exists"   fork_exists                                 || hint "fork job didn't run — ws reset m04 --user ${USER_NAME} (or check the gitea-fork-m04-${USER_NAME} Job in ns gitea)"
check "claims-db deployment ready in ${DEV}"           deploy_ready claims-db "$DEV"               || hint "wait for rollout: oc rollout status deploy/claims-db -n ${DEV}"
check "parasol-claims deployment ready in ${DEV}"      deploy_ready parasol-claims "$DEV"          || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${DEV}"
check "route parasol-claims answers 200 in ${DEV}"     route_ready_200 "$DEV"                      || hint "claims app not ready — check: oc get pods -n ${DEV}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove stage/prod start EMPTY (they fill in during the promotion exercise).
  check "no parasol-claims in ${STAGE} yet (clean)"    deploy_absent parasol-claims "$STAGE"       || hint "stage already has the app — ws reset m04 --user ${USER_NAME} for a clean entry"
  check "no parasol-claims in ${PROD} yet (clean)"     deploy_absent parasol-claims "$PROD"        || hint "prod already has the app — ws reset m04 --user ${USER_NAME} for a clean entry"
else
  # --- end state (what a completed lab looks like) ---------------------------
  # dev: config externalized to a ConfigMap + a Secret, all three probes, explicit resources.
  check "dev claims-config ConfigMap exists"           oc get configmap claims-config -n "$DEV"    || hint "create it — lab exercise 2 (oc create configmap claims-config ...)"
  check "dev claims-creds Secret exists"               oc get secret claims-creds -n "$DEV"        || hint "create it — lab exercise 3 (oc create secret generic claims-creds ...)"
  check "dev app references the ConfigMap"             deploy_references parasol-claims "$DEV" claims-config || hint "wire it — lab exercise 2 (oc set env deploy/parasol-claims --from=configmap/claims-config)"
  check "dev app references the Secret"                deploy_references parasol-claims "$DEV" claims-creds  || hint "wire it — lab exercise 3 (oc set env deploy/parasol-claims --from=secret/claims-creds)"
  check "dev app has all three probes"                 deploy_has_all_probes parasol-claims "$DEV" || hint "add them — lab exercise 4 (oc set probe --startup/--readiness/--liveness)"
  check "dev app sets explicit resource requests"      deploy_has_requests parasol-claims "$DEV"   || hint "set them — lab exercise 5 (oc set resources deploy/parasol-claims --requests=... --limits=...)"
  # promotion: same image, different config, in stage and prod.
  check "stage parasol-claims ready (2 replicas)"      deploy_ready_count parasol-claims "$STAGE" 2 || hint "promote — lab exercise 6 (oc apply -k overlays/stage from your claims-config fork)"
  check "stage config is APP_ENV=stage"                cm_app_env "$STAGE" stage                   || hint "the stage overlay sets APP_ENV=stage — re-apply overlays/stage"
  check "prod parasol-claims ready (3 replicas)"       deploy_ready_count parasol-claims "$PROD" 3  || hint "promote — lab exercise 6 (oc apply -k overlays/prod from your claims-config fork)"
  check "prod config is APP_ENV=prod"                  cm_app_env "$PROD" prod                     || hint "the prod overlay sets APP_ENV=prod — re-apply overlays/prod"
fi

verify_summary
