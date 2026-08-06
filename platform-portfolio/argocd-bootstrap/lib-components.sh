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
  # Reads the resources list rather than globbing the directory: a stack may ship an app file that is
  # deliberately COMMENTED OUT (today: observability/apps/loki-logging.yaml — capacity-gated), and
  # preflighting a component we will never apply would refuse — or worse, silently skip — an install
  # for no reason.
  #
  # Globbing apps/*.yaml instead is NOT equivalent, and the difference is a safety property, not a
  # tidiness one: bootstrap/install.sh's snapshot_operators() and bootstrap/ogsr-uninstall.sh's
  # enumerate_operators() DO glob, so they attribute a commented-out component's operators to us and
  # record op_<sub>=created:<ns> for operators that were never installed (verified on a live cluster
  # 2026-08-05: op_loki-operator/op_cluster-logging recorded created while neither namespace existed).
  # `created:` is the sole authorization csv_delete_authorized_by_state() consults before deleting a
  # CSV, so a false one licenses deleting an operator the ORG later installs under the same standard
  # name. Any new consumer must use active_app_files(), never a glob.
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

# ── namespace-strand detection (SHARED by install.sh §0 and hack/check-adoption-skip.sh) ──────────
# Skipping an operator-only component on an adopted cluster drops its child Application from the
# render. That is safe for the operator install itself — but NOT when the component is the ONLY thing
# that creates a namespace (or scopes an OperatorGroup to one) that a component we do NOT skip deploys
# into. The sibling then syncs resources into a namespace nothing creates, or operand CRs into a
# namespace nothing gives a controller: Argo reports Synced/Healthy and nothing ever reconciles. The
# live case is keycloak — components/keycloak-operator/namespace.yaml is the sole creator of
# `sso-workshop`, and sibling `keycloak` ships six resources into it while creating none of its own.
#
# component_strands() is the SINGLE source of truth for that verdict, so the installer and the CI gate
# can never hold two opinions. It reads a flat fact table — the "component snapshot" — that each caller
# builds its own way: the installer with the grep/sed/awk readers below (nothing but oc + this file),
# the CI gate from RENDERED manifests with yq (so drift a filename cannot show is still caught). Both
# then feed the SAME detector. One line per fact, "<verb> <component> <value>":
#   creates <comp> <ns>   the component creates a Namespace of that name
#   ogns    <comp> <ns>   it scopes an OperatorGroup to that namespace
#   uses    <comp> <ns>   it places a resource there (child App destination, or a manifest namespace)
#   opts    <comp> <csv>  the child App's syncOptions, "-" when none (CreateNamespace=true self-heals)
#   pkg     <comp> <name> an OLM package the component subscribes to (spec.name, not the Subscription's)
# Pure awk over text — no yq — so the verdict runs anywhere `oc` does.

_fact_has() {  # <facts-file> <verb> <component> <value> → true when that exact fact was recorded
  awk -v v="$2" -v c="$3" -v n="$4" '$1 == v && $2 == c && $3 == n { found = 1 } END { exit !found }' "$1"
}

