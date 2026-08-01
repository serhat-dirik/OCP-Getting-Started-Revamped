#!/usr/bin/env bash
# Verify resilience-multicluster-dr — Resilience, Multi-Cluster & DR (APPLICATION-LEVEL cross-site failover).
#   Entry: three per-user namespaces, all istio-discovery=enabled (mesh tenants). {user}-site-a and
#          {user}-site-b each run a RESILIENT claims service (parasol-claims: >=2 replicas + PDB + HPA +
#          topologySpread + probes, meshed), echoing SITE=A / SITE=B. {user}-client runs the external
#          curl-loop client and the mesh ingress gateway (the stable endpoint). NO failover routing yet —
#          the stable endpoint 404s until the attendee wires it. Entry marker set.
#   End:   the attendee built the cross-site failover routing on OSSM3 — a ServiceEntry + DestinationRule
#          (locality LB + outlier detection) + a VirtualService on the gateway (retries) — and then FAILED
#          THE PRIMARY SITE (lab exercise 2: `oc scale deploy/parasol-claims -n {user}-site-a --replicas=0`)
#          and watched the client keep getting 200s from site-b. The graded OUTCOME, mechanism-agnostic
#          (rule 14: assert the outcome, not the CRs): routing is wired, the stable endpoint serves, and
#          the client WAS ACTUALLY SERVED BY SITE B at some point after the routing went in.
# Runnable as the ATTENDEE: reads/execs only client/site-a/site-b objects the attendee sees via namespace
# admin (istio CRDs aggregate to the admin role). The G1 cockpit smoke runs `--entry-only` as {user}.
#
# MESH NOTE: OSSM3 1.28 injects the sidecar as a NATIVE SIDECAR (istio-proxy is an initContainer). The
# claims responder + client run on always-present platform imagestreams (nodejs / tools), so readiness is
# asserted directly — there is no parasol-image build gap here.
#
# ── MUTATION POLICY ───────────────────────────────────────────────────────────────────────────────
# THIS SCRIPT DOES NOT TOUCH THE ATTENDEE'S WORKLOADS. Not at entry, not at end, not under `--solve`.
#
# It used to. Until 2026-08-01 the end-state path proved failover by RE-ENACTING it: it scaled site-a to
# 0, polled for a site-b response, then scaled it back under an EXIT trap. Three things were wrong with
# that, and they are separable:
#
#   1. `ws verify` is the ATTENDEE'S OWN feedback loop, run mid-lab, often in a second terminal while the
#      first one tails the client log. Asking "is my work correct?" must never take the primary site down.
#   2. The EXIT trap was installed UNCONDITIONALLY at the top of the end-state branch, before the drill's
#      own prerequisite guard — and with SITEA_RESTORE still empty, so it fired `--replicas=${…:-3}` on
#      EVERY end-mode exit, including runs that skipped the drill entirely and runs that failed at the
#      first check. So a plain `ws verify` silently rewrote site-a's replica count to 3 whatever it was:
#      it stomped the attendee's own in-progress failover (site-a deliberately at 0) and clipped an
#      HPA-scaled or hand-scaled site back to 3. Measured, not reasoned: a 6-line harness reproducing the
#      trap placement fired the restore on a clean rc-0 run with the drill skipped.
#   3. An EXIT trap is not a guarantee. It DOES run on Ctrl-C (bash executes EXIT traps on SIGINT — also
#      measured), but nothing runs on SIGKILL: an OOM-killed cockpit terminal, a `oc delete pod` on the
#      showroom pod, a node eviction. That leaves the attendee's primary site at zero with no restorer,
#      and the only thing that repairs it is a full `ws prep`/`ws reset` of the module.
#
# The replacement is EVIDENCE, not re-enactment, and it is strictly better grading. claims-client is a
# long-lived once-a-second curl loop that prints `served-by-site=A|B` for every response. A `B` line can
# only be produced by the mesh actually failing over — which is the lab's money step, performed by the
# ATTENDEE. Reading it back grades the attendee's work; performing it for them graded the platform and
# handed a green banner to someone who never ran exercise 2.
#
# The active drill still exists, because `ws solve` renders the routing CRs but never fails a site over —
# so on a machine-solved world there is nothing to observe and a broken outlierDetection would go unseen.
# It is now OPT-IN ONLY (`--failover-drill` / WS_FAILOVER_DRILL=1), refuses to run at `--entry-only`,
# announces exactly what it is about to do, and records its restore intent as an ANNOTATION ON THE
# DEPLOYMENT before it scales — so a SIGKILLed run leaves a diagnosable wreck instead of a mystery, and
# every later run of this script (any mode, including `ws doctor`'s) names it and prints the exact fix.
#
# `ws doctor` CANNOT reach the drill by any path: it invokes `<script> --user U --entry-only` under
# VERIFY_STRICT=1 (tools/ws/ws cmd_doctor) and never forwards a `--failover-drill`. Both guards are
# independent — entry-only refuses it, and absence of the flag never enables it.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# --failover-drill is OURS, not part of the shared contract — parse_verify_args (tools/verify/_lib.sh,
# which this lane does not own) rejects any flag it does not know with exit 2. So filter it out here and
# hand the rest through unchanged. WS_FAILOVER_DRILL=1 is the same opt-in for callers that cannot thread
# an extra flag (CI job steps); neither is ever set by ws itself.
if [[ "${WS_FAILOVER_DRILL:-0}" == "1" ]]; then FAILOVER_DRILL="true"; else FAILOVER_DRILL="false"; fi
_args=()
for _a in "$@"; do
  case "$_a" in
    --failover-drill) FAILOVER_DRILL="true";;
    *) _args+=("$_a");;
  esac
