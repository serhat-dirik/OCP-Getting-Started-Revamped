#!/usr/bin/env bash
# ogsr-uninstall.sh — non-destructive, full-removal uninstall for the OCP-Getting-Started workshop.
#
# STATUS (2026-08-01): this is NOT the normal way to end a delivery or hand a cluster over between
# cohorts. Two other scripts own that job now — reach for one of them first:
#   bootstrap/ogsr-reset.sh       — keeps every user; deletes all lab/attendee content and returns
#                                    the cluster to its immediately-post-install state. Run this
#                                    between cohorts on a cluster you are keeping.
#   bootstrap/ogsr-wipe-users.sh  — removes user2..userN entirely (namespaces, Keycloak identities,
#                                    Gitea repos), keeping user1 as a working sample login. Run this
#                                    when handing the cluster to someone else but leaving the
#                                    platform installed.
#
# THIS script is for what those two deliberately do not do: remove the workshop from the cluster
# ENTIRELY — the platform, Gitea (with every attendee repository), Keycloak (with every login), and
# every cockpit — so the cluster goes back to its owner exactly as it was before install.sh touched
# it. That is the "I borrowed someone else's cluster and must return it untouched" case: a
# customer's cluster, a colleague's, a shared pool that is not yours to keep running. If the cluster
# is yours and you are just turning it over for the next cohort, use reset or wipe-users above
# instead — full removal throws away the platform stand-up time for no reason in that case.
#
# Because reset/wipe-users now cover the routine turnover, this script runs far less often than it
# used to. That has not made it less correct — the guarantees below, and the guards enforcing them,
# are unchanged — but it does mean this path is proven by its guards rather than by weekly use.
# Read the guarantees below before trusting a run against a cluster you cannot easily fix by hand.
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
#   3b. Guarantee 2 only covers operands ARGO created. An operator also creates operands of its OWN
#      accord (the Pipelines operator creates TektonConfig; the Subscription manifest says so in its
#      own comment), and those carry no Argo tracking-id, so no cascade can ever prune them. Left
#      alone they OUTLIVE their operator: measured 2026-07-31, after a full uninstall the Pipelines
#      CSV and Subscription were gone while TektonConfig was still alive with 18 pods and a bound 1Gi
#      PVC, every pod reading 1/1, nothing managing it and nothing that would ever remove it. Step 2
#      below deletes them FIRST — after step 1 has stopped reconciliation (so nothing re-creates them)
#      and before the cascade, which is the last moment their operator is still running to process
#      their finalizers. Same ordering argument as guarantee 2, applied to the operands Argo never saw.
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
# Usage (rare case — see STATUS above; ogsr-reset.sh / ogsr-wipe-users.sh have their own --help):
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
# " user1 user2 … " — the exact attendee usernames THIS install created, captured before either of its
# two sources can go. See capture_attendee_users() for why there are two, and step 4's own header for
# why a Dev Spaces auto-provisioned namespace can be identified as ours ONLY by intersecting with this.
ATTENDEE_USERS=""

ok()   { echo "✅ $*"; }
err()  { echo "❌ $*" >&2; }
warn() { echo "⚠️  $*" >&2; }   # CALLED by del_appprojects but never defined — same class of bug
info() { echo "▶ $*"; }         # install.sh's own header already fixed once (undefined command under
die()  { err "$*"; exit 1; }    # `set -u` normally aborts; sub()'s `"$@" || rc=$?` masked it here)

# 89 = the last line of the header block above (the TODO(verify-on-cluster) note). Re-count it whenever
# that block grows, or --help silently truncates mid-sentence.
usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,89p'; exit 1; }

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
STEP_TOTAL=10
STEP_LEDGER=""        # "<status>|<label>" per step, in run order — the EXIT summary reads only this
STEP_FAILED=0
STEP_SUB_FAILED=0     # non-zero returns from sub-actions inside the step currently running
STEPS_STARTED="false"
STATE_DUMP=""         # set in step 10; the EXIT summary references it, so it must always be defined
# The residue ledger. Declared HERE, with the other EXIT-summary globals rather than beside
# residue_record() 100 lines down, because print_run_summary() reads them and `set -u` makes an
# unset variable fatal — the summary must survive an early death at any point after the trap is set.
RESIDUE_KEYS=""       # "<state-key>\n"… — see § the residue ledger
RESIDUE_NOTES=""      # "<key>: <reason>\n"…
# The other thing this teardown deliberately declines to do, declared here for the same reason: built in
# step 10 by classify_shared_crds(), read by print_run_summary() from the EXIT trap, and `set -u` makes
# an unset variable fatal there. "<crd>|<why>|<detail>" per line — see § the shared-CRD guard.
CRDS_SHARED=""

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
  elif [[ "$DRY_RUN" == "true" && -n "$RESIDUE_KEYS" ]]; then
    # Qualify the HEADLINE, not just the detail block below it (owner decision 2026-07-31). An SA who
    # reads one line reads this one, and "complete" next to a namespace we deliberately kept is how a
    # deliberate receipt gets mistaken for a failed teardown — or worse, gets deleted by hand along
    # with the only record of the org's original values.
    warn "ogsr-uninstall dry-run complete — all ${STEP_TOTAL} steps evaluated, nothing changed"
    warn "   …but this plan ends with ${STATE_NS} KEPT ON PURPOSE — see below."
  elif [[ "$DRY_RUN" == "true" ]]; then
    ok "ogsr-uninstall dry-run complete — all ${STEP_TOTAL} steps evaluated, nothing changed"
  elif [[ -n "$RESIDUE_KEYS" ]]; then
    warn "ogsr-uninstall complete — all ${STEP_TOTAL} steps ran, but this cluster is NOT trace-free."
    warn "   ${STATE_NS} was KEPT ON PURPOSE. It is not leftover junk and it is not a failure:"
    warn "   it holds the org's own prior values for the change(s) below, and it is the only copy."
  else
    ok "ogsr-uninstall complete — all ${STEP_TOTAL} steps ran"
  fi
  # "All steps ran" is not "no trace left". A step can complete having deliberately declined to write
  # to a CR it cannot prove it changed, and that decision leaves the workshop's value on the org's
  # cluster — the verdict has to say so or it is the same false success the state ConfigMap's lifetime
  # bug produced. Printed for dry-runs too: there the ledger is the PLAN, and a plan that ends in
  # residue is exactly what an operator wants to see before saying yes.
  if [[ -n "$RESIDUE_KEYS" ]]; then
    echo
    err "NOT trace-free: $(printf '%s' "$RESIDUE_KEYS" | grep -c . || true) prior value(s) were not put back."
    err "   ${STATE_NS} is KEPT holding them (${STATE_CM}); it is the only record of the org's originals."
    printf '%s\n' "$RESIDUE_NOTES" | while IFS= read -r _line; do
      [[ -n "$_line" ]] || continue
      echo "      ↳ ${_line}"
    done
    echo "   Apply those restores, then: oc delete namespace ${STATE_NS}"
  fi
  # Same honesty rule, for the other thing this teardown deliberately does not do. A CRD left registered
  # on purpose has to appear in the verdict an SA actually reads, not only in the step output 200 lines
  # up — otherwise "complete" reads as "the CRD registry is back the way it was", which it is not.
  if [[ -n "$CRDS_SHARED" ]]; then
    echo
    warn "$(printf '%s' "$CRDS_SHARED" | grep -c . || true) CRD(s) are SHARED with the organisation and were left registered on purpose."
    warn "   They are named above with their reason. They are withheld from crds_created, so"
    warn "   ogsr-check-clean.sh will not offer to delete them — deleting one takes the org's instances too."
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
STATE_SNAPSHOT=""    # whole state CM cached as key=value lines — it is immutable until step 10 deletes it,
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

# ── the residue ledger ────────────────────────────────────────────────────────
# THE RECORD OF WHAT TO UNDO USED TO LIVE INSIDE THE THING BEING UNDONE. Step 10 deletes ${STATE_NS},
# and with it the ConfigMap that is the ONLY record of what the org's cluster looked like before this
# workshop touched it. That is correct exactly when this teardown put everything back — and a lie
# every other time: whatever we could NOT restore stays on the cluster as OUR value, and the next
# install's first-write-wins snapshot records it as "the org's original". Measured 2026-07-31 on a
# live cluster whose adopted Argo CD controller sits at our 6Gi with the true prior (2Gi) recorded
# and no consent key to authorise putting it back — one more install/teardown cycle and 6Gi becomes
# the recorded baseline, permanently, with the teardown reporting "complete".
#
# So the state is deleted only when this teardown has nothing left to confess. Every restore path
# that walks away leaving OUR value on an object we do not own calls residue_record; step 10 then
# PRUNES the ConfigMap down to exactly those keys and KEEPS ${STATE_NS} as the receipt. What remains
# is one namespace holding one ConfigMap of true prior values — and it remains only on a cluster that
# already carries a change of ours, so it documents an existing trace rather than adding a new one.
# It is self-clearing: restore the values by hand (the commands are printed) and delete the namespace,
# or let the next install carry them forward — record_once is first-write-wins, so a carried prior is
# never overwritten by the value we ourselves left behind.
# RESIDUE_KEYS / RESIDUE_NOTES are declared with the EXIT-summary globals at the top of the file.
residue_record() {  # <state-key> <reason> — this teardown left OUR value on an object we do not own
  local k="$1" reason="$2"
  case $'\n'"${RESIDUE_KEYS}" in
    *$'\n'"${k}"$'\n'*) ;;
    *) RESIDUE_KEYS="${RESIDUE_KEYS}${k}"$'\n' ;;
  esac
  RESIDUE_NOTES="${RESIDUE_NOTES}${k}: ${reason}"$'\n'
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
# Measured on a live cluster 2026-07-25: that exact orphan drove pp-devspaces Degraded with `CheCluster/devspaces
# Missing` and took M03 out of the workshop; deleting the CSV by hand let OLM resolve immediately.
#
# Step 5 used to name the CSV by reading `.status.installedCSV` off the Subscription. That was correct
# only while teardown deleted Subscriptions itself. Since teardown became a cascade, step 3 removes the
# Subscription (it IS an Argo-managed resource) long before step 5 runs, so the lookup returned "" for
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
# label KEY is capped at 63 characters and OLM silently TRUNCATES rather than skipping — live on a cluster,
# cluster-observability-operator in openshift-cluster-observability-operator (71 chars) is stamped
# `operators.coreos.com/cluster-observability-operator.openshift-cluster-observability` (exactly 63),
# so a selector built from the real names matches nothing at all. It survives only as a last-resort
# probe (full key, then its 63-char truncation) for a CSV that carries no properties annotation.
CSV_INDEX=""
CSV_INDEX_LOADED="false"
csv_index() {  # → "<ns>|<csv>|<copiedFrom>|<properties-json>" for every ORIGINAL CSV (cached, one call)
  if [[ "$CSV_INDEX_LOADED" != "true" ]]; then
    # `!olm.copiedFrom` drops OLM's per-namespace COPIES server-side. Not a micro-optimisation:
    # measured live, unfiltered is 3743 objects / 3.8 MB / 92s, filtered is 37 objects / 36 KB / 4s.
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
  # trims whatever the cut left dangling. Live on a cluster: cut(63) of
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
  local name ns st pkg csv n=0 total=0 c=0
  if [[ "$CSV_SNAPSHOT_TAKEN" == "true" ]]; then return 0; fi
  CSV_SNAPSHOT_TAKEN="true"
  # ONE cluster-wide read, not one per operator: an `oc get` against a remote cluster costs ~3s
  # (measured live), so 22 operators would be a minute of wall clock for data a single list
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
    # The owned-CRD capture, in the only moment it can be complete — see § the owned-CRD capture.
    # Gated on the SAME predicate that authorises a CSV deletion, so an adopted operator's CRDs are
    # never filed as ours; a `decide` line in the checker is recoverable, `oc delete crd` is not.
    if csv_delete_authorized_by_state "$name" "$ns"; then
      record_created_crds "$csv" "$ns"
      c=$((c + 1))
    fi
  done < <(enumerate_operators)
  # Set even when c is 0 (nothing on this cluster is recorded as created by us): the flag records that
  # the pass RAN before the cascade, which is what makes an empty list trustworthy rather than unknown.
  CRDS_CAPTURE_PHASE="pre-cascade"
  if [[ "$total" -eq 0 ]]; then return 0; fi
  ok "resolved a CSV for ${n} of ${total} recorded operators, before anything can delete a Subscription"
  if [[ "$n" -lt "$total" ]]; then
    echo "   • the other $((total - n)) have neither a Subscription nor a CSV on this cluster — either the"
    echo "     component was never installed, or an earlier uninstall already removed both"
  fi
  ok "recorded $(printf '%s' "${CRDS_CREATED_SET}" | wc -w | tr -d ' ') CRD(s) owned by the ${c} operator(s) this install created, pre-cascade"
  return 0
}

