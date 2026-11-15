#!/usr/bin/env bash
# Verify application-logging — Application Logging.
#   Entry: {user}-dev runs the claims app (ONE replica, shared image) + ephemeral PostgreSQL behind a
#          Route, with a readiness probe on /q/health/ready — the probe is load-bearing content, not
#          hygiene: it is what keeps the old pod serving while exercise 1's deliberately-broken one
#          crash-loops — and with Parasol's own code (com.parasol) at DEBUG, which exercise 3's
#          correlation query needs (at INFO it finds one record, not seven). With --entry-only, also
#          asserts the CLEAN SLATE the lab needs: structured output still off, no leftover root level,
#          one replica.
#   End:   the app actually emits JSON records, and the Deployment sits at THREE replicas, all ready —
#          where exercise 3 leaves it, and what the demo's Prep block asserts after `adm solve`.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only; jq is the LAB's tool, not this script's) -------

# deploy_ready (<deployment> [namespace]) and deploy_ready_min (<deployment> <namespace> <n>) are
# shared — tools/verify/_lib.sh. Both poll to a small budget so a workload that `ws prep` created
# seconds ago is not failed for being slow, and both classify the API's answer so a cluster that
# could not be asked reports ⚠ SKIP instead of a false ❌ on the attendee's work.

# The claims Route answers HTTP 200 on the readiness endpoint (which also proves DB connectivity,
# since readiness gates on the datasource). API-only service: "/" is 404 by design.
# The ROUTE READ is classified (no Route object and no answer from the API are different things);
# the HTTP probe goes through http_read, so a status code — any status code — is graded as the real
# answer it is, while a transport failure that the cluster API cannot corroborate stays ⚠.
# The host is derived IN THIS FUNCTION'S OWN SHELL, never `h="$(…)"`: a $( ) is a subshell and a flag
# raised inside one never reaches check().
route_ready_200() {
  local host
  oc_read get route parasol-claims -n "$NS" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  http_read "http://${host}/q/health/ready" || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# The claims Deployment's readiness probe points at the expected path. Asserted rather than assumed
# because exercise 1's whole captured output — two pods, one 0/1 Error and one 1/1 Running, with the
# Route still answering — is the rolling update being gated by THIS probe. A chart edit that dropped
# it or moved it to /q/health/live would leave every other check green and the exercise pointless.
readiness_probe_path_is() {
  oc_read get deploy parasol-claims -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' || return 1
  [[ "$OC_OUT" == "$1" ]]
}

# NONE of the named environment variables is declared on the claims Deployment's containers — inline
# `value` or per-key `valueFrom` alike. This is the other half of the entry state's clean slate, and
# it is not cosmetic: `oc set env deploy/parasol-claims QUARKUS_LOG_CONSOLE_JSON_ENABLED=true` is
# exercise 2's entire discovery, and a leftover QUARKUS_LOG_LEVEL from a half-finished exercise 1 can
# leave the app crash-looping on a value the next attendee never typed.
# Nested `range` over absent keys yields empty output and exit 0, so no jq and no python3 are needed;
# `grep -qx` anchors the whole line so a longer name never matches a shorter one.
deploy_env_unset() {
  local v
  oc_read get deploy parasol-claims -n "$NS" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{range .env[*]}{.name}{"\n"}{end}{end}' || return 1
  for v in "$@"; do
    if grep -qx -- "$v" <<<"$OC_OUT"; then return 1; fi
  done
  return 0
}

# An inline environment variable on the claims container has exactly this value. The entry state's
# one logging setting — Parasol's code at DEBUG — is asserted rather than assumed: without it the
# six reads in exercise 3 write nothing and the correlation query returns one line instead of seven.
deploy_env_is() {
  oc_read get deploy parasol-claims -n "$NS" \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}" || return 1
  [[ "$OC_OUT" == "$2" ]]
}

# The claims Deployment declares exactly N replicas in its SPEC (not "how many are ready" — that is
# deploy_ready_min's question). Entry is one; the end state is three.
deploy_spec_replicas_in() {
  local want n
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.replicas}' || return 1
  want="$OC_OUT"
  for n in "$@"; do
    if [[ "$want" == "$n" ]]; then return 0; fi
  done
  return 1
}

