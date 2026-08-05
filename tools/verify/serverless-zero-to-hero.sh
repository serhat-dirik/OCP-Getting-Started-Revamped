#!/usr/bin/env bash
# Verify serverless-zero-to-hero — Serverless Zero-to-Hero.
#   Entry: {user}-dev holds a single-revision SCALE-TO-ZERO parasol-claims Knative Service (revision
#          parasol-claims-v1) on the pre-built parasol-images/parasol-claims:1.1 image, an ephemeral
#          claims-db (PostgreSQL) so the revision's /q/health/ready passes, and a demo-client load pod.
#          The ksvc is Ready with an AUTO-CREATED edge Route (status.url populated) — no hand-rolled Route.
#          No traffic split and no eventing objects yet (the attendee builds those). Entry marker set.
#   End:   the attendee tuned + split + wired — the ksvc carries a tag-based (blue/green) traffic split
#          across two revisions, and an in-memory Broker + a Trigger + a PingSource wire the eventing taste
#          (source->broker->trigger->ksvc).
# Runnable as the ATTENDEE: reads only {user}-dev objects the attendee sees via namespace admin (the
# Knative serving/eventing CRDs aggregate to the admin role). The G1 cockpit smoke runs `--entry-only`.
#
# ROUTING NOTE: Knative auto-creates the external edge Route in ns knative-serving-ingress (attendee can't
# read that cross-namespace, rule 10) — so the auto-Route is proved via the attendee-readable
# `ksvc.status.url`, NOT the OpenShift Route object.
# IMAGE-GAP NOTE: parasol-claims runs parasol-images/parasol-claims (workshop image-load step). The ksvc is
# asserted PRESENT + Ready (materialization is the entry state's job); claims-db/demo-client run
# always-present platform images (postgresql/tools) and are asserted READY.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (oc only) -------------------------------------------------------

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# The parasol-claims Knative Service exists in {user}-dev. A missing ksvc CRD ("the server doesn't have
# a resource type") is the server's own answer and still fails loudly — Serverless not installed is a
# real platform failure, not an inconclusive read.
ksvc_present() { oc_present get ksvc parasol-claims -n "$NS" -o name; }

# The ksvc reports Ready=True (latest revision came up + Route admitted). Stays True even scaled to zero.
ksvc_ready() {
  oc_read get ksvc parasol-claims -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || return 1
  [[ "$OC_OUT" == "True" ]]
}

# The ksvc has an auto-created external URL (the operator-managed edge Route is admitted). Proof that
# Knative published the Route — attendee-readable, unlike the OpenShift Route object in knative-serving-ingress.
ksvc_has_url() {
  oc_read get ksvc parasol-claims -n "$NS" -o jsonpath='{.status.url}' || return 1
  [[ -n "$OC_OUT" ]]
}

# The ksvc traffic is TAG-split (blue/green). At entry the single default target carries no tag; at solve
# the two targets carry tags (stable/candidate), so a non-empty tag list means the split is in place.
ksvc_traffic_split() {
  oc_read get ksvc parasol-claims -n "$NS" -o jsonpath='{.status.traffic[*].tag}' || return 1
  [[ -n "$OC_OUT" ]]
}

# Eventing objects (namespaced; attendee admin reads them via the aggregated admin role).
broker_present()     { oc_present get broker.eventing.knative.dev default -n "$NS" -o name; }
trigger_present()    { oc_present get trigger.eventing.knative.dev claims-processor -n "$NS" -o name; }
pingsource_present() { oc_present get pingsource.sources.knative.dev claim-ticker -n "$NS" -o name; }

