#!/usr/bin/env bash
# check-layer-boundary — assert that no custom resource the WORKSHOP layer renders outlives the
# operator that reconciles it. READ-ONLY and CLUSTER-FREE: renders charts with helm and components
# with kustomize, then reasons about teardown order from repo contents alone.
#
#   WHY AN OPERAND MUST NOT OUTLIVE ITS OPERATOR
#   An operator sets a finalizer on the CRs it owns (kueue.x-k8s.io/resource-in-use,
#   tempo.grafana.com/finalizer, …). A finalizer is not a flag the API server clears by itself: the
#   object stays in the API until the CONTROLLER that put it there removes it. Delete the controller
#   first and the finalizer can never run — the CR is undeletable, its Argo Application never finishes
#   pruning, and its namespace hangs in Terminating until a human patches the object by hand.
#
#   WHY A SECOND CHECK EXISTS
#   hack/check-teardown-invariants.sh already enforces this rule — via sync waves, WITHIN one
#   app-of-apps root. Argo CD orders prunes inside an Application (descending wave); it has NO
#   ordering between roots. On 2026-07-25 the rule was violated across that boundary and nothing saw
#   it: gitops/workshop-config renders Kueue operands (8 ClusterQueue + 1 ResourceFlavor) while the
#   Kueue OPERATOR ships in the batch platform stack (pp-batch → pp-kueue). Both roots were deleted
#   at 13:52:41, pp-batch removed the controller first, and application/workshop-config never
#   finished pruning — "9 objects remaining for deletion", 900s cascade wait, then uninstall steps
#   4-8 were skipped. The pair was invisible to the wave checker because the two halves live in
#   different roots. This script covers exactly that seam.
#
#   THE PROPERTY BEING PROVED
#   bootstrap/ogsr-uninstall.sh deletes roots in ordered, blocking phases: 1 workshop layer,
#   2 platform stacks, 3 the git-mirror stack. So the ordering is safe iff every operator behind a
#   workshop-layer CR is provided from OUTSIDE phase 1 — a platform stack, the argocd-bootstrap, or a
#   cluster component we never install. This script proves that statically:
#     [1] the phase model still exists and the workshop layer is still classified into phase 1
#     [2] the workshop layer installs no controller of its own (so no provider can sit in phase 1)
#     [3] every declared provider is real and is shipped by a stack
#     [4] every custom resource the workshop layer renders resolves to a known, later-torn-down provider
#
#   NOTE ON SCOPE: ordering is enforced for every operator-owned group, not only for groups whose
#   controller happens to set a finalizer today. Which CRDs use finalizers is a product implementation
#   detail that changes between releases and cannot be read off a checkout — so the rule is applied
#   uniformly rather than guessed per group.
#
# Unlike the other two hack checks, this one needs the FULL repo, not just platform-portfolio/: the
# seam it inspects has one end in gitops/ and the ordering that makes it safe lives in bootstrap/.
# A checkout missing either end fails rather than passes — an unverifiable boundary is not a safe one.
#
# Usage: ./hack/check-layer-boundary.sh
# Exit 0 = the boundary is safe. Exit 1 = violations, each explained. Exit 2 = missing tooling.
set -euo pipefail

PORTFOLIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${PORTFOLIO_DIR}/.." && pwd)"
STACKS_DIR="${PORTFOLIO_DIR}/stacks"
COMPONENTS_DIR="${PORTFOLIO_DIR}/components"
WORKSHOP_CHART="${REPO_ROOT}/gitops/workshop-config"
ENTRY_STATES_DIR="${REPO_ROOT}/gitops/entry-states"
UNINSTALL_SH="${REPO_ROOT}/bootstrap/ogsr-uninstall.sh"
INSTALL_SH="${REPO_ROOT}/bootstrap/install.sh"
WS_CLI="${REPO_ROOT}/tools/ws/ws"

# The two labels bootstrap/ogsr-uninstall.sh classifies phase 1 (the workshop layer) by.
LAYER_LABEL="workshop.redhat.com/layer"
MODULE_LABEL="workshop.redhat.com/module"

FAILURES=0
# Set to "no" by [1] when nothing orders the workshop layer's roots before the platform stacks. [4]
# reads it: the SAME pair is safe or fatal depending purely on whether that ordering exists, so the
# two checks cannot be evaluated independently.
PHASE_ORDERING="yes"

ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
hint() { echo "     ↳ $*"; }