# The app is REALLY emitting structured records — the attendee-visible outcome, not just the object
# graph that should produce it. This is the check that catches the failure the instructor guide calls
# the single most likely cause of a dead lab: an image rebuilt without the quarkus-logging-json
# extension takes the setting and keeps printing free text, so the Deployment looks right while `jq`
# prints a parse error at exercise 2.
# Deliberately NOT parsed with jq: verify scripts must run with only oc + curl. A record from this
# extension is one JSON object per line carrying loggerName, which `grep` can assert without it.
# `oc logs deploy/…` reads ONE pod of the three and says so on stderr — fine here, since "is JSON on"
# is a property of the pod template, and oc_read keeps that stderr out of the matched output.
logs_are_structured_json() {
  oc_read logs "deploy/parasol-claims" -n "$NS" --tail=25 || return 1
  grep -q '^{.*"loggerName"' <<<"$OC_OUT"
}

# --- entry state (what `ws prep application-logging` materializes) --------------------------
check "namespace ${NS} exists"                                oc get ns "$NS"                                     || hint "run: ws prep application-logging"
check "entry marker ws-entry-application-logging in ${NS}"    oc get cm ws-entry-application-logging -n "$NS"      || hint "entry app not synced — ws prep application-logging"
check "workshop quota present in ${NS}"                       oc get resourcequota workshop-quota -n "$NS"         || hint "workshop layer not applied — run bootstrap/install.sh"
check "claims-db deployment ready in ${NS}"                   deploy_ready claims-db "$NS"                        || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment ready in ${NS}"              deploy_ready parasol-claims "$NS"                   || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "claims readiness probe is on /q/health/ready"          readiness_probe_path_is /q/health/ready             || hint "the probe exercise 1 depends on is missing or moved — re-materialize: ws prep application-logging --yes"
check "route parasol-claims answers 200 in ${NS}"             route_ready_200                                     || hint "claims app not ready — check: oc get pods -n ${NS}"
check "claims app starts with Parasol's code at DEBUG"        deploy_env_is QUARKUS_LOG_CATEGORY__COM_PARASOL__LEVEL DEBUG || hint "the platform-set level exercise 3 depends on is missing or changed — re-materialize: ws prep application-logging --yes"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove the world is the one the lab STARTS from. `ws prep` reads this run's rc as
  # "is this environment already prepared?", so every absence the lab depends on has to be asserted
  # here — an attendee who did exercise 2 and stopped must NOT be told "already prepared", or the
  # next pass has nothing to discover.
  check "QUARKUS_LOG_CONSOLE_JSON_ENABLED not set yet (exercise 2 sets it)"  deploy_env_unset QUARKUS_LOG_CONSOLE_JSON_ENABLED   || hint "structured logging is already switched on, so exercise 2 has nothing to discover — ws prep application-logging --yes for a clean entry"
  check "no leftover log level on the claims app"                            deploy_env_unset QUARKUS_LOG_LEVEL                  || hint "QUARKUS_LOG_LEVEL survives from exercise 1 and can leave the app crash-looping on a value you never typed. Remove it (oc set env deploy/parasol-claims QUARKUS_LOG_LEVEL- -n ${NS}) or ws prep application-logging --yes"
  check "claims app is at one replica (the lab scales it up)"                deploy_spec_replicas_in 1                           || hint "the app is not at the one replica entry ships; exercise 2 reads a single log stream — ws prep application-logging --yes for a clean entry"
else
  # --- end state (what a completed lab looks like) ---------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "claims app emits structured JSON records"            logs_are_structured_json                                                     || hint "not done yet? exercise 2 switches structured output on (oc set env deploy/parasol-claims QUARKUS_LOG_CONSOLE_JSON_ENABLED=true). If it IS set and this is still red, it is NOT your lab: the shared image predates this module and does not carry the quarkus-logging-json extension — tell your instructor (rebuild ogsr-parasol-images/parasol-claims:1.0 from current main)"
  check "claims app is at three replicas"                     deploy_spec_replicas_in 3                                                    || hint "not done yet — exercise 3 scales to three replicas (oc scale deploy/parasol-claims --replicas=3) and the lab leaves it there"
  check "three claims replicas ready"                         deploy_ready_min parasol-claims "$NS" 3                                      || hint "the pods are not all ready yet: oc get pods -n ${NS}"
fi

verify_summary
