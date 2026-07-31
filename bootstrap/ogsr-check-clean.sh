#!/usr/bin/env bash
# ogsr-check-clean.sh — REPORT what the workshop left on a cluster. READ-ONLY BY DESIGN.
#
# Run this after ./bootstrap/ogsr-uninstall.sh. It scans NINE classes of leftover — sections [1/9]
# through [9/9] below — explains in one line what each class means, and prints the exact `oc` command
# that would deal with each finding.
#
# It never deletes, patches, labels, annotates or applies ANYTHING. That is deliberate and is the
# most important property of this script: removing a CRD deletes every instance of it cluster-wide,
# and clearing a finalizer can strand an operator mid-cleanup. Those decisions belong to a cluster
# admin who knows what the org runs — not to a script running unattended. This tells you what there
# is to decide about; you decide.
#
# Every finding is then sorted into one of three REMEDIES, because "carries a workshop label" and
# "the workshop created it" are NOT the same statement. Our kustomize label transformer stamps our
# labels onto resources Argo ADOPTED — the org's operator namespace and the org's Subscription end up
# labelled `workshop.redhat.com/owner=ogsr` without us ever having created them:
#
#   DELETE  — we created it. The removal command is printed.
#   STRIP   — we only marked it. Our label/annotation is a trace that should go (the "no trace" bar),
#             but the OBJECT is the org's. The printed command removes our marks, never the object.
#   DECIDE  — we cannot tell. NO destructive command is printed; the line says what is ambiguous.
#
# An unattended admin must never be handed `oc delete <the org's thing>` on a guess. That is a worse
# failure than the leftover this script exists to report.
#
# Exit codes
#   0  nothing of the workshop remains and the cluster is healthy
#   1  findings are listed above (works as a CI gate and as a yes/no for an SA)
#   2  the scan could not run at all (no oc, not logged in)
#
# HOW LONG IT TAKES. The scan is latency-bound — it makes one list call per resource class and then
# classifies each marked object it found — so its runtime tracks the number of LEFTOVERS, not the size
# of the cluster. Measured on a 220-namespace cluster (RHDP, 2026-07-29):
#
#   after ogsr-uninstall.sh, nothing left ....... ~45s   (this is the case it was built for)
#   against a FULL install, ~500 marked objects .. ~1m50s (the pathological input: everything is a finding)
#
# That second figure was ~2m20s until the markers stopped being fetched one object at a time. Every
# index and sweep now carries the eight marker fields in the SAME list call that finds the object, so
# classification makes no cluster call at all; the only per-object read left is a ClusterServiceVersion's
# (a CSV embeds its whole install strategy, so it is not worth listing in bulk to get a label). Paired
# alternating runs, three each, same cluster: 138/136/147s before, 101/110/113s after — the two ranges
# do not overlap. Byte-identical output across the change.
#
# Every section prints its elapsed time as `t+NNs`, and section [8/9] announces how many objects it is
# about to classify before it starts, so a long run is visibly making progress rather than hung. On a
# rate-limited cluster lower the fan-out (OGSR_CHECK_JOBS=2) and expect proportionally longer.
#
# Usage
#   ./ogsr-check-clean.sh                     scan the cluster in the current kubecontext
#   ./ogsr-check-clean.sh --state-file PATH   read install state from a file. ogsr-uninstall.sh
#                                             writes one before it deletes the state namespace,
#                                             and prints the path in its closing summary.
#   ./ogsr-check-clean.sh --quiet             findings and verdict only, no explanations
#   ./ogsr-check-clean.sh --self-test         offline proof that the olm.copiedFrom exclusion works
#                                             and that a copy-only namespace is never misread as
#                                             foreign. Touches no cluster. Exit 1 = both proofs held
#                                             (house convention — see .github/workflows/lint.yml).
#
# `set -e` is deliberately NOT used. This script runs on a cluster whose state it cannot predict —
# including one whose API discovery is already broken, which is one of the things it reports. A
# failed `oc get` must degrade to a printed note, never kill the scan.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL_SH="${SCRIPT_DIR}/ogsr-uninstall.sh"

# The owner label and state-ConfigMap coordinates are READ OUT OF ogsr-uninstall.sh, not restated
# here, so the two scripts can never disagree about what "ours" means. Literals below are only the
# fallback for running this file on its own, away from the repo.
from_uninstall() {  # VAR default — echo the literal value of `VAR="…"` in ogsr-uninstall.sh
  local v=""
  [ -r "$UNINSTALL_SH" ] && v="$(grep -m1 "^${1}=\"" "$UNINSTALL_SH" 2>/dev/null | cut -d'"' -f2)"
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "$2"; fi
}
OWNER_LABEL="$(from_uninstall OWNER_LABEL 'workshop.redhat.com/owner=ogsr')"
STATE_NS="$(from_uninstall STATE_NS 'ogsr-system')"
STATE_CM="$(from_uninstall STATE_CM 'ogsr-uninstall-state')"
ARGO_NS="$(from_uninstall ARGO_NS 'openshift-gitops')"
OWNER_KEY="${OWNER_LABEL%%=*}"
OWNER_VAL="${OWNER_LABEL#*=}"

# Labels that are exclusively ours. Child portfolio Applications and some namespaces carry only the
# portfolio.* pair (verified: 31 of 32 stack child apps have portfolio.redhat.com/component and no
# owner label), so scanning the owner label alone under-reports — that is precisely how
# ogsr-observability-workshop survived a "complete" teardown unseen.
COMPONENT_KEY="portfolio.redhat.com/component"
STACK_KEY="portfolio.redhat.com/stack"
LAYER_KEY="workshop.redhat.com/layer"
USER_KEY="workshop.redhat.com/user"
NS_PREFIX="ogsr-"   # every shared namespace we create is prefixed; belt-and-braces for missing labels

# Argo annotations. sync-options carrying Delete=false is the ONE adoption signal that needs no state
# file — bootstrap/install.sh's protect_adopted_resources() stamps `Prune=false,Delete=false` on
# adopted resources and on nothing else, so its presence is proof the object was already here.
SYNC_OPTS_ANN="argocd.argoproj.io/sync-options"
# tracking-id is a trace we leave on every object an Argo app manages, adopted ones included. Every
# portfolio app is named pp-<stack|component> (argocd-bootstrap/stack-app.template.yaml → pp-__STACK__),
# so a pp-* tracking-id is unambiguously ours even after the labels have been stripped. Workshop-layer
# apps are deliberately NOT matched: their objects live in namespaces we delete outright, and a loose
# prefix here would claim someone else's Argo trace as our own.
TRACK_ANN="argocd.argoproj.io/tracking-id"
# Dev Spaces stamps this on every namespace it auto-provisions for a user (CheCluster
# devEnvironments.defaultNamespace {autoProvision: true, template: "<username>-devspaces"}). We never
# create those namespaces and they carry NONE of our labels, so before this they were invisible here:
# an attendee who opened Dev Spaces left `userN-devspaces` behind and the report said the cluster was
# clean. A false clean is worse than a named leftover — it is the one thing this script exists to
# prevent. Namespaces are cluster-scoped so nothing garbage-collects them either (no ownerReferences,
# and a namespaced controller could not own one anyway). Measured on ksls5 2026-07-29.
CHE_USER_ANN="che.eclipse.org/username"
PORTFOLIO_APP_PREFIX="pp-"

# Argo's own objects are exempt from the "lives in an adopted operator's namespace" rule: the portfolio
# CREATES its Applications, it never adopts the org's, and an Application that still reconciles must be
# deleted rather than de-labelled (stripping a label it is reconciling just puts the label back).
ARGO_OWN_KINDS=" applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io "

# Read-only list requests fan out safely; the scan is dominated by per-call round-trip latency, not by
# API server load. Lower it on a rate-limited cluster: OGSR_CHECK_JOBS=2 ./ogsr-check-clean.sh
SWEEP_JOBS="${OGSR_CHECK_JOBS:-8}"
case "$SWEEP_JOBS" in ''|*[!0-9]*|0) SWEEP_JOBS=8;; esac

STATE_FILE=""
STATE_FILE_DEFAULT="${TMPDIR:-/tmp}/ogsr-uninstall-state.txt"
QUIET="false"
SELF_TEST="false"

N_ADOPTED=0   # the org's own operators left unhealthy — the worst outcome this design can produce
N_HEALTH=0    # cluster-wide health damage (wedged namespaces, broken discovery)
N_WS=0        # workshop litter we created — safe to delete
N_TRACE=0     # our marks left on resources that are NOT ours to delete — strip the marks, keep the object
N_DECIDE=0    # unclassifiable — a human has to look; no destructive command is printed for these

TMPROOT=""
# shellcheck disable=SC2329  # invoked by the EXIT trap below, not called by name
# shellcheck disable=SC2317  # body runs from the EXIT trap, not from a call site
cleanup() { [ -n "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Print the header block and stop at the first line that is not a comment — a line COUNT drifts out of
# date the moment the header grows, which is how --help started printing internal comments once already.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    # `shift 2` with only one argument left is a no-op that returns non-zero — and with no `set -e`
    # (deliberate, see the header) the loop then spins on the same argument forever. Reject the missing
    # value explicitly instead of hanging a script an admin is running unattended after a teardown.
    --state-file)
      [ $# -ge 2 ] || { echo "❌ --state-file needs a path" >&2; exit 2; }
      STATE_FILE="$2"; shift 2;;
    --quiet|-q)   QUIET="true"; shift;;
    --self-test)  SELF_TEST="true"; shift;;
    -h|--help)    usage;;
    *) echo "unknown flag: $1" >&2; usage;;
  esac
done

# ── output helpers ────────────────────────────────────────────────────────────
RULE="──────────────────────────────────────────────────────────────────────────"
# Elapsed seconds, stamped on every section header and progress line. An admin deciding whether to run
# destructive commands is watching this output; "no output for fifteen minutes" reads as a hang, which
# is exactly how a slow-but-working scan got killed twice by `timeout 900` (ksls5, 2026-07-29). SECONDS
# is a bash builtin, so this costs no process and cannot itself fail.
elapsed() { printf 't+%ss' "$SECONDS"; }
prog() {  # one progress line, with a count wherever a count exists
  [ "$QUIET" = "true" ] || printf '      … %s  (%s)\n' "$1" "$(elapsed)"
  return 0
}
hdr() {  # n/N  title  one-line-explanation
  echo; echo "$RULE"; printf '[%s] %s  (%s)\n' "$1" "$2" "$(elapsed)"
  [ "$QUIET" = "true" ] || echo "      $3"
}
found() {  # bucket  what  [command]
  printf '   • %s\n' "$2"
  # The verb differs by bucket ON PURPOSE. "remove" next to an object we do not own is the defect this
  # classification exists to prevent, so the trace bucket says "strip" and never prints a delete.
  if [ -n "${3:-}" ]; then
    case "$1" in
      trace) printf '     strip:  %s\n' "$3";;
      *)     printf '     remove: %s\n' "$3";;
    esac
  fi
  case "$1" in
    adopted) N_ADOPTED=$((N_ADOPTED + 1));;
    health)  N_HEALTH=$((N_HEALTH + 1));;
    trace)   N_TRACE=$((N_TRACE + 1));;
    decide)  N_DECIDE=$((N_DECIDE + 1));;
    *)       N_WS=$((N_WS + 1));;
  esac
  return 0
}
sub()     { printf '       ↳ %s\n' "$*"; }
subcmd()  { printf '       remove: %s\n' "$*"; }
stripcmd(){ printf '       strip:  %s\n' "$*"; }
none()    { printf '   ✅ %s\n' "${1:-none}"; }
note()    { printf '   ℹ  %s\n' "$*"; }

# ── parallel helper ───────────────────────────────────────────────────────────
# Every `oc` invocation on a remote cluster costs ~0.7s of round-trip before it reads anything, so the
# scan is latency-bound: 168 cluster-scoped kinds cost the same whether each request is cheap or not.
# Running the reads concurrently is the only lever that does not cost coverage. bash 3.2 has no
# `wait -n`, so work is dealt round-robin into a fixed number of workers and we wait for all of them.
tmproot() { [ -n "$TMPROOT" ] || TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/ogsr-check.XXXXXX" 2>/dev/null)"; [ -n "$TMPROOT" ]; }

run_parallel() {  # worker-fn < newline-separated work items → concatenated stdout, deterministic order
  local fn="$1" d n=0 w
  tmproot || { while IFS= read -r w; do "$fn" "$w"; done; return 0; }   # no tmpdir → degrade to serial
  d="$(mktemp -d "${TMPROOT}/job.XXXXXX")" || return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    printf '%s\n' "$w" >> "${d}/in.$((n % SWEEP_JOBS))"
    n=$((n + 1))
  done
  w=0
  while [ "$w" -lt "$SWEEP_JOBS" ]; do
    if [ -f "${d}/in.${w}" ]; then
      # shellcheck disable=SC2094  # in.N is only read here; out.N is a different file
      ( while IFS= read -r item; do "$fn" "$item"; done < "${d}/in.${w}" ) > "${d}/out.${w}" 2>/dev/null &
    fi
    w=$((w + 1))
  done
  wait
  cat "${d}"/out.* 2>/dev/null
  rm -rf "$d"
  return 0
}

