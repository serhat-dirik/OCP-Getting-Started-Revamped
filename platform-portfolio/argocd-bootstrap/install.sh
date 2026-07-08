#!/usr/bin/env bash
# Platform Portfolio bootstrap — the ONLY imperative step of the portfolio.
# Does exactly two things: (1) install the OpenShift GitOps operator (+ controller RBAC),
# (2) apply one Argo CD Application per requested stack. Everything else reconciles.
#
# Usage:
#   ./install.sh --stacks core-devtools[,ai-assist,...]
#                [--repo-url <git url>] [--revision <branch|tag>] [--wait] [--dry-run]
#
# Idempotent: safe to re-run; re-running with more stacks adds them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/serhat-dirik/OCP-Getting-Started-Revamped}"
REVISION="${REVISION:-main}"
STACKS=""
WAIT="false"
DRY_RUN="false"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -12; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stacks)   STACKS="$2"; shift 2;;
    --repo-url) REPO_URL="$2"; shift 2;;
    --revision) REVISION="$2"; shift 2;;
    --wait)     WAIT="true"; shift;;
    --dry-run)  DRY_RUN="true"; shift;;
    -h|--help)  usage;;
    *) echo "❌ unknown flag: $1"; usage;;
  esac
done
[[ -n "$STACKS" ]] || { echo "❌ --stacks is required (e.g. --stacks core-devtools)"; usage; }

APPLY=(oc apply -f -)
[[ "$DRY_RUN" == "true" ]] && APPLY=(oc apply --dry-run=client -f -)

echo "▶ Platform Portfolio bootstrap"
echo "  cluster : $(oc whoami --show-server) (as $(oc whoami))"
echo "  source  : ${REPO_URL} @ ${REVISION}"
echo "  stacks  : ${STACKS}"

# ── 1. GitOps operator ────────────────────────────────────────────────────────
echo "▶ [1/2] Installing OpenShift GitOps operator (idempotent)…"
if [[ "$DRY_RUN" == "true" ]]; then
  oc kustomize "${SCRIPT_DIR}/operator" >/dev/null && echo "  ✓ operator kustomization renders"
else
  # Pre-installed detection: many managed/demo clusters ship GitOps already. Applying our
  # OperatorGroup next to an existing one breaks OLM (TooManyOperatorGroups) — reuse instead.
  if oc get subscription openshift-gitops-operator -n openshift-gitops-operator >/dev/null 2>&1; then
    echo "  ✓ operator subscription already present — reusing existing install"
  else
    oc apply -k "${SCRIPT_DIR}/operator"
  fi
  echo "  … waiting for operator CSV to succeed (up to 5m)"
  for _ in $(seq 1 60); do
    CSV="$(oc get subscription openshift-gitops-operator -n openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    [[ -n "$CSV" ]] && PHASE="$(oc get csv "$CSV" -n openshift-gitops-operator -o jsonpath='{.status.phase}' 2>/dev/null || true)" || PHASE=""
    [[ "$PHASE" == "Succeeded" ]] && break
    sleep 5
  done
  [[ "${PHASE:-}" == "Succeeded" ]] || { echo "❌ GitOps operator CSV not ready after 5m (phase: ${PHASE:-none}). Check: oc get csv -n openshift-gitops-operator"; exit 1; }
  echo "  ✓ operator ready: ${CSV}"

  echo "  … waiting for default Argo CD instance (openshift-gitops) to be available (up to 5m)"
  for _ in $(seq 1 60); do
    AVL="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$AVL" == "Available" ]] && break
    sleep 5
  done
  [[ "${AVL:-}" == "Available" ]] || { echo "❌ Argo CD instance not Available after 5m. Check: oc get argocd -n openshift-gitops"; exit 1; }
  echo "  ✓ Argo CD instance available"

  # The portfolio manages cluster-scoped resources (namespaces, operators, RBAC),
  # so the default instance's application-controller needs cluster-admin.
  oc apply -f "${SCRIPT_DIR}/operator/controller-rbac.yaml"
  echo "  ✓ controller RBAC applied"
fi

# ── 2. Stack Applications ─────────────────────────────────────────────────────
echo "▶ [2/2] Applying stack Applications…"
IFS=',' read -ra STACK_ARR <<< "$STACKS"
for stack in "${STACK_ARR[@]}"; do
  stack="$(echo "$stack" | xargs)"  # trim
  if [[ ! -d "${SCRIPT_DIR}/../stacks/${stack}" ]]; then
    echo "❌ unknown stack '${stack}' (no stacks/${stack}/ directory)"; exit 1
  fi
  sed -e "s|__STACK__|${stack}|g" \
      -e "s|__REPO_URL__|${REPO_URL}|g" \
      -e "s|__REVISION__|${REVISION}|g" \
      "${SCRIPT_DIR}/stack-app.template.yaml" | "${APPLY[@]}"
  echo "  ✓ Application pp-${stack} applied"
done

# ── Optionally wait for health ────────────────────────────────────────────────
if [[ "$WAIT" == "true" && "$DRY_RUN" != "true" ]]; then
  echo "▶ Waiting for stacks to become Healthy (up to 20m)…"
  for _ in $(seq 1 120); do
    UNHEALTHY=0
    for stack in "${STACK_ARR[@]}"; do
      H="$(oc get application "pp-$(echo "$stack" | xargs)" -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || echo Missing)"
      [[ "$H" == "Healthy" ]] || UNHEALTHY=$((UNHEALTHY+1))
    done
    [[ "$UNHEALTHY" -eq 0 ]] && { echo "✅ all stacks Healthy"; break; }
    sleep 10
  done
  [[ "${UNHEALTHY:-1}" -eq 0 ]] || { echo "⚠ some stacks not Healthy yet — inspect: oc get applications -n openshift-gitops"; exit 2; }
fi

echo "✅ bootstrap complete — reconciliation continues in-cluster."
echo "   Watch: oc get applications -n openshift-gitops"