for tool in kustomize yq helm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ ${tool} not found in PATH — install it, then re-run"; exit 2
  fi
done

# The stack readers (active_app_files, component_path_of) — the same code the installer uses to decide
# what a stack actually ships, so this check can never disagree with it about stack membership.
# shellcheck disable=SC1091  # path is runtime-derived; lib-components.sh is linted standalone
. "${PORTFOLIO_DIR}/argocd-bootstrap/lib-components.sh"
export STACKS_DIR

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── the provider table ────────────────────────────────────────────────────────
# Key   = "<api-group>" or "<api-group>/<Kind>" (the Kind form wins where one group is served by two
#         different operators — argoproj.io is both the GitOps operator's and Argo Rollouts').
# Value = who runs the controller for it:
#           component:<name>   a platform-portfolio component → torn down in cascade phase 2 or 3
#           bootstrap:<pkg>    installed by platform-portfolio/argocd-bootstrap, removed at uninstall
#                              step 7/8 — i.e. after the whole cascade
#           cluster:<what>     a cluster component we never install and never remove, so its
#                              finalizers always have a controller
#
# WHY THIS IS A TABLE AND NOT DERIVED. Three candidate sources were measured against this repo:
#   • CRD manifests — absent. Every operator here is installed through OLM, which delivers the CRDs
#     from the catalog at install time; `kustomize build` over all 33 components emits ZERO
#     CustomResourceDefinitions. Nothing in a checkout states which groups a package owns.
#   • Subscription package names — present and reliable for "which operator does this component
#     install", but package→API-group is a product fact, not a string transform:
#     openshift-pipelines-operator-rh→tekton.dev, serverless-operator→serving.knative.dev,
#     servicemeshoperator3→networking.istio.io, devspaces→workspace.devfile.io, rhbk-operator→
#     k8s.keycloak.org. Token matching gets one of those five right.
#   • The component's own operand CRs — misses precisely the groups that matter, because a component
#     configures its operator through the operator's CONFIG API while the workshop layer uses the
#     operator's WORKLOAD API. components/kueue emits kueue.openshift.io; the workshop layer renders
#     kueue.x-k8s.io. Same for serverless (operator.knative.dev vs serving/eventing.knative.dev) and
#     service-mesh (sailoperator.io vs networking.istio.io). components/openshift-pipelines emits no
#     group at all, yet provides tekton.dev.
# So the group→operator edge is irreducible product knowledge and is declared here. EVERYTHING ELSE
# is derived and enforced below, which is what stops the table rotting silently: each row must name a
# component that exists and is shipped by a stack [3], and any group the workshop layer renders with
# no row and no derivation is a HARD FAILURE, never a silent pass [4].
PROVIDERS="
# ── cluster components — never installed, never removed by us ──────────────────
apps                              cluster:kubernetes            built-in workload controllers
batch                             cluster:kubernetes            built-in Job/CronJob controllers
autoscaling                       cluster:kubernetes            built-in HorizontalPodAutoscaler
policy                            cluster:kubernetes            built-in PodDisruptionBudget
discovery.k8s.io                  cluster:kubernetes            built-in EndpointSlice controller
networking.k8s.io                 cluster:kubernetes            built-in Ingress/NetworkPolicy
scheduling.k8s.io                 cluster:kubernetes            built-in PriorityClass
storage.k8s.io                    cluster:kubernetes            built-in CSI/StorageClass
rbac.authorization.k8s.io         cluster:kubernetes            built-in RBAC, no finalizers
apiextensions.k8s.io              cluster:kubernetes            the CRD API itself
admissionregistration.k8s.io      cluster:kubernetes            built-in webhook registration
operators.coreos.com              cluster:olm                   OLM ships with OpenShift
route.openshift.io                cluster:openshift             cluster ingress operator
build.openshift.io                cluster:openshift             OpenShift build controller
image.openshift.io                cluster:openshift             OpenShift image registry/API
template.openshift.io             cluster:openshift             OpenShift template service broker API
user.openshift.io                 cluster:openshift             OpenShift user/group API
security.openshift.io             cluster:openshift             SCC admission, built in
config.openshift.io               cluster:openshift             cluster config API
console.openshift.io              cluster:openshift             console operator
k8s.ovn.org                       cluster:openshift             OVN-Kubernetes, the cluster CNI
monitoring.coreos.com             cluster:openshift-monitoring  in-cluster Prometheus Operator (our
#                                                               monitoring-uwm component only flips a
#                                                               ConfigMap; it installs no operator)
objectbucket.io                   cluster:odf-noobaa            ODF/NooBaa runs the OBC controller
tuned.openshift.io                cluster:openshift             Node Tuning Operator, built in

# ── the argocd-bootstrap's operator ────────────────────────────────────────────
# argoproj.io is served by TWO controllers, so it is split by Kind. Everything not listed below is
# the Argo CD control plane, whose operator the bootstrap installs and ogsr-uninstall.sh removes at
# step 7/8 — after the cascade, and only if we created it.
argoproj.io                       bootstrap:openshift-gitops-operator  Argo CD control-plane CRs
# Rollout CRs are reconciled by the controller the argo-rollouts component's RolloutManager
# provisions (see components/argo-rollouts/rollout-manager.yaml) — a phase-2 platform stack.
argoproj.io/Rollout               component:argo-rollouts       Argo Rollouts controller
argoproj.io/AnalysisTemplate      component:argo-rollouts       Argo Rollouts controller
argoproj.io/ClusterAnalysisTemplate component:argo-rollouts     Argo Rollouts controller
argoproj.io/AnalysisRun           component:argo-rollouts       Argo Rollouts controller
argoproj.io/Experiment            component:argo-rollouts       Argo Rollouts controller

# ── operator workload APIs the providing component never emits itself ──────────
kueue.x-k8s.io                    component:kueue               kueue-operator (batch stack)
tekton.dev                        component:openshift-pipelines openshift-pipelines-operator-rh
pipelinesascode.tekton.dev        component:openshift-pipelines Pipelines-as-Code ships with it
operator.tekton.dev               component:openshift-pipelines TektonConfig, same operator
triggers.tekton.dev               component:openshift-pipelines Triggers ship with it
results.tekton.dev                component:openshift-pipelines Results ships with it
serving.knative.dev               component:serverless          serverless-operator
eventing.knative.dev              component:serverless          serverless-operator
sources.knative.dev               component:serverless          serverless-operator
messaging.knative.dev             component:serverless          serverless-operator
flows.knative.dev                 component:serverless          serverless-operator
networking.istio.io               component:service-mesh        servicemeshoperator3
security.istio.io                 component:service-mesh        servicemeshoperator3
telemetry.istio.io                component:service-mesh        servicemeshoperator3
extensions.istio.io               component:service-mesh        servicemeshoperator3
workspace.devfile.io              component:devspaces           Dev Spaces / DevWorkspace controller
controller.devfile.io             component:devspaces           DevWorkspace controller
k8s.keycloak.org                  component:keycloak-operator   rhbk-operator
# Gateway API CRDs are GA/default-on in OCP, but the ingress operator only installs the istiod that
# reconciles Gateways/HTTPRoutes once our GatewayClass exists — so removing that component IS what
# removes the controller. Attributed to the component, which is the conservative reading.
gateway.networking.k8s.io         component:gateway-api         our GatewayClass activates istiod
skupper.io                        component:service-interconnect skupper-operator
"

# ── [1] the teardown phase model still exists ─────────────────────────────────
# Everything below rests on ONE fact: ogsr-uninstall.sh runs the workshop layer's roots to completion
# before it touches the platform stacks. If that ordering is removed or the classifier stops
# recognising the workshop layer, every pair reported safe in [4] becomes a race again.
echo "▶ [1/4] the teardown phase model still puts the workshop layer first"
if [[ ! -f "$UNINSTALL_SH" ]]; then
  bad "bootstrap/ogsr-uninstall.sh not found — cannot confirm any teardown ordering exists"
  PHASE_ORDERING="no"
else
  # The ordered cascade_phase calls, by the root-set variable each is given. Anchored on identifiers
  # rather than the phase labels, so re-wording a message cannot break the check.
  # `|| true` is load-bearing: with `set -o pipefail` a no-match grep fails the whole pipeline and
  # `set -e` would kill the script HERE — silently, in the exact tree this check exists to reject.
  # shellcheck disable=SC2016  # \$p… is a literal for grep: it matches the VARIABLE NAME in that file
  phase_seq="$(grep -oE 'cascade_phase[^#]*\$p[0-9]+_roots' "$UNINSTALL_SH" 2>/dev/null \
                 | grep -oE 'p[0-9]+_roots' | tr '\n' ' ' || true)"
  first_phase="${phase_seq%% *}"
  if [[ -z "$phase_seq" ]]; then
    bad "ogsr-uninstall.sh runs no ordered cascade_phase — all roots are deleted in parallel"
    hint "with no ordering between app-of-apps roots, a platform stack can remove an operator while"
    hint "the workshop layer's CRs still hold its finalizers. That is the 2026-07-25 hang exactly."
    PHASE_ORDERING="no"
  elif [[ "$first_phase" != "p1_roots" ]]; then
    bad "the first cascade phase is '${first_phase}', not the workshop layer (p1_roots)"
    hint "the workshop layer consumes the platform's operators, so it must be pruned FIRST"
    PHASE_ORDERING="no"
  elif ! grep -qE '^[[:space:]]*p1_set=.*workshop_layer_applications' "$UNINSTALL_SH"; then
    bad "phase 1's membership is no longer taken from workshop_layer_applications()"
    hint "if it no longer selects the workshop layer, phase 1 is ordering the wrong thing"
    PHASE_ORDERING="no"
  else
    ok "roots delete in $(printf '%s' "$phase_seq" | wc -w | tr -d ' ') ordered phases, workshop layer first"
  fi
  for lbl in "$LAYER_LABEL" "$MODULE_LABEL"; do
    if ! grep -q "$lbl" "$UNINSTALL_SH"; then
      bad "ogsr-uninstall.sh no longer classifies phase 1 by ${lbl}"
      PHASE_ORDERING="no"
    fi
  done
fi
# The producers of those labels. An Application that loses its label is not classified into phase 1;
# it falls through to phase 2 and races the very stacks that provide its operators.
if [[ -f "$INSTALL_SH" ]] && ! grep -q "${LAYER_LABEL}: workshop-config" "$INSTALL_SH"; then
  bad "bootstrap/install.sh no longer stamps ${LAYER_LABEL} on the workshop-config Application"
  hint "without it the app is not in phase 1 and is torn down alongside the platform stacks"
  PHASE_ORDERING="no"
fi
if [[ -f "$WS_CLI" ]] && ! grep -q "${MODULE_LABEL}:" "$WS_CLI"; then
  bad "tools/ws/ws no longer stamps ${MODULE_LABEL} on entry-state Applications"
  hint "without it entry states are not in phase 1 and race the stacks providing their operators"
  PHASE_ORDERING="no"
fi

# ── render the workshop layer ─────────────────────────────────────────────────
# workshop-config is rendered with every feature flag ON: a gated template still ships CRs on the
# deliveries that enable it, and a check that only sees the default value set would miss them.
render_workshop_layer() {  # → "<group>|<Kind>|<source>" per rendered resource
  local d slug out
  if ! out="$(helm template wc "$WORKSHOP_CHART" \
                --set sso.enabled=true \
                --set consolePlugins.enabled=true \
                --set appRepoSeed.enabled=true \
                --set showroom.enabled=true \
                --set showroomDemos.enabled=true \
                --set clusterDomain=apps.example.invalid 2>&1)"; then
    echo "RENDERFAIL|workshop-config|$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    return 0
  fi
  # `if !` around each parse, not a bare pipeline: under `set -e` + pipefail a yq failure here would
  # abort the whole check silently, which reads as a pass to anyone watching the exit code.
  if ! printf '%s\n' "$out" | to_group_kind "workshop-config"; then
    echo "RENDERFAIL|workshop-config|rendered, but yq could not parse the manifest stream"
  fi
  for d in "${ENTRY_STATES_DIR}"/*/; do
    [[ -f "${d}Chart.yaml" ]] || continue
    slug="$(basename "$d")"
    if ! out="$(helm template es "$d" 2>&1)"; then
      echo "RENDERFAIL|entry-states/${slug}|$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
      continue
    fi
    if ! printf '%s\n' "$out" | to_group_kind "entry-states/${slug}"; then
      echo "RENDERFAIL|entry-states/${slug}|rendered, but yq could not parse the manifest stream"
    fi
  done
  return 0
}

to_group_kind() {  # stdin: a manifest stream → "<group>|<Kind>|<source>"
  local src="$1" api kind
  yq -r 'select(.kind != null) | [(.apiVersion // ""), (.kind // "?")] | join("|")' - \
    | while IFS='|' read -r api kind; do
        [[ -n "$kind" ]] || continue
        # No slash in apiVersion = the core group. Core objects are never an operator's operand, so
        # they carry no operator finalizer and cannot participate in this failure mode.
        case "$api" in */*) ;; *) continue ;; esac
        echo "${api%%/*}|${kind}|${src}"
      done
}