# ── preflight ─────────────────────────────────────────────────────────────────
# --self-test proves the olm.copiedFrom exclusion offline, against a stubbed `oc` — it must never
# require a live cluster (CI runs it with no kubeconfig at all), so it skips preflight and the banner
# entirely and jumps straight to self_test() at the bottom, where the functions it needs are defined.
if [ "$SELF_TEST" != "true" ]; then
  command -v oc >/dev/null 2>&1 || { echo "❌ oc not found in PATH — cannot scan"; exit 2; }
  oc whoami >/dev/null 2>&1 || {
    echo "❌ not logged in to a cluster — cannot scan"
    echo "   fix: export KUBECONFIG=/path/to/kubeconfig   (this script never runs oc login itself)"
    exit 2
  }

  echo "ogsr-check-clean — read-only leftover report"
  echo "  cluster: $(oc whoami --show-server 2>/dev/null || echo '?')"
  echo "  as:      $(oc whoami 2>/dev/null || echo '?')     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "  owner label: ${OWNER_LABEL}"
  echo "  NOTHING below is changed for you. Each finding carries the command for ITS remedy — 'remove:'"
  echo "  where we created the object, 'strip:' where we only marked one of the org's, and neither where"
  echo "  the two cannot be told apart."
  # Said BEFORE the first long read, not after it. This tool is meant to be run after an uninstall, where
  # it finishes in well under a minute; run against a FULL install every object is a finding and the scan
  # takes minutes. Without this line that is indistinguishable from a hang, at exactly the moment someone
  # is deciding whether to run destructive commands on their own cluster.
  [ "$QUIET" = "true" ] || {
    echo "  Runtime scales with the number of LEFTOVERS, not with the size of the cluster: seconds on a"
    echo "  cleanly uninstalled cluster, a few minutes against a full install. Each section prints its"
    echo "  elapsed time as (t+NNs), so you can always see it moving."
  }
fi

# ── indexes: one cluster read each, reused by every section ───────────────────
DISCOVERY_NOTE=""
NS_INDEX=""; SVC_INDEX=""; CSV_INDEX=""; OG_INDEX=""; CRD_INDEX=""; STATE_KV=""; STATE_SRC=""

# ns|name|installedCSV|currentCSV|<the 8 marker fields> — ONE cluster-wide Subscription read, shared by
# the four call sites that each used to pay for it: section [3/9]'s orphan test, build_adoption_index's
# per-adopted-operator probe, ns_has_foreign_csv's per-namespace label query, and section [8/9]'s marks
# lookup (seeded into the cache from these very rows). Measured on ksls5 2026-07-29.
#
# THE DANGEROUS READ, and the reason its exit status is kept in a variable of its own. If this list
# fails and the failure is swallowed, every CSV on the cluster looks unowned and section [3/9] hands an
# admin `oc delete` for the org's entire operator estate. Verified on ksls5 2026-07-28 with
# `--as=system:serviceaccount:default:default`: a forbidden list exits 1 with EMPTY stdout — identical
# output to a cluster with no Subscriptions, distinguishable only by status. Every consumer below
# therefore branches on SUB_INDEX_RC and degrades to what it did before this index existed, never to
# "the list was empty".
#
# subscriptions.operators.coreos.com in full, never `subscriptions`: three API groups claim that plural
# and messaging.knative.dev shadows OLM's, which once reported every operator as absent (SEV1, fixed in
# 437bbf4). In section [3/9] the same mistake would report every operator as an orphan.
SUB_INDEX=""
SUB_INDEX_RC=1     # 0 = the list is trustworthy and may be answered from; anything else = fall back
SUB_INDEX_ERR=""   # first line of stderr from that read, quoted verbatim wherever the failure is reported

# The eight marker fields this script cares about on ANY object, in one jsonpath. The count is load-
# bearing — every index that embeds MARKS_JP is parsed by FIELD POSITION, so it is stated here and
# repeated nowhere else:
#   owner|component|stack|user|layer|tracking-id|sync-options|che-user
MARKS_JP="{.metadata.labels.${OWNER_KEY//./\\.}}|{.metadata.labels.${COMPONENT_KEY//./\\.}}|{.metadata.labels.${STACK_KEY//./\\.}}|{.metadata.labels.${USER_KEY//./\\.}}|{.metadata.labels.${LAYER_KEY//./\\.}}|{.metadata.annotations.${TRACK_ANN//./\\.}}|{.metadata.annotations.${SYNC_OPTS_ANN//./\\.}}|{.metadata.annotations.${CHE_USER_ANN//./\\.}}"

# ns|name|phase|  for every ORIGINAL ClusterServiceVersion — OLM's per-namespace copies excluded
# server-side. See the call site in load_indexes() for the full why; kept as its own function so
# --self-test can point it at a stubbed `oc` and prove the exclusion fires, rather than trusting that
# the flag is merely present somewhere in this file's source.
csv_index_read() {
  oc get clusterserviceversions.operators.coreos.com -A -l '!olm.copiedFrom' --no-headers 2>/dev/null \
    | awk 'NF>=3 { p=$NF; if (p !~ /^(Pending|InstallReady|Installing|Succeeded|Failed|Replacing|Deleting|Unknown)$/) p=""; print $1"|"$2"|"p"|" }'
  return 0
}

load_indexes() {
  local sub_ef
  echo
  echo "collecting cluster state (one read per resource class, ${SWEEP_JOBS} at a time)…"
  # Opened here, in the MAIN shell, before anything forks: every subshell must inherit the same path or
  # the shared marks cache silently degrades to one `oc get` per call site (see obj_marks).
  if tmproot; then MARKS_FILE="${TMPROOT}/marks.idx"; : > "$MARKS_FILE" || MARKS_FILE=""; fi

  # name|phase|<the 7 marker fields>. Namespaces are the most dangerous thing this script can be wrong
  # about, so their markers are read up front and seeded into the marks cache — no later object-by-object
  # round trip is needed to classify one.
  NS_INDEX="$(oc get namespaces -o jsonpath="{range .items[*]}{.metadata.name}|{.status.phase}|${MARKS_JP}{\"\n\"}{end}" 2>/dev/null)"
  [ -n "$NS_INDEX" ] || DISCOVERY_NOTE="${DISCOVERY_NOTE}could not list namespaces; "

  # " ns/name ns/name … " — membership test for the APIService and webhook sections
  SVC_INDEX=" $(oc get services -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null) "

  # ns|name|phase|reason
  #
  # `-l '!olm.copiedFrom'` drops OLM's per-namespace COPIES server-side — same flag, same reason, as
  # ogsr-uninstall.sh's csv_index() and this file's own section [3/9] (search ORPHAN_CSV_JP). OLM copies
  # a CSV into every namespace its OperatorGroup targets, which for an AllNamespaces-mode operator is
  # EVERY namespace on the cluster — so without this filter, CSV_INDEX previously said "yes, this
  # namespace holds a CSV" about nearly the whole cluster regardless of what any namespace actually is.
  # That is NOT harmless the way it once looked: ns_has_foreign_csv() below asks exactly "does ANY row
  # match this namespace", so every extra copy row flips more namespaces from "no CSV here" to "holds
  # one we can't account for" — which reads as SAFER (classify_finding's no-state fallback answers
  # `decide` instead of `ours`, printing no delete command) but actually just drowns the one case this
  # heuristic exists to catch — a namespace that genuinely hosts an unaccounted operator — under false
  # positives from namespaces that were never anything but a copy target. Excluding copies does not
  # remove real signal: an operator's ORIGINAL CSV still lives, un-filtered, in the namespace that
  # actually hosts it (adopted or ours), so a truly ambiguous namespace still classifies as `decide`.
  # Older OLM recorded the copy as an ANNOTATION instead of a label, which this selector cannot catch —
  # accepted here (as it is in section [3/9]'s own filtered read) because every OCP 4.20+ cluster this
  # portfolio targets stamps the label form.
  #
  # Read as a SERVER-SIDE TABLE, not as jsonpath. A CSV embeds its whole install strategy, alm-examples
  # and a base64 icon, so `-o jsonpath`/`-o name` pull the full objects: measured 5.8–12.9s here versus
  # 2.3s for the table. The table gives NAMESPACE …spaces-in-DISPLAY… PHASE, so only $1, $2 and $NF are
  # positionally safe; $NF is validated against OLM's phase vocabulary and anything unrecognised is
  # re-read per object below rather than guessed at.
  #
  # Pulled out to its own function (rather than inlined here) so --self-test can call the exact same
  # code path against a stubbed `oc` and prove the copiedFrom exclusion actually fires, instead of
  # grepping this file's own source for the flag.
  CSV_INDEX="$(csv_index_read)"
  # status.reason is not in the table and section [2/9] needs it. Only non-Succeeded CSVs can carry an
  # interesting reason, and a healthy cluster has none, so this costs nothing in the normal case.
  csv_fill_reasons

  # ns|name|<the 8 marker fields> — OperatorGroups are the TooManyOperatorGroups class in section 2,
  # which reads field 3 (our owner label). That is still field 3: MARKS_JP leads with the owner label,
  # so widening the tail from "just sync-options" to the full marker set costs the same call and lets
  # section [8/9] classify an adopted operator's OperatorGroup without re-reading the object.
  OG_INDEX="$(oc get operatorgroups.operators.coreos.com -A -o jsonpath="{range .items[*]}{.metadata.namespace}|{.metadata.name}|${MARKS_JP}{\"\n\"}{end}" 2>/dev/null)"
  seed_index_marks operatorgroups.operators.coreos.com "$OG_INDEX"

  # The shared Subscription list. Read AFTER the marks cache is open (above) and BEFORE
  # build_adoption_index, which is its first consumer.
  sub_ef=""
  [ -n "$TMPROOT" ] && sub_ef="${TMPROOT}/sub-list.err"
  SUB_INDEX="$(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath="{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.installedCSV}|{.status.currentCSV}|${MARKS_JP}{\"\n\"}{end}" 2>"${sub_ef:-/dev/null}")"
  SUB_INDEX_RC=$?
  if [ -n "$sub_ef" ] && [ -s "$sub_ef" ]; then SUB_INDEX_ERR="$(head -1 "$sub_ef")"; fi
  if [ "$SUB_INDEX_RC" -eq 0 ]; then
    # cut off the four status fields: seed_index_marks wants "ns|name|<marks>"
    seed_index_marks subscriptions.operators.coreos.com \
      "$(printf '%s\n' "$SUB_INDEX" | awk -F'|' 'NF>=12 {out=$1"|"$2; for(i=5;i<=12;i++) out=out"|"$i; print out}')"
  fi

  # name|group — also a table read. A CRD carries its full OpenAPI schema, so the jsonpath form measured
  # 8–31s against 2.2s for the table. The group is not lost: apiextensions REQUIRES a CRD to be named
  # <plural>.<group>, so everything after the first dot IS the group.
  CRD_INDEX="$(oc get customresourcedefinitions.apiextensions.k8s.io --no-headers 2>/dev/null \
    | awk '{ i=index($1,"."); if (i>0) print $1"|"substr($1,i+1); else print $1"|" }')"

  load_state
  build_adoption_index
  printf '  done — %s namespaces, %s CSVs, %s CRDs.  (%s)\n' \
    "$(printf '%s\n' "$NS_INDEX"  | grep -c .)" \
    "$(printf '%s\n' "$CSV_INDEX" | grep -c .)" \
    "$(printf '%s\n' "$CRD_INDEX" | grep -c .)" "$(elapsed)"
}

csv_fill_reasons() {
  local todo out
  todo="$(printf '%s\n' "$CSV_INDEX" | awk -F'|' '$2!="" && $3!="Succeeded" {print $1"|"$2}')"
  [ -n "$todo" ] || return 0
  out="$(printf '%s\n' "$todo" | run_parallel csv_probe)"
  [ -n "$out" ] || return 0
  # replace the table rows with the exact ones
  CSV_INDEX="$(printf '%s\n%s\n' \
    "$(printf '%s\n' "$CSV_INDEX" | awk -F'|' '$2!="" && $3=="Succeeded"')" "$out" | grep -v '^ *$')"
}
# shellcheck disable=SC2317,SC2329  # dispatched indirectly by run_parallel, not called by name
# (SC2329 is shellcheck >=0.10, SC2317 the same finding on 0.9.x which CI installs — name both)
csv_probe() {  # "ns|name" → "ns|name|phase|reason"
  local ns="${1%%|*}" nm="${1#*|}"
  printf '%s|%s|%s\n' "$ns" "$nm" \
    "$(oc get clusterserviceversions.operators.coreos.com "$nm" -n "$ns" \
        -o jsonpath='{.status.phase}|{.status.reason}' 2>/dev/null)"
}

# spec.customresourcedefinitions.owned is only needed to diagnose a namespace stuck Terminating, and
# fetching it means pulling every CSV in full. Deferred until something actually asks.
CSV_OWNED_INDEX=""; CSV_OWNED_LOADED="false"
load_csv_owned() {
  [ "$CSV_OWNED_LOADED" = "true" ] && return 0
  CSV_OWNED_LOADED="true"
  CSV_OWNED_INDEX="$(oc get clusterserviceversions.operators.coreos.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.phase}|{range .spec.customresourcedefinitions.owned[*]}{.name}{","}{end}{"\n"}{end}' 2>/dev/null)"
  return 0
}

