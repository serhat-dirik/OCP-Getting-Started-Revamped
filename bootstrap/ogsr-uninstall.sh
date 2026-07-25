#!/usr/bin/env bash
# ogsr-uninstall.sh — non-destructive uninstall for the OCP-Getting-Started workshop.
#
# Removes EXACTLY what this workshop installed onto a cluster and reverses every shared/default-object
# mutation, while NEVER touching operators, namespaces, or config the org already had. It is the
# inverse of bootstrap/install.sh and reads the ogsr-uninstall-state ConfigMap that install.sh writes.
#
# The two guarantees:
#   1. Adopted operators are NEVER removed. install.sh recorded, per operator, whether it pre-existed
#      (adopted) or was created by us; only "created" operators are removed here. Unknown → preserved.
#   2. Our Applications are CASCADE-deleted, so deleting them IS the uninstall: Argo prunes what it
#      installed, in reverse sync-wave order, which keeps each operator alive while its own operand CR
#      is removed so the CR's finalizer runs and the operator cleans up its webhooks/APIServices at the
#      source. Adopted resources are protected INDIVIDUALLY (argocd.argoproj.io/sync-options carrying
#      Prune=false,Delete=false — applied by install.sh's protect_adopted_resources), so the cascade
#      removes our resources and never theirs. This script VERIFIES that protection before it cascades
#      and REFUSES to run without it (see --cascade-unprotected).
#   3. The cascade runs in three ORDERED, blocking phases — consumers before providers. Argo orders
#      prunes WITHIN one Application (reverse sync-wave); it has no ordering BETWEEN app-of-apps roots,
#      so deleting all roots at once races. See § cascade ordering for the two dependencies that cross
#      that boundary and what each one cost.
#   4. No step can silently skip the ones after it. Every step runs through run_step(), which reports a
#      failure and continues, and an EXIT trap always prints a ledger of which steps actually ran.
#      A half-finished uninstall that says nothing is worse than a reported failure: the imperative
#      mutations (OAuth IdP, node taint, htpasswd, console plugins) are reversed by the LATER steps.
#
# Shared/default objects are RESTORED, not blindly deleted: cluster-monitoring-config's
# enableUserWorkload returns to its recorded prior value (or the ConfigMap is removed if we created it);
# the workshop-users OAuth IdP entry is removed while every other IdP is preserved; node labels/taint
# are reversed; the GatewayClass / GitOps operator are removed only if we created them.
#
# Usage:
#   ./ogsr-uninstall.sh --dry-run     # print the WIPE/PRESERVE plan and intended actions; change nothing
#   ./ogsr-uninstall.sh               # interactive confirm, then uninstall
#   ./ogsr-uninstall.sh --yes         # no prompt (CI / scripted)
#   ./ogsr-uninstall.sh --cascade-timeout SECONDS
#                                     # TOTAL seconds to let Argo finish pruning, shared across the three
#                                     # ordered cascade phases below (default 900). Each phase is still
#                                     # guaranteed a 60s floor, so a slow phase 1 cannot starve phase 3.
#   ./ogsr-uninstall.sh --cascade-unprotected
#                                     # DANGEROUS. Cascade even though adopted resources are NOT annotated
#                                     # Prune=false,Delete=false. What you are risking: Argo prunes every
#                                     # resource it manages, and on this cluster that set includes
#                                     # Subscriptions, CSVs, OperatorGroups and NAMESPACES that belonged to
#                                     # the org BEFORE the workshop was installed. They will be DELETED and
#                                     # this script cannot put them back — deleting an operator's namespace
#                                     # takes its operands, and their data, with it. The supported fix is to
#                                     # re-run ./bootstrap/install.sh (its protection pass is idempotent and
#                                     # merges into any sync-options already set); use this flag only when
#                                     # you have confirmed by hand that nothing on the cluster is adopted.
#
# After this finishes, run ./bootstrap/ogsr-check-clean.sh — a read-only report of anything that outlived
# the teardown (stale APIServices, dead webhooks, CRDs), with the exact removal command for each.
#
# Idempotent: safe to re-run; already-absent objects are skipped with a printed reason.
# NOTE: every cluster interaction below is unverified off-cluster — run against a disposable cluster
# first. Lines that need live verification are marked  # TODO(verify-on-cluster).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OWNER_LABEL="workshop.redhat.com/owner=ogsr"
STATE_NS="ogsr-system"
STATE_CM="ogsr-uninstall-state"
ARGO_NS="openshift-gitops"
POOL_KEY="workshop.redhat.com/pool"
ZONE_KEY="workshop.redhat.com/zone"

# Argo prunes an Application's resources on delete ONLY while this finalizer is on the Application.
# Without it, `oc delete application` removes the object and silently ORPHANS everything it managed —
# and `--cascade=foreground/background` does not change that, because those are Kubernetes
# ownerReference semantics and Argo tracks its resources by annotation, not ownerReferences. VERIFIED
# in-repo 2026-07-25: 0 of the 32 platform-portfolio child app manifests, and neither the pp-<stack>
# template nor the workshop-config Application, declare it — only tools/ws's entry-* apps do. So the
# uninstall ADDS it before deleting (this is exactly what `argocd app delete --cascade` does).
ARGO_FINALIZER="resources-finalizer.argocd.argoproj.io"
SYNC_OPTS_ANN="argocd.argoproj.io/sync-options"
# Argo stamps this on every resource it manages. Its presence is the precise answer to the only
# question the protection guard needs: "would the cascade prune this object?"
TRACK_ANN="argocd.argoproj.io/tracking-id"
TRACK_LABEL="app.kubernetes.io/instance"   # the older tracking method, checked too

DRY_RUN="false"
ASSUME_YES="false"
FORCE_UNPROTECTED="false"
CASCADE_TIMEOUT=900
# Namespaces we actually issued a delete for — F6 waits on exactly these to finish terminating.
DELETED_WS_NS=()

ok()   { echo "✅ $*"; }
err()  { echo "❌ $*" >&2; }
info() { echo "▶ $*"; }
die()  { err "$*"; exit 1; }

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,57p'; exit 1; }

# ── step resilience ───────────────────────────────────────────────────────────
# On 2026-07-25 this script printed "[3/8]" and stopped. No error, no summary. Steps 4-8 — OAuth IdP
# removal, console plugins, htpasswd, Lightspeed, monitoring restore, node unshaping, cluster RBAC,
# the AppProject, the Argo TLS key, GitOps handling and namespace deletion — never ran, and the
# cluster was left with every imperative mutation still in place and nothing on screen saying so.
#
# The cause was one line: `[[ -n "$csv" ]] && del_obj …` as the LAST statement of a loop body. With an
# empty $csv the AND-list returns 1, so the loop returns 1, so the function returns 1 — and a function
# CALL that returns non-zero is not exempt from `set -e`, so the shell exited. Nothing was wrong; the
# operator simply had no CSV to delete. That shape is a landmine anywhere it ends a function, and it
# hides perfectly: it only fires once the branch that leaves the value empty is actually taken.
#
# Three layers, because one is not enough:
#   1. every `cond && cmd` used as a statement is now an `if` (so a false condition is not a failure);
#   2. every action/enumerator function ends in an explicit `return 0` (so its status means "ran",
#      never "the last thing I evaluated happened to be false") — predicates are exempt and marked;
#   3. this wrapper. `set -e` is suppressed for the whole dynamic extent of a command whose status is
#      tested, so a non-zero return anywhere inside a step is RECORDED and the run continues.
#      `set -euo pipefail` stays on: unset variables are still fatal, containment is per-step.
STEP_TOTAL=8
STEP_LEDGER=""        # "<status>|<label>" per step, in run order — the EXIT summary reads only this
STEP_FAILED=0
STEP_SUB_FAILED=0     # non-zero returns from sub-actions inside the step currently running
STEPS_STARTED="false"
STATE_DUMP=""         # set in step 8; the EXIT summary references it, so it must always be defined

sub() {  # <fn> [args…] — one action inside a step: report a non-zero return, run the rest anyway
  local rc=0
  "$@" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    err "   ${1}() returned exit ${rc} — the remaining actions in this step still run"
    STEP_SUB_FAILED=$((STEP_SUB_FAILED + 1))
  fi
  return 0
}

run_step() {  # <label> <fn> [args…] — run one uninstall step; a failure is reported, never fatal
  local label="$1" rc=0
  shift
  STEPS_STARTED="true"
  STEP_SUB_FAILED=0
  info "$label"
  "$@" || rc=$?
  if [[ "$rc" -eq 0 && "$STEP_SUB_FAILED" -eq 0 ]]; then
    STEP_LEDGER="${STEP_LEDGER}ok|${label}"$'\n'
    return 0
  fi
  if [[ "$rc" -eq 0 ]]; then
    STEP_LEDGER="${STEP_LEDGER}ran, ${STEP_SUB_FAILED} action(s) failed|${label}"$'\n'
  else
    STEP_LEDGER="${STEP_LEDGER}step function returned exit ${rc}|${label}"$'\n'
    err "step returned exit ${rc}: ${label}"
  fi
  STEP_FAILED=$((STEP_FAILED + 1))
  err "   continuing with the remaining steps — a half-finished uninstall is worse than a reported one"
  return 0
}

print_run_summary() {  # <shell exit status> — the ONE place that says what happened, so it cannot lie
  local rc="$1" ran=0 status label
  echo
  echo "STEPS THAT RAN (${STEP_TOTAL} total):"
  while IFS='|' read -r status label; do
    [[ -n "$label" ]] || continue
    ran=$((ran + 1))
    if [[ "$status" == "ok" ]]; then echo "   ✅ ${label}"; else echo "   ❌ ${label} — ${status}"; fi
  done <<< "$STEP_LEDGER"
  echo
  if [[ "$ran" -lt "$STEP_TOTAL" ]]; then
    err "EXITED EARLY after ${ran} of ${STEP_TOTAL} steps (shell exit ${rc}) — steps $((ran + 1))-${STEP_TOTAL} did NOT run."
    err "   Whatever they reverse is still in place on this cluster. Every step is idempotent:"
    err "   fix the cause above and re-run this script — it will skip what is already gone."
  elif [[ "$STEP_FAILED" -gt 0 ]]; then
    err "all ${STEP_TOTAL} steps ran; ${STEP_FAILED} reported a failure (details above). Re-run when fixed."
  elif [[ "$DRY_RUN" == "true" ]]; then
    ok "ogsr-uninstall dry-run complete — all ${STEP_TOTAL} steps evaluated, nothing changed"
  else
    ok "ogsr-uninstall complete — all ${STEP_TOTAL} steps ran"
  fi
  echo
  echo "   NEXT — check what outlived the teardown (read-only, deletes nothing):"
  if [[ -r "$STATE_DUMP" ]]; then
    echo "     ./bootstrap/ogsr-check-clean.sh --state-file ${STATE_DUMP}"
  else
    echo "     ./bootstrap/ogsr-check-clean.sh"
  fi
  return 0
}

on_exit() {  # EXIT trap — fires on the normal end AND on any early death, so silence is impossible
  local rc=$?
  trap - EXIT
  if [[ "$STEPS_STARTED" == "true" ]]; then print_run_summary "$rc"; fi
  exit "$rc"
}
trap on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift;;
    --yes|-y)  ASSUME_YES="true"; shift;;
    --cascade-timeout)
      [[ -n "${2:-}" ]] || { err "--cascade-timeout needs a value in seconds"; usage; }
      [[ "$2" =~ ^[0-9]+$ ]] || { err "--cascade-timeout must be a whole number of seconds, got: $2"; usage; }
      CASCADE_TIMEOUT="$2"; shift 2;;
    --cascade-unprotected) FORCE_UNPROTECTED="true"; shift;;
    -h|--help) usage;;
    *) err "unknown flag: $1"; usage;;
  esac
done

# ── preflight ─────────────────────────────────────────────────────────────────
command -v oc >/dev/null || die "oc not found in PATH"
command -v yq >/dev/null || die "yq not found — needed to read component manifests (brew install yq)"
oc whoami >/dev/null 2>&1 || die "not logged in — run: oc login …"
oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
  || die "need cluster-admin to uninstall (oc auth can-i '*' '*' failed as $(oc whoami))"

if ! oc get configmap "$STATE_CM" -n "$STATE_NS" >/dev/null 2>&1; then
  err "uninstall-state ConfigMap ${STATE_NS}/${STATE_CM} not found."
  err "Without it, adopted-vs-created is unknown and this script defaults to PRESERVING operators/shared"
  err "objects (safe). It still removes owner-labeled (${OWNER_LABEL}) resources + workshop namespaces."
fi

# ── state helpers ─────────────────────────────────────────────────────────────
STATE_SNAPSHOT=""    # whole state CM cached as key=value lines — it is immutable until step 9 deletes it,
STATE_LOADED="false" # so one read serves the ~60 lookups a full run makes (a per-lookup oc call is minutes).
state() {  # key [default] — echo a recorded value from the uninstall-state ConfigMap (or the default)
  local k="$1" def="${2:-}" v
  if [[ "$STATE_LOADED" != "true" ]]; then
    # $k/$v are go-template variables, not shell variables — the single quotes are intentional.
    # shellcheck disable=SC2016
    STATE_SNAPSHOT="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o go-template='{{range $k,$v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null || true)"
    STATE_LOADED="true"
  fi
  v="$(printf '%s\n' "$STATE_SNAPSHOT" | grep -m1 "^${k}=" | cut -d= -f2- || true)"
  if [[ -n "$v" ]]; then echo "$v"; else echo "$def"; fi
  return 0
}

