#!/usr/bin/env bash
# Verify observability-health-scale — Observability, Health & Scale.
#   Entry: {user}-dev has the INSTRUMENTED claims app (OTLP export ON → the shared collector) + an
#          ephemeral claims-db + a load generator, plus a per-user ServiceMonitor; /q/metrics exposes
#          the golden signals and the custom claims_created_total. The scale/resilience objects the lab
#          builds (HPA, PrometheusRule, PDB) are NOT present yet.
#   End:   the lab's outcomes exist — a CPU HorizontalPodAutoscaler on parasol-claims (>=2 replicas),
#          a PrometheusRule alert, and a PodDisruptionBudget.
# Runnable as the attendee: reads only {user}-dev, and probes the app's OWN Route for /q/metrics — no
# cross-namespace reads (rule 10). The one exception is the attendee-visibility guard at the bottom,
# which queries the UWM *tenancy* rules endpoint with the CALLER's own token and the mandatory
# ?namespace={user}-dev — the same request the attendee's console page makes, so it stays inside the
# attendee's own tenancy. See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# The claims Route answers HTTP 200 on the readiness endpoint (also proves the app reached its
# datasource — readiness gates on the DB connection). parasol-claims is API-only, so probe /q/health/ready.
route_ready_200() {
  local host code
  # Route read classified via oc_read (_lib.sh); the HTTP probe below stays graded — "the app does
  # not answer" IS the outcome under test, unlike "the API could not be asked".
  oc_read get route parasol-claims -n "$NS" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# parasol-claims has the OpenTelemetry SDK turned ON (the seam that emits traces to the collector).
claims_otel_enabled() {
  oc_read get deploy parasol-claims -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="QUARKUS_OTEL_SDK_DISABLED")].value}' || return 1
  [[ "$OC_OUT" == "false" ]]
}

# parasol-claims exports OTLP to the shared observability-workshop collector.
claims_otel_endpoint() {
  oc_read get deploy parasol-claims -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' || return 1
  [[ "$OC_OUT" == *"otel-collector.ogsr-observability-workshop"* ]]
}

# /q/metrics (scraped by the ServiceMonitor) exposes a given metric name. Retries briefly: a
# Micrometer counter (claims_created_total) only appears after the load generator's first POST.
metrics_expose() {
  local needle="$1" host out
  oc_read get route parasol-claims -n "$NS" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  for _ in $(seq 1 10); do
    out="$(curl -ks --max-time 15 "http://${host}/q/metrics" 2>/dev/null || true)"
    grep -q "$needle" <<<"$out" && return 0
    sleep 3
  done
  return 1
}

# The parasol-claims Deployment has at least N ready replicas (>= so the lab may scale past the floor).
claims_replicas_at_least() {
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.status.readyReplicas}' || return 1
  [[ -n "$OC_OUT" && "$OC_OUT" -ge "$1" ]]
}

# The parasol-claims ServiceMonitor scrapes every 10s. Not cosmetic: the alert beat (Ex3) needs the
# ~30s 5xx window (DB gone -> readiness pulls the pod) to span >=3 scrapes so rate() sees a RISING
# counter and the rule fires deterministically. A 30s scrape re-introduces the G3 "never fires" flake
# (the counter is sampled once, at its frozen value -> rate()==0). Guards both entry and end state.
servicemonitor_scrape_10s() {
  oc_read get servicemonitor parasol-claims -n "$NS" -o jsonpath='{.spec.endpoints[0].interval}' || return 1
  [[ "$OC_OUT" == "10s" ]]
}

# --- attendee-visible alerting (the guard the SEV1 was missing) --------------
# The attendee's alerting page is the console's PROJECT-scoped view
#   /dev-monitoring/ns/{user}-dev/alertrules?alert-source=user
# served by the UWM *tenancy* rules endpoint on thanos-querier:9093. It is NOT the cluster-wide
# /monitoring/alertrules page: that one comes off port 9091, whose kube-rbac-proxy authorizes
# `get prometheuses/api` (name k8s) in openshift-monitoring — an attendee is denied it and the page
# renders 0 - 0 of 0 (measured as user1, 2026-07-28; that was the SEV1). `oc get prometheusrule` as
# cluster-admin stayed green through the whole incident, so everything below asserts the state the
# ATTENDEE can actually retrieve.

