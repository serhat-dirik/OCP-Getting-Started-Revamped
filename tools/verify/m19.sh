#!/usr/bin/env bash
# Verify M19 — Serverless Zero-to-Hero.
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

# A Deployment has at least one ready replica.
deploy_ready() {
  local ready
  ready="$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The parasol-claims Knative Service exists in {user}-dev.
ksvc_present() { oc get ksvc parasol-claims -n "$NS" >/dev/null 2>&1; }

# The ksvc reports Ready=True (latest revision came up + Route admitted). Stays True even scaled to zero.
ksvc_ready() {
  [[ "$(oc get ksvc parasol-claims -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]
}

# The ksvc has an auto-created external URL (the operator-managed edge Route is admitted). Proof that
# Knative published the Route — attendee-readable, unlike the OpenShift Route object in knative-serving-ingress.
ksvc_has_url() {
  [[ -n "$(oc get ksvc parasol-claims -n "$NS" -o jsonpath='{.status.url}' 2>/dev/null || true)" ]]
}

# The ksvc traffic is TAG-split (blue/green). At entry the single default target carries no tag; at solve
# the two targets carry tags (stable/candidate), so a non-empty tag list means the split is in place.
ksvc_traffic_split() {
  [[ -n "$(oc get ksvc parasol-claims -n "$NS" -o jsonpath='{.status.traffic[*].tag}' 2>/dev/null || true)" ]]
}

# Eventing objects (namespaced; attendee admin reads them via the aggregated admin role).
broker_present()     { oc get broker.eventing.knative.dev default -n "$NS" >/dev/null 2>&1; }
trigger_present()    { oc get trigger.eventing.knative.dev claims-processor -n "$NS" >/dev/null 2>&1; }
pingsource_present() { oc get pingsource.sources.knative.dev claim-ticker -n "$NS" >/dev/null 2>&1; }

# Entry clean-slate helpers: return 0 when the solve object is ABSENT (attendee has built nothing yet).
no_traffic_split() { ! ksvc_traffic_split; }
no_eventing() {
  [[ -z "$(oc get broker.eventing.knative.dev,trigger.eventing.knative.dev,pingsource.sources.knative.dev -n "$NS" -o name 2>/dev/null || true)" ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                       oc get ns "$NS"                 || hint "run: ws prep m19 (or ws start m19 --user ${USER_NAME}); the ${NS} namespace is workshop-layer (workshop-config)"
check "entry marker ws-entry-m19 present"            oc get cm ws-entry-m19 -n "$NS" || hint "entry app not synced — ws reset m19 --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"   deploy_ready claims-db          || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "demo-client deployment has >=1 ready replica" deploy_ready demo-client        || hint "the in-cluster load pod isn't up — oc get pods -l app=demo-client -n ${NS}"
check "parasol-claims Knative Service present"       ksvc_present                    || hint "entry app not synced (is the serverless stack installed?) — ws reset m19 --user ${USER_NAME}"
check "parasol-claims ksvc is Ready"                 ksvc_ready                      || hint "revision not Ready — check image pull + claims-db: oc get ksvc,revision -n ${NS}; oc get pods -n ${NS}"
check "parasol-claims ksvc has an auto-created URL (edge Route)" ksvc_has_url        || hint "Knative auto-publishes the edge Route — a blank status.url means the Route/Kourier isn't ready: oc get ksvc parasol-claims -n ${NS} -o yaml"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — one revision, no split, no eventing --------------------------------
  check "no tag-based traffic split yet (attendee splits revisions)" no_traffic_split || hint "entry ships one revision; if the ksvc traffic is tag-split the lab already started — ws reset m19 --user ${USER_NAME}"
  check "no eventing objects yet (attendee wires source->broker->trigger)" no_eventing || hint "entry ships no Broker/Trigger/PingSource; if they exist the lab already started — ws reset m19 --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOMES — tuned + split + eventing wired ---------------------------------
  # Assert OUTCOMES (ksvc tag-split; a Broker, Trigger and PingSource exist), never the exact CR wording,
  # so any correct attendee solution stays green (rule 14).
  check "parasol-claims ksvc traffic is tag-split (blue/green)"     ksvc_traffic_split || hint "split traffic across two revisions with tags (e.g. kn service update parasol-claims --traffic ...) — see the lab"
  check "eventing Broker present (in-memory)"                       broker_present     || hint "create a Broker in ${NS} (kn broker create default) — the eventing-taste hub"
  check "Trigger present (Broker -> parasol-claims ksvc)"           trigger_present    || hint "create a Trigger routing the Broker to the parasol-claims ksvc (see the lab)"
  check "PingSource present (source -> Broker)"                     pingsource_present || hint "create a PingSource emitting events into the Broker (see the lab)"
fi

verify_summary