component_strands() {  # <facts-file> <component> → one strand per line, empty when skipping is safe
  # "NS <ns> <sibling>"  a sibling deploys into a namespace only this component creates
  # "OG <ns> <sibling>"  a sibling's operand CRs sit in a namespace only this component scopes a group to
  # The OG rule is asserted separately, not folded into the NS one: an operand CR left in an existing
  # namespace with no controller fails MORE quietly than a resource in a namespace that never appears.
  local facts="$1" s="$2" ns sib opts
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    while IFS= read -r sib; do
      [[ -n "$sib" && "$sib" != "$s" ]] || continue
      # `if`, not `cond && continue`: as the last statement of a bare-called function the short-circuit
      # form makes the function's status the test's, and under `set -e` that silently skipped
      # cleanup_created_operators' steps 4-8 on 2026-07-25 (CLAUDE.md). Spelled out to stay immune.
      if _fact_has "$facts" creates "$sib" "$ns"; then continue; fi   # sibling creates the namespace itself
      opts="$(awk -v c="$sib" '$1 == "opts" && $2 == c { print $3; exit }' "$facts")"
      case ",${opts}," in *",CreateNamespace=true,"*) continue ;; esac   # child App self-provisions it
      echo "NS ${ns} ${sib}"
    done < <(awk -v n="$ns" '$1 == "uses" && $3 == n { print $2 }' "$facts" | sort -u)
  done < <(awk -v c="$s" '$1 == "creates" && $2 == c { print $3 }' "$facts" | sort -u)
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    while IFS= read -r sib; do
      [[ -n "$sib" && "$sib" != "$s" ]] || continue
      if _fact_has "$facts" ogns "$sib" "$ns"; then continue; fi   # sibling ships its own OperatorGroup
      echo "OG ${ns} ${sib}"
    done < <(awk -v n="$ns" '$1 == "uses" && $3 == n { print $2 }' "$facts" | sort -u)
  done < <(awk -v c="$s" '$1 == "ogns" && $2 == c { print $3 }' "$facts" | sort -u)
}

# ── operator watch-scope detection (for adoption that hands our operands to the ORG's operator) ───
# component_strands() above answers "would skipping this component leave a sibling with no namespace
# or no OperatorGroup?". These answer the question that comes NEXT, and only matters once a component
# is skipped in favour of an operator the organisation already installed:
#
#     does the org's operator actually WATCH the namespace our operand CRs land in?
#
# It is not rhetorical. An operator reconciles only the namespaces its OperatorGroup resolves to. Point
# our CRs at a namespace outside that set and they apply cleanly, Argo reports Synced/Healthy, and
# nothing ever reconciles them — quieter than a missing namespace and quieter than a missing group,
# because every object exists and every status is green. Adoption is correct ONLY when the answer is
# yes; anything else must refuse loudly, exactly as install.sh §0 already refuses a strand.
#
# THE SNAPSHOT. Pure text, one line per ClusterServiceVersion, built by the caller with one `oc` read
# (the installer's fifth; nothing here touches a cluster). Four `|`-separated fields:
#
#     <csv-namespace>|<csv-name>|<olm.targetNamespaces>|<label keys, each comma-TERMINATED>
#
# Built with the go-template below — a strict superset of install.sh's CSV_SNAPSHOT, which is the same
# line with field 3 removed. (Merging the two costs one character: csvs_for_package_in() would read $4
# where it reads $3.)
#
#   oc get clusterserviceversions.operators.coreos.com -A -o go-template='{{range .items}}{{.metadata.namespace}}|{{.metadata.name}}|{{index .metadata.annotations "olm.targetNamespaces"}}|{{range $k, $v := .metadata.labels}}{{$k}},{{end}}{{"\n"}}{{end}}'
#
# WHY THE CSV AND NOT THE OperatorGroup. The OperatorGroup carries the scope but not the identity —
# answering "does the org's rhbk-operator watch us?" from OperatorGroups needs a join, and the join is
# where a wrong answer hides. The CSV carries BOTH: which operator, and the scope OLM actually resolved
# for it. Measured 2026-08-06 on a live 4.22 cluster running three separate rhbk-operator installs.
#
# THE FOUR SHAPES OF FIELD 3, ALL MEASURED ON THAT CLUSTER — the parse is not inferred, it is observed:
#   "keycloak"        an explicit scope; comma-separated when there is more than one namespace.
#                     (org's RHBK: `keycloak|rhbk-operator.v26.4.14-opr.1|keycloak|…`)
#   ""                EMPTY STRING = AllNamespaces. The annotation is PRESENT and empty.
#                     (`gitea-operator|gitea-operator.v2.1.0||…`, likewise rhacs, web-terminal.)
#   "<no value>"      go-template's rendering of an ABSENT key. Scope unknown → treated as NOT covering
#                     anything. Fail closed: guessing "probably all namespaces" here would hand our
#                     operands to an operator that cannot see them, which is the exact silent failure.
#   any of the above, with `olm.copiedFrom` among the label keys — a COPY of someone else's CSV, which
#                     OLM propagates into every watched namespace. Never classify from a copy: it is
#                     evidence that an operator watches THIS namespace, but it is not the install, and
#                     its annotation is absent anyway. Discarded before the scope is ever read.
#
# WHY NOT `spec.targetNamespaces` — the trap this parse exists to avoid. It is EMPTY for AllNamespaces
# *and* empty for a label-selector OperatorGroup, and those mean opposite things. Measured on the same
# cluster: `openshift-monitoring/openshift-cluster-monitoring` has an empty spec.targetNamespaces, a
# `spec.selector.matchLabels`, and a resolved `status.namespaces` of 58 explicit namespaces. Reading
# spec would call it cluster-wide. Only the RESOLVED scope (status.namespaces, or equivalently the
# CSV's olm.targetNamespaces annotation) is the truth.

