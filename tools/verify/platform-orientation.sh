#!/usr/bin/env bash
# Verify platform-orientation — Platform Orientation & First App.
#   Entry: {user}-dev exists · entry marker CM · workshop quota · Gitea account answers ·
#          clean slate (no leftover parasol-web) so `ws prep` re-wipes on a re-run.
#   End:   parasol-web Deployment ready · Route answers HTTP 200 on / .
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea account exists → API returns 2xx. Host is discovered from the cluster so
# the script stays environment-agnostic (no hardcoded URLs). Instructors/CI read the
# route directly; an attendee (userN) cannot read routes in the gitea namespace, so
# we fall back to the conventional host derived from the cluster ingress domain
# (route "gitea" in namespace "ogsr-gitea" → gitea-ogsr-gitea.<domain>), which every
# authenticated user can resolve.
#
# CONVERTED via oc_read_optional (_lib.sh) — the route-then-domain fallback the guard excludes by name
# inside gitea_host(), inlined here under a different name. Mirrors tools/verify/gitops-at-scale.sh's
# read_gitea_host(). The route read is EXPECTED to be refused for an attendee (rule 10 — routes in
# ogsr-gitea are not theirs to read), so its rc 2 must NOT become this check's verdict once the domain
# fallback yields a host — oc_read_optional saves/restores VERIFY_INCONCLUSIVE around that call so a
# refusal check() would otherwise turn into ⚠ never reaches it. The domain fallback itself goes through
# plain oc_read: it is the LAST resort, so if it also cannot be asked, "could not determine the host" is
# genuinely inconclusive and must raise the flag — that is what keeps a real cluster outage a ⚠ instead
# of a false ❌ on a genuinely missing Gitea account.
gitea_user_exists() {
  local user="$1" host="" domain
  if oc_read_optional get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' && [[ -n "$OC_OUT" ]]; then
    host="$OC_OUT"
  fi
  if [[ -z "$host" ]]; then
    oc_read get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' || return 1
    domain="$OC_OUT"
    [[ -n "$domain" ]] && host="gitea-ogsr-gitea.${domain}"
  fi
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/users/${user}"
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# Route resolves and answers HTTP 200 on / (the app's landing page).
# Asserts what the lab actually teaches: an EDGE-terminated Route, reachable over HTTPS.
#
# This used to curl `http://` only, which a plain `oc expose` Route serves perfectly well — so the
# one check guarding the edge-Route rule passed just as readily on the broken shape as the correct
# one. It could not tell them apart, which made it a green tick that inspected the wrong thing.
#
# The rule it guards: a browser-facing Route must be `oc create route edge … --insecure-policy=Allow`.
# A plain HTTP Route gets HSTS-upgraded by the browser and the router answers "Application is not
# available"; edge with Redirect instead of Allow gives an empty 302 on `curl http`. So both the
# termination AND the https response are asserted here, not one standing in for the other.
#
# Both Route reads go through oc_present in THIS shell: a Route the API could not be asked about is
# not an un-exposed app, and telling an attendee to re-create a Route they already created correctly
# is exactly the false ❌ this suite exists to avoid.
route_answers_200() {
  local ns="$1" host code
  oc_present get route parasol-web -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  oc_present get route parasol-web -n "$ns" -o jsonpath='{.spec.tls.termination}' || return 1
  [[ "$OC_OUT" == "edge" ]] || return 1
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}/" || true)"
  [[ "$code" == "200" ]]
}

# The entry clean slate, asked three-outcome. Was a `bash -c "oc get ns … >/dev/null 2>&1 && ! oc get
# deploy … >/dev/null 2>&1"` — a SUBPROCESS, so even a converted read's VERIFY_INCONCLUSIVE could
# never have reached check(). And the negation is the dangerous direction: `! oc get deploy` certifies
# a clean slate from an API that never answered, which sends `ws prep` down its "already prepared"
# fast path against a world nobody verified. oc_absent returns 0 only when the API ANSWERED.
clean_slate_no_parasol_web() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent get deploy parasol-web -n "$NS" -o name
}

# --- entry state (what `ws start platform-orientation` materializes) --------------------------
check "namespace ${NS} exists"                 oc get ns "$NS"                      || hint "run: ws start platform-orientation --user ${USER_NAME}"
check "entry marker ws-entry-platform-orientation present"       oc get cm ws-entry-platform-orientation -n "$NS"      || hint "entry app not synced — ws start platform-orientation --user ${USER_NAME}"
check "workshop quota present in ${NS}"         oc get resourcequota workshop-quota -n "$NS" || hint "workshop layer not applied — run bootstrap/install.sh"
check "Gitea account ${USER_NAME} answers (API 200)" gitea_user_exists "$USER_NAME" || hint "Gitea seeding incomplete — check the workshop layer / ws git-refresh"

# platform-orientation's entry state is an EMPTY {user}-dev "ready to receive a first deployment". A leftover
# parasol-web means a previous run was not reset; assert the clean slate at ENTRY so `ws prep`
# detects the dirty namespace (its "already prepared" gate keys off this entry check passing)
# instead of letting the lab's `oc new-app parasol-web` collide with "already exists".
# Entry-only: at END, parasol-web SHOULD exist, so this must not run in completion mode.
if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Namespace must exist first — otherwise "not deployed" is vacuous (true on a cluster where
  # nothing materialized at all), not evidence of a clean, correctly-prepared entry state.
  check "clean slate: parasol-web not yet deployed" clean_slate_no_parasol_web \
    || hint "leftover from a previous run — reset with: ws prep platform-orientation --yes"
fi

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab looks like) ---------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "parasol-web deployment exists"         oc get deploy parasol-web -n "$NS"   || hint "not done yet — you deploy the image in lab exercise 2 (oc new-app --image=…/parasol-web:1.0 --name=parasol-web), so a red here before then is the expected state and not a broken environment"
  check "parasol-web has >=1 ready replica"     deploy_ready parasol-web "$NS"       || hint "not done yet? if the Deployment above is also red, this one follows from it and is equally expected. If it EXISTS but has no ready replica, that one is real: oc rollout status deploy/parasol-web -n ${NS}; oc get pods -n ${NS}"
  check "route parasol-web is edge-terminated and answers 200 over https" route_answers_200 "$NS" || hint "not done yet? publishing the app is exercise 4, so this is expected red before then. Publish it the way that exercise teaches — oc create route edge parasol-web --service=parasol-web --port=8080 --insecure-policy=Allow. NOT 'oc expose': a plain HTTP Route gets HSTS-upgraded and the router answers 'Application is not available'. If a plain Route already exists, delete it first."
fi

verify_summary
