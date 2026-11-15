#!/usr/bin/env bash
# Verify health-resources-autoscaling — Health, Resources & Autoscaling.
#   Entry: {user}-dev has the claims app + PostgreSQL + the claims-load generator; the app carries
#          NO probes and there is NO HorizontalPodAutoscaler yet (adding both is the lab). With
#          --entry-only, those two absences are asserted, so a half-done lab never passes as a
#          clean entry and `ws prep` never takes its "already prepared" fast path over it.
#   End:   parasol-claims carries all three probes with liveness on /q/health/live (not exercise
#          2's typo), an explicit CPU request (the HPA computes utilization against it) and a memory
#          limit; an HPA targets it on CPU with a floor of at least 2; at least 2 replicas are ready;
#          its latest rollout completed (catches exercise 3's OOMKilled break left in place, which
#          every ">= N ready" check misses); the Route answers 200.
#          Every count is >=, never ==: the HPA may legitimately hold 3 or 4 after the load beat.
# Runnable as the attendee with only oc + curl, reading only {user}-dev. See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# deploy_ready / deploy_ready_min are shared — tools/verify/_lib.sh (they poll briefly and classify
# an unanswerable API as ⚠, never ❌).

# The claims Route answers HTTP 200 on the readiness endpoint (also proves DB connectivity: Quarkus
# readiness includes the datasource). The Route READ is classified; the HTTP probe stays graded,
# because "the app does not answer" IS the outcome under test.
route_ready_200() {
  local host code
  oc_read get route parasol-claims -n "$NS" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "http://${host}/q/health/ready" || true)"
  [[ "$code" == "200" ]]
}

# Entry: the Deployment exists and declares none of the three probes. Asked in one read; the
# Deployment missing is rc 1 (a real NO), so this cannot pass on an empty namespace.
no_probes_yet() {
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe}{.spec.template.spec.containers[0].readinessProbe}{.spec.template.spec.containers[0].livenessProbe}' || return 1
  [[ -z "$OC_OUT" ]]
}

# Entry: no HPA of any name. The namespace must exist first, or absence is vacuous.
no_hpa_yet() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent  get hpa -n "$NS" -o name
}

# End: all three probes are set (any handler — the lab uses HTTP GET, a console user may not).
deploy_has_all_probes() {
  local p
  for p in startupProbe readinessProbe livenessProbe; do
    oc_read get deploy parasol-claims -n "$NS" -o jsonpath="{.spec.template.spec.containers[0].${p}}" || return 1
    [[ -n "$OC_OUT" ]] || return 1
  done
}

# End: an explicit value on the Deployment itself — the LimitRange default lands on the Pod only,
# so it never satisfies this. <jsonpath under .resources>
deploy_resource_set() {
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath="{.spec.template.spec.containers[0].resources.$1}" || return 1
  [[ -n "$OC_OUT" ]]
}

# End: liveness points at the real endpoint. Presence alone passes with exercise 2's deliberate typo
# (/q/health/alive) still in place — that pod restarts every ~30 s yet is ready most of the time, so
# no readiness check notices it.
liveness_path_ok() {
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' || return 1
  [[ "$OC_OUT" == "/q/health/live" ]]
}

# End: the latest rollout finished — every replica runs the current template and is ready, and no
# old-template pod is left (what `oc rollout status` waits for). This is what catches exercise 3's
# OOMKilled break left in place: the old pod keeps serving, so every ">= N ready" check stays green,
# while the new pod crash-loops and the rollout never completes. Polls to the shared settle budget
# (_lib.sh), because a rollout or an HPA scale-out legitimately takes seconds to converge.
# Fields are '|'-separated so an absent count (rendered empty) never shifts the others.
rollout_complete() {
  local deadline=$(( SECONDS + VERIFY_SETTLE_BUDGET_S )) gen seen want upd total ready
  while :; do
    oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.spec.replicas}|{.status.updatedReplicas}|{.status.replicas}|{.status.readyReplicas}' || return $?
    IFS='|' read -r gen seen want upd total ready <<<"$OC_OUT"
    if [[ "${seen:-0}" -ge "${gen:-1}" && "${upd:-0}" == "$want" && "${total:-0}" == "$want" && "${ready:-0}" == "$want" ]]; then return 0; fi
    if (( SECONDS >= deadline )); then return 1; fi
    sleep "$VERIFY_SETTLE_POLL_S"
  done
}

