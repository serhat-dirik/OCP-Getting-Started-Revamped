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

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# HTTP status of an app Route path (edge TLS → curl https; -k because the edge cert is the cluster's).
route_code() {  # route path [authHeader]
  local route="$1" path="$2" auth="${3:-}" host
  host="$(oc get route "$route" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || { echo "000"; return; }
  if [[ -n "$auth" ]]; then
    curl -ks -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer ${auth}" "https://${host}${path}" 2>/dev/null || echo "000"
  else
    curl -ks -o /dev/null -w '%{http_code}' --max-time 20 "https://${host}${path}" 2>/dev/null || echo "000"
  fi
}

# The OIDC auth-server-url the entry marker recorded (workshop Keycloak + this user's realm).
auth_server_url() {
  oc get cm ws-entry-securing-apps-keycloak -n "$NS" -o jsonpath='{.data.authServerUrl}' 2>/dev/null || true
}

# A demo access token for the given realm user (password grant, public client parasol-web). Uses the
# realm URL from the marker, so no cluster-domain read is needed.
realm_token() {  # username
  local user="$1" url tok
  url="$(auth_server_url)"
  [[ -n "$url" ]] || return 1
  tok="$(curl -ks --max-time 20 "${url}/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=parasol-web&username=${user}&password=parasol&scope=openid" 2>/dev/null \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  [[ -n "$tok" ]] && printf '%s' "$tok"
}

# Exchange a subject token for a parasol-fraud-audience token via Keycloak standard token exchange
# (RFC 8693), authenticating as the confidential parasol-claims client with the fixed workshop secret the
# lab uses (parasol-claims-secret — not a real credential). Parsed with sed (no jq), so this stays runnable
# with only oc + curl. Empty output ⇒ the exchange was refused (a broken/absent exchange wiring).
exchanged_token() {  # subject_token
  local subj="$1" url
  url="$(auth_server_url)"
  [[ -n "$url" && -n "$subj" ]] || return 1
  curl -ks --max-time 20 "${url}/protocol/openid-connect/token" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_id=parasol-claims -d client_secret=parasol-claims-secret \
    -d subject_token="$subj" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d audience=parasol-fraud 2>/dev/null \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                         || hint "run: ws start securing-apps-keycloak --user ${USER_NAME}"
check "entry marker ws-entry-securing-apps-keycloak present"               oc get cm ws-entry-securing-apps-keycloak -n "$NS"         || hint "entry app not synced — ws start securing-apps-keycloak --user ${USER_NAME}"
check "claims-db deployment has >=1 ready replica"      deploy_ready claims-db "$NS"            || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "parasol-claims deployment has >=1 ready replica" deploy_ready parasol-claims "$NS"       || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}"
check "parasol-web deployment has >=1 ready replica"    deploy_ready parasol-web "$NS"          || hint "wait for rollout: oc rollout status deploy/parasol-web -n ${NS}"
check "claims Route answers 200 (/q/health/ready)"      test "$(route_code parasol-claims /q/health/ready)" = "200" || hint "claims app not ready — check: oc get pods -n ${NS}"
check "web Route answers 200 (/q/health/ready)"         test "$(route_code parasol-web /q/health/ready)" = "200"    || hint "web app not ready — check: oc get pods -n ${NS}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: apps are UNPROTECTED and the advanced beat has not started -----------------
  check "claims API is OPEN — GET /api/claims is 200 with no token" \
        test "$(route_code parasol-claims /api/claims)" = "200"                                 || hint "entry is unprotected; if this is 401 the app is already secured — ws reset securing-apps-keycloak --user ${USER_NAME}"
  check "no parasol-fraud yet (token-exchange beat not started)" \
        test -z "$(oc get deploy parasol-fraud -n "$NS" -o name 2>/dev/null)"                   || hint "entry has no fraud service — ws reset securing-apps-keycloak --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOME — the API is bearer-protected and role-enforced -------------
  # Assert outcomes (HTTP behaviour), never the mechanism (env vars / annotation), so any correct
  # solution stays green (rule 14).
  check "claims API is PROTECTED — GET /api/claims is 401 with no token" \
        test "$(route_code parasol-claims /api/claims)" = "401"                                 || hint "secure the API: enable the OIDC tenant + require claims-adjuster on /api/claims (see the lab)"
  ADJ_TOKEN="$(realm_token adjuster || true)"
  check "a valid claims-adjuster token is accepted — GET /api/claims is 200" \
        test "$(route_code parasol-claims /api/claims "$ADJ_TOKEN")" = "200"                    || hint "role wiring: map realm_access/roles and allow claims-adjuster; token from ${USER_NAME}'s realm (adjuster/parasol)"
  check "web frontend redirects an unauthenticated request to login (302)" \
        test "$(route_code parasol-web /api/claims)" = "302"                                    || hint "protect the web app: OIDC web-app (auth-code + PKCE) — see the lab"

  # --- Ex7 [ADVANCED] token exchange (RFC 8693) — the module's ONLY optional exercise, and what `ws solve`
  # materializes. Never let this beat pass silently: if parasol-fraud is deployed, assert the discriminator
  # (the user's aud=parasol-claims token is 401 at fraud; a token EXCHANGED to aud=parasol-fraud is 200). If
  # fraud is absent, print a LOUD skip naming Ex7 — it is optional, so absence is not a core-lab failure, but
  # a grader must SEE it was not done instead of reading a misleading all-green.
  if oc get deploy parasol-fraud -n "$NS" >/dev/null 2>&1; then
    XADJ="$(realm_token adjuster || true)"
    check "Ex7 token-exchange: fraud REFUSES the user's aud=parasol-claims token — 401" \
          test "$(route_code parasol-fraud /api/fraud/score/CLM-1001 "$XADJ")" = "401"          || hint "fraud must enforce aud=parasol-fraud (QUARKUS_OIDC_TOKEN_AUDIENCE) — see Ex7"
    XCHG="$(exchanged_token "$XADJ" || true)"
    check "Ex7 token-exchange: fraud ACCEPTS a token exchanged to aud=parasol-fraud — 200" \
          test "$(route_code parasol-fraud /api/fraud/score/CLM-1001 "$XCHG")" = "200"          || hint "wire RFC 8693 exchange: parasol-claims (confidential) exchanges the user token to audience=parasol-fraud — see Ex7"
  else
    echo "⏭  SKIP Ex7 [ADVANCED] token-exchange — parasol-fraud is not deployed (the module's only optional"
    echo "    exercise; this is NOT a pass — deploy the fraud service and wire the RFC 8693 exchange to finish it)."
  fi
fi

verify_summary
