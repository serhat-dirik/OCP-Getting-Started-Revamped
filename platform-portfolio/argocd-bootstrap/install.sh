#!/usr/bin/env bash
# Platform Portfolio bootstrap — the ONLY imperative step of the portfolio.
# Mutates exactly twice: (1) install the OpenShift GitOps operator (+ controller RBAC),
# (2) apply the portfolio AppProject and one Argo CD Application per requested stack.
# Everything else reconciles. Ahead of both, a read-only preflight decides, per component, whether
# this cluster already runs that operator — and if so uses theirs instead of installing ours
# (see section 0).
#
# Usage:
#   ./install.sh --stacks core-devtools[,ai-assist,...]
#                [--repo-url <git url>] [--revision <branch|tag>]
#                [--source-repo <git url>] [--allow-source-repo <git url>]…
#                [--allow-destination <namespace glob>]…
#                [--project <name>] [--stacks-only] [--skip-repo-check]
#                [--adoption-plan] [--wait] [--dry-run]
#
# --repo-url        where Argo reads the portfolio FROM (default: the upstream project).
# --source-repo     the EXTERNAL repo the in-cluster Gitea pull-mirrors (defaults to --repo-url).
#                   Stays external when --repo-url is flipped to the mirror — a mirror configured
#                   to pull from itself never sees another commit.
# --allow-source-repo  extra repo permitted by the AppProject (repeatable). The phase-2 flip uses
#                   it to keep the external repo allowed alongside the mirror.
# --allow-destination  extra namespace (glob) the AppProject permits, for a consumer layer whose
#                   Applications deploy outside the portfolio's own namespaces (repeatable).
#                   Both allow-lists are UNIONED with what the live project already permits.
# --project         AppProject the Applications live in (default: ogsr-platform).
# --stacks-only     skip the GitOps-operator step; only (re-)apply the project + stack Applications.
#                   This is how the phase-2 flip re-points the stacks at the Gitea mirror.
# --skip-repo-check skip the source-repo reachability/layout validation (used for the in-cluster
#                   mirror, whose content the caller has already verified).
# --adoption-plan   print the section-0 verdict and EXIT, applying nothing. One machine-readable
#                   tab-separated line per component with a verdict:
#                     <verb> <stack> <component> <child-app> <namespaces> <foreign-subs> <reason>
#                   verb = skip (adopted, our component dropped from the render) | refuse | warn.
#                   The workshop bootstrap layer reads this so its uninstall snapshot records a
#                   skipped component's operator as ADOPTED — one detector, two callers.
#
# Idempotent: safe to re-run; re-running with more stacks adds them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/serhat-dirik/OCP-Getting-Started-Revamped}"
REVISION="${REVISION:-main}"
SOURCE_REPO=""
PROJECT="${PROJECT:-ogsr-platform}"
ARGO_NS="openshift-gitops"
EXTRA_SOURCE_REPOS=()
EXTRA_DESTINATIONS=()
STACKS=""
WAIT="false"
DRY_RUN="false"
STACKS_ONLY="false"
SKIP_REPO_CHECK="false"
ADOPTION_PLAN_ONLY="false"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -38; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stacks)            STACKS="$2"; shift 2;;
    --repo-url)          REPO_URL="$2"; shift 2;;
    --revision)          REVISION="$2"; shift 2;;
    --source-repo)       SOURCE_REPO="$2"; shift 2;;
    --allow-source-repo) EXTRA_SOURCE_REPOS+=("$2"); shift 2;;
    --allow-destination) EXTRA_DESTINATIONS+=("$2"); shift 2;;
    --project)           PROJECT="$2"; shift 2;;
    --stacks-only)       STACKS_ONLY="true"; shift;;
    --skip-repo-check)   SKIP_REPO_CHECK="true"; shift;;
    --adoption-plan)     ADOPTION_PLAN_ONLY="true"; shift;;
    --wait)              WAIT="true"; shift;;
    --dry-run)           DRY_RUN="true"; shift;;
    -h|--help)           usage;;
    *) echo "❌ unknown flag: $1"; usage;;
  esac
done
[[ -n "$STACKS" ]] || { echo "❌ --stacks is required (e.g. --stacks core-devtools)"; usage; }
# The mirror source defaults to whatever we are reading the portfolio from — correct for a normal
# phase-1 install, and overridden by the phase-2 flip (which passes the external repo explicitly).
[[ -n "$SOURCE_REPO" ]] || SOURCE_REPO="$REPO_URL"

APPLY=(oc apply -f -)
[[ "$DRY_RUN" == "true" ]] && APPLY=(oc apply --dry-run=client -f -)

# --adoption-plan must emit NOTHING on stdout but the plan, so every human line goes through say().
say() { [[ "$ADOPTION_PLAN_ONLY" == "true" ]] || printf '%s\n' "$*"; }

say "▶ Platform Portfolio bootstrap"
[[ "$ADOPTION_PLAN_ONLY" == "true" ]] \
  || echo "  cluster : $(oc whoami --show-server) (as $(oc whoami))"
say "  source  : ${REPO_URL} @ ${REVISION}"
say "  mirrors : ${SOURCE_REPO}"
say "  project : ${PROJECT}"
say "  stacks  : ${STACKS}"

# ── source repo validation (READ-ONLY, blocking) ──────────────────────────────
# A typo in --repo-url must fail HERE, with the URL in the message — not as N Applications stuck
# in ComparisonError twenty minutes later, where the actual cause is three screens up in a log.
# Two questions, both answered over plain git-over-HTTPS so this works against GitHub, GitLab,
# an internal Gitea, or anything else that serves git: does the revision exist, and does the tree
# look like this portfolio?
validate_source_repo() {  # <url> <revision>
  local url="$1" rev="$2" tmp refs top
  if ! command -v git >/dev/null 2>&1; then
    # The portfolio installer is meant to run on a box with nothing but oc. Degrade to the
    # reachability half rather than skipping validation altogether.
    if command -v curl >/dev/null 2>&1; then
      curl -sfI --max-time 30 "${url%.git}.git/info/refs?service=git-upload-pack" >/dev/null 2>&1 \
        || { echo "❌ source repo not reachable: ${url}"
             echo "   checked: ${url%.git}.git/info/refs?service=git-upload-pack"
             echo "   fix --repo-url (or repo_url in bootstrap/vars.yaml), then re-run."; return 1; }
      echo "  ✓ ${url} reachable (git not installed — revision + layout NOT checked)"
      return 0
    fi
    echo "  ⚠ neither git nor curl available — source repo NOT validated"
    return 0
  fi

  refs="$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads --tags "$url" "$rev" 2>/dev/null || true)"
  if [[ -z "$refs" ]]; then
    echo "❌ ${url} has no branch or tag '${rev}' (or the repo is unreachable/private)"
    echo "   fix --repo-url / --revision (repo_url / repo_revision in bootstrap/vars.yaml), then re-run."
    echo "   check by hand: git ls-remote ${url} ${rev}"
    return 1
  fi

  # Tree-only clone: no blobs, no checkout, one commit — ~200KB and about a second, which is worth
  # paying to prove the repo actually carries a portfolio before we create 30-odd Applications.
  tmp="$(mktemp -d)"
  if ! GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --filter=blob:none --no-checkout \
        --branch "$rev" "$url" "${tmp}/repo" >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo "  ⚠ ${url}@${rev} resolves but could not be shallow-cloned — layout NOT checked"
    return 0
  fi
  top="$(git -C "${tmp}/repo" ls-tree --name-only HEAD 2>/dev/null || true)"
  rm -rf "$tmp"
  if ! printf '%s\n' "$top" | grep -qx 'platform-portfolio'; then
    echo "❌ ${url}@${rev} has no platform-portfolio/ at its root — this is not a portfolio repo."
    echo "   top level: $(printf '%s' "$top" | tr '\n' ' ')"
    echo "   fix --repo-url (repo_url in bootstrap/vars.yaml), then re-run."
    return 1
  fi
  echo "  ✓ ${url}@${rev} reachable and carries platform-portfolio/"
}

