#!/usr/bin/env bash
# Platform Portfolio bootstrap — the ONLY imperative step of the portfolio.
# Mutates exactly twice: (1) install the OpenShift GitOps operator (+ controller RBAC),
# (2) apply the portfolio AppProject and one Argo CD Application per requested stack.
# Everything else reconciles. Ahead of both, a read-only preflight refuses to install where
# doing so would break an operator the cluster's owner already runs (see section 0).
#
# Usage:
#   ./install.sh --stacks core-devtools[,ai-assist,...]
#                [--repo-url <git url>] [--revision <branch|tag>]
#                [--source-repo <git url>] [--allow-source-repo <git url>]…
#                [--allow-destination <namespace glob>]…
#                [--project <name>] [--stacks-only] [--skip-repo-check]
#                [--wait] [--dry-run]
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

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -31; exit 1; }

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

echo "▶ Platform Portfolio bootstrap"
echo "  cluster : $(oc whoami --show-server) (as $(oc whoami))"
echo "  source  : ${REPO_URL} @ ${REVISION}"
echo "  mirrors : ${SOURCE_REPO}"
echo "  project : ${PROJECT}"
echo "  stacks  : ${STACKS}"

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

if [[ "$SKIP_REPO_CHECK" == "true" ]]; then
  echo "▶ source repo validation skipped (--skip-repo-check)"
else
  echo "▶ validating source repo (read-only)…"
  validate_source_repo "$REPO_URL" "$REVISION" \
    || { echo "❌ nothing was applied, the cluster is untouched."; exit 1; }
fi

# ── 0. OperatorGroup collision preflight (READ-ONLY, blocking) ────────────────
# OLM fails EVERY CSV in a namespace holding more than one OperatorGroup — phase Failed, reason
# TooManyOperatorGroups, "can't pick one automatically" — and it does so SILENTLY: the operator's
# pods keep running, so nothing looks broken while OLM has stopped managing it entirely (no upgrades,
# no self-heal). Found live 2026-07-25: pp-cert-manager applied our OperatorGroup into an ADOPTED
# cert-manager-operator namespace and the org's CSV failed one second later. Breaking somebody else's
# operator, invisibly and irreversibly, is exactly what this repo forbids — so this is a hard refusal
# BEFORE anything is applied, not a warning afterwards.
#
# Argo CD has no "create only if absent" primitive, so prevention cannot live in the manifests: the
# decision has to be made once, here, in the portfolio's single sanctioned imperative step. Read-only
# throughout — the worst this can do is decline to install.
OG_OWNER_KEY="workshop.redhat.com/owner"
OG_OWNER_VALUE="ogsr"
STACKS_DIR="$(cd "${SCRIPT_DIR}/../stacks" && pwd)"

active_app_files() {  # <stack> → each apps/*.yaml the stack's kustomization actually includes
  # Read the kustomization rather than globbing apps/: several stacks ship an app file that is
  # deliberately COMMENTED OUT (loki-logging, service-interconnect), and preflighting a component we
  # will never apply would refuse an install for no reason.
  sed -n 's|^[[:space:]]*-[[:space:]]*\(apps/[A-Za-z0-9._-]*\.yaml\)[[:space:]]*$|\1|p' \
    "${STACKS_DIR}/${1}/kustomization.yaml" 2>/dev/null
}

operatorgroup_namespaces() {  # <stack> → "<namespace> <component>" per OperatorGroup the stack ships
  local stack="$1" app comp_path og ns
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    comp_path="$(grep -m1 -E '^[[:space:]]+path:[[:space:]]' "${STACKS_DIR}/${stack}/${app}" 2>/dev/null \
                  | sed 's|.*path:[[:space:]]*||')"
    [[ -n "$comp_path" ]] || continue
    for og in "${SCRIPT_DIR}/../../${comp_path}"/operatorgroup*.yaml; do
      [[ -e "$og" ]] || continue
      # metadata.namespace is the only 2-space-indented `namespace:` in these single-doc files;
      # spec.targetNamespaces entries are list items at 4 spaces and never match.
      ns="$(grep -m1 -E '^  namespace:[[:space:]]' "$og" | sed 's|.*namespace:[[:space:]]*||')"
      [[ -n "$ns" ]] && echo "${ns} $(basename "$comp_path")"
    done
  done < <(active_app_files "$stack")
}