done
parse_verify_args ${_args[@]+"${_args[@]}"}
CLIENT_NS="${USER_NAME}-client"
SITEA_NS="${USER_NAME}-site-a"
SITEB_NS="${USER_NAME}-site-b"
# Set only inside the opt-in drill; the EXIT/INT/TERM trap it installs is scoped to that branch and
# nothing else in this script installs a trap or writes to the cluster.
SITEA_RESTORE=""
DRILL_ANN="workshop.redhat.com/failover-drill-restore"

if [[ "$FAILOVER_DRILL" == "true" && "$ENTRY_ONLY" == "true" ]]; then
  echo "refusing: --failover-drill takes the primary site down, and --entry-only grades a world nobody has started yet" >&2
  echo "   ↳ the entry state has no failover routing, so the drill could only ever fail — drop one of the two flags" >&2
  exit 2
fi

# --- helpers (oc only) -------------------------------------------------------

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# A namespace carries istio-discovery=enabled (the shared-istiod discoverySelectors label): $1=namespace.
ns_discovery_labeled() {
  [[ "$(oc get ns "$1" -o jsonpath='{.metadata.labels.istio-discovery}' 2>/dev/null || true)" == "enabled" ]]
}

# A site's claims service is RESILIENT: the Deployment is present with >=2 desired replicas, a PDB, and an
# HPA (the observability-health-scale/deployment-targets-scheduling primitives the in-site resiliency beat leans on): $1=namespace.
site_resilient() {
  local ns="$1" reps
  oc get deploy parasol-claims -n "$ns" >/dev/null 2>&1 || return 1
  oc get poddisruptionbudget parasol-claims -n "$ns" >/dev/null 2>&1 || return 1
  oc get horizontalpodautoscaler parasol-claims -n "$ns" >/dev/null 2>&1 || return 1
  reps="$(oc get deploy parasol-claims -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  [[ -n "$reps" && "$reps" -ge 2 ]]
}

# Any ServiceEntry AND any VirtualService exist in the client ns (mechanism-agnostic: don't pin the names).
failover_routing_present() {
  [[ -n "$(oc get serviceentry -n "$CLIENT_NS" -o name 2>/dev/null || true)" ]] &&
  [[ -n "$(oc get virtualservice -n "$CLIENT_NS" -o name 2>/dev/null || true)" ]]
}
# Entry clean-slate: NO failover routing yet (attendee builds the ServiceEntry + VirtualService).
# CLIENT_NS must actually exist first — otherwise an empty result is vacuous (true on a cluster
# where nothing materialized at all), not evidence of a clean, correctly-seeded entry state.
no_failover_routing() {
  oc get ns "$CLIENT_NS" >/dev/null 2>&1 || return 1
  [[ -z "$(oc get serviceentry,virtualservice -n "$CLIENT_NS" -o name 2>/dev/null || true)" ]]
}