# --adoption-plan answers a question about the CLUSTER, not about the repo, and its caller (the
# workshop bootstrap) validates the repo itself moments later — so skip the network round-trip.
if [[ "$SKIP_REPO_CHECK" == "true" || "$ADOPTION_PLAN_ONLY" == "true" ]]; then
  say "▶ source repo validation skipped (--skip-repo-check)"
else
  echo "▶ validating source repo (read-only)…"
  validate_source_repo "$REPO_URL" "$REVISION" \
    || { echo "❌ nothing was applied, the cluster is untouched."; exit 1; }
fi

# ── 0. component adoption preflight (READ-ONLY, blocking) ─────────────────────
# Two questions per component, both answered before anything is applied.
#
#   1. Does this cluster ALREADY run this operator? RHDP clusters — the primary target — ship at
#      least three pre-installed (cert-manager, Lightspeed, GitOps). Installing ours alongside is
#      never right, and where the component carries an OperatorGroup it is actively destructive:
#      OLM fails EVERY CSV in a namespace holding more than one OperatorGroup (phase Failed, reason
#      TooManyOperatorGroups) and does so SILENTLY — the operator's pods keep running, so nothing
#      looks broken while OLM has stopped managing it entirely. Found live 2026-07-25:
#      pp-cert-manager applied our OperatorGroup into an ADOPTED cert-manager-operator namespace and
#      the org's CSV failed one second later.
#
#   2. If it is already there, can we simply not install ours? Two things must hold, and they are the
#      two halves of lib-components.sh's skippability rule (hack/check-adoption-skip.sh proves the
#      same rule from rendered manifests, so there is exactly one of it):
#        • the component contributes NOTHING but the operator install (is_operator_only), and
#        • every namespace our operands occupy still has something to create it and something to
#          reconcile in it once the component is gone (component_skip_blockers).
#      Both hold → SKIPPED automatically (§2 renders a kustomize patch that removes its child
#      Application) and the install continues unattended. Either fails → we install ours, exactly as
#      on a cluster with nothing to adopt, and say why. Asking only the first question is what let
#      adoption drop keycloak-operator whenever ANY rhbk-operator existed anywhere on the cluster,
#      even though ours is OwnNamespace-scoped to a namespace only we create.
#      A REFUSAL is now reserved for the one case installing ours would actively damage: a foreign
#      OperatorGroup in a namespace we ship one into (TooManyOperatorGroups, silent, cluster-owner's
#      operator). Everything else keeps the component, because a wrongly-kept install costs an
#      operator nobody needed while a wrongly-skipped one ships a workshop that is green and broken.
#      OWNER DECISION 2026-08-06, asked and answered explicitly: this narrowing REVERSES the earlier
#      "refuse loudly rather than mutate someone's cluster on an assumption" posture for the
#      blocked-but-operator-only case, and was signed off on that asymmetry. It is not a silent
#      relaxation — do not "restore" the hard refuse here without taking the reversal back to them.
#
# Argo CD has no "create only if absent" primitive, so none of this can live in the manifests: the
# decision is made once, here, in the portfolio's single sanctioned imperative step. Read-only
# throughout — the worst this section can do is decline to install.
OG_OWNER_KEY="workshop.redhat.com/owner"
OG_OWNER_VALUE="ogsr"
STACKS_DIR="$(cd "${SCRIPT_DIR}/../stacks" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# The workshop bootstrap layer's adoption snapshot. ABSENT on a standalone portfolio install, which
# is why it is only ever one signal of three and never a requirement.
STATE_NS="ogsr-system"
STATE_CM="ogsr-uninstall-state"

# ── manifest readers ──────────────────────────────────────────────────────────
# Offline, cluster-free, and SHARED with hack/check-adoption-skip.sh so the decision to skip a
# component and the CI check that proves skipping is safe can never be two different opinions.
# shellcheck disable=SC1091  # lib-components.sh is linted standalone; its path is runtime-derived
. "${SCRIPT_DIR}/lib-components.sh"

# ── cluster snapshot ──────────────────────────────────────────────────────────
# FOUR reads, taken once, then every lookup below is pure text. Per-namespace queries meant ~100
# sequential round trips for a full stack set (over two minutes against a remote cluster), and made
# the verdict depend on the cluster not changing under the scan. Read-only and failure-tolerant: an
# unreadable resource yields an empty snapshot, which can only ever cause us to install rather than
# skip — never the other way round.
OG_SNAPSHOT=""      # <ns>|<name>|<our-owner-label>
SUB_SNAPSHOT=""     # <ns>|<name>|<package>|<our-owner-label>
CSV_SNAPSHOT=""     # <ns>|<name>|<olm.targetNamespaces>|<comma-terminated list of label KEYS>
STATE_SNAPSHOT=""   # <key>=<value> from the workshop layer's uninstall-state ConfigMap
# CSV_SNAPSHOT as a FILE, because lib-components.sh's watch-scope readers are awk over a table and
# awk reads files. Same four reads, no fifth: field 3 was added to the existing CSV query rather than
# taking a second one, which is what the format doc in lib-components.sh anticipated.
CSV_WATCH_TABLE=""