# End: SOME HPA targets parasol-claims on CPU with minReplicas >= 2. Name-agnostic: `oc autoscale`
# names it parasol-claims, the console form lets the attendee pick. An unset minReplicas means 1.
hpa_on_cpu_min2() {
  local tgt min res
  oc_read get hpa -n "$NS" -o jsonpath='{range .items[*]}{.spec.scaleTargetRef.name}{" "}{.spec.minReplicas}{" "}{.spec.metrics[?(@.type=="Resource")].resource.name}{"\n"}{end}' || return 1
  while read -r tgt min res; do
    # An unset minReplicas leaves two spaces, so `read` shifts the metric name into $min.
    if [[ ! "$min" =~ ^[0-9]+$ ]]; then res="$min ${res}"; min=1; fi
    if [[ "$tgt" == "parasol-claims" && "$min" -ge 2 && " ${res} " == *" cpu "* ]]; then return 0; fi
  done <<<"$OC_OUT"
  return 1
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                                   oc get ns "$NS"                                    || hint "run: ws prep health-resources-autoscaling"
check "entry marker ws-entry-health-resources-autoscaling present" oc get cm ws-entry-health-resources-autoscaling -n "$NS" || hint "entry app not synced — ws prep health-resources-autoscaling"
check "workshop quota present in ${NS}"                          oc get resourcequota workshop-quota -n "$NS"       || hint "workshop layer not applied — run bootstrap/install.sh"
check "claims-db deployment ready in ${NS}"                      deploy_ready claims-db "$NS"                       || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment ready in ${NS}"                 deploy_ready parasol-claims "$NS"                  || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}; if a pod shows OOMKilled, the memory limit is too low — set it back: oc set resources deploy/parasol-claims -n ${NS} --requests=memory=256Mi --limits=memory=512Mi"
check "claims-load generator ready in ${NS}"                     deploy_ready claims-load "$NS"                     || hint "the load generator drives the autoscaling exercise — ws reset health-resources-autoscaling restores it"
check "route parasol-claims answers 200 in ${NS}"                route_ready_200                                    || hint "no ready pod behind the Route — if you broke a probe on purpose, restore it: oc set probe deploy/parasol-claims -n ${NS} --readiness --get-url=http://:8080/q/health/ready"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: the objects the lab adds do NOT exist yet --------------------------------
  check "parasol-claims has no probes yet (the lab adds them)"    no_probes_yet || hint "probes from an earlier run are still set — ws reset health-resources-autoscaling for a clean entry"
  check "no HorizontalPodAutoscaler yet (the lab creates it)"     no_hpa_yet    || hint "an HPA from an earlier run is still present — ws reset health-resources-autoscaling for a clean entry"
else
  # --- end state (what a completed lab looks like) ---------------------------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "parasol-claims has all three probes"                     deploy_has_all_probes                          || hint "not done yet — exercises 1 and 2 add readiness, liveness and startup (oc set probe deploy/parasol-claims --readiness/--liveness/--startup ...); expected red until you do"
  check "liveness probe checks /q/health/live"                    liveness_path_ok                               || hint "not done yet, or exercise 2's typo is still in place (the pod keeps restarting) — fix it: oc set probe deploy/parasol-claims -n ${NS} --liveness --get-url=http://:8080/q/health/live --period-seconds=10 --failure-threshold=3"
  check "parasol-claims sets an explicit CPU request"             deploy_resource_set requests.cpu               || hint "not done yet — exercise 3 sets it (oc set resources deploy/parasol-claims --requests=cpu=200m,memory=256Mi --limits=cpu=500m,memory=512Mi); the HPA cannot compute CPU utilization without it"
  check "parasol-claims sets a memory limit"                      deploy_resource_set limits.memory              || hint "not done yet — exercise 3 sets it with the same oc set resources command; expected red until you do"
  check "an HPA scales parasol-claims on CPU (min >= 2)"          hpa_on_cpu_min2                                || hint "not done yet — exercise 4 creates it: oc autoscale deploy/parasol-claims --cpu=60% --min=2 --max=4 -n ${NS}"
  check "parasol-claims has >=2 ready replicas (HPA floor)"       deploy_ready_min parasol-claims "$NS" 2        || hint "not done yet? with no HPA nothing holds the floor at 2, so this follows from the check above. If the HPA EXISTS, give it a minute, then look: oc get hpa -n ${NS}; oc get pods -n ${NS} -l app=parasol-claims"
  check "parasol-claims rollout complete (no stuck new pod)"      rollout_complete                               || hint "a new pod never became ready, so the old one is still serving. If it shows OOMKilled or CrashLoopBackOff, exercise 3's too-small memory limit is still in place — restore it: oc set resources deploy/parasol-claims -n ${NS} --requests=memory=256Mi --limits=memory=512Mi. Otherwise look at it: oc get pods -n ${NS} -l app=parasol-claims"
fi

verify_summary
