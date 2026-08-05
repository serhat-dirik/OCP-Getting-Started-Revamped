#!/usr/bin/env bash
# Verify eventing-deep-dive — Eventing Deep-Dive & Serverless Workflows.
#   Entry: {user}-dev holds the serverless-zero-to-hero serverless END state PLUS the eventing-deep-dive eventing substrate, all deployed:
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

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# A named Knative Service exists in {user}-dev. A missing ksvc CRD ("the server doesn't have a
# resource type") is the server's own answer and still fails loudly — Serverless not installed is a
# real platform failure, not an inconclusive read.
ksvc_present() { oc_present get ksvc "$1" -n "$NS" -o name; }

# A named ksvc reports Ready=True (latest revision came up + Route admitted). Stays True scaled to zero.
ksvc_ready() {
  oc_read get ksvc "$1" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || return 1
  [[ "$OC_OUT" == "True" ]]
}

# A named ksvc has an auto-created external URL (the operator-managed edge Route is admitted) — the
# attendee-readable proof the consumer is Addressable, unlike the Route object in knative-serving-ingress.
ksvc_has_url() {
  oc_read get ksvc "$1" -n "$NS" -o jsonpath='{.status.url}' || return 1
  [[ -n "$OC_OUT" ]]
}

# Eventing objects (namespaced; attendee admin reads them via the aggregated admin role).
broker_present() { oc_present get broker.eventing.knative.dev default -n "$NS" -o name; }
broker_ready() {
  oc_read get broker.eventing.knative.dev default -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || return 1
  [[ "$OC_OUT" == "True" ]]
}
pingsource_present()   { oc_present get pingsource.sources.knative.dev claim-ticker -n "$NS" -o name; }
base_trigger_present() { oc_present get trigger.eventing.knative.dev claims-events -n "$NS" -o name; }

# OUTCOME detectors (rule 14 — assert the shape, not the name). A non-empty jsonpath line means at least
# one Trigger carries that field.
# Both go through _lib.sh's oc_read rather than `2>/dev/null`: a silenced list cannot tell "no Trigger
# carries that field" (a gradeable ❌ on the end-state outcome) from "the cluster did not answer" (a ⚠
# that is never the attendee's fault). rc 0 with an empty OC_OUT is still a real, graded absence.
#
# CONTENT, NOT MERE PRESENCE (false-pass audit F-11, 2026-08-05). Both detectors used to accept any
# line matching `[a-zA-Z]`, and the jsonpath renders Go's map syntax — so the literal word "map" in
# `map[]` (a filter block with no attributes) and in `map[type:]` (an attribute whose value is empty
# or mistyped) matched, and so did `map[ref:map[]]` for a deadLetterSink whose ref names nothing. The
# attendee got ✅ for a Trigger that filters nothing and a DLQ that sinks nowhere: the entry state
# pins the baseline, so they DID have to add something — they just did not have to make it work,
# which is the whole lesson. Both now demand a value on the other side of the colon.
#
# NOT narrowed to a particular attribute or sink. The lab drives `type` and the `claimpriority`
# extension attribute, the DLQ may be addressed by `ref` OR by `uri`, and an attendee may add their
# own sink — trading a false ✅ for a false ❌ on a correct solution is not a win (rule 14).
# Readiness is deliberately NOT asserted either: exercise 4 kills the consumer on purpose, so a
# correctly-wired Trigger is legitimately not Ready for part of the lab.