load_cluster_snapshot() {
  OG_SNAPSHOT="$(oc get operatorgroups.operators.coreos.com -A \
    -o jsonpath="{range .items[*]}{.metadata.namespace}{'|'}{.metadata.name}{'|'}{.metadata.labels.${OG_OWNER_KEY//./\\.}}{'\n'}{end}" \
    2>/dev/null || true)"
  SUB_SNAPSHOT="$(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath="{range .items[*]}{.metadata.namespace}{'|'}{.metadata.name}{'|'}{.spec.name}{'|'}{.metadata.labels.${OG_OWNER_KEY//./\\.}}{'\n'}{end}" \
    2>/dev/null || true)"
  # go-template, not jsonpath: only a template can enumerate label KEYS, and the package marker OLM
  # writes is a key (operators.coreos.com/<package>.<namespace>) with an empty value.
  # Field 3 is olm.targetNamespaces — the scope OLM RESOLVED for the install, never
  # spec.targetNamespaces, which is empty both for AllNamespaces and for a label-selector group and
  # so cannot tell them apart. See the format doc in lib-components.sh for the four shapes it takes.
  # $k/$v are go-template variables, not shell variables — the single quotes are intentional.
  # shellcheck disable=SC2016
  CSV_SNAPSHOT="$(oc get clusterserviceversions.operators.coreos.com -A \
    -o go-template='{{range .items}}{{.metadata.namespace}}|{{.metadata.name}}|{{index .metadata.annotations "olm.targetNamespaces"}}|{{range $k, $v := .metadata.labels}}{{$k}},{{end}}{{"\n"}}{{end}}' \
    2>/dev/null || true)"
  # Materialised once. An unreadable CSV list leaves an EMPTY table, and an empty table proves no
  # coverage — so the failure mode is "keep the component", never "drop it on a guess".
  CSV_WATCH_TABLE="$(mktemp)"
  printf '%s\n' "$CSV_SNAPSHOT" > "$CSV_WATCH_TABLE"
  # shellcheck disable=SC2016
  STATE_SNAPSHOT="$(oc get configmap "$STATE_CM" -n "$STATE_NS" \
    -o go-template='{{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null || true)"
}

foreign_operatorgroups_in() {  # <namespace> → names of OperatorGroups there that are NOT ours
  printf '%s\n' "$OG_SNAPSHOT" \
    | awk -F'|' -v ns="$1" -v ours="$OG_OWNER_VALUE" '$1 == ns && $2 != "" && $3 != ours { print $2 }'
}

our_subscriptions_in() {  # <namespace> → Subscription names there carrying OUR owner label
  printf '%s\n' "$SUB_SNAPSHOT" \
    | awk -F'|' -v ns="$1" -v ours="$OG_OWNER_VALUE" '$1 == ns && $4 == ours { print $2 }'
}

foreign_subscriptions_for() {  # <package> <namespace> → Subscriptions for that package that are NOT ours
  # Matched on spec.name (the PACKAGE), not metadata.name: the org is free to have called their
  # Subscription anything. Ours are excluded by owner label, which is what keeps a RE-INSTALL from
  # reading its own previous install as somebody else's operator and skipping the component.
  printf '%s\n' "$SUB_SNAPSHOT" \
    | awk -F'|' -v ns="$2" -v pkg="$1" -v ours="$OG_OWNER_VALUE" \
        '$1 == ns && $3 == pkg && $4 != ours { print $2 }'
}

csvs_for_package_in() {  # <package> <namespace> → CSVs OLM has labelled for that package there
  # OLM stamps every Subscription and CSV it manages with operators.coreos.com/<package>.<namespace>
  # (verified live, OCP 4.22). Catches an operator installed with no Subscription we can see. A CSV
  # COPIED into other namespaces by an AllNamespaces operator does NOT carry the marker (verified —
  # it carries olm.copiedFrom instead), so this never fires outside the operator's own namespace.
  # Only consulted when we hold no Subscription of our own for the package there — otherwise it
  # would match the CSV our own Subscription installed and a re-install would adopt itself.
  # $4, not $3: the label-key list moved one field right when olm.targetNamespaces was added to the
  # query so lib-components.sh's watch-scope readers could share the same snapshot.
  printf '%s\n' "$CSV_SNAPSHOT" \
    | awk -F'|' -v ns="$2" -v key="operators.coreos.com/${1}.${2}," \
        '$1 == ns && index("," $4, "," key) > 0 { print $2 }'
}

state_operator_record() {  # <sub-name> → op_<name> from the workshop layer's adoption snapshot
  printf '%s\n' "$STATE_SNAPSHOT" \
    | awk -F= -v k="op_$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

add_unique() {  # <csv> <item> → csv with item appended at most once
  local csv="$1" item="$2"
  case ",${csv}," in *",${item},"*) printf '%s' "$csv"; return 0 ;; esac
  printf '%s' "${csv:+${csv},}${item}"
}

# ── the verdict for ONE component ─────────────────────────────────────────────
# Sets globals rather than echoing a value: it also advances OG_CHECKED, which a $(subshell) would
# throw away. CC_VERB: ok (install it) | present (already on the cluster) | invalid (bug in the
# component). CC_HARD records whether the evidence was an OperatorGroup collision — the one class of
# evidence that must still refuse when the component cannot be skipped.
#
# KNOWN BLIND SPOT — A COMPONENT THAT SHIPS NO SUBSCRIPTION IS NEVER CLASSIFIED AT ALL.
# (Measured 2026-08-01 by driving this exact function against fixtures with every adoption signal
#  forced positive. Recorded, deliberately not fixed here: the fix needs a way for a component to
#  DECLARE which operator it configures, and that is an owner design decision, not a local patch.)
#
# The mechanism, precisely: both loops below are fed by lib-components.sh readers that GLOB the
# component directory — component_operatorgroup_namespaces() over operatorgroup*.yaml, and
# component_subscriptions() over subscription*.yaml. A component carrying neither file produces ZERO
# iterations of both loops, so not one of signals 1-4 is ever consulted. CC_VERB keeps the "ok" this
# function assigns on entry, and the preflight loop's `[[ "$CC_VERB" == "ok" ]] && continue` (the
# `for _stack in "${PREFLIGHT_STACKS[@]}"` loop further down) installs the component unconditionally.
#
# WHAT THAT LOOKS LIKE ON A CUSTOMER CLUSTER. Split an operator component in two — `foo-operator`
# (Namespace + OperatorGroup + Subscription, so is_operator_only() = half 1 of the skippability rule)
# and `foo-config` (the operand CRs alone, no Subscription). On a cluster that already runs foo:
#   • foo-operator is correctly detected as present and, if half 2 also passes, SKIPPED — the org's
#     operator is left alone;
#   • foo-config is classified "ok" and applied anyway, so our operand CRs land on THEIR operator
#     instance, at whatever channel and version they chose to run it at.
# Half 2 narrows this but does not close it: component_skip_blockers() reads namespaces a sibling
# would be stranded in, and a split like this leaves foo-config using a namespace foo-operator does
# not create or scope a group to, so there is nothing for it to report.
# There is no ❌, no ⚠, no line in --adoption-plan and nothing in the install summary: the adoption
# preflight prints exactly what it prints for a component that had nothing to adopt. That is QUIETER
# than the openshift-pipelines case this code path was criticised for, which at least warns.
#
# WHY IT MATTERS BEYOND ONE COMPONENT. "Move the extra resource into its own component" is the
# standard remedy the adoption gate itself recommends for a skippable → installs-more demotion (see
# tools/lint/adoption-skippable-guard.sh and platform-portfolio/README.md § Adoption). Taking that
# advice is what CREATES an operand-only component — so today the recommended fix silently converts
# a visible warning into an invisible overwrite, and the "split operator install from operand
# config" pattern cannot be used safely anywhere in the portfolio until this is resolved.
CC_VERB=""; CC_REASON=""; CC_NS=""; CC_SUBS=""; CC_HARD="false"
classify_component() {  # <component-dir>
  local dir="$1" ns f name subns pkg rec csv sub
  local -a found
  CC_VERB="ok"; CC_REASON=""; CC_NS=""; CC_SUBS=""; CC_HARD="false"

  # Signal 1 (strongest): a foreign OperatorGroup in a namespace we would ship one into.
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    OG_CHECKED=$((OG_CHECKED + 1))
    # Static rule, true on every cluster: openshift-operators ALWAYS carries OpenShift's own
    # cluster-wide `global-operators`, so shipping one there is a guaranteed collision with the
    # widest possible blast radius. Not an adoption case — a defect in the component.
    if [[ "$ns" == "openshift-operators" ]]; then
      CC_VERB="invalid"
      CC_REASON="ships an OperatorGroup into openshift-operators, which always carries OpenShift's own cluster-wide 'global-operators'"
      return 0
    fi
    f="$(foreign_operatorgroups_in "$ns" | tr '\n' ' ' | xargs || true)"
    [[ -n "$f" ]] || continue
    CC_VERB="present"; CC_HARD="true"
    CC_NS="$(add_unique "$CC_NS" "$ns")"
    [[ -n "$CC_REASON" ]] \
      || CC_REASON="namespace ${ns} already carries an OperatorGroup that is not ours (${f})"
  done < <(component_operatorgroup_namespaces "$dir")

  # Signals 2-4, per Subscription the component ships.
  while read -r name subns pkg; do
    [[ -n "$name" ]] || continue

    # 2 — the workshop layer's first-write-wins snapshot already ruled on this operator.
    rec="$(state_operator_record "$name")"
    case "$rec" in
      adopted:*)
        CC_VERB="present"
        CC_NS="$(add_unique "$CC_NS" "$subns")"
        CC_SUBS="$(add_unique "$CC_SUBS" "${name}@${subns}")"
        [[ -n "$CC_REASON" ]] \
          || CC_REASON="the workshop uninstall-state snapshot records ${name} in ${subns} as pre-existing" ;;
    esac

    # 3 — a Subscription for the same PACKAGE in the same namespace that is not ours. This is the
    # only signal that sees openshift-pipelines and web-terminal, which ship no OperatorGroup at all
    # and would otherwise have Argo silently adopt (and re-channel) the org's Subscription.
    f="$(foreign_subscriptions_for "$pkg" "$subns" | tr '\n' ' ' | xargs || true)"
    if [[ -n "$f" ]]; then
      CC_VERB="present"
      CC_NS="$(add_unique "$CC_NS" "$subns")"
      read -ra found <<< "$f"
      for sub in "${found[@]}"; do CC_SUBS="$(add_unique "$CC_SUBS" "${sub}@${subns}")"; done
      [[ -n "$CC_REASON" ]] \
        || CC_REASON="package ${pkg} is already subscribed in ${subns} by someone other than us (${f})"
    elif ! our_subscriptions_in "$subns" | grep -qx "$name"; then
      # 4 — a CSV with no Subscription of ours behind it.
      csv="$(csvs_for_package_in "$pkg" "$subns" | tr '\n' ' ' | xargs || true)"
      if [[ -n "$csv" ]]; then
        CC_VERB="present"
        CC_NS="$(add_unique "$CC_NS" "$subns")"
        [[ -n "$CC_REASON" ]] \
          || CC_REASON="a ClusterServiceVersion for package ${pkg} is already installed in ${subns} (${csv})"
      fi
    fi
  done < <(component_subscriptions "$dir")
}

say "▶ [0/2] component adoption preflight (read-only)…"
load_cluster_snapshot
ADOPTION_PLAN=""
OG_CONFLICTS=0
OG_CHECKED=0
SKIPPED_COUNT=0
IFS=',' read -ra PREFLIGHT_STACKS <<< "$STACKS"

plan_add() {  # <verb> <stack> <component> <child-app> <namespaces> <foreign-subs> <reason>
  ADOPTION_PLAN="${ADOPTION_PLAN}${ADOPTION_PLAN:+$'\n'}$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$1" "$2" "$3" "${4:--}" "${5:--}" "${6:--}" "$7")"
}