# When the failover routing first appeared — the anchor for "has a failover happened SINCE?". Oldest
# ServiceEntry wins, so re-editing a VirtualService mid-lab does not shrink the evidence window. Empty
# when there is no routing (the check that needs it is skipped in that case, never failed on it).
routing_since() {
  oc get serviceentry -n "$CLIENT_NS" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || true
}

# The stable endpoint (the ingress gateway) serves HTTP 200 to the client (routing is wired).
stable_serves() {
  local code
  code="$(oc exec deploy/claims-client -n "$CLIENT_NS" -- \
    curl -s -m5 -o /dev/null -w '%{http_code}' http://claims-stable/ 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

# Which SITE (A/B) the stable endpoint currently returns (empty on any failure). Drill-only.
served_site() {
  oc exec deploy/claims-client -n "$CLIENT_NS" -- curl -s -m3 http://claims-stable/ 2>/dev/null \
    | sed -n 's/.*"site":"\([AB]\)".*/\1/p' 2>/dev/null || true
}

# ── the lab's aftermath, read back ────────────────────────────────────────────────────────────────
# The client log IS the record of the failover: claims-client prints one `HTTP <code>  served-by-site=X`
# line a second, forever, from a pod that outlives the whole module (entry-states/…/client-gateway.yaml).
#
# Every flag here is load-bearing and was measured against a live cluster (cluster 2, user2/user8,
# 2026-08-01) rather than assumed:
#   --tail=-1     MANDATORY with a selector. `oc logs -l app=claims-client` returned exactly 10 lines
#                 (kubectl's selector default) against a pod holding 25,193 — a silent 99.96% truncation
#                 that would have made this check a coin flip.
#   --since-time  anchors the window at the routing's creation, so a `B` left in the log by an EARLIER
#                 cycle of the lab (a reset removes the CRs but does NOT restart the client pod — user2
#                 on cluster 2 had 122 stale `B` lines and no ServiceEntry at all) cannot pass a rebuilt
#                 world that never failed over. Narrowed user8's log from 1,272 lines to 1,147.
#   --previous    an in-place container restart (OOM, probe kill) rolls the current log without changing
#                 the pod's startTime, so the pre-restart log is where the evidence would be. It errors
#                 outright when there is no previous container, hence the `|| true`.
client_log_since() {  # $1=RFC3339 anchor → the client's post-anchor log on stdout
  oc logs -l app=claims-client -n "$CLIENT_NS" --tail=-1 --since-time="$1" 2>/dev/null || true
  oc logs -l app=claims-client -n "$CLIENT_NS" --tail=-1 --since-time="$1" --previous 2>/dev/null || true
}

# Cached: the log read is ~1 MB and the branch below asks the question more than once.
LOG_HAS_B=""
failover_evidenced() {  # $1=RFC3339 anchor
  if [[ -z "$LOG_HAS_B" ]]; then
    LOG_HAS_B="no"
    case "$(client_log_since "$1")" in *"served-by-site=B"*) LOG_HAS_B="yes";; esac
  fi
  [[ "$LOG_HAS_B" == "yes" ]]
}