CSV_SCOPE_UNKNOWN='<no value>'   # go-template's output for an absent annotation — never a valid namespace name

operator_install_scopes() {  # <csv-watch-table> <package> → "<ns>/<csv> <scope>" per install ("*" = all)
  # Diagnostics for the refusal message, so it can say WHICH namespaces theirs actually watches instead
  # of only that it does not watch ours. Prefix-matched on the package marker OLM stamps on every CSV it
  # manages (operators.coreos.com/<package>.<namespace>), so it finds the org's install whatever they
  # named their Subscription — and cannot collide with a longer package name, because the search string
  # ends at the '.' that separates package from namespace.
  awk -F'|' -v key=",operators.coreos.com/${2}." -v unknown="$CSV_SCOPE_UNKNOWN" '
    index("," $4, key)             == 0 { next }   # not an install of this package
    index("," $4, ",olm.copiedFrom,") > 0 { next }   # a propagated copy, not the install
    { print $1 "/" $2, ($3 == "" ? "*" : ($3 == unknown ? "?" : $3)) }' "$1" | sort -u
}

operator_installs_watching() {  # <csv-watch-table> <package> <target-ns> → "<ns>/<csv>" per COVERING install
  # Empty output is the load-bearing answer: nothing on this cluster runs that package with a scope
  # that reaches <target-ns>, so adopting it would strand our operands with no controller. Callers test
  # for emptiness rather than a status, matching component_strands() above.
  awk -F'|' -v key=",operators.coreos.com/${2}." -v want="$3" -v unknown="$CSV_SCOPE_UNKNOWN" '
    index("," $4, key)             == 0 { next }
    index("," $4, ",olm.copiedFrom,") > 0 { next }
    $3 == unknown                        { next }   # scope not resolvable → not covering (fail closed)
    $3 == ""                             { print $1 "/" $2; next }   # AllNamespaces covers everything
    {
      n = split($3, t, ",")
      for (i = 1; i <= n; i++) if (t[i] == want) { print $1 "/" $2; break }
    }' "$1" | sort -u
}

# ── THE skippability rule (SHARED by install.sh §0 and hack/check-adoption-skip.sh) ───────────────
# A component may be dropped on an adopting cluster when BOTH hold:
#
#   1. it renders only operator-install resources           → is_operator_only(), above
#   2. every namespace our operands occupy is still covered → component_skip_blockers(), here
#
# Rule 1 alone is what shipped until 2026-08-06, and it is purely SYNTACTIC: it asks "does this
# directory contain anything but Namespace/OperatorGroup/Subscription?". Nothing in it asks the
# question that actually decides whether dropping the component leaves a working cluster —
#
#     after we drop it, is anything still going to reconcile the operands we DO install?
#
# keycloak-operator is the measured counter-example. It is operator-only, so rule 1 called it
# skippable and adoption dropped it whenever ANY rhbk-operator existed anywhere on the cluster. But it
# installs rhbk-operator into sso-workshop with spec.targetNamespaces: [sso-workshop] — an
# OwnNamespace-scoped operator whose entire job is to reconcile OUR Keycloak CR — and it is the sole
# creator of that namespace. An organisation's rhbk-operator scoped to THEIR namespace can never
# reconcile ours: rhbk-operator publishes AllNamespaces=false and MultiNamespace=false on every
# channel it ships, so their OperatorGroup resolves to exactly one namespace and it is not ours.
#
# THE TWO BLOCKER CLASSES, and why they are not the same kind of thing:
#   NS  a sibling deploys into a namespace only this component creates. UNCONDITIONAL. No operator's
#       watch scope, however wide, causes a Namespace object to exist — an adopted operator cannot
#       create the namespace it would watch.
#   OG  a sibling places resources in a namespace only this component scopes an OperatorGroup to.
#       CONDITIONAL: it is cleared, and only cleared, by proof that an operator already on the cluster
#       watches that namespace — which is exactly what operator_installs_watching() measures.
#
# The proof is a CLUSTER fact, so the two callers reach different (and correctly different) verdicts
# from the SAME rule: the installer passes the live CSV watch table and can clear an OG blocker;
# hack/check-adoption-skip.sh has no cluster, passes none, and therefore clears nothing. Unprovable
# falls to NOT skippable in both, which is the safe direction — a component wrongly KEPT installs an
# operator the cluster did not need, a component wrongly SKIPPED ships a half-installed workshop whose
# every Argo status is green.

