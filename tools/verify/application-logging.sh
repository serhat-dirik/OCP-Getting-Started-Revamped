#!/usr/bin/env bash
# Verify application-logging — Application Logging.
#   Entry: {user}-dev runs the claims app (ONE replica, shared image) + ephemeral PostgreSQL behind a
#          Route, with a readiness probe on /q/health/ready — the probe is load-bearing content, not
#          hygiene: it is what keeps the old pod serving while exercise 1's deliberately-broken one
#          crash-loops. With --entry-only, also asserts the CLEAN SLATE the lab needs: no
#          claims-logging ConfigMap, no logging env on the Deployment, one replica. Every one of
#          those is something the attendee creates, so a survivor is a collision, not residue —
#          exercise 3 creates the ConfigMap with `oc create configmap`, a CREATE-only verb at a fixed
#          name, which fails "already exists" against a leftover.
#   End:   the claims-logging ConfigMap exists and carries QUARKUS_LOG_CATEGORY__COM_PARASOL__LEVEL,
#          the Deployment SOURCES it, the app actually emits JSON records, and the Deployment sits at
#          ONE or THREE replicas.
#          MECHANISM-AGNOSTIC ON PURPOSE, twice over:
#            * the CLI path (`oc set env deploy/… --from=configmap/claims-logging`) writes per-key
#              `valueFrom.configMapKeyRef` entries, while the console path ("All values from existing
#              ConfigMaps or Secrets (envFrom)") and `ws solve` write an `envFrom.configMapRef`. The
#              lab offers both and both are correct, so the reference check reads both shapes.
#            * ONE OR THREE REPLICAS, never an exact count. Exercise 5 scales to three and the lab
#              never scales back, so three is where a completed lab ends — but an attendee who tidied
#              up afterwards has not undone the lesson, and neither has one who followed exercise 1's
#              scale-back and stopped at exercise 4. Grading either as failure would print ❌ over
#              correct work.
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

# A named object of any kind is ABSENT from a namespace. The namespace must actually exist first —
# otherwise this is vacuously true on a cluster where nothing materialized at all.
# NEGATION NEEDS THE THIRD OUTCOME MOST: `! oc get … 2>/dev/null` turns a cluster that could not be
# asked into a PASS, the one direction this must never take. oc_absent answers 0 only when the API
# ANSWERED and nothing is there.
obj_absent() {
  oc_present get ns "$3" -o name || return 1
  oc_absent  get "$1" "$2" -n "$3" -o name
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

# The claims Deployment declares exactly N replicas in its SPEC (not "how many are ready" — that is
# deploy_ready_min's question). Entry is one; the end state is one or three.
deploy_spec_replicas_in() {
  local want n
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.replicas}' || return 1
  want="$OC_OUT"
  for n in "$@"; do
    if [[ "$want" == "$n" ]]; then return 0; fi
  done
  return 1
}

# The end state's replica check, in one predicate: the spec says one or three, AND that many are
# actually ready. Split from deploy_spec_replicas_in so the ready-poll runs against the count the
# attendee actually chose — asking for ">= 3" would red-flag a correct one-replica finish, and asking
# for ">= 1" would pass a three-replica deployment with two pods stuck Pending on quota.
deploy_ready_one_or_three() {
  local want
  oc_read get deploy parasol-claims -n "$NS" -o jsonpath='{.spec.replicas}' || return 1
  want="$OC_OUT"
  case "$want" in
    1|3) ;;
    *)   return 1 ;;
  esac
  deploy_ready_min parasol-claims "$NS" "$want"
}

# The claims Deployment references a ConfigMap by name FROM ITS CONTAINERS' ENVIRONMENT — matching
# both `envFrom.configMapRef` (the console path and `ws solve`) and per-key
# `valueFrom.configMapKeyRef` (what `oc set env --from=configmap/…` writes; the lab's own captured
# `--list` output shows both keys as "from configmap claims-logging, key …").
# Asked of env/envFrom directly, NOT by grepping the whole Deployment JSON for the name: that shape
# is satisfied by any object in the manifest carrying it — a volume, a volume mount, even the
# container — so a Deployment that merely MOUNTED claims-logging would pass a check whose entire
# subject is "is it wired into the environment" (narrowed in config-multienv 2026-08-01, same bug).
deploy_references_configmap() {
  oc_read get deploy parasol-claims -n "$NS" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{range .envFrom[*]}{.configMapRef.name}{"\n"}{end}{range .env[*]}{.valueFrom.configMapKeyRef.name}{"\n"}{end}{end}' || return 1
  grep -qx -- "$1" <<<"$OC_OUT"
}

# The app is REALLY emitting structured records — the attendee-visible outcome, not just the object
# graph that should produce it. This is the check that catches the failure the instructor guide calls
# the single most likely cause of a dead lab: an image rebuilt without the quarkus-logging-json
# extension takes the setting and keeps printing free text, so every ConfigMap check above stays
# green while `jq` prints a parse error at exercise 2.
# Deliberately NOT parsed with jq: verify scripts must run with only oc + curl. A record from this
# extension is one JSON object per line carrying loggerName, which `grep` can assert without it.
# `oc logs deploy/…` reads ONE pod of the three and says so on stderr — fine here, since "is JSON on"
# is a property of the pod template, and oc_read keeps that stderr out of the matched output.
logs_are_structured_json() {
  oc_read logs "deploy/parasol-claims" -n "$NS" --tail=25 || return 1
  grep -q '^{.*"loggerName"' <<<"$OC_OUT"
}