# Re-derive the operators the install installed, from the SAME component manifests + recorded stacks.
# Echoes one "subname namespace state package" line per operator (state = created|adopted|unknown).
# The 4th field is the OLM PACKAGE name, which is what identifies the operator's CSV once its
# Subscription is gone — see § operator CSV identity below. Every consumer reads four fields; a
# three-field `read` would silently absorb the package into $st and classify every operator as
# "not created", so if you add a field here, fix all of them.
enumerate_operators() {
  local stacks stack app comp_path sub name ns st pkg _stacks
  stacks="$(state installed_stacks)"
  [[ -n "$stacks" ]] || return 0
  IFS=',' read -ra _stacks <<< "$stacks"
  for stack in "${_stacks[@]}"; do
    stack="$(echo "$stack" | xargs)"
    [[ -d "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps" ]] || continue
    for app in "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps"/*.yaml; do
      [[ -e "$app" ]] || continue
      comp_path="$(yq '.spec.source.path' "$app" 2>/dev/null || true)"
      [[ -n "$comp_path" && "$comp_path" != "null" ]] || continue
      for sub in "${SCRIPT_DIR}/../${comp_path}"/subscription*.yaml; do
        [[ -e "$sub" ]] || continue
        name="$(yq '.metadata.name' "$sub" 2>/dev/null || true)"
        ns="$(yq '.metadata.namespace' "$sub" 2>/dev/null || true)"
        [[ -n "$name" && "$name" != "null" ]] || continue
        # spec.name IS the OLM package; metadata.name only happens to equal it in this portfolio
        # (verified across every components/*/subscription*.yaml, 2026-07-25). Read the real thing so
        # a future Subscription named differently from its package still resolves its CSV.
        pkg="$(yq '.spec.name' "$sub" 2>/dev/null || true)"
        [[ -n "$pkg" && "$pkg" != "null" ]] || pkg="$name"
        st="$(state "op_${name}" | cut -d: -f1)"
        [[ -n "$st" ]] || st="unknown"
        echo "${name} ${ns} ${st} ${pkg}"
      done
    done
  done
  # gitea-operator: installed via a remote rhpds/gitea-operator OLMDeploy kustomize base
  # (platform-portfolio/components/gitea/kustomization.yaml fetches it from a GitHub URL at build
  # time), so it carries no local subscription*.yaml for the glob above to find — explicit, same
  # treatment job-state-capture.yaml's snapshot gives it on the write side. Gated on core-devtools
  # (the stack that carries the gitea component) so a state record with no core-devtools somehow
  # installed doesn't fabricate an entry. Falls back to "unknown" (preserve-biased, like every other
  # operator here) when a pre-Wave-3 state record has no op_gitea-operator key yet.
  case ",${stacks}," in
    *,core-devtools,*)
      st="$(state op_gitea-operator | cut -d: -f1)"
      [[ -n "$st" ]] || st="unknown"
      # package == subscription name here; confirmed on-cluster, the CSV gitea-operator.v2.1.0 in
      # namespace gitea-operator carries olm.package packageName "gitea-operator".
      echo "gitea-operator gitea-operator ${st} gitea-operator"
      ;;
  esac
  return 0
}

# ── operator CSV identity ─────────────────────────────────────────────────────
# OLM creates a ClusterServiceVersion FROM a Subscription. Argo never manages the CSV, so nothing
# prunes it when the cascade removes the Subscription — and a leftover CSV is not litter, it BREAKS THE
# NEXT INSTALL of this workshop. OLM resolves the new Subscription against the CSV that is already
# there and gives up:
#     constraints not satisfiable: @existing/openshift-operators//devspacesoperator.v3.29.0,
#                                  redhat-operators/openshift-marketplace/stable/devspacesoperator
# Measured on ksls5 2026-07-25: that exact orphan drove pp-devspaces Degraded with `CheCluster/devspaces
# Missing` and took M03 out of the workshop; deleting the CSV by hand let OLM resolve immediately.
#
# Step 3 used to name the CSV by reading `.status.installedCSV` off the Subscription. That was correct
# only while teardown deleted Subscriptions itself. Since teardown became a cascade, step 2 removes the
# Subscription (it IS an Argo-managed resource) long before step 3 runs, so the lookup returned "" for
# EVERY operator, every CSV survived, and the log said `skip subscriptions…/<name> (absent)` — a total
# miss that read as success. The CSV name is therefore obtained without needing the Subscription:
#
#   1. SNAPSHOT — main calls capture_installed_csvs() BEFORE step 1, i.e. at the last moment every
#      Subscription is still alive, and records OLM's own answer. Exact, and it is the same value used
#      when the Subscription is still present (degraded Argo, or the imperative path), so that case
#      cannot regress.
#   2. THE CSV'S OWN IDENTITY — `operatorframework.io/properties` carries the olm.package packageName
#      on the CSV itself, so (namespace, package) finds it with no Subscription and no snapshot. This
#      is what makes a RE-RUN correct: run 1 cascades, removes the Subscriptions and then dies; run 2
#      has no snapshot to take, but every orphaned CSV is still there carrying its own package name.
#
# Deliberately NOT the primary mechanism: OLM's `operators.coreos.com/<package>.<namespace>` label. A
# label KEY is capped at 63 characters and OLM silently TRUNCATES rather than skipping — live on ksls5,
# cluster-observability-operator in openshift-cluster-observability-operator (71 chars) is stamped
# `operators.coreos.com/cluster-observability-operator.openshift-cluster-observability` (exactly 63),
# so a selector built from the real names matches nothing at all. It survives only as a last-resort
# probe (full key, then its 63-char truncation) for a CSV that carries no properties annotation.
CSV_INDEX=""
CSV_INDEX_LOADED="false"
csv_index() {  # → "<ns>|<csv>|<copiedFrom>|<properties-json>" for every ORIGINAL CSV (cached, one call)
  if [[ "$CSV_INDEX_LOADED" != "true" ]]; then
    # `!olm.copiedFrom` drops OLM's per-namespace COPIES server-side. Not a micro-optimisation:
    # measured on ksls5, unfiltered is 3743 objects / 3.8 MB / 92s, filtered is 37 objects / 36 KB / 4s.
    # Copies have to be excluded anyway (deleting one is pointless — OLM garbage-collects them when the
    # original goes, and re-creates any you delete), so filtering at the API server costs nothing.
    # properties LAST in the line: it is JSON, and putting it last means a stray delimiter inside it
    # lands in the final `read` variable instead of shifting every field after it.
    CSV_INDEX="$(oc get clusterserviceversions.operators.coreos.com -A -l '!olm.copiedFrom' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.annotations.olm\.copiedFrom}{"|"}{.metadata.annotations.operatorframework\.io/properties}{"\n"}{end}' 2>/dev/null || true)"
    CSV_INDEX_LOADED="true"
  fi
  printf '%s\n' "$CSV_INDEX"
  return 0
}

csv_package() {  # <properties-json> → its olm.package packageName ("" when the annotation is absent)
  # yq, not grep: the annotation also carries olm.package.required entries whose value has its own
  # packageName, and a text match would happily return a DEPENDENCY's package (devspaces declares
  # devworkspace-operator that way). Selecting on .type is the only correct read.
  local props="$1"
  [[ -n "$props" ]] || return 0
  printf '%s' "$props" \
    | yq -p=json -r '[.properties[] | select(.type == "olm.package") | .value.packageName][0] // ""' 2>/dev/null || true
  return 0
}

csv_by_package() {  # <package> <ns> → the ORIGINAL CSV in that namespace for that package ("" if none)
  local pkg="$1" ns="$2" ins iname icopied iprops
  [[ -n "$pkg" && -n "$ns" ]] || return 0
  while IFS='|' read -r ins iname icopied iprops; do
    [[ "$ins" == "$ns" && -n "$iname" ]] || continue
    # Older OLM recorded the copy as an ANNOTATION, which the label selector above cannot exclude.
    [[ -z "$icopied" ]] || continue
    if [[ "$(csv_package "$iprops")" == "$pkg" ]]; then echo "$iname"; return 0; fi
  done < <(csv_index)
  return 0
}

csv_index_props() {  # <ns> <csv> → "hit|<properties-json>" when the index knows it as an ORIGINAL, else ""
  local ns="$1" csv="$2" ins iname icopied iprops
  while IFS='|' read -r ins iname icopied iprops; do
    if [[ "$ins" == "$ns" && "$iname" == "$csv" && -z "$icopied" ]]; then echo "hit|${iprops}"; return 0; fi
  done < <(csv_index)
  return 0
}

csv_by_olm_label() {  # <package> <ns> → CSV found via OLM's component label (truncation-aware)
  # Truncation is NOT a plain cut to 63. A label key's name part must also END alphanumeric, so OLM
  # trims whatever the cut left dangling. Live on ksls5: cut(63) of
  # cluster-observability-operator.openshift-cluster-observability-operator ends in '-', and the label
  # OLM actually stamped is the 62-char version with that '-' removed. A cut-only candidate misses it,
  # and asking the API server for the untruncated key is not even a miss — it is a 400:
  #   Invalid value: "…": name part must be no more than 63 bytes
  local pkg="$1" ns="$2" key out
  [[ -n "$pkg" && -n "$ns" ]] || return 0
  for key in "${pkg}.${ns}" "$(printf '%s' "${pkg}.${ns}" | cut -c1-63 | sed 's/[^A-Za-z0-9]*$//')"; do
    [[ "${#key}" -le 63 ]] || continue
    out="$(oc get clusterserviceversions.operators.coreos.com -n "$ns" \
            -l "operators.coreos.com/${key},!olm.copiedFrom" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$out" ]]; then echo "$out"; return 0; fi
  done
  return 0
}

CSV_SNAPSHOT=""            # "<subname>|<ns>|<installedCSV>" per line
CSV_SNAPSHOT_TAKEN="false"
capture_installed_csvs() {  # main calls this ONCE, before step 1 — see mechanism 1 above
  # Ordering is the whole point: called any later than step 1 it captures nothing, because the cascade
  # has already taken the Subscriptions. It is read-only, so it runs in --dry-run too — which is what
  # lets the plan name the exact CSVs the run would remove.
  local name ns st pkg csv n=0 total=0
  if [[ "$CSV_SNAPSHOT_TAKEN" == "true" ]]; then return 0; fi
  CSV_SNAPSHOT_TAKEN="true"
  # ONE cluster-wide read, not one per operator: an `oc get` against a remote cluster costs ~3s
  # (measured on ksls5), so 22 operators would be a minute of wall clock for data a single list
  # already contains. The extra rows for Subscriptions that are not ours are inert — every lookup is
  # keyed on the exact (name, namespace) pair the state ConfigMap recorded.
  CSV_SNAPSHOT="$(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.namespace}{"|"}{.status.installedCSV}{"\n"}{end}' 2>/dev/null || true)"
  # Prime the CSV index in the same pre-cascade moment, so both mechanisms describe the same instant
  # and the plan cannot name a CSV that a later read would have missed.
  csv_index >/dev/null
  while read -r name ns st pkg; do
    [[ -n "$name" && -n "$ns" ]] || continue
    total=$((total + 1))
    csv="$(resolve_operator_csv "$name" "$ns" "$pkg" | cut -d'|' -f1)"
    [[ -n "$csv" ]] || continue
    n=$((n + 1))
  done < <(enumerate_operators)
  if [[ "$total" -eq 0 ]]; then return 0; fi
  ok "resolved a CSV for ${n} of ${total} recorded operators, before anything can delete a Subscription"
  if [[ "$n" -lt "$total" ]]; then
    echo "   • the other $((total - n)) have neither a Subscription nor a CSV on this cluster — either the"
    echo "     component was never installed, or an earlier uninstall already removed both"
  fi
  return 0
}

operator_package() {  # <subname> <ns> → its OLM package from the component manifests
  # Falls back to the Subscription name, which is what every subscription*.yaml in this portfolio
  # uses. Exists so callers that only have (name, namespace) — assert_adopted_protection reads the
  # state ConfigMap directly, by design — can still reach the package-based resolution.
  local name="$1" ns="$2" n s p
  while read -r n s _ p; do
    if [[ "$n" == "$name" && "$s" == "$ns" ]]; then echo "$p"; return 0; fi
  done < <(enumerate_operators)
  echo "$name"
  return 0
}

CSV_RESOLVED=""            # memo: "<subname>|<ns>|<csv>|<how>" — an empty <csv> means "probed, nothing"
resolve_operator_csv() {  # <subname> <ns> <package> → "<csv>|<how>" ("" when nothing matches)
  # MEMOISED, and not only to save round-trips. The plan (pre-cascade) and step 3 (post-cascade) both
  # resolve the same operator, and one of the mechanisms — reading a live Subscription — gives a
  # different answer either side of the cascade. Without the memo a plan line could promise a CSV that
  # step 3 then fails to name; with it, the answer is fixed at the first, pre-cascade, resolution.
  local name="$1" ns="$2" pkg="$3" csv out="" hit
  hit="$(printf '%s\n' "$CSV_RESOLVED" | awk -F'|' -v n="$name" -v s="$ns" '$1==n && $2==s {print $3"|"$4; exit}' || true)"
  if [[ -n "$hit" ]]; then
    if [[ "$hit" != "|" ]]; then echo "$hit"; fi
    return 0
  fi
  csv="$(printf '%s\n' "$CSV_SNAPSHOT" | awk -F'|' -v n="$name" -v s="$ns" '$1==n && $2==s {print $3; exit}' || true)"
  if [[ -n "$csv" ]]; then out="${csv}|snapshot"; fi
  if [[ -z "$out" ]]; then
    csv="$(oc get subscriptions.operators.coreos.com "$name" -n "$ns" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    if [[ -n "$csv" ]]; then out="${csv}|live Subscription"; fi
  fi
  if [[ -z "$out" ]]; then
    csv="$(csv_by_package "$pkg" "$ns")"
    if [[ -n "$csv" ]]; then out="${csv}|olm.package annotation"; fi
  fi
  if [[ -z "$out" ]]; then
    csv="$(csv_by_olm_label "$pkg" "$ns")"
    if [[ -n "$csv" ]]; then out="${csv}|OLM component label"; fi
  fi
  CSV_RESOLVED="${CSV_RESOLVED}${name}|${ns}|${out%%|*}|${out#*|}"$'\n'
  if [[ -n "$out" ]]; then echo "$out"; fi
  return 0
}