load_state() {
  local live f
  # shellcheck disable=SC2016  # $k/$v are go-template variables; expanding them here would break it
  live="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o go-template='{{range $k,$v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null)"
  if [ -n "$live" ]; then
    STATE_KV="$live"; STATE_SRC="ConfigMap ${STATE_NS}/${STATE_CM} (install still present)"
    return 0
  fi
  # The state ConfigMap lives in ogsr-system, which the uninstall deletes LAST — so after a
  # successful uninstall it is gone and only the dump file can say what we created vs adopted.
  for f in "$STATE_FILE" "$STATE_FILE_DEFAULT"; do
    [ -n "$f" ] || continue
    [ -r "$f" ] || continue
    STATE_KV="$(cat "$f" 2>/dev/null)"; STATE_SRC="file ${f}"
    return 0
  done
  STATE_SRC=""
}

# Here-string, NOT `printf … | grep -m1`: grep exits on its first match while printf is still
# writing, printf takes SIGPIPE, and bash prints `printf: write error: Broken pipe` to stderr —
# straight into an admin-facing report that is supposed to be trustworthy. Measured on ksls5
# 2026-07-29. A here-string has no upstream process to kill.
state_get() { grep -m1 "^${1}=" <<< "$STATE_KV" | cut -d= -f2- ; }
state_ops() {  # created|adopted → "name namespace" lines
  printf '%s\n' "$STATE_KV" | grep "^op_" | grep "=${1}:" \
    | sed "s/^op_\([^=]*\)=${1}:\(.*\)$/\1 \2/" | grep -v '^ *$'
}

# ── is this finding ours to delete? ───────────────────────────────────────────
# THE point of this block. Our kustomize label transformer stamps workshop labels on every resource in
# a component, INCLUDING the ones Argo adopted because the org already had them — so "carries a workshop
# label" is not evidence the workshop created anything. Section [1/9] has always known which operators
# were adopted; before this existed, nothing else asked it, and the script cheerfully printed
# `oc delete namespace cert-manager-operator` for an operator it had reported healthy four lines above.
#
# Deleting that namespace destroys the org's cert-manager and every certificate it issues.
ADOPTED_NS=" "        # " ns ns "                                     namespaces of adopted operators
ADOPTED_OBJ=" "       # " sub:<ns>/<n> csv:<ns>/<n> og:<ns>/<n> "     their OLM objects
ADOPTED_CSVN=" "      # " <csv-name> "                                CSV names, for OLM's copies elsewhere
ADOPTED_SUB_INFO=""   # name|ns|ok|missing|<installedCSV>             consumed by section [1/9]

build_adoption_index() {
  local rows row name ns og
  [ -n "$STATE_KV" ] || return 0
  rows="$(state_ops adopted)"
  [ -n "$rows" ] || return 0
  ADOPTED_SUB_INFO="$(printf '%s\n' "$rows" | run_parallel adopted_probe)"
  while IFS='|' read -r name ns _ csv; do
    [ -n "$name" ] || continue
    [ -n "$ns" ] || continue
    ADOPTED_NS="${ADOPTED_NS}${ns} "
    ADOPTED_OBJ="${ADOPTED_OBJ}subscriptions:${ns}/${name} "
    if [ -n "${csv:-}" ]; then
      ADOPTED_OBJ="${ADOPTED_OBJ}clusterserviceversions:${ns}/${csv} "
      ADOPTED_CSVN="${ADOPTED_CSVN}${csv} "
    fi
    # The OperatorGroup in an adopted operator's namespace is the org's too — free, OG_INDEX is loaded.
    while IFS='|' read -r _ og _; do
      [ -n "$og" ] || continue
      ADOPTED_OBJ="${ADOPTED_OBJ}operatorgroups:${ns}/${og} "
    done < <(printf '%s\n' "$OG_INDEX" | grep "^${ns}|")
  done < <(printf '%s\n' "$ADOPTED_SUB_INFO")
  return 0
}
# shellcheck disable=SC2317,SC2329  # dispatched indirectly by run_parallel, not called by name
# (SC2329 is shellcheck >=0.10, SC2317 the same finding on 0.9.x which CI installs — name both)
adopted_probe() {  # "name ns" → "name|ns|ok|<csv>" or "name|ns|missing|"
  local name="${1%% *}" ns="${1#* }" csv row
  # Answer from the ONE cluster-wide list when it succeeded: absence from a list that came back clean
  # IS "the Subscription is gone", and it costs no round trip. Only a list that FAILED sends us back to
  # probing object by object — because "the list errored" and "there are no Subscriptions" print the
  # same empty string, and reading the second as the first would report every adopted operator's
  # Subscription as GONE, which is the loudest false alarm section [1/9] can raise.
  if [ "$SUB_INDEX_RC" -eq 0 ]; then
    row="$(awk -F'|' -v n="$ns" -v s="$name" '$1==n && $2==s {print; exit}' <<< "$SUB_INDEX")"
    if [ -n "$row" ]; then
      printf '%s|%s|ok|%s\n' "$name" "$ns" "$(cut -d'|' -f3 <<< "$row")"
    else
      printf '%s|%s|missing|\n' "$name" "$ns"
    fi
    return 0
  fi
  if csv="$(oc get subscriptions.operators.coreos.com "$name" -n "$ns" \
              -o jsonpath='{.status.installedCSV}' 2>/dev/null)"; then
    printf '%s|%s|ok|%s\n' "$name" "$ns" "$csv"
  else
    printf '%s|%s|missing|\n' "$name" "$ns"
  fi
  return 0
}

# One memoised read per object, giving every marker at once. Namespaces are pre-seeded from NS_INDEX,
# and section [8/9]'s namespaced sweep seeds everything IT lists, so on a normal run this makes no
# cluster call at all.
#
# THE CACHE IS A FILE, not a shell variable, and that is the whole point of this block. Almost every
# caller reaches obj_marks through a command substitution — `cls="$(classify_finding …)"`,
# `c="$(strip_label_cmd …)"`, `"$(marks_summary …)"` — and an assignment made inside a subshell dies
# with it. A variable therefore memoised NOTHING across call sites: a single object reported as a trace
# cost four identical `oc get`s (classify, strip labels, strip annotations, summarise), one ~0.7s round
# trip each. Measured on ksls5 2026-07-29: 601 swept objects cost 604 per-object reads and ~1.15s per
# object, which is what pushed section [8/9] past a 900s timeout twice without ever reaching a verdict.
# A file is visible to every subshell in both directions, so a marker is read once or not at all.
MARKS_CACHE=""   # in-process fallback for a run with no writable tmpdir (inherited downward, never up)
MARKS_FILE=""    # set ONCE, before any fork, so every subshell inherits the same path
marks_lookup() {  # kind ns name → the cached row, or empty
  # Prefix match on "kind|ns|name|": the row's own separator makes it exact, and no k8s name can hold a
  # `|` to forge one. index() rather than -F'|' field equality because a marker VALUE may contain `|`.
  local p="${1}|${2}|${3}|"
  if [ -n "$MARKS_FILE" ]; then
    awk -v p="$p" 'index($0,p)==1 {print; exit}' "$MARKS_FILE" 2>/dev/null
  else
    printf '%s\n' "$MARKS_CACHE" | awk -v p="$p" 'index($0,p)==1 {print; exit}'
  fi
  return 0
}
marks_put() {  # row  → remember it for every later lookup, in this shell or any other
  # Writers are SERIAL by construction: classification runs in the main shell's loops, and none of the
  # functions run_parallel dispatches (sweep_*, csv_probe, adopted_probe, crd_count) touches the cache.
  # Parallelising a classification loop later would need a per-worker file merged at the end instead.
  if [ -n "$MARKS_FILE" ]; then
    printf '%s\n' "$1" >> "$MARKS_FILE"
  else
    MARKS_CACHE="${MARKS_CACHE}${1}
"
  fi
  return 0
}
obj_marks() {  # kind name [ns] → "owner|component|stack|user|layer|tracking-id|sync-options|che-user"
  local kind="$1" name="$2" ns="${3:-}" row out
  row="$(marks_lookup "$kind" "$ns" "$name")"
  if [ -z "$row" ]; then
    if [ -n "$ns" ]; then out="$(oc get "$kind" "$name" -n "$ns" -o jsonpath="$MARKS_JP" 2>/dev/null)"
    else                  out="$(oc get "$kind" "$name" -o jsonpath="$MARKS_JP" 2>/dev/null)"; fi
    [ -n "$out" ] || out="|||||||"
    row="${kind}|${ns}|${name}|${out}"
    marks_put "$row"
  fi
  printf '%s\n' "$(printf '%s' "$row" | cut -d'|' -f4-)"
}
seed_ns_marks() {  # feed the namespace markers we already listed into the cache
  local name marks
  while IFS='|' read -r name _ marks; do
    [ -n "$name" ] || continue
    marks_put "namespace||${name}|${marks}"
  done < <(printf '%s\n' "$NS_INDEX" | awk -F'|' 'NF>=10 {print $1"|"$2"|"$3"|"$4"|"$5"|"$6"|"$7"|"$8"|"$9"|"$10}')
}
seed_index_marks() {  # kind  "ns|name|<the 8 marker fields>" lines → into the cache, no cluster call
  # The same trick section [8/9]'s namespaced sweep already uses: an index that had to be read anyway
  # carries the markers, so classify/strip/summarise all answer from memory. Rows shorter than the ten
  # fields the layout promises are dropped rather than mis-split — a half-read row would cache a WRONG
  # marker set for a real object, and a wrong marker is how "the org's" and "ours" get swapped.
  local kind="$1" ns name marks
  [ -n "${2:-}" ] || return 0
  while IFS='|' read -r ns name marks; do
    [ -n "$name" ] || continue
    marks_put "${kind}|${ns}|${name}|${marks}"
  done < <(printf '%s\n' "$2" | awk -F'|' 'NF>=10')
  return 0
}
mark_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

is_argo_own_kind() { case "$ARGO_OWN_KINDS" in *" $1 "*) return 0;; esac; return 1; }
is_ns_kind()       { case "${1%%.*}" in namespace|namespaces|ns|project|projects) return 0;; esac; return 1; }

# A namespace holding an operator CSV but no Subscription of ours is very probably the org's. Used only
# when there is no install state at all — the case where guessing would be at its most expensive.
FOREIGN_CSV_CACHE=""
ns_has_foreign_csv() {  # ns → 0 = holds a CSV we cannot account for
  local ns="$1" ans mine
  ans="$(printf '%s\n' "$FOREIGN_CSV_CACHE" | awk -F'|' -v n="$ns" '$1==n {print $2; exit}')"
  if [ -z "$ans" ]; then
    ans="no"
    # HERE-STRING, never `printf … | grep -q`. `grep -q` exits on its FIRST match while printf is still
    # writing 3760 CSV rows; printf takes SIGPIPE and, under the `set -o pipefail` at the top of this
    # file, the PIPELINE's status becomes 141 — so a match reports as a NON-match. Whether printf has
    # finished is a scheduling race, which made this whole branch a coin flip: two runs of the
    # unmodified script against one idle cluster (ksls5, 2026-07-29) returned 609 vs 602 "ours: delete"
    # and 28 vs 35 "needs a human decision", 130 differing lines. The false side is the dangerous one —
    # "no CSV here" means "ours", so the report printed `oc delete namespace` for namespaces holding an
    # operator CSV it could not attribute. state_get() documents the same trap for a different reason
    # (the stderr noise); this is the same shape deciding a destructive command.
    if grep -q "^${ns}|" <<< "$CSV_INDEX"; then
      # "does this namespace hold a Subscription of OURS" — field 5 of SUB_INDEX is the owner label's
      # VALUE, so the label selector this replaces becomes a local field test. Same fallback rule as
      # adopted_probe: only a FAILED list sends us back to the per-namespace query, because on this
      # path an empty answer means "no Subscription of ours" and would flip the verdict to DECIDE for
      # every namespace at once.
      if [ "$SUB_INDEX_RC" -eq 0 ]; then
        awk -F'|' -v n="$ns" -v v="$OWNER_VAL" '$1==n && $5==v {f=1; exit} END{exit !f}' \
          <<< "$SUB_INDEX" || ans="yes"
      else
        # Captured, not piped into `grep -q`, for the same SIGPIPE-under-pipefail reason as above: oc
        # would be killed mid-write and the pipeline's 141 would fire the `||`, reporting "no
        # Subscription of ours" for a namespace that has one.
        mine="$(oc get subscriptions.operators.coreos.com -n "$ns" -l "$OWNER_LABEL" -o name \
          --ignore-not-found 2>/dev/null)"
        [ -n "$mine" ] || ans="yes"
      fi
    fi
    FOREIGN_CSV_CACHE="${FOREIGN_CSV_CACHE}${ns}|${ans}
"
  fi
  [ "$ans" = "yes" ]
}

