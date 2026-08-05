#!/usr/bin/env bash
# Verify developer-hub-golden-paths — Developer Hub & Golden Paths.
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
# EVERY HTTP probe here goes through _lib.sh's http_read, so "the endpoint answered X" and "the
# endpoint could not be asked" are different outcomes — load-bearing for the entry slate, which must
# never certify emptiness it did not actually observe (see the counters below).
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
DEV="${USER_NAME}-dev"
SCAFFOLD_ORG="${USER_NAME}-svcs"

# --- helpers (oc + curl only) ------------------------------------------------

# THE ONE oc READ IN THIS FILE, and every consumer of it used to be a command substitution — so a
# VERIFY_INCONCLUSIVE raised here could never have reached check(). It therefore does NOT echo: it
# leaves the domain in OC_OUT and returns rc 0/1, and its callers do the same, so the whole chain runs
# in the CALLER's own shell. rc 1 = the domain is absent OR the API could not be asked; the flag says
# which, and check() turns the second into ⚠ instead of a ❌ on the attendee's work.
ingress_domain() {
  oc_present get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
}

# Side effect, not stdout — same reason. RHDH_HOST is only ever read straight after a successful call.
RHDH_HOST=""
rhdh_host() {
  ingress_domain || return 1
  RHDH_HOST="backstage-developer-hub-rhdh.${OC_OUT}"
}

# gitea_host() is shared — tools/verify/_lib.sh. GLOBAL, not echo-shaped, same reason as
# ingress_domain()/rhdh_host() above: call it bare and read $GITEA_HOST, never `$(gitea_host)`.

# EVERY HTTP PROBE IN THIS FILE GOES THROUGH http_read, none through `code="$(curl … || true)"`.
# That two-outcome shape prints the identical ❌ for "the portal answered 503" (the platform is
# broken — gradeable, and worth a red line) and for "there is no route from here to this cluster"
# (hotel wifi, a dead RHDP environment — not the attendee's lab and not gradeable at all). http_read
# is oc_read's three outcomes over HTTP: rc 0 answered, rc 1 a real NO, rc 2 could-not-ask with
# VERIFY_INCONCLUSIVE raised so check() prints ⚠. It matters MOST for the counters below, where the
# missing third outcome was being read as a certified clean slate — see F-09 there.