render_workshop_layer | sort -u > "${WORK}/layer.txt"
while IFS='|' read -r marker src detail; do
  [[ "$marker" == "RENDERFAIL" ]] || continue
  bad "${src}: helm template failed — the layer cannot be checked at all"
  hint "$detail"
done < "${WORK}/layer.txt"

# ── [2] the workshop layer installs no controller of its own ──────────────────
# This is what makes "every provider is outside phase 1" true rather than assumed. If the workshop
# layer ever shipped a Subscription or a CRD, one root inside phase 1 would provide an API another
# root inside phase 1 consumes — and within a phase, roots are deleted in parallel with no ordering
# whatsoever, so the pair would race with nothing left to fix it.
echo "▶ [2/4] the workshop layer installs no operator of its own"
selfprov="$(awk -F'|' '$1=="operators.coreos.com" && $2=="Subscription" {print $3} \
                       $1=="apiextensions.k8s.io" && $2=="CustomResourceDefinition" {print $3}' \
              "${WORK}/layer.txt" | sort -u)"
if [[ -n "$selfprov" ]]; then
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    bad "${src} installs an operator or a CRD — the workshop layer must not provide APIs"
    hint "operators belong in platform-portfolio/components (GitOps-first, hard rule 1). A provider"
    hint "inside phase 1 races its consumers: roots WITHIN a phase are deleted in parallel."
  done <<<"$selfprov"