# The bootstrap's own OperatorGroup is only applied when we also create the Subscription (the reuse
# branch in §1 skips `oc apply -k operator/` entirely), so preflight it only in that case. Never
# skippable: without Argo CD there is no portfolio at all.
if ! oc get subscriptions.operators.coreos.com openshift-gitops-operator \
      -n openshift-gitops-operator >/dev/null 2>&1; then
  OG_CHECKED=$((OG_CHECKED + 1))
  _foreign="$(foreign_operatorgroups_in openshift-gitops-operator | tr '\n' ' ' | xargs || true)"
  if [[ -n "$_foreign" ]]; then
    OG_CONFLICTS=$((OG_CONFLICTS + 1))
    plan_add refuse "-" argocd-bootstrap "-" openshift-gitops-operator "-" \
      "namespace openshift-gitops-operator already carries an OperatorGroup that is not ours (${_foreign})"
    say "❌ namespace openshift-gitops-operator already has an OperatorGroup that is not ours: ${_foreign}"
    say "   but no openshift-gitops-operator Subscription — so something installed a group without an"
    say "   operator. Installing ours next to it would fail every CSV in that namespace. Refusing."
    say "   Inspect: oc get operatorgroups,subscriptions.operators.coreos.com,csv -n openshift-gitops-operator"
  fi
fi

