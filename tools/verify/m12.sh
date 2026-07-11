#!/usr/bin/env bash
# Verify M12 — Observability, Health & Scale.
#   Entry: {user}-dev has the INSTRUMENTED claims app (OTLP export ON → the shared collector) + an
#          ephemeral claims-db + a load generator, plus a per-user ServiceMonitor; /q/metrics exposes
#          the golden signals and the custom claims_created_total. The scale/resilience objects the lab
#          builds (HPA, PrometheusRule, PDB) are NOT present yet.
#   End:   the lab's outcomes exist — a CPU HorizontalPodAutoscaler on parasol-claims (>=2 replicas),
#          a PrometheusRule alert, and a PodDisruptionBudget.
# Runnable as the attendee: reads only {user}-dev, and probes the app's OWN Route for /q/metrics — no
# cross-namespace reads, no UWM/Thanos query (rule 10). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# The claims Route answers HTTP 200 on the readiness endpoint (also proves the app reached its
# datasource — readiness gates on the DB connection). parasol-claims is API-only, so probe /q/health/ready.
route_ready_200() {
  local host code
  host="$(oc get route parasol-claims -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# parasol-claims has the OpenTelemetry SDK turned ON (the seam that emits traces to the collector).
claims_otel_enabled() {
  oc get deploy parasol-claims -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="QUARKUS_OTEL_SDK_DISABLED")].value}' 2>/dev/null \
    | grep -q '^false$'
}

# parasol-claims exports OTLP to the shared observability-workshop collector.
claims_otel_endpoint() {
  oc get deploy parasol-claims -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' 2>/dev/null \
    | grep -q 'otel-collector.observability-workshop'
}

# /q/metrics (scraped by the ServiceMonitor) exposes a given metric name. Retries briefly: a
# Micrometer counter (claims_created_total) only appears after the load generator's first POST.
metrics_expose() {
  local needle="$1" host out
  host="$(oc get route parasol-claims -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
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
  local want="$1" ready
  ready="$(oc get deploy parasol-claims -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge "$want" ]]
}

# The HPA targets parasol-claims on CPU.
hpa_on_cpu() {
  local tgt metric
  tgt="$(oc get hpa parasol-claims -n "$NS" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null || true)"
  metric="$(oc get hpa parasol-claims -n "$NS" -o jsonpath='{.spec.metrics[?(@.type=="Resource")].resource.name}' 2>/dev/null || true)"
  [[ "$tgt" == "parasol-claims" && "$metric" == "cpu" ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                            oc get ns "$NS"                               || hint "run: ws start m12 --user ${USER_NAME}"
check "entry marker ws-entry-m12 present"                 oc get cm ws-entry-m12 -n "$NS"               || hint "entry app not synced — ws start m12 --user ${USER_NAME}"
check "workshop quota present in ${NS}"                   oc get resourcequota workshop-quota -n "$NS"  || hint "workshop layer not applied — run bootstrap/install.sh"
check "claims-db deployment has >=1 ready replica"        deploy_ready claims-db "$NS"                  || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica"   deploy_ready parasol-claims "$NS"             || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "claims Route answers 200 (/q/health/ready)"        route_ready_200                               || hint "claims app not ready — check: oc get pods -n ${NS}"
check "parasol-claims has OpenTelemetry export ON"        claims_otel_enabled                           || hint "OTLP disabled — entry sets QUARKUS_OTEL_SDK_DISABLED=false; ws reset m12 --user ${USER_NAME}"
check "parasol-claims exports OTLP to shared collector"   claims_otel_endpoint                          || hint "OTEL endpoint unset — should point at otel-collector.observability-workshop; ws reset m12"
check "ServiceMonitor parasol-claims present"             oc get servicemonitor parasol-claims -n "$NS" || hint "per-user metrics wiring missing — ws reset m12 --user ${USER_NAME}"
check "load generator claims-load has >=1 ready replica"  deploy_ready claims-load "$NS"                || hint "load generator missing — ws reset m12 --user ${USER_NAME}"
check "/q/metrics exposes http_server_requests (golden signals)" metrics_expose http_server_requests_seconds || hint "metrics endpoint not answering — check: oc get pods -n ${NS}"
check "/q/metrics exposes claims_created_total (custom metric)"  metrics_expose claims_created_total         || hint "custom counter absent — the load generator POSTs claims to register it; check: oc logs deploy/claims-load -n ${NS}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the scale/resilience objects the lab builds do NOT exist yet ---------------
  check "no HorizontalPodAutoscaler yet (scale beat not started)"   test -z "$(oc get hpa parasol-claims -n "$NS" -o name 2>/dev/null)"            || hint "entry state has no HPA — ws reset m12 --user ${USER_NAME}"
  check "no PrometheusRule yet (alert beat not started)"            test -z "$(oc get prometheusrule -n "$NS" -o name 2>/dev/null)"               || hint "entry state has no alert rule — ws reset m12 --user ${USER_NAME}"
  check "no PodDisruptionBudget yet (resilience beat not started)"  test -z "$(oc get pdb parasol-claims -n "$NS" -o name 2>/dev/null)"           || hint "entry state has no PDB — ws reset m12 --user ${USER_NAME}"
else
  # --- end state: the lab's outcomes exist (HPA + alert + PDB); >= replicas, never == ----------
  check "HorizontalPodAutoscaler parasol-claims targets CPU"       hpa_on_cpu                                    || hint "create the HPA: oc autoscale deploy/parasol-claims --cpu-percent=60 --min=2 --max=4 -n ${NS}"
  check "parasol-claims has >=2 ready replicas (HPA floor)"        claims_replicas_at_least 2                    || hint "HPA floor is 2 — wait: oc get hpa parasol-claims -n ${NS}"
  check "a PrometheusRule alert exists in ${NS}"                   test -n "$(oc get prometheusrule -n "$NS" -o name 2>/dev/null)"               || hint "create an alerting rule (PrometheusRule) in ${NS} — see the alert beat"
  check "PodDisruptionBudget parasol-claims exists"               oc get pdb parasol-claims -n "$NS"            || hint "create a PDB: oc create pdb parasol-claims --selector app=parasol-claims --min-available=1 -n ${NS}"
fi

verify_summary