else
  ok "no Subscription and no CRD in the workshop layer — every provider is outside phase 1"
fi

# ── [3] every declared provider is real and shipped by a stack ────────────────
# Which stack ships a component is read from the stacks' own kustomizations via the installer's
# reader, so a component dropped from a stack (or a stack's app file commented out) is caught here
# rather than at 02:00 on a teardown.
stack_of_component() {  # <component> → the stack(s) whose active apps sync that component
  local want="$1" stack_dir stack app cpath hits=""
  for stack_dir in "${STACKS_DIR}"/*/; do
    stack="$(basename "$stack_dir")"
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      # `|| true`: component_path_of is a grep|sed pipeline, and an app file with no `path:` would
      # fail it under pipefail and take the whole check down with set -e.
      cpath="$(component_path_of "$stack" "$app" || true)"
      [[ -n "$cpath" ]] || continue
      [[ "$(basename "$cpath")" == "$want" ]] || continue
      hits="${hits}${hits:+,}${stack}"
    done < <(active_app_files "$stack")
  done
  printf '%s' "$hits"
}

echo "▶ [3/4] every declared provider exists and is shipped by a stack"
: > "${WORK}/stackof.txt"
declared_bad=0
while read -r key provider _rest; do
  case "${key:-}" in ''|'#'*) continue ;; esac
  case "$provider" in
    component:*)
      comp="${provider#component:}"
      if [[ ! -d "${COMPONENTS_DIR}/${comp}" ]]; then
        bad "provider table: ${key} → component '${comp}', which does not exist"
        hint "a renamed or deleted component leaves this operand with no declared owner — fix the row"
        declared_bad=1; continue
      fi
      stacks="$(stack_of_component "$comp")"
      if [[ -z "$stacks" ]]; then
        bad "provider table: ${key} → component '${comp}', which no stack ships"
        hint "an operand whose operator is in no stack has no controller AT ALL: the CR never"
        hint "reconciles on install, and on teardown its finalizer can never run. Add the component"
        hint "to a stack, or move the CR out of the workshop layer."
        declared_bad=1; continue
      fi
      echo "${comp}|${stacks}" >> "${WORK}/stackof.txt" ;;
    bootstrap:*|cluster:*) ;;
    *)
      bad "provider table: ${key} → '${provider}' is not component:/bootstrap:/cluster:"
      declared_bad=1 ;;
  esac
done <<<"$PROVIDERS"
if [[ "$declared_bad" -eq 0 ]]; then
  ok "$(sort -u "${WORK}/stackof.txt" | wc -l | tr -d ' ') provider component(s) resolved to a stack"
fi

# ── [4] every workshop-layer CR resolves to a provider that outlives it ───────
lookup_provider() {  # <group> <Kind> → "<provider>" or "" — Kind row wins over group row
  local group="$1" kind="$2" key provider _rest
  while read -r key provider _rest; do
    case "${key:-}" in ''|'#'*) continue ;; esac
    [[ "$key" == "${group}/${kind}" ]] || continue
    printf '%s' "$provider"; return 0
  done <<<"$PROVIDERS"
  while read -r key provider _rest; do
    case "${key:-}" in ''|'#'*) continue ;; esac
    [[ "$key" == "$group" ]] || continue
    printf '%s' "$provider"; return 0
  done <<<"$PROVIDERS"
  return 0
}

# Derivation, applied only where the table is silent: a component that installs an operator AND
# renders a CR of group G is itself evidence that its operator owns G. It resolves nothing the table
# already covers, but it means a future workshop-layer CR that happens to share a group with a
# portfolio operand (a TempoMonolithic, a SecuredCluster) is classified with no table edit at all.
# Where two such components exist for one group they are all in platform stacks, so the safety
# verdict — "outside phase 1" — is identical either way; the first is reported.
build_derived_index() {
  local dir comp out groups
  : > "${WORK}/derived.txt"
  for dir in "${COMPONENTS_DIR}"/*/; do
    [[ -f "${dir}kustomization.yaml" ]] || continue
    comp="$(basename "$dir")"
    out="$(kustomize build --enable-helm "$dir" 2>/dev/null || true)"
    [[ -n "$out" ]] || continue
    printf '%s\n' "$out" | grep -q 'kind: Subscription' || continue
    # `|| true`: a component rendering only core-group objects makes `grep '/'` fail the pipeline.
    groups="$(printf '%s\n' "$out" \
                | yq -r 'select(.kind != null) | (.apiVersion // "")' - \
                | grep '/' | sed 's|/.*||' | sort -u || true)"
    while IFS= read -r g; do
      [[ -n "$g" ]] || continue
      [[ -z "$(lookup_provider "$g" '')" ]] || continue   # the table already answers for this group
      echo "${g}|${comp}" >> "${WORK}/derived.txt"
    done <<<"$groups"
  done
  sort -u -t'|' -k1,1 "${WORK}/derived.txt" -o "${WORK}/derived.txt"
  return 0
}
build_derived_index