for _stack in "${PREFLIGHT_STACKS[@]}"; do
  _stack="$(echo "$_stack" | xargs)"
  [[ -d "${STACKS_DIR}/${_stack}" ]] || continue
  # The whole stack's fact table, built once (offline, from filenames) so the skip decision below can
  # ask whether dropping any one component would strand a sibling. Same table shape the CI gate builds
  # from rendered manifests; both feed lib-components.sh component_strands().
  _facts="$(mktemp)"
  build_stack_facts_offline "$_stack" "$_facts"
  while IFS= read -r _app; do
    [[ -n "$_app" ]] || continue
    _cpath="$(component_path_of "$_stack" "$_app")"
    [[ -n "$_cpath" ]] || continue
    _cdir="${REPO_ROOT}/${_cpath}"
    _comp="$(basename "$_cpath")"
    _child="$(yaml_scalar "${STACKS_DIR}/${_stack}/${_app}" metadata name)"
    [[ -n "$_child" ]] || _child="pp-${_comp}"

    classify_component "$_cdir"
    [[ "$CC_VERB" == "ok" ]] && continue

    if [[ "$CC_VERB" == "invalid" ]]; then
      OG_CONFLICTS=$((OG_CONFLICTS + 1))
      plan_add refuse "$_stack" "$_comp" "$_child" "-" "-" "$CC_REASON"
      say "❌ component '${_comp}' ${CC_REASON}."
      say "   Every operator the org installed cluster-wide would stop being reconciled."
      say "   Fix in git: delete components/${_comp}/operatorgroup*.yaml and drop it from the"
      say "   component's kustomization — an operator installed there needs no OperatorGroup of ours."
      continue
    fi

    # CC_VERB == present. Both halves of lib-components.sh's skippability rule decide what happens
    # next — the SAME rule hack/check-adoption-skip.sh runs, from the same library, so the installer's
    # decision and the CI proof that it is safe can never be two opinions:
    #   half 1  is_operator_only()          — the component contributes nothing but the operator
    #   half 2  component_skip_blockers()   — every namespace our operands occupy survives the drop
    # Half 2 gets the LIVE watch table here, which is the one thing the CI gate cannot have: an OG
    # blocker clears when an operator already on this cluster is measured to watch the namespace at
    # issue. An NS blocker never clears — no operator creates the namespace it watches.
    #
    # A blocked component is NOT a refusal. It is simply not skipped: it falls through to the same
    # two branches a component that ships operands takes, and the workshop installs its own operator
    # exactly as it would on a cluster with nothing to adopt. That is the safe direction and the
    # cheap one — a component wrongly KEPT costs an operator install nobody needed, a component
    # wrongly SKIPPED ships a half-built workshop whose every Argo status is green. Until 2026-08-06
    # this branch REFUSED the whole install instead, on a path that could not fire for the case it
    # was written for (every adoption signal for keycloak-operator is scoped to a namespace only we
    # create), while the real defect — dropping it whenever ANY rhbk-operator existed anywhere — went
    # unnoticed because half 2 did not exist. The reversal was put to the owner as its own decision
    # and approved 2026-08-06; see the asymmetry argument in the § header above.
    _keep_why=""   # non-empty ⇒ operator-only but blocked; names the reason for the messages below
    _skippable="false"
    if is_operator_only "$_cdir"; then
      _blockers="$(component_skip_blockers "$_facts" "$_comp" "$CSV_WATCH_TABLE" || true)"
      if [[ -z "$_blockers" ]]; then
        _skippable="true"
      else
        _sib="$(printf '%s\n' "$_blockers" | awk '{ print $3 }' | sort -u | tr '\n' ' ' | xargs || true)"
        _sns="$(printf '%s\n' "$_blockers" | awk '{ print $2 }' | sort -u | tr '\n' ' ' | xargs || true)"
        _keep_why="dropping it would leave sibling(s) ${_sib} without namespace(s)/operator coverage in ${_sns}, which only ${_comp} provides"
      fi
    fi

    if [[ "$_skippable" == "true" ]]; then
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      plan_add skip "$_stack" "$_comp" "$_child" "$CC_NS" "$CC_SUBS" "$CC_REASON"
      say "  • ${_comp}: already installed by this cluster's owner — using theirs, our component skipped"
      say "      evidence : ${CC_REASON}"
      say "      effect   : ${_child} is removed from the rendered ${_stack} stack — nothing of theirs is touched"
    elif [[ "$CC_HARD" == "true" ]]; then
      OG_CONFLICTS=$((OG_CONFLICTS + 1))
      plan_add refuse "$_stack" "$_comp" "$_child" "$CC_NS" "$CC_SUBS" "$CC_REASON"
      say "❌ ${CC_REASON}"
      say "   Component '${_comp}' would add a second one. OLM would then fail EVERY CSV in"
      say "   ${CC_NS%%,*} (TooManyOperatorGroups) while its pods keep running — a silent, invisible"
      say "   break of an operator this cluster's owner installed. Refusing to continue."
      if [[ -n "$_keep_why" ]]; then
        say "   '${_comp}' cannot be skipped the way an adoptable operator-only component is: ${_keep_why}."
      else
        say "   '${_comp}' ships operand CRs as well as the operator, so it cannot be skipped the way an"
        say "   operator-only component is: dropping it would leave the workshop quietly incomplete."
      fi
      say "   Choose one, then re-run:"
      say "     • install without the stack that ships it — drop '${_stack}' from --stacks"
      say "     • or remove the org's operator from ${CC_NS%%,*} first (their call, not ours)"
    else
      plan_add warn "$_stack" "$_comp" "$_child" "$CC_NS" "$CC_SUBS" "$CC_REASON"
      say "  ⚠ ${_comp}: ${CC_REASON}"
      if [[ -n "$_keep_why" ]]; then
        say "      '${_comp}' installs only an operator, but ${_keep_why} — so it is NOT skipped."
        say "      Ours installs ALONGSIDE theirs, in the same namespace. Nothing of theirs is deleted"
        say "      now — but the workshop's uninstall snapshot keys on OUR Subscription name, so an"
        say "      operator the org named differently is not recorded as adopted. Check both before"
        say "      you tear down:"
      else
        say "      '${_comp}' ships operand CRs as well as the operator, so it is NOT skipped — Argo will"
        say "      manage the existing Subscription. Check its channel is one the org expects:"
      fi
      say "        oc get subscriptions.operators.coreos.com -n ${CC_NS%%,*}"
    fi
  done < <(active_app_files "$_stack")
  rm -f "$_facts"   # per-stack; the loop completes before either exit below, so nothing leaks
done
# Same reasoning one level up: preflight is finished, and --adoption-plan exits three lines below.
[[ -z "$CSV_WATCH_TABLE" ]] || rm -f "$CSV_WATCH_TABLE"

if [[ "$ADOPTION_PLAN_ONLY" == "true" ]]; then
  [[ -n "$ADOPTION_PLAN" ]] && printf '%s\n' "$ADOPTION_PLAN"
  exit 0
fi

if [[ "$OG_CONFLICTS" -gt 0 ]]; then
  echo "❌ ${OG_CONFLICTS} unskippable adoption conflict(s) — nothing was applied, the cluster is untouched."
  exit 1
fi
echo "  ✓ ${OG_CHECKED} OperatorGroup namespace(s) checked · ${SKIPPED_COUNT} component(s) adopted-and-skipped"

# ── 1. GitOps operator ────────────────────────────────────────────────────────
# --stacks-only callers (the phase-2 mirror flip) already have a working Argo CD; re-running the
# operator dance would only be a slow no-op, so skip straight to the Applications.
if [[ "$STACKS_ONLY" == "true" ]]; then
  echo "▶ [1/2] GitOps operator step skipped (--stacks-only — Argo CD is already installed)"