# `oc auth can-i --as` needs impersonation rights, which only admin/CI has. When the attendee runs
# this in their own cockpit terminal there is nobody to impersonate — their own SelfSubjectAccessReview
# IS the attendee answer. Flags stay literal in both branches: an --as string built from a variable
# silently reviews the wrong subject.
IMPERSONATE_AS_ATTENDEE="false"
if [[ "$(oc whoami 2>/dev/null || true)" != "$USER_NAME" ]] && oc auth can-i impersonate users >/dev/null 2>&1; then
  IMPERSONATE_AS_ATTENDEE="true"
fi

# The exact SubjectAccessReview thanos-querier runs for the tenancy rules port — resource
# prometheusrules in monitoring.coreos.com, namespace taken from the ?namespace= parameter (read out
# of secret/thanos-querier-kube-rbac-proxy-rules, 2026-07-29). Attendees get it from the workshop
# layer's monitoring-edit RoleBinding; drop that binding and the page goes empty while every
# admin-side check stays green.
attendee_reads_namespaced_rules() {
  if [[ "$IMPERSONATE_AS_ATTENDEE" == "true" ]]; then
    oc auth can-i get prometheusrules.monitoring.coreos.com -n "$NS" \
      --as="$USER_NAME" --as-group=workshop-attendees
  else
    oc auth can-i get prometheusrules.monitoring.coreos.com -n "$NS"
  fi
}

# Fetch the page's own data source once, with the CALLER's token. The tenancy ports carry no Route, so
# this resolves in-cluster only (cockpit terminal, ws smoke) — an off-cluster maintainer run is
# INCONCLUSIVE (⚠), never a ❌. Measured 2026-07-29: no ?namespace= -> 400, no token -> 401, a
# namespace with no user rules -> 200 with {"groups":[]} — that 200-plus-empty IS the broken page.
TENANCY_RULES_URL="https://thanos-querier.openshift-monitoring.svc:9093/api/v1/rules"
TENANCY_STATE="unreachable"   # unreachable (inconclusive) | denied (hard fail) | ok
TENANCY_BODY=""

tenancy_rules_fetch() {
  local token resp code
  token="$(oc whoami -t 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    return 0
  fi
  for _ in 1 2 3; do
    resp="$(curl -ks --max-time 10 -w '\n%{http_code}' \
              -H "Authorization: Bearer ${token}" \
              "${TENANCY_RULES_URL}?namespace=${NS}" 2>/dev/null || true)"
    code="${resp##*$'\n'}"
    if [[ "$code" == "200" ]]; then
      TENANCY_BODY="${resp%$'\n'*}"
      TENANCY_STATE="ok"
      return 0
    fi
    if [[ "$code" == "401" || "$code" == "403" ]]; then
      TENANCY_STATE="denied"
      return 0
    fi
    # code 000 means curl never got an HTTP response at all (DNS/connection failure — off-cluster,
    # or the service genuinely isn't there). That is not a transient service-side condition a sleep
    # + retry can wait out, unlike an actual 5xx from thanos-querier — so stop immediately instead
    # of burning 2 more rounds of sleep-and-hope for an outcome that cannot change.
    if [[ "$code" == "000" ]]; then
      break
    fi
    sleep 3
  done
  return 0
}

tenancy_endpoint_ok() { [[ "$TENANCY_STATE" == "ok" ]]; }

# How many ALERTING rules the attendee's page would list. Name-agnostic on purpose (template rule 14):
# the outcome is "the page is not empty", and Thanos Ruler only serves a group it actually loaded — so
# this also catches a PrometheusRule that exists but was rejected, which an object-existence check
# cannot see. An attendee who names their alert something other than ParasolClaimsErrorRateHigh still
# passes, as they should.
tenancy_alerting_rule_count() {
  grep -o '"type":[[:space:]]*"alerting"' <<<"$TENANCY_BODY" | wc -l | tr -d '[:space:]'
}
tenancy_lists_an_alerting_rule() {
  local n
  n="$(tenancy_alerting_rule_count)"
  [[ "$n" -ge 1 ]]
}