# ── attendee identity, captured before anything can remove either source of it ────────────────────
# Dev Spaces auto-provisions ONE namespace per attendee the first time they open a workspace
# (devEnvironments.defaultNamespace {autoProvision: true, template: "<username>-devspaces"}). It carries
# NONE of our labels — the only mark on it is che.eclipse.org/username, which is stamped on EVERY
# namespace Dev Spaces auto-provisions, including the org's own users on a cluster whose Dev Spaces we
# ADOPTED. So the annotation alone is not proof of ownership; step 4 below needs to intersect it against
# the exact usernames THIS install created, and that list has to be read before either place it lives
# on the cluster is gone.
ATTENDEE_USERS_CAPTURED="false"
capture_attendee_users() {  # main calls this ONCE, before step 1 — same reasoning as capture_installed_csvs()
  # TWO independent sources, unioned, because their failure modes do not overlap and either can be gone
  # by the time step 4 needs to classify a Dev Spaces namespace:
  #   Group/workshop-attendees — rendered by the workshop-config Application (gitops/workshop-config/
  #     templates/group-workshop-attendees.yaml: one user1..userN entry per Values.userCount). Step 3's
  #     cascade deletes it along with everything else that Application manages, so it must be read
  #     before step 3 runs, not after.
  #   secret/htpasswd-workshop-users -n openshift-config — created directly by install.sh with `oc
  #     create secret` (never through Argo), so the cascade cannot touch it; step 6 below deletes it
  #     explicitly. Its `htpasswd` key is the apache-htpasswd file install.sh wrote, one
  #     `username:hash` line per attendee — the same identities the Group is rendered from, kept as a
  #     second source in case the Group was never healthy (workshop-config degraded at install time).
  # A re-run that finds BOTH already gone (e.g. an earlier, interrupted run already removed them) has
  # nothing to intersect against and step 4 skips, exactly like every other "no state" branch in this
  # script — it does not fall back to guessing from the namespace name.
  if [[ "$ATTENDEE_USERS_CAPTURED" == "true" ]]; then return 0; fi
  ATTENDEE_USERS_CAPTURED="true"
  local from_group from_htpasswd="" b64
  # NOT `{range .users[*]}{.}{end}` — verified live (2026-07-31): oc's jsonpath does not resolve
  # a bare `{.}` as the current item over a plain string array, so that form silently prints NOTHING,
  # which would have made ATTENDEE_USERS always empty and disabled this whole guard without an error.
  # `{.users[*]}` prints the array space-separated directly; verified to actually return the 8 usernames.
  from_group="$(oc get group workshop-attendees -o jsonpath='{.users[*]}' 2>/dev/null | tr ' ' '\n' || true)"
  b64="$(oc get secret htpasswd-workshop-users -n openshift-config -o jsonpath='{.data.htpasswd}' 2>/dev/null || true)"
  if [[ -n "$b64" ]]; then
    from_htpasswd="$(printf '%s' "$b64" | base64 -d 2>/dev/null | cut -d: -f1)"
  fi
  ATTENDEE_USERS=" $(printf '%s\n%s\n' "$from_group" "$from_htpasswd" | grep . | sort -u | tr '\n' ' ' || true)"
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
  # MEMOISED, and not only to save round-trips. The plan (pre-cascade) and step 5 (post-cascade) both
  # resolve the same operator, and one of the mechanisms — reading a live Subscription — gives a
  # different answer either side of the cascade. Without the memo a plan line could promise a CSV that
  # step 5 then fails to name; with it, the answer is fixed at the first, pre-cascade, resolution.
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
  # Read BEFORE the delete, from the object we are about to remove — its .spec is still there to read
  # either side of that call, but reading first means a failed/absent delete (DRY_RUN, or the object
  # already gone under us) never leaves this half-run.
  record_created_crds "$csv" "$ns"
  del_obj clusterserviceversions.operators.coreos.com "$csv" "$ns"
  return 0
}

# ── the owned-CRD capture, and why it happens BEFORE the cascade ──────────────
# `crds_created` is what lets ogsr-check-clean.sh's section [9/9] run in its "exact" mode — the list of
# CRDs that came onto this cluster because WE installed an operator, read from each CSV's own
# .spec.customresourcedefinitions.owned instead of guessed from name tokens.
#
# IT USED TO BE CAPTURED IN THE WRONG PLACE. The only call site was del_created_csv, which runs in the
# CSV-cleanup step — AFTER the cascade. But the cascade deletes Subscriptions AND, transitively, most
# of the CSVs: measured on a live teardown 2026-07-31, 15 of 19 CSVs were already gone by the time the
# capture ran, so it recorded 17 CRDs while 165 were actually still registered. Section [9/9] then
# reported those 17 as the complete list, in its HIGHEST-confidence mode, and called the cluster clean.
# A capture that runs after the thing it is capturing has been deleted does not measure a small number;
# it measures nothing, and dresses the nothing up as certainty.
#
# So the capture now runs in the SAME pre-cascade moment as capture_installed_csvs(), off the same
# resolved (csv, namespace) pairs, gated by the SAME authorization predicate del_created_csv uses
# (csv_delete_authorized_by_state): an ADOPTED operator's CRDs are the org's and are never recorded as
# ours. del_created_csv still calls it, for an operator the pre-pass could not resolve; the memo below
# makes that a no-op in the ordinary case.
#
# CRDS_CAPTURE_PHASE is the honesty half. Anything downstream that wants to treat this list as complete
# has to prove it was taken before the cascade, and a state dump written by an older uninstall carries
# no such proof — see ogsr-check-clean.sh section [9/9], which refuses "exact" without it rather than
# reporting a truncated list as the whole truth.
CRDS_CREATED_SET=" "     # space-padded " crd1 crd2 " — same de-dup idiom as ATTENDEE_USERS/PROTECTED_CSVS
CRDS_CAPTURED_CSVS=" "   # " ns/csv … " already read, so two callers cost one round trip
CRDS_CAPTURE_PHASE=""    # "pre-cascade" once capture_installed_csvs() has run its authorized pass

# ONE cluster-wide read for every CSV's owned-CRD list, in the same shape and for the same reason as
# csv_index(): 19 operators would otherwise be 19 serial `oc get`s (~3s each, measured live) added
# to the pre-cascade moment, which --dry-run pays for too. Nested `range` is a documented jsonpath form
# (the same one kubectl's own docs use for containers within pods), and if it ever fails the index
# simply comes back empty and record_created_crds falls through to the per-CSV read it has always used
# — slower, never silent.
CRD_OWNED_INDEX=""
CRD_OWNED_INDEX_LOADED="false"
crd_owned_index() {  # → "<ns>|<csv>|<crd> <crd> …" per ORIGINAL CSV (cached, one call)
  if [[ "$CRD_OWNED_INDEX_LOADED" != "true" ]]; then
    CRD_OWNED_INDEX="$(oc get clusterserviceversions.operators.coreos.com -A -l '!olm.copiedFrom' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{range .spec.customresourcedefinitions.owned[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null || true)"
    CRD_OWNED_INDEX_LOADED="true"
  fi
  printf '%s\n' "$CRD_OWNED_INDEX"
  return 0
}

record_created_crds() {  # csv ns — remember every CRD that CSV's spec says it owns, skipping dupes
  local csv="$1" ns="$2" crd owned
  [[ -n "$csv" && -n "$ns" ]] || return 0
  case "$CRDS_CAPTURED_CSVS" in *" ${ns}/${csv} "*) return 0;; esac
  CRDS_CAPTURED_CSVS="${CRDS_CAPTURED_CSVS}${ns}/${csv} "
  # Field-exact match on the first two columns, never a substring grep: one CSV name can be a suffix
  # of another in the same namespace, and a substring hit would attribute its CRDs to the wrong one.
  owned="$(crd_owned_index | awk -F'|' -v n="$ns" -v c="$csv" '$1==n && $2==c {print $3; exit}')"
  if [[ -z "$owned" ]]; then
    owned="$(oc get clusterserviceversions.operators.coreos.com "$csv" -n "$ns" \
               -o jsonpath='{range .spec.customresourcedefinitions.owned[*]}{.name}{" "}{end}' 2>/dev/null || true)"
  fi
  # Word splitting is the point here — the field is a space-separated CRD list — and a CRD name is
  # DNS-subdomain-shaped, so it can carry no glob character.
  for crd in $owned; do
    case "$CRDS_CREATED_SET" in *" ${crd} "*) continue;; esac
    CRDS_CREATED_SET="${CRDS_CREATED_SET}${crd} "
  done
  return 0
}

# ── the shared-CRD guard: OUR OPERATOR OWNING A CRD DOES NOT MAKE THE CRD OURS ─
# `crds_created` is not a passive record. ogsr-check-clean.sh section [9/9] prints
#   oc delete crd <name>   # this deletes all N instance(s) of it, everywhere
# beside every entry of it, in its highest-confidence "exact" mode — and in that mode it prints the line
# WITHOUT consulting crd_matches_adopted(), because that guard is behind `[ -n "$op" ]` and the exact
# branch never sets an operator name. So this list is a delete authorisation, and it is the most
# destructive one in this toolchain: a CRD is a CLUSTER-SCOPED registration shared by every namespace on
# the cluster, so deleting it deletes every instance of that kind, in every namespace, ours and the
# org's alike, and nothing puts them back.
#
# OLM's "owned" means "this operator reconciles this kind", NOT "this operator brought this kind onto
# the cluster". MEASURED on cluster-65prs 2026-08-06, read-only:
#   keycloaks.k8s.keycloak.org is declared in .spec.customresourcedefinitions.owned by FOUR original
#   CSVs — sso-workshop/rhbk-operator.v26.6.5-opr.1 (ours), openshift-mta/rhbk-operator.v26.6.5-opr.1
#   (OLM resolved it as an MTA dependency), keycloak/rhbk-operator.v26.4.13-opr.1 and .v26.4.14-opr.1
#   (the organisation's own Keycloak). Its live instances are sso-workshop/sso-workshop (ours) and
#   keycloak/keycloak (theirs). The CRD's own labels agree: operators.coreos.com/rhbk-operator.keycloak,
#   .openshift-mta and .sso-workshop, three OLM owners on one cluster-scoped object.
# Our capture files that CRD as ours — correctly, by its own rule: our operator does own it. Handing the
# name to `oc delete crd` would take the org's Keycloak with ours.
#
# THE RULE, and it is deliberately two independent tests joined by OR, because they fail differently:
#   [A] a FOREIGN OWNING CSV — any original CSV outside this install declares the same CRD owned. Proves
#       the CRD belongs to somebody else's operator EVEN WHEN IT CURRENTLY HAS ZERO INSTANCES: their
#       operator is still running and will create instances the moment they use it.
#   [B] a LIVE INSTANCE OUTSIDE THE NAMESPACES THIS TEARDOWN REMOVES — proves live dependence right now,
#       even when we are the only operator that has ever owned the kind (the org can create a Pipeline
#       or a Certificate in their own namespace using an operator we installed).
# Either one withholds the CRD. Nothing here deletes anything, and nothing here suppresses a report:
# a withheld CRD is NAMED, with its reason and with the read-only command to inspect it, and its name is
# written to the state dump under `crds_shared` so it cannot vanish between this run and the checker.
#
# WHY NOT JUST DROP THEM QUIETLY — because a teardown that silently narrows its own report is the
# 2026-07-31 defect wearing a different hat (17 CRDs of 165, presented as the complete answer). The
# withheld set is a category with a name, printed on every run, counted, and repeated in the closing
# summary beside the residue ledger.
#
# WHAT THIS DOES NOT TOUCH: CRDS_CREATED_SET itself, and therefore step 2. That set drives
# cluster_scoped_created_crds(), whose deletes are per-INSTANCE and already guarded object-by-object
# (Prune=false/Delete=false, then Argo tracking). Narrowing it here would silently stop step 2 removing
# our own orphan-prone operands; the authorisation this section filters is the CRD-level one, which is
# the only place a single command can reach the org's data.
CRDS_SHARED_BUILT="false"
CRDS_CLASSIFIED="false"  # completion proof — a HALF-finished classification must never be written out
CRDS_MINE=" "            # space-padded " crd … " that passed BOTH tests: what `crds_created` may carry
CRD_META_INDEX=""
CRD_META_INDEX_LOADED="false"
# 25 CRDs per read, not one read per CRD: 218 candidates on a full install (measured, same cluster) at
# ~1.9s each is seven minutes bolted onto the end of every teardown; at 25 per read it is nine calls.
CRD_SCAN_CHUNK=25
CRD_SCAN_JP='{range .items[*]}{.apiVersion}{"|"}{.kind}{"|"}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}'

crd_meta_index() {  # → "<group>|<kind>|<crd>" for every registered CRD (cached, one call)
  # Exists to attribute an item in a merged multi-type list back to the CRD it came from: `oc get a,b,c`
  # returns ONE list whose items each carry their own apiVersion+kind (verified live 2026-08-06), and
  # group+kind is unique across CRDs — the API server refuses to register two with the same pair.
  if [[ "$CRD_META_INDEX_LOADED" != "true" ]]; then
    CRD_META_INDEX="$(oc get customresourcedefinitions.apiextensions.k8s.io \
      -o jsonpath='{range .items[*]}{.spec.group}{"|"}{.spec.names.kind}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    CRD_META_INDEX_LOADED="true"
  fi
  printf '%s\n' "$CRD_META_INDEX"
  return 0
}

# PREDICATE — its non-zero IS the answer, so no trailing `return 0`. Test [A].
crd_foreign_owners() {  # <crd> → "<ns>/<csv>" per foreign owner; rc 0 when at least one exists
  # ZERO cluster reads: crd_owned_index() is already cached from the pre-cascade moment, which is also
  # the only honest instant to ask this — after the cascade OUR CSV is gone and every surviving owner
  # would look foreign. CRDS_CAPTURED_CSVS is the exact set of CSVs this run read owned-CRDs from, and
  # every call site of record_created_crds sits behind csv_delete_authorized_by_state, so "not in that
  # set" is precisely "not an operator the state records as created by us, in that namespace".
  # An orphaned OLDER CSV of our own operator, left in our own namespace by an upgrade, reads as foreign
  # here. That withholds one CRD we could have offered — the safe direction, and section [3/9] of the
  # checker reports that orphan separately anyway.
  local crd="$1" ns csv owned hit=1
  while IFS='|' read -r ns csv owned; do
    [[ -n "$ns" && -n "$csv" ]] || continue
    case " $owned " in *" ${crd} "*) ;; *) continue;; esac
    case "$CRDS_CAPTURED_CSVS" in *" ${ns}/${csv} "*) continue;; esac
    printf '%s/%s\n' "$ns" "$csv"
    hit=0
  done < <(crd_owned_index)
  return "$hit"
}

removed_namespace_set() {  # → " ns … " — exactly the namespaces THIS run deleted, or would in --dry-run
  # DELETED_WS_NS is the record of issued deletes (delete_workshop_namespaces appends before del_ns_fast
  # decides whether to act, so a --dry-run preview is faithful), plus STATE_NS, which goes at the very
  # end of step 10. Deliberately NOT widened with created_operator_namespaces: that set contains
  # openshift-operators, a namespace three of our operators live in and this teardown never removes —
  # treating it as "ours" would mask exactly the org instance test [B] exists to find.
  local ns out=" "
  if [[ "${#DELETED_WS_NS[@]}" -gt 0 ]]; then
    for ns in "${DELETED_WS_NS[@]}"; do
      case "$out" in *" ${ns} "*) continue;; esac
      out="${out}${ns} "
    done
  fi
  case "$out" in *" ${STATE_NS} "*) ;; *) out="${out}${STATE_NS} ";; esac
  printf '%s' "$out"
  return 0
}