foreign_operatorgroups_in() {  # <namespace> → names of OperatorGroups there that are NOT ours
  oc get operatorgroups.operators.coreos.com -n "$1" \
    -o jsonpath="{range .items[*]}{.metadata.name}{'|'}{.metadata.labels.${OG_OWNER_KEY//./\\.}}{'\n'}{end}" \
    2>/dev/null | awk -F'|' -v ours="$OG_OWNER_VALUE" '$1 != "" && $2 != ours { print $1 }'
}

echo "▶ [0/2] OperatorGroup collision preflight (read-only)…"
OG_CONFLICTS=0
OG_CHECKED=0
IFS=',' read -ra PREFLIGHT_STACKS <<< "$STACKS"

# The bootstrap's own OperatorGroup is only applied when we also create the Subscription (the reuse
# branch below skips `oc apply -k operator/` entirely), so preflight it only in that case.
PREFLIGHT_PAIRS=""
if ! oc get subscriptions.operators.coreos.com openshift-gitops-operator \
      -n openshift-gitops-operator >/dev/null 2>&1; then
  PREFLIGHT_PAIRS="openshift-gitops-operator argocd-bootstrap"
fi
for _stack in "${PREFLIGHT_STACKS[@]}"; do
  _stack="$(echo "$_stack" | xargs)"
  [[ -d "${STACKS_DIR}/${_stack}" ]] || continue
  PREFLIGHT_PAIRS="${PREFLIGHT_PAIRS}${PREFLIGHT_PAIRS:+$'\n'}$(operatorgroup_namespaces "$_stack")"
done

while read -r og_ns og_comp; do
  [[ -n "$og_ns" ]] || continue
  OG_CHECKED=$((OG_CHECKED + 1))

  # Static rule, true on every cluster: openshift-operators ALWAYS ships the cluster-wide
  # `global-operators` OperatorGroup, so shipping one there is a guaranteed collision with the widest
  # possible blast radius — every operator the org installed cluster-wide stops being reconciled.
  if [[ "$og_ns" == "openshift-operators" ]]; then
    echo "❌ component '${og_comp}' ships an OperatorGroup into openshift-operators"
    echo "   That namespace always has OpenShift's own cluster-wide 'global-operators' OperatorGroup."
    echo "   Fix in git: delete components/${og_comp}/operatorgroup*.yaml and drop it from the"
    echo "   component's kustomization — an operator installed there needs no OperatorGroup of ours."
    OG_CONFLICTS=$((OG_CONFLICTS + 1))
    continue
  fi

  _foreign="$(foreign_operatorgroups_in "$og_ns" | tr '\n' ' ' | xargs || true)"
  [[ -n "$_foreign" ]] || continue
  echo "❌ namespace ${og_ns} already has an OperatorGroup that is not ours: ${_foreign}"
  echo "   Component '${og_comp}' would add a second one. OLM would then fail EVERY CSV in"
  echo "   ${og_ns} (TooManyOperatorGroups) while its pods keep running — a silent, invisible"
  echo "   break of an operator this cluster's owner installed. Refusing to continue."
  echo "   Fix: this cluster already runs that operator, so do not install ours. Remove"
  echo "     apps/${og_comp}.yaml from the stack kustomization that ships it and re-run:"
  echo "       grep -rl '${og_comp}' ${STACKS_DIR}/*/kustomization.yaml"
  OG_CONFLICTS=$((OG_CONFLICTS + 1))
done <<< "$PREFLIGHT_PAIRS"

if [[ "$OG_CONFLICTS" -gt 0 ]]; then
  echo "❌ ${OG_CONFLICTS} OperatorGroup collision(s) — nothing was applied, the cluster is untouched."
  exit 1