classify_finding() {  # kind name [ns] → "ours|" | "adopted|<why>" | "decide|<what is ambiguous>"
  local kind="$1" name="$2" ns="${3:-}" marks base probe
  base="${kind%%.*}"
  marks="$(obj_marks "$kind" "$name" "$ns")"

  # (1) The strongest signal, and the only one that needs no state file.
  case "$(mark_field "$marks" 7)" in
    *Delete=false*)
      printf 'adopted|it carries %s with Delete=false, which install.sh stamps ONLY on resources it adopted\n' "$SYNC_OPTS_ANN"
      return 0;;
  esac

  if [ -n "$STATE_KV" ]; then
    # (2) it IS an adopted operator's namespace
    if is_ns_kind "$kind"; then
      case "$ADOPTED_NS" in
        *" ${name} "*)
          printf 'adopted|it IS the namespace of an operator recorded adopted: — deleting it destroys that operator and everything it manages\n'
          return 0;;
      esac
    fi
    # (3) it IS the Subscription / CSV / OperatorGroup of an adopted operator
    case "$ADOPTED_OBJ" in
      *" ${base}:${ns}/${name} "*)
        printf 'adopted|it is the %s of an operator recorded adopted: — removing it unmanages the org operator\n' "${base%s}"
        return 0;;
    esac
    case "$kind" in
      clusterserviceversions*)
        case "$ADOPTED_CSVN" in
          *" ${name} "*)
            printf 'adopted|it is the CSV of an operator recorded adopted: (OLM copies a CSV into other namespaces)\n'
            return 0;;
        esac;;
    esac
    # (4) it LIVES IN an adopted operator's namespace. Argo's own objects are exempt — see ARGO_OWN_KINDS.
    if [ -n "$ns" ] && ! is_argo_own_kind "$kind"; then
      case "$ADOPTED_NS" in
        *" ${ns} "*)
          printf 'adopted|it lives in %s, the namespace of an operator recorded adopted:\n' "$ns"
          return 0;;
      esac
    fi
    printf 'ours|\n'
    return 0
  fi

  # (5) No state at all. Prove it is not the org's before saying it is ours.
  probe="$ns"
  is_ns_kind "$kind" && probe="$name"
  if [ -n "$probe" ] && ns_has_foreign_csv "$probe"; then
    printf 'decide|no install state is available, and %s holds an operator CSV whose Subscription carries none of our labels\n' "$probe"
    return 0
  fi
  printf 'ours|\n'
  return 0
}

# ── remedies for things that are not ours to delete ───────────────────────────
oc_target() {  # kind name [ns] → the object as `oc label`/`oc annotate` want it
  local kind="$1" name="$2" ns="${3:-}"
  is_ns_kind "$kind" && { printf 'namespace %s' "$name"; return 0; }
  if [ -n "$ns" ]; then printf '%s %s -n %s' "$kind" "$name" "$ns"; else printf '%s %s' "$kind" "$name"; fi
}

marks_summary() {  # kind name [ns] → "workshop.redhat.com/owner=ogsr, tracking-id pp-cert-manager"
  local marks out i key val
  marks="$(obj_marks "$1" "$2" "${3:-}")"
  i=1; out=""
  for key in "$OWNER_KEY" "$COMPONENT_KEY" "$STACK_KEY" "$USER_KEY" "$LAYER_KEY"; do
    val="$(mark_field "$marks" "$i")"
    [ -n "$val" ] && out="${out}${out:+, }${key}=${val}"
    i=$((i + 1))
  done
  val="$(mark_field "$marks" 6)"
  case "$val" in "${PORTFOLIO_APP_PREFIX}"*) out="${out}${out:+, }${TRACK_ANN} → ${val%%:*}";; esac
  printf '%s' "${out:-no marker readable}"
}

has_our_marks() {  # kind name [ns] → 0 when any workshop label or a pp-* tracking-id is present
  local marks i
  marks="$(obj_marks "$1" "$2" "${3:-}")"
  i=1
  while [ "$i" -le 5 ]; do
    [ -n "$(mark_field "$marks" "$i")" ] && return 0
    i=$((i + 1))
  done
  case "$(mark_field "$marks" 6)" in "${PORTFOLIO_APP_PREFIX}"*) return 0;; esac
  return 1
}

# The whole point of the trace class: remove OUR MARK, never the object.
strip_label_cmd() {  # kind name [ns] → `oc label …` removing only the keys actually present
  local marks keys i key
  marks="$(obj_marks "$1" "$2" "${3:-}")"
  keys=""; i=1
  for key in "$OWNER_KEY" "$COMPONENT_KEY" "$STACK_KEY" "$USER_KEY" "$LAYER_KEY"; do
    [ -n "$(mark_field "$marks" "$i")" ] && keys="${keys} ${key}-"
    i=$((i + 1))
  done
  [ -n "$keys" ] && printf 'oc label %s%s' "$(oc_target "$1" "$2" "${3:-}")" "$keys"
  return 0
}
strip_ann_cmd() {  # kind name [ns] → `oc annotate …` for the Argo annotations that are ours alone
  local marks anns track so
  marks="$(obj_marks "$1" "$2" "${3:-}")"
  track="$(mark_field "$marks" 6)"; so="$(mark_field "$marks" 7)"
  anns=""
  case "$track" in "${PORTFOLIO_APP_PREFIX}"*) anns="${anns} ${TRACK_ANN}-";; esac
  # sync-options is only removable when it holds NOTHING but our two keys. install.sh MERGES into what
  # the org had (merge_sync_options), so blanket-deleting the annotation could drop their options too.
  [ "$so" = "Prune=false,Delete=false" ] && anns="${anns} ${SYNC_OPTS_ANN}-"
  [ -n "$anns" ] && printf 'oc annotate %s%s' "$(oc_target "$1" "$2" "${3:-}")" "$anns"
  return 0
}

# One call site for the whole trace remedy, so every section words it identically.
report_trace() {  # kind name ns headline
  local kind="$1" name="$2" ns="${3:-}" head="$4" c
  found trace "$head"
  c="$(strip_label_cmd "$kind" "$name" "$ns")"; [ -n "$c" ] && stripcmd "$c"
  c="$(strip_ann_cmd   "$kind" "$name" "$ns")"; [ -n "$c" ] && stripcmd "$c"
  case "$(mark_field "$(obj_marks "$kind" "$name" "$ns")" 7)" in
    ""|"Prune=false,Delete=false") ;;
    *) sub "${SYNC_OPTS_ANN} was merged into options the org already set — left alone, remove ours by hand";;
  esac
  return 0
}
report_decide() {  # kind name ns headline why
  found decide "$4"
  sub "ambiguous because: $5"
  sub "NO removal command is printed for this line — deleting the org's object is not recoverable."
  sub "check: oc describe $(oc_target "$1" "$2" "${3:-}")   and re-run with --state-file PATH if you have the dump"
  return 0
}

# ── shared diagnosis: why is this namespace stuck? ────────────────────────────
# Two completely different failures present as "Terminating", with completely different blast radii:
#   discovery failure → EVERY namespace on the cluster wedges, including ones that were never ours
#   remaining finalizer → only this namespace wedges, and only until its controller runs the finalizer
# The output has to make plain which one an admin is looking at.
diagnose_stuck_ns() {  # ns
  local ns="$1" conds disc rtype obj fins owner_csv
  conds="$(oc get namespace "$ns" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" :: "}{.message}{"\n"}{end}' 2>/dev/null)"
  [ -n "$conds" ] || { sub "no status conditions readable — the namespace object may already be gone"; return 0; }

  disc="$(printf '%s\n' "$conds" | grep -c 'NamespaceDeletionDiscoveryFailure')"
  if [ "$disc" -gt 0 ]; then
    sub "API DISCOVERY IS FAILING for this namespace — this is the cluster-wide class."
    sub "Kubernetes cannot enumerate resource types, so garbage collection stops for EVERY"
    sub "namespace on the cluster, not just ours. See section [6/9] for the stale APIService"
    sub "that usually causes it; removing that unblocks all of them at once."
    printf '%s\n' "$conds" | sed 's/^/         /'
    return 0
  fi

  printf '%s\n' "$conds" | sed 's/^/         /'
  # Go one level deeper than the condition message: name the object, its finalizer, and — the part
  # that decides what the admin should do — whether a controller for it still exists.
  while IFS= read -r rtype; do
    [ -n "$rtype" ] || continue
    if ! oc get "$rtype" -n "$ns" >/dev/null 2>&1; then
      sub "type ${rtype} no longer resolves (its CRD was removed while an instance was still"
      sub "finalizing) — the object cannot be addressed by type, so this can never complete."
      continue
    fi
    while IFS='|' read -r obj fins; do
      [ -n "$obj" ] || continue
      sub "blocked by ${rtype}/${obj}  finalizers: ${fins%,}"
      # Exact field match against each CSV's owned-CRD list — a substring grep would call an
      # unrelated operator the owner and tell the admin to wait for a controller that isn't there.
      load_csv_owned   # the only caller that needs full CSV specs; nothing pays for it otherwise
      owner_csv="$(printf '%s\n' "$CSV_OWNED_INDEX" \
        | awk -F'|' -v t="$rtype" '{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]==t){print $1"/"$2" ("$3")"; exit}}')"
      if [ -n "$owner_csv" ]; then
        sub "a controller for ${rtype} IS still installed (${owner_csv}) — the finalizer can still"
        sub "complete on its own. WAIT before forcing anything."
      else
        sub "NO operator on this cluster owns ${rtype} — nothing will ever run this finalizer."
        sub "Clearing it is a destructive last resort and YOUR decision: it drops the operator's"
        sub "own cleanup (external state the operator would have released stays behind)."
        subcmd "oc patch ${rtype} ${obj} -n ${ns} --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'"
      fi
    done < <(oc get "$rtype" -n "$ns" -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.metadata.name}|{range .metadata.finalizers[*]}{.}{","}{end}{"\n"}{end}' 2>/dev/null)
  done < <(printf '%s\n' "$conds" | grep -oE '[a-z0-9.-]+\.[a-z0-9-]+ has [0-9]+ resource instances' | sed 's/ has.*//' | sort -u)
  # Never suggest patching the NAMESPACE's own finalizer: it deletes the namespace object while its
  # content stays behind as untracked garbage. The fix is always on the blocking object.
}

# ── [1/9] adopted operators still healthy? ────────────────────────────────────
section_adopted_health() {
  hdr "1/9" "the org's own (adopted) operators — still healthy?" \
    "An adopted operator left broken is worse than any amount of litter: the cluster looks fine and stops being maintained. Every operator this install found already present must still be Succeeded."
  if [ -z "$STATE_KV" ]; then
    note "no install state available — cannot tell adopted from created."
    note "run with --state-file PATH (ogsr-uninstall.sh prints the path it wrote), or accept that"
    note "this section and section [9/9] cannot be checked on this cluster."
    return 0
  fi
  local name ns st csv phase reason
  [ -n "$ADOPTED_SUB_INFO" ] || { none "no adopted operators recorded — this install created everything it used"; return 0; }
  # build_adoption_index already probed every adopted Subscription (fully qualified, always: Knative's
  # subscriptions.messaging.knative.dev shadows the OLM one and a bare `subscription` silently reports
  # every operator as absent — SEV1 here, fixed in 437bbf4). Reuse it rather than probing twice.
  while IFS='|' read -r name ns st csv; do
    [ -n "$name" ] || continue
    [ -n "$ns" ] || continue
    if [ "$st" = "missing" ]; then
      found adopted "adopted operator ${ns}/${name} — its Subscription is GONE (we must never remove an adopted operator)" \
        "reinstall it from OperatorHub: the org owned this before the workshop was installed"
      sub "section [3/9] shows the same damage from the other side: their CSV is still there and now"
      sub "belongs to no Subscription. Do not delete that CSV — it IS their running operator."
      continue
    fi
    if [ -z "$csv" ]; then
      found adopted "adopted operator ${ns}/${name} — Subscription has no installedCSV (OLM is not resolving it)" \
        "oc describe subscriptions.operators.coreos.com ${name} -n ${ns}   # read status.conditions"
      continue
    fi
    # One lookup, not two, and via a here-string — see state_get() above for why `printf | grep -m1`
    # emits a Broken pipe error into the report. This is the site that actually did it (twice, once
    # per line) on every adopted operator the checker examined.
    csv_row="$(grep -m1 "^${ns}|${csv}|" <<< "$CSV_INDEX")"
    phase="$(cut -d'|' -f3 <<< "$csv_row")"
    reason="$(cut -d'|' -f4 <<< "$csv_row")"
    if [ "$phase" = "Succeeded" ]; then
      [ "$QUIET" = "true" ] || echo "   ✅ ${ns}/${name} — ${csv} Succeeded"
    else
      found adopted "adopted operator ${ns}/${name} — CSV ${csv} is ${phase:-<unknown>}${reason:+ (${reason})}" \
        "oc describe csv ${csv} -n ${ns}"
      [ "$reason" = "TooManyOperatorGroups" ] && sub "see section [2/9] — an OperatorGroup we added is what stopped OLM reconciling it"
    fi
  done < <(printf '%s\n' "$ADOPTED_SUB_INFO")
}