# The shared RHDH portal answers on its route.
rhdh_up() {
  rhdh_host || return 1
  http_read "https://${RHDH_HOST}/" || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# A short-lived guest token for the catalog/scaffolder API (guest sign-in is the workshop default).
#
# GLOBAL, not echo-shaped — the same reason ingress_domain()/rhdh_host()/gitea_host() are global:
# read as `tok="$(rhdh_guest_token)"` the entire body runs in a SUBSHELL, and the
# VERIFY_INCONCLUSIVE that http_read raises when the portal cannot be reached at all dies with that
# subshell. The flag never reaches the caller's check(), so a genuine outage renders as a ❌ on the
# attendee's own work. Call it bare and read $RHDH_TOKEN.
RHDH_TOKEN=""
rhdh_guest_token() {  # → 0 + RHDH_TOKEN set; non-zero otherwise, flag says whether it was askable
  RHDH_TOKEN=""
  rhdh_host || return 1
  http_read "https://${RHDH_HOST}/api/auth/guest/refresh" || return 1
  [[ "$HTTP_CODE" == "200" ]] || return 1
  RHDH_TOKEN="$(printf '%s' "$HTTP_OUT" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
print((d.get("backstageIdentity") or {}).get("token","") if isinstance(d,dict) else "")')" || return 1
  [[ -n "$RHDH_TOKEN" ]]
}

# The Parasol catalog is populated: the catalog API returns the parasol-claims Component.
catalog_has_parasol() {
  rhdh_guest_token || return 1
  http_read "https://${RHDH_HOST}/api/catalog/entities/by-name/component/default/parasol-claims" \
    -H "Authorization: Bearer ${RHDH_TOKEN}" || return 1
  [[ "$HTTP_CODE" == "200" ]] || return 1
  printf '%s' "$HTTP_OUT" | grep -q '"name":"parasol-claims"'
}

# The golden-path Software Template is registered (catalog holds the Template entity).
template_registered() {
  rhdh_guest_token || return 1
  http_read "https://${RHDH_HOST}/api/catalog/entities/by-name/template/default/parasol-service-template" \
    -H "Authorization: Bearer ${RHDH_TOKEN}" || return 1
  [[ "$HTTP_CODE" == "200" ]] || return 1
  printf '%s' "$HTTP_OUT" | grep -q '"name":"parasol-service-template"'
}

# The attendee's dedicated scaffold org exists (the golden-path publish target).
scaffold_org_exists() {
  gitea_host || return 1
  http_read "https://${GITEA_HOST}/api/v1/orgs/${SCAFFOLD_ORG}" || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# ── the scaffold-slate counters: three outcomes, because "0" was two facts wearing one hat ────────
#
# F-09 (false-pass audit, 2026-08-05). Both counters used to `echo 0` on EVERY failure path —
# gitea_host unresolvable, a curl transport error, a body that is not JSON at all, an HTTP 500
# carrying a JSON error object — and scaffold_slate_clean read `0 && 0` as "the org is empty AND no
# orphan catalog Location points at it". A clean slate certified BY SILENCE.
#
# THAT IS THE EXPENSIVE DIRECTION, because it is the ENTRY side. `ws prep` reads
# `<script> --entry-only`'s rc as the boolean "is this world already prepared?" (tools/ws/ws
# cmd_prep), so a wrongly-green slate takes the "already prepared — nothing to do" fast path, the
# cleanup hook never runs, and the next attendee inherits the previous run's scaffold repo AND its
# orphan catalog Location on the SHARED portal — which is precisely the G3 multi-tenancy loop these
# two checks were written to close, reopened by the way they fail. Same defect, same direction, as
# config-multienv's obj_absent and serverless-zero-to-hero's single_revision fix comments.
#
# THE TWO GUARDS IN FRONT DID NOT CLOSE IT AND COULD NOT. scaffold_org_exists proves the ORG
# endpoint answers, not the REPOS endpoint; rhdh_up proves `/` answers, not /api/catalog/locations.
# A portal that serves its landing page and 500s on the catalog API passes both, every time. So the
# fix is not a third guard — it is each counter GRADING ITS OWN ENDPOINT'S ANSWER.
#
# GLOBAL, not echo-shaped, for the same reason as rhdh_guest_token above: a command substitution
# runs the body in a subshell where http_read's VERIFY_INCONCLUSIVE cannot survive. Contract:
#   rc 0 → the endpoint answered and the answer was COUNTABLE; the count is in the global.
#   rc 1 → the endpoint answered something that is not a count (non-200, or a 200 whose body is not
#          a JSON array). A real ❌ — Gitea or RHDH answering wrongly IS broken, and saying so is
#          the point; it is emphatically not "the org is empty".
#   rc 2 → could not be asked at all. http_read has already raised VERIFY_INCONCLUSIVE, so check()
#          prints ⚠ "could not check" and the call site's hint never fires. Never a clean slate.
SCAFFOLD_REPO_COUNT=""
scaffold_repos_read() {  # repos in the {user}-svcs scaffold org (public repos list anonymously)
  SCAFFOLD_REPO_COUNT=""
  local rc=0
  gitea_host || return 1
  http_read "https://${GITEA_HOST}/api/v1/orgs/${SCAFFOLD_ORG}/repos?limit=50" || rc=$?
  if (( rc != 0 )); then return "$rc"; fi
  if [[ "$HTTP_CODE" != "200" ]]; then return 1; fi
  # sys.exit(1) on a body that is not a JSON list, where the old code printed 0: "Gitea handed me an
  # error object" and "the org holds no repos" are different facts and only one of them is a slate.
  SCAFFOLD_REPO_COUNT="$(printf '%s' "$HTTP_OUT" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
if not isinstance(d,list): sys.exit(1)
print(len(d))')" || { SCAFFOLD_REPO_COUNT=""; return 1; }
  [[ -n "$SCAFFOLD_REPO_COUNT" ]]
}

# Catalog Locations registered against this user's scaffold org. The golden-path scaffolder's
# catalog:register step creates one per scaffolded service; the entry cleanup hook deregisters them, so
# a clean entry slate has ZERO. Guarding the loop the G3 smoke found: after ws reset/prep, no orphan
# {user}-svcs Location should linger on the SHARED portal (the entity name is per-user, e.g.
# parasol-policy-{user}, so its Location target is …/{user}-svcs/<svc>/…).
USER_CATALOG_LOCATION_COUNT=""
user_catalog_locations_read() {
  USER_CATALOG_LOCATION_COUNT=""
  local rc=0
  rhdh_guest_token || return 1
  http_read "https://${RHDH_HOST}/api/catalog/locations" \
    -H "Authorization: Bearer ${RHDH_TOKEN}" || rc=$?
  if (( rc != 0 )); then return "$rc"; fi
  if [[ "$HTTP_CODE" != "200" ]]; then return 1; fi
  USER_CATALOG_LOCATION_COUNT="$(printf '%s' "$HTTP_OUT" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
if not isinstance(d,list): sys.exit(1)
org=sys.argv[1]
print(sum(1 for e in d if isinstance(e,dict) and ("/"+org+"/") in ((e.get("data",e) or {}).get("target") or "")))' "$SCAFFOLD_ORG")" || { USER_CATALOG_LOCATION_COUNT=""; return 1; }
  [[ -n "$USER_CATALOG_LOCATION_COUNT" ]]
}

# A clean scaffold slate = the Gitea org is empty AND no orphan catalog Location points at it. Both are
# what the entry cleanup hook guarantees; asserting both closes the multi-tenancy loop (G3 FAIL).
# EVERY LEG MUST HAVE BEEN ANSWERED. `return 1` rather than propagating rc 2 is deliberate and costs
# nothing: check() classifies on the FLAG, not on the rc, so an unaskable endpoint still renders ⚠
# — what must never happen is the leg being skipped and its silence counted as emptiness.
scaffold_slate_clean() {
  scaffold_org_exists || return 1
  rhdh_up || return 1
  scaffold_repos_read || return 1
  [[ "$SCAFFOLD_REPO_COUNT" -eq 0 ]] || return 1
  user_catalog_locations_read || return 1
  [[ "$USER_CATALOG_LOCATION_COUNT" -eq 0 ]]
}

# THE EXACT NEGATION of scaffold_slate_clean's repo leg — `>= 1` against its `== 0`, off the same
# reader, so the two modes cannot disagree about the same world. `ws prep` reads the entry rc as "is
# this world prepared?" and `ws verify` reads the full rc as "is it complete"; a predicate pair that
# is not a mirror lets one world answer YES to both, which is how a completed lab gets offered as a
# clean slate. The orphan-Location leg is an ADDITIONAL entry requirement, not a second reading of
# the same fact: a world with zero repos and a stale Location is neither prepared (entry ❌ — the
# cleanup hook still has work to do) nor complete (end ❌ — nothing was scaffolded). No world is both.
scaffold_repo_present() {
  scaffold_repos_read || return 1
  [[ "$SCAFFOLD_REPO_COUNT" -ge 1 ]]
}

# --- entry state (what `ws start developer-hub-golden-paths` materializes) --------------------------
check "namespace ${DEV} exists"                          oc get ns "$DEV"                          || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-developer-hub-golden-paths in ${DEV}"              oc get cm ws-entry-developer-hub-golden-paths -n "$DEV"          || hint "entry app not synced — ws start developer-hub-golden-paths --user ${USER_NAME}"
check "shared RHDH portal is reachable"                  rhdh_up                                   || hint "portal stack down — sync pp-portal (platform-portfolio/stacks/portal)"
check "Parasol catalog populated (parasol-claims)"       catalog_has_parasol                       || hint "catalog not wired — check app-config-rhdh catalog.locations + Gitea seeding (ws git-refresh)"
check "golden-path template registered"                  template_registered                       || hint "template not registered — check the parasol-service-template location in app-config-rhdh"
check "scaffold org ${SCAFFOLD_ORG} exists"              scaffold_org_exists                       || hint "org hook didn't run — ws reset developer-hub-golden-paths --user ${USER_NAME} (or check gitea-scaffold-org-developer-hub-golden-paths-${USER_NAME} Job in ns gitea)"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove the scaffold slate is clean (running the template is the lab). "Clean" =
  # empty Gitea org AND no orphan catalog Location on the shared portal (the G3 multi-tenancy fix).
  # "Clean" is asserted from two answers, never from two silences: a leg that could not be asked
  # renders ⚠ (check() reads VERIFY_INCONCLUSIVE) and this hint does not fire at all.
  check "clean scaffold slate (${SCAFFOLD_ORG} empty, no orphan catalog entry)"   scaffold_slate_clean   || hint "not a clean slate — either a prior run left something behind (a repo in ${SCAFFOLD_ORG} or an orphan catalog Location: ws reset developer-hub-golden-paths --user ${USER_NAME}), or Gitea/RHDH answered with something that is not a list (a non-200 from /api/v1/orgs/${SCAFFOLD_ORG}/repos or from /api/catalog/locations is a broken platform, not your lab — tell your instructor). A slate is only called clean when BOTH endpoints actually answered"
else
  # --- end state (what a completed lab / solve looks like) -------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  # The hint no longer states "${SCAFFOLD_ORG} is empty" as a fact: since scaffold_repos_read grades
  # Gitea's own answer, this ❌ now covers "answered, and the org holds nothing" AND "answered with
  # something that is not a repo list", and asserting the first when it was the second is the same
  # false-confidence bug one layer up (cf. check()'s "could not check:" prefix rationale in _lib.sh).
  check "${USER_NAME} scaffolded >=1 golden-path service" scaffold_repo_present                    || hint "not done yet — running the 'New Parasol microservice' template in RHDH IS the lab, so an empty ${SCAFFOLD_ORG} is the expected state before you start, not a broken portal (ws solve developer-hub-golden-paths materializes ${SCAFFOLD_ORG}/parasol-golden). If instead Gitea answered /api/v1/orgs/${SCAFFOLD_ORG}/repos with a non-200 or with something that is not a repo list, that IS broken — tell your instructor"
fi

verify_summary