# ── the adopted-operator guard, made structural ───────────────────────────────
# Deleting an ADOPTED operator's CSV uninstalls the ORG'S operator. It is the single most dangerous
# thing in this file, so it is not guarded by one `if` in the delete path — three independent things
# have to agree, and two of them are derived from the state ConfigMap rather than from whatever the
# caller believes:
#   GATE 1  the state ConfigMap must record this operator as created BY US, in THIS namespace.
#           Re-read at delete time; the caller's classification is never trusted.
#   GATE 2  an independently-built deny-set of every CSV reachable from a NON-created record. If one
#           CSV is ever reachable from both, the delete is refused and reported rather than resolved.
#   GATE 3  the object on the cluster must be an ORIGINAL (not an OLM copy) of the expected package.
# The allowlist is structural on top of that: the only producer of deletion candidates walks the
# `created` branch of enumerate_operators, and the `adopted`/`unknown` branch has no call path to a
# delete at all — it can only strip labels.
PROTECTED_CSVS=""
PROTECTED_CSVS_BUILT="false"
protected_csv_set() {  # → " <ns>/<csv> … " for every operator the state does NOT record as created
  local name ns st pkg csv
  if [[ "$PROTECTED_CSVS_BUILT" != "true" ]]; then
    PROTECTED_CSVS=" "
    while read -r name ns st pkg; do
      [[ -n "$name" && -n "$ns" ]] || continue
      [[ "$st" != "created" ]] || continue
      csv="$(resolve_operator_csv "$name" "$ns" "$pkg" | cut -d'|' -f1)"
      [[ -n "$csv" ]] || continue
      PROTECTED_CSVS="${PROTECTED_CSVS}${ns}/${csv} "
    done < <(enumerate_operators)
    PROTECTED_CSVS_BUILT="true"
  fi
  printf '%s' "$PROTECTED_CSVS"
  return 0
}

# PREDICATE — its non-zero IS the answer. Never give this one a trailing `return 0`.
# The ONLY thing that may authorise a CSV deletion, and it reads the state ConfigMap exclusively.
# Two recorded shapes exist: portfolio operators under op_<subscription>=created|adopted:<ns>, and the
# GitOps operator, which argocd-bootstrap installs imperatively before Argo exists and which is
# therefore recorded under gitops_preexisted instead.
csv_delete_authorized_by_state() {  # <subname> <ns>
  local name="$1" ns="$2"
  if [[ "$name" == "openshift-gitops-operator" && "$ns" == "openshift-gitops-operator" ]]; then
    [[ "$(state gitops_preexisted '')" == "false" ]]
    return
  fi
  [[ "$(state "op_${name}" '')" == "created:${ns}" ]]
}

del_created_csv() {  # <csv> <ns> <subname> <package> <how> — the ONE place that deletes a CSV
  local csv="$1" ns="$2" name="$3" pkg="$4" how="$5" info copied ipkg
  [[ -n "$csv" && -n "$ns" ]] || return 0

  if ! csv_delete_authorized_by_state "$name" "$ns"; then
    err "   REFUSING to delete csv/${csv} -n ${ns}: the install state does not record ${name} as created"
    err "      by us in ${ns} (it reads '$(state "op_${name}" '<no record>')'). An adopted operator's CSV"
    err "      belongs to the org — deleting it would uninstall their operator."
    return 0
  fi
  case "$(protected_csv_set)" in
    *" ${ns}/${csv} "*)
      err "   REFUSING to delete csv/${csv} -n ${ns}: the same CSV is also reachable from an operator this"
      err "      cluster owns. Two records resolved to one CSV — nothing was deleted; please report this."
      return 0;;
  esac
  # Identity comes from the cached index when it knows this CSV as an original — no extra round-trip,
  # and a package name cannot change under us. An index MISS is the interesting case (a copy, or an
  # object that is simply gone), so that one is worth a live read.
  info="$(csv_index_props "$ns" "$csv")"
  if [[ -n "$info" ]]; then
    info="|${info#hit|}"
  else
    info="$(oc get clusterserviceversions.operators.coreos.com "$csv" -n "$ns" \
             -o jsonpath='{.metadata.labels.olm\.copiedFrom}{.metadata.annotations.olm\.copiedFrom}{"|"}{.metadata.annotations.operatorframework\.io/properties}' 2>/dev/null || true)"
  fi
  copied="${info%%|*}"
  if [[ -n "$copied" ]]; then
    echo "   • skip csv/${csv} -n ${ns} — this is OLM's copy of the original in ${copied}; OLM removes"
    echo "     copies itself once the original goes, so deleting the copy achieves nothing"
    return 0
  fi
  ipkg="$(csv_package "${info#*|}")"
  if [[ -n "$ipkg" && -n "$pkg" && "$ipkg" != "$pkg" ]]; then
    err "   REFUSING to delete csv/${csv} -n ${ns}: it belongs to package '${ipkg}', not '${pkg}'"
    return 0
  fi
  if [[ -n "$how" ]]; then echo "   • csv/${csv} -n ${ns} identified via ${how}"; fi
  del_obj clusterserviceversions.operators.coreos.com "$csv" "$ns"
  return 0
}

# Every namespace the INSTALLED stacks declare in their component manifests — the "installed stacks'
# namespaces" half of F2's delete allowlist. Mirrors enumerate_operators but reads namespace*.yaml
# instead of subscription*.yaml, so it also catches non-operator infra namespaces (e.g. ogsr-gitea)
# that carry no per-user/shared marker label. A stack no longer in installed_stacks contributes
# nothing here, so its leftover owner-labeled namespace (e.g. openshift-mta) is NOT in the allowlist.
# Emits "<stack>|<namespace>" so the same walk answers both questions asked of it: F2's delete
# allowlist (namespace only) and "which stack owns this namespace?" (the cascade's phase-3 lookup).
enumerate_installed_stack_ns_pairs() {
  local stacks stack app comp_path nsfile _stacks n
  stacks="$(state installed_stacks)"
  [[ -n "$stacks" ]] || return 0
  IFS=',' read -ra _stacks <<< "$stacks"
  for stack in "${_stacks[@]}"; do
    stack="$(echo "$stack" | xargs)"
    [[ -d "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps" ]] || continue
    for app in "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps"/*.yaml; do
      [[ -e "$app" ]] || continue
      comp_path="$(yq '.spec.source.path' "$app" 2>/dev/null || true)"
      [[ -n "$comp_path" && "$comp_path" != "null" ]] || continue
      for nsfile in "${SCRIPT_DIR}/../${comp_path}"/namespace*.yaml "${SCRIPT_DIR}/../${comp_path}"/namespaces*.yaml; do
        [[ -e "$nsfile" ]] || continue
        # `[[ … ]] && echo` here would make the LAST namespace line decide the function's exit status
        # (yq emits a blank line for a non-Namespace document), and this function's output is consumed
        # in a command substitution — a 1 there is a `set -e` kill. Guard with `continue`, never `&&`.
        while IFS= read -r n; do
          [[ -n "$n" && "$n" != "null" ]] || continue
          echo "${stack}|${n}"
        done < <(yq 'select(.kind == "Namespace") | .metadata.name' "$nsfile" 2>/dev/null || true)
      done
    done
  done
  return 0
}

enumerate_installed_stack_ns() {  # namespace-only view of the pairs above
  enumerate_installed_stack_ns_pairs | cut -d'|' -f2
  return 0
}

# Every Argo Application that is OURS, matched on ANY label we stamp. All five are exclusively ours
# (workshop.redhat.com/* and portfolio.redhat.com/* are workshop-invented domains), and all five are
# needed: the CHILD component apps carry ONLY portfolio.redhat.com/component — 31 of the 32 have no
# owner label — so the previous owner-or-stack pair never saw them. That mattered twice over. Step 1
# left every child app on `automated: {prune, selfHeal}` while step 2 orphaned its parent, so the
# children kept reconciling the stack back into existence mid-teardown (a stale pp-mta on C2 re-created
# pp-mta-hub and re-added openshift-mta's owner label immediately after F7 stripped it); and the
# cascade wait below cannot know Argo has finished if it cannot see the apps still pruning.
APP_LABELS=("$OWNER_LABEL" "portfolio.redhat.com/stack" "portfolio.redhat.com/component"
            "workshop.redhat.com/layer" "workshop.redhat.com/module")
our_applications() {
  local l
  { for l in "${APP_LABELS[@]}"; do
      oc get applications.argoproj.io -n "$ARGO_NS" -l "$l" -o name 2>/dev/null
    done
  } | sed 's|.*/||' | sort -u || true
  return 0
}

# The WORKSHOP LAYER — everything the workshop bootstrap put on top of the portfolio (the
# workshop-config Application and tools/ws's per-module entry-* apps). Architecturally it is the
# consumer side of every operator the portfolio installs, which is why it is cascade phase 1.
WORKSHOP_LAYER_LABELS=("workshop.redhat.com/layer" "workshop.redhat.com/module")
workshop_layer_applications() {
  local l
  { for l in "${WORKSHOP_LAYER_LABELS[@]}"; do
      oc get applications.argoproj.io -n "$ARGO_NS" -l "$l" -o name 2>/dev/null
    done
  } | sed 's|.*/||' | sort -u || true
  return 0
}

# The app-of-apps ROOTS: our apps minus the child component apps. Deleting only the roots is what makes
# the cascade ORDERED — Argo prunes a root's managed resources (its child Applications) in reverse
# sync-wave order, and each child, carrying the finalizer we add below, then prunes its own resources
# the same way. Deleting every app at once instead would issue all the deletes in parallel and throw
# away exactly the ordering this change exists to obtain (operand CR before its operator, so the
# operator is alive to run the CR's finalizer — TempoMonolithic/traces wedged ogsr-observability-workshop
# indefinitely on 2026-07-25 because tempo.grafana.com/finalizer outlived the Tempo operator).
root_applications() {
  local comps app
  comps=" $(oc get applications.argoproj.io -n "$ARGO_NS" -l "portfolio.redhat.com/component" \
              -o name 2>/dev/null | sed 's|.*/||' | tr '\n' ' ' || true) "
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    case "$comps" in *" $app "*) continue;; esac
    echo "$app"
  done < <(our_applications)
  return 0
}

# ── cascade ordering: consumers before providers ──────────────────────────────
# Argo orders prunes WITHIN one Application (reverse sync-wave). It has no ordering BETWEEN
# app-of-apps roots, so deleting all 13 at once issues 13 independent cascades in parallel. Two
# dependencies cross that boundary; the ordered phases below are the only place they can be expressed.
#
#   PHASE 1 — the workshop layer depends on the platform's OPERATORS.
#     gitops/workshop-config renders Kueue operands: 8 ClusterQueue + 1 ResourceFlavor. The Kueue
#     OPERATOR ships in the batch stack (pp-batch → pp-kueue). On 2026-07-25 both roots were deleted
#     at 13:52:41; pp-batch removed the Kueue controller first, so when workshop-config deleted its
#     ClusterQueues at 13:55:27 nothing was left to run kueue.x-k8s.io/resource-in-use. The app never
#     finished pruning — 900s cascade wait plus a 300s straggler sweep, then steps 4-8 were skipped.
#     This is the SAME operand-before-operator rule check-teardown-invariants.sh enforces inside a
#     stack; it simply has no expression across roots, so ordering it here is bash's job.
#
#   PHASE 3 — every Gitea-sourced Application depends on the in-cluster MIRROR.
#     Since the phase-2 install flip, apps source from ogsr-gitea, which is itself torn down by the
#     stack that hosts it. Measured on the same run: the mirror began returning 503 at 13:57:02 and
#     20 Applications — pp-gitea and pp-core-devtools among them — finished pruning normally between
#     14:00:56 and 14:04:57. So Argo's CASCADED DELETE does not need the source repo (it enumerates
#     managed objects from the cluster cache); only the refresh/comparison loop does, which is why a
#     dying mirror shows up as a cosmetic ComparisonError. Deleting the mirror's stack last is
#     therefore insurance, not a fix for an observed failure — it costs one extra bounded wait and
#     removes the class, and it keeps teardown independent of any repo, in-cluster or external.
#
# Deliberately NOT chosen: flipping sources back to the external repo_url before cascading. That
# would make an offline teardown depend on GitHub being reachable — a new failure mode, to fix a
# dependency the measurements above show does not exist.

# The hosts our Applications currently source FROM (post-flip: the in-cluster mirror's Route host).
our_app_repo_hosts() {
  local l
  { for l in "${APP_LABELS[@]}"; do
      oc get applications.argoproj.io -n "$ARGO_NS" -l "$l" \
        -o jsonpath='{range .items[*]}{.spec.source.repoURL}{"\n"}{end}' 2>/dev/null
    done
  } | sed -e 's|^[a-z+]*://||' -e 's|^[^/@]*@||' -e 's|[/:].*$||' | grep . | sort -u || true
  return 0
}

