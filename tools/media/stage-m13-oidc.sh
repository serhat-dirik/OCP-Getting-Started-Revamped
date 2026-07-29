#!/usr/bin/env bash
# Put M13's parasol-claims into the state exercise 2 leaves it in — for the capture harness.
#
# WHY THIS IS NEEDED AT ALL. The securing-apps-keycloak entry state ships parasol-claims with
# nothing but POSTGRESQL_HOST: every QUARKUS_OIDC_* variable in that chart sits behind
# `{{- if .Values.solve }}`. So `ws start` followed by a shot of the Environment tab renders one
# unrelated row, while a wait on the word "Environment" — a tab label on the page shell — passes
# instantly. Valid PNG, wrong picture, no error.
#
# WHY NOT `ws solve`. Solve is the END state of the whole module: it also enforces the
# claims-adjuster role policy from exercise 3 and deploys parasol-fraud. The manifest row is
# exercise 2's shot, so this replays exercise 2's own `oc set env` and nothing else.
#
# The realm URL is read from the live Route rather than templated, because `pre_sh` is NOT
# {domain}-substituted by capture.py — only `url` and `url_sh` are. A hardcoded domain here would
# also be a privacy-guard failure in a tracked file.
#
# Usage: tools/media/stage-m13-oidc.sh [user]     (default user1)
set -euo pipefail

USER_N="${1:-user1}"
NS="${USER_N}-dev"

echo "▶ M13 OIDC staging for ${NS}"

SSO_HOST="$(oc get route keycloak -n sso-workshop -o jsonpath='{.spec.host}')"
if [[ -z "${SSO_HOST}" ]]; then
  echo "❌ no keycloak Route in sso-workshop — the workshop Keycloak is not up" >&2
  exit 1
fi
REALM="https://${SSO_HOST}/realms/realm-${USER_N}"
echo "  realm: ${REALM}"

# Exercise 2, verbatim.
oc set env "deployment/parasol-claims" -n "${NS}" \
  QUARKUS_OIDC_TENANT_ENABLED=true \
  "QUARKUS_OIDC_AUTH_SERVER_URL=${REALM}" \
  QUARKUS_OIDC_APPLICATION_TYPE=service \
  'QUARKUS_HTTP_AUTH_PERMISSION_CLAIMS_PATHS=/api/claims,/api/claims/*' \
  QUARKUS_HTTP_AUTH_PERMISSION_CLAIMS_POLICY=authenticated

oc rollout status "deployment/parasol-claims" -n "${NS}" --timeout=300s

echo "✅ the five exercise-2 variables are on the Deployment; the Environment tab now has rows to show"