# Entry clean-slate helpers: the scale/alert/resilience beats haven't been built yet. Each requires
# the namespace to actually exist first — otherwise an empty `oc get` result is vacuous (true on a
# cluster where nothing materialized at all), not evidence of a clean, correctly-seeded entry state.
# NEGATION IS THE DANGEROUS DIRECTION: `[[ -z "$(oc get … 2>/dev/null)" ]]` certifies a clean slate
# from an API that never answered. ns_exists_then_absent asks both questions through oc_read, so an
# unanswerable read is ⚠ SKIP — never the silent PASS the old shape produced.
ns_exists_then_absent() {  # <resource> [name] → 0 when the namespace exists and the object does not
  oc_present get ns "$NS" -o name || return 1
  if [[ -n "${2:-}" ]]; then oc_absent get "$1" "$2" -n "$NS" -o name
  else                       oc_absent get "$1" -n "$NS" -o name
  fi
}
# At least one PrometheusRule in the namespace. Was an inline `test -n "$(oc get … 2>/dev/null)"` at
# the call site — the substitution ran BEFORE check() ever saw it, so the error was gone by then and
# no amount of work inside check() could have classified it. Moved into a predicate for that reason.
prometheusrule_exists() {
  oc_read get prometheusrule -n "$NS" -o name || return 1
  [[ -n "$OC_OUT" ]]
}

no_hpa_yet()  { ns_exists_then_absent hpa parasol-claims; }
no_rule_yet() { ns_exists_then_absent prometheusrule; }
no_pdb_yet()  { ns_exists_then_absent pdb parasol-claims; }