mirror_host_namespaces() {  # namespaces whose Route serves a repo our Applications source from
  local hosts rhost ns
  hosts="$(our_app_repo_hosts)"
  [[ -n "$hosts" ]] || return 0
  while IFS='|' read -r rhost ns; do
    [[ -n "$rhost" && -n "$ns" ]] || continue
    if printf '%s\n' "$hosts" | grep -qxF -- "$rhost"; then echo "$ns"; fi
  done < <(oc get routes --all-namespaces \
             -o jsonpath='{range .items[*]}{.spec.host}{"|"}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true) \
    | sort -u
  return 0
}

mirror_stack() {  # → the installed stack that HOSTS the in-cluster git mirror ("" when there is none)
  local ns stack pstack pns
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    while IFS='|' read -r pstack pns; do
      if [[ "$pns" == "$ns" ]]; then stack="$pstack"; fi
    done < <(enumerate_installed_stack_ns_pairs)
    if [[ -n "${stack:-}" ]]; then echo "$stack"; return 0; fi
  done < <(mirror_host_namespaces)
  return 0
}

stack_child_app_names() {  # <stack> → the child Application names its app-of-apps declares
  local stack="$1" app name
  [[ -n "$stack" ]] || return 0
  [[ -d "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps" ]] || return 0
  for app in "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps"/*.yaml; do
    [[ -e "$app" ]] || continue
    name="$(yq '.metadata.name' "$app" 2>/dev/null || true)"
    [[ -n "$name" && "$name" != "null" ]] || continue
    echo "$name"
  done
  return 0
}

# Phase membership is a space-padded one-line set (" a b c "), the same idiom the namespace
# classifier already uses — no associative arrays, so this stays correct on the bash 3.2 that
# /usr/bin/env bash resolves to on a stock macOS.
to_set() {  # <newline-list> → " a b c "
  local s
  s="$(printf '%s\n' "$1" | grep . | tr '\n' ' ' || true)"
  echo " ${s}"
  return 0
}

apps_remaining_in() {  # <set> → how many of our LIVE Applications belong to that phase
  local set="$1" app n=0
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    case "$set" in *" $app "*) n=$((n + 1));; esac
  done < <(our_applications)
  echo "$n"
  return 0
}

# The phases share ONE budget so --cascade-timeout still means "roughly this long in total", with a
# floor per phase so a slow phase 1 cannot starve phase 3 of any chance at all.
CASCADE_DEADLINE=0
PHASE_FLOOR=60
phase_budget() {  # → seconds the next phase may wait
  local now left
  now="$(date +%s)"
  left=$((CASCADE_DEADLINE - now))
  if [[ "$left" -lt "$PHASE_FLOOR" ]]; then left="$PHASE_FLOOR"; fi
  echo "$left"
  return 0
}

# ── adopted-resource protection guard ─────────────────────────────────────────
# The cascade is safe for exactly one reason: install.sh annotated every ADOPTED resource
# `argocd.argoproj.io/sync-options: …,Prune=false,Delete=false`, so Argo's prune skips it. That is an
# assumption about a DIFFERENT script that ran at a DIFFERENT time — an install predating that change
# looks identical to a correct one from here — so it is verified against the live cluster, never
# trusted. Findings block the run; --cascade-unprotected overrides at the operator's risk.
#
# The test is deliberately "would the cascade prune this?", not "is this annotated?": a resource Argo
# does not manage cannot be pruned, so it needs no protection and must not raise a false alarm that
# trains people to reach for the override. Argo's tracking stamp answers that exactly.
PROT_OK=0            # adopted resources verified safe (protected, untracked, or already gone)
PROT_BAD=0           # adopted resources the cascade WOULD delete
PROT_BAD_LIST=""     # rendered findings, each with the exact annotate command that fixes it
PROT_NOTE_LIST=""    # rendered "safe, and here is why" lines for the dry-run plan
PROT_NO_STATE="false"

argo_manages() {  # kind name [ns] → 0 if Argo currently tracks this object (⇒ a cascade would prune it)
  local kind="$1" name="$2" ns="${3:-}" out
  # shellcheck disable=SC2016  # the backslash escapes are jsonpath field escaping, not shell
  local jp='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{" "}{.metadata.labels.app\.kubernetes\.io/instance}'
  if [[ -n "$ns" ]]; then
    out="$(oc get "$kind" "$name" -n "$ns" -o jsonpath="$jp" 2>/dev/null || true)"
  else
    out="$(oc get "$kind" "$name" -o jsonpath="$jp" 2>/dev/null || true)"
  fi
  [[ -n "${out// /}" ]]
}

is_protected() {  # kind name [ns] → 0 if sync-options carries BOTH Prune=false and Delete=false
  local kind="$1" name="$2" ns="${3:-}" v
  # shellcheck disable=SC2016
  local jp='{.metadata.annotations.argocd\.argoproj\.io/sync-options}'
  if [[ -n "$ns" ]]; then
    v="$(oc get "$kind" "$name" -n "$ns" -o jsonpath="$jp" 2>/dev/null || true)"
  else
    v="$(oc get "$kind" "$name" -o jsonpath="$jp" 2>/dev/null || true)"
  fi
  [[ "$v" == *"Prune=false"* && "$v" == *"Delete=false"* ]]
}

# PREDICATE — its non-zero IS the answer. Never give this one a trailing `return 0`.
obj_exists() { local k="$1" n="$2" ns="${3:-}"
  if [[ -n "$ns" ]]; then oc get "$k" "$n" -n "$ns" >/dev/null 2>&1; else oc get "$k" "$n" >/dev/null 2>&1; fi
}

check_adopted() {  # kind name ns why — classify ONE adopted resource against the cascade
  local kind="$1" name="$2" ns="${3:-}" why="$4" loc nsarg=""
  loc="${kind%%.*}/${name}"
  if [[ -n "$ns" ]]; then loc="${loc} -n ${ns}"; nsarg=" -n ${ns}"; fi
  if ! obj_exists "$kind" "$name" "$ns"; then
    PROT_OK=$((PROT_OK + 1))
    PROT_NOTE_LIST="${PROT_NOTE_LIST}"$'\n'"      ✓ ${loc} — recorded ${why}, but no longer on the cluster"
    return 0
  fi
  if ! argo_manages "$kind" "$name" "$ns"; then
    PROT_OK=$((PROT_OK + 1))
    PROT_NOTE_LIST="${PROT_NOTE_LIST}"$'\n'"      ✓ ${loc} — ${why}; Argo does not manage it, so the cascade cannot prune it"
    return 0
  fi
  if is_protected "$kind" "$name" "$ns"; then
    PROT_OK=$((PROT_OK + 1))
    PROT_NOTE_LIST="${PROT_NOTE_LIST}"$'\n'"      ✓ ${loc} — ${why}; Prune=false,Delete=false → SURVIVES the cascade"
    return 0
  fi
  PROT_BAD=$((PROT_BAD + 1))
  PROT_BAD_LIST="${PROT_BAD_LIST}"$'\n'"   ✗ ${loc}"$'\n'"       ${why}, Argo manages it, and it is NOT protected → the cascade WOULD DELETE IT"$'\n'"       fix: oc annotate ${kind} ${name}${nsarg} '${SYNC_OPTS_ANN}=Prune=false,Delete=false' --overwrite"
  return 0
}

assert_adopted_protection() {
  local name ns csv og adopted napps
  state installed_stacks >/dev/null 2>&1 || true   # forces the one-time STATE_SNAPSHOT read

  # Nothing to cascade ⇒ nothing to protect against. This is the ordinary shape of a RE-RUN: run 1
  # deleted both the Applications and the state ConfigMap, and run 2 exists to finish the imperative
  # reversals (OAuth IdP, node taint, htpasswd) and to sweep stragglers. Refusing here would block the
  # very cleanup the operator came back to finish, over a risk that cannot materialise.
  napps="$(our_applications | grep -c . || true)"; napps="${napps:-0}"
  if [[ "$napps" == "0" ]]; then
    PROT_NOTE_LIST="${PROT_NOTE_LIST}"$'\n'"      ✓ no workshop Argo Applications on this cluster — there is no cascade to guard"
    return 0
  fi

  if [[ -z "$STATE_SNAPSHOT" ]]; then
    # No state at all: we cannot tell an adopted operator from one we created, so we cannot tell what
    # the cascade would take. This is also EXACTLY what a pre-2026-07-25 install looks like.
    PROT_NO_STATE="true"; PROT_BAD=$((PROT_BAD + 1))
    PROT_BAD_LIST="${PROT_BAD_LIST}"$'\n'"   ✗ no ${STATE_NS}/${STATE_CM} ConfigMap — adopted-vs-created is unknown for EVERY operator on this cluster"
    return 0
  fi
  adopted="$(printf '%s\n' "$STATE_SNAPSHOT" | grep '^op_' | grep '=adopted:' \
              | sed 's/^op_\([^=]*\)=adopted:\(.*\)$/\1 \2/' || true)"
  while read -r name ns; do
    [[ -n "$name" && -n "$ns" ]] || continue
    # ALWAYS fully qualified — Knative's subscriptions.messaging.knative.dev shadows OLM's, and the bare
    # name reported every operator as absent (SEV1, fixed in 437bbf4). Do not regress it here.
    check_adopted subscriptions.operators.coreos.com "$name" "$ns" "adopted operator (the org installed it)"
    # Resolve the CSV the way step 3 does, NOT from the Subscription — this guard had the SAME defect.
    # Live on ksls5 2026-07-25: the org's adopted openshift-pipelines-operator-rh and web-terminal have
    # Succeeded CSVs and NO Subscription at all, so the old installedCSV read returned "" and the guard
    # printed no line for them — it silently verified nothing about the two objects it exists to
    # protect, and a genuinely unprotected adopted CSV would have sailed through as "clean".
    csv="$(resolve_operator_csv "$name" "$ns" "$(operator_package "$name" "$ns")" | cut -d'|' -f1)"
    if [[ -n "$csv" ]]; then
      check_adopted clusterserviceversions.operators.coreos.com "$csv" "$ns" "CSV of an adopted operator"
    fi
    while IFS= read -r og; do
      [[ -n "$og" ]] || continue
      check_adopted operatorgroups.operators.coreos.com "$og" "$ns" "OperatorGroup of an adopted operator"
    done < <(oc get operatorgroups.operators.coreos.com -n "$ns" \
              -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    # The NAMESPACE matters as much as the Subscription and is the one install.sh does not annotate:
    # our component manifests declare operator namespaces (platform-portfolio/components/*/namespace.yaml),
    # so Argo adopts a pre-existing one on first sync. Deleting a namespace destroys everything inside it
    # regardless of what those objects are annotated — the Prune=false on the Subscription does not save
    # an operator whose namespace goes. classify_workshop_namespaces() already preserves these, but the
    # cascade now runs BEFORE it, so bash never gets the chance.
    check_adopted namespace "$ns" "" "namespace of an adopted operator"
  done <<< "$adopted"

  # Two more resources the state records as pre-existing, both declared in portfolio components and so
  # both inside Argo's managed set. install.sh's protection pass covers operators only, so these are
  # verified here rather than assumed: a pruned cluster-monitoring-config takes the org's whole
  # monitoring configuration with it (not just the enableUserWorkload key restore_monitoring() handles),
  # and a pruned GatewayClass tears down their Gateway API data plane.
  if [[ "$(state gatewayclass_preexisted '')" == "true" ]]; then
    check_adopted gatewayclasses.gateway.networking.k8s.io openshift-default "" "GatewayClass the cluster already had"
  fi
  if [[ "$(state monitoring_cm_existed '')" == "true" ]]; then
    check_adopted configmap cluster-monitoring-config openshift-monitoring "the org's own cluster-monitoring-config"
  fi
  return 0
}

enforce_adopted_protection() {  # print the verdict; refuse the cascade unless it is clean or overridden
  if [[ "$PROT_BAD" -eq 0 ]]; then
    if [[ "$PROT_OK" -eq 0 ]]; then
      ok "adopted-resource protection verified — nothing on this cluster is at risk from the cascade"
    else
      ok "adopted-resource protection verified — ${PROT_OK} adopted resource(s) will survive the cascade"
    fi
    return 0
  fi
  echo
  err "REFUSING TO CASCADE — ${PROT_BAD} resource(s) the org owns would be DELETED by this uninstall."
  echo "$PROT_BAD_LIST" >&2
  echo >&2
  err "What this means, plainly:"
  err "  Deleting our Argo Applications is now the uninstall — Argo removes everything it manages. That"
  err "  is only safe while each ADOPTED resource carries Prune=false,Delete=false, which bootstrap/install.sh"
  err "  applies at install time. The resources above do not carry it, so Argo would treat the org's own"
  err "  operators/namespaces as ours and prune them. Nothing here can put them back."
  if [[ "$PROT_NO_STATE" == "true" ]]; then
    err "  This cluster has no install-state ConfigMap at all, which is what an install from before"
    err "  2026-07-25 looks like — and also what a second uninstall run looks like (run 1 deletes it)."
  fi
  echo >&2
  err "How to proceed, best first:"
  err "  1. Re-run ./bootstrap/install.sh against this cluster. Its protection pass is idempotent and"
  err "     merges into any sync-options already set; then re-run this uninstall."
  err "  2. Or apply the 'fix:' command printed with each finding above, then re-run this uninstall."
  err "  3. Or, if you have confirmed by hand that nothing on this cluster is adopted, re-run with"
  err "     --cascade-unprotected (see --help for exactly what that risks)."
  echo >&2
  err "Either way, ./bootstrap/ogsr-check-clean.sh gives you a read-only picture of what is on the"
  err "cluster right now — including which operators the org owns and whether they are healthy."
  if [[ "$FORCE_UNPROTECTED" == "true" ]]; then
    echo >&2
    err "--cascade-unprotected given — PROCEEDING ANYWAY. The ${PROT_BAD} resource(s) above are expected to be deleted."
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then echo >&2; err "(dry-run: a real run stops here. Nothing was changed.)"; fi
  exit 1
}

# ── cascade delete ────────────────────────────────────────────────────────────
ensure_resources_finalizer() {  # app — make `oc delete` CASCADE instead of silently orphaning
  local app="$1" fins
  fins="$(oc get applications.argoproj.io "$app" -n "$ARGO_NS" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
  case "$fins" in *"$ARGO_FINALIZER"*) return 0;; esac
  if [[ -z "$fins" || "$fins" == "[]" ]]; then
    oc patch applications.argoproj.io "$app" -n "$ARGO_NS" --type merge \
      -p "{\"metadata\":{\"finalizers\":[\"${ARGO_FINALIZER}\"]}}" >/dev/null 2>&1 || true
  else
    # Append, never replace: a merge patch on the whole array would drop finalizers someone else owns.
    oc patch applications.argoproj.io "$app" -n "$ARGO_NS" --type json \
      -p "[{\"op\":\"add\",\"path\":\"/metadata/finalizers/-\",\"value\":\"${ARGO_FINALIZER}\"}]" >/dev/null 2>&1 || true
  fi
  return 0
}

# PREDICATE — returns 1 on timeout by design; every caller tests it. Do not add `return 0`.
wait_for_phase() {  # <label> <member-set> <budget> — bounded, progress-printing wait for one phase
  local label="$1" members="$2" budget="$3" waited=0 n prev=""
  while (( waited < budget )); do
    n="$(apps_remaining_in "$members")"
    if [[ "$n" == "0" ]]; then
      ok "${label}: Argo finished pruning after ${waited}s"
      return 0
    fi
    # Print only on change, so an unattended run shows progress without a wall of identical lines.
    if [[ "$n" != "$prev" ]]; then
      echo "   … ${label}: ${n} Application(s) still pruning (${waited}s of ${budget}s)"
      prev="$n"
    fi
    sleep 10; waited=$((waited + 10))
  done
  return 1
}

