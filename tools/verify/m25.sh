#!/usr/bin/env bash
# Verify M25 — Packaging & Distributing Your App (Helm/OLM).
#   Entry: {user}-dev holds the entry marker; the attendee has a Gitea fork {user}/parasol-notifications
#          (the Helm target) and a PREBUILT istag parasol-notifications:1.0 in {user}-dev, so `helm
#          install` has a pullable image. The platform-observer ClusterRole lets the attendee DISSECT a
#          live operator's OLM bundle (CSV/Subscription/InstallPlan/CRD) read-only. Nothing is deployed
#          yet — the attendee runs helm create/install/upgrade/rollback by hand.
#   End:   the notifications app is DEPLOYED to {user}-dev (Deployment parasol-notifications) — the
#          outcome of the Helm install lab.
# Runnable as the ATTENDEE: reads only {user}-dev objects (namespace admin), the attendee's own public
# Gitea fork over HTTPS (URL from the marker), and cluster-scoped OLM metadata via platform-observer
# (no peer-namespace reads). The G1 cockpit smoke runs `--entry-only` as {user}.
#
# BARE-NAME TRAP: fully-qualify subscriptions.operators.coreos.com and packagemanifests.packages.
# operators.coreos.com — bare `oc get subscription`/`packagemanifest` resolve to Knative's Subscription
# and another catalog's channels (live traps this script deliberately avoids).
# HELM + DISSECTION-TARGET are environment facts reported as INFO (never failed): the OCI-capable helm
# client lives in the cockpit image (the ws smoke gate hard-checks 'helm version'), and the recommended
# Pipelines dissection target is a PLATFORM install, not per-user entry state.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (oc + curl only) ------------------------------------------------

# A field from the entry marker (single source of truth for repo URL / image / dissection target).
marker() { oc get cm ws-entry-m25 -n "$NS" -o jsonpath="{.data.$1}" 2>/dev/null || true; }

# The prebuilt notifications istag exists in {user}-dev (helm install has something to pull).
istag_present() {
  local name tag; name="$(marker imageName)"; tag="$(marker imageTag)"
  [[ -n "$name" && -n "$tag" ]] || return 1
  oc get istag "${name}:${tag}" -n "$NS" >/dev/null 2>&1
}

# The attendee's notifications fork is reachable (public repo → anonymous HTTPS GET 200). Net-tolerant.
repo_reachable() {
  local u; u="$(marker notificationsRepo)"
  [[ -n "$u" ]] || return 1
  curl -ksf --max-time 10 "$u" >/dev/null 2>&1
}

# platform-observer OLM-dissection reads (fully-qualified — the bare kinds are live traps). As the
# attendee these prove the extended grant; as admin they are trivially true (the cockpit smoke is the
# authoritative attendee-perspective test).
observer_reads_csv() { oc auth can-i get clusterserviceversions.operators.coreos.com -n "$(marker dissectionOperatorNamespace)" >/dev/null 2>&1; }
observer_reads_crd() { oc auth can-i get customresourcedefinitions.apiextensions.k8s.io >/dev/null 2>&1; }

# Deployment presence in {user}-dev (the notifications app the finished lab leaves running).
deploy_present() { oc get deploy "$(marker imageName)" -n "$NS" >/dev/null 2>&1; }
no_deploy()      { ! oc get deploy "$(marker imageName)" -n "$NS" >/dev/null 2>&1; }

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                 || hint "run: ws prep m25 (or ws start m25 --user ${USER_NAME}); ${NS} is workshop-layer (per-user-namespaces)"
check "entry marker ws-entry-m25 present"               oc get cm ws-entry-m25 -n "$NS" || hint "entry app not synced — ws reset m25 --user ${USER_NAME}"
check "Helm target fork parasol-notifications reachable in Gitea" repo_reachable        || hint "the fork {user}/parasol-notifications is missing — check the gitea-fork Job (ws reset m25 --user ${USER_NAME}); needs parasol/parasol-notifications seeded (workshop-config app-repo-seed)"
check "prebuilt image istag $(marker imageName):$(marker imageTag) present in ${NS}" istag_present \
  || hint "the notifications image is not built — check the notifications-build Job (ws reset m25 --user ${USER_NAME}); inspect: oc logs -f bc/$(marker imageName) -n ${NS}"
check "platform-observer: attendee can read OLM ClusterServiceVersions (bundle dissection)" observer_reads_csv \
  || hint "extend platform-observer with operators.coreos.com {clusterserviceversions,subscriptions,installplans,operatorgroups} — gitops/workshop-config/templates/platform-observer-clusterrole.yaml, then sync workshop-config"
check "platform-observer: attendee can read CustomResourceDefinitions"                observer_reads_crd \
  || hint "extend platform-observer with apiextensions.k8s.io/customresourcedefinitions (get,list,watch)"

# INFO: the OCI-capable helm client (hard-checked by the cockpit smoke gate, not failed here so
# standalone/CI verify on a runner without helm stays green).
if command -v helm >/dev/null 2>&1; then
  info "helm client present: $(helm version --short 2>/dev/null || echo '?') (OCI push/pull needs >= 3.8)"
else
  info "helm not on THIS PATH — the attendee cockpit image ships it (ws smoke hard-checks 'helm version'); not required for standalone verify"
fi
# INFO: the recommended read-only dissection target is a platform install (not per-user entry state).
DTN="$(marker dissectionSubscriptionName)"; DTNS="$(marker dissectionOperatorNamespace)"
if [[ -n "$DTN" ]] && oc get subscriptions.operators.coreos.com "$DTN" -n "$DTNS" >/dev/null 2>&1; then
  info "dissection target readable: subscriptions.operators.coreos.com/${DTN} in ${DTNS} (the 'customer clicked your tile' chain)"
else
  info "dissection target ${DTN:-<unset>} not readable here — content may target another installed operator (GitOps/Serverless/…); dissection is read-only against whatever the cluster runs"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — the attendee has not installed the chart yet ------------------------
  check "no notifications app deployed yet (attendee runs helm install)" no_deploy \
    || hint "parasol-notifications is already deployed; the lab already ran — ws reset m25 --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — the notifications app deployed to {user}-dev --------------------
  # Assert the OUTCOME (a notifications Deployment is running), never the mechanism, so any correct
  # solution (helm install OR ws solve) stays green (rule 14).
  check "notifications app parasol-notifications deployed" deploy_present \
    || hint "install the chart (helm install parasol-notifications ./parasol-notifications -n ${NS}), or ws solve m25 --user ${USER_NAME}"
fi

verify_summary