# ── [2/9] OperatorGroup conflicts ─────────────────────────────────────────────
section_operatorgroups() {
  hdr "2/9" "namespaces with more than one OperatorGroup" \
    "OLM refuses to reconcile a CSV in a namespace carrying two OperatorGroups (TooManyOperatorGroups). Pods keep running, so nothing looks wrong — the operator has simply stopped being managed and will not upgrade or self-heal."
  local dupes ns name owner ours csv_ns csv_name csv_reason hit=0
  if [ -z "$OG_INDEX" ]; then note "could not list OperatorGroups — skipping"; return 0; fi
  dupes="$(printf '%s\n' "$OG_INDEX" | awk -F'|' 'NF>1 && $1!="" {c[$1]++} END{for(n in c) if(c[n]>1) print n}' | sort)"
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    hit=1
    ours=""
    found ws "namespace/${ns} has more than one OperatorGroup — OLM cannot pick one, so it manages none"
    # A trailing `_` so `owner` is FIELD 3 and not "field 3 onwards". bash's `read` hands the last
    # variable the unsplit remainder, so with three variables `owner` silently became
    # `ogsr|Prune=false,Delete=false` whenever the OperatorGroup carried sync-options — and
    # `[ "$owner" = "ogsr" ]` is then false, so an OperatorGroup WE added to an adopted operator's
    # namespace (the exact object that causes TooManyOperatorGroups, and the only one that always
    # carries Delete=false) printed as "not ours — never delete this one". Positional, not remainder:
    # this row decides whether an admin is handed a delete command for their own object.
    while IFS='|' read -r _ name owner _; do
      [ -n "$name" ] || continue
      if [ "$owner" = "$OWNER_VAL" ]; then
        sub "${name}  ← ADDED BY THIS WORKSHOP (${OWNER_KEY}=${owner})"
        ours="$name"
      else
        sub "${name}  ← not ours (no owner label) — never delete this one"
      fi
    done < <(printf '%s\n' "$OG_INDEX" | grep "^${ns}|")
    if [ -n "$ours" ]; then
      subcmd "oc delete operatorgroups.operators.coreos.com ${ours} -n ${ns}"
      sub "after deleting ours, OLM re-reconciles the org's CSV within a minute"
    else
      sub "none of them carries our owner label — this conflict is not ours to resolve; left for you"
    fi
  done < <(printf '%s\n' "$dupes")

  # A CSV can still be parked in Failed/TooManyOperatorGroups after the duplicate is gone.
  while IFS='|' read -r csv_ns csv_name _ csv_reason; do
    [ -n "$csv_name" ] || continue
    hit=1
    found adopted "csv ${csv_ns}/${csv_name} is Failed: ${csv_reason} — the operator is not being managed" \
      "oc delete csv ${csv_name} -n ${csv_ns}   # OLM recreates it from the Subscription once only ONE OperatorGroup remains"
  done < <(printf '%s\n' "$CSV_INDEX" | awk -F'|' '$3=="Failed" && $4=="TooManyOperatorGroups" {print $1"|"$2"|"$3"|"$4}')

  [ "$hit" -eq 0 ] && none "every namespace has at most one OperatorGroup"
  return 0
}

# ── [3/9] CSVs that no Subscription owns ──────────────────────────────────────
# An org that installs an operator through OLM the normal way ends up with a Subscription, and the CSV
# is that Subscription's `status.installedCSV`. A CSV that no Subscription points at is an ORPHAN, and
# an orphan is our fingerprint: the cascade deletes the Subscription (Argo manages it) while nothing
# prunes the CSV (OLM created it, Argo never did). Adoption logic that only reads labels calls such a
# CSV "adopted, preserved" — which is exactly backwards, and hides our own mess behind a word that
# means "the org's".
#
# Worse than litter: an orphan CSV BREAKS THE NEXT INSTALL of this workshop. OLM resolves the new
# Subscription against the CSV that is already there and gives up —
#   constraints not satisfiable: @existing/openshift-operators//devspacesoperator.v3.29.0,
#                                redhat-operators/openshift-marketplace/stable/devspacesoperator
# (measured on ksls5 2026-07-25; see ogsr-uninstall.sh § operator CSV identity for the full incident).
#
# Note what this section does NOT use: labels. Measured on ksls5 2026-07-28, not one CSV on the cluster
# carries a workshop label, a portfolio label or a pp-* tracking-id — Argo manages Subscriptions, not
# CSVs. The only mark we ever leave on a CSV is install.sh's `Delete=false`, and that is stamped on
# ADOPTED resources alone. On a CSV, therefore, a mark of ours is evidence the object is the ORG'S; it
# is never evidence that it is ours. The Subscription is the only signal that can answer the question.
ORPHAN_CSV_JP='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.phase}|{.spec.replaces}|{.metadata.labels.olm\.clusteroperator\.name}|{.metadata.annotations.olm\.copiedFrom}{"\n"}{end}'

section_orphan_csvs() {
  hdr "3/9" "ClusterServiceVersions that no Subscription owns" \
    "An operator installed through OLM has a Subscription, and its CSV is that Subscription's status.installedCSV. A CSV nobody subscribes to is an orphan — normally ours, left behind when the cascade took the Subscription and nothing pruned the CSV. Not just litter: OLM resolves the NEXT install against it and fails with 'constraints not satisfiable'."

  local csv_rows sub_rows ef rc skipped hit row
  local ns name phase coname copied owner_sub unresolved elsewhere successor cls why verdict
  ef=""; skipped=""; hit=0
  tmproot && ef="${TMPROOT}/orphan-csv.err"

  # `-l '!olm.copiedFrom'` drops OLM's per-namespace COPIES server-side, and that is load-bearing rather
  # than an optimisation. A copy legitimately lives in a namespace with no Subscription — it is the
  # original elsewhere that has one — so every copy is a false orphan. Measured on ksls5 2026-07-28:
  # 3760 CSVs on the cluster, 3723 of them copies. Unfiltered, this section would print 3723 delete
  # commands for objects OLM re-creates the moment you remove them.
  csv_rows="$(oc get clusterserviceversions.operators.coreos.com -A -l '!olm.copiedFrom' \
    -o jsonpath="$ORPHAN_CSV_JP" 2>"${ef:-/dev/null}")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Distinct from "there are none": a Forbidden list and an empty cluster both print nothing, so the
    # EXIT STATUS is what is read here, never the emptiness of the output.
    note "could not list ClusterServiceVersions (oc exited ${rc}) — this section could not run"
    if [ -n "$ef" ] && [ -s "$ef" ]; then sub "$(head -1 "$ef")"; fi
    DISCOVERY_NOTE="${DISCOVERY_NOTE}CSV list failed, the orphan-CSV check did not run; "
    return 0
  fi
  csv_rows="$(printf '%s\n' "$csv_rows" | grep -v '^ *$')"
  [ -n "$csv_rows" ] || { none "no ClusterServiceVersion is installed on this cluster"; return 0; }

  # THE dangerous read — now made ONCE, in load_indexes, and shared (see SUB_INDEX for the full
  # reasoning and the forbidden-list measurement). Nothing about the failure contract changes here: the
  # status is carried alongside the rows precisely so this section can still tell "the list errored"
  # from "there are no Subscriptions", which print the same empty string. It is only read once instead
  # of twice.
  sub_rows="$(printf '%s\n' "$SUB_INDEX" | cut -d'|' -f1-4 | grep -v '^ *$')"
  rc="$SUB_INDEX_RC"
  if [ "$rc" -ne 0 ]; then
    note "could not list Subscriptions (oc exited ${rc}) — NOT reporting any orphan"
    if [ -n "$SUB_INDEX_ERR" ]; then sub "$SUB_INDEX_ERR"; fi
    sub "without the Subscription list every CSV would read as unowned, so this section reports"
    sub "nothing rather than name the org's operators as ours. Re-run as an admin who can list"
    sub "subscriptions.operators.coreos.com cluster-wide."
    DISCOVERY_NOTE="${DISCOVERY_NOTE}Subscription list failed, the orphan-CSV check did not run; "
    return 0
  fi

  # spec.replaces is in the row but is read out of $csv_rows by awk below (a CSV's successor is a
  # DIFFERENT row than its own), so this loop drops it rather than shadowing the lookup with a name.
  while IFS='|' read -r ns name phase _ coname copied; do
    [ -n "$name" ] || continue
    [ -n "$ns" ] || continue

    # Older OLM recorded the copy as an ANNOTATION, which the label selector above cannot exclude.
    [ -z "$copied" ] || continue

    # A CSV carrying olm.clusteroperator.name is installed by the cluster-version-operator, not by a
    # Subscription — it backs a ClusterOperator. `packageserver` in openshift-operator-lifecycle-manager
    # is that case on EVERY OpenShift cluster (ksls5 2026-07-28: the only original CSV of 37 with no
    # Subscription), so without this it is a guaranteed false positive on every run, on every cluster.
    # The namespace test is belt-and-braces for a future core CSV that carries no such label: OLM's own
    # namespace is never one we install into.
    if [ -n "$coname" ] || [ "$ns" = "openshift-operator-lifecycle-manager" ]; then
      skipped="${skipped}${ns}/${name} — installed by the cluster itself (ClusterOperator ${coname:-core OLM}), no Subscription is expected
"
      continue
    fi

    owner_sub="$(printf '%s\n' "$sub_rows" | awk -F'|' -v n="$ns" -v c="$name" \
      '$1==n && ($3==c || $4==c) {print $2; exit}')"
    [ -z "$owner_sub" ] || continue

    # Mid-upgrade, OLM's successor CSV names the outgoing one in spec.replaces while the Subscription
    # has already moved on to the successor. The outgoing CSV is momentarily pointed at by neither
    # status field — owned, not orphaned, and OLM garbage-collects it on its own.
    successor="$(printf '%s\n' "$csv_rows" | awk -F'|' -v n="$ns" -v c="$name" \
      '$1==n && $4==c {print $2; exit}')"
    if [ -n "$successor" ]; then
      skipped="${skipped}${ns}/${name} — being replaced by ${successor} (an upgrade in flight, not an orphan)
"
      continue
    fi

    hit=1
    unresolved="$(printf '%s\n' "$sub_rows" | awk -F'|' -v n="$ns" \
      '$1==n && $3=="" && $4=="" {print $2; exit}')"
    elsewhere="$(printf '%s\n' "$sub_rows" | awk -F'|' -v n="$ns" -v c="$name" \
      '$1!=n && ($3==c || $4==c) {print $1"/"$2; exit}')"

    if [ -n "$unresolved" ]; then
      # A Subscription that has resolved to nothing yet may be about to adopt this very CSV. That is an
      # install in flight, not a leftover, and it is the one case where an orphan must not carry a
      # delete command however it classifies.
      report_decide clusterserviceversions.operators.coreos.com "$name" "$ns" \
        "csv/${name} -n ${ns} — ${phase:-<unknown>}, no Subscription owns it, but one in ${ns} is still resolving" \
        "subscriptions.operators.coreos.com/${unresolved} in ${ns} has neither installedCSV nor currentCSV set — it may be about to claim this CSV"
      continue
    fi

    cls="$(classify_finding clusterserviceversions.operators.coreos.com "$name" "$ns")"
    why="${cls#*|}"
    verdict="${cls%%|*}"
    # WITHOUT install state, "ours" is a guess this section refuses to make. An orphan we left and an
    # operator the ORG installed and later unsubscribed by hand look identical from the cluster alone.
    # classify_finding's no-state fallback decides by asking whether the namespace holds a CSV it cannot
    # account for — an inference that is circular here, because the object being classified IS that CSV,
    # and one that reads "not foreign" whenever its CSV index came back empty for any reason. Measured
    # against fixtures 2026-07-28: left to that path, an unsubscribed cert-manager in the org's own
    # namespace printed `oc delete` for the org's operator. Adoption evidence (Delete=false) still
    # stands on its own — it needs no state — so only the "ours" side is downgraded.
    if [ -z "$STATE_KV" ] && [ "$verdict" != "adopted" ]; then
      verdict="decide"
      why="no install state is available, so an orphan we left cannot be told from an operator the org installed and later unsubscribed by hand"
    fi
    case "$verdict" in
      adopted)
        # The worst version of this finding, and the reason it is NOT filed as litter: an orphan in an
        # adopted operator's namespace means the ORG'S operator has lost its Subscription. The CSV is
        # the running operator — deleting it uninstalls their operator outright. Restoring the
        # Subscription is the fix, and section [1/9] reports it from the other direction.
        found adopted "csv/${name} -n ${ns} — no Subscription owns it, and it belongs to the ORG: ${why}"
        sub "their operator is now UNMANAGED: with no Subscription, OLM will not upgrade or repair it."
        sub "do NOT delete this CSV — it IS the running operator. Restore the Subscription instead"
        sub "(OperatorHub, same package and channel the org had), and OLM re-adopts this CSV."
        sub "check: oc get subscriptions.operators.coreos.com -n ${ns}   # expect: the org's, missing"
        ;;
      decide)
        report_decide clusterserviceversions.operators.coreos.com "$name" "$ns" \
          "csv/${name} -n ${ns} — ${phase:-<unknown>}, no Subscription owns it" "$why"
        ;;
      *)
        found ws "csv/${name} -n ${ns} — ${phase:-<unknown>}, no Subscription owns it (orphaned by our teardown)" \
          "oc delete clusterserviceversions.operators.coreos.com ${name} -n ${ns}"
        sub "leaving it makes the NEXT install of this workshop fail to resolve this operator"
        sub "('constraints not satisfiable: @existing/...'), so this one is worth acting on."
        ;;
    esac
    # A Subscription elsewhere installing the same CSV NAME does not own this object — two namespaces
    # can run the same operator (ksls5 2026-07-28: rhbk-operator.v26.6.4-opr.1 in both openshift-mta and
    # sso-workshop, each with its own Subscription). Said as context, never as a reason to spare it.
    if [ -n "$elsewhere" ]; then
      sub "note: ${elsewhere} installs the same CSV name in its own namespace — a different object, and"
      sub "no evidence about this one."
    fi
  done < <(printf '%s\n' "$csv_rows")

  [ "$hit" -eq 0 ] && none "every ClusterServiceVersion is owned by a Subscription"
  # Printed as context, not as findings: these carry no count and cannot affect the exit code. They are
  # here because "the section found nothing" and "the section excluded something on purpose" are
  # different statements, and only the second one is auditable.
  if [ "$QUIET" != "true" ] && [ -n "$skipped" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      note "not an orphan: ${row}"
    done < <(printf '%s\n' "$skipped")
  fi
  return 0
}