else
  echo "▶ [1/2] Installing OpenShift GitOps operator (idempotent)…"
  if [[ "$DRY_RUN" == "true" ]]; then
    oc kustomize "${SCRIPT_DIR}/operator" >/dev/null && echo "  ✓ operator kustomization renders"
  else
    # Pre-installed detection: many managed/demo clusters ship GitOps already. Applying our
    # OperatorGroup next to an existing one breaks OLM (TooManyOperatorGroups) — reuse instead.
    # GITOPS_PREEXISTED is the caller's AUTHORITATIVE verdict (bootstrap/install.sh reads it from the
    # first-write-wins uninstall-state snapshot, so a re-install still knows who originally installed
    # GitOps). Standalone runs have no snapshot, so fall back to the live check below.
    GITOPS_ADOPTED="${GITOPS_PREEXISTED:-}"
    if oc get subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator >/dev/null 2>&1; then
      echo "  ✓ operator subscription already present — reusing existing install"
      GITOPS_ADOPTED="${GITOPS_ADOPTED:-true}"
    else
      oc apply -k "${SCRIPT_DIR}/operator"
      GITOPS_ADOPTED="${GITOPS_ADOPTED:-false}"
    fi
    echo "  … waiting for operator CSV to succeed (up to 5m)"
    for _ in $(seq 1 60); do
      CSV="$(oc get subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
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

    # The operator-default controller memory (2Gi) OOM-wedges under cohort-scale concurrent entry-state
    # materializations; raise it to 6Gi. On an instance WE installed that is unconditional. On an
    # ADOPTED one it is a mutation of something the org owns, so it is asked for, recorded, and undone
    # by ogsr-uninstall.sh's restore_argocd_controller_resources() — which is what makes it survivable
    # rather than the "unreversible, manual restore hint only" it used to be.
    if [[ "$GITOPS_ADOPTED" == "true" ]]; then
      # ADOPTED Argo CD: the controller sizing belongs to the org, so we ASK before changing it.
      #
      # Why asking beats either extreme (owner decision, 2026-07-31). Silently patching mutates
      # something the customer owns and restarts THEIR controller mid-workshop. Silently skipping
      # looks polite and is not: the operator default is 2Gi, the workshop-config Application alone
      # carries 636 resources, and the controller is OOMKilled (exit 137) before anything
      # materializes — measured on a clean cluster, where the whole workshop layer came up as 3
      # namespaces instead of ~70 with no sync operation ever recorded. The old behaviour printed a
      # hint and carried on, so the failure surfaced only after a full install run had "succeeded".
      #
      # So: consent, then act on the answer. Yes -> patch, recording the prior value so teardown can
      # put it back. No -> stop and do NOT install, because an install that cannot materialize is
      # worse than no install: it looks done and leaves an empty workshop.
      TARGET_MEM="$(grep -A2 'limits:' "${SCRIPT_DIR}/operator/argocd-controller-resources.yaml" 2>/dev/null \
                     | grep -m1 'memory:' | sed 's/.*memory:[[:space:]]*//' | tr -d '"' || true)"
      [[ -n "$TARGET_MEM" ]] || TARGET_MEM="6Gi"
      CUR_MEM="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.controller.resources.limits.memory}' 2>/dev/null || true)"
      DECISION="skip"
      # Tracks whether argocd-controller-resources.yaml was ACTUALLY applied, which is not the same
      # question as $DECISION. The already-at-target branch below decides "apply" and then applies
      # nothing, so keying the closing notice off $DECISION made the Subscription health-check
      # override go missing SILENTLY on exactly the cluster shape it exists for.
      HC_APPLIED="false"

      if [[ "$CUR_MEM" == "$TARGET_MEM" ]]; then
        echo "  ✓ adopted Argo CD controller already at ${CUR_MEM} — nothing to change"
        DECISION="apply"   # no memory change owed; the file is still not applied — see HC_APPLIED
      else
        echo
        echo "  ⚠️  This cluster's OpenShift GitOps is ADOPTED — it belongs to the cluster owner."
        echo "      Its application-controller memory limit is ${CUR_MEM:-the operator default 2Gi}."
        echo "      The workshop needs ${TARGET_MEM}: below that the controller is OOMKilled while"
        echo "      materializing entry states, and NOTHING the workshop installs will ever sync."
        echo
        echo "      Applying this changes a resource the org owns and RESTARTS their controller, which"
        echo "      briefly interrupts their own GitOps reconciliation. Before patching, the CR's whole"
        echo "      current spec.controller.resources is recorded so ogsr-uninstall.sh can put it back."
        echo "      If that recording fails you are told so on the spot, with the value to keep — this"
        echo "      prompt never promises a restore it has not yet been able to arrange."
        echo
        # Explicit env var wins (CI / the RHDP catalog item have no TTY); otherwise ask. With no TTY
        # and no env var we REFUSE — never mutate someone else's cluster on an assumption.
        DECISION="${OGSR_ADOPTED_ARGOCD_MEMORY:-}"
        if [[ -z "$DECISION" ]]; then
          if [[ -t 0 ]]; then
            printf '      Raise the adopted controller to %s and continue? [y/N] ' "$TARGET_MEM"
            read -r _reply </dev/tty || _reply=""
            case "$_reply" in [yY]|[yY][eE][sS]) DECISION="apply" ;; *) DECISION="refuse" ;; esac
          else
            DECISION="refuse"
            echo "      (no terminal to ask on — set OGSR_ADOPTED_ARGOCD_MEMORY=apply to consent up front)"
          fi
        fi

        if [[ "$DECISION" == "apply" ]]; then
          # Record BEFORE mutating: a half-applied patch must still leave us knowing what to restore.
          #
          # ONE FACT, ONE KEY. The prior value goes into gitops_argocd_controller_resources_b64 — the
          # key bootstrap/install.sh and helm/bootstrap's job-state-capture already write and
          # ogsr-uninstall.sh already reads — so every install entry point feeds ONE restore path.
          # A memory-only key cannot be that path: the override below sets limits.cpu, limits.memory,
          # requests.cpu AND requests.memory, so undoing it needs the whole resources block, and a
          # second key describing the same fact is exactly how the write-only-key drift started.
          # Written first-write-wins (only when unset): on a re-install the earliest snapshot is the
          # true prior, and this branch is only reached when the live value is NOT yet the target.
          #
          # argocd_controller_resources_changed_by_us is a genuinely DIFFERENT fact and earns its own
          # key: the b64 snapshot is also taken by passes that never mutate anything, so "a prior was
          # recorded" has never meant "we changed it", and teardown must only restore what we changed.
          #
          # An EMPTY prior is meaningful and is recorded by the ABSENCE of the b64 key: the CR carried
          # no explicit .spec.controller.resources at all. Teardown restores that by REMOVING the field
          # (a JSON-merge-patch null), not by writing a number back. Every writer of this key already
          # skips it when the value is empty, so absence is unambiguous — no sentinel needed.
          CUR_RES="$(oc get argocd openshift-gitops -n openshift-gitops \
                       -o jsonpath='{.spec.controller.resources}' 2>/dev/null || true)"
          # Same producer shape as bootstrap/install.sh:  <jsonpath output> | base64 | tr -d '\n'.
          # jsonpath emits no trailing newline and printf '%s' adds none, so the two writers produce
          # byte-identical values — which is what makes them interchangeable for one reader.
          CUR_RES_B64="$(printf '%s' "$CUR_RES" | base64 | tr -d '\n' || true)"
          [[ -n "$CUR_RES" ]] || CUR_RES_B64=""
          RECORDED="false"
          oc create namespace "$STATE_NS" >/dev/null 2>&1 || true
          oc create configmap "$STATE_CM" -n "$STATE_NS" >/dev/null 2>&1 || true
          if oc get configmap "$STATE_CM" -n "$STATE_NS" >/dev/null 2>&1; then
            PRIOR_RECORDED="$(oc get configmap "$STATE_CM" -n "$STATE_NS" \
                                -o jsonpath='{.data.gitops_argocd_controller_resources_b64}' 2>/dev/null || true)"
            # CARRIED RESIDUE. ogsr-uninstall keeps ${STATE_NS} when it could not put a value back,
            # pruned to the unrestored priors and stamped with residue_keys. For a key listed there
            # the org's original is ALREADY known — as the recorded value, or, when the key is
            # absent, as the fact that the CR carried no explicit .spec.controller.resources at all.
            # The live CR meanwhile still carries OUR sizing. So a carried key counts as recorded and
            # must not be re-derived: writing CUR_RES_B64 here would file the workshop's own leftover
            # as "the org's original", which is the 2026-07-31 state-lifetime defect. Absence stays
            # absence — the empty-prior encoding this whole restore path rests on.
            # bootstrap/install.sh's record_once and the FSC state-capture Job hold the same rule.
            RESIDUE_CARRIED=" $(oc get configmap "$STATE_CM" -n "$STATE_NS" \
                                  -o jsonpath='{.data.residue_keys}' 2>/dev/null | tr ',' ' ' | xargs || true) "
            case "$RESIDUE_CARRIED" in
              *" gitops_argocd_controller_resources_b64 "*)
                echo "  • prior controller sizing carried forward by a previous ogsr-uninstall — kept verbatim"
                PRIOR_RECORDED="carried" ;;
            esac
            RES_OK="true"
            if [[ -z "$PRIOR_RECORDED" && -n "$CUR_RES_B64" ]]; then
              oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge \
                -p "{\"data\":{\"gitops_argocd_controller_resources_b64\":\"${CUR_RES_B64}\"}}" >/dev/null 2>&1 \
                || RES_OK="false"
            fi
            if [[ "$RES_OK" == "true" ]] \
               && oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge \
                    -p '{"data":{"argocd_controller_resources_changed_by_us":"true"}}' >/dev/null 2>&1; then
              RECORDED="true"
            fi
          fi
          # If we could not record the prior value, REFUSE — do not patch (owner decision 2026-07-31).
          # We are about to mutate a CR the org owns. The consent we were given was consent to a
          # REVERSIBLE change; without the recording it is not reversible, so it is not the thing
          # they agreed to. Crucially, nothing has been touched at this point, so refusing is free:
          # the operator loses nothing and can re-run or raise it themselves. The previous behaviour
          # patched anyway behind a loud warning, but a warning in a 700-line install log is not a
          # decision anyone actually made — and this is the promise the whole workshop rests on.
          if [[ "$RECORDED" != "true" ]]; then
            echo
            echo "  ❌ could NOT record the prior value in ${STATE_NS}/${STATE_CM} — NOT installing."
            echo "     Nothing on this cluster has been changed."
            echo "     You consented to a reversible change. Without that record teardown cannot put"
            echo "     the controller back, so the change would not be reversible and we will not"
            echo "     make it on your behalf."
            echo "     Current value, for your records:"
            echo "       spec.controller.resources: ${CUR_RES:-<none — the CR carries no explicit resources>}"
            echo "     Fix the state ConfigMap (check RBAC on ${STATE_NS}) and re-run, or raise it"
            echo "     yourself and keep that value:"
            echo "       oc -n openshift-gitops patch argocd openshift-gitops --type merge \\"
            echo "         -p '{\"spec\":{\"controller\":{\"resources\":{\"limits\":{\"memory\":\"${TARGET_MEM}\"},\"requests\":{\"memory\":\"2Gi\"}}}}}'"
            exit 1
          fi
          oc apply -f "${SCRIPT_DIR}/operator/argocd-controller-resources.yaml"
          HC_APPLIED="true"
          echo "  ✓ adopted controller raised to ${TARGET_MEM} with consent"
          echo "    prior spec.controller.resources recorded — ogsr-uninstall.sh restores it"
        else
          echo
          echo "  ❌ declined — NOT installing. Nothing on this cluster has been changed."
          echo "     An install against a ${CUR_MEM:-2Gi} controller cannot materialize: it would look"
          echo "     like it worked and leave you with an empty workshop."
          echo "     To proceed later, re-run and answer yes, or raise it yourself first:"
          echo "       oc -n openshift-gitops patch argocd openshift-gitops --type merge \\"
          echo "         -p '{\"spec\":{\"controller\":{\"resources\":{\"limits\":{\"memory\":\"${TARGET_MEM}\"},\"requests\":{\"memory\":\"2Gi\"}}}}}'"
          exit 1
        fi
      fi

      # The same file carries the Subscription resourceHealthChecks override. If it was never applied,
      # say so rather than let it go missing silently on exactly the cluster shape where it matters.
      # Gated on HC_APPLIED, not $DECISION: on an instance already at the target the file is not
      # applied either, and that case used to print nothing at all — the override was absent and the
      # log implied it was there.
      if [[ "$HC_APPLIED" != "true" ]]; then
        echo "  • skipped on this adopted instance: the operators.coreos.com/Subscription health-check"
        echo "    override. Without it an ADOPTED operator whose Subscription carries a stale condition"
        echo "    can show its Application Degraded while the operator is fine. To opt in (it is a"
        echo "    change to the org's ArgoCD CR, which is why it is not applied unasked):"
        echo "      oc apply -f ${SCRIPT_DIR}/operator/argocd-controller-resources.yaml   # NOTE: also sets the ${TARGET_MEM} memory limit"
      fi
    else
      oc apply -f "${SCRIPT_DIR}/operator/argocd-controller-resources.yaml"
      echo "  ✓ controller resources raised (6Gi limit / 2Gi request)"
    fi
  fi