# Is the ABSENCE of a `B` line the attendee's real answer, or just lost evidence? It is only gradeable
# when the pod that holds the log has been running, uninterrupted, since before the routing existed —
# then it cannot have missed the flip. A pod that (re)started after the routing went in, or whose
# container restarted in place, may simply have lost the lines, and failing someone for that is exactly
# the false ❌ this suite exists to prevent. Compared LEXICOGRAPHICALLY: the API's RFC3339 timestamps are
# fixed-width and Z-suffixed, so string order is time order — and it is portable, where `date -d` (GNU)
# vs `date -j` (BSD) is not, and these scripts run both in the cockpit and off a maintainer's macOS.
client_log_is_complete() {  # $1=RFC3339 routing anchor
  local pod_start restarts
  pod_start="$(oc get pods -l app=claims-client -n "$CLIENT_NS" --sort-by=.status.startTime \
    -o jsonpath='{.items[-1:].status.startTime}' 2>/dev/null || true)"
  restarts="$(oc get pods -l app=claims-client -n "$CLIENT_NS" \
    -o jsonpath='{.items[*].status.containerStatuses[?(@.name=="client")].restartCount}' 2>/dev/null || true)"
  [[ -n "$pod_start" ]] || return 1
  [[ "$pod_start" < "$1" ]] || return 1
  # Any non-zero count across the (normally single) client pod disqualifies the window. Written as a
  # full `if` and not `[[ … ]] && return 1`: under `set -e` a failing AND-list inside a function is the
  # shape that silently killed cleanup_created_operators mid-teardown (see CLAUDE.md).
  if [[ "${restarts// /}" =~ [1-9] ]]; then return 1; fi
  return 0
}