# The HPA targets parasol-claims on CPU.
hpa_on_cpu() {
  local tgt
  oc_read get hpa parasol-claims -n "$NS" -o jsonpath='{.spec.scaleTargetRef.name}' || return 1
  tgt="$OC_OUT"
  oc_read get hpa parasol-claims -n "$NS" -o jsonpath='{.spec.metrics[?(@.type=="Resource")].resource.name}' || return 1
  [[ "$tgt" == "parasol-claims" && "$OC_OUT" == "cpu" ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                            oc get ns "$NS"                               || hint "run: ws start observability-health-scale --user ${USER_NAME}"
check "entry marker ws-entry-observability-health-scale present"                 oc get cm ws-entry-observability-health-scale -n "$NS"               || hint "entry app not synced — ws start observability-health-scale --user ${USER_NAME}"
check "workshop quota present in ${NS}"                   oc get resourcequota workshop-quota -n "$NS"  || hint "workshop layer not applied — run bootstrap/install.sh"
check "claims-db deployment has >=1 ready replica"        deploy_ready claims-db "$NS"                  || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica"   deploy_ready parasol-claims "$NS"             || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "claims Route answers 200 (/q/health/ready)"        route_ready_200                               || hint "claims app not ready — check: oc get pods -n ${NS}"
check "parasol-claims has OpenTelemetry export ON"        claims_otel_enabled                           || hint "OTLP disabled — entry sets QUARKUS_OTEL_SDK_DISABLED=false; ws reset observability-health-scale --user ${USER_NAME}"
check "parasol-claims exports OTLP to shared collector"   claims_otel_endpoint                          || hint "OTEL endpoint unset — should point at otel-collector.ogsr-observability-workshop; ws reset observability-health-scale"
check "ServiceMonitor parasol-claims present"             oc get servicemonitor parasol-claims -n "$NS" || hint "per-user metrics wiring missing — ws reset observability-health-scale --user ${USER_NAME}"
check "ServiceMonitor scrapes every 10s (alert-beat determinism)" servicemonitor_scrape_10s          || hint "entry ships a 10s scrape so the Ex3 alert fires deterministically; a 30s interval re-introduces the flake — ws reset observability-health-scale --user ${USER_NAME}"
check "load generator claims-load has >=1 ready replica"  deploy_ready claims-load "$NS"                || hint "load generator missing — ws reset observability-health-scale --user ${USER_NAME}"
check "/q/metrics exposes http_server_requests (golden signals)" metrics_expose http_server_requests_seconds || hint "metrics endpoint not answering — check: oc get pods -n ${NS}"
check "/q/metrics exposes claims_created_total (custom metric)"  metrics_expose claims_created_total         || hint "custom counter absent — the load generator POSTs claims to register it; check: oc logs deploy/claims-load -n ${NS}"
check "attendee can read alerting rules in ${NS} (tenancy RBAC)" attendee_reads_namespaced_rules            || hint "the project-scoped Alerting rules page would be EMPTY — the workshop layer's ${USER_NAME}-monitoring-edit RoleBinding is missing; run bootstrap/install.sh"

# Both modes: entry ships no PrometheusRule, so an empty rule list is CORRECT there — at entry we only
# prove the endpoint answers for this namespace (UWM up + caller authorized). The not-empty assertion
# is end-state only, below.
tenancy_rules_fetch
if [[ "$TENANCY_STATE" == "unreachable" ]]; then
  warn "project-scoped Alerting rules endpoint unreachable from here — attendee-visibility check"
  hint "run it where the attendee is — from the cockpit terminal: ws verify observability-health-scale (thanos-querier:9093 is in-cluster only, it has no Route, so an off-cluster run cannot answer this)"
else
  check "project-scoped Alerting rules endpoint answers for ${NS}"  tenancy_endpoint_ok                     || hint "UWM tenancy rules API rejected this identity (401/403) — the attendee's Alerting rules page would be empty; check the monitoring-edit RoleBinding and that enableUserWorkload is true"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the scale/resilience objects the lab builds do NOT exist yet ---------------
  check "no HorizontalPodAutoscaler yet (scale beat not started)"   no_hpa_yet   || hint "entry state has no HPA — ws reset observability-health-scale --user ${USER_NAME}"
  check "no PrometheusRule yet (alert beat not started)"            no_rule_yet  || hint "entry state has no alert rule — ws reset observability-health-scale --user ${USER_NAME}"
  check "no PodDisruptionBudget yet (resilience beat not started)"  no_pdb_yet   || hint "entry state has no PDB — ws reset observability-health-scale --user ${USER_NAME}"
else
  # --- end state: the lab's outcomes exist (HPA + alert + PDB); >= replicas, never == ----------
  check "HorizontalPodAutoscaler parasol-claims targets CPU"       hpa_on_cpu                                    || hint "create the HPA: oc autoscale deploy/parasol-claims --cpu=60% --min=2 --max=4 -n ${NS}"
  check "parasol-claims has >=2 ready replicas (HPA floor)"        claims_replicas_at_least 2                    || hint "HPA floor is 2 — wait: oc get hpa parasol-claims -n ${NS}"
  check "a PrometheusRule alert exists in ${NS}"                   prometheusrule_exists                         || hint "create an alerting rule (PrometheusRule) in ${NS} — see the alert beat"
  # The object existing is not the outcome — the attendee SEEING it is. Only assert this when the
  # endpoint answered; unreachable already printed its ⚠, and a denied endpoint already failed above.
  if [[ "$TENANCY_STATE" == "ok" ]]; then
    check "attendee's Alerting rules page lists >=1 rule for ${NS}" tenancy_lists_an_alerting_rule          || hint "the /dev-monitoring/ns/${NS}/alertrules?alert-source=user page is EMPTY for the attendee — if 'oc get prometheusrule -n ${NS}' is empty, create the alert (alert beat); if it lists one, Thanos Ruler did not load it (bad expr, or give UWM ~30s and re-verify)"
  fi
  check "PodDisruptionBudget parasol-claims exists"               oc get pdb parasol-claims -n "$NS"            || hint "create a PDB: oc create pdb parasol-claims --selector app=parasol-claims --min-available=1 -n ${NS}"
fi

verify_summary