# ── [4/9] workshop namespaces ─────────────────────────────────────────────────
ns_is_ours() {  # name owner component stack user layer track che-user → 0 and echoes the marker that identified it
  local name="$1" owner="$2" comp="$3" stack="$4" user="$5" layer="$6" track="${7:-}" che="${8:-}"
  [ -n "$owner" ] && { echo "${OWNER_KEY}=${owner}"; return 0; }
  [ -n "$comp" ]  && { echo "${COMPONENT_KEY}=${comp}"; return 0; }
  [ -n "$stack" ] && { echo "${STACK_KEY}=${stack}"; return 0; }
  [ -n "$user" ]  && { echo "${USER_KEY}=${user}"; return 0; }
  [ -n "$layer" ] && { echo "${LAYER_KEY}=${layer}"; return 0; }
  # A namespace whose labels were stripped but which an Argo portfolio app still claims is STILL a trace.
  case "$track" in "${PORTFOLIO_APP_PREFIX}"*) echo "${TRACK_ANN} → ${track%%:*}"; return 0;; esac
  # A Dev Spaces workspace namespace auto-provisioned FOR ONE OF OUR ATTENDEES. Gate on the attendee
  # identity, not merely on the annotation being present: on a cluster whose Dev Spaces we adopted,
  # the org's own users have these too and they are emphatically not ours. userN is the canonical
  # workshop identity (install.sh USER_PREFIX="user", the same rule `ws` validates --user against).
  case "$che" in
    user[0-9]*) echo "${CHE_USER_ANN}=${che} — Dev Spaces auto-provisioned this for our attendee"; return 0;;
  esac
  case "$name" in "${NS_PREFIX}"*) echo "name prefix ${NS_PREFIX}* (no label — teardown could not see it)"; return 0;; esac
  return 1
}

OURS_NS_LIST=" "   # filled here, consumed by section 4 so it does not re-report the same namespaces
section_namespaces() {
  hdr "4/9" "namespaces carrying a mark of this workshop" \
    "A mark is not proof of ownership: Argo stamps our labels onto resources it ADOPTED, so the org's own operator namespace ends up labelled by us. Each line below says whether the namespace is ours to delete, ours only to un-mark, or genuinely undecidable."
  local name phase owner comp stack user layer track marker cls why hit=0
  if [ -z "$NS_INDEX" ]; then note "could not list namespaces — skipping"; return 0; fi
  while IFS='|' read -r name phase owner comp stack user layer track _ che _; do
    [ -n "$name" ] || continue
    marker="$(ns_is_ours "$name" "$owner" "$comp" "$stack" "$user" "$layer" "$track" "$che")" || continue
    hit=1
    OURS_NS_LIST="${OURS_NS_LIST}${name} "
    cls="$(classify_finding namespace "$name" "")"
    why="${cls#*|}"
    case "${cls%%|*}" in
      adopted)
        if [ "$phase" = "Terminating" ]; then
          # An adopted operator's namespace being torn down is the worst outcome in this whole script.
          found adopted "namespace/${name} — TERMINATING, and it is the org's, not ours: ${why}"
          sub "this namespace must not go. If it completes, the org loses that operator."
          diagnose_stuck_ns "$name"
        else
          report_trace namespace "$name" "" \
            "namespace/${name} — ${phase}, marked by us (${marker}) but NOT ours to delete: ${why}"
        fi;;
      decide)
        report_decide namespace "$name" "" \
          "namespace/${name} — ${phase}, marked by us (${marker}) — CANNOT TELL whether we created it" "$why";;
      *)
        if [ "$phase" = "Terminating" ]; then
          found health "namespace/${name} — Terminating (identified by ${marker})"
          diagnose_stuck_ns "$name"
        else
          found ws "namespace/${name} — ${phase} (identified by ${marker})" "oc delete namespace ${name}"
        fi;;
    esac
  done < <(printf '%s\n' "$NS_INDEX")
  [ "$hit" -eq 0 ] && none "no namespace carries a workshop mark"
  return 0
}

# ── [5/9] anything else wedged ────────────────────────────────────────────────
section_other_terminating() {
  hdr "5/9" "other namespaces stuck Terminating (not ours)" \
    "Listed because our teardown can wedge namespaces that were never ours — a stale APIService stops garbage collection cluster-wide. If these appear, look at section [6/9] first; one fix usually releases all of them."
  local name phase hit=0
  [ -n "$NS_INDEX" ] || { note "could not list namespaces — skipping"; return 0; }
  while IFS='|' read -r name phase _; do
    [ "$phase" = "Terminating" ] || continue
    case "$OURS_NS_LIST" in *" $name "*) continue;; esac
    hit=1
    found health "namespace/${name} — Terminating, and it is NOT one of ours"
    diagnose_stuck_ns "$name"
  done < <(printf '%s\n' "$NS_INDEX")
  [ "$hit" -eq 0 ] && none "no other namespace is stuck"
  return 0
}

# ── [6/9] stale APIServices ───────────────────────────────────────────────────
section_apiservices() {
  hdr "6/9" "APIServices whose backing Service no longer exists" \
    "The highest-impact class there is. An aggregated APIService with no backend makes discovery fail, and Kubernetes then refuses to garbage-collect ANY namespace on the cluster — 92 of them wedged in the 2026-07-25 teardown, most not ours."
  local name svc_ns svc_nm avail hit=0
  while IFS='|' read -r name svc_ns svc_nm avail; do
    [ -n "$name" ] || continue
    [ -n "$svc_ns" ] || continue
    case "$SVC_INDEX" in *" ${svc_ns}/${svc_nm} "*) continue;; esac
    hit=1
    found health "apiservice/${name} → backing service ${svc_ns}/${svc_nm} does not exist (Available=${avail:-?})" \
      "oc delete apiservices.apiregistration.k8s.io ${name}"
    sub "check first that the namespace is not simply mid-restart — a Service that is coming back"
    sub "makes this self-heal, while a Service whose namespace is gone never will."
  done < <(oc get apiservices.apiregistration.k8s.io -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.service.namespace}|{.spec.service.name}|{range .status.conditions[?(@.type=="Available")]}{.status}{end}{"\n"}{end}' 2>/dev/null)
  [ "$hit" -eq 0 ] && none "every aggregated APIService has a live backing Service"
  return 0
}

# ── [7/9] orphaned admission webhooks ─────────────────────────────────────────
section_webhooks() {
  hdr "7/9" "admission webhooks pointing at a Service that no longer exists" \
    "A webhook whose backend is gone rejects or hangs every create/update it intercepts, which blocks deletion of objects in the namespaces it covers. Only ones with failurePolicy=Fail actually block; Ignore is listed as informational."
  local kind w refs ref rns rnm pol hit=0
  for kind in validatingwebhookconfigurations.admissionregistration.k8s.io \
              mutatingwebhookconfigurations.admissionregistration.k8s.io; do
    while IFS='|' read -r w refs pol; do
      [ -n "$w" ] || continue
      for ref in $refs; do
        case "$ref" in ""|"/") continue;; esac
        rns="${ref%%/*}"; rnm="${ref##*/}"
        [ -n "$rns" ] || continue
        [ -n "$rnm" ] || continue
        case "$SVC_INDEX" in *" ${ref} "*) continue;; esac
        hit=1
        found health "${kind}/${w} → missing service ${ref}" "oc delete ${kind} ${w}"
        case " $pol " in
          *" Fail "*) sub "failurePolicy=Fail — this one actively blocks writes to everything it intercepts";;
          *)          sub "failurePolicy=${pol:-?} — requests fall through, so this is litter rather than a blocker";;
        esac
        break
      done
    done < <(oc get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}|{range .webhooks[*]}{.clientConfig.service.namespace}/{.clientConfig.service.name}{" "}{end}|{range .webhooks[*]}{.failurePolicy}{" "}{end}{"\n"}{end}' 2>/dev/null)
  done
  [ "$hit" -eq 0 ] && none "every admission webhook points at a live Service"
  return 0
}

# ── [8/9] objects still carrying a workshop label ─────────────────────────────
CLUSTER_KINDS_FALLBACK="clusterroles.rbac.authorization.k8s.io clusterrolebindings.rbac.authorization.k8s.io
groups.user.openshift.io customresourcedefinitions.apiextensions.k8s.io apiservices.apiregistration.k8s.io
validatingwebhookconfigurations.admissionregistration.k8s.io mutatingwebhookconfigurations.admissionregistration.k8s.io
clusterqueues.kueue.x-k8s.io resourceflavors.kueue.x-k8s.io workloadpriorityclasses.kueue.x-k8s.io
gatewayclasses.gateway.networking.k8s.io storageclasses.storage.k8s.io consoleplugins.console.openshift.io"

# Namespaced kinds worth sweeping cluster-wide. Not every namespaced kind: objects inside a namespace
# we deleted are gone with it. What matters is what we left in namespaces we deliberately PRESERVED
# (openshift-gitops, openshift-monitoring, the org's operator namespaces).
NAMESPACED_KINDS="applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io
operatorgroups.operators.coreos.com subscriptions.operators.coreos.com
imagestreams.image.openshift.io secrets configmaps serviceaccounts
rolebindings.rbac.authorization.k8s.io roles.rbac.authorization.k8s.io
localqueues.kueue.x-k8s.io"

# Cluster-scoped kinds discovery returns that must NOT be swept, one line each for `grep -vxF`.
#
# The last three are LEGACY OpenShift MIRRORS: a second endpoint onto objects another API group already
# serves. `projects.project.openshift.io` is the namespace list, and the two
# `authorization.openshift.io` kinds are the RBAC objects. Sweeping a mirror does not find anything new
# — it finds the SAME object again — so every finding is printed twice, once per group, with two
# different `oc delete` commands for one object, and the VERDICT counts stop being a count of things.
# It also costs a classification round trip per duplicate. Measured on ksls5 2026-07-29: 150 of the 182
# cluster-scoped hits were mirrors — 136 Projects, which section [4/9] already reports WITH the stuck-
# namespace diagnosis a bare `oc delete project` line cannot give, plus 14 duplicate ClusterRole and
# ClusterRoleBinding lines. Verified as mirrors, not coincidence: both groups returned identical name
# sets for the same label selector.
# componentstatuses is deprecated and holds nothing; projectrequests is a request-only virtual resource
# that answers a list with a Status object (see drop_phantoms — it is filtered there as well).
SWEEP_SKIP_KINDS="componentstatuses
namespaces
projectrequests.project.openshift.io
projects.project.openshift.io
clusterroles.authorization.openshift.io
clusterrolebindings.authorization.openshift.io"

SWEEP_EXTRA=""   # "" or "-A"; set by sweep_labeled, read by the workers run_parallel forks
SWEEP_FAILED=""  # path of the file workers append a failed chunk to (a subshell cannot set a parent var)

sweep_labeled() {  # scope(cluster|ns) kinds… — batched gets, run SWEEP_JOBS at a time
  local scope="$1"; shift
  local kinds="$*" chunk="" n=0 k list=""
  SWEEP_EXTRA=""
  [ "$scope" = "ns" ] && SWEEP_EXTRA="-A"
  # Chunks of 15 amortise oc's ~0.4s start-up over 15 list requests; running the CHUNKS concurrently is
  # what actually pays, because each chunk is a serial round-trip the API server answers independently.
  # Measured on a 168-cluster-kind cluster: 53s serial → ~9s at SWEEP_JOBS=8, identical output.
  for k in $kinds; do
    chunk="${chunk}${chunk:+,}${k}"; n=$((n + 1))
    if [ "$n" -ge 15 ]; then list="${list}${chunk}
"; chunk=""; n=0; fi
  done
  [ -n "$chunk" ] && list="${list}${chunk}
"
  [ -n "$list" ] || return 0
  if tmproot; then SWEEP_FAILED="${TMPROOT}/sweep-failed"; : > "$SWEEP_FAILED"; else SWEEP_FAILED=""; fi
  printf '%s' "$list" | run_parallel sweep_chunk
  # The "(partial scan: …)" note is built by the CALLER, from the file, not here. This function's own
  # output is consumed through a command substitution, so its body runs in a subshell and any
  # DISCOVERY_NOTE it appended would be discarded when that subshell exits — the note was silently lost
  # for every failed batch (the previous `< <(sweep_labeled …)` process substitution lost it the same
  # way). A warning that cannot reach the verdict is worse than no warning at all.
  return 0
}
sweep_failed_kinds() {  # → the chunks whose batched list failed, or empty. Readable from the parent.
  [ -n "$TMPROOT" ] || return 0
  [ -s "${TMPROOT}/sweep-failed" ] || return 0
  tr '\n' ' ' < "${TMPROOT}/sweep-failed"
  return 0
}
# Some endpoints answer a list request with a Status object instead of a list, and `-o name` renders
# that as the literal string `status/<unknown>` while exiting 0 — indistinguishable from a real hit.
# projectrequests.project.openshift.io is the one that does it on every OpenShift cluster (it is a
# request-only virtual resource). Left unfiltered it is a phantom finding that no admin can act on
# (`oc delete status/<unknown>` is not a command) and, because it is always present, it would make this
# script exit 1 forever — destroying the exit contract that CI and `ws doctor` depend on.
# shellcheck disable=SC2329  # called from sweep_chunk, which is itself dispatched indirectly
# shellcheck disable=SC2317  # used as a pipeline stage; 0.9.x cannot see that call site
drop_phantoms() { grep -v '^ *$' | grep -vE '^status/|/<unknown>$'; }

