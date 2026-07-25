#!/usr/bin/env bash
# ogsr-check-clean.sh — REPORT what the workshop left on a cluster. READ-ONLY BY DESIGN.
#
# Run this after ./bootstrap/ogsr-uninstall.sh. It scans for eight classes of leftover, explains in
# one line what each class means, and prints the exact `oc` command that would remove each finding.
#
# It never deletes, patches, labels, annotates or applies ANYTHING. That is deliberate and is the
# most important property of this script: removing a CRD deletes every instance of it cluster-wide,
# and clearing a finalizer can strand an operator mid-cleanup. Those decisions belong to a cluster
# admin who knows what the org runs — not to a script running unattended. This tells you what there
# is to decide about; you decide.
#
# Exit codes
#   0  nothing of the workshop remains and the cluster is healthy
#   1  findings are listed above (works as a CI gate and as a yes/no for an SA)
#   2  the scan could not run at all (no oc, not logged in)
#
# Usage
#   ./ogsr-check-clean.sh                     scan the cluster in the current kubecontext
#   ./ogsr-check-clean.sh --state-file PATH   read install state from a file. ogsr-uninstall.sh
#                                             writes one before it deletes the state namespace,
#                                             and prints the path in its closing summary.
#   ./ogsr-check-clean.sh --quiet             findings and verdict only, no explanations
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

STATE_FILE=""
STATE_FILE_DEFAULT="${TMPDIR:-/tmp}/ogsr-uninstall-state.txt"
QUIET="false"

N_ADOPTED=0   # the org's own operators left unhealthy — the worst outcome this design can produce
N_HEALTH=0    # cluster-wide health damage (wedged namespaces, broken discovery)
N_WS=0        # workshop litter

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,30p'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    # `shift 2` with only one argument left is a no-op that returns non-zero — and with no `set -e`
    # (deliberate, see the header) the loop then spins on the same argument forever. Reject the missing
    # value explicitly instead of hanging a script an admin is running unattended after a teardown.
    --state-file)
      [ $# -ge 2 ] || { echo "❌ --state-file needs a path" >&2; exit 2; }
      STATE_FILE="$2"; shift 2;;
    --quiet|-q)   QUIET="true"; shift;;
    -h|--help)    usage;;
    *) echo "unknown flag: $1" >&2; usage;;
  esac
done

# ── output helpers ────────────────────────────────────────────────────────────
RULE="──────────────────────────────────────────────────────────────────────────"
hdr() {  # n/N  title  one-line-explanation
  echo; echo "$RULE"; echo "[$1] $2"
  [ "$QUIET" = "true" ] || echo "      $3"
}
found() {  # bucket  what  [removal-command]
  printf '   • %s\n' "$2"
  [ -n "${3:-}" ] && printf '     remove: %s\n' "$3"
  case "$1" in
    adopted) N_ADOPTED=$((N_ADOPTED + 1));;
    health)  N_HEALTH=$((N_HEALTH + 1));;
    *)       N_WS=$((N_WS + 1));;
  esac
  return 0
}
sub()    { printf '       ↳ %s\n' "$*"; }
subcmd() { printf '       remove: %s\n' "$*"; }
none()   { printf '   ✅ %s\n' "${1:-none}"; }
note()   { printf '   ℹ  %s\n' "$*"; }

# ── preflight ─────────────────────────────────────────────────────────────────
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
echo "  NOTHING below is deleted for you. Every finding carries the command that would remove it."

# ── indexes: one cluster read each, reused by every section ───────────────────
DISCOVERY_NOTE=""
NS_INDEX=""; SVC_INDEX=""; CSV_INDEX=""; OG_INDEX=""; CRD_INDEX=""; STATE_KV=""; STATE_SRC=""