crd_scan_emit() {  # <jsonpath output> → "<crd>|<ns>|<name>" per instance (ns empty ⇒ cluster-scoped)
  # NR==FNR two-stream awk rather than `-v meta=…`: awk processes escapes in a -v value, and the map is
  # multi-line. crd_meta_index runs in a process substitution, i.e. a SUBSHELL, so its cache assignment
  # would be discarded — classify_shared_crds primes it in the parent first and the subshell inherits
  # the loaded value, the same reason capture_installed_csvs primes csv_index before the cascade.
  awk -F'|' '
    NR==FNR { if ($3 != "") M[$1 "|" $2] = $3; next }
    { sub(/\/.*/, "", $1); k = $1 "|" $2; if ($4 != "" && (k in M)) print M[k] "|" $3 "|" $4 }
  ' <(crd_meta_index) <(printf '%s\n' "$1")
  return 0
}

crd_scan_chunk() {  # <crd…> → crd_scan_emit's shape, plus "<crd>|?|-" for a CRD that could not be read
  # A chunk read is ALL-OR-NOTHING: `oc get a,b,c` fails the WHOLE command when any one type is not
  # served — "error: the server doesn't have a resource type", rc 1, no output on stdout (verified live
  # 2026-08-06). Silence from a failed read is indistinguishable from "no instances anywhere", and
  # reading it as the latter is the fail-OPEN that hands back the delete command this guard exists to
  # withhold. So a failed chunk is retried CRD by CRD — one dead APIService must not taint 24 healthy
  # types — and a CRD whose own read fails is marked unreadable and withheld on that basis.
  local joined out rc=0 crd
  joined="$(printf '%s,' "$@")"
  joined="${joined%,}"
  out="$(oc get "$joined" -A -o jsonpath="$CRD_SCAN_JP" 2>/dev/null)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    crd_scan_emit "$out"
    return 0
  fi
  if [[ "$#" -eq 1 ]]; then
    printf '%s|?|-\n' "$1"
    return 0
  fi
  for crd in "$@"; do
    crd_scan_chunk "$crd"
  done
  return 0
}

crd_instance_scan() {  # <crd…> → every instance of every candidate, chunked
  local -a chunk=()
  local crd
  for crd in "$@"; do
    chunk+=("$crd")
    if [[ "${#chunk[@]}" -ge "$CRD_SCAN_CHUNK" ]]; then
      crd_scan_chunk "${chunk[@]}"
      chunk=()
    fi
  done
  if [[ "${#chunk[@]}" -gt 0 ]]; then crd_scan_chunk "${chunk[@]}"; fi
  return 0
}

classify_shared_crds() {  # split CRDS_CREATED_SET into CRDS_MINE (deletable) and CRDS_SHARED (withheld)
  local -a cand=()
  local crd removed scan outside owners n_out n_unread why detail meta
  if [[ "$CRDS_SHARED_BUILT" == "true" ]]; then return 0; fi
  CRDS_SHARED_BUILT="true"
  if [[ "$CRDS_CREATED_SET" == " " ]]; then
    # Nothing was captured, so there is nothing to authorise and nothing to withhold. Classified is
    # still TRUE: an empty split of an empty set is complete, and the snapshot below must not treat it
    # as a half-run.
    CRDS_CLASSIFIED="true"
    return 0
  fi
  # Word splitting is the point — CRDS_CREATED_SET is a space-separated set and a CRD name is
  # DNS-subdomain-shaped, so it carries no glob character.
  for crd in $CRDS_CREATED_SET; do cand+=("$crd"); done
  removed="$(removed_namespace_set)"

  # ── the three inputs, each checked, because EVERY one of them fails OPEN if it comes back empty ────
  # This function runs with `set -e` suppressed for its whole dynamic extent — its only call site is
  # `sub classify_shared_crds`, and sub() runs it as `"$@" || rc=$?`, i.e. a TESTED command. So a failed
  # read does NOT abort anything here; it just yields an empty string and execution walks on. MEASURED
  # against this file's own code 2026-08-06: with the instance scan stubbed to fail, the loop below
  # found no outside instances, withheld nothing, set CRDS_CLASSIFIED=true and printed "no CRD of ours
  # is shared with the organisation — all 4 are safe to offer". A confident all-clear derived from a
  # read that never happened is precisely the failure this section exists to make impossible, so each
  # input is proven non-empty and an unprovable one ends the classification INCOMPLETE instead.
  #
  # crd_owned_index empty ⇒ test [A] is blind: no CSV can be found owning anything, so no CRD ever has a
  # foreign owner. It cannot legitimately be empty here — CRDS_CREATED_SET is non-empty, which means at
  # least one CSV was read — so empty means the read failed.
  # `fn >/dev/null`, never `$(fn)`: a command substitution runs in a SUBSHELL, so the cache these two
  # fill would be discarded and every later caller — crd_foreign_owners once per candidate,
  # crd_scan_emit once per chunk, both from subshells of their own — would re-read the cluster. The
  # redirection form runs in THIS shell, so the globals below are the ones the whole pass then reuses.
  crd_owned_index >/dev/null
  if [[ -z "$CRD_OWNED_INDEX" ]]; then
    err "the CSV owned-CRD index is empty while ${#cand[@]} CRD(s) are recorded as ours — that read failed."
    err "   Without it no CRD can be shown to have an owner outside this install, so every one of them"
    err "   would look exclusively ours. Refusing to classify."
    return 1
  fi
  # crd_meta_index empty ⇒ test [B] is blind: crd_scan_emit maps an instance back to its CRD through
  # this index, so an empty map discards every instance and each CRD reads as instance-free.
  crd_meta_index >/dev/null
  meta="$CRD_META_INDEX"
  if [[ -z "$meta" ]]; then
    err "could not read the CRD registry, so no instance can be attributed back to the CRD it came from."
    err "   Every candidate would read as having no instances anywhere. Refusing to classify."
    return 1
  fi
  scan="$(crd_instance_scan "${cand[@]}")" || {
    err "the instance scan failed outright — nothing can be said about which CRDs still have instances"
    err "   outside the namespaces this teardown removed. Refusing to classify."
    return 1
  }
  # Reduce once, in awk, to "<crd>|<where>". An empty namespace is a CLUSTER-SCOPED instance: it sits in
  # no namespace at all, so no namespace deletion can take it, which makes it outside every namespace
  # this teardown removes by definition. UNREADABLE is kept as its own marker rather than folded in with
  # the instances — "1 live instance(s) outside" printed about a CRD nobody could list is a sentence
  # that is simply not true, and a reason an admin cannot trust is worse than no reason.
  outside="$(printf '%s\n' "$scan" | awk -F'|' -v rm="$removed" '
    $1 == "" { next }
    $2 == "?" { print $1 "|!unreadable"; next }
    $2 == ""  { print $1 "|cluster-scoped/" $3; next }
    index(rm, " " $2 " ") == 0 { print $1 "|" $2 "/" $3 }
  ' || true)"
  for crd in "${cand[@]}"; do
    owners="$(crd_foreign_owners "$crd" | tr '\n' ' ' || true)"
    n_out="$(printf '%s\n' "$outside" | awk -F'|' -v c="$crd" '$1 == c && $2 != "!unreadable"' | grep -c . || true)"
    n_unread="$(printf '%s\n' "$outside" | awk -F'|' -v c="$crd" '$1 == c && $2 == "!unreadable"' | grep -c . || true)"
    why=""
    detail=""
    if [[ -n "$owners" ]]; then
      why="owned by $(printf '%s' "$owners" | wc -w | tr -d ' ') CSV(s) outside this install"
      detail="${owners% }"
    fi
    if [[ "$n_out" -gt 0 ]]; then
      # awk 'NR<=4', never `head -4`: head exits early, awk takes SIGPIPE, and under `pipefail` the
      # substitution returns 141 — the same trap ogsr-check-clean.sh documents twice.
      if [[ -n "$why" ]]; then why="${why}; "; fi
      why="${why}${n_out} live instance(s) outside the namespaces this teardown removes"
      if [[ -n "$detail" ]]; then detail="${detail} + "; fi
      detail="${detail}$(printf '%s\n' "$outside" | awk -F'|' -v c="$crd" '$1 == c && $2 != "!unreadable" {print $2}' | awk 'NR<=4' | tr '\n' ' ' || true)"
    fi
    if [[ "$n_unread" -gt 0 ]]; then
      # Withheld for NOT KNOWING, and it says so. The alternative is to treat an unanswerable read as
      # "no instances anywhere" and hand back the delete command, which is the one outcome this whole
      # section exists to make impossible.
      if [[ -n "$why" ]]; then why="${why}; "; fi
      why="${why}its instances could not be listed, so it cannot be shown to be ours alone"
      if [[ -n "$detail" ]]; then detail="${detail} + "; fi
      detail="${detail}read failed (a dead APIService does this) — check by hand"
    fi
    if [[ -n "$why" ]]; then
      CRDS_SHARED="${CRDS_SHARED}${crd}|${why}|${detail% }"$'\n'
      continue
    fi
    CRDS_MINE="${CRDS_MINE}${crd} "
  done
  # Set LAST and only here: a classification that died partway would otherwise write a silently
  # shortened crds_created, which is the 2026-07-31 defect exactly (a fragment presented as the whole).
  CRDS_CLASSIFIED="true"
  return 0
}

