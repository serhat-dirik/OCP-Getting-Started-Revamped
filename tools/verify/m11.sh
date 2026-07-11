#!/usr/bin/env bash
# Verify M11 — Developer Hub & Golden Paths.
#   Entry: {user}-dev + entry marker · the SHARED RHDH portal is reachable · the Parasol software
#          catalog is populated (parasol-claims Component present) · the golden-path Software Template
#          is registered · and a CLEAN scaffold slate — the {user}-svcs scaffold org holds NO
#          golden-path-scaffolded repos AND no orphan catalog Location points at it yet (running the
#          template is the lab; the entry hook empties the org AND deregisters its catalog entry).
#   End:   the SHARED portal + catalog + template are still there AND the {user} Gitea namespace holds
#          >= 1 golden-path-scaffolded repo (the attendee ran the template; ws solve materializes
#          {user}/parasol-golden). End checks are outcome-based and pass for BOTH the attendee's own
#          result AND ws solve's demo repo (>=, not ==, per verify rule 14 — the attendee may scaffold
#          more than one service).
# Shared-platform checks (portal/catalog/template) are identical for every user — they assert the
# pp-portal stack is serving. Runnable with only oc + curl (Showroom terminal reality); RHDH/Gitea
# hosts are derived from the ingress domain (no cross-namespace route reads — verify rule 10).
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
DEV="${USER_NAME}-dev"
SCAFFOLD_ORG="${USER_NAME}-svcs"

# --- helpers (oc + curl only) ------------------------------------------------

ingress_domain() {
  oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true
}

rhdh_host() {
  local d; d="$(ingress_domain)"
  [[ -n "$d" ]] && echo "backstage-developer-hub-rhdh.${d}"
}

gitea_host() {
  local host domain
  host="$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(ingress_domain)"
    [[ -n "$domain" ]] && host="gitea-gitea.${domain}"
  fi
  echo "$host"
}

# The shared RHDH portal answers on its route.
rhdh_up() {
  local h code; h="$(rhdh_host)"
  [[ -n "$h" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "https://${h}/" || true)"
  [[ "$code" == "200" ]]
}

# A short-lived guest token for the catalog/scaffolder API (guest sign-in is the workshop default).
rhdh_guest_token() {
  local h; h="$(rhdh_host)"
  [[ -n "$h" ]] || return 1
  curl -ks --max-time 15 "https://${h}/api/auth/guest/refresh" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("backstageIdentity",{}).get("token",""))' 2>/dev/null
}

# The Parasol catalog is populated: the catalog API returns the parasol-claims Component.
catalog_has_parasol() {
  local h tok; h="$(rhdh_host)"; tok="$(rhdh_guest_token)"
  [[ -n "$h" && -n "$tok" ]] || return 1
  curl -ks --max-time 15 -H "Authorization: Bearer ${tok}" \
    "https://${h}/api/catalog/entities/by-name/component/default/parasol-claims" 2>/dev/null \
    | grep -q '"name":"parasol-claims"'
}

# The golden-path Software Template is registered (catalog holds the Template entity).
template_registered() {
  local h tok; h="$(rhdh_host)"; tok="$(rhdh_guest_token)"
  [[ -n "$h" && -n "$tok" ]] || return 1
  curl -ks --max-time 15 -H "Authorization: Bearer ${tok}" \
    "https://${h}/api/catalog/entities/by-name/template/default/parasol-service-template" 2>/dev/null \
    | grep -q '"name":"parasol-service-template"'
}

# The attendee's dedicated scaffold org exists (the golden-path publish target).
scaffold_org_exists() {
  local h; h="$(gitea_host)"
  [[ -n "$h" ]] || return 1
  curl -ksf -o /dev/null --max-time 15 "https://${h}/api/v1/orgs/${SCAFFOLD_ORG}"
}

# Count repos in the {user}-svcs scaffold org (dedicated to golden-path scaffolds; public repos list
# anonymously — attendee-safe).
scaffold_repo_count() {
  local h; h="$(gitea_host)"
  [[ -n "$h" ]] || { echo 0; return; }
  curl -ks --max-time 15 "https://${h}/api/v1/orgs/${SCAFFOLD_ORG}/repos?limit=50" 2>/dev/null \
    | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d=[]
print(len(d) if isinstance(d,list) else 0)' 2>/dev/null || echo 0
}

# Count catalog Locations registered against this user's scaffold org. The golden-path scaffolder's
# catalog:register step creates one per scaffolded service; the entry cleanup hook deregisters them, so
# a clean entry slate has ZERO. Guarding the loop the G3 smoke found: after ws reset/prep, no orphan
# {user}-svcs Location should linger on the SHARED portal (the entity name is per-user, e.g.
# parasol-policy-{user}, so its Location target is …/{user}-svcs/<svc>/…). RHDH unreachable → 0 (the
# "portal reachable" check above already fails in that case; don't double-count the outage here).
user_catalog_location_count() {
  local h tok; h="$(rhdh_host)"; tok="$(rhdh_guest_token)"
  [[ -n "$h" && -n "$tok" ]] || { echo 0; return; }
  curl -ks --max-time 15 -H "Authorization: Bearer ${tok}" "https://${h}/api/catalog/locations" 2>/dev/null \
    | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d=[]
org=sys.argv[1]
print(sum(1 for e in d if isinstance(e,dict) and ("/"+org+"/") in ((e.get("data",e) or {}).get("target") or "")))' "$SCAFFOLD_ORG" 2>/dev/null || echo 0
}

# A clean scaffold slate = the Gitea org is empty AND no orphan catalog Location points at it. Both are
# what the entry cleanup hook guarantees; asserting both closes the multi-tenancy loop (G3 FAIL).
scaffold_slate_clean() { [[ "$(scaffold_repo_count)" == "0" && "$(user_catalog_location_count)" -eq 0 ]]; }
scaffold_repo_present() { [[ "$(scaffold_repo_count)" -ge 1 ]]; }

# --- entry state (what `ws start m11` materializes) --------------------------
check "namespace ${DEV} exists"                          oc get ns "$DEV"                          || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-m11 in ${DEV}"              oc get cm ws-entry-m11 -n "$DEV"          || hint "entry app not synced — ws start m11 --user ${USER_NAME}"
check "shared RHDH portal is reachable"                  rhdh_up                                   || hint "portal stack down — sync pp-portal (platform-portfolio/stacks/portal)"
check "Parasol catalog populated (parasol-claims)"       catalog_has_parasol                       || hint "catalog not wired — check app-config-rhdh catalog.locations + Gitea seeding (ws git-refresh)"
check "golden-path template registered"                  template_registered                       || hint "template not registered — check the parasol-service-template location in app-config-rhdh"
check "scaffold org ${SCAFFOLD_ORG} exists"              scaffold_org_exists                       || hint "org hook didn't run — ws reset m11 --user ${USER_NAME} (or check gitea-scaffold-org-m11-${USER_NAME} Job in ns gitea)"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove the scaffold slate is clean (running the template is the lab). "Clean" =
  # empty Gitea org AND no orphan catalog Location on the shared portal (the G3 multi-tenancy fix).
  check "clean scaffold slate (${SCAFFOLD_ORG} empty, no orphan catalog entry)"   scaffold_slate_clean   || hint "prior scaffold left over (Gitea repo or catalog Location) — ws reset m11 --user ${USER_NAME} for a clean entry"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  check "${USER_NAME} scaffolded >=1 golden-path service" scaffold_repo_present                    || hint "run the 'New Parasol microservice' template in RHDH; ws solve m11 materializes ${SCAFFOLD_ORG}/parasol-golden"
fi

verify_summary
