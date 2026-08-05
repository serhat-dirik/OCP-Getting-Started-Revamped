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
  oc_read get ns "$1" -o jsonpath='{.metadata.labels.istio-discovery}' || return 1
  [[ "$OC_OUT" == "enabled" ]]
}

# A site's claims service is RESILIENT: the Deployment is present with >=2 desired replicas, a PDB, and an
# HPA (the observability-health-scale/deployment-targets-scheduling primitives the in-site resiliency beat leans on): $1=namespace.
site_resilient() {
  local ns="$1"
  oc_present get deploy parasol-claims -n "$ns" -o name || return 1
  oc_present get poddisruptionbudget parasol-claims -n "$ns" -o name || return 1
  oc_present get horizontalpodautoscaler parasol-claims -n "$ns" -o name || return 1
  oc_read get deploy parasol-claims -n "$ns" -o jsonpath='{.spec.replicas}' || return 1
  [[ -n "$OC_OUT" && "$OC_OUT" -ge 2 ]]
}

# Any ServiceEntry AND any VirtualService exist in the client ns (mechanism-agnostic: don't pin the names).
# An empty list is a real answer (rc 0, empty) and still a ❌; only an API that could not be asked skips.
failover_routing_present() {
  oc_present get serviceentry -n "$CLIENT_NS" -o name || return 1
  oc_present get virtualservice -n "$CLIENT_NS" -o name
}
# Entry clean-slate: NO failover routing yet (attendee builds the ServiceEntry + VirtualService).
# CLIENT_NS must actually exist first — otherwise an empty result is vacuous (true on a cluster
# where nothing materialized at all), not evidence of a clean, correctly-seeded entry state.
# A NEGATION THAT MUST KEEP PASSING ON GENUINE ABSENCE: oc_absent returns 0 for both NotFound and an
# empty list, and 1 only when the API could not be asked — so a clean entry state still passes and an
# unreachable cluster can no longer certify a clean slate it never looked at.
no_failover_routing() {
  oc_present get ns "$CLIENT_NS" -o name || return 1
  oc_absent get serviceentry,virtualservice -n "$CLIENT_NS" -o name
}