report_shared_crds() {  # the named category — printed every run, in --dry-run too
  local crd why detail n
  if [[ "$CRDS_CLASSIFIED" != "true" ]]; then
    err "the shared-CRD classification did not finish, so this run cannot say which CRDs are safe to offer."
    err "   crds_created is NOT being written: ogsr-check-clean.sh section [9/9] will fall back to its"
    err "   heuristic name-match mode and tell you to verify each CRD by hand. That is the honest answer;"
    err "   a partial list written as if it were complete is not."
    return 0
  fi
  if [[ -z "$CRDS_SHARED" ]]; then
    ok "no CRD of ours is shared with the organisation — all $(printf '%s' "$CRDS_MINE" | wc -w | tr -d ' ') are safe to offer for removal"
    return 0
  fi
  n="$(printf '%s' "$CRDS_SHARED" | grep -c . || true)"
  echo
  echo "   SHARED CRDs — LEFT REGISTERED ON PURPOSE, and NOT offered for deletion (${n}):"
  echo "   A CRD is cluster-scoped. Deleting one of these would delete the organisation's instances of it"
  echo "   too, in namespaces this workshop never touched. They are withheld from crds_created, so"
  echo "   ./bootstrap/ogsr-check-clean.sh will not print an 'oc delete crd' line for them."
  while IFS='|' read -r crd why detail; do
    [[ -n "$crd" ]] || continue
    echo "      ⚠ ${crd} — ${why}"
    if [[ -n "$detail" ]]; then echo "        namely: ${detail}"; fi
    echo "        inspect (read-only): oc get ${crd} -A"
  done <<< "$CRDS_SHARED"
  if [[ "$CRDS_MINE" == " " ]]; then
    err "   EVERY captured CRD was withheld, so crds_created will not be written at all. Section [9/9] of"
    err "   the checker therefore falls back to its heuristic name-match mode — treat any 'oc delete crd'"
    err "   it prints as a suggestion to verify, never as an instruction."
  fi
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
# left every child app on `automated: {prune, selfHeal}` while step 3 orphaned its parent, so the
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
    # here-string, not `printf | grep -qxF` — same SIGPIPE-under-pipefail trap as install.sh's
    # resolve_slug(): $hosts can carry more than one line, and an early match would otherwise risk
    # reading as a non-match, misordering the cascade's mirror-last phase.
    if grep -qxF -- "$rhost" <<< "$hosts"; then echo "$ns"; fi
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

# <state-value> <kind> <name> [ns] → the REASON a preserve decision was taken, told truthfully.
# The preserve branches used to read `if [[ "$(state X)" == "false" ]]; then delete; else "adopted /
# pre-existing"; fi`, which collapses two very different situations into one confident sentence:
# state recorded "true" (install genuinely found it already there) and state recorded NOTHING (no
# ConfigMap at all — we know nothing and preserve because that is the safe default). Measured on a
# never-installed cluster 2026-07-31: the dry run announced "GitOps was adopted (pre-existing) —
# operator + instance preserved", "preserve namespace/openshift-lightspeed (pre-existed…)" and
# "preserve GatewayClass/openshift-default (adopted / pre-existing)" on a cluster where none of those
# three objects exist at all. Nothing was at risk — the safe branch was correctly chosen — but an
# operator reading that output would conclude the cluster has an adopted GitOps to protect.
# The decision does not change; only the sentence does. Absence is checked live, never assumed.
preserve_reason() {
  local st="$1" kind="$2" name="$3" ns="${4:-}"
  if [[ "$st" == "true" ]]; then
    echo "adopted — install recorded it as already present"
  elif obj_exists "$kind" "$name" "$ns"; then
    echo "no state on record — preserving by default; it IS on this cluster"
  else
    echo "no state on record, and it is not on this cluster — nothing here to preserve"
  fi
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
    # Resolve the CSV the way step 5 does, NOT from the Subscription — this guard had the SAME defect.
    # Live on a cluster 2026-07-25: the org's adopted openshift-pipelines-operator-rh and web-terminal have
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

# Release the operands a timed-out phase could not prune, BEFORE the next phase removes their operator.
#
# WHY THIS IS NOT "JUST WAIT LONGER" (measured 2026-07-29, and 2026-07-25 before it). The phase wait is
# bounded, and on expiry cascade_phase used to log "moving to the next phase anyway" and proceed. That
# turns a RECOVERABLE stall into a PERMANENT one: phase 1 leaves workshop-config holding ClusterQueues
# on kueue.x-k8s.io/resource-in-use, phase 2 then deletes the Kueue operator, and from that moment the
# finalizer has no controller and can never clear — by any amount of waiting, ever. On 2026-07-29 three
# Applications sat wedged 3.5 hours with 0 kueue pods and 0 kueue CSV; cq-user2/cq-user3 still carried
# the finalizer with deletionTimestamp NONE.
#
# So the ordered phases were real but the block was ADVISORY, and advisory ordering fails exactly when
# it matters. Clearing a stuck operand's finalizer while its operator is still alive is strictly better
# than stranding it after the operator is gone: same objects orphaned either way, but the cluster is
# left removable instead of requiring hand surgery. Deliberately touches ONLY the Application's managed
# objects, never the Application's own finalizer — that is the advice diagnose_stuck_app already gives.
release_operand_blockers() {  # <label> <member-set> — clear finalizers on what this phase left behind
  local label="$1" members="$2" app group kind ns name res fins cleared=0
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    # Same membership test apps_remaining_in uses — the member set is a space-delimited string, so the
    # app must be matched with its surrounding spaces or `pp-git` would match `pp-gitea`.
    case "$members" in *" $app "*) ;; *) continue;; esac
    while IFS='|' read -r group kind ns name; do
      [[ -n "$kind" && -n "$name" ]] || continue
      res="$kind"; [[ -n "$group" ]] && res="${kind}.${group}"
      if [[ -n "$ns" ]]; then
        fins="$(oc get "$res" "$name" -n "$ns" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
      else
        fins="$(oc get "$res" "$name" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
      fi
      [[ -n "$fins" && "$fins" != "[]" ]] || continue
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "   • WOULD clear finalizers on ${res}/${name}${ns:+ -n $ns} (holds ${fins}) so ${label} can complete"
        continue
      fi
      if [[ -n "$ns" ]]; then
        oc patch "$res" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      else
        oc patch "$res" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      fi
      cleared=$((cleared + 1))
      err "   ↳ FORCE-CLEARED finalizers on ${res}/${name}${ns:+ -n $ns} — it held ${fins} and the next"
      err "     phase is about to remove the controller that owns it. Its operator cleanup will NOT run."
    done < <(oc get applications.argoproj.io "$app" -n "$ARGO_NS" \
               -o jsonpath='{range .status.resources[*]}{.group}{"|"}{.kind}{"|"}{.namespace}{"|"}{.name}{"\n"}{end}' 2>/dev/null || true)
  done < <(our_applications)
  if [[ "$cleared" -gt 0 ]]; then
    err "   ${cleared} operand(s) force-cleared. Anything they owned is ORPHANED — ogsr-check-clean.sh"
    err "   names it afterwards. This is the cost of the phase timing out, not of clearing them."
  fi
  return 0
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
  err "${label} did not finish pruning within ${budget}s"
  # DO NOT simply proceed. Proceeding is what converts a stalled prune into an unrecoverable one: the
  # next phase deletes the operator whose finalizer is holding these operands, and after that no wait
  # can ever clear them. Release them here, while that is still merely a stall, then give the cascade a
  # short second chance now that nothing is blocking it.
  release_operand_blockers "$label" "$members"
  if wait_for_phase "${label} (after releasing blockers)" "$members" "$PHASE_FLOOR"; then
    ok "${label} completed once its blocked operands were released"
    return 0
  fi
  err "   still not finished after releasing blockers — moving on; the straggler sweep and the report"
  err "   below cover whatever is left, and ogsr-check-clean.sh names anything orphaned"
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
  # The caller's namespace classification is a snapshot; by the time we get here another step's cascade
  # may have already deleted this same namespace out from under it (measured 2026-07-31: step 9 logged
  # "deleted namespace/openshift-gitops-operator", then step 10's own independent re-scan caught it
  # mid-Terminating and logged "preserved" the SAME namespace — self-contradictory, even though the end
  # state was correct). Check live and say which one actually happened.
  if ! obj_exists namespace "$ns" ""; then
    echo "   • namespace/${ns} is already gone (deleted or caught mid-Terminating elsewhere) — nothing to preserve or strip"
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
    # so this branch would PRESERVE 'workshop-users' — but step 6 deletes the htpasswd secret it points
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
      # >&2 like the err() above it: a message whose sentence ends on stderr and whose command lands on
      # stdout is readable on NEITHER stream alone. Same convention as diagnose_stuck_app's hand-clear hint.
      echo "      oc -n openshift-monitoring edit configmap cluster-monitoring-config   # delete the enableUserWorkload line" >&2
      # RESIDUE, and the second instance of the same defect class as the Argo one: our
      # enableUserWorkload line stays on the org's ConfigMap. Drop the record here and the next
      # install snapshots monitoring_uwm_prior=true — after which every future teardown "preserves"
      # user-workload monitoring as something the org had all along.
      residue_record monitoring_uwm_prior \
        "cluster-monitoring-config -n openshift-monitoring still carries the enableUserWorkload key this workshop added; the ConfigMap had no such key before install. Remove it: oc -n openshift-monitoring edit configmap cluster-monitoring-config";;
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
  # ns_preexisted normalises lightspeed_ns_created's polarity for preserve_reason, which speaks in
  # "did it pre-exist?" while this key records "did WE create it?" — recorded "false" is a positive
  # statement that it was already there; empty means no record at all, which is NOT the same thing.
  local preinstalled ns_created secret_created secret_owner ns_preexisted
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
    case "$ns_created" in false) ns_preexisted="true" ;; *) ns_preexisted="" ;; esac
    echo "   • preserve namespace/openshift-lightspeed ($(preserve_reason "$ns_preexisted" namespace openshift-lightspeed))"
  fi
  return 0
}

# SEV1, reproduced live 2026-07-31: this used to delete the argocd/openshift-gitops CR fire-and-forget
# (`del_obj` → `--wait=false`) and then immediately delete the operator's Subscription+CSV. The CR's
# `argoproj.io/finalizer` runs ONLY inside the operator's own reconcile loop — it is what tears down the
# server/repo-server/redis/appset-controller Deployments and the RBAC the CR owns. Removing the operator
# before that finalizer had any chance to run left namespace/openshift-gitops wedged Terminating forever;
# ogsr-check-clean.sh diagnosed it exactly ("NO operator on this cluster owns argocds.argoproj.io —
# nothing will ever run this finalizer"). This is the one uninstall path NOT delivered by the Argo
# cascade (deleting the operator's OWN operand, not something Argo prunes), so it inherits none of the
# cascade's ordering guarantee and has to earn its own.
#
# Budget: 120s. An ArgoCD CR's own teardown is a handful of Deployments + RBAC — not a cascade phase
# pruning dozens of Applications — so it does not share CASCADE_TIMEOUT's 900s budget; 120s is generous
# against normal operator reconcile latency while still bounded (an unbounded wait turns a wedge into a
# hang, which is the failure mode report_stuck_namespaces exists to avoid elsewhere in this file).
ARGOCD_CR_FINALIZER_TIMEOUT=120

# <ns> <name> → "<uid>|<deletionTimestamp>", or "" if the object is absent. The ONE read both loop
# bodies below use to tell "still the object we deleted" from "a new one wearing the same name" — see
# wait_for_argocd_cr_gone's header for why that distinction, not presence/absence, is the real question.
argocd_cr_identity() {
  local ns="$1" name="$2"
  oc get argocd "$name" -n "$ns" -o jsonpath='{.metadata.uid}|{.metadata.deletionTimestamp}' 2>/dev/null || true
  return 0
}

# Set by wait_for_argocd_cr_gone() and read back by it alone (the generation count is logged inline as
# it happens, not summarised afterward) — kept as a global rather than a local return value only because
# a future caller may want to branch on the outcome without re-deriving it.
ARGOCD_WAIT_OUTCOME=""       # gone | resurrected-then-gone | force-cleared-original | force-cleared-resurrected

# ns name budget → ALWAYS returns 0 (forward progress is guaranteed within `budget` seconds; the caller
# never has to branch on failure). What happened is reported through the global above and logged as it
# occurs below — a fresh generation being recreated, or the budget running out, is worth knowing about
# the moment it happens, not just in a post-hoc summary.
#
# SEV1, reproduced live 2026-07-31 AGAINST THE FIRST FIX (a plain bounded wait for the CR to disappear,
# commit 67b8bd4): that fix is necessary but not sufficient. OpenShift GitOps self-heals a missing
# default instance — proof from that run: argocd/openshift-gitops's creationTimestamp landed AFTER this
# function's delete was issued and BEFORE the Subscription/CSV were removed, i.e. the operator recreated
# the CR while it was still alive to do so. The plain wait cannot tell that apart from "still terminating
# normally" — both read as "argocd/openshift-gitops exists" — so it burned its whole budget watching a
# resurrection loop and force-cleared at the end anyway, and namespace/openshift-gitops stayed
# Terminating: the object it patched had never had a delete issued against ITS generation, so stripping
# its finalizers did not make it go away (a finalizer-null patch only removes an object that ALREADY has
# a deletionTimestamp — it does not itself request deletion), and the org's own operator was already gone
# by the time anything tried to enumerate the namespace's contents again.
#
# The tension: operator alive → it can run the finalizer, but also resurrects the CR; operator dead →
# neither. Resolved by SEQUENCING plus a THIRD state this function distinguishes explicitly: a
# resurrection is proven, not guessed, by comparing the object's UID. Kubernetes never reuses a UID and
# never lets two live objects hold one namespaced name at once, so a NEW uid under the same name is proof
# — not an inference — that the OLD generation's delete (finalizer included) already ran to completion.
# That is what makes clearing a resurrected generation's finalizer a DIFFERENT decision from clearing the
# first one: by the time a new uid shows up, the real operand cleanup this whole wait exists to protect
# has already happened, on the generation before it. What is sitting under the name now is, at most,
# `budget` seconds old and had the operator alive to run a real delete on it via del_obj below — the
# force-clear at the end is reached only if THAT ALSO does not finish in time.
#
# ACCEPTED FAILURE MODE: if the operator keeps recreating the CR faster than each generation can tear
# down, this loop chases it for the full budget and then force-clears whatever generation is current. The
# risk that orphans is bounded to that last generation's brief lifetime, never to the original's full
# operand set — and the loop always terminates and always hands control back in ≤`budget` seconds, which
# is the property the old unbounded assumption did not have. Rejected alternatives: scaling the operator's
# Deployment to zero mid-loop (adds a second object whose name/replica-count is not guaranteed by the
# component manifests, a new failure surface to fix a problem UID-tracking already solves); deleting the
# Subscription/CSV first and handling the finalizer with no operator at all (guarantees the finalizer
# NEVER runs, the strictly worse case this whole function exists to avoid).
wait_for_argocd_cr_gone() {
  local ns="$1" name="$2" budget="$3" waited=0 id uid orig_uid gens=1
  ARGOCD_WAIT_OUTCOME="gone"

  if [[ "$DRY_RUN" == "true" ]]; then
    if obj_exists argocd "$name" "$ns"; then
      echo "   • WOULD wait up to ${budget}s for argocd/${name} -n ${ns}'s finalizer before removing the operator,"
      echo "     watching for OpenShift GitOps recreating its own default instance while its operator is still alive"
    fi
    return 0
  fi

  id="$(argocd_cr_identity "$ns" "$name")"
  if [[ -z "$id" ]]; then
    return 0   # already gone — idempotent re-run, or a finalizer that cleared before we even checked
  fi
  orig_uid="${id%%|*}"

  info "waiting for argocd/${name} -n ${ns} finalizer (argoproj.io/finalizer) to clear (up to ${budget}s) before removing its operator"
  while (( waited < budget )); do
    id="$(argocd_cr_identity "$ns" "$name")"
    if [[ -z "$id" ]]; then
      ok "argocd/${name} -n ${ns}: finalizer cleared after ${waited}s"
      if (( gens > 1 )); then
        ARGOCD_WAIT_OUTCOME="resurrected-then-gone"
        echo "   • it was recreated $((gens - 1)) time(s) by the operator's self-heal while we waited; the last generation also finished cleanly"
      fi
      return 0
    fi
    uid="${id%%|*}"
    if [[ "$uid" != "$orig_uid" ]]; then
      gens=$((gens + 1))
      echo "   • argocd/${name} -n ${ns} was RECREATED (new uid) after ${waited}s — OpenShift GitOps self-heals a"
      echo "     missing default instance while its operator is alive. This PROVES the previous generation's"
      echo "     finalizer already completed (a new object cannot take the name while the old one is still"
      echo "     there), so re-issuing delete on the new one orphans nothing the first generation owned:"
      del_obj argocd "$name" "$ns"
      orig_uid="$uid"
    fi
    if (( waited > 0 && waited % 30 == 0 )); then
      echo "   … still waiting for argocd/${name} -n ${ns} to finish deleting (${waited}s of ${budget}s)"
    fi
    sleep 10; waited=$((waited + 10))
  done

  if (( gens > 1 )); then
    ARGOCD_WAIT_OUTCOME="force-cleared-resurrected"
    err "argocd/${name} -n ${ns} did not finish deleting within ${budget}s, across ${gens} generations — the"
    err "operator keeps recreating it faster than it tears one down. The REAL operand cleanup already"
    err "happened, on an earlier generation (proven by the uid change logged above); force-clearing this"
    err "one orphans at most a few seconds of a brand-new instance, not the workshop's actual deployment."
  else
    ARGOCD_WAIT_OUTCOME="force-cleared-original"
    err "argocd/${name} -n ${ns} did not finish deleting within ${budget}s,"
    err "and the operator that is the only thing able to run its finalizer is about to be removed next."
  fi
  err "Force-clearing the CR's OWN finalizer now, while its operator is still here to have tried:"
  oc patch argocd "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  # Stripping finalizers alone does not delete an object with no deletionTimestamp — only an object
  # ALREADY marked for deletion disappears once its finalizer list empties. Every generation reachable
  # here had delete issued against it (the caller's own del_obj for the first, the del_obj call above for
  # each resurrection), so this reissue is what actually removes the object; without it a resurrected
  # generation could sit forever as a live, finalizer-less object — which is what left
  # namespace/openshift-gitops Terminating even after the earlier fix's force-clear.
  del_obj argocd "$name" "$ns"
  if [[ "$ARGOCD_WAIT_OUTCOME" == "force-cleared-original" ]]; then
    err "   ↳ FORCE-CLEARED finalizers on argocd/${name} -n ${ns}. Its own cleanup"
    err "     (server/repo-server/redis/appset-controller Deployments + the RBAC it owned) will NOT run —"
    err "     those objects are ORPHANED, not deleted. Deleting the openshift-gitops namespace below still"
    err "     removes what lives inside it; ogsr-check-clean.sh reports anything that survives that too."
  fi
  return 0
}