# ── stranded-drill detection (READ-ONLY, runs in every mode) ──────────────────────────────────────
# The one thing an EXIT trap can never cover is SIGKILL. If the opt-in drill is ever killed between its
# scale-down and its restore, site-a sits at zero and this annotation is the only record of what it was.
# Reported, never auto-repaired: `ws doctor` and `--entry-only` are diagnostics and must not write to a
# cluster to make their own row green. The attendee/instructor gets the exact command instead.
# The saved count, published for the hint. The hint must print a LITERAL number, never a nested
# `oc get -o jsonpath=…` for the attendee to paste: the annotation key contains dots, so the jsonpath
# needs them backslash-escaped, and an unescaped copy silently returns EMPTY — `--replicas=` with no
# value, a fix instruction that always errors. Read it once here, interpolate the number there.
STRANDED_REPLICAS=""
stranded_drill() {
  local have
  STRANDED_REPLICAS="$(oc get deploy parasol-claims -n "$SITEA_NS" \
    -o jsonpath="{.metadata.annotations.${DRILL_ANN//./\\.}}" 2>/dev/null || true)"
  [[ -n "$STRANDED_REPLICAS" ]] || return 1
  have="$(oc get deploy parasol-claims -n "$SITEA_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  [[ -n "$have" && "$have" -lt "$STRANDED_REPLICAS" ]]
}
# check() needs a predicate that FAILS when the world is wrong, and "stranded" is the wrong world.
not_stranded_drill() { ! stranded_drill; }

# Solve marker (end-state only) lives in the client ns.
solved() { oc get cm ws-solve-resilience-multicluster-dr -n "$CLIENT_NS" >/dev/null 2>&1; }
# CLIENT_NS must actually exist first — otherwise "absent" is vacuous, not evidence of a clean entry.
not_solved() {
  oc get ns "$CLIENT_NS" >/dev/null 2>&1 || return 1
  ! solved
}

# ── the opt-in active drill ───────────────────────────────────────────────────────────────────────
# The ONLY thing in this file that writes to the cluster, and it runs only when a human or a CI step
# asked for it by name. Save site-a's replica count ON THE OBJECT, scale it to 0 ("the site fails"),
# confirm the client is still served — by site-b — through the stable endpoint, then restore and wait.
# >= semantics: a single site-b response is a pass.
# ws-mutation-optin: takes the primary site down; only --failover-drill or WS_FAILOVER_DRILL=1 asks
#   for it, it refuses --entry-only, and ws doctor cannot reach it by any path. Everything else in
#   tools/verify/ is read-only and tools/lint/verify-mutation-guard.sh enforces that.
failover_drill() {
  local orig site deadline got_b=0
  orig="$(oc get deploy parasol-claims -n "$SITEA_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 3)"
  [[ -n "$orig" && "$orig" -ge 1 ]] || orig=3
  SITEA_RESTORE="$orig"
  # Durable restore intent BEFORE the scale. An in-shell variable dies with the shell; this does not,
  # which is what turns a SIGKILLed drill from an unexplained zero into a one-line fix.
  oc annotate deploy/parasol-claims -n "$SITEA_NS" --overwrite "${DRILL_ANN}=${orig}" >/dev/null 2>&1 || true
  # INT/TERM/HUP as well as EXIT: bash does run EXIT traps on SIGINT, but naming the signals costs
  # nothing and documents the intent. Nothing covers SIGKILL — that is what the annotation is for.
  trap 'oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas="${SITEA_RESTORE:-3}" >/dev/null 2>&1 || true' EXIT INT TERM HUP
  oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas=0 >/dev/null 2>&1 || true
  deadline=$(( $(date +%s) + 45 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    site="$(served_site)"
    if [[ "$site" == "B" ]]; then got_b=1; break; fi
    sleep 3
  done
  oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas="$orig" >/dev/null 2>&1 || true
  oc rollout status deploy/parasol-claims -n "$SITEA_NS" --timeout=60s >/dev/null 2>&1 || true
  # Restored: drop the marker so a later run does not report a stranded drill that no longer exists.
  oc annotate deploy/parasol-claims -n "$SITEA_NS" "${DRILL_ANN}-" >/dev/null 2>&1 || true
  # DISARM. Left armed, the trap fires again at verify_summary's exit and re-scales site-a a second
  # time — harmless the day it was written, but it re-applies a now-stale count AFTER the marker is
  # gone, so an HPA that scaled the site up in between would be clipped back by a verify script that
  # is supposed to be finished. Caught by counting the stubbed oc calls: six writes where five were
  # intended. Nothing below here may write to the cluster.
  trap - EXIT INT TERM HUP
  [[ "$got_b" == "1" ]]
}
# ws-mutation-optin-end

# --- shared checks (hold at BOTH entry and end) ------------------------------
# First, because it changes how every check below should be read: a site-a sitting at zero because an
# opt-in drill was killed is not a lab mistake, and "wait for rollout" is the wrong advice for it.
if stranded_drill; then
  check "site-a is NOT stranded at zero by an interrupted failover drill" not_stranded_drill \
    || hint "an opt-in --failover-drill was killed before it could restore the primary site (nothing runs on SIGKILL). It was at ${STRANDED_REPLICAS} replicas — restore it, then clear the marker: oc scale deploy/parasol-claims -n ${SITEA_NS} --replicas=${STRANDED_REPLICAS} && oc annotate deploy/parasol-claims -n ${SITEA_NS} ${DRILL_ANN}-"
fi
check "namespace ${CLIENT_NS} exists"                  oc get ns "$CLIENT_NS"                   || hint "run: ws prep resilience-multicluster-dr (or ws start resilience-multicluster-dr --user ${USER_NAME}); the three namespaces are workshop-layer (per-user-resilience)"
check "namespace ${SITEA_NS} exists"                   oc get ns "$SITEA_NS"                    || hint "the ${SITEA_NS} namespace is workshop-layer — sync gitops/workshop-config (per-user-resilience.yaml)"
check "namespace ${SITEB_NS} exists"                   oc get ns "$SITEB_NS"                    || hint "the ${SITEB_NS} namespace is workshop-layer — sync gitops/workshop-config (per-user-resilience.yaml)"
check "${CLIENT_NS} is istio-discovery=enabled (mesh tenant)" ns_discovery_labeled "$CLIENT_NS" || hint "the workshop layer must label ${CLIENT_NS} istio-discovery=enabled — sync per-user-resilience.yaml"
check "${SITEA_NS} is istio-discovery=enabled (mesh tenant)"  ns_discovery_labeled "$SITEA_NS"  || hint "the workshop layer must label ${SITEA_NS} istio-discovery=enabled — sync per-user-resilience.yaml"
check "${SITEB_NS} is istio-discovery=enabled (mesh tenant)"  ns_discovery_labeled "$SITEB_NS"  || hint "the workshop layer must label ${SITEB_NS} istio-discovery=enabled — sync per-user-resilience.yaml"
check "entry marker ws-entry-resilience-multicluster-dr present"              oc get cm ws-entry-resilience-multicluster-dr -n "$CLIENT_NS"   || hint "entry app not synced — ws reset resilience-multicluster-dr --user ${USER_NAME}"
check "site-a claims service is RESILIENT (>=2 replicas + PDB + HPA)" site_resilient "$SITEA_NS" || hint "the primary site must be resilient — ws reset resilience-multicluster-dr --user ${USER_NAME}"
check "site-b claims service is RESILIENT (>=2 replicas + PDB + HPA)" site_resilient "$SITEB_NS" || hint "the secondary site must be resilient — ws reset resilience-multicluster-dr --user ${USER_NAME}"
check "site-a claims has >=1 ready replica"            deploy_ready parasol-claims "$SITEA_NS"   || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${SITEA_NS}"
check "site-b claims has >=1 ready replica"            deploy_ready parasol-claims "$SITEB_NS"   || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${SITEB_NS}"
check "external client (claims-client) has >=1 ready replica" deploy_ready claims-client "$CLIENT_NS" || hint "the client loop isn't up — oc get pods -l app=claims-client -n ${CLIENT_NS}"
check "mesh ingress gateway (claims-gateway) has >=1 ready replica" deploy_ready claims-gateway "$CLIENT_NS" || hint "the stable endpoint isn't up — oc get pods -l istio=claims-gateway -n ${CLIENT_NS}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — sites up, gateway up, but NO failover routing wired yet ----------------
  check "no failover routing yet (attendee builds ServiceEntry + VirtualService)" no_failover_routing \
    || hint "entry ships no failover routing; if a ServiceEntry/VirtualService exists the lab already ran — ws reset resilience-multicluster-dr --user ${USER_NAME}"
  check "no solve marker yet (ws-solve-resilience-multicluster-dr absent)"    not_solved \
    || hint "a solve/end marker exists; the lab already ran — ws reset resilience-multicluster-dr --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — cross-site failover configured AND proven -------------------------
  check "failover routing present (ServiceEntry + VirtualService on the gateway)" failover_routing_present \
    || hint "build the failover routing: a ServiceEntry spanning both sites, a DestinationRule (locality LB + outlier detection), and a VirtualService with retries on claims-gateway (see the lab)"
  check "the stable endpoint serves HTTP 200"          stable_serves \
    || hint "the ingress gateway isn't routing — check the VirtualService is bound to gateway claims-gateway and the ServiceEntry host matches"
  # The ws-solve marker is stamped ONLY by `ws solve`, so assert it ONLY in solve mode (ws verify --solve
  # / CI). A plain `ws verify` is the attendee's own closing verify after doing the failover BY HAND — no
  # solve marker exists, and the OUTCOME checks above + the failover evidence below carry the proof.
  # Asserting the marker there false-REDs a correctly-completed lab.
  if [[ "$SOLVE_MODE" == "true" ]]; then
    check "solve marker present (ws-solve-resilience-multicluster-dr)"        solved \
      || hint "ws solve did not stamp the marker — re-run: ws solve resilience-multicluster-dr --user ${USER_NAME}"
  else
    info "closing verify: the failover OUTCOME below is the proof (the ws-solve marker is stamped only by ws solve; a hand-completed lab legitimately has none)"
  fi

  # ── THE GRADED OUTCOME: did a failover actually happen? ────────────────────────────────────────
  ROUTING_SINCE="$(routing_since)"
  if [[ -z "$ROUTING_SINCE" ]]; then
    warn "failover evidence — there is no failover routing to measure from (see the ❌ above)"
    hint "wire the routing first (lab exercise 2), then fail site-a over; re-run this verify afterwards"
  elif failover_evidenced "$ROUTING_SINCE"; then
    # A pass is a pass however it arose — attendee, instructor demo, or an earlier --failover-drill.
    # This must stay AHEAD of the solved-world branch below, or a demo world where the instructor did
    # perform the failover live would be downgraded from ✅ to ⚠.
    check "FAILOVER proven: the client log shows it served by SITE B after the routing went in" \
      failover_evidenced "$ROUTING_SINCE"
  elif solved; then
    # Keyed on the MARKER, not on --solve: the instructor's pre-demo check is a plain `ws verify` after
    # `ws solve` (instructor.adoc), and `ws solve` renders the three routing CRs and stops — it never
    # fails a site over. So a machine-solved world has nothing to observe and grading it "you never
    # failed over" would red-flag someone whose world is exactly as `ws solve` left it. Saying it PASSED
    # would be the false-completeness verify_summary was rewritten to stop. Skip, and name the one
    # caller that can legitimately prove it actively.
    warn "live failover evidence — this world was machine-solved (ws-solve marker present) and ws solve wires the routing without ever failing a site over"
    hint "nothing to observe yet, and not a failure: either perform the failover (lab exercise 2) and re-verify, or prove it actively where causing an outage is acceptable — a machine-owned or instructor world, never an attendee's mid-lab one: ws verify resilience-multicluster-dr --user ${USER_NAME} --failover-drill"
  elif ! client_log_is_complete "$ROUTING_SINCE"; then
    # The client pod is younger than the routing, or its container restarted: the flip may well have
    # happened and simply not be in any log we can still read. Not gradeable, and NOT the attendee's ❌.
    warn "failover evidence — the client pod restarted after the routing was created, so its log no longer covers the whole window"
    hint "not your lab, and not graded: the evidence was lost with the pod, not by you. Re-run the failover beat to re-record it — oc scale deploy/parasol-claims -n ${SITEA_NS} --replicas=0, watch oc logs -f deploy/claims-client -n ${CLIENT_NS} flip to site B, then oc scale … --replicas=3 — and verify again"
  else
    # The pod has held the log continuously since before the routing existed and no site-B response is
    # in it. That is a real answer: the routing is wired but the site was never failed over.
    check "FAILOVER proven: the client log shows it served by SITE B after the routing went in" \
      failover_evidenced "$ROUTING_SINCE" \
      || hint "the routing is wired but nothing has ever failed over — you still owe the module's money step (lab exercise 2): oc scale deploy/parasol-claims -n ${SITEA_NS} --replicas=0, watch the client log flip to served-by-site=B, then oc scale deploy/parasol-claims -n ${SITEA_NS} --replicas=3"
  fi

  # ── opt-in active drill ────────────────────────────────────────────────────────────────────────
  if [[ "$FAILOVER_DRILL" == "true" ]]; then
    # Guarded on its own prerequisites (rule 14 idiom, matching deployment-targets-scheduling.sh): with
    # the sites/client/gateway down or the routing unwired there is ZERO chance of a site-b response, so
    # the poll would burn its full 45s window before giving up — measured on an empty cluster (CRC,
    # 2026-07-31), the same "written against a populated cluster" shape as the install.sh incident.
    if deploy_ready parasol-claims "$SITEA_NS" && deploy_ready parasol-claims "$SITEB_NS" \
       && deploy_ready claims-client "$CLIENT_NS" && deploy_ready claims-gateway "$CLIENT_NS" \
       && failover_routing_present; then
      echo
      echo "⚠  ACTIVE FAILOVER DRILL — THIS CHANGES THE CLUSTER, and you asked for it (--failover-drill)."
      echo "   About to scale deploy/parasol-claims in ${SITEA_NS} to 0 — the PRIMARY SITE GOES DOWN —"
      echo "   poll the stable endpoint for up to 45s, then restore it and wait for the rollout."
      echo "   Anyone watching ${USER_NAME}'s app will see the outage. If this run is KILLED (SIGKILL, a"
      echo "   destroyed terminal), site-a stays at 0: the replica count is saved on the Deployment as"
      echo "   annotation ${DRILL_ANN}, and the next run of this script prints the restore command."
      echo
      check "FAILOVER proven ACTIVELY: site-a down -> the client is served by site-b" failover_drill \
        || hint "with site-a scaled to 0 the client should be served by site-b within ~30s — check the DestinationRule outlierDetection + locality LB and the VirtualService retries"
    else
      warn "the active failover drill — sites/client/gateway not all Ready yet, or routing not wired (see the checks above)"
      hint "the drill needs a fully-up, fully-wired world; fix the ❌s above and re-run with --failover-drill"
    fi
  fi
fi

verify_summary