echo "▶ [4/4] every custom resource the workshop layer renders outlives its operator"
: > "${WORK}/seen.txt"
: > "${WORK}/pairs.txt"
while IFS='|' read -r group kind src; do
  [[ -n "$group" && "$group" != "RENDERFAIL" ]] || continue
  provider="$(lookup_provider "$group" "$kind")"
  if [[ -z "$provider" ]]; then
    derived="$(awk -F'|' -v g="$group" '$1==g {print $2; exit}' "${WORK}/derived.txt")"
    if [[ -n "$derived" ]]; then provider="component:${derived}"; fi
  fi

  if [[ -z "$provider" ]]; then
    # A loud unknown, deliberately. A silent pass here is what the 2026-07-25 hang WAS: a pair nobody
    # had modelled, behaving perfectly until the one teardown where it mattered. Nothing in a
    # checkout can tell us who owns an unrecognised group, so the honest answer is to stop and make
    # a human say — the cost of a wrong "safe" is a wedged cluster, the cost of this is one table row.
    bad "${src} renders ${kind} (${group}) — NO KNOWN PROVIDER"
    hint "who runs the controller for ${group}? Add a row to PROVIDERS in this script:"
    hint "  ${group}   component:<portfolio component>   — if a platform stack installs its operator"
    hint "  ${group}   cluster:<what>                    — if it is a cluster component we never install"
    hint "If the operator is NOT in the portfolio at all, this CR has no controller on a clean cluster:"
    hint "it will never reconcile, and on teardown its finalizer can never run."
    continue
  fi

  case "$provider" in
    cluster:*)
      # Never installed and never removed by us, so its controller outlives everything by definition.
      echo "${group}|${kind}|${provider}|${src}|permanent" >> "${WORK}/pairs.txt" ;;
    bootstrap:*)
      # argocd-bootstrap's operator is removed at uninstall step 7/8; the cascade is step 2/8, so it
      # outlives the whole app-of-apps regardless of how the roots inside the cascade are ordered.
      echo "${group}|${kind}|${provider}|${src}|step 7/8, after the cascade" >> "${WORK}/pairs.txt" ;;
    component:*)
      comp="${provider#component:}"
      stacks="$(grep -m1 "^${comp}|" "${WORK}/stackof.txt" | cut -d'|' -f2 || true)"
      if [[ -z "$stacks" ]]; then
        # Not in the declared table (so [3] never validated it) — validate the derived row here.
        stacks="$(stack_of_component "$comp")"
      fi
      if [[ -z "$stacks" ]]; then
        bad "${src} renders ${kind} (${group}) — provider '${comp}' is shipped by no stack"
        hint "its operator is never installed, so the CR has no controller to reconcile OR finalize it"
        continue
      fi
      echo "${group}|${kind}|${provider}|${src}|stack ${stacks}" >> "${WORK}/pairs.txt" ;;
  esac
  echo "${group}|${provider}" >> "${WORK}/seen.txt"