# ── the routing is MINE, not the whole mesh's: exportTo ["."] (END STATE) ─────────────────────────
# Istio defaults exportTo to ["*"] — MESH-WIDE. Every attendee on this shared control plane declares
# the SAME logical host (claims.parasol.internal is deliberately one stable global service name —
# that is the lesson), so an un-scoped ServiceEntry/DestinationRule/VirtualService is merged into
# every other tenant's config and one attendee's gateway can end up resolving to ANOTHER attendee's
# sites. `["."]` scopes the resource to its own namespace. The lab's three CRs carry it and the solve
# end state renders it — and until this check existed nothing asserted it, so dropping the field
# again would have gone green while every attendee published mesh-wide.
#
# NAME-AGNOSTIC, like failover_routing_present above (rule 14): EVERY resource of that kind in the
# attendee's OWN client namespace must be scoped, not one named claims-global. Nothing else can be
# there by accident — the entry state ships none of these three kinds in {user}-client (it ships the
# Gateway and nothing else), which is also why no_failover_routing can assert their absence at entry.
#
# FULLY-QUALIFIED resource names, unlike the bare `serviceentry`/`virtualservice` above. Measured on
# a live 4.x cluster 2026-08-05: serviceentries/destinationrules/virtualservices are each claimed by
# exactly one API group, but `gateways` on that same cluster is claimed by TWO (networking.istio.io
# and gateway.networking.k8s.io) — the bare-plural ambiguity trap is live in this exact API
# neighbourhood, so new reads here spell the group out.
#
# jsonpath over a LIST: a missing .spec.exportTo comes back as an EMPTY field, not an error
# (--allow-missing-template-keys defaults true — measured against the live cluster with a
# deliberately absent field inside a `{range .items[*]}`, 2026-08-05). So "the attendee left exportTo
# out" arrives as `name=` and is graded ❌, which is the whole point, instead of blowing the read up.
UNSCOPED_CRS=""
export_scoped() {  # $1=resource type → 0 when >=1 exists and EVERY one is exportTo ["."]
  local line name scope
  UNSCOPED_CRS=""
  oc_read get "$1" -n "$CLIENT_NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.exportTo[*]}{"\n"}{end}' || return 1
  # An empty list is the API's REAL answer (rc 0, empty output) and still a ❌ — nothing is wired.
  [[ -n "$OC_OUT" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%=*}"
    scope="${line#*=}"
    # A multi-element exportTo prints space-separated (measured, same run), so anything other than a
    # lone "." — ["*"], ["." "istio-system"], or nothing at all — is not namespace-local.
    # Written as a full `if`, never `[[ … ]] && …` as a loop body's last statement inside a function:
    # that is the shape CLAUDE.md records as fatal under `set -e`.
    if [[ "$scope" != "." ]]; then
      UNSCOPED_CRS="${UNSCOPED_CRS}${UNSCOPED_CRS:+, }${name} (exportTo: ${scope:-unset, i.e. the mesh-wide default})"
    fi
  done <<< "$OC_OUT"
  [[ -z "$UNSCOPED_CRS" ]]
}

# The hint has TWO causes to explain — nothing of that kind exists at all, and something exists but
# is published mesh-wide — and only the predicate knows which. Built here so each call site stays
# one line. Echo-shaped on purpose: it reads state and writes none, so the subshell that
# `hint "$(scope_hint …)"` runs it in costs nothing (contrast routing_since/served_site, which must
# stay global because they raise VERIFY_INCONCLUSIVE).
scope_hint() {  # $1=human kind, $2=resource type for the repair command
  if [[ -n "$UNSCOPED_CRS" ]]; then
    echo "published MESH-WIDE on a shared control plane: ${UNSCOPED_CRS}. Every attendee declares the same host (claims.parasol.internal), so an un-scoped ${1} merges into other tenants' config and your gateway can resolve to someone else's sites. Re-apply the lab's ${1} with the exportTo: [\".\"] line, or scope it in place: oc patch ${2} <name> -n ${CLIENT_NS} --type=merge -p '{\"spec\":{\"exportTo\":[\".\"]}}'"
  else
    echo "there is no ${1} in ${CLIENT_NS} to scope — build the failover routing first (lab exercise 2), and keep the exportTo: [\".\"] line on all three resources"
  fi
}

# ── whose sites is the routing pointing at? (user8, suggestion 4) ─────────────────────────────────
# exportTo stops YOUR routing leaking to other tenants; this is the same question from the other end
# — do your ServiceEntry's endpoints resolve to YOUR OWN two site Services? The lab has the attendee
# compare the GATEWAY'S PROGRAMMED endpoints against their own ClusterIPs, but reading those needs
# `istioctl proxy-config endpoints`: the cockpit does not ship istioctl (the lab downloads it), and
# this suite will not take a dependency on a binary an attendee may not have fetched. The DECLARED
# endpoints are the same fact one layer earlier and are a plain `oc` read — with resolution: DNS,
# these names are exactly what Envoy resolves — so that is what is graded, and the check's wording
# says "declared" rather than claiming to have read Envoy.
#
# HOSTNAMES ONLY. An endpoint written as a bare IP literal cannot be attributed to a namespace
# without resolving it. That is a legitimate (if un-lab-like) way to write the resource, so it is ➖
# not applicable rather than ❌ — failing it would be a false ❌ on work that may be perfectly correct.
SE_ADDRS=""
SE_ADDRS_LITERAL=0
#
# RETURNS oc_read's OWN rc, all three of it — 1 (the API answered no: no such namespace, no Istio CRD)
# and 2 (the API could not be asked) mean different things to the caller and collapsing them into a
# bare 1 would print "the cluster did not answer" over a cluster that answered perfectly clearly.
# rc 1 leaves SE_ADDRS empty, which the caller already handles as "nothing to attribute" — the
# ❌ for a missing namespace or a missing mesh CRD is the routing check's, not this one's.
se_endpoint_addrs() {  # → 0 answered (SE_ADDRS set, one address per line) · 1 answered no · 2 could not ask
  local a
  SE_ADDRS=""
  SE_ADDRS_LITERAL=0
  oc_read get serviceentries.networking.istio.io -n "$CLIENT_NS" \
    -o jsonpath='{range .items[*].spec.endpoints[*]}{.address}{"\n"}{end}' || return $?
  SE_ADDRS="$OC_OUT"
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    case "$a" in
      *:*)       SE_ADDRS_LITERAL=1 ;;   # IPv6 literal (hex letters, so the digit test below can't see it)
      *[!0-9.]*) : ;;                    # anything other than digits and dots → a hostname
      *)         SE_ADDRS_LITERAL=1 ;;   # digits and dots only → an IPv4 literal
    esac
  done <<< "$SE_ADDRS"
  return 0
}

