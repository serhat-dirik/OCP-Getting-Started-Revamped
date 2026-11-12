#!/usr/bin/env bash
# ogsr-idp-migrate.sh — retire the legacy `workshop-users` HTPasswd IdP on a cluster installed before
# attendees signed in through Keycloak (owner decision 2026-11-12). Called by bootstrap/install.sh after
# the workshop layer is Healthy, i.e. once cluster-idp-users has put user1..N in the Keycloak realm.
#
#   1. removes the `workshop-users` entry from oauth/cluster (test+remove: a concurrent edit cannot
#      shift the index onto another IdP); every other IdP is untouched;
#   2. deletes every `workshop-users:<user>` Identity and drops it from that User's identities, so the
#      attendee's first Keycloak login claims the SAME User (mappingMethod claim refuses a User already
#      mapped to another identity). Users, Group memberships and RoleBindings are by name and survive;
#   3. deletes secret openshift-config/htpasswd-workshop-users.
# Idempotent: a cluster with nothing to migrate prints one line and exits 0.
# Refuses (exit 1, nothing changed) if removing the entry would leave no OpenID IdP — that would lock
# everyone out.
#
# Usage: bootstrap/ogsr-idp-migrate.sh            (current oc context, cluster-admin)
set -euo pipefail

ok()   { echo "✅ $*"; }
err()  { echo "❌ $*" >&2; }
info() { echo "▶ $*"; }

LEGACY="workshop-users"
names="$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\t"}{.type}{"\n"}{end}')"
idx=-1; i=0; openid=0
while IFS=$'\t' read -r n t; do
  [[ -n "$n" ]] || continue
  [[ "$n" == "$LEGACY" && "$idx" -lt 0 ]] && idx="$i"
  [[ "$t" == "OpenID" ]] && openid=$((openid + 1))
  i=$((i + 1))
done <<< "$names"
ids="$(oc get identities -o jsonpath="{range .items[?(@.providerName==\"${LEGACY}\")]}{.metadata.name}{\"\t\"}{.user.name}{\"\n\"}{end}")"

if [[ "$idx" -lt 0 && -z "$ids" ]] && ! oc get secret htpasswd-workshop-users -n openshift-config >/dev/null 2>&1; then
  ok "no legacy '${LEGACY}' sign-in to migrate"
  exit 0
fi

if [[ "$idx" -ge 0 ]]; then
  if [[ "$openid" -lt 1 ]]; then
    err "refusing: removing '${LEGACY}' would leave oauth/cluster without an OpenID (Keycloak) IdP"
    echo "   fix: re-run bootstrap/install.sh — it adds the workshop's own Keycloak IdP on such clusters" >&2
    exit 1
  fi
  oc patch oauth cluster --type=json -p "[{\"op\":\"test\",\"path\":\"/spec/identityProviders/${idx}/name\",\"value\":\"${LEGACY}\"},{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${idx}\"}]" >/dev/null
  ok "oauth/cluster: removed IdP '${LEGACY}' (other IdPs untouched)"
fi

while IFS=$'\t' read -r id u; do
  [[ -n "$id" ]] || continue
  oc delete identity "$id" >/dev/null
  if [[ -n "$u" ]] && oc get user "$u" >/dev/null 2>&1; then
    keep=""
    for x in $(oc get user "$u" -o jsonpath='{.identities[*]}'); do
      [[ "$x" == "$id" ]] || keep="${keep:+${keep},}\"${x}\""
    done
    oc patch user "$u" --type=merge -p "{\"identities\":[${keep}]}" >/dev/null
  fi
  ok "identity ${id} removed; user/${u:-?} kept (next sign-in links it to Keycloak)"
done <<< "$ids"

if oc get secret htpasswd-workshop-users -n openshift-config >/dev/null 2>&1; then
  oc delete secret htpasswd-workshop-users -n openshift-config >/dev/null
  ok "secret openshift-config/htpasswd-workshop-users deleted"
fi
info "oauth-openshift rolls out the new provider list in ~1-2 min (oc get co authentication)"