fi
echo "  ✓ ${OG_CHECKED} OperatorGroup namespace(s) checked — none already carries a foreign one"

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
    # materializations; raise it to 6Gi. ONLY on an Argo CD we installed ourselves. On an ADOPTED
    # instance this is an unreversible mutation of something the org owns — uninstall could do no better
    # than print a manual restore hint, which fails the "no trace" bar. Their instance keeps their sizing
    # and we tell the admin exactly what to raise if the controller starts OOMing under load.
    if [[ "$GITOPS_ADOPTED" == "true" ]]; then
      # Read the target from the canonical override so the hint can never drift from what we'd apply.
      # grep, not yq: the portfolio installer must run on a box with nothing but oc.
      TARGET_MEM="$(grep -A2 'limits:' "${SCRIPT_DIR}/operator/argocd-controller-resources.yaml" 2>/dev/null \
                     | grep -m1 'memory:' | sed 's/.*memory:[[:space:]]*//' | tr -d '"' || true)"
      [[ -n "$TARGET_MEM" ]] || TARGET_MEM="6Gi"
      CUR_MEM="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.controller.resources.limits.memory}' 2>/dev/null || true)"
      echo "  • adopted Argo CD instance — controller resources left at the org's settings (${CUR_MEM:-operator default 2Gi})"
      echo "    if the application-controller OOMKills while a cohort materializes entry states, raise it:"
      echo "      oc -n openshift-gitops patch argocd openshift-gitops --type merge \\"
      echo "        -p '{\"spec\":{\"controller\":{\"resources\":{\"limits\":{\"memory\":\"${TARGET_MEM}\"},\"requests\":{\"memory\":\"2Gi\"}}}}}'"
      echo "    that is YOUR change to make and to keep — this installer will not touch it, and uninstall will not revert it."
      # Same file also carries the Subscription resourceHealthChecks override; skipping the file skips
      # that too, so say so rather than let it go missing silently on exactly the cluster shape (adopted
      # operators) where it matters most. See the header of argocd-controller-resources.yaml for why.
      echo "  • also skipped on this adopted instance: the operators.coreos.com/Subscription health-check"
      echo "    override. Without it an ADOPTED operator whose Subscription carries a stale condition can"
      echo "    show its Application Degraded while the operator is fine. To opt in:"
      echo "      oc apply -f ${SCRIPT_DIR}/operator/argocd-controller-resources.yaml   # NOTE: also applies the ${TARGET_MEM} memory bump"
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
trap 'rm -f "$REPOS_FILE" "$DESTS_FILE"' EXIT

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
} | grep -v '^[[:space:]]*$' | sort -u > "$REPOS_FILE"

# Destinations the template does not already carry (consumer layers add their own namespaces),
# plus everything the live project already permits.
{
  for _ns in ${EXTRA_DESTINATIONS[@]+"${EXTRA_DESTINATIONS[@]}"}; do
    [[ -n "$_ns" ]] || continue
    printf "    - {server: https://kubernetes.default.svc, namespace: '%s'}\n" "$_ns"
  done
  oc get appproject "$PROJECT" -n "$ARGO_NS" \
    -o jsonpath='{range .spec.destinations[*]}{.namespace}{"\n"}{end}' 2>/dev/null \
    | grep . \
    | while IFS= read -r _ns; do
        # Already in the template body → skip, so the rendered file has no duplicates.
        grep -qF "namespace: '${_ns}'" "${SCRIPT_DIR}/appproject.template.yaml" && continue
        grep -qE "namespace: ${_ns}\$|namespace: ${_ns} " "${SCRIPT_DIR}/appproject.template.yaml" && continue
        printf "    - {server: https://kubernetes.default.svc, namespace: '%s'}\n" "$_ns"
      done
} | grep -v '^[[:space:]]*$' | sort -u > "$DESTS_FILE"

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

IFS=',' read -ra STACK_ARR <<< "$STACKS"
for stack in "${STACK_ARR[@]}"; do
  stack="$(echo "$stack" | xargs)"  # trim
  if [[ ! -d "${SCRIPT_DIR}/../stacks/${stack}" ]]; then
    echo "❌ unknown stack '${stack}' (no stacks/${stack}/ directory)"; exit 1
  fi
  sed -e "s|__STACK__|${stack}|g" \
      -e "s|__REPO_URL__|${REPO_URL}|g" \
      -e "s|__SOURCE_REPO_URL__|${SOURCE_REPO}|g" \
      -e "s|__REVISION__|${REVISION}|g" \
      -e "s|__PROJECT__|${PROJECT}|g" \
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