# Evaluates the ALREADY-READ addresses and asks the cluster nothing: the caller below reads them
# once, up front, precisely so it can tell "could not ask" (⚠) from "nothing to attribute" (➖) from
# "these are not your sites" (❌) — three outcomes check() alone cannot separate. Same reasoning as
# failover_evidenced's cache, minus the re-raise: this predicate is only ever reached after a read
# that succeeded, so there is no unknown left for it to carry.
#
# Suffix match on ".${ns}" as well as ".${ns}." so the short forms are accepted too: the lab writes
# claims.{user}-site-a.svc.cluster.local, but claims.{user}-site-a.svc and claims.{user}-site-a are
# equally valid in-cluster names and must not be graded ❌. The leading dot is what keeps
# user1-site-a from matching a user10-site-a address.
se_targets_own_sites() {
  local a hit_a=0 hit_b=0
  [[ -n "$SE_ADDRS" ]] || return 1
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    case "$a" in *".${SITEA_NS}."*|*".${SITEA_NS}") hit_a=1 ;; esac
    case "$a" in *".${SITEB_NS}."*|*".${SITEB_NS}") hit_b=1 ;; esac
  done <<< "$SE_ADDRS"
  if (( hit_a == 1 && hit_b == 1 )); then return 0; fi
  return 1
}

# When the failover routing first appeared — the anchor for "has a failover happened SINCE?". Oldest
# ServiceEntry wins, so re-editing a VirtualService mid-lab does not shrink the evidence window. Empty
# when there is no routing (the check that needs it is skipped in that case, never failed on it).
#
# Writes the GLOBAL ROUTING_SINCE and ALWAYS returns 0, rather than echoing for `x="$(routing_since)"`.
# Two reasons, both of them the traps the previous conversion waves hit: under `set -e` an assignment
# whose command substitution returns non-zero KILLS the script silently, and a command substitution
# runs in a SUBSHELL — so VERIFY_INCONCLUSIVE raised inside one never reaches the caller, and the
# "empty because nothing is wired" / "empty because nobody answered" distinction would be lost again
# at exactly the point this conversion exists to preserve it.
ROUTING_SINCE=""
routing_since() {
  ROUTING_SINCE=""
  oc_read get serviceentry -n "$CLIENT_NS" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[0].metadata.creationTimestamp}' || true
  ROUTING_SINCE="$OC_OUT"
}

# The stable endpoint (the ingress gateway) serves HTTP 200 to the client (routing is wired).
# The in-pod probe converts cleanly, MEASURED not assumed (cluster 2, user8, 2026-08-01): curl runs
# with -s, so on a refused connection it prints nothing and `oc exec` reports only `command terminated
# with exit code 7`. That is not in oc_read's could-not-ask allowlist, so "the endpoint did not serve"
# stays a graded ❌ — unlike networking-dev-devops' `</dev/tcp/…` probes, where BASH prints
# "Connection refused" and only the allowlist's lowercase spelling keeps that module gradeable.
stable_serves() {
  oc_read exec deploy/claims-client -n "$CLIENT_NS" -- \
    curl -s -m5 -o /dev/null -w '%{http_code}' http://claims-stable/ || return 1
  [[ "$OC_OUT" == "200" ]]
}