cascade_phase() {  # <label> <roots> <member-set> — delete this phase's roots, then BLOCK on them
  local label="$1" roots="$2" members="$3" app budget n
  n="$(apps_remaining_in "$members")"
  if [[ "$n" == "0" ]]; then
    echo "   • ${label}: no Applications in this phase — skipping"
    return 0
  fi
  # Members but no ROOT to delete = orphaned children whose parent is already gone (a stale pp-* from
  # an older stack set). Waiting would burn this phase's budget on deletes nobody issued; the straggler
  # sweep deletes them directly afterwards, which is exactly what it exists for.
  if [[ -z "${roots//[[:space:]]/}" ]]; then
    echo "   • ${label}: ${n} Application(s) present but no app-of-apps root to delete — left to the straggler sweep"
    return 0
  fi
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "   • WOULD cascade-delete application/${app}  [${label}]"
      continue
    fi
    oc delete applications.argoproj.io "$app" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    ok "cascade-delete requested for application/${app}  [${label}]"
  done < <(printf '%s\n' "$roots")
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   • WOULD then WAIT for ${label} to finish pruning before starting the next phase"
    return 0
  fi
  budget="$(phase_budget)"
  info "waiting for ${label} to finish pruning (${n} Application(s), up to ${budget}s)"
  if wait_for_phase "$label" "$members" "$budget"; then return 0; fi
  err "${label} did not finish pruning within ${budget}s — moving to the next phase anyway"
  err "   ordering is best-effort for whatever is left; the straggler sweep and the report below cover it"
  return 0
}

app_source_host() {  # <app> → the host its source repoURL points at ("" when unreadable)
  oc get applications.argoproj.io "$1" -n "$ARGO_NS" -o jsonpath='{.spec.source.repoURL}' 2>/dev/null \
    | sed -e 's|^[a-z+]*://||' -e 's|^[^/@]*@||' -e 's|[/:].*$||' || true
  return 0
}

# PREDICATE — returns 1 when nothing serves the host any more. Callers test it; no `return 0`.
host_served_by_route() {  # <host>
  local host="$1" n
  [[ -n "$host" ]] || return 1
  n="$(oc get routes --all-namespaces -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null \
        | grep -cxF -- "$host" || true)"
  [[ "${n:-0}" != "0" ]]
}

diagnose_stuck_app() {  # <app> — name the blocker and the exact command, never an rpc error to decode
  local app="$1" group kind ns name res fins shown=0 blockers=0 host
  err "   ✗ application/${app}"
  # .status.resources is Argo's OWN list of what it still manages, and it shrinks as objects go — so
  # whatever remains in it is exactly what the cascade is waiting for. That is how the 2026-07-25 run
  # read: 8 ClusterQueue + 1 ResourceFlavor, all Terminating on kueue.x-k8s.io/resource-in-use with
  # the Kueue operator already removed by a DIFFERENT root. Read it before blaming anything else.
  while IFS='|' read -r group kind ns name; do
    [[ -n "$kind" && -n "$name" ]] || continue
    res="$kind"
    if [[ -n "$group" ]]; then res="${kind}.${group}"; fi
    if [[ -n "$ns" ]]; then
      fins="$(oc get "$res" "$name" -n "$ns" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
    else
      fins="$(oc get "$res" "$name" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
    fi
    [[ -n "$fins" && "$fins" != "[]" ]] || continue
    blockers=$((blockers + 1))
    if [[ "$shown" -ge 20 ]]; then continue; fi
    shown=$((shown + 1))
    echo "      ↳ ${res}/${name}${ns:+ -n $ns} still holds ${fins}" >&2
    if [[ -n "$ns" ]]; then
      echo "         clear: oc patch ${res} ${name} -n ${ns} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'" >&2
    else
      echo "         clear: oc patch ${res} ${name} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'" >&2
    fi
  done < <(oc get applications.argoproj.io "$app" -n "$ARGO_NS" \
             -o jsonpath='{range .status.resources[*]}{.group}{"|"}{.kind}{"|"}{.namespace}{"|"}{.name}{"\n"}{end}' 2>/dev/null || true)

  if [[ "$blockers" -gt 0 ]]; then
    if [[ "$blockers" -gt "$shown" ]]; then err "      ↳ … and $((blockers - shown)) more"; fi
    err "      CAUSE: those objects are Terminating on a finalizer whose controller is already gone,"
    err "      so Argo cannot finish. Clearing them (commands above) releases the Application too —"
    err "      you do NOT need to touch the Application's own finalizer. Clear only if you accept that"
    err "      the operator's cleanup for those objects will not run."
    return 0
  fi

  # No managed objects left, so the Application's own finalizer is all that remains. The one cause
  # with no self-healing path is a source repo that no longer exists: the in-cluster Gitea mirror is
  # torn down by this very uninstall, and if it went before this app did, Argo's refresh loop reports
  # only `failed to list refs … rpc error`, which says nothing about what to do.
  host="$(app_source_host "$app")"
  if [[ -n "$host" ]] && ! host_served_by_route "$host"; then
    err "      CAUSE: its source repo is GONE — ${host} is no longer served by any Route on this"
    err "      cluster. That is the in-cluster Gitea mirror, torn down earlier in this same uninstall."
    err "      It surfaces as: ComparisonError … failed to list refs: unexpected client error."
    err "      Nothing will bring it back, so the ONLY recourse is to clear the finalizer by hand:"
    echo "         oc patch application ${app} -n ${ARGO_NS} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'" >&2
    err "      Anything the app still manages is then ORPHANED — run ogsr-check-clean.sh afterwards."
    return 0
  fi
  err "      no managed objects and no missing source repo — inspect it directly:"
  err "         oc describe application ${app} -n ${ARGO_NS}"
  return 0
}

cascade_delete_applications() {
  local app n total=0 sweep_budget all_set p1_set p3_set p2_set
  local mstack p1_roots="" p2_roots="" p3_roots="" p3_apps=""
  # The straggler sweep gets a third of the main budget (floor 30s): someone who sets a short
  # --cascade-timeout means "do not sit here", and a fixed second wait would ignore that.
  sweep_budget=$(( CASCADE_TIMEOUT / 3 ))
  if [[ "$sweep_budget" -lt 30 ]]; then sweep_budget=30; fi
  total="$(our_applications | grep -c . || true)"; total="${total:-0}"
  if [[ "$total" == "0" ]]; then ok "no workshop Argo Applications present — nothing to cascade"; return 0; fi
  CASCADE_DEADLINE=$(( $(date +%s) + CASCADE_TIMEOUT ))

  # (a) Arm EVERY app, children included. A child pruned by its parent still needs its own finalizer,
  #     or the parent's cascade deletes the child Application object and orphans the child's resources.
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD ensure ${ARGO_FINALIZER} on application/${app}"; continue; fi
    ensure_resources_finalizer "$app"
  done < <(our_applications)
  if [[ "$DRY_RUN" != "true" ]]; then
    ok "armed ${total} Application(s) with ${ARGO_FINALIZER} (cascade, not orphan)"
  fi

  # (b) Partition the ROOTS into the three ordered phases (see § cascade ordering above). Membership
  #     is computed once, from the live cluster plus the stack manifests — an app that cannot be
  #     attributed lands in phase 2, which is exactly where every root used to be, so the worst case
  #     is today's behaviour and never worse.
  all_set="$(to_set "$(our_applications)")"
  p1_set="$(to_set "$(workshop_layer_applications)")"
  mstack="$(mirror_stack)"
  if [[ -n "$mstack" ]]; then
    p3_apps="$(printf 'pp-%s\n' "$mstack"; stack_child_app_names "$mstack")"
    p3_set="$(to_set "$p3_apps")"
    info "in-cluster git mirror is hosted by stack '${mstack}' — its Applications are pruned LAST"
  else
    p3_set=" "
    info "no in-cluster git mirror found among our Application sources — two phases instead of three"
  fi
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    case "$p1_set" in *" $app "*) p1_roots="${p1_roots}${app}"$'\n'; continue;; esac
    case "$p3_set" in *" $app "*) p3_roots="${p3_roots}${app}"$'\n'; continue;; esac
    p2_roots="${p2_roots}${app}"$'\n'
  done < <(root_applications)
  # Phase 2 = everything that is neither the workshop layer nor the mirror's stack. Built by
  # subtraction so a child Application nobody classified still gets waited on by SOME phase.
  p2_set=" "
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    case "$p1_set" in *" $app "*) continue;; esac
    case "$p3_set" in *" $app "*) continue;; esac
    p2_set="${p2_set}${app} "
  done < <(printf '%s' "${all_set# }" | tr ' ' '\n')

  # (c) Run the phases in order, each BLOCKING. Within a phase, Argo still prunes each root's children
  #     in reverse sync-wave order, so the operand-before-operator ordering the sync waves buy is
  #     preserved — the phases only add ordering BETWEEN roots, where Argo has none.
  cascade_phase "phase 1/3 · workshop layer"                    "$p1_roots" "$p1_set"
  cascade_phase "phase 2/3 · platform stacks"                   "$p2_roots" "$p2_set"
  cascade_phase "phase 3/3 · git mirror stack (${mstack:-none})" "$p3_roots" "$p3_set"
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

  n="$(our_applications | grep -c . || true)"; n="${n:-0}"
  if [[ "$n" == "0" ]]; then ok "cascade complete — 0 workshop Applications remain"; return 0; fi

  # (d) Stragglers: a child whose parent was already gone (a legacy stale pp-* app) is never reached by
  #     a root delete. Delete those directly — they are armed, so they still cascade, just unordered.
  err "${n} Application(s) still present after the ordered phases — deleting them directly"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    oc delete applications.argoproj.io "$app" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "   • direct cascade-delete requested for application/${app}"
  done < <(our_applications)
  # Recompute the set: the sweep must wait on what is on the cluster NOW, not on the partition taken
  # before the phases ran, or an app that appeared since would be declared gone without being checked.
  all_set="$(to_set "$(our_applications)")"
  if wait_for_phase "straggler sweep" "$all_set" "$sweep_budget"; then return 0; fi

  # (e) Still stuck. Do NOT force the finalizer off — that would silently orphan everything the app
  #     still manages, which is the failure mode this whole change removes. Diagnose each one by name
  #     and continue: the imperative mutations below (OAuth IdP, node taint, htpasswd) must still be
  #     reversed, and ogsr-check-clean.sh will show precisely what Argo left behind.
  err "Argo did not finish pruning. Continuing with the rest of the uninstall, but expect leftovers:"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    diagnose_stuck_app "$app"
  done < <(our_applications)
  err "   then run: ./bootstrap/ogsr-check-clean.sh"
  return 0
}

# ── delete helpers (all dry-run aware, all tolerant of already-absent objects) ─
del_obj() {  # kind name [ns] — delete one object if it exists; print a skip reason if absent
  local kind="$1" name="$2" ns="${3:-}" loc
  loc="${kind}/${name}"
  if [[ -n "$ns" ]]; then loc="${loc} -n ${ns}"; fi
  if [[ -n "$ns" ]]; then
    oc get "$kind" "$name" -n "$ns" >/dev/null 2>&1 || { echo "   • skip ${loc} (absent)"; return 0; }
  else
    oc get "$kind" "$name" >/dev/null 2>&1 || { echo "   • skip ${loc} (absent)"; return 0; }
  fi
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD delete ${loc}"; return 0; fi
  if [[ -n "$ns" ]]; then
    oc delete "$kind" "$name" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  else
    oc delete "$kind" "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  ok "deleted ${loc}"
  return 0
}

