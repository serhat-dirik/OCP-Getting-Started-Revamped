#!/usr/bin/env bash
# Verify securing-apps-keycloak — Securing Apps with Keycloak.
#   Entry: {user}-dev has parasol-web + parasol-claims + an ephemeral claims-db, all UNPROTECTED (the
#          OIDC tenant is off) — GET /api/claims returns 200 with NO token; parasol-fraud is not up yet.
#   End:   the apps are OIDC-protected — GET /api/claims is 401 without a token and 200 with a valid
#          claims-adjuster token; the web frontend 302-redirects an unauthenticated request to Keycloak.
# Runnable as the attendee: reads only {user}-dev + the app's OWN Routes, and gets a demo token from the
# public Keycloak route recorded in the entry marker (no cross-namespace reads — rule 10).
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (oc + curl only) ------------------------------------------------

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# EVERY oc READ IN THIS FILE IS SPLIT OUT OF ITS COMMAND SUBSTITUTION, and that is the whole point of
# the shape below. The old `check "…" test "$(route_code …)" = "200"` evaluated the substitution — and
# with it the Route's oc read — in a SUBSHELL, before check() was ever entered; check() then cleared
# VERIFY_INCONCLUSIVE on the way in. So no amount of classification inside oc_read could have reached
# the verdict: a Route the API could not be asked about read as "000" and graded ❌ against work the
# attendee may well have done correctly. The oc reads now happen inside a predicate that check() calls
# in its OWN shell; the curl half is unchanged, because there is no three-outcome primitive for HTTP.

# The Route's public host. rc 1 = no Route, or the API could not be asked — the flag says which.
route_host() {  # route → OC_OUT is the host
  oc_present get route "$1" -n "$NS" -o jsonpath='{.spec.host}'
}

# HTTP status of an app Route path (edge TLS → curl https; -k because the edge cert is the cluster's).
# Echo-only twin: it touches no oc, so nothing it does can be inconclusive.
http_code() {  # host path [authHeader]
  local host="$1" path="$2" auth="${3:-}"
  if [[ -n "$auth" ]]; then
    curl -ks -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer ${auth}" "https://${host}${path}" 2>/dev/null || echo "000"
  else
    curl -ks -o /dev/null -w '%{http_code}' --max-time 20 "https://${host}${path}" 2>/dev/null || echo "000"
  fi
}

# The predicate every HTTP assertion goes through now.
route_answers() {  # route path expected-code [authHeader]
  local route="$1" path="$2" want="$3" auth="${4:-}"
  route_host "$route" || return 1
  [[ "$(http_code "$OC_OUT" "$path" "$auth")" == "$want" ]]
}

# The OIDC auth-server-url the entry marker recorded (workshop Keycloak + this user's realm).
# rc 1 = the marker carries no URL, or the API could not be asked.
auth_server_url() {  # → OC_OUT is the URL
  oc_present get cm ws-entry-securing-apps-keycloak -n "$NS" -o jsonpath='{.data.authServerUrl}'
}

# A demo access token for the given realm user (password grant, public client parasol-web). Takes the
# realm URL rather than reading it, so the marker's oc read stays in the caller's shell — this helper is
# necessarily consumed from a `$(…)`, and an inconclusive raised in there would die with the subshell.
realm_token() {  # url username
  local url="$1" user="$2" tok
  tok="$(curl -ks --max-time 20 "${url}/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=parasol-web&username=${user}&password=parasol&scope=openid" 2>/dev/null \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  [[ -n "$tok" ]] && printf '%s' "$tok"
}

# Same predicate as route_answers, but presenting a freshly minted realm token. The marker read that
# yields the realm URL happens HERE, inside the predicate, because check() clears VERIFY_INCONCLUSIVE
# on entry — a flag raised at the call site before the call is already gone by the time it matters.
route_answers_as() {  # route path expected-code realm-user
  local route="$1" path="$2" want="$3" who="$4" url tok
  auth_server_url || return 1
  url="$OC_OUT"
  route_host "$route" || return 1
  tok="$(realm_token "$url" "$who" || true)"
  [[ "$(http_code "$OC_OUT" "$path" "$tok")" == "$want" ]]
}