# Which SITE (A/B) the stable endpoint currently returns (empty on any failure). Drill-only.
# Sets the global SERVED_SITE and always returns 0 — same subshell/`set -e` reasoning as routing_since.
SERVED_SITE=""
served_site() {
  SERVED_SITE=""
  oc_read exec deploy/claims-client -n "$CLIENT_NS" -- curl -s -m3 http://claims-stable/ || true
  SERVED_SITE="$(sed -n 's/.*"site":"\([AB]\)".*/\1/p' <<< "$OC_OUT")"
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
#                 outright when there is no previous container — which is the NORMAL case, so the
#                 caller reads its rc rather than swallowing it (the old `|| true`).
#
# Through oc_read, so "the log says no failover" and "nobody answered when I asked for the log" stop
# being the same empty string. Both `oc logs` outcomes that are NOT a log were measured on cluster 2
# (2026-08-01) and both are the server's real answer, not a transport failure — so neither becomes a
# skip: no pods match the selector → rc 0, empty stdout, `No resources found in <ns> namespace.`;
# no previous container → rc 1, `Error from server (BadRequest): previous terminated container … not
# found`. Only a refused/unauthorized/timed-out API reaches rc 2.
client_log_read() {  # $1=RFC3339 anchor, rest=extra oc args → rc 0/1/2 per oc_read, log in OC_OUT
  local anchor="$1" rc=0
  shift
  oc_read logs -l app=claims-client -n "$CLIENT_NS" --tail=-1 --since-time="$anchor" "$@" || rc=$?
  return "$rc"
}

# Cached: the log read is ~1 MB (12,712 lines on user8, measured) and the branch below asks the
# question more than once. Three states, not two: yes · no · unknown (the API could not be asked).
LOG_STATE=""
failover_evidenced() {  # $1=RFC3339 anchor
  local rc
  if [[ -z "$LOG_STATE" ]]; then
    rc=0; client_log_read "$1" || rc=$?
    if (( rc == 2 )); then
      LOG_STATE="unknown"
    else
      case "$OC_OUT" in *"served-by-site=B"*) LOG_STATE="yes";; esac
    fi
    # Only when the current log holds no proof: a `B` already found is proof enough, and skipping the
    # second read keeps a could-not-ask on the (usually absent) previous container from downgrading an
    # answer we already have.
    if [[ -z "$LOG_STATE" ]]; then
      rc=0; client_log_read "$1" --previous || rc=$?
      if (( rc == 2 )); then
        LOG_STATE="unknown"
      else
        case "$OC_OUT" in
          *"served-by-site=B"*) LOG_STATE="yes";;
          *)                    LOG_STATE="no";;
        esac
      fi
    fi
  fi
  # Re-raised on a CACHED unknown, deliberately: check() clears VERIFY_INCONCLUSIVE before every
  # predicate and normally only oc_read sets it, so the second (cache-hit) call would report a graded
  # ❌ — "you never failed over" — for a log this run never managed to read at all.
  if [[ "$LOG_STATE" == "unknown" ]]; then VERIFY_INCONCLUSIVE=1; return 1; fi
  [[ "$LOG_STATE" == "yes" ]]
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
  # Read straight out of OC_OUT rather than through `x="$(oc …)"`: under `set -e` an assignment whose
  # command substitution fails kills the script outright, which is how the first conversion wave
  # truncated an absence run silently.
  oc_read get pods -l app=claims-client -n "$CLIENT_NS" --sort-by=.status.startTime \
    -o jsonpath='{.items[-1:].status.startTime}' || return 1
  pod_start="$OC_OUT"
  oc_read get pods -l app=claims-client -n "$CLIENT_NS" \
    -o jsonpath='{.items[*].status.containerStatuses[?(@.name=="client")].restartCount}' || return 1
  restarts="$OC_OUT"
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
  # Cleared FIRST: an early `return 1` below must not leave a previous call's number behind for the
  # hint to interpolate.
  STRANDED_REPLICAS=""
  oc_read get deploy parasol-claims -n "$SITEA_NS" \
    -o jsonpath="{.metadata.annotations.${DRILL_ANN//./\\.}}" || return 1
  STRANDED_REPLICAS="$OC_OUT"
  [[ -n "$STRANDED_REPLICAS" ]] || return 1
  oc_read get deploy parasol-claims -n "$SITEA_NS" -o jsonpath='{.spec.replicas}' || return 1
  have="$OC_OUT"
  [[ -n "$have" && "$have" -lt "$STRANDED_REPLICAS" ]]
}
# check() needs a predicate that FAILS when the world is wrong, and "stranded" is the wrong world.
not_stranded_drill() { ! stranded_drill; }