del_labeled_cluster() {  # kind — delete owner-labeled objects of a CLUSTER-SCOPED kind (skips if CRD absent)
  local kind="$1" name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    del_obj "$kind" "$name"
  done < <(oc get "$kind" -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' || true)
  return 0
}

# REMOVED with the move to cascade delete: del_labeled_namespaced(). Its only caller was the old step 7
# (AppProjects, and the java-21 ImageStream alongside it), and every namespaced object it swept is
# rendered by the workshop-config Application — so cascade-deleting that app prunes them, in order,
# instead of bash finding them by label after the fact.

# ── namespace lifecycle helpers (F7 owner-label strip) ────────────────────────
# REMOVED with the move to cascade delete: collect_finalizer_jobs() / strip_hook_finalizers(). They
# cleared argocd.argoproj.io/hook-finalizer off Argo's Sync/PostSync hook Jobs, which was necessary only
# because --cascade=orphan left those Jobs behind with Argo's own bookkeeping finalizer and no
# controller to clear it (ogsr-gitea hung 8h in the C2 lifecycle test). A cascade delete deletes the
# hook resources through Argo, which removes its own finalizer as part of that — there is nothing left
# to strip. If a degraded Argo ever leaves one behind, report_stuck_namespaces() names the Job and
# prints the clear command, and ogsr-check-clean.sh reports it afterwards.

preserve_and_strip() {  # ns reason — F2/F7: keep the namespace, remove every mark we put on it
  # Stripping the owner label alone is not enough. Argo also stamps `argocd.argoproj.io/tracking-id`
  # and the component kustomizations stamp `portfolio.redhat.com/component` on anything they adopt —
  # so an org namespace we merely borrowed still reads as ours afterwards. That is a visible "no
  # trace" failure, and ogsr-check-clean.sh reports it, meaning a genuinely clean teardown would
  # still exit non-zero. Remove all three; `oc label/annotate` with a trailing `-` is a no-op when
  # the key is absent, so this is safe on a namespace that never carried them.
  local ns="$1" reason="$2" key="${OWNER_LABEL%%=*}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   • WOULD preserve namespace/${ns} + strip ${key} / portfolio.redhat.com/component labels and ${TRACK_ANN} (${reason})"
    return 0
  fi
  oc label namespace "$ns" "${key}-" "${TRACK_LABEL}-" portfolio.redhat.com/component- --overwrite >/dev/null 2>&1 || true
  oc annotate namespace "$ns" "${TRACK_ANN}-" >/dev/null 2>&1 || true
  echo "   • preserved namespace/${ns}, removed our labels + Argo tracking-id (${reason})"
  return 0
}

strip_our_marks() {  # kind name ns — same de-marking for a single adopted OBJECT, not a namespace
  # Used for the org's Subscription/CSV/OperatorGroup, which Argo also stamps when it adopts them.
  # Deliberately does NOT touch argocd.argoproj.io/sync-options: install.sh merges our Prune/Delete
  # values into whatever the org already had there, so removing the whole annotation would silently
  # drop their settings. The uninstall removes only marks that are unambiguously ours.
  local kind="$1" name="$2" ns="${3:-}" key="${OWNER_LABEL%%=*}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   • WOULD strip our labels + ${TRACK_ANN} from ${kind}/${name}${ns:+ -n $ns}"
    return 0
  fi
  # TRACK_ANN is Argo's current tracking method, TRACK_LABEL the older one — both are marks we made,
  # and an Argo instance configured for either will have stamped that one.
  if [[ -n "$ns" ]]; then
    oc label "$kind" "$name" -n "$ns" "${key}-" "${TRACK_LABEL}-" portfolio.redhat.com/component- --overwrite >/dev/null 2>&1 || true
    oc annotate "$kind" "$name" -n "$ns" "${TRACK_ANN}-" >/dev/null 2>&1 || true
  else
    oc label "$kind" "$name" "${key}-" "${TRACK_LABEL}-" portfolio.redhat.com/component- --overwrite >/dev/null 2>&1 || true
    oc annotate "$kind" "$name" "${TRACK_ANN}-" >/dev/null 2>&1 || true
  fi
  return 0
}

del_ns_fast() {  # ns — delete a namespace classify already confirmed exists (skips del_obj's redundant get,
  local ns="$1"  # which halves step-9 round-trips on an 8-user cohort's ~100 per-user namespaces)
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD delete namespace/${ns}"; return 0; fi
  oc delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ok "deleted namespace/${ns}"
  return 0
}

# ── reverse the imperative bootstrap mutations ────────────────────────────────
remove_oauth_idp() {  # remove ONLY the workshop-users IdP entry, preserving every other identity provider
  local owned names n idx i backing
  owned="$(state oauth_idp_ownedbyus)"
  if [[ "$owned" != "true" ]]; then
    # Retrofit safety: a pre-Wave-1 install (no state ConfigMap) leaves oauth_idp_ownedbyus unrecorded,
    # so this branch would PRESERVE 'workshop-users' — but step 4 deletes the htpasswd secret it points
    # at, stranding a broken login provider on the org's cluster (fails "uninstall fully reverses"). The
    # IdP is unambiguously ours when it is backed by OUR htpasswd-workshop-users secret; remove it then.
    backing="$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.name=="workshop-users")].htpasswd.fileData.name}' 2>/dev/null || true)"
    if [[ "$backing" != "htpasswd-workshop-users" ]]; then
      echo "   • preserve OAuth IdP 'workshop-users' (not ours: no state record, not backed by htpasswd-workshop-users)"; return 0
    fi
    echo "   • OAuth IdP 'workshop-users' is backed by our htpasswd-workshop-users secret — removing (retrofit-safe)"
  fi
  names="$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
  idx=-1; i=0
  while IFS= read -r n; do
    if [[ "$n" == "workshop-users" ]]; then idx="$i"; break; fi
    i=$((i + 1))
  done <<< "$names"
  if [[ "$idx" -lt 0 ]]; then echo "   • skip OAuth IdP 'workshop-users' (already absent)"; return 0; fi
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD remove OAuth IdP 'workshop-users' (index ${idx}; other IdPs preserved)"; return 0; fi
  oc patch oauth cluster --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${idx}\"}]" >/dev/null 2>&1 || true
  ok "removed OAuth IdP 'workshop-users' (existing IdPs preserved)"  # TODO(verify-on-cluster)
  return 0
}

remove_console_plugins() {  # remove ONLY the plugin names workshop-config recorded as added (backlog #24)
  local added n idx i cur
  added="$(state console_plugins_added)"
  if [[ -z "$added" ]]; then
    echo "   • skip console plugins (no console_plugins_added recorded — feature never enabled, or nothing was newly added)"
    return 0
  fi
  for n in $added; do
    [[ -n "$n" ]] || continue
    # Recompute the index every iteration: removing one entry shifts every index after it.
    idx=-1; i=0
    while IFS= read -r cur; do
      if [[ "$cur" == "$n" ]]; then idx="$i"; break; fi
      i=$((i + 1))
    done < <(oc get consoles.operator.openshift.io cluster -o jsonpath='{range .spec.plugins[*]}{@}{"\n"}{end}' 2>/dev/null || true)
    if [[ "$idx" -lt 0 ]]; then
      echo "   • skip console plugin '${n}' (already absent)"
      continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "   • WOULD remove console plugin '${n}' from spec.plugins (index ${idx}; other plugins preserved)"
      continue
    fi
    oc patch consoles.operator.openshift.io cluster --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/plugins/${idx}\"}]" >/dev/null 2>&1 || true
    ok "removed console plugin '${n}' from spec.plugins (existing plugins preserved)"  # TODO(verify-on-cluster)
  done
  return 0
}

restore_monitoring() {  # put cluster-monitoring-config back the way we found it
  local existed prior
  existed="$(state monitoring_cm_existed)"
  prior="$(state monitoring_uwm_prior)"
  if [[ "$existed" == "false" ]]; then
    # Default clusters ship WITHOUT this ConfigMap — the portfolio created it, so we remove it.
    del_obj configmap cluster-monitoring-config openshift-monitoring
    return 0
  fi
  if [[ "$existed" != "true" ]]; then
    echo "   • skip cluster-monitoring-config (no recorded prior state — left as-is)"; return 0
  fi
  case "$prior" in
    true)
      echo "   • preserve cluster-monitoring-config (user-workload monitoring was already ON before install)";;
    false)
      if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD restore enableUserWorkload=false in cluster-monitoring-config"; return 0; fi
      oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml 2>/dev/null \
        | sed 's/enableUserWorkload: *true/enableUserWorkload: false/' \
        | oc apply -f - >/dev/null 2>&1 || true
      ok "restored enableUserWorkload=false in cluster-monitoring-config";;  # TODO(verify-on-cluster)
    *)
      err "cluster-monitoring-config pre-existed WITHOUT enableUserWorkload; we added it. Remove it manually:"
      echo "      oc -n openshift-monitoring edit configmap cluster-monitoring-config   # delete the enableUserWorkload line";;
  esac
  return 0
}

reverse_node_shaping() {  # remove the batch pool label+taint and the synthetic zone labels
  local node
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD untaint+unlabel node/${node} (${POOL_KEY})"; continue; fi
    oc adm taint nodes "$node" "${POOL_KEY}=batch:NoSchedule-" >/dev/null 2>&1 || true
    oc label node "$node" "${POOL_KEY}-" >/dev/null 2>&1 || true
    ok "removed batch pool label+taint from node/${node}"
  done < <(oc get nodes -l "$POOL_KEY" -o name 2>/dev/null | sed 's|.*/||' || true)
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD remove ${ZONE_KEY} label from node/${node}"; continue; fi
    oc label node "$node" "${ZONE_KEY}-" >/dev/null 2>&1 || true
    ok "removed ${ZONE_KEY} label from node/${node}"
  done < <(oc get nodes -l "$ZONE_KEY" -o name 2>/dev/null | sed 's|.*/||' || true)
  return 0
}

handle_lightspeed() {  # remove our MaaS secret / namespace only when WE installed Lightspeed
  local preinstalled ns_created secret_created secret_owner
  preinstalled="$(state lightspeed_preinstalled)"
  ns_created="$(state lightspeed_ns_created)"
  secret_created="$(state lightspeed_secret_created)"
  if [[ "$preinstalled" == "true" ]]; then
    echo "   • preserve OpenShift Lightspeed (pre-installed / adopted — untouched)"; return 0
  fi
  # Delete the MaaS secret ONLY with positive evidence it is ours: install recorded creating it, or it
  # still carries our owner label. Absent both — e.g. a re-run after the state CM was removed (every
  # second run is stateless, since run 1 deletes it), on an ADOPTED Lightspeed — we must NOT delete the
  # org's provider secret. Preserve-biased, matching the preflight's promise (retrofit-safe like the IdP).
  secret_owner="$(oc get secret credentials -n openshift-lightspeed -o jsonpath='{.metadata.labels.workshop\.redhat\.com/owner}' 2>/dev/null || true)"
  if [[ "$secret_created" == "true" || "$secret_owner" == "ogsr" ]]; then
    del_obj secret credentials openshift-lightspeed
  else
    echo "   • preserve secret credentials in openshift-lightspeed (no state/label showing WE created it)"
  fi
  if [[ "$ns_created" == "true" ]]; then
    del_obj namespace openshift-lightspeed
  else
    echo "   • preserve namespace/openshift-lightspeed (pre-existed; removed only our secret + operator)"
  fi
  return 0
}

handle_gitops() {  # remove the GitOps operator ONLY if we created it; otherwise preserve (+ note the memory bump)
  local preexisted csv res b64 prior_res prior_mem target_mem
  preexisted="$(state gitops_preexisted)"
  if [[ "$preexisted" == "false" ]]; then
    info "GitOps was installed by us — removing operator + default instance"
    del_obj argocd openshift-gitops openshift-gitops
    # Same resolution as step 3, and routed through the same single delete path. argocd-bootstrap
    # applies this Subscription imperatively so the cascade does not normally reach it — but "normally"
    # is exactly the assumption that broke step 3, and del_created_csv re-derives the authorization
    # from gitops_preexisted anyway, so an adopted GitOps can never be removed through it.
    res="$(resolve_operator_csv openshift-gitops-operator openshift-gitops-operator openshift-gitops-operator)"
    csv="${res%%|*}"
    del_obj subscriptions.operators.coreos.com openshift-gitops-operator openshift-gitops-operator
    if [[ -n "$csv" ]]; then
      del_created_csv "$csv" openshift-gitops-operator openshift-gitops-operator openshift-gitops-operator "${res#*|}"
    fi
    del_obj operatorgroup openshift-gitops-operator openshift-gitops-operator
    del_obj namespace openshift-gitops
    del_obj namespace openshift-gitops-operator
  else
    info "GitOps was adopted (pre-existing) — operator + instance preserved"
    b64="$(state gitops_argocd_controller_resources_b64)"
    if [[ -n "$b64" ]]; then
      prior_res="$(echo "$b64" | base64 --decode 2>/dev/null || true)"
      # Install only RAISES the controller memory limit (operator default 2Gi → 6Gi). If the org was
      # ALREADY at the target, install changed nothing and there is nothing to restore — so gate the
      # warning on prior≠target instead of firing whenever a prior spec was recorded (false alarm on a
      # cluster that shipped at 6Gi). Target is read from the canonical override so it never drifts.
      target_mem="$(yq '.spec.controller.resources.limits.memory' "${SCRIPT_DIR}/../platform-portfolio/argocd-bootstrap/operator/argocd-controller-resources.yaml" 2>/dev/null || true)"
      if [[ -z "$target_mem" || "$target_mem" == "null" ]]; then target_mem="6Gi"; fi
      prior_mem="$(echo "$prior_res" | yq -p=json '.limits.memory' 2>/dev/null || true)"
      if [[ "$prior_mem" == "$target_mem" ]]; then
        echo "   • openshift-gitops controller memory was already ${target_mem} before install — not raised, nothing to restore"
      else
        err "install raised the adopted openshift-gitops controller memory to ${target_mem} (was ${prior_mem:-unset}). Prior spec.controller.resources:"
        echo "      ${prior_res:-<unreadable>}"
        echo "      restore manually if the org relied on it: oc -n openshift-gitops edit argocd openshift-gitops"
      fi
    fi
  fi
  return 0
}

cleanup_created_operators() {  # remove Subscription+CSV for operators WE created (covers shared-ns operators)
  local name ns st pkg csv how res og n=0 live_subs sub_here
  # The report below has to say whether each Subscription is still there RIGHT NOW (the pre-cascade
  # snapshot cannot answer that — it would always say "present"). One list answers it for every
  # operator; 22 individual gets would be ~66s of round-trips on a remote cluster.
  live_subs=" $(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null || true) "
  while read -r name ns st pkg; do
    [[ -n "$name" ]] || continue
    n=$((n + 1))
    sub_here="false"
    case "$live_subs" in *" ${ns}/${name} "*) sub_here="true";; esac
    if [[ "$st" == "created" ]]; then
      # Resolve the CSV WITHOUT depending on the Subscription — by step 3 the cascade has normally
      # taken it. See § operator CSV identity for the mechanisms and why the old installedCSV-only
      # lookup silently found nothing for every operator.
      res="$(resolve_operator_csv "$name" "$ns" "$pkg")"
      csv="${res%%|*}"; how="${res#*|}"
      # Report the three states apart. The old code printed `skip … (absent)` for a Subscription the
      # cascade had already removed, which reads as "nothing to do" at exactly the moment its CSV still
      # needs deleting — the failure looked like a success in the log.
      if [[ "$sub_here" == "true" ]]; then
        echo "   • ${name} -n ${ns}: Subscription still present (the cascade did not prune it) — removing Subscription + CSV"
        del_obj subscriptions.operators.coreos.com "$name" "$ns"
      elif [[ -n "$csv" ]] && [[ -n "$(csv_index_props "$ns" "$csv")" ]]; then
        echo "   • ${name} -n ${ns}: Subscription already pruned by the cascade, but its CSV is STILL HERE."
        echo "     An orphaned CSV is not litter — it makes the NEXT install of this workshop fail to"
        echo "     resolve (constraints not satisfiable: @existing/${ns}//${csv}). Removing it."
      else
        echo "   • ${name} -n ${ns}: Subscription and CSV both already gone — nothing owed"
      fi
      if [[ -n "$csv" ]]; then
        del_created_csv "$csv" "$ns" "$name" "$pkg" "$how"
      elif [[ "$sub_here" == "true" ]]; then
        err "   could not name the CSV for ${name} in ${ns}: its Subscription reports no installedCSV and"
        err "      no CSV in that namespace carries package '${pkg}'. If one appears later it will block"
        err "      the next install — check and remove by hand:"
        echo "      oc get csv -n ${ns}   # then: oc delete csv <name> -n ${ns}"
      fi
    else
      echo "   • preserve operator ${name} in ${ns} (${st} — not created by us)"
      # Preserving is necessary but not sufficient: Argo stamped the org's own Subscription, CSV and
      # OperatorGroup with our labels and its tracking-id when it adopted them. Leaving those behind
      # means the cluster still reads as ours after a "complete" teardown, and ogsr-check-clean.sh
      # correctly reports it — so a clean run would still exit non-zero. De-mark what we marked.
      strip_our_marks subscriptions.operators.coreos.com "$name" "$ns"
      # Same resolver as the created branch, for the same reason: an adopted operator's Subscription is
      # ALSO Argo-managed (install.sh adopts it), so the cascade takes it and the installedCSV lookup
      # that used to be here returned "" — leaving our labels and Argo's tracking-id on the org's CSV
      # after a teardown that claimed to leave no trace. This branch only ever STRIPS marks; it has no
      # call path to del_created_csv, which is what makes the adopted guard structural rather than
      # conditional.
      csv="$(resolve_operator_csv "$name" "$ns" "$pkg" | cut -d'|' -f1)"
      # Same shape as the killer above, and it survives here only because it is not currently last —
      # which is exactly how this class hides. Written as an `if` so re-ordering this branch is safe.
      if [[ -n "$csv" ]]; then
        strip_our_marks clusterserviceversions.operators.coreos.com "$csv" "$ns"
      fi
      while IFS= read -r og; do
        [[ -n "$og" ]] || continue
        strip_our_marks operatorgroups.operators.coreos.com "$og" "$ns"
      done < <(oc get operatorgroups.operators.coreos.com -n "$ns" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
      # The NAMESPACE itself, not just the objects inside it. Argo stamps its tracking-id on a
      # namespace it adopts, and preserve_and_strip never reaches this one — an adopted operator's
      # namespace is not in the "preserved" list, it is simply never a deletion candidate. Leaving
      # the mark means ogsr-check-clean.sh correctly reports the org's namespace as marked by us
      # after a teardown that was otherwise complete. Measured on ksls5, 2026-07-25.
      strip_our_marks namespace "$ns" ""
    fi
  done < <(enumerate_operators)
  # Say so when there is nothing to act on, rather than printing an empty step. This is the ordinary
  # shape of a RE-RUN after a completed uninstall: run 1 deleted the state ConfigMap in step 8, so
  # created-vs-adopted is unknowable and NOTHING here is authorized to delete an operator's CSV.
  if [[ "$n" -eq 0 ]]; then
    echo "   • no operators recorded in ${STATE_NS}/${STATE_CM} — nothing here is authorized for removal."
    echo "     (A re-run after a completed uninstall looks exactly like this. If CSVs of ours are still"
    echo "      on the cluster, ./bootstrap/ogsr-check-clean.sh names them with their removal command.)"
  fi
  return 0
}