# Exchange a subject token for a parasol-fraud-audience token via Keycloak standard token exchange
# (RFC 8693), authenticating as the confidential parasol-claims client with the fixed workshop secret the
# lab uses (parasol-claims-secret — not a real credential). Parsed with sed (no jq), so this stays runnable
# with only oc + curl. Empty output ⇒ the exchange was refused (a broken/absent exchange wiring).
exchanged_token() {  # url subject_token
  local url="$1" subj="$2"
  [[ -n "$url" && -n "$subj" ]] || return 1
  curl -ks --max-time 20 "${url}/protocol/openid-connect/token" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_id=parasol-claims -d client_secret=parasol-claims-secret \
    -d subject_token="$subj" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d audience=parasol-fraud 2>/dev/null \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# Entry clean-slate: NO parasol-fraud yet (the optional token-exchange beat hasn't started). Namespace
# must actually exist first — otherwise an empty result is vacuous (true on a cluster where nothing
# materialized at all), not evidence of a clean, correctly-seeded entry state.
# NEGATION IS THE DANGEROUS DIRECTION: `[[ -z "$(oc get … 2>/dev/null)" ]]` certifies a clean slate
# from an API that never answered, and a wrongly-green entry check sends `ws prep` down its "already
# prepared" fast path. oc_absent returns 0 only when the API ANSWERED and nothing is there.
no_fraud_yet() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent get deploy parasol-fraud -n "$NS" -o name
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                         || hint "run: ws start securing-apps-keycloak --user ${USER_NAME}"
check "entry marker ws-entry-securing-apps-keycloak present"               oc get cm ws-entry-securing-apps-keycloak -n "$NS"         || hint "entry app not synced — ws start securing-apps-keycloak --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db "$NS"            || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica" deploy_ready parasol-claims "$NS"       || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "parasol-web deployment has >=1 ready replica"    deploy_ready parasol-web "$NS"          || hint "wait for rollout: oc rollout status deploy/parasol-web -n ${NS}"
check "claims Route answers 200 (/q/health/ready)"      route_answers parasol-claims /q/health/ready 200 || hint "claims app not ready — check: oc get pods -n ${NS}"
check "web Route answers 200 (/q/health/ready)"         route_answers parasol-web /q/health/ready 200    || hint "web app not ready — check: oc get pods -n ${NS}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: apps are UNPROTECTED and the advanced beat has not started -----------------
  check "claims API is OPEN — GET /api/claims is 200 with no token" \
        route_answers parasol-claims /api/claims 200                                            || hint "entry is unprotected; if this is 401 the app is already secured — ws reset securing-apps-keycloak --user ${USER_NAME}"
  check "no parasol-fraud yet (token-exchange beat not started)" no_fraud_yet || hint "entry has no fraud service — ws reset securing-apps-keycloak --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — the API is bearer-protected and role-enforced -------------
  # Assert outcomes (HTTP behaviour), never the mechanism (env vars / annotation), so any correct
  # solution stays green (rule 14).
  check "claims API is PROTECTED — GET /api/claims is 401 with no token" \
        route_answers parasol-claims /api/claims 401                                            || hint "secure the API: enable the OIDC tenant + require claims-adjuster on /api/claims (see the lab)"
  check "a valid claims-adjuster token is accepted — GET /api/claims is 200" \
        route_answers_as parasol-claims /api/claims 200 adjuster                                || hint "role wiring: map realm_access/roles and allow claims-adjuster; token from ${USER_NAME}'s realm (adjuster/parasol)"
  check "web frontend redirects an unauthenticated request to login (302)" \
        route_answers parasol-web /api/claims 302                                               || hint "protect the web app: OIDC web-app (auth-code + PKCE) — see the lab"

  # --- Ex7 [ADVANCED] token exchange (RFC 8693) — the module's ONLY optional exercise, and what `ws solve`
  # materializes. Never let this beat pass silently: if parasol-fraud is deployed, assert the discriminator
  # (the user's aud=parasol-claims token is 401 at fraud; a token EXCHANGED to aud=parasol-fraud is 200). If
  # fraud is absent, print a LOUD skip naming Ex7 — it is optional, so absence is not a core-lab failure, but
  # a grader must SEE it was not done instead of reading a misleading all-green.
  # THREE outcomes, not two. `oc get deploy parasol-fraud >/dev/null 2>&1` fails identically whether
  # the attendee skipped Ex7 and whether the apiserver never answered — and the else arm then STATES,
  # as fact, that they did not deploy it. A grader reading that is being told something nobody checked.
  fraud_rc=0
  oc_read get deploy parasol-fraud -n "$NS" -o name || fraud_rc=$?
  if (( fraud_rc == 0 )) && [[ -n "$OC_OUT" ]]; then
    # Realm URL and subject token minted ONCE, in this shell: the second check exchanges the very token
    # the first one presented, so minting per-check would exchange a token that was never presented.
    XURL=""; XADJ=""; XCHG=""
    if auth_server_url; then
      XURL="$OC_OUT"
      XADJ="$(realm_token "$XURL" adjuster || true)"
      XCHG="$(exchanged_token "$XURL" "$XADJ" || true)"
    fi
    check "Ex7 token-exchange: fraud REFUSES the user's aud=parasol-claims token — 401" \
          route_answers parasol-fraud /api/fraud/score/CLM-1001 401 "$XADJ"                     || hint "fraud must enforce aud=parasol-fraud (QUARKUS_OIDC_TOKEN_AUDIENCE) — see Ex7"
    check "Ex7 token-exchange: fraud ACCEPTS a token exchanged to aud=parasol-fraud — 200" \
          route_answers parasol-fraud /api/fraud/score/CLM-1001 200 "$XCHG"                     || hint "wire RFC 8693 exchange: parasol-claims (confidential) exchanges the user token to audience=parasol-fraud — see Ex7"
  elif (( fraud_rc == 2 )); then
    warn "Ex7 [ADVANCED] token-exchange — the cluster API could not be asked whether parasol-fraud is deployed, so this beat has no verdict"
    hint "not your lab, and not graded: re-run 'ws verify securing-apps-keycloak' in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor"
  else
    warn "Ex7 [ADVANCED] token-exchange — parasol-fraud is not deployed (the module's only optional exercise; deploy the fraud service and wire the RFC 8693 exchange to finish it)"
  fi
fi

verify_summary