# Solve marker (end-state only) lives in the client ns.
solved() { oc_present get cm ws-solve-resilience-multicluster-dr -n "$CLIENT_NS" -o name; }
# CLIENT_NS must actually exist first — otherwise "absent" is vacuous, not evidence of a clean entry.
# The same negation-on-genuine-absence care as no_failover_routing: oc_absent passes on a real
# NotFound (the entry state's whole point) and refuses to pass on an API that never answered. NOT
# written as `! solved`, which would turn could-not-ask into a certified-clean PASS.
not_solved() {
  oc_present get ns "$CLIENT_NS" -o name || return 1
  oc_absent get cm ws-solve-resilience-multicluster-dr -n "$CLIENT_NS" -o name
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
  local orig deadline got_b=0
  # The one READ in this function, and it goes through oc_read like every other read in the file —
  # `|| true` because an unanswerable API must not kill the drill before its own restore path exists;
  # the 3-replica default below already covers an empty answer.
  oc_read get deploy parasol-claims -n "$SITEA_NS" -o jsonpath='{.spec.replicas}' || true
  orig="$OC_OUT"
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
    served_site   # sets SERVED_SITE; never `site="$(served_site)"` — see served_site's own comment
    if [[ "$SERVED_SITE" == "B" ]]; then got_b=1; break; fi
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

  # ── the routing is scoped to THIS attendee, not the whole mesh ──────────────────────────────────
  # END STATE ONLY, and it has to be: the attendee creates these three CRs during the lab, and the
  # entry branch above already asserts the opposite (no_failover_routing — none of them exist yet).
  # Asserting exportTo at entry would grade a world nobody has started.
  check "ServiceEntry is namespace-scoped (exportTo: [\".\"], not published mesh-wide)" \
    export_scoped serviceentries.networking.istio.io \
    || hint "$(scope_hint ServiceEntry serviceentry)"
  check "DestinationRule is namespace-scoped (exportTo: [\".\"], not published mesh-wide)" \
    export_scoped destinationrules.networking.istio.io \
    || hint "$(scope_hint DestinationRule destinationrule)"
  check "VirtualService is namespace-scoped (exportTo: [\".\"], not published mesh-wide)" \
    export_scoped virtualservices.networking.istio.io \
    || hint "$(scope_hint VirtualService virtualservice)"

  # ── and it points at YOUR sites ─────────────────────────────────────────────────────────────────
  # Read up front, outside check(), because the branch needs three outcomes check() cannot separate
  # on its own: could-not-ask (⚠), nothing-to-attribute (➖), and endpoints that are not yours (❌).
  # VERIFY_INCONCLUSIVE is cleared first for the same reason the failover block below clears it —
  # check() normally does it per-assertion and this read happens outside one.
  VERIFY_INCONCLUSIVE=0
  SE_READ_RC=0
  se_endpoint_addrs || SE_READ_RC=$?
  if (( SE_READ_RC == 2 )); then
    warn "could not check: the ServiceEntry's endpoints are your own sites — the cluster API did not answer${OC_ERR:+ (${OC_ERR:0:120})}"
    hint "not your lab, and not graded: the cluster could not be asked, so this check has no verdict. Re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor"
  elif [[ -z "$SE_ADDRS" ]]; then
    # No ServiceEntry, or one that declares no endpoints: there is nothing whose ownership could be
    # wrong. NOT a second ❌ for a cause the checks above already reported with the right fix.
    na "ServiceEntry endpoint ownership — there are no ServiceEntry endpoints in ${CLIENT_NS} to attribute (see the ServiceEntry checks above)"
  elif (( SE_ADDRS_LITERAL == 1 )); then
    na "ServiceEntry endpoint ownership — an endpoint is written as an IP literal, which no oc read can attribute to a namespace (the lab's istioctl proxy-config endpoints step is where that is read)"
  else
    check "the ServiceEntry's declared endpoints are YOUR OWN sites (${SITEA_NS} + ${SITEB_NS})" se_targets_own_sites \
      || hint "your ServiceEntry's endpoints do not name both of your own site Services. On a shared mesh that means your stable endpoint can be served by someone else's claims service — check the two endpoint addresses are claims.${SITEA_NS}.svc.cluster.local and claims.${SITEB_NS}.svc.cluster.local: oc get serviceentry -n ${CLIENT_NS} -o jsonpath='{range .items[*].spec.endpoints[*]}{.address}{\"\\n\"}{end}'"
  fi
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
  VERIFY_INCONCLUSIVE=0
  routing_since                                    # sets ROUTING_SINCE, always rc 0
  ROUTING_UNKNOWN="$VERIFY_INCONCLUSIVE"           # …and the flag says WHY it came back empty

  # Will the opt-in active drill below run AND be able to run? Answered ONCE, here, for two reasons.
  #
  # CORRECTNESS. The passive chain below reports what the client's LOG already shows. On a
  # machine-solved world it has nothing to show, so it warns — and its own hint tells you to re-run
  # with --failover-drill. But the drill then runs anyway, twelve lines later, and PASSES. Measured
  # on cluster 65prs, a single `ws verify … --failover-drill` printed BOTH
  #   ⚠ live failover evidence — … SKIPPED (not a failure)
  #   ✅ FAILOVER proven ACTIVELY: site-a down -> the client is served by site-b
  # and closed "⚠ 20 passed · 1 SKIPPED — this run did NOT fully verify the lab". The run DID fully
  # verify it, by the exact command the ⚠ recommended. Not a false pass — a FALSE INCOMPLETENESS,
  # which is the same class of defect as the banner rewrite that introduced na(): a caveat printed
  # when nothing is missing teaches people to ignore caveats.
  #
  # COST. deploy_ready polls to a 45s budget now, so evaluating these four readiness probes in both
  # places would double the wait on exactly the runs that are already the slowest.
  DRILL_SUPERSEDES="false"
  if [[ "$FAILOVER_DRILL" == "true" ]] \
     && deploy_ready parasol-claims "$SITEA_NS" && deploy_ready parasol-claims "$SITEB_NS" \
     && deploy_ready claims-client "$CLIENT_NS" && deploy_ready claims-gateway "$CLIENT_NS" \
     && failover_routing_present; then
    DRILL_SUPERSEDES="true"
  fi

  if [[ "$DRILL_SUPERSEDES" == "true" ]]; then
    # The drill is a strictly STRONGER assertion than anything the log could show passively: it causes
    # the outage itself and observes the flip. Grading the passive evidence too can only subtract.
    info "passive failover evidence not graded — the opt-in drill below proves it ACTIVELY in this same run"
  elif [[ -z "$ROUTING_SINCE" && "$ROUTING_UNKNOWN" == "1" ]]; then
    # Empty because nobody answered, not because nothing is wired. Before the oc_read conversion these
    # two were the same empty string and the attendee was pointed at the ❌ above — which, on an
    # unreachable API, is now a ⚠ that says nothing about their work.
    warn "failover evidence — the cluster API could not be asked when the routing was created (see the ⚠ above)"
    hint "not your lab, and not graded: re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor"
  elif [[ -z "$ROUTING_SINCE" ]]; then
    warn "failover evidence — there is no failover routing to measure from (see the ❌ above)"
    hint "wire the routing first (lab exercise 2), then fail site-a over; re-run this verify afterwards"
  elif failover_evidenced "$ROUTING_SINCE"; then
    # A pass is a pass however it arose — attendee, instructor demo, or an earlier --failover-drill.
    # This must stay AHEAD of the solved-world branch below, or a demo world where the instructor did
    # perform the failover live would be downgraded from ✅ to ⚠.
    check "FAILOVER proven: the client log shows it served by SITE B after the routing went in" \
      failover_evidenced "$ROUTING_SINCE"
  elif [[ "$LOG_STATE" == "unknown" ]]; then
    # The routing exists but the log itself could not be read. Placed AHEAD of the solved-world and
    # log-completeness branches because both of those describe a log we actually got an answer about;
    # falling through to them would explain an outage as either "you machine-solved this" or "your pod
    # restarted", and send the attendee chasing a pod that is fine.
    warn "failover evidence — the client's log could not be read (the cluster API did not answer)"
    hint "not your lab, and not graded: the evidence is still in the pod, this run just could not fetch it. Re-run the same ws verify in a moment; if it keeps happening, tell your instructor"
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
    # Reuses the single evaluation above rather than re-probing: same condition by construction, so
    # the guard and the passive-chain suppression can never drift apart, and the four readiness polls
    # are paid once.
    if [[ "$DRILL_SUPERSEDES" == "true" ]]; then
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