# Entry clean-slate helpers: return 0 when the solve object is ABSENT (attendee has built nothing yet).
# Each requires the namespace to actually exist first — otherwise "absent" is vacuous (true on a
# cluster where nothing materialized at all), not evidence of a clean, correctly-seeded entry state.
# THE NEGATIONS. `! ksvc_traffic_split` and `[[ -z "$(oc get … 2>/dev/null)" ]]` both certify a clean
# slate from an API that never answered, and a wrongly-green entry check is what sends `ws prep` down
# its "already prepared — nothing to do" fast path WITHOUT purging (the same fast path the orphaned-
# revision note below is about). ksvc_traffic_split now distinguishes its own three outcomes, so
# no_traffic_split must not blanket-negate it: only a real "no tags" answer is a clean slate.
no_traffic_split() {
  local rc=0
  oc_present get ns "$NS" -o name || return 1
  ksvc_traffic_split || rc=$?
  if (( VERIFY_INCONCLUSIVE == 1 )); then return 1; fi   # could not ask → ⚠, never a certified clean slate
  (( rc != 0 ))
}
no_eventing() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent get broker.eventing.knative.dev,trigger.eventing.knative.dev,pingsource.sources.knative.dev -n "$NS" -o name
}
# Entry ships EXACTLY ONE revision (parasol-claims-v1) — this file's header and the entry block below
# both already claimed "one revision", but nothing tested it, so an ORPHANED revision from an earlier
# pass passed every entry check (measured 2026-07-31). That false green is load-bearing: `ws prep`'s
# fast path returns "already prepared — nothing to do" WITHOUT purging when the entry checks pass, so a
# stale revision survived prep, and the lab's own exercise-3 command (`kn service update … --revision-name
# parasol-claims-v2`) then hard-failed `Ready=False reason=RevisionNameTaken` /
# `revisions.serving.knative.dev "parasol-claims-v2" already exists` with NO new revision created.
# Revision names are FIXED (the chart pins v1; the lab pins v2), so a leftover is a collision, not
# residue. Asserting the count here makes prep purge, which is the only thing that clears it.
# == not >= on purpose: this runs ONLY under --entry-only, where a clean slate is the assertion; the
# lab legitimately mints v1-warm/v1-cold/v2 later and those are checked in the END branch, not here.
single_revision() {
  oc_present get ns "$NS" -o name || return 1
  oc_read get revision.serving.knative.dev -n "$NS" \
    -l "serving.knative.dev/service=parasol-claims" -o name || return 1
  [[ "$OC_OUT" == "revision.serving.knative.dev/parasol-claims-v1" ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                 || hint "run: ws prep serverless-zero-to-hero (or ws start serverless-zero-to-hero --user ${USER_NAME}); the ${NS} namespace is workshop-layer (workshop-config)"
check "entry marker ws-entry-serverless-zero-to-hero present"            oc get cm ws-entry-serverless-zero-to-hero -n "$NS" || hint "entry app not synced — ws reset serverless-zero-to-hero --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"   deploy_ready claims-db          || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "demo-client deployment has >=1 ready replica" deploy_ready demo-client        || hint "the in-cluster load pod isn't up — oc get pods -l app=demo-client -n ${NS}"
check "parasol-claims Knative Service present"       ksvc_present                    || hint "entry app not synced (is the serverless stack installed?) — ws reset serverless-zero-to-hero --user ${USER_NAME}"
check "parasol-claims ksvc is Ready"                 ksvc_ready                      || hint "revision not Ready — check image pull + claims-db: oc get ksvc,revision -n ${NS}; oc get pods -n ${NS}"
check "parasol-claims ksvc has an auto-created URL (edge Route)" ksvc_has_url        || hint "Knative auto-publishes the edge Route — a blank status.url means the Route/Kourier isn't ready: oc get ksvc parasol-claims -n ${NS} -o yaml"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — one revision, no split, no eventing --------------------------------
  check "no tag-based traffic split yet (attendee splits revisions)" no_traffic_split || hint "entry ships one revision; if the ksvc traffic is tag-split the lab already started — ws reset serverless-zero-to-hero --user ${USER_NAME}"
  check "no eventing objects yet (attendee wires source->broker->trigger)" no_eventing || hint "entry ships no Broker/Trigger/PingSource; if they exist the lab already started — ws reset serverless-zero-to-hero --user ${USER_NAME}"
  check "exactly one revision (parasol-claims-v1) — no orphan from an earlier pass" single_revision || hint "a leftover revision is present. Revision names are FIXED, so exercise 3's 'kn service update --revision-name parasol-claims-v2' will fail RevisionNameTaken against it. Clear it: ws reset serverless-zero-to-hero --user ${USER_NAME} (or, targeted: oc delete revision <name> -n ${NS})"
else
  # --- end state: the lab's OUTCOMES — tuned + split + eventing wired ---------------------------------
  # Assert OUTCOMES (ksvc tag-split; a Broker, Trigger and PingSource exist), never the exact CR wording,
  # so any correct attendee solution stays green (rule 14).
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "parasol-claims ksvc traffic is tag-split (blue/green)"     ksvc_traffic_split || hint "not done yet — the entry state ships ONE revision with all the traffic on purpose; splitting it across two tagged revisions is the lab (kn service update parasol-claims --traffic ...), so this red is expected before you start"
  check "eventing Broker present (in-memory)"                       broker_present     || hint "not done yet — the entry state ships no eventing objects; creating the Broker is the eventing-taste hub: kn broker create default -n ${NS}"
  check "Trigger present (Broker -> parasol-claims ksvc)"           trigger_present    || hint "not done yet — you create this during the lab (a Trigger routing the Broker to the parasol-claims ksvc); expected red until you do"
  check "PingSource present (source -> Broker)"                     pingsource_present || hint "not done yet — you create this during the lab (a PingSource emitting events into the Broker); expected red until you do"
fi

verify_summary