load_indexes() {
  echo
  echo "collecting cluster state (one read per resource class)…"

  # name|phase|owner|component|stack|user|layer
  NS_INDEX="$(oc get namespaces -o jsonpath="{range .items[*]}{.metadata.name}|{.status.phase}|{.metadata.labels.${OWNER_KEY//./\\.}}|{.metadata.labels.${COMPONENT_KEY//./\\.}}|{.metadata.labels.${STACK_KEY//./\\.}}|{.metadata.labels.${USER_KEY//./\\.}}|{.metadata.labels.${LAYER_KEY//./\\.}}{\"\n\"}{end}" 2>/dev/null)"
  [ -n "$NS_INDEX" ] || DISCOVERY_NOTE="${DISCOVERY_NOTE}could not list namespaces; "

  # " ns/name ns/name … " — membership test for the APIService and webhook sections
  SVC_INDEX=" $(oc get services -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null) "

  # ns|name|phase|reason|owned-crd,owned-crd,…   (copied CSVs appear once per namespace; harmless —
  # every section below asks "does ANY row match", never "how many rows")
  CSV_INDEX="$(oc get clusterserviceversions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.phase}|{.status.reason}|{range .spec.customresourcedefinitions.owned[*]}{.name}{","}{end}{"\n"}{end}' 2>/dev/null)"

  # ns|name|ourownerlabel — OperatorGroups are the TooManyOperatorGroups class in section 2
  OG_INDEX="$(oc get operatorgroups.operators.coreos.com -A -o jsonpath="{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.metadata.labels.${OWNER_KEY//./\\.}}{\"\n\"}{end}" 2>/dev/null)"

  # name|group
  CRD_INDEX="$(oc get customresourcedefinitions.apiextensions.k8s.io -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.group}{"\n"}{end}' 2>/dev/null)"

  load_state
  echo "  done."
}

load_state() {
  local live f
  live="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o go-template='{{range $k,$v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null)"
  if [ -n "$live" ]; then
    STATE_KV="$live"; STATE_SRC="ConfigMap ${STATE_NS}/${STATE_CM} (install still present)"
    return 0
  fi
  # The state ConfigMap lives in ogsr-system, which the uninstall deletes LAST — so after a
  # successful uninstall it is gone and only the dump file can say what we created vs adopted.
  for f in "$STATE_FILE" "$STATE_FILE_DEFAULT"; do
    [ -n "$f" ] && [ -r "$f" ] || continue
    STATE_KV="$(cat "$f" 2>/dev/null)"; STATE_SRC="file ${f}"
    return 0
  done
  STATE_SRC=""
}

state_get() { printf '%s\n' "$STATE_KV" | grep -m1 "^${1}=" | cut -d= -f2- ; }
state_ops() {  # created|adopted → "name namespace" lines
  printf '%s\n' "$STATE_KV" | grep "^op_" | grep "=${1}:" \
    | sed "s/^op_\([^=]*\)=${1}:\(.*\)$/\1 \2/" | grep -v '^ *$'
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
    sub "namespace on the cluster, not just ours. See section [5/8] for the stale APIService"
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
      owner_csv="$(printf '%s\n' "$CSV_INDEX" \
        | awk -F'|' -v t="$rtype" '{n=split($5,a,","); for(i=1;i<=n;i++) if(a[i]==t){print $1"/"$2" ("$3")"; exit}}')"
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

# ── [1/8] adopted operators still healthy? ────────────────────────────────────
section_adopted_health() {
  hdr "1/8" "the org's own (adopted) operators — still healthy?" \
    "An adopted operator left broken is worse than any amount of litter: the cluster looks fine and stops being maintained. Every operator this install found already present must still be Succeeded."
  if [ -z "$STATE_KV" ]; then
    note "no install state available — cannot tell adopted from created."
    note "run with --state-file PATH (ogsr-uninstall.sh prints the path it wrote), or accept that"
    note "this section and section [8/8] cannot be checked on this cluster."
    return 0
  fi
  local rows name ns csv phase reason
  rows="$(state_ops adopted)"
  [ -n "$rows" ] || { none "no adopted operators recorded — this install created everything it used"; return 0; }
  while read -r name ns; do
    [ -n "$name" ] && [ -n "$ns" ] || continue
    # Fully qualified, always: Knative's subscriptions.messaging.knative.dev shadows the OLM one and
    # a bare `subscription` silently reports every operator as absent (SEV1 here, fixed in 437bbf4).
    if ! oc get subscriptions.operators.coreos.com "$name" -n "$ns" >/dev/null 2>&1; then
      found adopted "adopted operator ${ns}/${name} — its Subscription is GONE (we must never remove an adopted operator)" \
        "reinstall it from OperatorHub: the org owned this before the workshop was installed"
      continue
    fi
    csv="$(oc get subscriptions.operators.coreos.com "$name" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null)"
    if [ -z "$csv" ]; then
      found adopted "adopted operator ${ns}/${name} — Subscription has no installedCSV (OLM is not resolving it)" \
        "oc describe subscriptions.operators.coreos.com ${name} -n ${ns}   # read status.conditions"
      continue
    fi
    phase="$(printf '%s\n' "$CSV_INDEX" | grep -m1 "^${ns}|${csv}|" | cut -d'|' -f3)"
    reason="$(printf '%s\n' "$CSV_INDEX" | grep -m1 "^${ns}|${csv}|" | cut -d'|' -f4)"
    if [ "$phase" = "Succeeded" ]; then
      [ "$QUIET" = "true" ] || echo "   ✅ ${ns}/${name} — ${csv} Succeeded"
    else
      found adopted "adopted operator ${ns}/${name} — CSV ${csv} is ${phase:-<unknown>}${reason:+ (${reason})}" \
        "oc describe csv ${csv} -n ${ns}"
      [ "$reason" = "TooManyOperatorGroups" ] && sub "see section [2/8] — an OperatorGroup we added is what stopped OLM reconciling it"
    fi
  done < <(printf '%s\n' "$rows")
}

# ── [2/8] OperatorGroup conflicts ─────────────────────────────────────────────
section_operatorgroups() {
  hdr "2/8" "namespaces with more than one OperatorGroup" \
    "OLM refuses to reconcile a CSV in a namespace carrying two OperatorGroups (TooManyOperatorGroups). Pods keep running, so nothing looks wrong — the operator has simply stopped being managed and will not upgrade or self-heal."
  local dupes ns line name owner ours csv_ns csv_name csv_reason hit=0
  if [ -z "$OG_INDEX" ]; then note "could not list OperatorGroups — skipping"; return 0; fi
  dupes="$(printf '%s\n' "$OG_INDEX" | awk -F'|' 'NF>1 && $1!="" {c[$1]++} END{for(n in c) if(c[n]>1) print n}' | sort)"
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    hit=1
    ours=""
    found ws "namespace/${ns} has more than one OperatorGroup — OLM cannot pick one, so it manages none"
    while IFS='|' read -r _ name owner; do
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

# ── [3/8] workshop namespaces ─────────────────────────────────────────────────
ns_is_ours() {  # name owner component stack user layer → 0 and echoes the marker that identified it
  local name="$1" owner="$2" comp="$3" stack="$4" user="$5" layer="$6"
  [ -n "$owner" ] && { echo "${OWNER_KEY}=${owner}"; return 0; }
  [ -n "$comp" ]  && { echo "${COMPONENT_KEY}=${comp}"; return 0; }
  [ -n "$stack" ] && { echo "${STACK_KEY}=${stack}"; return 0; }
  [ -n "$user" ]  && { echo "${USER_KEY}=${user}"; return 0; }
  [ -n "$layer" ] && { echo "${LAYER_KEY}=${layer}"; return 0; }
  case "$name" in "${NS_PREFIX}"*) echo "name prefix ${NS_PREFIX}* (no label — teardown could not see it)"; return 0;; esac
  return 1
}

OURS_NS_LIST=" "   # filled here, consumed by section 4 so it does not re-report the same namespaces
section_namespaces() {
  hdr "3/8" "namespaces this workshop owned that still exist" \
    "Identified by our labels, or by the ogsr- name prefix for namespaces that lost their label. A namespace stuck Terminating is diagnosed below: what blocks it, and whether anything is left to unblock it."
  local line name phase owner comp stack user layer marker hit=0
  if [ -z "$NS_INDEX" ]; then note "could not list namespaces — skipping"; return 0; fi
  while IFS='|' read -r name phase owner comp stack user layer; do
    [ -n "$name" ] || continue
    marker="$(ns_is_ours "$name" "$owner" "$comp" "$stack" "$user" "$layer")" || continue
    hit=1
    OURS_NS_LIST="${OURS_NS_LIST}${name} "
    if [ "$phase" = "Terminating" ]; then
      found health "namespace/${name} — Terminating (identified by ${marker})"
      diagnose_stuck_ns "$name"
    else
      found ws "namespace/${name} — ${phase} (identified by ${marker})" "oc delete namespace ${name}"
    fi
  done < <(printf '%s\n' "$NS_INDEX")
  [ "$hit" -eq 0 ] && none "no workshop namespace remains"
  return 0
}

# ── [4/8] anything else wedged ────────────────────────────────────────────────
section_other_terminating() {
  hdr "4/8" "other namespaces stuck Terminating (not ours)" \
    "Listed because our teardown can wedge namespaces that were never ours — a stale APIService stops garbage collection cluster-wide. If these appear, look at section [5/8] first; one fix usually releases all of them."
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

# ── [5/8] stale APIServices ───────────────────────────────────────────────────
section_apiservices() {
  hdr "5/8" "APIServices whose backing Service no longer exists" \
    "The highest-impact class there is. An aggregated APIService with no backend makes discovery fail, and Kubernetes then refuses to garbage-collect ANY namespace on the cluster — 92 of them wedged in the 2026-07-25 teardown, most not ours."
  local name svc_ns svc_nm avail hit=0
  while IFS='|' read -r name svc_ns svc_nm avail; do
    [ -n "$name" ] && [ -n "$svc_ns" ] || continue
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

# ── [6/8] orphaned admission webhooks ─────────────────────────────────────────
section_webhooks() {
  hdr "6/8" "admission webhooks pointing at a Service that no longer exists" \
    "A webhook whose backend is gone rejects or hangs every create/update it intercepts, which blocks deletion of objects in the namespaces it covers. Only ones with failurePolicy=Fail actually block; Ignore is listed as informational."
  local kind w refs ref rns rnm pol hit=0
  for kind in validatingwebhookconfigurations.admissionregistration.k8s.io \
              mutatingwebhookconfigurations.admissionregistration.k8s.io; do
    while IFS='|' read -r w refs pol; do
      [ -n "$w" ] || continue
      for ref in $refs; do
        case "$ref" in ""|"/") continue;; esac
        rns="${ref%%/*}"; rnm="${ref##*/}"
        [ -n "$rns" ] && [ -n "$rnm" ] || continue
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

# ── [7/8] objects still carrying a workshop label ─────────────────────────────
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

sweep_labeled() {  # scope(cluster|ns) kinds… — one batched get, per-kind retry if the batch fails
  local scope="$1"; shift
  local kinds="$*" chunk="" n=0 k out extra=""
  [ "$scope" = "ns" ] && extra="-A"
  for k in $kinds; do
    chunk="${chunk}${chunk:+,}${k}"; n=$((n + 1))
    if [ "$n" -ge 15 ]; then sweep_chunk "$chunk" "$extra"; chunk=""; n=0; fi
  done
  [ -n "$chunk" ] && sweep_chunk "$chunk" "$extra"
  return 0
}
# Some endpoints answer a list request with a Status object instead of a list, and `-o name` renders
# that as the literal string `status/<unknown>` while exiting 0 — indistinguishable from a real hit.
# projectrequests.project.openshift.io is the one that does it on every OpenShift cluster (it is a
# request-only virtual resource). Left unfiltered it is a phantom finding that no admin can act on
# (`oc delete status/<unknown>` is not a command) and, because it is always present, it would make this
# script exit 1 forever — destroying the exit contract that CI and `ws doctor` depend on.
drop_phantoms() { grep -v '^ *$' | grep -vE '^status/|/<unknown>$'; }

sweep_chunk() {  # comma-list  extra-args — echo "kind/name" or "ns kind/name" lines
  local chunk="$1" extra="${2:-}" out k
  # shellcheck disable=SC2086  # $extra is intentionally word-split (empty or -A)
  if out="$(oc get "$chunk" $extra -l "$OWNER_LABEL" -o name --ignore-not-found 2>/dev/null)"; then
    printf '%s\n' "$out" | drop_phantoms
    return 0
  fi
  # A single broken API group fails the whole batch — fall back to one call per kind so one bad
  # group cannot hide every other leftover. This is the graceful-degradation path, not the norm.
  DISCOVERY_NOTE="${DISCOVERY_NOTE}batched list failed for [${chunk}], retried per kind; "
  for k in $(printf '%s\n' "$chunk" | tr ',' ' '); do
    # shellcheck disable=SC2086
    oc get "$k" $extra -l "$OWNER_LABEL" -o name --ignore-not-found 2>/dev/null | drop_phantoms
  done
  return 0
}

section_labeled_objects() {
  hdr "7/8" "objects still carrying a workshop label" \
    "Anything here was created by the workshop and outlived it. Argo Applications come first: they actively reconcile, so while one exists it re-creates whatever you delete."
  local obj kinds hit=0 app lbl apps=""

  # (a) Argo Applications / AppProjects — matched on ANY of our labels, then deduped. Child
  #     portfolio Applications carry ONLY portfolio.redhat.com/component (31 of 32 of them), so an
  #     owner-label-only scan misses the apps that do the reconciling.
  for lbl in "$OWNER_LABEL" "$COMPONENT_KEY" "$STACK_KEY" "$LAYER_KEY"; do
    apps="${apps}$(oc get applications.argoproj.io,applicationsets.argoproj.io -n "$ARGO_NS" \
                     -l "$lbl" -o name --ignore-not-found 2>/dev/null)
"
  done
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    hit=1
    found ws "${app} in ${ARGO_NS} — STILL RECONCILING (it re-creates whatever you remove)" \
      "oc delete ${app} -n ${ARGO_NS}"
  done < <(printf '%s\n' "$apps" | grep -v '^ *$' | sort -u)

  # (b) cluster-scoped sweep, driven by live discovery so nothing is missed by a stale hardcoded
  #     list. namespaces are excluded — section [3/8] already reports them, with diagnosis.
  # projectrequests is excluded by name as well as filtered by drop_phantoms: listing it is pure noise
  # (it never holds objects) and skipping it saves the API call that produces the Status response.
  kinds="$(oc api-resources --namespaced=false --verbs=list -o name 2>/dev/null \
            | grep -vE '^(componentstatuses|namespaces|projectrequests\.project\.openshift\.io)$' | tr '\n' ' ')"
  if [ -z "$kinds" ]; then
    DISCOVERY_NOTE="${DISCOVERY_NOTE}api-resources discovery failed, used the fallback kind list; "
    kinds="$CLUSTER_KINDS_FALLBACK"
  fi
  # shellcheck disable=SC2086  # $kinds is a deliberately word-split list of resource names
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    hit=1
    found ws "${obj} (cluster-scoped, ${OWNER_LABEL})" "oc delete ${obj}"
  done < <(sweep_labeled cluster $kinds | sort -u)

  # (c) namespaced sweep over the kinds we actually label, cluster-wide
  # shellcheck disable=SC2086  # $NAMESPACED_KINDS is a deliberately word-split list
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    hit=1
    found ws "${obj} (namespaced, ${OWNER_LABEL} — in a namespace we preserved)" \
      "oc delete ${obj} -n <namespace>   # oc get ${obj%%/*} -A -l ${OWNER_LABEL} to see which"
  done < <(sweep_labeled ns $NAMESPACED_KINDS | sort -u)

  [ "$hit" -eq 0 ] && none "nothing carries a workshop label"
  return 0
}

# ── [8/8] CRDs from operators we installed ────────────────────────────────────
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
  hdr "8/8" "CRDs installed by operators this install created" \
    "Never removed automatically, and never by us: deleting a CRD deletes every instance of it cluster-wide, in every namespace. The instance count tells you whether anything is using it before you decide."
  if [ -z "$STATE_KV" ]; then
    note "no install state (source: none) — cannot tell which operators were ours."
    note "re-run with --state-file PATH, using the file ogsr-uninstall.sh wrote before it removed"
    note "the ${STATE_NS} namespace. Without it this section cannot be checked."
    return 0
  fi
  local exact op crd n hit=0 mode
  exact="$(state_get crds_created | tr ',' ' ')"
  if [ -n "$exact" ]; then
    mode="exact (captured from each operator's CSV during uninstall)"
    for crd in $exact; do
      printf '%s\n' "$CRD_INDEX" | grep -q "^${crd}|" || continue
      hit=1
      n="$(oc get "$crd" -A --no-headers 2>/dev/null | grep -c .)"
      found ws "crd/${crd} — ${n} instance(s) cluster-wide  [${mode}]" \
        "oc delete crd ${crd}   # this deletes all ${n} instance(s) of it, everywhere"
    done
  else
    mode="heuristic name match — VERIFY before deleting"
    while read -r op _; do
      [ -n "$op" ] || continue
      while IFS= read -r crd; do
        [ -n "$crd" ] || continue
        hit=1
        n="$(oc get "$crd" -A --no-headers 2>/dev/null | grep -c .)"
        found ws "crd/${crd} (probably from ${op}) — ${n} instance(s) cluster-wide  [${mode}]" \
          "oc delete crd ${crd}   # this deletes all ${n} instance(s) of it, everywhere"
      done < <(crd_candidates_for "$op")
    done < <(state_ops created)
  fi
  [ "$hit" -eq 0 ] && none "no CRD from an operator we installed is still registered"
  return 0
}

# ── run ───────────────────────────────────────────────────────────────────────
load_indexes
[ -n "$STATE_SRC" ] && echo "  install state: ${STATE_SRC}" || echo "  install state: NOT FOUND (sections 1 and 8 will be limited)"

section_adopted_health
section_operatorgroups
section_namespaces
section_other_terminating
section_apiservices
section_webhooks
section_labeled_objects
section_crds

# ── verdict ───────────────────────────────────────────────────────────────────
echo
echo "$RULE"
echo "VERDICT"
printf '   %-42s %s\n' "the org's operators harmed" "$N_ADOPTED"
printf '   %-42s %s\n' "cluster-health findings"     "$N_HEALTH"
printf '   %-42s %s\n' "workshop leftovers"          "$N_WS"
[ -n "$DISCOVERY_NOTE" ] && echo "   (partial scan: ${DISCOVERY_NOTE%; })"
echo

if [ "$((N_ADOPTED + N_HEALTH + N_WS))" -eq 0 ]; then
  echo "✅ clean — nothing from this workshop remains and no namespace is wedged."
  exit 0
fi
if [ "$N_ADOPTED" -gt 0 ]; then
  echo "❌ ${N_ADOPTED} finding(s) affect operators the org already had. Fix these first —"
  echo "   an adopted operator left unmanaged is the one outcome this uninstall must never produce."
fi
echo "⚠️  Nothing was deleted. Read each line above and decide; the removal command is printed with it."
echo "   Re-run this script after acting; it exits 0 once nothing remains."
exit 1