handle_gitops() {  # remove the GitOps operator ONLY if we created it; otherwise preserve (+ note the memory bump)
  local preexisted csv res
  preexisted="$(state gitops_preexisted)"
  if [[ "$preexisted" == "false" ]]; then
    info "GitOps was installed by us — removing operator + default instance"
    del_obj argocd openshift-gitops openshift-gitops
    # Bounded wait for the CR's OWN finalizer before the next lines remove the only controller that can
    # ever run it (see wait_for_argocd_cr_gone's header for the SEV1 this fixes, and the resurrection it
    # has to detect and chase). It ALWAYS returns having made forward progress — never leaves this
    # function branching on a failure it would otherwise have to re-implement force-clear logic for — but
    # every outcome, including a bare "the CR's finalizer just ran on schedule", is logged inside it, so
    # nothing here duplicates that reasoning. The operator is still installed for the whole call (its
    # Subscription/CSV are not deleted until below), which is what gives the finalizer — and any re-issued
    # delete on a resurrected generation — a real controller to run against.
    wait_for_argocd_cr_gone openshift-gitops openshift-gitops "$ARGOCD_CR_FINALIZER_TIMEOUT"
    # Same resolution as step 5, and routed through the same single delete path. argocd-bootstrap
    # applies this Subscription imperatively so the cascade does not normally reach it — but "normally"
    # is exactly the assumption that broke step 5, and del_created_csv re-derives the authorization
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
    # Probed on the operator's own namespace: the Subscription/CSV live there, so its presence is what
    # distinguishes "an adopted GitOps is really here" from "no GitOps on this cluster at all".
    info "GitOps operator + instance preserved ($(preserve_reason "$(state gitops_preexisted)" namespace openshift-gitops-operator))"
    # The adopted instance's controller SIZING is put back by restore_argocd_controller_resources(),
    # which runs in step 6 beside the other imperative reversals (monitoring, node shaping, OAuth IdP)
    # — it is one of those, not part of operator lifecycle. It is safe there and not here: it is gated
    # on a recorded consent that only an ADOPTED instance can ever carry, and step 3's cascade — the
    # one thing that needs the raised memory — has already drained by then.
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
      # Resolve the CSV WITHOUT depending on the Subscription — by step 5 the cascade has normally
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
        echo "      oc get csv -n ${ns}   # then: oc delete csv <name> -n ${ns}" >&2
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
      # after a teardown that was otherwise complete. Measured on a live cluster, 2026-07-25.
      strip_our_marks namespace "$ns" ""
    fi
  done < <(enumerate_operators)
  # Say so when there is nothing to act on, rather than printing an empty step. This is the ordinary
  # shape of a RE-RUN after a completed uninstall: run 1 deleted the state ConfigMap in step 10, so
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
  # END SENTINEL — the last thing this function emits, so its ABSENCE proves the loop above died early.
  # This function is consumed as `< <(classify_workshop_namespaces)`, i.e. in a subshell, and every emit
  # above is a bare `printf` under `set -e`: one failed write kills the subshell mid-loop and the reader
  # sees nothing but EOF. Measured on cluster-65prs 2026-08-06 — `printf: write error: Interrupted system
  # call` at namespace 85 of 137, after which the remaining 52 (all of user5-user8) were never classified,
  # delete_workshop_namespaces still returned 0, and the step ledger printed ✅ for a teardown that had
  # silently done a third less than it said. A count comparison would race with the cascade still
  # finishing its own namespace deletions; a sentinel cannot.
  printf 'end-of-classification\t-\t-\n'
  return 0
}

delete_workshop_namespaces() {  # act on the classification: delete ours, preserve+strip the rest (F7)
  local verb n reason seen=0 complete="false"
  while IFS=$'\t' read -r verb n reason; do
    [[ -n "$n" ]] || continue
    case "$verb" in
      end-of-classification) complete="true";;   # see classify_workshop_namespaces' END SENTINEL
      delete)         del_ns_fast "$n"; DELETED_WS_NS+=("$n"); seen=$((seen + 1));;
      preserve-strip) preserve_and_strip "$n" "$reason"; seen=$((seen + 1));;
      defer)          seen=$((seen + 1));;  # STATE_NS removed right after this fn; Lightspeed handled by handle_lightspeed
    esac
  done < <(classify_workshop_namespaces)
  # No sentinel = the classifier died partway and every namespace after that point was never looked at.
  # Reported, never swallowed: run_step marks the step failed and the EXIT ledger carries it, which is
  # the difference between "re-run this" and a teardown that silently left a third of itself behind.
  if [[ "$complete" != "true" ]]; then
    err "namespace classification STOPPED EARLY — only ${seen} owner-labeled namespace(s) were classified."
    err "   Every namespace it never reached was NOT acted on, and this step's ✅ would have been a lie."
    err "   Re-run this script: it is idempotent and skips whatever is already gone."
    return 1
  fi
  return 0
}

# F6 — a namespace whose operator we PRESERVED can wedge in Terminating on an operator-instance CR
# finalizer (e.g. CheCluster che.eclipse.org). We refuse to auto-strip arbitrary CR finalizers: the
# operator may still need to run its cleanup, and after the cascade the ordinary case is that it CAN —
# steps 2-3 removed operand CRs while their operators were alive, so anything still holding here is a
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
  local apps roots created adopted name ns st pkg gitops_plan mon_plan gw_plan mirror_plan operand_plan
  local verb wn reason nwipe=0 wipe_stack="" strip_list="" csv_plan="" res
  mirror_plan="$(mirror_stack)"
  # `grep -c .` prints 0 AND exits 1 on empty input, so a `|| echo '?'` fallback appended a second line
  # and the plan read "0\n?". Take the count and normalise it instead.
  apps="$(our_applications | grep -c . || true)"; apps="${apps:-0}"
  # Drive the namespace plan from the SAME classifier step 10 uses, so the summary is exactly the action.
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
    # Name the CSVs, resolved by the SAME call step 5 makes, so the plan and the action cannot
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
  # verification pass: the old two-way else printed "restore → ?" on a stateless cluster while step 5
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
  echo "(full removal — not the routine path; for cohort turnover use ogsr-reset.sh or ogsr-wipe-users.sh instead)"
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
  echo "    — most are pruned by the cascade; step 10 deletes any Argo did not manage, and waits."
  echo "  • Dev Spaces namespaces auto-provisioned for our attendees (<username>-devspaces, step 4) —"
  if [[ -n "${ATTENDEE_USERS// /}" ]]; then
    echo "    matched against $(printf '%s' "${ATTENDEE_USERS}" | wc -w | tr -d ' ') usernames this install created (Group/workshop-attendees + htpasswd-workshop-users);"
    echo "    a Dev Spaces namespace belonging to anyone else is the org's and is never touched"
  else
    echo "    no attendee usernames captured — nothing here is authorized for removal"
  fi
  echo "  • cluster-scoped operands their operator created for itself (step 2) — no Argo Application owns"
  echo "    them, so no cascade can prune them, and after their operator goes nothing ever will:"
  if [[ "$CRDS_CAPTURE_PHASE" == "pre-cascade" ]]; then
    operand_plan="$(cluster_scoped_created_crds \
      | while IFS= read -r crd; do
          [[ -n "$crd" ]] || continue
          oc get "$crd" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
            | sed "s|^|      - ${crd}/|"
        done || true)"
    printf '%s\n' "${operand_plan:-      - <none present>}"
  else
    echo "      - <the owned-CRD capture did not run; step 2 will delete nothing>"
  fi
  echo "  • the argo controller ClusterRoleBinding + ClusterRoles (applied imperatively by argocd-bootstrap)"
  echo "  • imperative bootstrap objects: htpasswd-workshop-users, workshop-users OAuth IdP entry, node labels/taint"
  echo "  • console plugins WE added to consoles.operator.openshift.io (backlog #24): $(state console_plugins_added '<none recorded>')"
  echo "  • operators WE created:${created:-<none recorded>}"
  echo "  • their ClusterServiceVersions — OLM creates a CSV from a Subscription and Argo never manages"
  echo "    it, so the cascade cannot prune it and only step 5 can. Left behind, a CSV BLOCKS the next"
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
  #
  # DELETING IT WHILE ANY APPLICATION STILL NAMES IT BRICKS THE TEARDOWN. Argo refuses to process an
  # Application whose project is missing — including its DELETION — so every straggler freezes in
  # Unknown with `InvalidSpecError: Application referencing project ogsr-platform which does not
  # exist` and `DeletionError: error getting app project`. Their hook finalizers then never clear and
  # their namespaces never finish. Measured on a live cluster 2026-07-25: deleting it in step 6 stranded 7
  # Applications and wedged the stackrox namespace on four finalizers at once. An AppProject left
  # behind is a reported leftover; an AppProject deleted too early is an unrecoverable teardown.
  local name remaining
  remaining="$(our_applications | grep -c . || true)"; remaining="${remaining:-0}"
  if [[ "$remaining" != "0" ]]; then
    warn "${remaining} Application(s) still reference an AppProject — NOT deleting it"
    echo "     Argo cannot process an Application whose project is gone, not even to delete it."
    echo "     Resolve those Applications first, then re-run; ogsr-check-clean.sh will report the"
    echo "     AppProject as a leftover in the meantime."
    return 0
  fi
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

# ── the nine steps ────────────────────────────────────────────────────────────
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

# ── operator-created operands ─────────────────────────────────────────────────
# THE DEFECT (measured 2026-07-31, after a full uninstall reported success). openshift-pipelines was
# still up: 18 pods Running 1/1, a bound 1Gi PVC, and a live TektonConfig — while the Pipelines CSV and
# Subscription were both gone. Nothing managed it and nothing ever would. Every check on the cluster
# read healthy, because the pods genuinely were.
#
# WHY THE CASCADE CANNOT REACH IT. Argo prunes what Argo applied, identified by its own tracking-id
# annotation. TektonConfig was never applied by Argo — the Pipelines operator creates it itself the
# moment it starts (the portfolio's own subscription.yaml says exactly that in its wave-0 comment).
# So it carries no tracking-id, no Application owns it, and no `oc delete application` will ever touch
# it. Deleting its Subscription and CSV removes the only controller that could have cleaned it up and
# leaves the operand, and everything the operand stood up, running forever.
#
# WHY HERE, BETWEEN STEP 1 AND STEP 2 — the same ordering argument the cascade itself is built on, one
# layer further out. It has to be AFTER step 1, because an app-of-apps still on `automated: {selfHeal}`
# would re-create anything we removed. It has to be BEFORE step 3, because step 3 is what starts
# dismantling the operators: the operand's finalizer can only run while its own controller is alive,
# and after the cascade + step 5 that controller is gone, at which point the finalizer can NEVER
# complete and the object needs a human with a finalizer patch. This is the last moment everything is
# still running.
#
# SCOPE: CLUSTER-SCOPED operands only, of CRDs owned by an operator the state records as created BY US.
# The scope restriction is the argument, not a shortcut. A NAMESPACED operand sits in a namespace this
# teardown deletes, and dies with it (and the one case where a namespaced finalizer needs its operator
# alive — Dev Spaces' DevWorkspaces — already has its own step, 4). A CLUSTER-SCOPED operand has no
# namespace to take it: if this step does not remove it, nothing ever does. That is the whole of the
# measured defect and it is the whole of what this step claims.
#
# TWO THINGS ARE NEVER TOUCHED, checked per object rather than assumed, and PROTECTION IS TESTED FIRST:
#   • anything carrying Prune=false,Delete=false — a protection mark, whether install.sh stamped it on
#     an adopted resource or a chart ships it on an operand we only patch. Either way the object STAYS.
#   • anything Argo currently tracks — the ordered cascade prunes it in reverse sync-wave order, which
#     is strictly better ordering than this step has; racing it would only break that.
#
# WHY THAT ORDER, given both branches merely `continue`. It is not a behaviour fix — it is a TRUTH fix
# for the sentence this step prints. The two marks are not mutually exclusive: TektonConfig/config
# carries our own `pp-openshift-pipelines:…` tracking-id AND
# `SkipDryRunOnMissingResource=true,Prune=false,Delete=false` (measured on a live cluster 2026-08-06;
# the mark is hardcoded in platform-portfolio/components/openshift-pipelines/tekton-config.yaml, NOT
# applied by install.sh's adoption logic, because the Pipelines operator creates the object itself and
# an Argo cascade taking it would tear down the ENTIRE Tekton install on a cluster where Pipelines
# belongs to the org). With the Argo test first, that object printed "the ordered cascade prunes it in
# wave order" — and `Delete=false` is precisely the instruction NOT to prune it. An operator reading
# that line was told the object was being handled while it was being left behind, permanently.
# Protection first means the sentence that survives is the one that matches what happens; a third
# sentence names the both-true case explicitly rather than letting either half stand in for it.
#
# TWO PASSES, because an operator can re-create a child operand from a parent that has not gone yet
# (TektonConfig owns TektonPipeline/TektonTrigger/…, and the CRDS_CREATED_SET has no parent-child
# order in it). The second pass is the idempotency proof as well: on a clean first pass it finds
# nothing, which is exactly what re-running the whole script must also do.
cluster_scoped_created_crds() {  # → CRDs owned by an operator WE created that are CLUSTER-scoped
  local scopes crd
  [[ "$CRDS_CREATED_SET" != " " ]] || return 0
  # One read for every CRD's scope. Asking per CRD would be ~165 round trips on a full install.
  scopes="$(oc get customresourcedefinitions.apiextensions.k8s.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.scope}{"\n"}{end}' 2>/dev/null || true)"
  for crd in $CRDS_CREATED_SET; do
    case "$(printf '%s\n' "$scopes" | awk -F'|' -v c="$crd" '$1==c {print $2; exit}')" in
      Cluster) printf '%s\n' "$crd";;
    esac
  done
  return 0
}

