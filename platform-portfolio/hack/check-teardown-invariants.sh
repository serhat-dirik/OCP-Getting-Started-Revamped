#!/usr/bin/env bash
# check-teardown-invariants — assert the two portfolio-wide properties an unattended uninstall
# depends on. READ-ONLY: renders manifests with kustomize, never touches a cluster.
#
#   ORDERING   Argo CD applies resources in ascending sync-wave order and prunes in descending order.
#              An operand CR pruned in the same wave as (or after) the operator that reconciles it
#              leaves its finalizer stranded with no controller to run it, and the namespace hangs in
#              Terminating forever. That wedged 8 namespaces on 2026-07-25 —
#              ogsr-observability-workshop had to be cleared by hand because TempoMonolithic/traces
#              still held tempo.grafana.com/finalizer after the Tempo operator was already gone.
#
#   VISIBILITY bootstrap/ogsr-uninstall.sh discovers the namespaces a component creates by globbing
#              namespace*.yaml / namespaces*.yaml inside the component directory. A namespace
#              manifest with any other filename is invisible to teardown and survives it. That is
#              precisely how ogsr-observability-workshop escaped: its manifest was called
#              observability-namespace.yaml.
#
# The wave vocabulary is documented in platform-portfolio/README.md § Sync waves; keep the two in step.
#
# Usage: ./hack/check-teardown-invariants.sh
# Exit 0 = both invariants hold. Exit 1 = violations listed above. Exit 2 = missing tooling.
set -euo pipefail

PORTFOLIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
hint() { echo "     ↳ $*"; }

for tool in kustomize yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "❌ ${tool} not found in PATH — install it, then re-run"; exit 2; }
done

# Wave the vocabulary assigns to each structural class. Keep in step with README § Sync waves.
WAVE_NAMESPACE="-2"
WAVE_CONTROLLER="0"
WAVE_OPERAND_MIN="2"

# API groups whose objects are NEVER an operand of an operator this portfolio installs, so they are
# exempt from the "operands live at wave >= 2" rule. Two reasons a group lands here: it is plain
# Kubernetes/OpenShift infrastructure (core, apps, rbac…), or its controller is a cluster component
# we never install and never remove (ODF/NooBaa for ObjectBucketClaim, the Node Tuning Operator for
# Tuned), so its finalizer always has someone to run it. Add to this list only with that reasoning.
INFRA_GROUPS="
admissionregistration.k8s.io
apiextensions.k8s.io
apps
autoscaling
batch
discovery.k8s.io
monitoring.coreos.com
networking.k8s.io
objectbucket.io
operators.coreos.com
policy
rbac.authorization.k8s.io
route.openshift.io
scheduling.k8s.io
security.openshift.io
tuned.openshift.io
"

is_infra_group() {
  case "
${INFRA_GROUPS}" in *"
$1
"*) return 0 ;; esac
  return 1
}

