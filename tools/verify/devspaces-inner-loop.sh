#!/usr/bin/env bash
# Verify devspaces-inner-loop — Dev Spaces & the Inner Loop.
#   Entry: {user}-dev has the claims app + PostgreSQL (build-deliver end state, composed directly);
#          a per-user Gitea fork of parasol-claims exists; entry marker + quota present.
#   End:   the attendee started THE parasol-claims workspace — it lives in {user}-devspaces, which is
#          Dev Spaces' per-user project and therefore shared with every other module's workspace.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
WS_NS="${USER_NAME}-devspaces"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# gitea_host() (route if readable, else derived from the cluster ingress domain — attendees can't
# read routes in the gitea namespace) is shared — tools/verify/_lib.sh. GLOBAL, not echo-shaped: call
# it bare and read $GITEA_HOST, never `$(gitea_host)` (that would strand VERIFY_INCONCLUSIVE in a
# subshell).

# The per-user fork exists → the Gitea API answers 2xx for {user}/parasol-claims.
fork_exists() {
  gitea_host || return 1
  curl -ksf -o /dev/null "https://${GITEA_HOST}/api/v1/repos/${USER_NAME}/parasol-claims"
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# The claims Route answers HTTP 200 on the readiness endpoint. NOTE: parasol-claims is an
# API-only service — "/" returns 404 by design, so we probe /q/health/ready (and it also
# proves the app reached its datasource, since readiness gates on the DB connection).
# The Route read is oc_present in THIS shell (never `$(…)`, which would strand VERIFY_INCONCLUSIVE in a
# subshell): a Route the API could not be asked about is not a missing Route, and grading it ❌ blames
# the attendee for a cluster blip.
route_ready_200() {
  local ns="$1" host code
  oc_present get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# --- did the attendee actually START THE parasol-claims WORKSPACE? -----------
# THE NAMESPACE IS NOT THE END STATE. Dev Spaces auto-provisions {user}-devspaces on first DASHBOARD
# LOGIN — CheCluster/devspaces carries devEnvironments.defaultNamespace.autoProvision=true with
# template `<username>-devspaces` (read off the cluster 2026-08-01) — so an attendee who opened the
# dashboard and did nothing else collected a full green for a lab they never ran.
# What appears only when a workspace is STARTED is what the DevWorkspace controller creates for it: a
# Deployment, its pod, and its PVC. ConfigMaps/Secrets/ServiceAccounts are deliberately NOT in that
# list — Che provisions several of those at namespace-creation time, so they exist before any
# workspace runs (its namespace configurators create Secrets, ConfigMaps, a ServiceAccount and RBAC,
# and nothing else: eclipse-che/che-server …/namespace/configurator/).
#
# AND "SOMETHING IS IN THAT NAMESPACE" IS NOT THE END STATE EITHER — this is the false ✅ this block
# was rewritten for (audit F-06, 2026-08-05). {user}-devspaces is DEV SPACES' PER-USER WORKSPACE
# NAMESPACE, not this module's: every workspace this attendee ever runs lands in it, from any module
# or from the dashboard's own sample catalogue. app-modernization's lab sends them into Dev Spaces on
# a different fork (parasol-legacy-claims) and says so in as many words — "Dev Spaces provisions your
# workspace in its own {user}-devspaces namespace" (app-modernization/lab.adoc §"AI path") — while its
# ws-meta declares NO conflictsWith and purges only {user}-modernize. So that workspace's Deployment
# and Pod, and the shared per-user PVC (claim-devworkspace, pvcStrategy per-user) that outlives it,
# sit in this namespace with devspaces-inner-loop's entry app still materialized and untouched. A
# namespace-wide "is anything here" read then prints "✅ the parasol-claims workspace has been
# started" to an attendee who never opened it — the whole module, silently ungraded.
# Every signal below is therefore SCOPED TO parasol-claims.
# Rights in that namespace come from Dev Spaces, not from the workshop's per-user RBAC (which covers
# only {user}-dev|stage|prod|cicd) — and they ARRIVE WHEN CHE ADOPTS THE NAMESPACE, i.e. at the
# attendee's first dashboard sign-in, NOT at `ws prep`. Measured on cluster 2026-08-05 on a
# freshly-prepped user5-devspaces: `oc get rolebinding -n user5-devspaces` listed only DWO/OpenShift
# defaults (devworkspace-default-rolebinding, image-puller, system:deployers, …) — NO cheworkspaces
# binding for user5 — and the four reads below answered Forbidden as {user}. That is expected and it
# is why the rc=2 branch exists: an attendee who runs `ws verify` BEFORE opening Dev Spaces gets ⚠
# "could not check", never a ✅ and never a ❌. By the time the end state is real they have signed in
# (that IS exercise 1), so the reads answer. Grounded on cluster 2026-08-01: cm/che in openshift-devspaces sets
# CHE_INFRA_KUBERNETES_USER__CLUSTER__ROLES=openshift-devspaces-cheworkspaces-clusterrole,
# openshift-devspaces-cheworkspaces-devworkspace-clusterrole, and Che RoleBinds exactly those two into
# {user}-devspaces when it auto-provisions it. The first carries `list` on pods, apps/deployments and
# PVCs (plus events, which the troubleshooting page tells attendees to read); the second carries
# get/list/watch/create/update/patch/delete on devworkspaces AND devworkspacetemplates.
# NOT devspaces-edit / devspaces-view: those two ship with the operator but have ZERO bindings on the
# cluster (0 ClusterRoleBindings, 0 RoleBindings) and are named nowhere in the Che config, so they
# grant nobody anything. An earlier revision of this comment named them as the source of the rights
# and inferred from that a refusal which cannot happen.
# So the rc=2 branch below has exactly TWO causes, and the 2026-08-05 measurement above added the
# first: the attendee has not opened Dev Spaces yet, so Che has not adopted the namespace and bound
# those two roles — ORDINARY, and it means "not gradeable yet", not "broken"; or the API could not be
# asked at all. Either way a read that could not be answered has to be an explicit "cannot grade",
# never a silent pass. (An earlier revision of this comment asserted the refusal "cannot happen";
# it can, routinely, for anyone who verifies before exercise 1.)

# Read one resource in the workspace namespace and CLASSIFY the server's answer. Deliberately not
# `oc auth can-i`: run by an instructor or CI the caller is cluster-admin, so can-i would answer for
# THEM and skip (or mis-grade) the check on the attendee's behalf.
# Caller passes the whole `oc get …` argument list EXCEPT `-n <ns>`, which is added here — so a
# caller chooses its own selector and output format (`-o name`, `-o jsonpath=…`).
# stdout: whatever the read produced, possibly empty. return: 0 = read succeeded · 1 = Forbidden ·
# 2 = other error (including NotFound — a caller that cares distinguishes it by what it asked for).
ws_ns_read() {  # ws_ns_read <oc get args…>
  local rc=0 tmp="/tmp/.devspaces-read.$$"
  oc get "$@" -n "$WS_NS" 2>"$tmp" || rc=$?
  if (( rc != 0 )); then
    if grep -qi forbidden "$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"; return 2
  fi
  rm -f "$tmp"
  return 0
}

# The workspace this module is about, and the label the DevWorkspace controller stamps on everything
# it creates for it. Grounded in the operator's own source, not recalled: the label constants are
# devfile/devworkspace-operator pkg/constants/metadata.go (DevWorkspaceNameLabel =
# "controller.devfile.io/devworkspace_name", DevWorkspaceIDLabel = "…/devworkspace_id"), and
# pkg/provision/workspace/deployment.go sets BOTH on the workspace Deployment and on its pod
# template. That label is what turns "something is in this namespace" into "THIS workspace ran".
# The shared per-user PVC (claim-devworkspace, pvcStrategy per-user) carries no such label, which is
# exactly right: it is created for whichever of the attendee's workspaces starts first and outlives
# all of them, so it is evidence about the USER, never about this workspace.
DW_NAME="parasol-claims"
DW_SELECTOR="controller.devfile.io/devworkspace_name=${DW_NAME}"

# 0 = the parasol-claims workspace was actually STARTED · 1 = it is declared but has never run ·
# 2 = none of the signals is readable from here, so the end state is not gradeable.
#
# TWO kinds of evidence, in the order this suite's rule puts them — grade the DECLARATION the
# attendee wrote, corroborate with the OBSERVATION:
#
#   (1) DECLARATION. Clicking the workspace on the dashboard writes spec.started:true on THIS
#       DevWorkspace. That is the attendee's own act, and it is true from the click onward — before
#       the controller has created anything, which is the first ~20-90s of a start.
#       NOT the DevWorkspace's EXISTENCE: since 2026-08-02 the entry chart declares it with
#       spec.started:false, so `oc get devworkspace parasol-claims` succeeding proves only that
#       `ws prep` ran. That is asserted as an ENTRY check above, which is where it belongs.
#   (2) OBSERVATION. What the controller created FOR THIS WORKSPACE, label-scoped. This survives Dev
#       Spaces' idle auto-stop, which sets spec.started back to false and scales the Deployment to
#       zero replicas without deleting it (devworkspace_controller.go doStop → ScaleDeploymentToZero),
#       so an attendee who finished the lab an hour ago still grades ✅.
#
# Either one ALONE would be wrong in one direction: the declaration disappears on an idle stop, and
# the observation does not exist yet in the opening seconds of a start. Both are scoped to
# parasol-claims, so neither can be satisfied by another module's workspace sharing this namespace.
workspace_started() {
  local kind names rc readable=0 started phase wsid=""

  # (1) the declaration. Fields are separated by a LITERAL '|' inside the jsonpath, not by spaces:
  # .status.phase is empty on a freshly-created DevWorkspace, and whitespace-splitting an empty
  # middle field silently shifts the workspace ID into it.
  rc=0; names="$(ws_ns_read devworkspace "$DW_NAME" -o jsonpath='{.spec.started}|{.status.phase}|{.status.devworkspaceId}')" || rc=$?
  if (( rc == 0 )); then
    readable=1
    IFS='|' read -r started phase wsid <<<"$names" || true
    if [[ "$started" == "true" || "$phase" == "Running" || "$phase" == "Starting" ]]; then return 0; fi
  fi

  # (2) the observation, scoped TWO independent ways so a narrowing that is wrong about this
  # cluster's operator build cannot manufacture a false ❌ on an attendee who did the lab:
  #   • the controller's own label (above), and
  #   • the workspace ID, which the controller bakes into the names of the objects it creates
  #     (Deployment `workspace<id>`, its pods below that). The ID is unique per workspace and is
  #     read off THIS DevWorkspace's status, so an ID match is as exact as a label match.
  # A match on either is evidence; a match on neither, with the reads answering, is a real ❌.
  # NOTE the deliberate asymmetry with the unscoped read this replaced: an UNSCOPED name that
  # happens to contain nothing of ours is skipped, so another module's workspace never counts.
  for kind in deployments pods persistentvolumeclaims; do
    rc=0; names="$(ws_ns_read "$kind" -l "$DW_SELECTOR" -o name)" || rc=$?
    if (( rc == 0 )); then
      readable=1
      if [[ -n "$names" ]]; then return 0; fi
    fi
    [[ -n "$wsid" ]] || continue
    rc=0; names="$(ws_ns_read "$kind" -o name)" || rc=$?
    if (( rc == 0 )); then
      readable=1
      if echo "$names" | grep -qF -- "$wsid"; then return 0; fi
    fi
  done
  if (( readable == 0 )); then return 2; fi
  return 1
}

# --- entry state (what `ws start devspaces-inner-loop` materializes) --------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                              || hint "run: ws start devspaces-inner-loop --user ${USER_NAME}"
check "entry marker ws-entry-devspaces-inner-loop present"            oc get cm ws-entry-devspaces-inner-loop -n "$NS"              || hint "entry app not synced — ws start devspaces-inner-loop --user ${USER_NAME}"
check "workshop quota present in ${NS}"              oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea fork ${USER_NAME}/parasol-claims exists" fork_exists                                 || hint "fork job didn't run — ws reset devspaces-inner-loop --user ${USER_NAME} (or check the gitea-fork-devspaces-inner-loop-${USER_NAME} Job in ns gitea)"
check "claims-db deployment has >=1 ready replica"   deploy_ready claims-db "$NS"                 || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica" deploy_ready parasol-claims "$NS"         || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "route parasol-claims answers 200 (/q/health/ready)" route_ready_200 "$NS"                  || hint "claims app not ready — check: oc get pods -n ${NS}"

# The workspace namespace and the DevWorkspace are ENTRY state now, not evidence of attendee work.
# They used to be checked only at the end, on the reasoning that the namespace proves the attendee
# signed in — Dev Spaces creates it on first sign-in. That inference died when the entry chart
# started creating both (2026-08-02): the factory URL the lab used cannot work against Gitea, which
# Dev Spaces does not support, so `ws prep` now declares the workspace instead. A check still worded
# "you signed in to the dashboard" would assert something the cluster cannot show.
#
# AND ENTRY MODE DELIBERATELY DOES NOT ASSERT "the workspace has NOT been started" — do not add it as
# the mirror image of the end-state check below. `ws doctor --user U` runs --entry-only against every
# materialized entry app, and it only switches to --solve for apps an instructor `ws solve`d; a lab
# the attendee completed BY HAND still gets graded in entry mode. A negation here would therefore red
# doctor for everyone who finished this module, which is a false ❌ bought for nothing: every entry
# assertion in this script is a `ws prep` artefact that survives completion, on purpose.
check "Dev Spaces namespace ${WS_NS} exists"          oc get ns "$WS_NS"                          || hint "entry app not synced — ws prep devspaces-inner-loop --user ${USER_NAME}"
check "workspace parasol-claims is declared in ${WS_NS}" oc get devworkspace parasol-claims -n "$WS_NS" || hint "the entry state defines this workspace; if it is missing the chart did not apply — ws reset devspaces-inner-loop --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab looks like) ---------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  # The attendee's own act is STARTING the parasol-claims workspace: that sets its spec.started and
  # leaves the controller's own Deployment/Pod behind, both scoped to it by name. The entry check
  # above proves only that prep DECLARED it. Other workspaces in this same namespace — Dev Spaces
  # gives the attendee ONE for all modules — are deliberately not evidence.
  WS_DESC="the parasol-claims workspace has been started (its own pods or workload exist in ${WS_NS})"
  ws_rc=0; workspace_started || ws_rc=$?
  case "$ws_rc" in
    0) check "$WS_DESC" true ;;
    1) check "$WS_DESC" false \
         || hint "not done yet — the workspace is declared but has never run, which is exactly the state ws prep leaves it in: STARTING it is lab exercise 1. Open the Dev Spaces dashboard and click the parasol-claims workspace. Nothing is broken here — and note that a workspace you started for ANOTHER module lives in this same project and does not count for this one" ;;
    *) warn "the end state is not gradeable from here — none of the parasol-claims workspace's signals in ${WS_NS} (its DevWorkspace, and the Deployments/Pods/PVCs the controller labels with its name) is readable as this identity"
       hint "usually this just means you have not opened Dev Spaces yet: it grants you these reads in ${WS_NS} when it adopts the project at your first dashboard sign-in, which is lab exercise 1 — so nothing is wrong, this check simply has no verdict yet. If you HAVE signed in and still land here, the API could not be asked or that grant is missing: retry, then show your instructor 'oc get rolebinding -n ${WS_NS}'. Either way, the dashboard tells you directly whether your parasol-claims workspace is running" ;;
  esac
fi

verify_summary