fi

# ── 2. AppProject + stack Applications ────────────────────────────────────────
# The project goes first: an Application naming a project that does not exist never syncs, and the
# error ("Application referencing project X which does not exist") is far from the real cause.
echo "▶ [2/2] Applying AppProject ${PROJECT} + stack Applications…"

# Both lists are UNIONED with whatever the live project already permits. A consumer layer widens
# this project through --allow-source-repo / --allow-destination, and a later standalone re-run of
# this installer would otherwise silently narrow it again — revoking the mirror the stacks are
# currently sourcing from, or the namespaces a consumer's Application deploys into. Removing an
# entry for real means deleting the project (which teardown does anyway).
REPOS_FILE="$(mktemp)"
DESTS_FILE="$(mktemp)"
SKIP_FILE="$(mktemp)"
trap 'rm -f "$REPOS_FILE" "$DESTS_FILE" "$SKIP_FILE"' EXIT

# Argo matches sourceRepos as globs against the Application's repoURL, and repo URLs are written
# both with and without the .git suffix across this tree — emit both spellings of every entry so a
# harmless cosmetic difference can never read as "repo not permitted in project".
{
  for _repo in "$REPO_URL" "$SOURCE_REPO" ${EXTRA_SOURCE_REPOS[@]+"${EXTRA_SOURCE_REPOS[@]}"}; do
    [[ -n "$_repo" ]] || continue
    printf '    - %s\n    - %s.git\n' "${_repo%.git}" "${_repo%.git}"
  done
  oc get appproject "$PROJECT" -n "$ARGO_NS" \
    -o jsonpath='{range .spec.sourceRepos[*]}    - {@}{"\n"}{end}' 2>/dev/null || true
} | sed '/^[[:space:]]*$/d' | sort -u > "$REPOS_FILE"