# Emit "<group>|<kind>|<name>|<wave>" for every rendered resource. A resource with no sync-wave
# annotation is reported as wave 0, which is exactly how Argo CD treats it. The group is the
# apiVersion up to the slash ("" for core/v1), split here rather than in yq so the expression stays
# readable.
render() {
  kustomize build --enable-helm "$1" 2>/dev/null \
    | yq -r '[(.apiVersion // ""), (.kind // "?"), (.metadata.name // "?"),
              (.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0")] | join("|")' - \
    | while IFS='|' read -r api kind name wave; do
        [[ -n "$kind" ]] || continue
        case "$api" in */*) group="${api%%/*}" ;; *) group="" ;; esac
        echo "${group}|${kind}|${name}|${wave}"
      done
}

echo "▶ teardown invariants (namespace ${WAVE_NAMESPACE} · controller ${WAVE_CONTROLLER} · operand >= ${WAVE_OPERAND_MIN})"

# ── 0. namespace manifests are discoverable by teardown ───────────────────────
echo "▶ [0/4] namespace manifests are named so teardown can find them"
while IFS= read -r nsfile; do
  case "$(basename "$nsfile")" in
    namespace*.yaml) ;;   # also matches namespaces.yaml / namespaces-*.yaml — the * covers the plural
    *)
      bad "$(basename "$(dirname "$nsfile")")/$(basename "$nsfile") declares a Namespace"
      hint "rename it to namespace-<something>.yaml — ogsr-uninstall.sh globs namespace*.yaml and"
      hint "cannot see any other filename, so that namespace would survive a complete uninstall" ;;
  esac
done < <(grep -rl '^kind: Namespace' "${PORTFOLIO_DIR}/components" --include='*.yaml' 2>/dev/null | sort)
[[ "$FAILURES" -eq 0 ]] && ok "every Namespace manifest matches the teardown glob"

# ── 1. components ─────────────────────────────────────────────────────────────
echo "▶ [1/4] components"
for dir in "${PORTFOLIO_DIR}"/components/*/; do
  [[ -f "${dir}kustomization.yaml" ]] || continue
  comp="$(basename "$dir")"
  if ! rendered="$(render "$dir")"; then
    bad "${comp}: kustomize build failed"; continue
  fi
  # A component that ships no Subscription installs no operator, so the operand rule cannot apply:
  # its resources are plain workloads whose only controller is Kubernetes itself.
  has_sub="no"
  grep -q '^operators.coreos.com|Subscription|' <<<"$rendered" && has_sub="yes"
  problems=0
  while IFS='|' read -r group kind name wave; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      Namespace)
        [[ "$wave" == "$WAVE_NAMESPACE" ]] && continue
        bad "${comp}: Namespace/${name} is wave ${wave}, must be ${WAVE_NAMESPACE}"
        hint "a namespace deleted before the operands inside it takes their finalizers with it"
        problems=1; continue ;;
      OperatorGroup|Subscription)
        [[ "$wave" == "$WAVE_CONTROLLER" ]] && continue
        bad "${comp}: ${kind}/${name} is wave ${wave}, must be ${WAVE_CONTROLLER}"
        problems=1; continue ;;
    esac
    [[ "$has_sub" == "yes" ]] || continue
    is_infra_group "$group" && continue
    if [[ "$wave" -lt "$WAVE_OPERAND_MIN" ]]; then
      bad "${comp}: ${kind}/${name} (${group}) is wave ${wave}, operands must be >= ${WAVE_OPERAND_MIN}"
      hint "at wave ${wave} it is deleted no later than its operator, stranding its finalizer"
      problems=1
    fi
  done <<<"$rendered"
  [[ "$problems" -eq 0 ]] && ok "${comp}"
done

# ── 2. child Applications carry a wave ────────────────────────────────────────
echo "▶ [2/4] child Applications declare an app-of-apps wave"
for app in "${PORTFOLIO_DIR}"/stacks/*/apps/*.yaml; do
  [[ -e "$app" ]] || continue
  name="$(yq -r '.metadata.name // "?"' "$app")"
  wave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave" // "MISSING"' "$app")"
  if [[ "$wave" == "MISSING" ]]; then
    bad "${name}: no sync-wave (stacks/$(basename "$(dirname "$(dirname "$app")")")/apps/$(basename "$app"))"
    hint 'add: argocd.argoproj.io/sync-wave: "0"  — see README § Sync waves'
  fi
done
[[ "$FAILURES" -eq 0 ]] && ok "every child Application declares a wave"

# ── 3. operand Applications outrank their operator Applications ───────────────
# Cross-app pairs only: where the operand CR ships in a DIFFERENT Application from the operator that
# reconciles it, the operand's Application must carry the higher wave so it is deleted first.
# "operator-app:operand-app" — extend when a new stack splits an operator from its operand.
echo "▶ [3/4] operand Applications outrank their operator Applications"
PAIRS="
pp-keycloak-operator:pp-keycloak
pp-rhdh-operator:pp-rhdh
pp-rhacs-operator:pp-rhacs-central
pp-service-mesh:pp-kiali
pp-tempo:pp-opentelemetry
pp-cluster-observability-operator:pp-loki-logging
"
app_wave() {
  local target="$1" f
  for f in "${PORTFOLIO_DIR}"/stacks/*/apps/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(yq -r '.metadata.name // ""' "$f")" == "$target" ]] || continue
    yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave" // "MISSING"' "$f"
    return 0
  done
  echo "NOTFOUND"
}
while IFS=':' read -r operator_app operand_app; do
  [[ -n "$operator_app" ]] || continue
  wop="$(app_wave "$operator_app")"; wnd="$(app_wave "$operand_app")"
  if [[ "$wop" == "NOTFOUND" || "$wnd" == "NOTFOUND" ]]; then
    bad "${operand_app}/${operator_app}: one of the pair no longer exists — update the PAIRS table"
    continue
  fi
  if [[ "$wnd" -gt "$wop" ]]; then
    ok "${operand_app} (wave ${wnd}) deletes before ${operator_app} (wave ${wop})"
  else
    bad "${operand_app} is wave ${wnd}, must be greater than ${operator_app} (wave ${wop})"
    hint "otherwise ${operator_app} can be torn down while ${operand_app}'s CRs still hold finalizers"
  fi
done <<<"$PAIRS"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "✅ teardown invariants hold across the portfolio"
  exit 0
fi
echo "❌ ${FAILURES} violation(s) — see platform-portfolio/README.md § Sync waves"
exit 1