component_packages() {  # <facts-file> <component> → each OLM package the component subscribes to
  awk -v c="$2" '$1 == "pkg" && $2 == c { print $3 }' "$1" | sort -u
}

component_skip_blockers() {  # <facts> <comp> [<csv-watch-table>] → one blocker per line; EMPTY = skippable
  # Same "<kind> <ns> <sibling>" lines component_strands() emits, minus any OG strand the watch table
  # proves is covered. Callers test for emptiness, never a status.
  #
  # Coverage requires EVERY package the component subscribes to have a covering install, not any one
  # of them: with two Subscriptions in the stranded namespace we cannot know which one owns the CRDs
  # the sibling's operands belong to, and half a controller is the silent failure this exists to stop.
  # A component with no recorded package proves nothing and is never cleared.
  local facts="$1" comp="$2" watch="${3:-}" pkgs line kind ns sib pkg covered
  pkgs="$(component_packages "$facts" "$comp")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r kind ns sib <<< "$line"
    if [[ "$kind" != "OG" ]]; then
      printf '%s %s %s\n' "$kind" "$ns" "$sib"
      continue
    fi
    covered=1
    # `-s`, not just `-n`: an empty table is a table that proves nothing, and mktemp hands the
    # installer a real path before a single CSV has been written into it.
    if [[ -z "$watch" || ! -s "$watch" || -z "$pkgs" ]]; then
      covered=0
    else
      while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        if [[ -z "$(operator_installs_watching "$watch" "$pkg" "$ns")" ]]; then covered=0; fi
      done <<< "$pkgs"
    fi
    if [[ "$covered" -eq 0 ]]; then printf 'OG %s %s\n' "$ns" "$sib"; fi
  done < <(component_strands "$facts" "$comp")
  # Explicit: the while-loop's EOF status is 0, but a bare-called function must never RELY on that —
  # and this one IS called bare from hack/check-adoption-skip.sh's classification loop.
  return 0
}

# ── offline fact builders (the installer's yq-free path into component_strands) ────────────────────
# hack/check-adoption-skip.sh builds the same fact table from RENDERED manifests; these read the
# FILENAMES, exactly as is_operator_only() does, so the installer needs nothing but oc + this file.