# F2/F7 — classify EVERY owner-labeled namespace exactly as the teardown will act on it, so the plan
# and the action can never disagree (each row is "<verb>\t<ns>\t<reason>"). Delete allowlist = the
# INSTALLED stacks' namespaces + the workshop's own per-user/shared namespaces. Anything else that is
# owner-labeled is PRESERVED and de-labeled: an adopted operator's namespace (deleting it would take
# the org's operator down with it), or a namespace of a stack no longer installed (openshift-mta).
classify_workshop_namespaces() {
  local created_op_ns=" " adopted_op_ns=" " stack_ns name ns st n user layer shared
  # enumerate_operators emits four fields; the package is discarded here. Reading three would put
  # "created <package>" into $st and silently classify every namespace as adopted.
  while read -r name ns st _; do
    [[ -n "$ns" ]] || continue
    if [[ "$st" == "created" ]]; then created_op_ns="${created_op_ns}${ns} "; else adopted_op_ns="${adopted_op_ns}${ns} "; fi
  done < <(enumerate_operators)
  stack_ns=" $(enumerate_installed_stack_ns | tr '\n' ' ') "
  while IFS=$'\t' read -r n user layer shared; do
    [[ -n "$n" ]] || continue
    if [[ "$n" == "$STATE_NS" ]]; then
      printf 'defer\t%s\tuninstall-state namespace (removed last)\n' "$n"; continue
    fi
    if [[ "$n" == "openshift-lightspeed" ]]; then
      printf 'defer\t%s\tLightspeed (its own adoption guard)\n' "$n"; continue
    fi
    # Adopted-operator namespace → PRESERVE (the operator lives here) + strip our owner label (F7).
    case "$adopted_op_ns" in *" $n "*) printf 'preserve-strip\t%s\tadopted-operator namespace (operator preserved)\n' "$n"; continue;; esac
    # Workshop-owned per-user / shared namespace (marker label) → ours to delete.
    if [[ -n "$user" || "$layer" == "workshop-config" || "$shared" == "true" ]]; then
      printf 'delete\t%s\tworkshop-owned (per-user / shared) namespace\n' "$n"; continue
    fi
    # Namespace of an installed stack — an operator we created, or plain infra like ogsr-gitea → delete.
    case "$created_op_ns" in *" $n "*) printf 'delete\t%s\tinstalled-stack operator namespace (created by us)\n' "$n"; continue;; esac
    case "$stack_ns"       in *" $n "*) printf 'delete\t%s\tinstalled-stack namespace\n' "$n"; continue;; esac
    # Owner-labeled but attributable to NO installed stack (e.g. openshift-mta after `mta` left the set,
    # or infra we cannot positively attribute) → PRESERVE intact + strip the label + flag for review (F2).
    printf 'preserve-strip\t%s\tnot part of installed_stacks (%s) — left intact, review manually\n' "$n" "$(state installed_stacks)"
  done < <(oc get namespaces -l "$OWNER_LABEL" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.workshop\.redhat\.com/user}{"\t"}{.metadata.labels.workshop\.redhat\.com/layer}{"\t"}{.metadata.labels.workshop\.redhat\.com/shared}{"\n"}{end}' 2>/dev/null || true)
  return 0
}

delete_workshop_namespaces() {  # act on the classification: delete ours, preserve+strip the rest (F7)
  local verb n reason
  while IFS=$'\t' read -r verb n reason; do
    [[ -n "$n" ]] || continue
    case "$verb" in
      delete)         del_ns_fast "$n"; DELETED_WS_NS+=("$n");;
      preserve-strip) preserve_and_strip "$n" "$reason";;
      defer)          : ;;  # STATE_NS removed right after this fn; Lightspeed handled by handle_lightspeed
    esac
  done < <(classify_workshop_namespaces)
  return 0
}

# F6 — a namespace whose operator we PRESERVED can wedge in Terminating on an operator-instance CR
# finalizer (e.g. CheCluster che.eclipse.org). We refuse to auto-strip arbitrary CR finalizers: the
# operator may still need to run its cleanup, and after the cascade the ordinary case is that it CAN —
# step 2 removed operand CRs while their operators were alive, so anything still holding here is a
# genuine exception worth a human. We wait (bounded, early-exit) for our deletes to finish, then REPORT
# what remains with the finalizer-holding objects and the exact manual clear command.
report_ns_finalizer_holders() {  # ns — surface what blocks termination, from the namespace's OWN status
  local ns="$1" rtype objname fins
  # The namespace controller records exactly what content + which finalizers remain, in
  # status.conditions — ONE read, instead of brute-force `oc get` across every namespaced
  # api-resource (~100 calls, which is what pushed the first C2 run past the run budget).
  oc get namespace "$ns" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{"      ↳ "}{.type}{": "}{.message}{"\n"}{end}' 2>/dev/null || true
  # For each resource TYPE the status still lists as remaining, print each object + the exact clear cmd
  # (the finalizers themselves are already itemised in the NamespaceFinalizersRemaining message above).
  while IFS= read -r rtype; do
    [[ -n "$rtype" ]] || continue
    while IFS= read -r objname; do
      [[ -n "$objname" ]] || continue
      echo "         clear: oc patch ${rtype} ${objname} -n ${ns} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done < <(oc get "$rtype" -n "$ns" -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  done < <(oc get namespace "$ns" -o jsonpath='{range .status.conditions[*]}{.message}{"\n"}{end}' 2>/dev/null \
            | grep -oE '[a-z0-9.-]+\.[a-z0-9-]+ has [0-9]+ resource instances' | sed 's/ has.*//' | sort -u || true)
  return 0
}

report_stuck_namespaces() {  # names… — bounded wait for termination, then report any still stuck (>~2min)
  local targets=("$@") waited=0 max=150 ns remaining present
  [[ ${#targets[@]} -gt 0 && "$DRY_RUN" != "true" ]] || return 0
  while (( waited < max )); do
    # ONE list per poll (not one get per target — the delete set can be ~100 namespaces).
    present=" $(oc get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true) "
    remaining=()
    for ns in "${targets[@]}"; do case "$present" in *" $ns "*) remaining+=("$ns");; esac; done
    if [[ ${#remaining[@]} -eq 0 ]]; then
      ok "all deleted workshop namespaces finished terminating"; return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  # Guard the expansion: /usr/bin/env bash is 3.2 on a stock macOS, where "${arr[@]}" on an EMPTY
  # array under `set -u` is an unbound-variable error, not an empty list.
  [[ ${#remaining[@]} -gt 0 ]] || return 0
  err "still Terminating after ${max}s — a preserved operator's CR finalizer is holding these namespaces:"
  for ns in "${remaining[@]}"; do
    echo "   ✗ namespace/${ns} — finalizer-holding objects (clear ONLY if you understand the operator's cleanup):"
    report_ns_finalizer_holders "$ns"
  done
  return 0
}

# ── plan ──────────────────────────────────────────────────────────────────────
print_plan() {
  local apps roots created adopted name ns st pkg gitops_plan mon_plan gw_plan mirror_plan
  local verb wn reason nwipe=0 wipe_stack="" strip_list="" csv_plan="" res
  mirror_plan="$(mirror_stack)"
  # `grep -c .` prints 0 AND exits 1 on empty input, so a `|| echo '?'` fallback appended a second line
  # and the plan read "0\n?". Take the count and normalise it instead.
  apps="$(our_applications | grep -c . || true)"; apps="${apps:-0}"
  # Drive the namespace plan from the SAME classifier step 9 uses, so the summary is exactly the action.
  while IFS=$'\t' read -r verb wn reason; do
    case "$verb" in
      delete) nwipe=$((nwipe + 1)); case "$reason" in installed-stack*) wipe_stack="${wipe_stack} ${wn}";; esac;;
      preserve-strip) strip_list="${strip_list}\n      - ${wn} — ${reason}";;
    esac
  done < <(classify_workshop_namespaces)
  created=""; adopted=""
  while read -r name ns st pkg; do
    [[ -n "$name" ]] || continue
    if [[ "$st" != "created" ]]; then adopted="${adopted} ${name}(${st})"; continue; fi
    created="${created} ${name}"
    # Name the CSVs, resolved by the SAME call step 3 makes, so the plan and the action cannot
    # disagree. This is the line whose absence hid the defect: a plan that says only "operators WE
    # created: devspaces …" is silent about the object that actually blocks the next install.
    res="$(resolve_operator_csv "$name" "$ns" "$pkg")"
    if [[ -n "${res%%|*}" ]]; then
      csv_plan="${csv_plan}\n      - ${ns}/${res%%|*}  (${name}, identified via ${res#*|})"
    else
      csv_plan="${csv_plan}\n      - ${ns}: no CSV on the cluster for package '${pkg}' — nothing to remove"
    fi
  done < <(enumerate_operators)

  # Three-way plans: created-by-us → REMOVE/restore; recorded-adopted → PRESERVE; NO state record at all
  # (pre-Wave-1 install, or the state CM was lost) → PRESERVE and say so honestly. Found in the 2026-07-17
  # verification pass: the old two-way else printed "restore → ?" on a stateless cluster while step 4
  # correctly skipped — the summary must match the action.
  case "$(state gitops_preexisted '')" in
    false) gitops_plan="REMOVE (we installed it)";;
    true)  gitops_plan="PRESERVE (adopted)";;
    *)     gitops_plan="PRESERVE (no state recorded)";;
  esac
  case "$(state monitoring_cm_existed '')" in
    false) mon_plan="REMOVE (we created it)";;
    true)  mon_plan="restore enableUserWorkload → $(state monitoring_uwm_prior '?')";;
    *)     mon_plan="PRESERVE (no state recorded)";;
  esac
  case "$(state gatewayclass_preexisted '')" in
    false) gw_plan="REMOVE (we created it)";;
    true)  gw_plan="PRESERVE (adopted)";;
    *)     gw_plan="PRESERVE (no state recorded)";;
  esac

  roots="$(root_applications | grep -c . || true)"; roots="${roots:-0}"

  echo "ogsr-uninstall — WIPE the workshop, PRESERVE everything the org owns"
  echo
  echo "WILL WIPE:"
  echo "  • ${apps} of our Argo Applications (pp-*, workshop-config, entry-*), CASCADE-deleted:"
  echo "      ${roots} app-of-apps root(s) are deleted and Argo prunes downward in reverse sync-wave"
  echo "      order, so an operand CR is removed while its operator is still running. Everything Argo"
  echo "      installed goes with them — namespaces, CRs, RBAC, Subscriptions — except the resources"
  echo "      listed under PROTECTED below."
  echo "      Roots go in THREE ordered, blocking phases — consumers before providers:"
  echo "        1. the workshop layer (workshop-config, entry-*), whose CRs are operands of"
  echo "           operators the platform stacks own;"
  echo "        2. the platform stacks;"
  echo "        3. the stack hosting the in-cluster git mirror${mirror_plan:+ (${mirror_plan})}, last."
  echo "  • ${nwipe} owner-labeled namespaces (per-user {user}-*, shared ogsr-*, installed-stack:${wipe_stack:- <none>} )"
  echo "    — most are pruned by the cascade; step 9 deletes any Argo did not manage, and waits."
  echo "  • the argo controller ClusterRoleBinding + ClusterRoles (applied imperatively by argocd-bootstrap)"
  echo "  • imperative bootstrap objects: htpasswd-workshop-users, workshop-users OAuth IdP entry, node labels/taint"
  echo "  • console plugins WE added to consoles.operator.openshift.io (backlog #24): $(state console_plugins_added '<none recorded>')"
  echo "  • operators WE created:${created:-<none recorded>}"
  echo "  • their ClusterServiceVersions — OLM creates a CSV from a Subscription and Argo never manages"
  echo "    it, so the cascade cannot prune it and only step 3 can. Left behind, a CSV BLOCKS the next"
  echo "    install of this workshop (OLM: constraints not satisfiable / @existing):"
  printf '%b\n' "${csv_plan:-\n      - <none>}"
  echo
  echo "WILL PRESERVE (untouched):"
  echo "  • operators the org already had:${adopted:-<none recorded>}"
  # Components the install SKIPPED because this cluster already ran that operator (portfolio §0
  # adoption). Their Subscriptions are among the "adopted" line above — this names the components, so
  # the reason those namespaces survive teardown is legible instead of inferred.
  echo "  • components never installed (this cluster already provided them): $(state skipped_components '<none>')"
  printf '  • namespaces preserved + owner-label stripped (adopted-operator / not in installed_stacks — F2/F7):%b\n' "${strip_list:-\n      - <none>}"
  echo "  • GitOps operator: ${gitops_plan}"
  echo "  • cluster-monitoring-config: ${mon_plan}"
  echo "  • openshift-default GatewayClass: ${gw_plan}"
  echo "  • every namespace/operator/CR the org owns and we never labeled"
  echo
  # The cascade's safety rests entirely on this list, so it is shown rather than summarised: each line
  # is a resource the state ConfigMap records as the org's, and the reason it survives Argo's prune.
  echo "PROTECTED FROM THE CASCADE (verified live, not assumed):"
  if [[ -n "$PROT_NOTE_LIST" ]]; then
    printf '%s\n' "${PROT_NOTE_LIST#$'\n'}"
  else
    echo "      (none — this install adopted nothing, so the cascade has nothing to skip)"
  fi
  if [[ "$PROT_BAD" -gt 0 ]]; then
    echo "      ⚠️  ${PROT_BAD} adopted resource(s) are NOT protected — details below."
  fi
  echo
  return 0
}