# `oc get <kind> -A -o name` prints `kind/name` and NOT the namespace, so the batched sweep above can
# only be used where there is no namespace to lose: cluster-scoped kinds. Namespaced kinds are swept one
# per call with an explicit jsonpath, because the classifier cannot apply its most important rule —
# "does this live in an adopted operator's namespace?" — without knowing which namespace that is.
sweep_ns_kinds() {  # kinds… → "ns|kind/name|<the 8 marker fields>" lines, SWEEP_JOBS at a time
  printf '%s\n' "$*" | tr ' ' '\n' | grep -v '^ *$' | run_parallel sweep_ns_kind
}
# shellcheck disable=SC2317,SC2329  # dispatched indirectly by run_parallel, not called by name
# (SC2329 is shellcheck >=0.10, SC2317 the same finding on 0.9.x which CI installs — name both)
sweep_ns_kind() {  # kind → "ns|kind/name|<the 8 marker fields>"
  # The markers ride along in the SAME list call that finds the object. They cost nothing here — the
  # API server is already serving these items — and they save a per-object round trip in every one of
  # the four places that later asks for them (classify, strip labels, strip annotations, summarise).
  # This is the read the caller seeds the marks cache with; without it, 419 objects meant 419+ `oc get`s.
  oc get "$1" -A -l "$OWNER_LABEL" --ignore-not-found \
    -o jsonpath="{range .items[*]}{.metadata.namespace}|${1}/{.metadata.name}|${MARKS_JP}{\"\n\"}{end}" 2>/dev/null \
    | grep -v '^ *$'
  return 0
}

# The cluster-scoped sweep above lists with `-o name`, which carries NO markers — so every object it
# found was then read back one at a time by obj_marks, in the main shell, serially. Measured on ksls5
# 2026-07-29: 35 such reads, 39.5s of `oc` wall clock inside a 128s scan, ~31% of the run, for objects
# the API server had already served once.
#
# The fix is not to widen the `-o name` sweep — a comma-list get answers with `{.kind}`, the CamelCase
# singular, and there is no reliable way back from `StorageClass` to `storageclasses.storage.k8s.io`
# for the `oc delete` line — but to make a SECOND pass keyed on what the first one found: one labelled
# list per DISTINCT kind that actually returned a hit, run at SWEEP_JOBS concurrency, seeding the same
# cache. 11 lists replaced 32 serial reads here.
#
# On the case this script exists for — a cluster with nothing left — there are no hits, so there are no
# distinct kinds and this costs exactly zero extra calls.
seed_cluster_marks() {  # "kind/name" lines → their markers into the cache, one list per kind
  local hits="$1" kinds row
  [ -n "$hits" ] || return 0
  kinds="$(printf '%s\n' "$hits" | awk -F/ 'NF>=2 && $1!="" {print $1}' | sort -u)"
  [ -n "$kinds" ] || return 0
  # marks_put runs HERE, in the main shell, not in the workers — the cache has exactly one writer by
  # construction and this keeps it that way (see marks_put).
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    marks_put "$row"
  done < <(printf '%s\n' "$kinds" | run_parallel sweep_cluster_marks)
  return 0
}
# shellcheck disable=SC2317,SC2329  # dispatched indirectly by run_parallel, not called by name
# (SC2329 is shellcheck >=0.10, SC2317 the same finding on 0.9.x which CI installs — name both)
sweep_cluster_marks() {  # kind → "kind||name|<the 8 marker fields>" rows, already shaped for marks_put
  # The kind is echoed back as LITERAL text inside the template so the row keys off the exact string
  # the `-o name` sweep produced — that string is what report_swept later looks the object up by, and a
  # normalised or re-derived spelling would miss the cache and re-read the object anyway. The empty ns
  # field between the two pipes is the cluster-scoped marker: these objects have no namespace.
  oc get "$1" -l "$OWNER_LABEL" --ignore-not-found \
    -o jsonpath="{range .items[*]}${1}||{.metadata.name}|${MARKS_JP}{\"\n\"}{end}" 2>/dev/null \
    | grep -v '^ *$'
  return 0
}

# shellcheck disable=SC2317,SC2329  # dispatched indirectly by run_parallel, not called by name
# (SC2329 is shellcheck >=0.10, SC2317 the same finding on 0.9.x which CI installs — name both)
sweep_chunk() {  # comma-list — echo "kind/name" (or "ns kind/name" when SWEEP_EXTRA=-A) lines
  local chunk="$1" extra="$SWEEP_EXTRA" out k
  # shellcheck disable=SC2086  # $extra is intentionally word-split (empty or -A)
  if out="$(oc get "$chunk" $extra -l "$OWNER_LABEL" -o name --ignore-not-found 2>/dev/null)"; then
    printf '%s\n' "$out" | drop_phantoms
    return 0
  fi
  # A single broken API group fails the whole batch — fall back to one call per kind so one bad
  # group cannot hide every other leftover. This is the graceful-degradation path, not the norm.
  [ -n "$SWEEP_FAILED" ] && printf '%s\n' "$chunk" >> "$SWEEP_FAILED"
  for k in $(printf '%s\n' "$chunk" | tr ',' ' '); do
    # shellcheck disable=SC2086
    oc get "$k" $extra -l "$OWNER_LABEL" -o name --ignore-not-found 2>/dev/null | drop_phantoms
  done
  return 0
}

# Emit one classified line for a swept object. `obj` is `kind/name`, `ns` may be empty.
report_swept() {  # kind/name  ns  scope-suffix
  local obj="$1" ns="${2:-}" where="$3" kind name cls why nsarg
  kind="${obj%%/*}"; name="${obj#*/}"
  nsarg=""; [ -n "$ns" ] && nsarg=" -n ${ns}"
  cls="$(classify_finding "$kind" "$name" "$ns")"
  why="${cls#*|}"
  case "${cls%%|*}" in
    adopted)
      report_trace "$kind" "$name" "$ns" \
        "${obj}${nsarg} (${where}) — marked by us but NOT ours to delete: ${why}";;
    decide)
      report_decide "$kind" "$name" "$ns" \
        "${obj}${nsarg} (${where}) — CANNOT TELL whether we created it" "$why";;
    *)
      if [ -n "$ns" ]; then
        found ws "${obj}${nsarg} (${where}, ${OWNER_LABEL})" "oc delete ${obj} -n ${ns}"
      else
        found ws "${obj} (${where}, ${OWNER_LABEL})" "oc delete ${obj}"
      fi;;
  esac
  return 0
}

section_labeled_objects() {
  hdr "8/9" "objects carrying a mark of this workshop" \
    "Our kustomize label transformer stamps these labels on every resource in a component, adopted ones included — so a workshop label on an object is NOT proof the workshop created it. Objects we only marked get an un-mark command; only objects we created get a delete. Argo Applications come first: they actively reconcile, so while one exists it re-creates whatever you delete."
  local obj kinds hit=0 app apps="" ns name owner comp stack layer og st csv kindres seen=" " swept marks failed

  # (a) Argo Applications / AppProjects — matched on ANY of our labels, then deduped. Child
  #     portfolio Applications carry ONLY portfolio.redhat.com/component (31 of 32 of them), so an
  #     owner-label-only scan misses the apps that do the reconciling. One list, filtered locally:
  #     four label-selected gets cost four round-trips to answer a question one read already answers.
  while IFS='|' read -r name owner comp stack layer; do
    [ -n "$name" ] || continue
    [ -n "${owner}${comp}${stack}${layer}" ] || continue
    apps="${apps}${name}
"
  done < <(oc get applications.argoproj.io,applicationsets.argoproj.io -n "$ARGO_NS" -o jsonpath="{range .items[*]}{.kind}/{.metadata.name}|{.metadata.labels.${OWNER_KEY//./\\.}}|{.metadata.labels.${COMPONENT_KEY//./\\.}}|{.metadata.labels.${STACK_KEY//./\\.}}|{.metadata.labels.${LAYER_KEY//./\\.}}{\"\n\"}{end}" 2>/dev/null)
  prog "$(printf '%s\n' "$apps" | grep -c .) Argo Application(s)/ApplicationSet(s) to report"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    hit=1
    # `.kind` is Application/ApplicationSet; the plural + group is what `oc delete` wants.
    kindres="$(printf '%s' "${app%%/*}" | tr '[:upper:]' '[:lower:]')s.argoproj.io"
    # An Argo Application in our Argo namespace is one we created — the portfolio never adopts the
    # org's Applications — so this stays a delete. classify_finding's ARGO_OWN_KINDS exemption exists
    # for exactly this: a still-reconciling app cannot be dealt with by removing a label.
    found ws "${app} in ${ARGO_NS} — STILL RECONCILING (it re-creates whatever you remove)" \
      "oc delete ${kindres}/${app#*/} -n ${ARGO_NS}"
    seen="${seen}${app#*/} "
  done < <(printf '%s\n' "$apps" | grep -v '^ *$' | sort -u)

  # (b) cluster-scoped sweep, driven by live discovery so nothing is missed by a stale hardcoded
  #     list, minus the kinds in SWEEP_SKIP_KINDS (namespaces — section [4/9] reports those with
  #     diagnosis — plus the legacy mirrors and the two virtual resources; see that list for why).
  kinds="$(oc api-resources --namespaced=false --verbs=list -o name 2>/dev/null \
            | grep -vxF "$SWEEP_SKIP_KINDS" | tr '\n' ' ')"
  if [ -z "$kinds" ]; then
    DISCOVERY_NOTE="${DISCOVERY_NOTE}api-resources discovery failed, used the fallback kind list; "
    kinds="$CLUSTER_KINDS_FALLBACK"
  fi
  # The list phase and the classify phase are announced separately: they fail differently, and an admin
  # watching a long scan needs to know which one is running and how much of it is left.
  prog "listing $(printf '%s\n' "$kinds" | wc -w | tr -d ' ') cluster-scoped kinds…"
  # shellcheck disable=SC2086  # $kinds is a deliberately word-split list of resource names
  swept="$(sweep_labeled cluster $kinds | sort -u)"
  failed="$(sweep_failed_kinds)"
  [ -n "$failed" ] && DISCOVERY_NOTE="${DISCOVERY_NOTE}batched list failed for [${failed% }], retried per kind; "
  prog "$(printf '%s\n' "$swept" | grep -c .) cluster-scoped object(s) to classify"
  # Fetch their markers in one list per kind BEFORE classifying, so the loop below makes no cluster
  # call at all — the same contract the namespaced sweep already gets for free from its own list.
  seed_cluster_marks "$swept"
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    hit=1
    report_swept "$obj" "" "cluster-scoped"
  done < <(printf '%s\n' "$swept")

  # (c) namespaced sweep over the kinds we actually label, cluster-wide
  # shellcheck disable=SC2086  # $NAMESPACED_KINDS is a deliberately word-split list
  swept="$(sweep_ns_kinds $NAMESPACED_KINDS | sort -u)"
  prog "$(printf '%s\n' "$swept" | grep -c .) namespaced object(s) to classify"
  while IFS='|' read -r ns obj marks; do
    [ -n "$obj" ] || continue
    hit=1
    seen="${seen}${obj#*/} "
    # Seed the shared cache from the row the sweep already carried back, so classify/strip/summarise
    # all answer from memory. Without this the four of them make four identical round trips per object.
    [ -n "$marks" ] && marks_put "${obj%%/*}|${ns}|${obj#*/}|${marks}"
    report_swept "$obj" "$ns" "namespaced, in a namespace we preserved"
  done < <(printf '%s\n' "$swept")

  # (d) The OLM objects of every ADOPTED operator, checked by name rather than by label selector.
  #     A label selector cannot find a trace once the label is gone, and the Argo tracking-id outlives
  #     the labels: on cluster ksls5 the org's cert-manager Subscription had been de-labelled but still
  #     carried `argocd.argoproj.io/tracking-id: pp-cert-manager`. That is still our fingerprint on
  #     their object, and the "no trace" bar says it goes — by un-marking it, never by deleting it.
  while IFS='|' read -r name ns st csv; do
    [ -n "$name" ] || continue
    [ -n "$ns" ] || continue
    [ "$st" = "ok" ] || continue
    adopted_obj_trace subscriptions.operators.coreos.com "$name" "$ns" "$seen" && \
      seen="${seen}${name} " && hit=1
    if [ -n "$csv" ]; then
      adopted_obj_trace clusterserviceversions.operators.coreos.com "$csv" "$ns" "$seen" && \
        seen="${seen}${csv} " && hit=1
    fi
    while IFS='|' read -r _ og _; do
      [ -n "$og" ] || continue
      adopted_obj_trace operatorgroups.operators.coreos.com "$og" "$ns" "$seen" && \
        seen="${seen}${og} " && hit=1
    done < <(printf '%s\n' "$OG_INDEX" | grep "^${ns}|")
  done < <(printf '%s\n' "$ADOPTED_SUB_INFO")

  [ "$hit" -eq 0 ] && none "nothing carries a workshop mark"
  return 0
}

