#!/usr/bin/env bash
# Offline manifest readers shared by argocd-bootstrap/install.sh (§0 adoption preflight) and
# hack/check-adoption-skip.sh (the CI invariant check). Nothing here touches a cluster.
#
# It lives in one file for one reason: the installer's decision to SKIP a component and the check
# that proves skipping is safe must be the same code. Two implementations would drift, and the way
# they would drift is a component quietly gaining an operand while the installer still thinks it is
# safe to drop — which ships an incomplete workshop.
#
# grep/sed/awk only, no yq: the portfolio installer must run on a box carrying nothing but oc.
#
# Callers must set STACKS_DIR (…/platform-portfolio/stacks) before using the stack readers.
#
# shellcheck disable=SC2317,SC2329  # sourced library: every function is called by its consumers
# (SC2329 on shellcheck >= 0.10, SC2317 on 0.9.x — CI pins 0.9.0, so both names are needed.)

kustomize_resources() {  # <kustomization.yaml> → each entry under `resources:`
  # Reads the resources list rather than globbing the directory: several stacks ship an app file that
  # is deliberately COMMENTED OUT (loki-logging, service-interconnect), and preflighting a component
  # we will never apply would refuse — or worse, silently skip — an install for no reason.
  awk '
    /^resources:[[:space:]]*$/           { inres = 1; next }
    /^[A-Za-z0-9_.-]+:/                  { inres = 0 }
    inres && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); sub(/[[:space:]]+$/, "")
      if ($0 != "") print
    }' "$1" 2>/dev/null
}

yaml_scalar() {  # <file> <top-level block> <key> → the first `  <key>: value` inside that block
  # Subscriptions carry `name:` twice at the same indent (metadata.name = the object, spec.name = the
  # PACKAGE), so a plain grep would conflate them. Block-scoped, single-document files only.
  awk -v blk="$2" -v key="$3" '
    $0 ~ "^" blk ":"                        { in_blk = 1; next }
    /^[A-Za-z0-9_.-]+:/                     { in_blk = 0 }
    in_blk && $0 ~ "^  " key ":[[:space:]]" {
      sub("^  " key ":[[:space:]]*", ""); gsub(/"/, ""); sub(/[[:space:]]*$/, ""); print; exit
    }' "$1" 2>/dev/null
}

active_app_files() {  # <stack> → each apps/*.yaml the stack's kustomization actually includes
  kustomize_resources "${STACKS_DIR}/${1}/kustomization.yaml" \
    | grep -E '^apps/[A-Za-z0-9._-]+\.yaml$' || true
}

component_path_of() {  # <stack> <apps/x.yaml> → the component path that child Application syncs
  grep -m1 -E '^[[:space:]]+path:[[:space:]]' "${STACKS_DIR}/${1}/${2}" 2>/dev/null \
    | sed 's|.*path:[[:space:]]*||'
}

component_operatorgroup_namespaces() {  # <component-dir> → namespace of each OperatorGroup it ships
  local dir="$1" og ns
  for og in "${dir}"/operatorgroup*.yaml; do
    [[ -e "$og" ]] || continue
    ns="$(yaml_scalar "$og" metadata namespace)"
    [[ -n "$ns" ]] && echo "$ns"
  done
}

component_subscriptions() {  # <component-dir> → "<sub-name> <namespace> <package>" per Subscription
  local dir="$1" f name ns pkg
  for f in "${dir}"/subscription*.yaml; do
    [[ -e "$f" ]] || continue
    name="$(yaml_scalar "$f" metadata name)"
    ns="$(yaml_scalar "$f" metadata namespace)"
    pkg="$(yaml_scalar "$f" spec name)"
    [[ -n "$name" && -n "$ns" ]] || continue
    echo "${name} ${ns} ${pkg:-$name}"
  done
}

is_operator_only() {  # <component-dir> — true when the component installs an operator AND NOTHING ELSE
  # THE safety rule behind automatic adoption. Skipping a component that also ships operand CRs,
  # config, Jobs or RBAC would silently drop things the workshop needs; skipping one that is only
  # namespace + OperatorGroup + Subscription loses nothing but an operator install we did not need.
  # Derived from the directory every time — never a hardcoded list, which would rot the first time a
  # component grows an operand. hack/check-adoption-skip.sh proves the same verdict against the
  # RENDERED manifests, so a stray operand hidden in a subscription-*.yaml cannot slip past.
  local dir="$1" f rel
  [[ -f "${dir}/kustomization.yaml" ]] || return 1
  compgen -G "${dir}/subscription*.yaml" >/dev/null || return 1   # installs no operator at all
  # `namespace*.yaml` also covers the plural: namespaces.yaml is namespace + s + .yaml.
  while IFS= read -r f; do
    rel="${f#"${dir}/"}"
    case "$rel" in
      kustomization.yaml|README.md) ;;
      namespace*.yaml|operatorgroup*.yaml|subscription*.yaml) ;;
      *) return 1 ;;
    esac
  done < <(find "$dir" -type f 2>/dev/null)
  # A `resources:` entry that is not a local file (a remote base, another component) pulls in
  # manifests the file scan above cannot see.
  while IFS= read -r rel; do
    case "$rel" in
      namespace*.yaml|operatorgroup*.yaml|subscription*.yaml) ;;
      *) return 1 ;;
    esac
  done < <(kustomize_resources "${dir}/kustomization.yaml")
  # Same reasoning for generators and overlays: they emit resources no glob would show.
  if grep -qE '^(helmCharts|configMapGenerator|secretGenerator|components|crds|bases|patches|patchesStrategicMerge|patchesJson6902|generators|resources:[[:space:]]*\[)' \
       "${dir}/kustomization.yaml"; then
    return 1
  fi
  return 0
}

skip_patch_block() {  # <child-app> <component> <reason> <argo-namespace> → one kustomize patch entry
  # A strategic-merge patch carrying `$patch: delete` removes the targeted resource from the render.
  # It has to be the merge form: JSON6902 has no "delete this resource" operation. Indented for the
  # `kustomize.patches:` list of stack-app.template.yaml (list items at 8 spaces).
  printf '        # Adopted: %s is already installed on this cluster — %s.\n' "$2" "$3"
  printf '        # The child Application is deleted from the render, so nothing of the org%ss is touched.\n' "'"
  printf '        - target:\n'
  printf '            kind: Application\n'
  printf '            name: %s\n' "$1"
  printf '          patch: |-\n'
  printf '            apiVersion: argoproj.io/v1alpha1\n'
  printf '            kind: Application\n'
  printf '            metadata:\n'
  printf '              name: %s\n' "$1"
  printf '              namespace: %s\n' "$4"
  # `$patch` is a kustomize strategic-merge DIRECTIVE, not a shell variable — it must stay literal.
  # shellcheck disable=SC2016
  printf '            $patch: delete\n'
}