# Destinations the template does not already carry (consumer layers add their own namespaces),
# plus everything the live project already permits.
{
  for _ns in ${EXTRA_DESTINATIONS[@]+"${EXTRA_DESTINATIONS[@]}"}; do
    [[ -n "$_ns" ]] || continue
    printf "    - {server: https://kubernetes.default.svc, namespace: '%s'}\n" "$_ns"
  done
  # `|| true` + an in-loop emptiness guard, NOT `| grep .`: on a FIRST install the AppProject does
  # not exist yet, so both `oc get` and a `grep .` with no input exit non-zero — and under
  # `set -o pipefail` that is the last command of this group, so the whole installer died before it
  # could create the project it was looking for. (Introduced 499aea1, never reached because the
  # section-0 refusal fired first.)
  { oc get appproject "$PROJECT" -n "$ARGO_NS" \
      -o jsonpath='{range .spec.destinations[*]}{.namespace}{"\n"}{end}' 2>/dev/null || true; } \
    | while IFS= read -r _ns; do
        [[ -n "$_ns" ]] || continue
        # Already in the template body → skip, so the rendered file has no duplicates.
        grep -qF "namespace: '${_ns}'" "${SCRIPT_DIR}/appproject.template.yaml" && continue
        grep -qE "namespace: ${_ns}\$|namespace: ${_ns} " "${SCRIPT_DIR}/appproject.template.yaml" && continue
        printf "    - {server: https://kubernetes.default.svc, namespace: '%s'}\n" "$_ns"
      done
  # sed, not `grep -v`: grep exits 1 on empty input, and under `set -o pipefail` that killed a
  # standalone `--stacks <x>` install (no --allow-destination, no pre-existing project → no lines).
} | sed '/^[[:space:]]*$/d' | sort -u > "$DESTS_FILE"

# sed's `r` reads a list in after the marker line; the paired `d` drops the marker itself.
# (A plain s/// cannot carry a multi-line replacement portably across GNU and BSD sed.)
sed -e "s|__PROJECT__|${PROJECT}|g" \
    -e "s|__ARGO_NAMESPACE__|${ARGO_NS}|g" \
    -e "/__SOURCE_REPOS__/r ${REPOS_FILE}" \
    -e "/__SOURCE_REPOS__/d" \
    -e "/__EXTRA_DESTINATIONS__/r ${DESTS_FILE}" \
    -e "/__EXTRA_DESTINATIONS__/d" \
    "${SCRIPT_DIR}/appproject.template.yaml" | "${APPLY[@]}"
echo "  ✓ AppProject ${PROJECT} applied ($(wc -l < "$REPOS_FILE" | tr -d ' ') source repo pattern(s), $(wc -l < "$DESTS_FILE" | tr -d ' ') extra destination(s))"

# Render the section-0 skip decisions as kustomize patches on the parent Application. The parent
# already rewrites repoURL/targetRevision/project across all 32 children this way; a strategic-merge
# patch carrying `$patch: delete` removes a child outright (JSON6902 has no delete-resource op). The
# repo is never edited at install time — the decision travels in the Application, so re-running with
# the same cluster state renders the same manifest.
render_skip_patches() {  # <stack> → the patch block for every component skipped in that stack
  local stack="$1" verb s comp child ns subs reason
  : > "$SKIP_FILE"
  [[ -n "$ADOPTION_PLAN" ]] || return 0
  while IFS=$'\t' read -r verb s comp child ns subs reason; do
    [[ "$verb" == "skip" && "$s" == "$stack" ]] || continue
    : "$ns" "$subs"   # carried for the workshop layer's uninstall snapshot, not needed here
    skip_patch_block "$child" "$comp" "$reason" "$ARGO_NS" >> "$SKIP_FILE"
  done <<< "$ADOPTION_PLAN"
}

IFS=',' read -ra STACK_ARR <<< "$STACKS"
for stack in "${STACK_ARR[@]}"; do
  stack="$(echo "$stack" | xargs)"  # trim
  if [[ ! -d "${SCRIPT_DIR}/../stacks/${stack}" ]]; then
    echo "❌ unknown stack '${stack}' (no stacks/${stack}/ directory)"; exit 1
  fi
  render_skip_patches "$stack"
  # sed's `r` reads the block in after the marker line; the paired `d` drops the marker itself.
  sed -e "s|__STACK__|${stack}|g" \
      -e "s|__REPO_URL__|${REPO_URL}|g" \
      -e "s|__SOURCE_REPO_URL__|${SOURCE_REPO}|g" \
      -e "s|__REVISION__|${REVISION}|g" \
      -e "s|__PROJECT__|${PROJECT}|g" \
      -e "/__SKIP_PATCHES__/r ${SKIP_FILE}" \
      -e "/__SKIP_PATCHES__/d" \
      "${SCRIPT_DIR}/stack-app.template.yaml" | "${APPLY[@]}"
  _skipped_here="$(grep -c '^        - target:' "$SKIP_FILE" || true)"
  if [[ "${_skipped_here:-0}" -gt 0 ]]; then
    echo "  ✓ Application pp-${stack} applied (${_skipped_here} adopted component(s) dropped from the render)"
  else
    echo "  ✓ Application pp-${stack} applied"
  fi
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
# Say plainly what this cluster is NOT getting from us, and why. An operator silently absent from the
# portfolio is the kind of surprise that surfaces three modules later.
if [[ "$SKIPPED_COUNT" -gt 0 ]]; then
  echo "   adopted — already on this cluster, so ours was never installed:"
  while IFS=$'\t' read -r _v _s _c _rest; do
    [[ "$_v" == "skip" ]] || continue
    : "$_s" "$_rest"
    echo "     • ${_c}: already installed by this cluster's owner — using theirs, our component skipped"
  done <<< "$ADOPTION_PLAN"
fi
echo "   Watch: oc get applications -n openshift-gitops"