# --- entry state (what `ws start application-logging` materializes) --------------------------
check "namespace ${NS} exists"                                oc get ns "$NS"                                     || hint "run: ws start application-logging --user ${USER_NAME}"
check "entry marker ws-entry-application-logging in ${NS}"    oc get cm ws-entry-application-logging -n "$NS"      || hint "entry app not synced — ws start application-logging --user ${USER_NAME}"
check "workshop quota present in ${NS}"                       oc get resourcequota workshop-quota -n "$NS"         || hint "workshop layer not applied — run bootstrap/install.sh"
check "claims-db deployment ready in ${NS}"                   deploy_ready claims-db "$NS"                        || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment ready in ${NS}"              deploy_ready parasol-claims "$NS"                   || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "claims readiness probe is on /q/health/ready"          readiness_probe_path_is /q/health/ready             || hint "the probe exercise 1 depends on is missing or moved — re-materialize: ws reset application-logging --user ${USER_NAME}"
check "route parasol-claims answers 200 in ${NS}"             route_ready_200                                     || hint "claims app not ready — check: oc get pods -n ${NS}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove the world is the one the lab STARTS from. `ws prep` reads this run's rc as
  # "is this environment already prepared?", so every absence the lab depends on has to be asserted
  # here — an attendee who did exercises 2-3 and stopped must NOT be told "already prepared", or the
  # next pass hard-fails on its own `oc create configmap`.
  check "no claims-logging ConfigMap in ${NS} yet (attendee creates it)"     obj_absent configmap claims-logging "$NS"           || hint "a leftover claims-logging is present; exercise 3's 'oc create configmap claims-logging …' will fail 'already exists' against it — ws reset application-logging --user ${USER_NAME} for a clean entry"
  check "QUARKUS_LOG_CONSOLE_JSON_ENABLED not set yet (exercise 2 sets it)"  deploy_env_unset QUARKUS_LOG_CONSOLE_JSON_ENABLED   || hint "structured logging is already switched on, so exercise 2 has nothing to discover — ws reset application-logging --user ${USER_NAME} for a clean entry"
  check "no leftover log-level / access-log env on the claims app"           deploy_env_unset QUARKUS_LOG_LEVEL QUARKUS_HTTP_ACCESS_LOG_ENABLED || hint "QUARKUS_LOG_LEVEL or QUARKUS_HTTP_ACCESS_LOG_ENABLED survives from a previous run — the first can leave the app crash-looping on a value you never typed. Remove it (oc set env deploy/parasol-claims QUARKUS_LOG_LEVEL- QUARKUS_HTTP_ACCESS_LOG_ENABLED- -n ${NS}) or ws reset application-logging --user ${USER_NAME}"
  check "claims app is at one replica (the lab scales it up)"                deploy_spec_replicas_in 1                           || hint "the app is not at the one replica entry ships; exercises 2-4 read a single log stream — ws reset application-logging --user ${USER_NAME} for a clean entry"
else
  # --- end state (what a completed lab looks like) ---------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "claims-logging ConfigMap exists in ${NS}"            oc get configmap claims-logging -n "$NS"                                    || hint "not done yet — you create this in lab exercise 3 (oc create configmap claims-logging …), so it is expected to be missing before then"
  check "claims-logging sets the com.parasol category level"  cm_key_set "$NS" claims-logging QUARKUS_LOG_CATEGORY__COM_PARASOL__LEVEL     || hint "not done yet? exercise 3 puts QUARKUS_LOG_CATEGORY__COM_PARASOL__LEVEL in this ConfigMap. If you believe you did set it, check the underscores: the quoted segment of quarkus.log.category.\"com.parasol\".level is delimited by DOUBLE underscores, and with single ones Quarkus logs no warning at all and the level silently stays put"
  check "claims-logging switches structured output on"        cm_key_set "$NS" claims-logging QUARKUS_LOG_CONSOLE_JSON_ENABLED             || hint "not done yet? exercise 3 moves QUARKUS_LOG_CONSOLE_JSON_ENABLED out of the one-off 'oc set env' from exercise 2 and into this ConfigMap — that move is the point of the exercise, so the key belongs here rather than on the Deployment"
  check "claims app sources the claims-logging ConfigMap"     deploy_references_configmap claims-logging                                   || hint "not done yet? exercise 3 wires it with 'oc set env deploy/parasol-claims --from=configmap/claims-logging' (or the console's envFrom picker). Both shapes pass this check; neither being present means the Deployment is still reading its logging config from nowhere"
  check "claims app emits structured JSON records"            logs_are_structured_json                                                     || hint "not done yet? the log is still free text. If the ConfigMap checks above are green and this one is red, it is NOT your lab: the shared image predates this module and does not carry the quarkus-logging-json extension — tell your instructor (rebuild ogsr-parasol-images/parasol-claims:1.0 from current main)"
  check "claims app ready at one or three replicas"           deploy_ready_one_or_three                                                    || hint "not done yet? exercise 5 scales to three replicas (oc scale deploy/parasol-claims --replicas=3) and the lab leaves it there; one is accepted too. If the count IS one or three and this is still red, the pods are not all ready: oc get pods -n ${NS}"
fi

verify_summary