component_created_namespaces() {  # <component-dir> → each namespace a `kind: Namespace` manifest creates
  local dir="$1" f
  for f in "${dir}"/*.yaml; do
    [[ -e "$f" ]] || continue
    # Document-aware: reset on `---`, capture metadata.name only INSIDE the metadata block, and print
    # it for any document whose kind is Namespace. A bare grep would miss multi-document files and
    # could pick up a container's `name:`.
    awk '
      function flush() { if (kind == "Namespace" && nm != "") print nm; kind=""; nm=""; inmeta=0 }
      /^---[[:space:]]*$/             { flush(); next }
      /^kind:[[:space:]]/             { kind=$2 }
      /^metadata:[[:space:]]*$/       { inmeta=1; next }
      /^[A-Za-z0-9_.-]+:/             { inmeta=0 }
      inmeta && /^  name:[[:space:]]/ { nm=$2; gsub(/"/, "", nm) }
      END { flush() }
    ' "$f" 2>/dev/null
  done
}

component_used_namespaces() {  # <component-dir> [dest-ns…] → namespaces the component deploys into
  # The child App destination(s) passed in, plus every metadata.namespace the manifests name. `^  ` is
  # deliberate: it matches metadata.namespace at indent 2 and never spec.sourceNamespace (a different
  # key) or a targetNamespaces list item (a `-` entry, not `namespace:`).
  local dir="$1" ns
  shift
  {
    for ns in "$@"; do [[ -n "$ns" ]] && printf '%s\n' "$ns"; done
    grep -hE '^  namespace:[[:space:]]' "${dir}"/*.yaml 2>/dev/null \
      | sed -E 's/^  namespace:[[:space:]]*//; s/[[:space:]]*$//'
  } | awk 'NF' | sort -u || true
}

app_destination_namespace() {  # <app-file> → spec.destination.namespace ("" when unset)
  # destination.namespace sits at indent 4 under `  destination:`; yaml_scalar reads indent-2 keys, so
  # it cannot see this one. Block-scoped so a `namespace:` under `  source:` can never be mistaken for it.
  awk '
    /^  destination:[[:space:]]*$/      { ind=1; next }
    /^  [A-Za-z0-9_.-]+:/               { ind=0 }
    ind && /^    namespace:[[:space:]]/ { sub(/^    namespace:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1" 2>/dev/null
}

app_creates_namespace() {  # <app-file> → true when the child App's syncOptions set CreateNamespace=true
  grep -qE 'CreateNamespace=true' "$1" 2>/dev/null
}

build_stack_facts_offline() {  # <stack> <out-file> — write component_strands facts for a whole stack
  # The installer's offline twin of hack/check-adoption-skip.sh collect_facts(): same verbs, read from
  # FILENAMES not rendered manifests. Needs STACKS_DIR and REPO_ROOT set by the caller.
  local stack="$1" out="$2" app cpath cdir comp dest n sub_name sub_ns sub_pkg
  : > "$out"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    cpath="$(component_path_of "$stack" "$app" || true)"
    [[ -n "$cpath" ]] || continue
    cdir="${REPO_ROOT}/${cpath}"
    comp="$(basename "$cpath")"
    dest="$(app_destination_namespace "${STACKS_DIR}/${stack}/${app}")"
    printf 'stack %s %s\n' "$comp" "$stack" >> "$out"
    if app_creates_namespace "${STACKS_DIR}/${stack}/${app}"; then
      printf 'opts %s CreateNamespace=true\n' "$comp" >> "$out"
    else
      printf 'opts %s -\n' "$comp" >> "$out"
    fi
    while IFS= read -r n; do printf 'creates %s %s\n' "$comp" "$n" >> "$out"; done \
      < <(component_created_namespaces "$cdir")
    while IFS= read -r n; do printf 'ogns %s %s\n' "$comp" "$n" >> "$out"; done \
      < <(component_operatorgroup_namespaces "$cdir")
    while IFS= read -r n; do printf 'uses %s %s\n' "$comp" "$n" >> "$out"; done \
      < <(component_used_namespaces "$cdir" "$dest")
    # The PACKAGE (spec.name), never the Subscription's metadata.name: component_skip_blockers() looks
    # the package up in the OLM marker OLM stamps on a CSV, and the org is free to have named their
    # Subscription anything at all.
    while read -r sub_name sub_ns sub_pkg; do
      [[ -n "$sub_pkg" ]] || continue
      : "$sub_name" "$sub_ns"
      printf 'pkg %s %s\n' "$comp" "$sub_pkg" >> "$out"
    done < <(component_subscriptions "$cdir")
  done < <(active_app_files "$stack")
  return 0   # the while-loop's EOF status is 0, but a bare-called function must never RELY on that
}
