#!/usr/bin/env bash
# check-adoption-skip — prove the two properties automatic component adoption rests on.
# READ-ONLY: renders manifests with kustomize, never touches a cluster.
#
#   SAFETY   argocd-bootstrap/install.sh §0 SKIPS a component when this cluster already runs that
#            operator, but only if the component is "operator-only" — it contributes nothing but the
#            operator install. That verdict comes from is_operator_only(), which reads FILENAMES.
#            This check re-derives it from the RENDERED manifests: every resource an operator-only
#            component emits must be a Namespace, an OperatorGroup or a Subscription. A stray operand
#            in a file called subscription-extra.yaml would pass the filename test and fail here,
#            which is exactly the drift that would ship a silently incomplete workshop.
#
#   MECHANICS A skip is delivered as a kustomize `$patch: delete` on the parent Application, not by
#            editing the repo. This check renders every stack with each of its skippable components
#            simulated as skipped and asserts the child Application is GONE and every other child
#            survives byte-identically. `$patch: delete` is a strategic-merge directive; the JSON6902
#            form cannot delete a resource, and a silent no-op patch would install the operator we
#            just promised the cluster's owner we would not touch.
#
# Usage: ./hack/check-adoption-skip.sh
# Exit 0 = both properties hold. Exit 1 = violations listed above. Exit 2 = missing tooling.
set -euo pipefail

PORTFOLIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS_DIR="${PORTFOLIO_DIR}/stacks"
REPO_ROOT="$(cd "${PORTFOLIO_DIR}/.." && pwd)"
ARGO_NS="openshift-gitops"
FAILURES=0

# The installer's own classifier and patch renderer — sourced, never re-implemented.
# shellcheck disable=SC1091  # lib-components.sh is linted standalone; its path is runtime-derived
. "${PORTFOLIO_DIR}/argocd-bootstrap/lib-components.sh"

ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
hint() { echo "     ↳ $*"; }

for tool in kustomize yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "❌ ${tool} not found in PATH — install it, then re-run"; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Kinds an operator-only component is allowed to render. Anything else is an operand, config or
# workload the workshop would silently lose if the component were skipped.
OPERATOR_ONLY_KINDS='^(Namespace|OperatorGroup|Subscription)/'

echo "▶ [1/2] operator-only components render nothing but namespace + OperatorGroup + Subscription"
SKIPPABLE=""   # "<stack> <apps-file> <component> <child-app>" per skippable component
for stack_dir in "${STACKS_DIR}"/*/; do
  stack="$(basename "$stack_dir")"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    # `|| true` is what makes the next line reachable. component_path_of is a grep|sed pipeline, so
    # under `set -o pipefail` an app file with no `path:` fails the substitution and `set -e` kills
    # the run HERE — the "no path, skip it" guard below never gets to execute. Same silent-death class
    # as the one that skipped uninstall steps 4-8 on 2026-07-25 (fix 8722a79).
    cpath="$(component_path_of "$stack" "$app" || true)"
    [[ -n "$cpath" ]] || continue
    cdir="${REPO_ROOT}/${cpath}"
    comp="$(basename "$cpath")"
    child="$(yaml_scalar "${STACKS_DIR}/${stack}/${app}" metadata name)"
    [[ -n "$child" ]] || child="pp-${comp}"
    is_operator_only "$cdir" || continue
    SKIPPABLE="${SKIPPABLE}${SKIPPABLE:+$'\n'}${stack} ${app} ${comp} ${child}"

    if ! rendered="$(kustomize build --enable-helm "$cdir" 2>/dev/null)"; then
      bad "${comp}: classified operator-only but kustomize build fails"
      continue
    fi
    printf '%s\n' "$rendered" \
      | yq -r '[(.kind // "?"), (.metadata.name // "?")] | join("/")' - > "${WORK}/kinds.txt"
    offenders="$(grep -vE "$OPERATOR_ONLY_KINDS" "${WORK}/kinds.txt" || true)"
    if [[ -n "$offenders" ]]; then
      bad "${comp}: classified operator-only, but renders $(printf '%s' "$offenders" | tr '\n' ' ')"
      hint "install.sh §0 would DROP this component on a cluster that already runs the operator,"
      hint "taking those resources with it. Either move them to their own component, or rename the"
      hint "file so is_operator_only() stops matching (lib-components.sh)."
    else
      ok "${comp} (stack ${stack}) — skippable, renders only operator install resources"
    fi
  done < <(active_app_files "$stack")
done
[[ -n "$SKIPPABLE" ]] || bad "no skippable component found at all — is_operator_only() matches nothing"

# yq emits a `---` separator between documents and prints `null` for an empty stream, so the raw
# name list needs normalising before two renders can be compared.
app_names() {  # <kustomize dir> → one child Application name per line
  # awk, not grep -vE: BSD grep rejects an empty alternative, so `---|null|` is not portable.
  kustomize build "$1" 2>/dev/null \
    | yq -r '.metadata.name' - \
    | awk '$0 != "" && $0 != "---" && $0 != "null"'
}

echo "▶ [2/2] a simulated skip removes exactly one child Application from the rendered stack"
while read -r stack app comp child; do
  [[ -n "$stack" ]] || continue
  : "$app"
  rm -rf "${WORK}/sim"; mkdir -p "${WORK}/sim"
  cp -R "${STACKS_DIR}/${stack}" "${WORK}/sim/"
  simdir="${WORK}/sim/${stack}"

  before="$(app_names "${STACKS_DIR}/${stack}")"
  if [[ -z "$before" ]]; then
    bad "${stack}: renders no child Applications at all"; continue
  fi
  # Exactly what install.sh §2 hands Argo CD in spec.source.kustomize.patches. Argo appends those to
  # the stack's kustomization, which is what this reproduces.
  { echo "patches:"; skip_patch_block "$child" "$comp" "simulated skip" "$ARGO_NS"; } \
    >> "${simdir}/kustomization.yaml"
  if ! kustomize build "$simdir" >/dev/null 2>&1; then
    bad "${stack}/${comp}: kustomize build fails WITH the skip patch"
    hint "the \$patch: delete block in lib-components.sh no longer renders — see skip_patch_block()"
    continue
  fi
  after="$(app_names "$simdir")"

  expected="$(printf '%s\n' "$before" | grep -vx "$child" || true)"
  if printf '%s\n' "$after" | grep -qx "$child"; then
    bad "${stack}/${comp}: ${child} SURVIVED the skip patch — the operator would still be installed"
    hint "\$patch: delete must be a strategic-merge patch; JSON6902 cannot delete a resource"
  elif [[ "$after" != "$expected" ]]; then
    bad "${stack}/${comp}: the skip patch changed other children of the stack"
    hint "expected: $(printf '%s' "$expected" | tr '\n' ' ')"
    hint "rendered: $(printf '%s' "$after"    | tr '\n' ' ')"
  else
    ok "${stack}: skipping ${comp} removes ${child} and leaves $(printf '%s\n' "$after" | grep -c . ) sibling(s) untouched"
  fi
done <<< "$SKIPPABLE"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "✅ automatic component adoption is safe across the portfolio"
  exit 0
fi
echo "❌ ${FAILURES} violation(s) — see platform-portfolio/README.md § Adoption"
exit 1
