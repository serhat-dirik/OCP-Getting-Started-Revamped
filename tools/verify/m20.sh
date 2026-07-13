#!/usr/bin/env bash
# Verify M20 — Eventing Deep-Dive & Serverless Workflows.
#   Entry: {user}-dev holds the M19 serverless END state PLUS the M20 eventing substrate, all deployed:
#          the parasol-claims claims-processor ksvc (+ ephemeral claims-db so its /q/health/ready passes)
#          and demo-client load pod; a default in-memory Broker; a NET-NEW real CloudEvents consumer
#          (claims-consumer, the quay showcase image — returns HTTP 200 and displays the event) and a
#          dead-letter sink (claims-dlq); a seeded PingSource; and ONE unfiltered baseline Trigger
#          (source->Broker->consumer). NO attribute-filtered Trigger and NO deadLetterSink-configured
#          Trigger yet — the attendee wires filtering, retries and the DLQ (the lab OUTCOMES). Marker set.
#   End:   the attendee wired the outcomes — a Trigger with an attribute FILTER (spec.filter.attributes)
#          routing to the consumer, and a Trigger with delivery RETRIES + a deadLetterSink to claims-dlq.
# Runnable as the ATTENDEE: reads only {user}-dev objects the attendee sees via namespace admin (the
# Knative serving/eventing CRDs aggregate to the admin role). The G1 cockpit smoke runs `--entry-only`.
#
# ROUTING NOTE: Knative auto-creates each ksvc's external edge Route in ns knative-serving-ingress
# (attendee can't read that cross-namespace, rule 10) — so a ksvc's Route is proved via the
# attendee-readable `ksvc.status.url`, NOT the OpenShift Route object.
# OUTCOME NOTE (rule 14): the end checks assert OUTCOMES (SOME Trigger carries a filter; SOME Trigger
# carries a deadLetterSink), never exact CR names, so any correct attendee solution stays green.
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

# A named Knative Service exists in {user}-dev.
ksvc_present() { oc get ksvc "$1" -n "$NS" >/dev/null 2>&1; }

# A named ksvc reports Ready=True (latest revision came up + Route admitted). Stays True scaled to zero.
ksvc_ready() {
  [[ "$(oc get ksvc "$1" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]
}

# A named ksvc has an auto-created external URL (the operator-managed edge Route is admitted) — the
# attendee-readable proof the consumer is Addressable, unlike the Route object in knative-serving-ingress.
ksvc_has_url() {
  [[ -n "$(oc get ksvc "$1" -n "$NS" -o jsonpath='{.status.url}' 2>/dev/null || true)" ]]
}

# Eventing objects (namespaced; attendee admin reads them via the aggregated admin role).
broker_present()     { oc get broker.eventing.knative.dev default -n "$NS" >/dev/null 2>&1; }
broker_ready() {
  [[ "$(oc get broker.eventing.knative.dev default -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]
}
pingsource_present() { oc get pingsource.sources.knative.dev claim-ticker -n "$NS" >/dev/null 2>&1; }
base_trigger_present() { oc get trigger.eventing.knative.dev claims-events -n "$NS" >/dev/null 2>&1; }

# OUTCOME detectors (rule 14 — assert the shape, not the name). A non-empty jsonpath line means at least
# one Trigger carries that field.
# A Trigger with a non-empty attribute filter exists (attribute-based routing wired).
filtered_trigger_present() {
  oc get trigger.eventing.knative.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.filter.attributes}{"\n"}{end}' 2>/dev/null | grep -q '[a-zA-Z]'
}
# A Trigger with a deadLetterSink configured exists (delivery/DLQ wired).
dlq_trigger_present() {
  oc get trigger.eventing.knative.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.delivery.deadLetterSink}{"\n"}{end}' 2>/dev/null | grep -q '[a-zA-Z]'
}
# Entry clean-slate helpers: return 0 when the outcome is ABSENT (attendee has built nothing yet).
no_filtered_trigger() { ! filtered_trigger_present; }
no_dlq_trigger()      { ! dlq_trigger_present; }

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                 || hint "run: ws prep m20 (or ws start m20 --user ${USER_NAME}); the ${NS} namespace is workshop-layer (workshop-config)"
check "entry marker ws-entry-m20 present"               oc get cm ws-entry-m20 -n "$NS" || hint "entry app not synced — ws reset m20 --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db          || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "demo-client deployment has >=1 ready replica"    deploy_ready demo-client        || hint "the in-cluster load pod isn't up — oc get pods -l app=demo-client -n ${NS}"
check "parasol-claims Knative Service is Ready"         ksvc_ready parasol-claims       || hint "the M19 claims-processor ksvc isn't Ready — check image pull + claims-db: oc get ksvc,revision -n ${NS}; oc get pods -n ${NS}"
check "claims-consumer ksvc present (net-new consumer)" ksvc_present claims-consumer    || hint "entry app not synced (is the serverless stack installed?) — ws reset m20 --user ${USER_NAME}"
check "claims-consumer ksvc is Ready (returns HTTP 200)" ksvc_ready claims-consumer     || hint "the showcase consumer revision isn't Ready — oc get ksvc claims-consumer -n ${NS} -o yaml; oc get pods -l app=claims-consumer -n ${NS}"
check "claims-consumer ksvc has an auto-created URL (Addressable)" ksvc_has_url claims-consumer || hint "blank status.url means the Route/Kourier isn't ready — oc get ksvc claims-consumer -n ${NS} -o yaml"
check "claims-dlq dead-letter sink ksvc is Ready"       ksvc_ready claims-dlq           || hint "the dead-letter sink isn't Ready — oc get ksvc claims-dlq -n ${NS} -o yaml"
check "eventing Broker present (in-memory)"             broker_present                  || hint "create a Broker in ${NS} (the eventing hub) — ws reset m20 --user ${USER_NAME}"
check "eventing Broker is Ready"                        broker_ready                    || hint "the Broker isn't Ready — oc get broker default -n ${NS} -o yaml (is KnativeEventing installed?)"
check "PingSource present (seeded source -> Broker)"    pingsource_present              || hint "the seeded PingSource is missing — ws reset m20 --user ${USER_NAME}"
check "baseline Trigger present (Broker -> consumer)"   base_trigger_present            || hint "the baseline claims-events Trigger is missing — ws reset m20 --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — substrate only, no filtered/DLQ Triggers yet -----------------------
  check "no attribute-filtered Trigger yet (attendee filters routing)" no_filtered_trigger || hint "entry ships one UNFILTERED baseline Trigger; if a filtered Trigger exists the lab already started — ws reset m20 --user ${USER_NAME}"
  check "no dead-letter Trigger yet (attendee wires retries + DLQ)"     no_dlq_trigger      || hint "entry ships no deadLetterSink Trigger; if one exists the lab already started — ws reset m20 --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOMES — filtered routing + retry/DLQ wired -----------------------------
  check "an attribute-filtered Trigger exists (spec.filter.attributes)" filtered_trigger_present || hint "add a Trigger that filters on a CloudEvent attribute (e.g. type) to the consumer — see the lab"
  check "a Trigger with a deadLetterSink exists (retries + DLQ)"        dlq_trigger_present       || hint "add delivery.retry + delivery.deadLetterSink (-> claims-dlq) on a Trigger — the retry/DLQ beat"
fi

verify_summary