del_appprojects() {  # the AppProject(s) argocd-bootstrap applies imperatively
  # ogsr-platform must exist BEFORE the Applications that name it, so it is applied with `oc apply`
  # outside any Application — which means the cascade never sees it and it outlives the teardown.
  # It is also not inert: the installer unions its sourceRepos/destinations on every apply, so a
  # stale one silently widens what a later install is allowed to sync.
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    del_obj appprojects.argoproj.io "$name" "$ARGO_NS"
  done < <(oc get appprojects.argoproj.io -n "$ARGO_NS" -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' || true)
  return 0
}

remove_argo_tls_cert_key() {  # drop OUR host key from a ConfigMap the org may also be using
  # install.sh merges the mirror's host into argocd-tls-certs-cm so Argo can verify Gitea's cert
  # without `insecure: true`, and records which host under argo_tls_cert_host precisely so teardown
  # can remove exactly that key. Deleting the whole ConfigMap would strip every host the org trusts.
  local host esc
  host="$(state argo_tls_cert_host '')"
  [[ -n "$host" ]] || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   • WOULD remove key ${host} from configmap/argocd-tls-certs-cm -n ${ARGO_NS}"
    return 0
  fi
  oc get configmap argocd-tls-certs-cm -n "$ARGO_NS" >/dev/null 2>&1 || return 0
  esc="$(printf '%s' "$host" | sed 's|~|~0|g; s|/|~1|g')"   # RFC 6901 JSON-pointer escaping
  if oc patch configmap argocd-tls-certs-cm -n "$ARGO_NS" --type=json \
       -p "[{\"op\":\"remove\",\"path\":\"/data/${esc}\"}]" >/dev/null 2>&1; then
    ok "removed ${host} from argocd-tls-certs-cm (other hosts untouched)"
  else
    info "argocd-tls-certs-cm carries no ${host} key — nothing to remove"
  fi
  return 0
}

# ── the eight steps ───────────────────────────────────────────────────────────
# One function per step, so `main` is a list of run_step calls and the ledger it prints cannot drift
# from what actually ran. Multi-action steps route each action through sub(), which reports a failing
# action and still runs the rest — the OAuth IdP must come out even if the console-plugin patch fails.
step_stop_reconciliation() {  # 1 — no app-of-apps may re-create a child mid-teardown
  local app
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD disable automated sync on application/${app}"; continue; fi
    oc patch application "$app" -n "$ARGO_NS" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
  done < <(our_applications)
  return 0
}

step_reverse_cluster_mutations() {  # 4 — the imperative, cluster-global changes install.sh made
  sub remove_oauth_idp
  sub remove_console_plugins
  sub del_obj secret htpasswd-workshop-users openshift-config
  sub handle_lightspeed
  sub restore_monitoring
  sub reverse_node_shaping
  return 0
}

step_gateway_api() {  # 5 — remove only if we created it. Argo manages this CR (it is
  # platform-portfolio/components/gateway-api/gatewayclass.yaml), so a GatewayClass WE created is
  # already gone with the cascade and del_obj skips it. Kept for the adopted case, which is the branch
  # that matters: it must NOT be deleted, and the guard above has verified Argo will skip it.
  if [[ "$(state gatewayclass_preexisted)" == "false" ]]; then
    del_obj gatewayclass.gateway.networking.k8s.io openshift-default
  else
    echo "   • preserve GatewayClass/openshift-default (adopted / pre-existing)"
  fi
  return 0
}

step_cluster_rbac() {  # 6 — cluster-scoped objects the cascade CANNOT reach, because Argo never
  # managed them. Everything else that used to be swept here is now pruned by step 2 and has been
  # removed from this step: Group/workshop-attendees, the Kueue ResourceFlavor/WorkloadPriorityClass/
  # ClusterQueue triple (all gitops/workshop-config/templates/kueue-queues.yaml), AppProjects
  # (student-appprojects.yaml + appproject-workshop-entries.yaml) and the openshift/java-21
  # ImageStream (java-21-imagestream.yaml) — every one is rendered by the workshop-config Application,
  # so cascade-deleting it removes them in the same pass, with dependency ordering bash never had.
  # What remains has a genuinely imperative source: platform-portfolio/argocd-bootstrap/install.sh
  # applies controller-rbac.yaml (the openshift-gitops-application-controller-cluster-admin binding)
  # with `oc apply`, outside any Application. The ClusterRole half is swept alongside it because RBAC
  # is the one leftover class that grants standing access after a teardown.
  sub del_labeled_cluster clusterrolebindings.rbac.authorization.k8s.io
  sub del_labeled_cluster clusterroles.rbac.authorization.k8s.io
  sub del_appprojects
  sub remove_argo_tls_cert_key
  sub sweep_dead_webhooks
  return 0
}

sweep_dead_webhooks() {  # admission webhooks whose backing Service died with a namespace we removed
  # Some operators register their webhooks at RUNTIME rather than through the CSV's webhookdefinitions,
  # so OLM does not own them and removing the operator leaves them behind. Sync waves cannot help: the
  # operator's finalizer only cleans up what the operator itself tracks. Measured on ksls5 2026-07-25 —
  # keda-admission and stackrox both survived a complete teardown pointing at deleted Services.
  #
  # These are not inert. failurePolicy=Fail means every create/update the webhook intercepts is REJECTED
  # while its backend is gone, which blocks writes and can block deletion of objects in the namespaces it
  # covers. Left behind, they degrade a cluster that is supposed to be back to normal.
  #
  # Scoped deliberately: only webhooks whose Service lives in a namespace WE owned and removed. A webhook
  # pointing at a live Service is working; one pointing into a namespace that was never ours is the org's
  # problem to diagnose, not ours to delete — ogsr-check-clean.sh reports those instead.
  # Read the owned-namespace set from the installed stacks' MANIFESTS, not from the cluster: by the
  # time this runs the namespaces are already deleted, so a live query would return nothing.
  local kind name svc_ns svc_nm owned
  owned=" $(enumerate_installed_stack_ns | tr '\n' ' ') "
  for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    while IFS='|' read -r name svc_ns svc_nm; do
      [[ -n "$name" && -n "$svc_ns" ]] || continue
      case "$owned" in *" ${svc_ns} "*) ;; *) continue ;; esac
      oc get namespace "$svc_ns" >/dev/null 2>&1 && continue        # namespace still there: not ours to judge
      oc get service "$svc_nm" -n "$svc_ns" >/dev/null 2>&1 && continue
      del_obj "$kind" "$name"
    done < <(oc get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.webhooks[0].clientConfig.service.namespace}{"|"}{.webhooks[0].clientConfig.service.name}{"\n"}{end}' 2>/dev/null || true)
  done
  return 0
}

step_delete_namespaces() {  # 8 — whatever the cascade did not own, then the state namespace last
  sub delete_workshop_namespaces
  # The state ConfigMap is about to go with its namespace, so dump it first: ogsr-check-clean.sh needs
  # it to tell an adopted operator from one we created, and a second run has no other source.
  # Only set in a REAL run: the closing guidance prints `--state-file $STATE_DUMP` when the file is
  # readable, and a dry-run must not point at a dump left behind by some earlier run.
  if [[ "$DRY_RUN" != "true" && -n "$STATE_SNAPSHOT" ]]; then
    STATE_DUMP="${TMPDIR:-/tmp}/ogsr-uninstall-state.txt"
    if printf '%s\n' "$STATE_SNAPSHOT" > "$STATE_DUMP" 2>/dev/null; then
      ok "install state saved to ${STATE_DUMP}"
    else
      err "could not write the install-state dump to ${STATE_DUMP} — ogsr-check-clean.sh will run without it"
    fi
  fi
  sub del_obj namespace "$STATE_NS"
  DELETED_WS_NS+=("$STATE_NS")   # always ≥1 element, so the expansion below is safe on bash 3.2
  sub report_stuck_namespaces "${DELETED_WS_NS[@]}"
  return 0
}

# ── main ──────────────────────────────────────────────────────────────────────
echo "▶ ogsr-uninstall  (cluster: $(oc whoami --show-server 2>/dev/null || echo '?') as $(oc whoami 2>/dev/null || echo '?'))"
if [[ "$DRY_RUN" == "true" ]]; then echo "  MODE: --dry-run (no changes will be made)"; fi
echo

# Verify BEFORE the plan is printed and before anyone is asked to confirm: the plan's PROTECTED section
# is this check's output, and refusing after a "yes" would be asking for consent to something we then
# decline to do. The check itself is read-only, so running it in dry-run costs nothing.
# FIRST, before anything else reads or touches the cluster: this is the only moment at which OLM's own
# `.status.installedCSV` is still readable for every operator, and both the protection guard below and
# step 3 resolve CSVs through the memo it fills. Read-only, so it also runs in --dry-run — which is
# what lets the plan name the exact CSVs a real run would remove.
info "capturing operator CSV identity before anything can delete a Subscription"
capture_installed_csvs

info "verifying adopted-resource protection (the cascade's one safety assumption)"
assert_adopted_protection

print_plan
enforce_adopted_protection

if [[ "$DRY_RUN" == "true" ]]; then
  info "dry-run — showing intended actions (no changes made):"
else
  if [[ "$ASSUME_YES" != "true" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Proceed — WIPE the workshop, PRESERVE the org? [y/N] " reply
      [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || { info "nothing changed. Re-run with --yes when ready."; exit 0; }
    else
      die "not a terminal and no --yes given — re-run: ./ogsr-uninstall.sh --yes"
    fi
  fi
fi

run_step "[1/8] stopping reconciliation on workshop Argo Applications" step_stop_reconciliation

# CASCADE-delete our apps: deleting the Application IS the uninstall. Argo removes what it installed,
# in reverse sync-wave order, so each operator is still running when its own operand CR is deleted and
# that CR's finalizer can complete — which is also how the operator's webhooks and APIServices get
# removed at the source instead of being swept up afterwards. The previous --cascade=orphan protected
# adopted operators by exempting EVERYTHING, which threw away Argo's ordering and forced the
# incomplete bash re-implementation below it; adopted resources are now exempted individually.
run_step "[2/8] cascade-deleting workshop Argo Applications (Argo prunes what it installed)" \
  cascade_delete_applications

# CSVs for operators WE created. The cascade already pruned their Subscriptions (those ARE in our
# component manifests), but a CSV is created by OLM from the Subscription, never by Argo, so nothing
# prunes it — deleting a Subscription deliberately leaves its CSV and the running operator behind.
# This is the one operator-removal step GitOps cannot do for us — and the one that must not depend on
# the Subscription still being there, because by now it usually is not (§ operator CSV identity). The
# Subscription delete remains for the degraded-Argo / imperative case.
run_step "[3/8] removing CSVs for operators we created (adopted operators preserved)" \
  cleanup_created_operators

run_step "[4/8] reversing imperative cluster mutations (OAuth IdP, console plugins, monitoring, nodes, htpasswd)" \
  step_reverse_cluster_mutations

run_step "[5/8] Gateway API" step_gateway_api

run_step "[6/8] deleting owner-labeled cluster RBAC that no Application manages" step_cluster_rbac

run_step "[7/8] GitOps operator (removed only if we created it)" handle_gitops

run_step "[8/8] deleting workshop namespaces (org / adopted-operator namespaces preserved + de-labeled)" \
  step_delete_namespaces

# The step ledger and the closing verdict are printed by the EXIT trap, so they are emitted on an early
# death too. What follows is guidance that is worth having either way.
echo
echo "   Operators create CRDs, APIServices and admission webhooks at runtime, so no GitOps teardown"
echo "   can own them. The checker reports those with the exact removal command for each, and exits 0"
echo "   once nothing remains. Deciding what to remove is yours — deleting a CRD deletes every instance"
echo "   of it cluster-wide, including any the org created."
cat <<'VERIFY'

   Spot-check by hand if you prefer:
     oc get ns -l workshop.redhat.com/owner=ogsr                 # expect: no resources
     oc get applications -n openshift-gitops | grep -E 'pp-|entry-|workshop-config'   # expect: none
     oc get clusterrole,clusterrolebinding -l workshop.redhat.com/owner=ogsr          # expect: none
     oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'; echo       # expect: workshop-users absent
     oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'; echo  # expect: names WE added absent, everything else preserved
     # Adopted operators must still be Present/Succeeded:
     oc get csv -A | grep -Ev 'ogsr'                             # org operators intact
VERIFY