step_delete_operator_operands() {  # 2 — operands only their own operator can finalize, deleted first
  local crd inst pass deleted=0 skipped=0 left stuck=0 budget deadline
  if [[ "$CRDS_CAPTURE_PHASE" != "pre-cascade" ]]; then
    err "the owned-CRD capture did not run before this step — refusing to guess which operands are ours."
    err "   Nothing was deleted. ./bootstrap/ogsr-check-clean.sh will report what is left."
    # Non-zero on purpose: the ledger the EXIT trap prints must say this step did not do its job.
    # Reporting "ok" for a step that declined to act is the shape of defect this whole file fights.
    return 1
  fi
  # A third of the cascade budget, floor 60s: someone who shortens --cascade-timeout means "do not sit
  # here", and a fixed wait would ignore that. Shared across both passes, so the step is bounded.
  budget=$(( CASCADE_TIMEOUT / 3 ))
  if [[ "$budget" -lt 60 ]]; then budget=60; fi
  deadline=$(( $(date +%s) + budget ))
  for pass in 1 2; do
    while IFS= read -r crd; do
      [[ -n "$crd" ]] || continue
      while IFS= read -r inst; do
        [[ -n "$inst" ]] || continue
        # Protection first — see the ORDER argument in this step's header. The nested argo_manages
        # runs only on pass 1 (pass 2 prints nothing) and only for an operand that is already
        # protected, so the extra read costs one call per protected operand per teardown.
        if is_protected "$crd" "$inst"; then
          if [[ "$pass" == "1" ]]; then
            skipped=$((skipped + 1))
            if argo_manages "$crd" "$inst"; then
              echo "   • skip ${crd}/${inst} — Argo tracks it, but Delete=false tells the cascade NOT to prune it:"
              echo "     it STAYS on the cluster after this teardown, on purpose. ./bootstrap/ogsr-check-clean.sh"
              echo "     reports it as declared residue and prints the command if you do want it gone."
            else
              echo "   • skip ${crd}/${inst} — marked Prune=false,Delete=false; this operand is the org's"
            fi
          fi
          continue
        fi
        if argo_manages "$crd" "$inst"; then
          if [[ "$pass" == "1" ]]; then
            skipped=$((skipped + 1))
            echo "   • skip ${crd}/${inst} — Argo tracks it, so the ordered cascade prunes it in wave order"
          fi
          continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
          if [[ "$pass" == "1" ]]; then
            echo "   • WOULD delete ${crd}/${inst} (operator-created, cluster-scoped, no Argo owner)"
          fi
          continue
        fi
        # BLOCKING on purpose. --wait=true is what proves the finalizer completed while the operator
        # was still there; returning early and hoping is how the operand ends up orphaned anyway.
        left=$(( deadline - $(date +%s) ))
        if [[ "$left" -lt 15 ]]; then left=15; fi
        if oc delete "$crd" "$inst" --ignore-not-found --wait=true --timeout="${left}s" >/dev/null 2>&1; then
          deleted=$((deleted + 1))
          ok "deleted ${crd}/${inst} — its finalizer ran while its operator was still up"
        else
          stuck=$((stuck + 1))
          err "   ${crd}/${inst} did not finish deleting within ${left}s. Its operator is about to be"
          err "      removed, after which the finalizer can never complete. Clear it by hand NOW:"
          err "      oc patch ${crd} ${inst} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
        fi
      done < <(oc get "$crd" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    done < <(cluster_scoped_created_crds)
    if [[ "$DRY_RUN" == "true" ]]; then break; fi
  done
  if [[ "$deleted" -eq 0 && "$stuck" -eq 0 ]]; then
    echo "   • no operator-created cluster-scoped operand of ours is present (${skipped} left to the cascade)"
  fi
  # An operand still holding after its bounded wait is the exact outcome this step exists to prevent,
  # and the operator that could still clear it is removed two steps from now. Say so in the ledger.
  if [[ "$stuck" -gt 0 ]]; then return 1; fi
  return 0
}

step_remove_devspaces_namespaces() {  # 4 — Dev Spaces namespaces auto-provisioned for our attendees (#84)
  # Dev Spaces auto-provisions ONE namespace per attendee the first time they open a workspace
  # (devEnvironments.defaultNamespace {autoProvision: true, template: "<username>-devspaces"}), so a
  # cohort of N attendees leaves N of these behind. It carries NONE of our labels —
  # classify_workshop_namespaces below finds its targets with `-l "$OWNER_LABEL"`, which never matches
  # a Dev Spaces namespace — so every namespace-owning step in this script used to report done while
  # one of these survived per attendee. ogsr-check-clean.sh's section [4/9] is what actually spotted
  # it, by the one mark that IS on it: che.eclipse.org/username.
  #
  # THE DISCRIMINATOR IS AN INTERSECTION, not the annotation alone. che.eclipse.org/username is stamped
  # on every namespace Dev Spaces auto-provisions, including the org's OWN users on a cluster whose Dev
  # Spaces we adopted — those namespaces are the org's and must survive this teardown exactly like any
  # other object we did not create. A namespace only qualifies here when its annotation value is ALSO
  # one of the usernames ATTENDEE_USERS captured (capture_attendee_users(), called before step 1 —
  # see that function for why there are two sources and why a re-run with neither reachable skips
  # rather than guesses).
  #
  # WHY STEP 4, between the cascade (3) and the CSV cleanup (5) — and not folded into step 10's final
  # namespace sweep, where it would sit more tidily alongside every other namespace deletion. A Dev
  # Spaces workspace can leave DevWorkspace custom resources in the attendee namespace, and those carry
  # a devworkspace-operator finalizer that only that operator's own controller can ever clear (the same
  # rule diagnose_stuck_ns in ogsr-check-clean.sh applies to every other operator-owned finalizer: a
  # controller that is still installed can still complete it; one that is gone never will). Step 3's
  # cascade removes the Dev Spaces Subscription (Argo owns it), but a Subscription's removal does not
  # touch the CSV it installed — the operator's Deployment is owned by the CSV, not the Subscription,
  # so the controller is STILL RUNNING when step 3 returns. Step 5 is what deletes that CSV, and with
  # it the controller. Namespace deletion issued HERE, before step 5, gives any such finalizer its only
  # real chance to run to completion; issued after step 5, or deferred all the way to step 10, the
  # controller that could have cleared it is already gone and the namespace is left to wedge in
  # Terminating for a human to diagnose. // TODO(verify-on-cluster): no attendee had an open workspace
  # to confirm a live DevWorkspace's finalizer actually blocks in that state — the CSV-alive-vs-gone
  # asymmetry is real either way, and acting earlier is never less safe than acting later.
  local ns che matched=0
  if [[ -z "${ATTENDEE_USERS// /}" ]]; then
    echo "   • no attendee usernames captured (Group/workshop-attendees and the htpasswd secret were"
    echo "     both unreadable) — nothing here is authorized for removal; ogsr-check-clean.sh will"
    echo "     still report any che.eclipse.org/username namespace left behind"
    return 0
  fi
  while IFS='|' read -r ns che; do
    [[ -n "$ns" && -n "$che" ]] || continue
    case "$ATTENDEE_USERS" in
      *" ${che} "*)
        matched=$((matched + 1))
        del_ns_fast "$ns"
        DELETED_WS_NS+=("$ns")
        ;;
    esac
  done < <(oc get namespaces \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.che\.eclipse\.org/username}{"\n"}{end}' \
    2>/dev/null || true)
  if [[ "$matched" -eq 0 ]]; then
    echo "   • no Dev Spaces namespace matched a username this install created — nothing to remove"
  fi
  return 0
}

