#!/usr/bin/env bash
# argocd-exclusions.sh — keep project.openshift.io/Project out of the openshift-gitops controller's cache.
#
# WHY. A projects LIST carries no resourceVersion (`metadata: {}`). client-go's RetryWatcher refuses to
# start from an empty one, so the controller's Project watch never opens and gitops-engine re-lists every
# project about once a second, forever — manifest-hashing each Argo-tracked one, and every Argo-managed
# Namespace's Project is tracked. Measured on a 30-attendee cluster (2026-11-13): ~1.1 of the controller's
# 2 cores and 60-80 MB/s of heap churn at idle; 0.02-0.06 cores and 1-3 MB/s with this rule. A Project is
# a read-only view of a Namespace — the portfolio and the workshop manage Namespaces, never Projects.
#
# Usage: argocd-exclusions.sh [--check]
#   (none)   append the rule to argocd/openshift-gitops .spec.resourceExclusions when absent (idempotent).
#            The CR's prior list is recorded FIRST, first-write-wins, in ogsr-system/ogsr-uninstall-state
#            so bootstrap/ogsr-uninstall.sh puts it back; if that record cannot be written, nothing is
#            patched. Refuses when a live Application manages a Project (excluding it would break that
#            app). The controller re-syncs its cache (~2-3 min); its pod does not restart.
#   --check  exit 0 when the rule is present, 1 when it is not. Changes nothing.
# Callers: install.sh in this directory (after the adopted-instance consent); by hand on a cluster that
# is already installed — a config change, not a reinstall.
set -euo pipefail

ARGO_NS="${ARGO_NS:-openshift-gitops}"
STATE_NS="${STATE_NS:-ogsr-system}"
STATE_CM="${STATE_CM:-ogsr-uninstall-state}"
export RULE='{"apiGroups":["project.openshift.io"],"clusters":["*"],"kinds":["Project"]}'

ok()  { echo "✅ $*"; }
err() { echo "❌ $*" >&2; }

command -v yq >/dev/null || { err "yq not found — install mikefarah yq v4 (brew install yq / dnf install yq)"; exit 1; }

live="$(oc get argocd openshift-gitops -n "$ARGO_NS" -o jsonpath='{.spec.resourceExclusions}')" \
  || { err "cannot read argocd/openshift-gitops in ${ARGO_NS} — is OpenShift GitOps installed, and are you cluster-admin?"; exit 1; }

excluded() {  # → 0 when a rule already covers project.openshift.io/Project
  printf '%s' "$live" | yq -e '[(. // [])[]
      | select((.apiGroups // []) | any_c(. == "project.openshift.io" or . == "*"))
      | select((.kinds // []) | any_c(. == "Project" or . == "*"))] | length > 0' >/dev/null 2>&1
}

if [[ "${1:-}" == "--check" ]]; then
  if excluded; then ok "argocd/openshift-gitops excludes project.openshift.io/Project"; exit 0; fi
  err "argocd/openshift-gitops caches project.openshift.io/Project — its controller re-lists every project each second."
  err "   fix (records the prior value; ogsr-uninstall.sh restores it): $0"
  exit 1
fi

if excluded; then
  ok "argocd/openshift-gitops already excludes project.openshift.io/Project — nothing to change"
  exit 0
fi

managing="$(oc get applications.argoproj.io -A -o json | yq -p=json '.items[]
    | select([.status.resources[]? | select(.group == "project.openshift.io" and .kind == "Project")] | length > 0)
    | .metadata.namespace + "/" + .metadata.name')"
if [[ -n "$managing" ]]; then
  err "not excluding project.openshift.io/Project: these Applications manage one, and would stop syncing it:"
  printf '%s\n' "$managing" | sed 's/^/     /' >&2
  exit 1
fi

# Record BEFORE mutating. An empty prior is recorded by the key's ABSENCE (the CR carried no list), which
# teardown restores by removing the field. A key a previous ogsr-uninstall carried forward (residue_keys)
# is already the org's original and is never re-derived from what is live now.
oc create namespace "$STATE_NS" >/dev/null 2>&1 || true
oc create configmap "$STATE_CM" -n "$STATE_NS" >/dev/null 2>&1 || true
prior="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o jsonpath='{.data.gitops_argocd_resource_exclusions_b64}')" \
  || { err "cannot read ${STATE_NS}/${STATE_CM} — NOT patching (teardown could not restore the prior list)"; exit 1; }
residue=" $(oc get configmap "$STATE_CM" -n "$STATE_NS" -o jsonpath='{.data.residue_keys}' | tr ',' ' ') "
if [[ -z "$prior" && "$residue" != *" gitops_argocd_resource_exclusions_b64 "* && -n "$live" ]]; then
  oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge \
    -p "{\"data\":{\"gitops_argocd_resource_exclusions_b64\":\"$(printf '%s' "$live" | base64 | tr -d '\n')\"}}" >/dev/null \
    || { err "could not record the prior resourceExclusions in ${STATE_NS}/${STATE_CM} — NOT patching"; exit 1; }
fi
oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge \
  -p '{"data":{"argocd_resource_exclusions_changed_by_us":"true"}}' >/dev/null \
  || { err "could not record the change in ${STATE_NS}/${STATE_CM} — NOT patching"; exit 1; }

new="$(printf '%s' "$live" | yq '(. // []) + [env(RULE)]')"
oc patch argocd openshift-gitops -n "$ARGO_NS" --type merge \
  -p "$(NEW="$new" yq -n -o=json -I0 '{"spec": {"resourceExclusions": strenv(NEW)}}')" >/dev/null
ok "argocd/openshift-gitops now excludes project.openshift.io/Project (prior list recorded — ogsr-uninstall.sh restores it)"
echo "   the controller re-syncs its cluster cache now (~2-3 min); its pod does not restart"