done < "${WORK}/layer.txt"

# The cross-boundary pairs, printed every run: this table IS the answer to "what does the workshop
# layer depend on the platform for", and it is only trustworthy when it is regenerated, not written.
# Each pair is safe ONLY because [1] found an ordering that makes the workshop layer outlive the
# stacks. Without it, every one of these is the 2026-07-25 hang waiting for a teardown.
crossings=0
explained=0
if [[ -s "${WORK}/pairs.txt" ]]; then
  while IFS='|' read -r group kind provider src where; do
    case "$provider" in component:*) ;; *) continue ;; esac
    crossings=$((crossings + 1))
    comp="${provider#component:}"
    if [[ "$PHASE_ORDERING" == "yes" ]]; then
      ok "${kind} (${group}) → ${comp} — torn down at ${where}, after the workshop layer"
      continue
    fi
    bad "${src} renders ${kind} (${group}); its operator ships in ${comp} (${where})"
    if [[ "$explained" -eq 0 ]]; then
      hint "two DIFFERENT app-of-apps roots, and nothing above orders them. Delete both at once and"
      hint "the stack can remove the ${comp} controller first; the ${kind} objects then hold a"
      hint "finalizer no controller can ever run, so they never delete, the Application never"
      hint "finishes pruning, and their namespace hangs in Terminating until a human intervenes."
      hint "Fix the ORDERING (tear the workshop layer down first) — not this pair one CR at a time."
      explained=1
    fi
  done < <(sort -u -t'|' -k1,2 "${WORK}/pairs.txt")