# A Trigger carrying an attribute filter with a NON-EMPTY value (attribute-based routing wired).
# Go prints the attribute map as `map[type:dev.knative.sources.ping]`; the regex demands a colon with
# a non-`]`, non-blank character on BOTH sides, so `map[]`, `map[type:]` and `map[type: ]` all fail.
filtered_trigger_present() {
  oc_read get trigger.eventing.knative.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.filter.attributes}{"\n"}{end}' || return 1
  grep -Eq '[^][:space:]]:[^][:space:]]' <<<"$OC_OUT"
}
# A Trigger whose deadLetterSink actually ADDRESSES something (delivery/DLQ wired).
# The two fields are read directly rather than pattern-matched out of the Go map, because
# `map[ref:map[]]` — a ref with no name — is indistinguishable from a real one by shape alone. One
# line per Trigger, `<ref.name>|<uri>`: a line carrying any character that is neither the separator
# nor blank means one of the two is set. A Knative Destination is exactly ref-or-uri, so this is the
# full vocabulary, not a subset.
dlq_trigger_present() {
  oc_read get trigger.eventing.knative.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.delivery.deadLetterSink.ref.name}{"|"}{.spec.delivery.deadLetterSink.uri}{"\n"}{end}' || return 1
  grep -Eq '[^|[:space:]]' <<<"$OC_OUT"
}
# PRESENCE detectors — the LOOSE half of each pair, and the only thing the entry side may negate.
#
# WHY NOT JUST `! filtered_trigger_present`. Tightening the end predicate above without adding these
# would have moved the defect rather than fixed it. `ws prep` reads --entry-only's rc as "is this
# world already prepared?" and skips its purge on rc 0, so a world holding a half-wired Trigger — the
# exact `map[type:]` the end check now correctly refuses — would have been certified a clean slate and
# left in place for the next attendee. That is the F-05 class, bought with the F-11 fix.
#
# The invariant the two halves must satisfy is NOT "entry == !end" but "entry ⇒ !end": no world may
# ever be BOTH complete and a clean slate, because `ws prep` would then either skip setup or offer to
# WIPE a finished lab. Strict IMPLIES loose (a filter with a value is a filter block; an addressed
# sink is a sink block), so ¬loose ⇒ ¬strict, and negating the LOOSE detector satisfies the invariant
# with room to spare. The half-wired world in between is neither complete nor clean — which is the
# honest verdict for it, and the one that keeps prep purging.
#
# Any non-blank output means the field is rendered at all (Go prints even an empty map as `map[]`).
any_filter_attributes() {
  oc_read get trigger.eventing.knative.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.filter.attributes}{"\n"}{end}' || return 1
  grep -q '[^[:space:]]' <<<"$OC_OUT"
}
any_dead_letter_sink() {
  oc_read get trigger.eventing.knative.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.delivery.deadLetterSink}{"\n"}{end}' || return 1
  grep -q '[^[:space:]]' <<<"$OC_OUT"
}