adopted_obj_trace() {  # kind name ns already-seen → 0 when it reported a trace
  local kind="$1" name="$2" ns="$3" seen="$4"
  case "$seen" in *" ${name} "*) return 1;; esac          # the label sweep already reported it
  has_our_marks "$kind" "$name" "$ns" || return 1
  report_trace "$kind" "$name" "$ns" \
    "${kind}/${name} -n ${ns} — the org's own object, still marked by us ($(marks_summary "$kind" "$name" "$ns"))"
  return 0
}

# ── [9/9] CRDs from operators we installed ────────────────────────────────────
crd_candidates_for() {  # operator-name → CRD names that plausibly belong to it (heuristic)
  local op="$1" tok toks=""
  for tok in $(printf '%s\n' "$op" | tr '-' ' '); do
    case "$tok" in openshift|redhat|rh|operator|operators|product|community|cluster|custom|metrics|autoscaler) continue;; esac
    [ "${#tok}" -ge 4 ] || continue
    toks="${toks} ${tok}"
  done
  [ -n "$toks" ] || return 0
  for tok in $toks; do
    printf '%s\n' "$CRD_INDEX" | awk -F'|' -v t="$tok" 'index($2,t)>0 || index($1,t)==1 {print $1}'
  done | sort -u
}

section_crds() {
  hdr "9/9" "CRDs installed by operators this install created" \
    "Never removed automatically, and never by us: deleting a CRD deletes every instance of it cluster-wide, in every namespace. The instance count tells you whether anything is using it before you decide."
  if [ -z "$STATE_KV" ]; then
    note "no install state (source: none) — cannot tell which operators were ours."
    note "re-run with --state-file PATH, using the file ogsr-uninstall.sh wrote before it removed"
    note "the ${STATE_NS} namespace. Without it this section cannot be checked."
    return 0
  fi
  local exact op crd n hit=0 mode counts todo=""
  exact="$(state_get crds_created | tr ',' ' ')"
  if [ -n "$exact" ]; then
    mode="exact (captured from each operator's CSV during uninstall)"
    for crd in $exact; do
      # Here-string, same SIGPIPE-under-pipefail trap as ns_has_foreign_csv: `grep -q` exits on its
      # first hit, printf is killed mid-write, pipefail turns the match into a 141, and the `|| continue`
      # then DROPS a CRD that is registered — silently shrinking the only list section [9/9] can offer.
      grep -q "^${crd}|" <<< "$CRD_INDEX" || continue
      todo="${todo}${crd}|\n"
    done
  else
    mode="heuristic name match — VERIFY before deleting"
    while read -r op _; do
      [ -n "$op" ] || continue
      while IFS= read -r crd; do
        [ -n "$crd" ] || continue
        todo="${todo}${crd}|${op}\n"
      done < <(crd_candidates_for "$op")
    done < <(state_ops created)
  fi
  [ -n "$todo" ] || { none "no CRD from an operator we installed is still registered"; return 0; }
  # One `oc get <crd> -A` per candidate was the second-largest serial cost on a cluster with many
  # created operators; the counts are independent reads, so they go out together.
  counts="$(printf '%b' "$todo" | grep -v '^ *$' | sort -u | run_parallel crd_count)"
  while IFS='|' read -r crd op n; do
    [ -n "$crd" ] || continue
    hit=1
    # A heuristic token match can land on a CRD belonging to an ADOPTED operator (cert-manager's own
    # CRDs match the token "cert"). Deleting one of those takes every certificate on the cluster with
    # it, so an ambiguous name match must never carry a delete command.
    if [ -n "$op" ] && crd_matches_adopted "$crd"; then
      report_decide customresourcedefinitions.apiextensions.k8s.io "$crd" "" \
        "crd/${crd} — ${n} instance(s) cluster-wide; name-matched to ${op}, but it ALSO matches an operator the org already had" \
        "the match is by name token only, and an adopted operator's name matches it just as well"
      continue
    fi
    found ws "crd/${crd}${op:+ (probably from ${op})} — ${n} instance(s) cluster-wide  [${mode}]" \
      "oc delete crd ${crd}   # this deletes all ${n} instance(s) of it, everywhere"
  done < <(printf '%s\n' "$counts")
  [ "$hit" -eq 0 ] && none "no CRD from an operator we installed is still registered"
  return 0
}
# shellcheck disable=SC2317,SC2329  # dispatched indirectly by run_parallel, not called by name
# (SC2329 is shellcheck >=0.10, SC2317 the same finding on 0.9.x which CI installs — name both)
crd_count() {  # "crd|op" → "crd|op|<instance count>"
  printf '%s|%s\n' "$1" "$(oc get "${1%%|*}" -A --no-headers 2>/dev/null | grep -c .)"
}
crd_matches_adopted() {  # crd-name → 0 when an ADOPTED operator's name tokens also claim this CRD
  local crd="$1" op cands
  while read -r op _; do
    [ -n "$op" ] || continue
    # Captured first, then matched. `crd_candidates_for … | grep -qx` is the same SIGPIPE trap: the
    # function's own `| sort -u` is killed once grep exits on a hit, pipefail makes the pipeline 141,
    # the `&&` does not fire, and the answer flips to "no adopted operator claims this CRD". That
    # answer is what decides between a DECIDE line and `oc delete crd` — and deleting an adopted
    # operator's CRD deletes every instance of it cluster-wide (cert-manager's, every certificate).
    cands="$(crd_candidates_for "$op")"
    if grep -qx "$crd" <<< "$cands"; then return 0; fi
  done < <(state_ops adopted)
  return 1
}

# ── self-test: offline proof for the olm.copiedFrom exclusion ────────────────
# ORIGIN: CSV_INDEX used to be read with no `-l '!olm.copiedFrom'` filter — unlike this file's own
# section [3/9] (search ORPHAN_CSV_JP) and ogsr-uninstall.sh's csv_index(), both of which filter OLM's
# per-namespace copies server-side and document why. OLM copies a CSV into every namespace its
# OperatorGroup targets — for an AllNamespaces-mode operator that is EVERY namespace on the cluster —
# so the unfiltered read made ns_has_foreign_csv() answer "yes, this namespace holds a CSV we cannot
# account for" about nearly the whole cluster. That reads as the SAFE side (classify_finding's
# no-state fallback answers `decide`, never `ours`, so no delete command gets printed) but it is not
# free: it drowns the one namespace that genuinely hosts an unaccounted operator under false
# positives from namespaces that never held anything but a copy.
#
# Two things have to be PROVEN, never asserted:
#   1. the exclusion actually fires — against a stubbed `oc`, not a grep of this file's own source
#      for the flag (a comment can lie about what the code does; a stub cannot).
#   2. with the copy excluded, a namespace holding a genuine, unaccounted ORIGINAL CSV is STILL
#      caught — proving the fix narrows the false-positive net without cutting a hole in it.
# Never touches a real cluster: `oc` is shadowed by a fixture-returning function for the duration of
# this test only, and unset again before it returns.
self_test() {
  local rc=0 idx canary_leaked copy_only_rc orig_rc

  # ── proof 1: csv_index_read() excludes OLM's per-namespace copies ──────────
  # The stub is ARGV-sensitive: it answers as a real FILTERED list would (the copy never comes back)
  # only when it sees the exact selector this script is supposed to pass. Drop the selector — the
  # historical bug — and the stub hands the copy back too, exactly as an unfiltered `oc get` would on
  # a real cluster carrying one global (AllNamespaces-mode) operator.
  oc() {
    case " $* " in
      *' clusterserviceversions.operators.coreos.com '*'!olm.copiedFrom'*)
        printf 'real-operator-ns real-operator.v1.0.0 Succeeded\n' ;;
      *' clusterserviceversions.operators.coreos.com '*)
        printf 'real-operator-ns real-operator.v1.0.0 Succeeded\nogsr-selftest-canary real-operator.v1.0.0 Succeeded\n' ;;
    esac
    return 0
  }
  idx="$(csv_index_read)"
  unset -f oc
  canary_leaked=1
  case "$idx" in *"ogsr-selftest-canary|"*) canary_leaked=0;; esac

  if [ "$canary_leaked" -eq 0 ]; then
    echo "❌ SELF-TEST: csv_index_read() let a copy's namespace through — the -l '!olm.copiedFrom' selector is missing or broken"
    rc=1
  else
    echo "✅ self-test 1/2: csv_index_read() excludes a namespace whose only CSV is OLM's copy"
  fi

  # ── proof 2: the downstream bias is actually fixed, not just the read ──────
  # No `oc` needed — ns_has_foreign_csv() reads only the globals set below, which is what makes it
  # directly testable. SUB_INDEX_RC=0 means "the Subscription list is trustworthy", so the function
  # answers from these fixtures instead of falling back to a live probe.
  SUB_INDEX_RC=0
  SUB_INDEX=""              # no Subscription anywhere carries our owner label in this fixture

  # copy-only namespace: CSV_INDEX (as proof 1 established) has NO row for it, so it must NOT be
  # reported as holding a CSV we cannot account for — this is the exact bias the fix removes.
  FOREIGN_CSV_CACHE=""
  CSV_INDEX="real-operator-ns|real-operator.v1.0.0|Succeeded|"
  copy_only_rc=1
  ns_has_foreign_csv "ogsr-selftest-canary" && copy_only_rc=0

  # genuine unaccounted operator: an ORIGINAL CSV actually sits in this namespace with no Subscription
  # of ours anywhere — the real case this heuristic exists to catch. Excluding copies must not have
  # broken it.
  FOREIGN_CSV_CACHE=""
  CSV_INDEX="an-adopted-operator-ns|some-operator.v2.0.0|Succeeded|"
  orig_rc=1
  ns_has_foreign_csv "an-adopted-operator-ns" && orig_rc=0

  if [ "$copy_only_rc" -eq 0 ]; then
    echo "❌ SELF-TEST: a namespace holding only a copied CSV was reported as foreign — the exact bias this fix removes"
    rc=1
  else
    echo "✅ self-test 2/2a: a copy-only namespace is no longer misreported as foreign"
  fi
  if [ "$orig_rc" -ne 0 ]; then
    echo "❌ SELF-TEST: a namespace holding a genuine, unaccounted ORIGINAL CSV was NOT flagged — this is a regression in detection, not just a fix"
    rc=1
  else
    echo "✅ self-test 2/2b: a namespace holding a genuine unaccounted CSV is still flagged"
  fi

  if [ "$rc" -eq 0 ]; then
    echo "self-test ok — both proofs held (copy excluded from CSV_INDEX; a real foreign CSV is still caught)"
    return 1
  fi
  return 2
}

if [ "$SELF_TEST" = "true" ]; then
  self_test
  exit $?
fi

# ── run ───────────────────────────────────────────────────────────────────────
load_indexes
seed_ns_marks
if [ -n "$STATE_SRC" ]; then
  echo "  install state: ${STATE_SRC}"
else
  echo "  install state: NOT FOUND — sections 1 and 9 are limited, and anything this scan cannot"
  echo "                 attribute is reported as 'needs a human decision' rather than as deletable."
fi

section_adopted_health
section_operatorgroups
section_orphan_csvs
section_namespaces
section_other_terminating
section_apiservices
section_webhooks
section_labeled_objects
section_crds

# ── verdict ───────────────────────────────────────────────────────────────────
echo
echo "$RULE"
printf 'VERDICT   (scan completed in %ss)\n' "$SECONDS"
printf '   %-42s %s\n' "the org's operators harmed"          "$N_ADOPTED"
printf '   %-42s %s\n' "cluster-health findings"             "$N_HEALTH"
printf '   %-42s %s\n' "workshop leftovers (ours: delete)"   "$N_WS"
printf '   %-42s %s\n' "our marks on the org's resources"    "$N_TRACE"
printf '   %-42s %s\n' "needs a human decision"              "$N_DECIDE"
[ -n "$DISCOVERY_NOTE" ] && echo "   (partial scan: ${DISCOVERY_NOTE%; })"
echo

if [ "$((N_ADOPTED + N_HEALTH + N_WS + N_TRACE + N_DECIDE))" -eq 0 ]; then
  echo "✅ clean — nothing from this workshop remains and no namespace is wedged."
  exit 0
fi
if [ "$N_ADOPTED" -gt 0 ]; then
  echo "❌ ${N_ADOPTED} finding(s) affect operators the org already had. Fix these first —"
  echo "   an adopted operator left unmanaged is the one outcome this uninstall must never produce."
fi
# A trace is a finding — the "no trace" bar says our label should not outlive us — but the remedy is
# the opposite of a delete, so it is counted and worded separately and never merged into the litter.
if [ "$N_TRACE" -gt 0 ]; then
  echo "⚠️  ${N_TRACE} finding(s) are OUR MARK on a resource the org owns. Each is printed with a"
  echo "   'strip:' command that removes the label or annotation and leaves the object alone."
  echo "   Do NOT delete these objects — they were here before the workshop and must outlive it."
fi
if [ "$N_DECIDE" -gt 0 ]; then
  echo "❓ ${N_DECIDE} finding(s) could not be attributed. No removal command was printed for them"
  echo "   on purpose. Re-run with --state-file PATH if you still have the dump ogsr-uninstall.sh"
  echo "   wrote; that usually resolves them without anyone having to guess."
fi
echo "⚠️  Nothing was changed. Read each line above and decide; where a remedy is safe to state, its"
echo "   command is printed with it. Re-run this script after acting; it exits 0 once nothing remains."
exit 1