fi
n_perm="$(awk -F'|' '$3 ~ /^cluster:/ {print $1}' "${WORK}/pairs.txt" | sort -u | wc -l | tr -d ' ')"
n_boot="$(awk -F'|' '$3 ~ /^bootstrap:/ {print $1}' "${WORK}/pairs.txt" | sort -u | wc -l | tr -d ' ')"
echo "  · ${crossings} cross-boundary pair(s); ${n_perm} group(s) served by permanent cluster components; ${n_boot} by the argocd-bootstrap"

# Rows the workshop layer does not currently render are NOT a failure: the layer is feature-gated
# (sso, per-module entry states) and a row describing a provider for a module that ships next month is
# correct, just unexercised. The asymmetry is deliberate — a RENDERED group with no row is fatal
# above, because that is the direction in which a real teardown hangs.
declared_groups="$(awk '$1 !~ /^#/ && NF >= 2 {split($1, a, "/"); print a[1]}' <<<"$PROVIDERS" | sort -u)"
rendered_groups="$(cut -d'|' -f1 "${WORK}/layer.txt" | sort -u)"
n_unused="$(comm -23 <(printf '%s\n' "$declared_groups") <(printf '%s\n' "$rendered_groups") | grep -c . || true)"
echo "  · ${n_unused} declared group(s) not currently rendered by the workshop layer (allowed — gated/future modules)"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "✅ no workshop-layer custom resource outlives the operator that reconciles it"
  exit 0
fi
echo "❌ ${FAILURES} violation(s)"
echo "   An operand deleted after its operator can never run its finalizer: the CR becomes"
echo "   undeletable, its Application never finishes pruning, and its namespace hangs in"
echo "   Terminating until a human patches the object by hand. See bootstrap/ogsr-uninstall.sh"
echo "   § cascade ordering and platform-portfolio/README.md § Sync waves."
exit 1