# ── adopted Argo CD controller sizing ─────────────────────────────────────────
# Put an ADOPTED openshift-gitops controller back EXACTLY as we found it. Reaching the "no trace" bar
# for the one org-owned object the installer is allowed to mutate (with consent — see the adopted
# branch of platform-portfolio/argocd-bootstrap/install.sh).
#
# SUPERSEDES restore_argocd_controller_memory() (d79d088), which stood here and restored ONLY
# .spec.controller.resources.limits.memory. That could not reach the bar it was written for: the
# override applies limits.cpu="2", limits.memory=6Gi, requests.cpu=250m AND requests.memory=2Gi, so
# putting one of those four back leaves three of ours on the org's CR — and its empty-prior branch
# (`remove /spec/controller/resources/limits/memory`) left behind a whole `resources:` block the CR
# never had. Same contract, same consent semantics, same step; whole block instead of one field, and
# on the key the other two install entry points already write. Placement kept from that commit.
#
# ONE FACT, ONE KEY. The prior value is gitops_argocd_controller_resources_b64: base64 of the CR's
# WHOLE .spec.controller.resources, written first-write-wins by every install entry point
# (bootstrap/install.sh, helm/bootstrap's job-state-capture Job, and the portfolio's consent gate).
# It has to be the whole block, not just the memory: the override sets limits.cpu, limits.memory,
# requests.cpu and requests.memory, so a memory-only record could never undo it.
#
# argocd_controller_resources_changed_by_us is the ORTHOGONAL fact and the reason it is a second key
# rather than an inference: two of the three writers above snapshot the prior WITHOUT mutating
# anything, so "a prior was recorded" never meant "we changed it". Only a recorded consent authorizes
# a restore; without it we are back to the pre-2026-07-31 behaviour of naming the value and standing
# down (the legacy branch below), because writing to someone's CR on a guess is the very harm this
# whole path exists to avoid.
#
# AN EMPTY PRIOR IS MEANINGFUL, and is recorded by the ABSENCE of the b64 key: the CR carried no
# explicit .spec.controller.resources at all. Restoring that means REMOVING the field — a
# JSON-merge-patch null — never writing a number back. Every writer of the key already skips it when
# the value is empty and the state ConfigMap cannot represent an empty string distinguishably from an
# unset one, so absence is the unambiguous encoding and needs no sentinel.
restore_argocd_controller_resources() {
  local changed b64 prior target_mem prior_mem live_mem rc=0 out
  changed="$(state argocd_controller_resources_changed_by_us)"
  b64="$(state gitops_argocd_controller_resources_b64)"
  prior=""
  if [[ -n "$b64" ]]; then
    prior="$(printf '%s' "$b64" | base64 --decode 2>/dev/null || true)"
  fi

  if [[ "$changed" != "true" ]]; then
    # LEGACY state, written before consent was recorded (or by a snapshot pass that never patched).
    # Behaviour preserved verbatim, including its reasoning: install only RAISES the controller memory
    # limit (operator default 2Gi → 6Gi). If the org was ALREADY at the target, install changed nothing
    # and there is nothing to restore — so gate the warning on prior≠target instead of firing whenever
    # a prior spec was recorded (false alarm on a cluster that shipped at 6Gi). Target is read from the
    # canonical override so it never drifts.
    if [[ -z "$b64" ]]; then return 0; fi
    target_mem="$(yq '.spec.controller.resources.limits.memory' "${SCRIPT_DIR}/../platform-portfolio/argocd-bootstrap/operator/argocd-controller-resources.yaml" 2>/dev/null || true)"
    if [[ -z "$target_mem" || "$target_mem" == "null" ]]; then target_mem="6Gi"; fi
    prior_mem="$(printf '%s' "$prior" | yq -p=json '.limits.memory' 2>/dev/null || true)"
    live_mem="$(oc get argocd openshift-gitops -n "$ARGO_NS" -o jsonpath='{.spec.controller.resources.limits.memory}' 2>/dev/null || true)"
    if [[ "$prior_mem" == "$target_mem" ]]; then
      echo "   • openshift-gitops controller memory was already ${target_mem} before install — not raised, nothing to restore"
    elif [[ "$live_mem" != "$target_mem" ]]; then
      # Second, independent proof that nothing of ours is on this CR: the live limit is not the value
      # this workshop applies, so no install path ever raised it (the FSC/helm entry point records the
      # same b64 snapshot but never patches the controller at all — without this check that path fires
      # a "cannot prove the change was ours" alarm on every teardown, about a change that never
      # happened). If we HAD raised it, the live value would be the target.
      echo "   • openshift-gitops controller memory is ${live_mem:-the operator default} — not ${target_mem}, so this workshop never raised it; nothing to restore"
    else
      err "a prior openshift-gitops controller spec was recorded, but NO consent to change it was —"
      err "   this install predates the consent gate, so we cannot prove the change was ours and will"
      err "   not write to an adopted CR on a guess. Prior spec.controller.resources:"
      # The VALUE this sentence promises, on the SAME stream as the sentence. Measured on a live cluster
      # 2026-08-06: with these two on stdout, `2>/dev/null` printed a bare JSON blob with no line saying
      # what it was, and `1>/dev/null` printed "Prior spec.controller.resources:" with nothing after it.
      echo "      ${prior:-<unreadable>}" >&2
      echo "      restore manually if the org relied on it: oc -n ${ARGO_NS} edit argocd openshift-gitops" >&2
      # RESIDUE. The live limit IS our target and the recorded prior is not, so a workshop install
      # raised it and this run is walking away without putting it back. Deleting the record now would
      # make the next install snapshot OUR ${target_mem} as the org's original.
      residue_record gitops_argocd_controller_resources_b64 \
        "argocd/openshift-gitops -n ${ARGO_NS} is at the workshop's ${target_mem}; no consent record authorised putting it back. Restore: oc -n ${ARGO_NS} patch argocd openshift-gitops --type json -p '[{\"op\":\"add\",\"path\":\"/spec/controller/resources\",\"value\":${prior}}]'"
    fi
    return 0
  fi

  # Tolerant of the object already being absent — an adopted instance can still have been removed by
  # its owner between install and teardown, and that is not our failure to report as one.
  if ! oc get argocd openshift-gitops -n "$ARGO_NS" >/dev/null 2>&1; then
    echo "   • skip controller-resources restore (argocd/openshift-gitops -n ${ARGO_NS} absent)"
    return 0
  fi

  if [[ -z "$b64" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "   • WOULD remove spec.controller.resources from argocd/openshift-gitops (the CR carried none before install)"
      return 0
    fi
    out="$(oc patch argocd openshift-gitops -n "$ARGO_NS" --type merge \
             -p '{"spec":{"controller":{"resources":null}}}' 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      err "could not remove spec.controller.resources from argocd/openshift-gitops: ${out}"
      echo "      by hand: oc -n ${ARGO_NS} patch argocd openshift-gitops --type merge -p '{\"spec\":{\"controller\":{\"resources\":null}}}'"
      # RESIDUE with an EMPTY prior. The key stays UNSET in the carried ConfigMap on purpose — absence
      # is how "the CR carried no explicit .spec.controller.resources" is encoded, and residue_keys is
      # what makes that absence authoritative instead of just missing (see install.sh's record_once).
      residue_record gitops_argocd_controller_resources_b64 \
        "argocd/openshift-gitops -n ${ARGO_NS} still carries the workshop's spec.controller.resources; the CR had NONE before install and the removal patch failed. Restore: oc -n ${ARGO_NS} patch argocd openshift-gitops --type merge -p '{\"spec\":{\"controller\":{\"resources\":null}}}'"
      return 1
    fi
    ok "removed spec.controller.resources from argocd/openshift-gitops (it carried no explicit sizing before install; the operator restarts the controller)"
    return 0
  fi

  # The recorded value is `oc get -o jsonpath='{.spec.controller.resources}'` output, which kubectl
  # marshals as JSON for a map — so it can go straight back as a patch VALUE. Refuse anything that is
  # not an object rather than feed the CR a malformed patch: a client old enough to have printed Go's
  # map[…] form would otherwise turn a restore into a corruption.
  case "$prior" in
    '{'*'}') ;;
    *)
      err "recorded prior controller resources are not a JSON object — refusing to patch argocd/openshift-gitops with them."
      echo "      recorded value: ${prior:-<unreadable>}"
      echo "      restore by hand: oc -n ${ARGO_NS} edit argocd openshift-gitops"
      residue_record gitops_argocd_controller_resources_b64 \
        "argocd/openshift-gitops -n ${ARGO_NS} still carries the workshop's sizing; the recorded prior is not a JSON object so it could not be patched back. Restore by hand: oc -n ${ARGO_NS} edit argocd openshift-gitops"
      return 1 ;;
  esac

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   • WOULD restore argocd/openshift-gitops spec.controller.resources to ${prior}"
    return 0
  fi
  # JSON patch `add`, not a merge patch: `add` REPLACES the whole value at the path, while a merge
  # patch would union our four keys with the prior's — leaving requests.memory=2Gi behind on a CR
  # whose prior block only set limits.memory. Union is not restoration.
  out="$(oc patch argocd openshift-gitops -n "$ARGO_NS" --type json \
           -p "[{\"op\":\"add\",\"path\":\"/spec/controller/resources\",\"value\":${prior}}]" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    err "could not restore argocd/openshift-gitops spec.controller.resources: ${out}"
    echo "      recorded prior value: ${prior}"
    echo "      restore by hand: oc -n ${ARGO_NS} edit argocd openshift-gitops"
    residue_record gitops_argocd_controller_resources_b64 \
      "argocd/openshift-gitops -n ${ARGO_NS} still carries the workshop's sizing; the restore patch failed. Restore: oc -n ${ARGO_NS} patch argocd openshift-gitops --type json -p '[{\"op\":\"add\",\"path\":\"/spec/controller/resources\",\"value\":${prior}}]'"
    return 1
  fi
  ok "restored argocd/openshift-gitops spec.controller.resources to ${prior} (the operator restarts the controller)"
  return 0
}

step_reverse_cluster_mutations() {  # 5 — the imperative, cluster-global changes install.sh made
  sub remove_oauth_idp
  sub remove_console_plugins
  sub del_obj secret htpasswd-workshop-users openshift-config
  sub handle_lightspeed
  sub restore_monitoring
  sub reverse_node_shaping
  sub restore_argocd_controller_resources
  return 0
}

step_gateway_api() {  # 6 — remove only if we created it. Argo manages this CR (it is
  # platform-portfolio/components/gateway-api/gatewayclass.yaml), so a GatewayClass WE created is
  # already gone with the cascade and del_obj skips it. Kept for the adopted case, which is the branch
  # that matters: it must NOT be deleted, and the guard above has verified Argo will skip it.
  if [[ "$(state gatewayclass_preexisted)" == "false" ]]; then
    del_obj gatewayclass.gateway.networking.k8s.io openshift-default
  else
    echo "   • preserve GatewayClass/openshift-default ($(preserve_reason "$(state gatewayclass_preexisted)" gatewayclass.gateway.networking.k8s.io openshift-default))"
  fi
  return 0
}

step_cluster_rbac() {  # 7 — cluster-scoped objects the cascade CANNOT reach, because Argo never
  # managed them. Everything else that used to be swept here is now pruned by step 3 and has been
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
  # OAuthClients are the second member of that "imperative source" class, added 2026-08-16 with the
  # shared cockpit's OAuth front door (gitops/workshop-config/templates/showroom-shared.yaml). The
  # cockpit needs a REAL OAuthClient rather than a ServiceAccount-as-client — an SA client's tokens
  # are capped at `user:info user:check-access`, which cannot drive a terminal — and the client's
  # secret has to be minted IN the cluster and reused across syncs, so a Sync-hook Job creates it
  # rather than Argo. That is exactly what puts it out of the cascade's reach: `argo_manages()`
  # answers no, nothing prunes it, and an OAuthClient outlives the namespace it serves. Left behind
  # it is a standing OAuth grant on someone else's cluster — the same "leftover with a security
  # consequence" category as the RBAC above, which is why it is swept here and not merely reported.
  #
  # Safe as a label sweep because we never ADOPT one: the portfolio's kustomize label transformer
  # stamps the owner label on resources in the components it manages, and no component manages an
  # OAuthClient (measured on a live cluster 2026-08-16: the six present were console, kiali,
  # openshift-browser-client, openshift-challenging-client, openshift-cli-client and
  # openshift-devspaces-client, none of them ours and none owner-labelled). Every owner-labelled
  # OAuthClient is therefore one this installer created.
  sub del_labeled_cluster oauthclients.oauth.openshift.io
  # NOTE: del_appprojects deliberately does NOT run here. It moved to the LAST step, because an
  # AppProject removed while any Application still names it freezes those Applications permanently
  # (Argo will not process an app whose project is missing, not even to delete it). By step 10 the
  # cascade has drained and the guard inside del_appprojects re-checks anyway.
  sub remove_argo_tls_cert_key
  sub sweep_dead_webhooks
  sub del_labeled_rbac_in_preserved_ns
  return 0
}

del_labeled_rbac_in_preserved_ns() {
  # Owner-labelled RBAC we placed in namespaces we PRESERVE. Found by the #84 regression, 2026-07-30:
  # a completed teardown left roles/maas-copy-agentic-ai-1 and its RoleBinding in openshift-lightspeed.
  #
  # Why nothing caught it. Everything else we create lives in a namespace we delete outright, and
  # deleting a namespace takes its contents with it — so namespaced cleanup has never been needed.
  # del_labeled_cluster only handles CLUSTER-scoped kinds, as its own name says. The leak is exactly
  # the intersection: objects WE created, inside a namespace we deliberately do NOT delete because the
  # org owns it. RBAC is the class that matters there — a leftover Role/RoleBinding grants standing
  # access after a teardown, which is the one leftover kind with a security consequence rather than
  # merely an untidy one.
  #
  # Deliberately narrow, and it must stay narrow. Our kustomize label transformer stamps the owner
  # label on every resource in a component INCLUDING adopted ones, so an owner label is not proof we
  # created something — ogsr-check-clean.sh says so in its own section [8/9]. A blanket "delete every
  # owner-labelled object everywhere" sweep would therefore delete the org's resources that we merely
  # marked. Restricting this to Roles and RoleBindings keeps it to objects this installer creates by
  # hook rather than inherits, and leaves anything ambiguous to the checker's report and a human.
  local kind ns name preserved
  preserved="$(oc get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "$preserved" ]] || return 0
  for kind in roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io; do
    while IFS='|' read -r ns name; do
      [[ -n "$ns" && -n "$name" ]] || continue
      del_obj "$kind" "$name" "$ns"
    done < <(oc get "$kind" -A -l "$OWNER_LABEL" \
               -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  done
  return 0
}

sweep_dead_webhooks() {  # admission webhooks whose backing Service died with a namespace we removed
  # Some operators register their webhooks at RUNTIME rather than through the CSV's webhookdefinitions,
  # so OLM does not own them and removing the operator leaves them behind. Sync waves cannot help: the
  # operator's finalizer only cleans up what the operator itself tracks. Measured on a live cluster 2026-07-25 —
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
  # SECOND SCOPE — operators WE created inside a SHARED namespace. Found by the #84 teardown
  # regression, 2026-07-30: a full uninstall left three Tekton webhooks
  # (config./validation./webhook.operator.tekton.dev) pointing at
  # openshift-operators/tekton-operator-webhook, a Service that no longer existed. All three carry
  # failurePolicy=Fail, so with their backend gone they REJECT OR HANG every create/update they
  # intercept — cluster-wide, for anyone touching Tekton objects, including orgs that never ran this
  # workshop. ogsr-check-clean flagged them as its only cluster-health findings (0 before, 3 after).
  #
  # The first scope above cannot catch them, and correctly so on its own terms: it requires the
  # webhook's Service to sit in a namespace we OWNED AND REMOVED, and skips any namespace that still
  # exists. But three components — openshift-pipelines, devspaces, web-terminal — deliberately
  # install into `openshift-operators`, because that namespace already carries the cluster-wide
  # OperatorGroup and adding a second one is the singleton violation that silently breaks the org's
  # operators. So their webhooks live in a namespace that is not ours and does not go away, while the
  # operator that created them IS ours and step 5 removed it.
  #
  # The safe discriminator is not the namespace, it is: did WE create the operator that owns this
  # webhook, and is its backing Service actually gone? A missing Service means the webhook cannot
  # function for anyone, so leaving it serves nobody — while an org webhook whose Service is alive is
  # untouched by the Service check alone. Both conditions are required.
  local shared_created
  shared_created=" $(created_operator_namespaces 2>/dev/null | tr '\n' ' ') "

  local kind name svc_ns svc_nm owned
  owned=" $(enumerate_installed_stack_ns | tr '\n' ' ') "
  for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    while IFS='|' read -r name svc_ns svc_nm; do
      [[ -n "$name" && -n "$svc_ns" ]] || continue
      if [[ " $owned " == *" ${svc_ns} "* ]]; then
        oc get namespace "$svc_ns" >/dev/null 2>&1 && continue      # namespace still there: not ours to judge
      elif [[ " $shared_created " == *" ${svc_ns} "* ]]; then
        :                                                            # shared ns, but the operator was ours
      else
        continue                                                     # neither: the org's to diagnose
      fi
      oc get service "$svc_nm" -n "$svc_ns" >/dev/null 2>&1 && continue
      del_obj "$kind" "$name"
    done < <(oc get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.webhooks[0].clientConfig.service.namespace}{"|"}{.webhooks[0].clientConfig.service.name}{"\n"}{end}' 2>/dev/null || true)
  done
  return 0
}

# Namespaces where the recorded state says WE created an operator. Used to widen the orphaned-webhook
# sweep above into shared namespaces without widening it to namespaces the org owns outright: an
# operator marked `adopted` never contributes its namespace here, so an adopted operator's webhooks
# stay untouched even when they sit beside one of ours.
created_operator_namespaces() {
  local name ns st pkg
  while read -r name ns st pkg; do
    [[ -n "$name" && "$st" == "created" ]] || continue
    printf '%s\n' "$ns"
  done < <(enumerate_operators 2>/dev/null || true) | sort -u
}

step_delete_namespaces() {  # 9 — whatever the cascade did not own, then the state namespace last
  # AppProjects go FIRST in this step and LAST in the run: by now the cascade has drained, so no
  # Application should still name one. del_appprojects re-checks and refuses if any does — deleting
  # it early is what stranded 7 Applications and wedged a namespace on 2026-07-25.
  sub del_appprojects
  sub delete_workshop_namespaces
  # AFTER delete_workshop_namespaces, because test [B] asks which instances survive OUTSIDE the
  # namespaces this run removes, and DELETED_WS_NS is not populated until that call has classified them.
  # BEFORE the dump below, which is the one thing the classification exists to filter. Read-only, so it
  # runs in --dry-run too — which is what lets the plan show the CRDs a real run would decline to offer.
  sub classify_shared_crds
  sub report_shared_crds
  # The state ConfigMap is about to go with its namespace, so dump it first: ogsr-check-clean.sh needs
  # it to tell an adopted operator from one we created, and a second run has no other source.
  # Only set in a REAL run: the closing guidance prints `--state-file $STATE_DUMP` when the file is
  # readable, and a dry-run must not point at a dump left behind by some earlier run.
  if [[ "$DRY_RUN" != "true" && -n "$STATE_SNAPSHOT" ]]; then
    STATE_DUMP="${TMPDIR:-/tmp}/ogsr-uninstall-state.txt"
    # crds_created exists ONLY in this in-memory snapshot, never in the live ConfigMap install.sh wrote
    # (it is populated during THIS run — see record_created_crds) — so it has to be folded in here, the
    # one place that snapshot gets persisted, or it is lost the moment the ogsr-system namespace goes.
    #
    # CRDS_MINE, never CRDS_CREATED_SET: this key is a DELETE AUTHORISATION (§ the shared-CRD guard) and
    # only the CRDs that passed both the foreign-owner and the outside-instance test may appear in it.
    # Written ONLY on a complete classification — a half-finished split would shorten the list silently,
    # which is the one failure mode this whole area was rebuilt to stop. Its absence is not a loss: the
    # checker's heuristic mode says out loud that every CRD needs verifying by hand.
    if [[ "$CRDS_CLASSIFIED" == "true" && "$CRDS_MINE" != " " ]]; then
      STATE_SNAPSHOT="${STATE_SNAPSHOT}"$'\n'"crds_created=$(printf '%s' "$CRDS_MINE" | sed -e 's/^ //' -e 's/ $//' -e 's/ /,/g')"
    fi
    # The withheld half, carried so it cannot vanish between this run and whoever reads the dump. It is
    # a statement, not an authorisation: nothing may turn this key into a delete command.
    #
    # NAMES ONLY, AND THAT IS SETTLED — owner decision 2026-08-06, asked and answered. `$CRDS_SHARED`
    # holds `<name>|<reason>` pairs and the awk above deliberately keeps only field 1. A proposal to
    # add a `crds_shared_why` key was raised and DECLINED, so do not "improve" this into one.
    #
    # The argument for it, recorded so the decision is not re-litigated from scratch: the reason is
    # computed here at the honest moment — pre-cascade, while our own CSVs still exist — and the
    # checker re-derives its own reason later from a cluster where they are gone, so a CRD withheld
    # for a pre-cascade-only reason reads as "recorded by the teardown" with nothing behind it.
    # The argument against, which won: the CRD is withheld either way, so nothing unsafe turns on it.
    # This buys reporting quality at the price of widening a state contract that two scripts read, and
    # a narrow contract is worth more than a richer sentence.
    if [[ -n "$CRDS_SHARED" ]]; then
      STATE_SNAPSHOT="${STATE_SNAPSHOT}"$'\n'"crds_shared=$(printf '%s\n' "$CRDS_SHARED" | awk -F'|' '$1 != "" {print $1}' | tr '\n' ',' | sed 's/,$//')"
    fi
    # WHEN the list was taken, written alongside it and never inferred from it. A list captured after
    # the cascade is a fragment (measured: 17 of 165), and a fragment presented as complete is worse
    # than no list at all — ogsr-check-clean.sh reads this key and refuses its "exact" mode without it.
    # An older dump carries no such key, which is exactly the "cannot verify" answer that dump deserves.
    if [[ -n "$CRDS_CAPTURE_PHASE" ]]; then
      STATE_SNAPSHOT="${STATE_SNAPSHOT}"$'\n'"crds_created_capture=${CRDS_CAPTURE_PHASE}"
    fi
    if printf '%s\n' "$STATE_SNAPSHOT" > "$STATE_DUMP" 2>/dev/null; then
      ok "install state saved to ${STATE_DUMP}"
    else
      err "could not write the install-state dump to ${STATE_DUMP} — ogsr-check-clean.sh will run without it"
    fi
  fi
  sub carry_residue_or_delete_state_ns
  # No longer "always ≥1 element": carry_residue_or_delete_state_ns KEEPS the namespace when this
  # teardown has residue to confess, so the array can be empty here. Under `set -u`, "${arr[@]}" on an
  # empty array is an unbound-variable FATAL on bash 3.2 — which is what macOS still ships and what
  # `env bash` resolves to on a stock admin laptop. Guard on the count, which is safe on every bash.
  if [[ "${#DELETED_WS_NS[@]}" -gt 0 ]]; then
    sub report_stuck_namespaces "${DELETED_WS_NS[@]}"
  fi
  return 0
}

# ── the residue receipt ───────────────────────────────────────────────────────
# The one place ${STATE_NS} is removed, and the one place it is kept. See the residue ledger's header
# for why: the state ConfigMap is the ONLY record of the org's prior values, so deleting it is honest
# exactly when this run put every one of them back. With residue, the ConfigMap is PRUNED to the
# unrestored keys and the namespace stays as the receipt for a trace that is already on the cluster.
#
# Pruned, not left whole, on purpose: every other key (op_*, og_*, installed_stacks, node lists…)
# describes objects this teardown DID remove, and carrying them would make the next install believe a
# previous workshop is still live. What survives is the minimum that is still true.
#
# A residue key with NO recorded value is left UNSET here rather than written empty: for
# gitops_argocd_controller_resources_b64 absence is the encoding for "the CR carried no explicit
# resources", and residue_keys is what turns that absence from missing into authoritative — see
# install.sh's record_once, which refuses to fill any key named in residue_keys.
carry_residue_or_delete_state_ns() {
  local k v n=0
  local -a args
  if [[ -z "$RESIDUE_KEYS" ]]; then
    sub del_obj namespace "$STATE_NS"
    DELETED_WS_NS+=("$STATE_NS")
    return 0
  fi

  n="$(printf '%s' "$RESIDUE_KEYS" | grep -c . || true)"
  err "KEEPING ${STATE_NS}: ${n} prior value(s) this teardown could NOT put back"
  printf '%s\n' "$RESIDUE_NOTES" | while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    echo "      ↳ ${k}"
  done
  echo "   The workshop's own value is still on the org's cluster, so this teardown did not leave it"
  echo "   trace-free. ${STATE_NS}/${STATE_CM} is kept holding ONLY those prior values, because it is"
  echo "   the only record of them: delete it and the next install snapshots OUR value as the org's."
  echo "   Apply the restores above, then:  oc delete namespace ${STATE_NS}"

  # THE WORKSHOP'S OWN MaaS KEY MUST NOT SURVIVE THIS BRANCH (F-3, measured 2026-08-07).
  # install.sh creates secrets/ogsr-maas-credentials in STATE_NS. The delete branch above takes it
  # with the namespace, so this was invisible until a run ended with residue: that path KEEPS the
  # namespace for the prior values, and a live model credential rode along on a cluster the teardown
  # had just reported clean. Nobody reading "uninstall complete" expects a key to remain.
  # It is deleted, not carried: a residue key is by definition the ORG'S prior value, and this
  # Secret is ours — it can never be something this teardown owes anyone back.
  sub del_obj secret ogsr-maas-credentials "$STATE_NS"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   • WOULD keep ${STATE_NS} and prune ${STATE_CM} to: $(printf '%s' "$RESIDUE_KEYS" | tr '\n' ' ' | xargs || true)"
    return 0
  fi

  args=(create configmap "$STATE_CM" -n "$STATE_NS")
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    v="$(state "$k")"
    # Absent stays absent — writing "" would destroy the empty-prior encoding (see the header).
    [[ -n "$v" ]] || continue
    args+=("--from-literal=${k}=${v}")
  done <<< "$RESIDUE_KEYS"
  args+=("--from-literal=residue_keys=$(printf '%s' "$RESIDUE_KEYS" | tr '\n' ',' | sed 's/,$//')")
  args+=("--from-literal=residue_notes=${RESIDUE_NOTES}")
  args+=("--from-literal=residue_recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  args+=("--from-literal=residue_readme=This ConfigMap is what is LEFT of an ogsr-uninstall run: the prior values of objects the workshop changed and the teardown could not put back. Each key is the ORG'S value, never the workshop's. Do not delete it while residue_notes lists an unapplied restore — a re-install would then record the workshop's own leftovers as the org's originals. Apply every restore in residue_notes, then: oc delete namespace ${STATE_NS}")

  # Delete-then-create, not apply: apply 3-way-merges against the last-applied annotation install.sh
  # wrote and would KEEP every key we are pruning away.
  oc delete configmap "$STATE_CM" -n "$STATE_NS" --ignore-not-found >/dev/null 2>&1 || true
  if oc "${args[@]}" >/dev/null 2>&1; then
    oc label configmap "$STATE_CM" -n "$STATE_NS" "$OWNER_LABEL" --overwrite >/dev/null 2>&1 || true
    ok "pruned ${STATE_NS}/${STATE_CM} to the ${n} unrestored prior value(s) and kept the namespace"
    return 0
  fi
  err "could not write the residue ConfigMap ${STATE_NS}/${STATE_CM} — the prior values below are now"
  err "   recorded NOWHERE. Save them by hand before the next install:"
  printf '%s\n' "$RESIDUE_NOTES" >&2
  return 1
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
# step 5 resolve CSVs through the memo it fills. Read-only, so it also runs in --dry-run — which is
# what lets the plan name the exact CSVs a real run would remove.
info "capturing operator CSV identity before anything can delete a Subscription"
capture_installed_csvs

# Same reasoning, same moment: Group/workshop-attendees is rendered by the workshop-config Application,
# so step 3's cascade removes it, and step 4 needs the exact usernames it named to identify a Dev Spaces
# namespace as ours. Read-only, so it also runs in --dry-run.
info "capturing attendee usernames before the cascade can remove Group/workshop-attendees"
capture_attendee_users

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

run_step "[1/10] stopping reconciliation on workshop Argo Applications" step_stop_reconciliation

# Operands the operator created for ITSELF, which Argo therefore never tracked and no cascade can
# prune. They must go while their operator is still running to process their finalizers, and that
# window closes the moment step 3 starts. After step 1 (nothing re-creates them), before step 3 (the
# controllers are all still up) — see § operator-created operands for the TektonConfig that survived a
# "successful" uninstall with 18 pods and a bound PVC and nothing left that would ever remove it.
run_step "[2/10] deleting operator-created operands while their operators are still running" \
  step_delete_operator_operands

# CASCADE-delete our apps: deleting the Application IS the uninstall. Argo removes what it installed,
# in reverse sync-wave order, so each operator is still running when its own operand CR is deleted and
# that CR's finalizer can complete — which is also how the operator's webhooks and APIServices get
# removed at the source instead of being swept up afterwards. The previous --cascade=orphan protected
# adopted operators by exempting EVERYTHING, which threw away Argo's ordering and forced the
# incomplete bash re-implementation below it; adopted resources are now exempted individually.
run_step "[3/10] cascade-deleting workshop Argo Applications (Argo prunes what it installed)" \
  cascade_delete_applications

# Dev Spaces namespaces auto-provisioned for our attendees (#84). Placed HERE, before step 5 deletes
# the Dev Spaces CSV: the CSV owns the operator's Deployment, not the Subscription the cascade just
# removed, so the controller is still running now and any DevWorkspace finalizer in an attendee
# namespace has its one real chance to clear. See the step's own header for the full reasoning.
run_step "[4/10] removing Dev Spaces namespaces auto-provisioned for our attendees" \
  step_remove_devspaces_namespaces

# CSVs for operators WE created. The cascade already pruned their Subscriptions (those ARE in our
# component manifests), but a CSV is created by OLM from the Subscription, never by Argo, so nothing
# prunes it — deleting a Subscription deliberately leaves its CSV and the running operator behind.
# This is the one operator-removal step GitOps cannot do for us — and the one that must not depend on
# the Subscription still being there, because by now it usually is not (§ operator CSV identity). The
# Subscription delete remains for the degraded-Argo / imperative case.
run_step "[5/10] removing CSVs for operators we created (adopted operators preserved)" \
  cleanup_created_operators

run_step "[6/10] reversing imperative cluster mutations (OAuth IdP, console plugins, monitoring, nodes, htpasswd)" \
  step_reverse_cluster_mutations

run_step "[7/10] Gateway API" step_gateway_api

run_step "[8/10] deleting owner-labeled cluster RBAC that no Application manages" step_cluster_rbac

run_step "[9/10] GitOps operator (removed only if we created it)" handle_gitops

run_step "[10/10] deleting workshop namespaces (org / adopted-operator namespaces preserved + de-labeled)" \
  step_delete_namespaces

# The step ledger and the closing verdict are printed by the EXIT trap, so they are emitted on an early
# death too. What follows is guidance that is worth having either way.
echo
echo "   Operators create CRDs, APIServices and admission webhooks at runtime, so no GitOps teardown"
echo "   can own them. The checker reports those with the exact removal command for each, and exits 0"
echo "   once nothing remains. Deciding what to remove is yours — deleting a CRD deletes every instance"
echo "   of it cluster-wide, including any the org created."
echo "   Which is why a CRD another operator ALSO owns, or that still has an instance outside the"
echo "   namespaces this teardown removed, is never offered: it is listed under SHARED CRDs above and"
echo "   carried in the state dump as crds_shared. Inspect those with 'oc get <crd> -A' and decide by"
echo "   hand; there is no cluster on which this script will hand you a delete command for one."
cat <<'VERIFY'

   Spot-check by hand if you prefer:
     oc get ns -l workshop.redhat.com/owner=ogsr                 # expect: no resources
     oc get applications -n openshift-gitops | grep -E 'pp-|entry-|workshop-config'   # expect: none
     oc get clusterrole,clusterrolebinding -l workshop.redhat.com/owner=ogsr          # expect: none
     # Cluster-scoped and hook-created (shared-cockpit front door), so no cascade could have pruned it;
     # a leftover here is a standing OAuth grant on the org's cluster, not merely litter:
     oc get oauthclients.oauth.openshift.io -l workshop.redhat.com/owner=ogsr         # expect: none
     # Operands their operator created for ITSELF: no Argo Application owns them, so only step [2/10]
     # can remove them, and a leftover here is a whole product still running with nothing managing it
     # (measured: TektonConfig alive with 18 pods and a bound 1Gi PVC after a "successful" teardown):
     oc get tektonconfig 2>/dev/null   # expect: no resources — unless the org installed Pipelines themselves
     oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'; echo       # expect: workshop-users absent
     oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'; echo  # expect: names WE added absent, everything else preserved
     # Adopted operators must still be Present/Succeeded:
     oc get csv -A | grep -Ev 'ogsr'                             # org operators intact
     # A CSV that no Subscription installs is an ORPHAN — step [5/10] above deletes only the CSVs the
     # state records as ours, so anything it could not authorise is still here, and a leftover CSV
     # makes the NEXT install fail to resolve that operator. Section [3/9] of ogsr-check-clean.sh
     # names them with the removal command; by hand it is the difference of two lists:
     comm -23 \
       <(oc get csv -A -l '!olm.copiedFrom' -o custom-columns=NS:.metadata.namespace,CSV:.metadata.name --no-headers | awk '{print $1"/"$2}' | sort) \
       <(oc get subscriptions.operators.coreos.com -A -o custom-columns=NS:.metadata.namespace,CSV:.status.installedCSV --no-headers | awk '{print $1"/"$2}' | sort)
     # expect: only openshift-operator-lifecycle-manager/packageserver, which the cluster itself
     # installs with no Subscription. Anything else is an orphan — check WHOSE before deleting it:
     # in an adopted operator's namespace it is the org's operator, and deleting it uninstalls them.
VERIFY
