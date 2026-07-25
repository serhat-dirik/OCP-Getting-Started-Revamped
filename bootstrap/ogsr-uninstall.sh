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
#                                     # how long to let Argo finish pruning before continuing (default 900)
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

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,45p'; exit 1; }

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
}

# Re-derive the operators the install installed, from the SAME component manifests + recorded stacks.
# Echoes one "subname namespace state" line per operator (state = created|adopted|unknown).
enumerate_operators() {
  local stacks stack app comp_path sub name ns st _stacks
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
        st="$(state "op_${name}" | cut -d: -f1)"
        [[ -n "$st" ]] || st="unknown"
        echo "${name} ${ns} ${st}"
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
      echo "gitea-operator gitea-operator ${st}"
      ;;
  esac
}

# Every namespace the INSTALLED stacks declare in their component manifests — the "installed stacks'
# namespaces" half of F2's delete allowlist. Mirrors enumerate_operators but reads namespace*.yaml
# instead of subscription*.yaml, so it also catches non-operator infra namespaces (e.g. ogsr-gitea)
# that carry no per-user/shared marker label. A stack no longer in installed_stacks contributes
# nothing here, so its leftover owner-labeled namespace (e.g. openshift-mta) is NOT in the allowlist.
enumerate_installed_stack_ns() {
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
        while IFS= read -r n; do
          [[ -n "$n" && "$n" != "null" ]] && echo "$n"
        done < <(yq 'select(.kind == "Namespace") | .metadata.name' "$nsfile" 2>/dev/null || true)
      done
    done
  done
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

obj_exists() { local k="$1" n="$2" ns="${3:-}"
  if [[ -n "$ns" ]]; then oc get "$k" "$n" -n "$ns" >/dev/null 2>&1; else oc get "$k" "$n" >/dev/null 2>&1; fi
}

check_adopted() {  # kind name ns why — classify ONE adopted resource against the cascade
  local kind="$1" name="$2" ns="${3:-}" why="$4" loc nsarg=""
  loc="${kind%%.*}/${name}"; [[ -n "$ns" ]] && { loc="${loc} -n ${ns}"; nsarg=" -n ${ns}"; }
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
    csv="$(oc get subscriptions.operators.coreos.com "$name" -n "$ns" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    [[ -n "$csv" ]] && check_adopted clusterserviceversions.operators.coreos.com "$csv" "$ns" \
      "CSV of an adopted operator"
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
  [[ "$(state gatewayclass_preexisted '')" == "true" ]] && \
    check_adopted gatewayclasses.gateway.networking.k8s.io openshift-default "" "GatewayClass the cluster already had"
  [[ "$(state monitoring_cm_existed '')" == "true" ]] && \
    check_adopted configmap cluster-monitoring-config openshift-monitoring "the org's own cluster-monitoring-config"
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
  [[ "$DRY_RUN" == "true" ]] && { echo >&2; err "(dry-run: a real run stops here. Nothing was changed.)"; exit 1; }
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
}

wait_for_cascade() {  # bounded, progress-printing wait until every one of our Applications is gone
  local waited=0 n prev="" label="$1"
  local budget="$2"
  while (( waited < budget )); do
    n="$(our_applications | grep -c . || true)"; n="${n:-0}"
    if [[ "$n" == "0" ]]; then
      ok "${label}: Argo finished pruning after ${waited}s — 0 workshop Applications remain"
      return 0
    fi
    # Print only on change, so an unattended run shows progress without a wall of identical lines.
    if [[ "$n" != "$prev" ]]; then
      echo "   … ${n} Application(s) still pruning (${waited}s of ${budget}s)"
      prev="$n"
    fi
    sleep 10; waited=$((waited + 10))
  done
  return 1
}

cascade_delete_applications() {
  local app n roots=0 total=0 sweep_budget
  # The straggler sweep gets a third of the main budget (floor 30s): someone who sets a short
  # --cascade-timeout means "do not sit here", and a fixed second wait would ignore that.
  sweep_budget=$(( CASCADE_TIMEOUT / 3 )); [[ "$sweep_budget" -lt 30 ]] && sweep_budget=30
  total="$(our_applications | grep -c . || true)"; total="${total:-0}"
  if [[ "$total" == "0" ]]; then ok "no workshop Argo Applications present — nothing to cascade"; return 0; fi

  # (a) Arm EVERY app, children included. A child pruned by its parent still needs its own finalizer,
  #     or the parent's cascade deletes the child Application object and orphans the child's resources.
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD ensure ${ARGO_FINALIZER} on application/${app}"; continue; fi
    ensure_resources_finalizer "$app"
  done < <(our_applications)
  [[ "$DRY_RUN" == "true" ]] || ok "armed ${total} Application(s) with ${ARGO_FINALIZER} (cascade, not orphan)"

  # (b) Delete the ROOTS only and let Argo prune downward in reverse sync-wave order. --wait=false so
  #     all roots start pruning together; the ordering that matters is WITHIN each app-of-apps.
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    roots=$((roots + 1))
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD cascade-delete application/${app} (root — Argo prunes its children in reverse sync-wave order)"; continue; fi
    oc delete applications.argoproj.io "$app" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    ok "cascade-delete requested for application/${app}"
  done < <(root_applications)
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   • WOULD then wait up to ${CASCADE_TIMEOUT}s for Argo to finish pruning before touching anything else"
    return 0
  fi

  # (c) WAIT. Everything after this step assumes Argo is done: step 3 removes operators, step 9 deletes
  #     namespaces. Racing ahead is how an operand CR ends up outliving its operator and stranding a
  #     finalizer nothing can run (TempoMonolithic/traces, 2026-07-25) — the exact bug this replaces.
  info "waiting for Argo to finish pruning (${roots} root app(s), up to ${CASCADE_TIMEOUT}s)"
  wait_for_cascade "cascade" "$CASCADE_TIMEOUT" && return 0

  # (d) Stragglers: a child whose parent was already gone (a legacy stale pp-* app) is never reached by
  #     a root delete. Delete those directly — they are armed, so they still cascade, just unordered.
  n="$(our_applications | grep -c . || true)"; n="${n:-0}"
  err "${n} Application(s) still present after ${CASCADE_TIMEOUT}s — deleting them directly"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    oc delete applications.argoproj.io "$app" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "   • direct cascade-delete requested for application/${app}"
  done < <(our_applications)
  wait_for_cascade "straggler sweep" "$sweep_budget" && return 0

  # (e) Still stuck. Do NOT force the finalizer off — that would silently orphan everything the app
  #     still manages, which is the failure mode this whole change removes. Report and continue: the
  #     imperative mutations below (OAuth IdP, node taint, htpasswd) must still be reversed, and
  #     ogsr-check-clean.sh will show precisely what Argo left behind.
  err "Argo did not finish pruning. Continuing with the rest of the uninstall, but expect leftovers:"
  our_applications | sed 's/^/      ✗ application\//' >&2
  err "   inspect: oc describe application <name> -n ${ARGO_NS}"
  err "   then run: ./bootstrap/ogsr-check-clean.sh"
  return 0
}

# ── delete helpers (all dry-run aware, all tolerant of already-absent objects) ─
del_obj() {  # kind name [ns] — delete one object if it exists; print a skip reason if absent
  local kind="$1" name="$2" ns="${3:-}" loc
  loc="${kind}/${name}"; [[ -n "$ns" ]] && loc="${loc} -n ${ns}"
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
}

del_labeled_cluster() {  # kind — delete owner-labeled objects of a CLUSTER-SCOPED kind (skips if CRD absent)
  local kind="$1" name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    del_obj "$kind" "$name"
  done < <(oc get "$kind" -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' || true)
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

preserve_and_strip() {  # ns reason — F2/F7: keep the namespace, strip our owner label so `-l owner=ogsr` is clean
  local ns="$1" reason="$2" key="${OWNER_LABEL%%=*}"
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD preserve namespace/${ns} + strip ${key} label (${reason})"; return 0; fi
  oc label namespace "$ns" "${key}-" --overwrite >/dev/null 2>&1 || true
  echo "   • preserved namespace/${ns}, stripped owner label (${reason})"
}

del_ns_fast() {  # ns — delete a namespace classify already confirmed exists (skips del_obj's redundant get,
  local ns="$1"  # which halves step-9 round-trips on an 8-user cohort's ~100 per-user namespaces)
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD delete namespace/${ns}"; return 0; fi
  oc delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ok "deleted namespace/${ns}"
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
}

handle_gitops() {  # remove the GitOps operator ONLY if we created it; otherwise preserve (+ note the memory bump)
  local preexisted csv b64 prior_res prior_mem target_mem
  preexisted="$(state gitops_preexisted)"
  if [[ "$preexisted" == "false" ]]; then
    info "GitOps was installed by us — removing operator + default instance"
    del_obj argocd openshift-gitops openshift-gitops
    csv="$(oc get subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    del_obj subscriptions.operators.coreos.com openshift-gitops-operator openshift-gitops-operator
    [[ -n "$csv" ]] && del_obj clusterserviceversion "$csv" openshift-gitops-operator
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
      [[ -n "$target_mem" && "$target_mem" != "null" ]] || target_mem="6Gi"
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
}

cleanup_created_operators() {  # remove Subscription+CSV for operators WE created (covers shared-ns operators)
  local name ns st csv
  while read -r name ns st; do
    [[ -n "$name" ]] || continue
    if [[ "$st" == "created" ]]; then
      csv="$(oc get subscriptions.operators.coreos.com "$name" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
      del_obj subscriptions.operators.coreos.com "$name" "$ns"
      [[ -n "$csv" ]] && del_obj clusterserviceversion "$csv" "$ns"
    else
      echo "   • preserve operator ${name} in ${ns} (${st} — not created by us)"
    fi
  done < <(enumerate_operators)
}

# F2/F7 — classify EVERY owner-labeled namespace exactly as the teardown will act on it, so the plan
# and the action can never disagree (each row is "<verb>\t<ns>\t<reason>"). Delete allowlist = the
# INSTALLED stacks' namespaces + the workshop's own per-user/shared namespaces. Anything else that is
# owner-labeled is PRESERVED and de-labeled: an adopted operator's namespace (deleting it would take
# the org's operator down with it), or a namespace of a stack no longer installed (openshift-mta).
classify_workshop_namespaces() {
  local created_op_ns=" " adopted_op_ns=" " stack_ns name ns st n user layer shared
  while read -r name ns st; do
    [[ -n "$ns" ]] || continue
    if [[ "$st" == "created" ]]; then created_op_ns="${created_op_ns}${ns} "; else adopted_op_ns="${adopted_op_ns}${ns} "; fi
  done < <(enumerate_operators)
  stack_ns=" $(enumerate_installed_stack_ns | tr '\n' ' ') "
  while IFS=$'\t' read -r n user layer shared; do
    [[ -n "$n" ]] || continue
    [[ "$n" == "$STATE_NS" ]]            && { printf 'defer\t%s\tuninstall-state namespace (removed last)\n' "$n"; continue; }
    [[ "$n" == "openshift-lightspeed" ]] && { printf 'defer\t%s\tLightspeed (its own adoption guard)\n' "$n"; continue; }
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
}

report_stuck_namespaces() {  # names… — bounded wait for termination, then report any still stuck (>~2min)
  local targets=("$@") waited=0 max=150 ns remaining present
  [[ ${#targets[@]} -gt 0 && "$DRY_RUN" != "true" ]] || return 0
  while (( waited < max )); do
    # ONE list per poll (not one get per target — the delete set can be ~100 namespaces).
    present=" $(oc get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true) "
    remaining=()
    for ns in "${targets[@]}"; do case "$present" in *" $ns "*) remaining+=("$ns");; esac; done
    [[ ${#remaining[@]} -eq 0 ]] && { ok "all deleted workshop namespaces finished terminating"; return 0; }
    sleep 10; waited=$((waited + 10))
  done
  err "still Terminating after ${max}s — a preserved operator's CR finalizer is holding these namespaces:"
  for ns in "${remaining[@]}"; do
    echo "   ✗ namespace/${ns} — finalizer-holding objects (clear ONLY if you understand the operator's cleanup):"
    report_ns_finalizer_holders "$ns"
  done
}

# ── plan ──────────────────────────────────────────────────────────────────────
print_plan() {
  local apps roots created adopted name ns st gitops_plan mon_plan gw_plan
  local verb wn reason nwipe=0 wipe_stack="" strip_list=""
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
  while read -r name ns st; do
    [[ -n "$name" ]] || continue
    if [[ "$st" == "created" ]]; then created="${created} ${name}"; else adopted="${adopted} ${name}(${st})"; fi
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
  echo "  • ${nwipe} owner-labeled namespaces (per-user {user}-*, shared ogsr-*, installed-stack:${wipe_stack:- <none>} )"
  echo "    — most are pruned by the cascade; step 9 deletes any Argo did not manage, and waits."
  echo "  • the argo controller ClusterRoleBinding + ClusterRoles (applied imperatively by argocd-bootstrap)"
  echo "  • imperative bootstrap objects: htpasswd-workshop-users, workshop-users OAuth IdP entry, node labels/taint"
  echo "  • console plugins WE added to consoles.operator.openshift.io (backlog #24): $(state console_plugins_added '<none recorded>')"
  echo "  • operators WE created:${created:-<none recorded>}"
  echo
  echo "WILL PRESERVE (untouched):"
  echo "  • operators the org already had:${adopted:-<none recorded>}"
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
  [[ "$PROT_BAD" -gt 0 ]] && echo "      ⚠️  ${PROT_BAD} adopted resource(s) are NOT protected — details below."
  echo
}

# ── main ──────────────────────────────────────────────────────────────────────
echo "▶ ogsr-uninstall  (cluster: $(oc whoami --show-server 2>/dev/null || echo '?') as $(oc whoami 2>/dev/null || echo '?'))"
[[ "$DRY_RUN" == "true" ]] && echo "  MODE: --dry-run (no changes will be made)"
echo

# Verify BEFORE the plan is printed and before anyone is asked to confirm: the plan's PROTECTED section
# is this check's output, and refusing after a "yes" would be asking for consent to something we then
# decline to do. The check itself is read-only, so running it in dry-run costs nothing.
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

# 1. Stop reconciliation on ALL our apps first, so no app-of-apps re-creates a child mid-teardown.
info "[1/8] stopping reconciliation on workshop Argo Applications"
while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD disable automated sync on application/${app}"; continue; fi
  oc patch application "$app" -n "$ARGO_NS" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
done < <(our_applications)

# 2. CASCADE-delete our apps: deleting the Application IS the uninstall. Argo removes what it installed,
#    in reverse sync-wave order, so each operator is still running when its own operand CR is deleted and
#    that CR's finalizer can complete — which is also how the operator's webhooks and APIServices get
#    removed at the source instead of being swept up afterwards. The previous --cascade=orphan protected
#    adopted operators by exempting EVERYTHING, which threw away Argo's ordering and forced the
#    incomplete bash re-implementation below it; adopted resources are now exempted individually.
info "[2/8] cascade-deleting workshop Argo Applications (Argo prunes what it installed)"
cascade_delete_applications

# 3. CSVs for operators WE created. The cascade already pruned their Subscriptions (those ARE in our
#    component manifests), but a CSV is created by OLM from the Subscription, never by Argo, so nothing
#    prunes it — deleting a Subscription deliberately leaves its CSV and the running operator behind.
#    This is the one operator-removal step GitOps cannot do for us. The Subscription delete stays as a
#    no-op safety net for a degraded Argo (del_obj prints "skip (absent)" when the cascade got it).
info "[3/8] removing CSVs for operators we created (adopted operators preserved)"
cleanup_created_operators

# 4. Reverse the imperative, cluster-global mutations.
info "[4/8] reversing imperative cluster mutations (OAuth IdP, console plugins, monitoring, nodes, htpasswd)"
remove_oauth_idp
remove_console_plugins
del_obj secret htpasswd-workshop-users openshift-config
handle_lightspeed
restore_monitoring
reverse_node_shaping

# 5. GatewayClass — remove only if we created it. Argo manages this CR (it is
#    platform-portfolio/components/gateway-api/gatewayclass.yaml), so a GatewayClass WE created is
#    already gone with the cascade and del_obj skips it. Kept for the adopted case, which is the branch
#    that matters: it must NOT be deleted, and step 0's guard has already verified Argo will skip it.
info "[5/8] Gateway API"
if [[ "$(state gatewayclass_preexisted)" == "false" ]]; then
  del_obj gatewayclass.gateway.networking.k8s.io openshift-default
else
  echo "   • preserve GatewayClass/openshift-default (adopted / pre-existing)"
fi

# 6. Cluster-scoped objects the cascade CANNOT reach, because Argo never managed them.
#    Everything else that used to be swept here is now pruned by step 2 and has been removed from this
#    step: Group/workshop-attendees, the Kueue ResourceFlavor/WorkloadPriorityClass/ClusterQueue triple
#    (all gitops/workshop-config/templates/kueue-queues.yaml), AppProjects
#    (student-appprojects.yaml + appproject-workshop-entries.yaml) and the openshift/java-21 ImageStream
#    (java-21-imagestream.yaml) — every one of them is rendered by the workshop-config Application, so
#    cascade-deleting it removes them in the same pass, with dependency ordering bash never had.
#    What remains here has a genuinely imperative source: platform-portfolio/argocd-bootstrap/install.sh
#    applies controller-rbac.yaml (the openshift-gitops-application-controller-cluster-admin binding)
#    with `oc apply`, outside any Application. The ClusterRole half is swept alongside it because RBAC is
#    the one leftover class that grants standing access after a teardown.
info "[6/8] deleting owner-labeled cluster RBAC that no Application manages"
del_labeled_cluster clusterrolebindings.rbac.authorization.k8s.io
del_labeled_cluster clusterroles.rbac.authorization.k8s.io

# 8. GitOps operator — remove only if we created it (else preserve + note the controller-memory bump).
info "[7/8] GitOps operator"
handle_gitops

# 8. Whatever namespaces the cascade did not own (created outside an Application), then the state
#    namespace last. Most workshop namespaces are gone by now — step 2 pruned them — so this is
#    normally a short list of skips. F6 waits (bounded, early-exit) and reports any namespace still
#    wedged on a preserved operator's CR finalizer, with the exact manual clear command.
info "[8/8] deleting workshop namespaces (org / adopted-operator namespaces preserved + de-labeled)"
delete_workshop_namespaces
# The state ConfigMap is about to go with its namespace, so dump it first: ogsr-check-clean.sh needs it
# to tell an adopted operator from one we created, and a second run of this script has no other source.
STATE_DUMP="${TMPDIR:-/tmp}/ogsr-uninstall-state.txt"
if [[ "$DRY_RUN" != "true" && -n "$STATE_SNAPSHOT" ]]; then
  printf '%s\n' "$STATE_SNAPSHOT" > "$STATE_DUMP" 2>/dev/null && ok "install state saved to ${STATE_DUMP}"
fi
del_obj namespace "$STATE_NS"; DELETED_WS_NS+=("$STATE_NS")   # always ≥1 element, so the expansion below is safe
report_stuck_namespaces "${DELETED_WS_NS[@]}"

echo
ok "ogsr-uninstall complete$([[ "$DRY_RUN" == "true" ]] && echo ' (dry-run — nothing changed)')"
echo
echo "   NEXT — check what outlived the teardown (read-only, deletes nothing):"
if [[ -r "$STATE_DUMP" ]]; then
  echo "     ./bootstrap/ogsr-check-clean.sh --state-file ${STATE_DUMP}"
else
  echo "     ./bootstrap/ogsr-check-clean.sh"
fi
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