# Entry clean-slate helpers: return 0 when the outcome is ABSENT (attendee has built nothing yet).
# Require the namespace to exist first — otherwise "absent" is vacuous (true on a cluster where
# nothing materialized at all), not evidence of a clean, correctly-seeded entry state.
no_filtered_trigger() {
  oc_read get ns "$NS" || return 1
  ! any_filter_attributes
}
no_dlq_trigger() {
  oc_read get ns "$NS" || return 1
  ! any_dead_letter_sink
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                 || hint "run: ws prep eventing-deep-dive (or ws start eventing-deep-dive --user ${USER_NAME}); the ${NS} namespace is workshop-layer (workshop-config)"
check "entry marker ws-entry-eventing-deep-dive present"               oc get cm ws-entry-eventing-deep-dive -n "$NS" || hint "entry app not synced — ws reset eventing-deep-dive --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db          || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "demo-client deployment has >=1 ready replica"    deploy_ready demo-client        || hint "the in-cluster load pod isn't up — oc get pods -l app=demo-client -n ${NS}"
check "parasol-claims Knative Service is Ready"         ksvc_ready parasol-claims       || hint "the serverless-zero-to-hero claims-processor ksvc isn't Ready — check image pull + claims-db: oc get ksvc,revision -n ${NS}; oc get pods -n ${NS}"
check "claims-consumer ksvc present (net-new consumer)" ksvc_present claims-consumer    || hint "entry app not synced (is the serverless stack installed?) — ws reset eventing-deep-dive --user ${USER_NAME}"
check "claims-consumer ksvc is Ready (returns HTTP 200)" ksvc_ready claims-consumer     || hint "the showcase consumer revision isn't Ready — oc get ksvc claims-consumer -n ${NS} -o yaml; oc get pods -l app=claims-consumer -n ${NS}"
check "claims-consumer ksvc has an auto-created URL (Addressable)" ksvc_has_url claims-consumer || hint "blank status.url means the Route/Kourier isn't ready — oc get ksvc claims-consumer -n ${NS} -o yaml"
check "claims-dlq dead-letter sink ksvc is Ready"       ksvc_ready claims-dlq           || hint "the dead-letter sink isn't Ready — oc get ksvc claims-dlq -n ${NS} -o yaml"
check "eventing Broker present (in-memory)"             broker_present                  || hint "create a Broker in ${NS} (the eventing hub) — ws reset eventing-deep-dive --user ${USER_NAME}"
check "eventing Broker is Ready"                        broker_ready                    || hint "the Broker isn't Ready — oc get broker default -n ${NS} -o yaml (is KnativeEventing installed?)"
check "PingSource present (seeded source -> Broker)"    pingsource_present              || hint "the seeded PingSource is missing — ws reset eventing-deep-dive --user ${USER_NAME}"
check "baseline Trigger present (Broker -> consumer)"   base_trigger_present            || hint "the baseline claims-events Trigger is missing — ws reset eventing-deep-dive --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — substrate only, no filtered/DLQ Triggers yet -----------------------
  # These negate the LOOSE presence detectors, never the strict end predicates — see the invariant
  # spelled out above them (entry ⇒ ¬end, which is what stops one world being both "complete" and "a
  # clean slate"). Negating the strict ones instead would certify a half-wired leftover Trigger as a
  # clean slate and talk `ws prep` out of purging it. Never re-implement either condition here.
  check "no attribute filter on any Trigger yet (attendee filters routing)" no_filtered_trigger || hint "entry ships one UNFILTERED baseline Trigger; if any Trigger carries spec.filter.attributes — even an empty or half-written one — the lab already started here: ws reset eventing-deep-dive --user ${USER_NAME}"
  check "no deadLetterSink on any Trigger yet (attendee wires retries + DLQ)"     no_dlq_trigger      || hint "entry ships no deadLetterSink; if any Trigger carries spec.delivery.deadLetterSink — even one that names no sink — the lab already started here: ws reset eventing-deep-dive --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOMES — filtered routing + retry/DLQ wired -----------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "an attribute-filtered Trigger exists, with a value to match on (spec.filter.attributes)" filtered_trigger_present || hint "not done yet — the entry state deliberately ships only an UNFILTERED baseline Trigger; adding one that filters on a CloudEvent attribute (e.g. type) is the lab, so this red is expected before you start. If you HAVE added one, check the attribute has a value: a Trigger whose spec.filter.attributes is empty (or whose value is blank) matches nothing and is not graded as filtering — oc get trigger -n ${NS} -o custom-columns=NAME:.metadata.name,FILTER:.spec.filter.attributes"
  check "a Trigger's deadLetterSink addresses a real sink (retries + DLQ)"        dlq_trigger_present       || hint "not done yet — the entry state deliberately ships no deadLetterSink; adding delivery.retry + delivery.deadLetterSink (-> claims-dlq) is the retry/DLQ beat, so this red is expected before you get there. If you HAVE added one, check it points somewhere: delivery.deadLetterSink needs either a ref with a name (apiVersion/kind/name of claims-dlq) or a uri — an empty ref sinks nothing. Read it back with: oc get trigger -n ${NS} -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.spec.delivery.deadLetterSink}{\"\\n\"}{end}'"
fi

verify_summary
