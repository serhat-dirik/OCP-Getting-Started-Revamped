#!/usr/bin/env bash
# ogsr-wipe-users.sh — clear the cohort, keep a sample. Hand a cluster over; do not uninstall it.
#
# The workshop is no longer something you uninstall; it is something you hand over and re-run. This
# script removes the ATTENDEES and everything they own — namespaces, cluster identities, Gitea
# accounts and repositories, Keycloak realms — while LEAVING every installed component, the shared
# ogsr-* layer, Gitea itself, all cockpits and Keycloak exactly where they are.
#
# user1 SURVIVES ENTIRELY, login included (--keep N keeps user1..userN). Whoever inherits the cluster
# inherits a WORKING SAMPLE they can log into and click through — not an inspectable corpse.
#
#   ./bootstrap/ogsr-wipe-users.sh --dry-run   # print the WIPE/PRESERVE plan; change nothing
#   ./bootstrap/ogsr-wipe-users.sh             # interactive confirm, then wipe
#   ./bootstrap/ogsr-wipe-users.sh --yes       # no prompt (CI / scripted)
#   ./bootstrap/ogsr-wipe-users.sh --keep 2    # keep user1 AND user2 (default 1)
#
# ── WHY THIS DOES NOT JUST `oc delete ns` ────────────────────────────────────────────────────────
# The workshop layer (Argo Application workshop-config) syncs with prune: true, selfHeal: true and
# renders EVERY per-user object from .Values.userCount. Hand-delete a per-user namespace and Argo
# recreates it within seconds — and the deletion is not merely undone, it is undone SILENTLY: minutes
# later the namespace list looks correct again, for entirely the wrong reason.
#
# So the cohort is removed by LOWERING userCount and letting Argo prune — GitOps doing the work rather
# than being fought. userCount is a SCALAR, which is the only kind of value an Argo helm.parameters
# override applies reliably (list literals do not; those belong in values.yaml). Lowering it
# un-renders the per-user namespaces, the workshop-attendees group entries, the cockpits, the Kueue
# ClusterQueues, the student AppProjects and Argo RBAC, and the KeycloakRealmImport CRs — and Argo's
# own prune removes them in reverse sync-wave order. No chart CONTENT changes, so there is no stale
# manifest render to bust and no chart version to bump.
#
# That whole mechanism — purge the users' worlds in the SEV1-safe order, patch userCount, hard
# refresh, sync (never while an operation is Running), wait Healthy, regenerate htpasswd — is ALREADY
# IMPLEMENTED, correctly, as `ws scale-users` (tools/ws/ws, cmd_scale_users). This script DELEGATES to
# it rather than growing a second copy that can drift; the Argo sync discipline in particular lives in
# ws's sync_app_operation and is not re-implemented here.
#
# What this script adds is everything Argo CANNOT prune because it never created it — the state that
# lives outside Kubernetes objects or outside the chart, which `ws scale-users` itself declares it
# does not remove:
#
#   • OpenShift User + Identity objects. Created lazily by the OAuth server on first login and owned
#     by nobody. Removing an htpasswd line stops a NEW login; it does not remove the User/Identity
#     pair, and a User object with no identity behind it is exactly the corpse this policy rejects.
#   • Gitea accounts and their repositories. gitea-user-seed only ever ADDS accounts (create-if-absent
#     hook), so the account and every fork under it outlive any userCount change.
#   • The attendee's {user}-svcs scaffold ORG (developer-hub-golden-paths). A Gitea org is a separate
#     owner from the user, so deleting the user — even with purge — does not take it.
#   • SonarQube accounts. sonarqube-user-seed is create-if-absent, exactly like the Gitea one, and a
#     SonarQube account is `local: true` — it authenticates against SonarQube's own user table and
#     needs no OpenShift identity, no htpasswd line and no Gitea account behind it. Left in place it
#     is the ONE working login a wiped attendee keeps.
#   • Keycloak realms. KeycloakRealmImport is IMPORT-ONCE: the operator imports the realm and then
#     ignores the CR forever. Pruning the CR does not delete the realm from Keycloak's database.
#   • The per-user LOCAL Argo account password in the student-gitops argocd-secret
#     (accounts.<user>.password), written by the student-argo-accounts hook, which also only ADDS.
#
# ── WHAT IS NEVER TOUCHED ────────────────────────────────────────────────────────────────────────
# Nothing credential-related belonging to the ADMIN. The MaaS key, the shared workshop password
# secret, the Gitea admin credential, the Keycloak admin credential and the cluster's own identity
# providers were supplied BY the admin through install.sh — they are the admin's own, and this script
# neither removes, rotates, nor prints them. Neither are any operators, stacks, shared ogsr-*
# namespaces, BuildConfigs, images, nor the workshop-config Application itself.
#
# Idempotent: safe to re-run. Already-absent objects are skipped with a printed reason, and a second
# run over an already-wiped cohort is a no-op that exits 0.
#
# NOT the same thing as, and deliberately not a variant of:
#   ws reset <module> --user U   — ONE module for ONE attendee (attendee-facing: `ws prep`)
#   bootstrap/ogsr-reset.sh      — keeps the WHOLE cohort, clears what the labs created
#   bootstrap/ogsr-uninstall.sh  — removes the workshop from the cluster entirely
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WS_BIN="${REPO_ROOT}/tools/ws/adm"   # SA verb (cohort-reset/scale-users): the operator entry point, not the attendee one

DRY_RUN="false"
ASSUME_YES="false"
KEEP=1

# shellcheck source=bootstrap/ogsr-cohort-lib.sh
source "${SCRIPT_DIR}/ogsr-cohort-lib.sh"

usage() {
  # 2,70 = the header comment block minus the shebang (ws's own --help does the same).
  # Re-count 70 whenever that block grows, or --help
  # truncates mid-sentence. It is the count of leading '#' lines: awk '/^set -euo/{print NR-1; exit}'.
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,70p'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN="true"; shift ;;
    --yes|-y)   ASSUME_YES="true"; shift ;;
    --keep)     KEEP="${2:-}"; shift 2 ;;
    -h|--help)  usage ;;
    *)          err "unknown argument '$1'"; usage ;;
  esac
done

if [[ ! "$KEEP" =~ ^[0-9]+$ ]] || [[ "$KEEP" -lt 1 ]]; then
  die "--keep must be a positive integer (got '${KEEP}') — the whole point is that at least ${USER_PREFIX}1 survives"
fi

trap 'gitea_cleanup; sonarqube_cleanup; print_ledger' EXIT

need_tools
require_ws "$WS_BIN" "the cohort prune is ws scale-users"

# ── discover the cohort (never assume 8) ─────────────────────────────────────────────────────────
LIVE_COUNT="$(live_user_count)"
GROUP_USERS="$(group_users)"
if [[ ! "$LIVE_COUNT" =~ ^[0-9]+$ ]]; then
  die "could not read workshop-config's userCount helm parameter from ${ARGO_NS} (got '${LIVE_COUNT}') — is the workshop layer installed? inspect: oc get application workshop-config -n ${ARGO_NS} -o yaml"
fi

# The removal set is the UNION of "above the keep line in the chart" and "above the keep line in the
# live group". They normally coincide; when a previous scale was interrupted they do not, and taking
# only one of them leaves a straggler with a working login and no namespaces — the exact half-state
# this policy exists to prevent.
REMOVED=()
_seen=" "
for (( _i = KEEP + 1; _i <= LIVE_COUNT; _i++ )); do
  REMOVED+=("${USER_PREFIX}${_i}")
  _seen="${_seen}${USER_PREFIX}${_i} "
done
for _u in $GROUP_USERS; do
  _idx="$(user_index "$_u")"
  if [[ -z "$_idx" ]]; then
    warn "workshop-attendees carries '${_u}', which is not ${USER_PREFIX}<N> — left alone (this script only removes generated attendee accounts)"
    continue
  fi
  if [[ "$_idx" -le "$KEEP" ]]; then
    continue
  fi
  case "$_seen" in
    *" ${_u} "*) : ;;
    *) REMOVED+=("$_u"); _seen="${_seen}${_u} " ;;
  esac
done

KEPT=()
for (( _i = 1; _i <= KEEP; _i++ )); do
  KEPT+=("${USER_PREFIX}${_i}")
done

# ── the plan ─────────────────────────────────────────────────────────────────────────────────────
echo "ogsr-wipe-users — clear the cohort, keep a working sample (the platform is NOT uninstalled)"
echo
echo "Discovered cohort : ${LIVE_COUNT} user(s) — workshop-config's LIVE userCount helm parameter"
echo "workshop-attendees: ${GROUP_USERS:-<empty>}"
if [[ -n "$GROUP_USERS" ]]; then
  _group_n="$(count_words "$GROUP_USERS")"
  if [[ "$_group_n" != "$LIVE_COUNT" ]]; then
    warn "the group has ${_group_n} member(s) but userCount=${LIVE_COUNT} — a prior scale may still be converging; the removal set below is the UNION of both"
  fi
fi
echo

if [[ "${#REMOVED[@]}" -eq 0 ]]; then
  ok "nothing above ${USER_PREFIX}${KEEP} — the cohort is already down to the sample. Nothing to do."
  exit 0
fi

echo "WILL REMOVE COMPLETELY — ${#REMOVED[@]} user(s) [${REMOVED[*]}]:"
echo "  • userCount lowered ${LIVE_COUNT} → ${KEEP}, and Argo PRUNES everything the chart rendered for"
echo "    them: every <user>-* namespace (shell included), cockpit, Kueue ClusterQueue, student"
echo "    AppProject + Argo RBAC, workshop-attendees membership, and KeycloakRealmImport CR"
echo "  • their per-user worlds are purged FIRST, in ws's SEV1-safe order (attendee Argo apps →"
echo "    namespace contents → entry-*-<user> apps), so the prune never races an attendee-pinned PVC"
echo "  • their htpasswd login line (openshift-config/htpasswd-workshop-users)"
echo "  • their OpenShift User + Identity objects (workshop-users:<user>)"
echo "  • their Gitea account, purged — every repository they own goes with it"
echo "  • their <user>-${SCAFFOLD_ORG_SUFFIX} Gitea scaffold org and its repositories"
echo "  • their SonarQube account in ${SONAR_NS}, removed AND anonymized so the login is freed —"
echo "    a SonarQube account is local:true and needs no cluster identity, so it would otherwise be"
echo "    the one working login a wiped attendee keeps"
echo "  • their Keycloak realm realm-<user> in ${SSO_NS} (pruning the import CR does NOT remove it)"
echo "  • their student-Argo local account password key in ${STUDENT_ARGO_NS}/argocd-secret"
echo
echo "WILL PRESERVE — untouched:"
echo "  • ${KEPT[*]} — namespaces, cockpit, Gitea account and repos, Keycloak realm, SonarQube"
echo "    account, AND LOGIN."
echo "    Whoever inherits this cluster can log in as ${KEPT[0]} and click through a working workshop."
echo "  • every installed component and operator, the platform-portfolio stacks (pp-*), workshop-config"
echo "  • the shared ogsr-* layer: Gitea, showroom infra, parasol images/tasks, student-gitops"
echo "  • Keycloak itself, and every realm belonging to a kept user"
echo "  • EVERY admin-supplied credential — the MaaS key, the shared workshop password secret, the"
echo "    Gitea and Keycloak admin credentials, and the cluster's own identity providers. Those came"
echo "    from the admin via install.sh; they are the admin's own and nothing here deletes them."
echo
echo "NOT REMOVED TODAY (known residue — CATALOG POINTERS, not credentials: nothing here authenticates"
echo "anyone, and every target they name is deleted above):"
echo "  • RHDH catalog Locations left by any golden-path service they scaffolded — they point at the"
echo "    Gitea repos purged above, so they resolve to nothing and grant nothing"
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "── DRY RUN — the exact live state that WOULD be removed ────────────────────"
  echo
  echo "delegated cohort prune (the only thing that lowers userCount):"
  echo "  ${WS_BIN} scale-users ${KEEP} --yes"
  echo
  echo "OpenShift User / Identity objects:"
  for _u in "${REMOVED[@]}"; do
    if oc get user "$_u" >/dev/null 2>&1; then
      echo "  user/${_u} + identity/workshop-users:${_u}"
    else
      echo "  (absent) user/${_u}"
    fi
  done
  echo
  echo "Keycloak realms in ${SSO_NS}:"
  if oc get namespace "$SSO_NS" >/dev/null 2>&1; then
    for _u in "${REMOVED[@]}"; do
      if oc get keycloakrealmimport "realm-${_u}" -n "$SSO_NS" >/dev/null 2>&1; then
        echo "  realm-${_u} (import CR present — Argo prunes the CR, this script deletes the realm itself)"
      else
        echo "  realm-${_u} (no import CR; the realm is still probed and deleted if present)"
      fi
    done
  else
    echo "  (${SSO_NS} absent — auth stack not installed)"
  fi
  echo
  echo "Gitea accounts, repositories and scaffold orgs:"
  if gitea_connect; then
    for _u in "${REMOVED[@]}"; do
      _code="$(gitea_api GET "/api/v1/users/${_u}")"
      if [[ "$_code" == "200" ]]; then
        echo "  account ${_u} — repositories:"
        _repos="$(gitea_owner_repos "$_u" user)"
        if [[ -n "$_repos" ]]; then
          indent_list "     " <<< "$_repos"
        else
          echo "     (none)"
        fi
      else
        echo "  account ${_u} (absent, HTTP ${_code})"
      fi
      _org="${_u}-${SCAFFOLD_ORG_SUFFIX}"
      _code="$(gitea_api GET "/api/v1/orgs/${_org}")"
      if [[ "$_code" == "200" ]]; then
        echo "  org ${_org} — repositories:"
        _repos="$(gitea_owner_repos "$_org" org)"
        if [[ -n "$_repos" ]]; then
          indent_list "     " <<< "$_repos"
        else
          echo "     (none)"
        fi
      else
        echo "  org ${_org} (absent, HTTP ${_code})"
      fi
    done
  else
    warn "could not reach the Gitea admin API — the Gitea half of the plan could not be enumerated"
  fi
  echo
  echo "SonarQube accounts in ${SONAR_NS}:"
  _sq_rc=0
  sonarqube_connect || _sq_rc=$?
  if [[ "$_sq_rc" -eq 2 ]]; then
    echo "  (${SONAR_NS} absent — SonarQube not installed)"
  elif [[ "$_sq_rc" -ne 0 ]]; then
    warn "could not reach the SonarQube admin API — the SonarQube half of the plan could not be enumerated"
  else
    for _u in "${REMOVED[@]}"; do
      _code="$(sonar_api GET "/api/v2/users-management/users?q=${_u}")"
      if [[ "$_code" != "200" ]]; then
        _code="$(sonar_api GET "/api/users/search?q=${_u}")"
      fi
      if [[ "$_code" != "200" ]]; then
        echo "  account ${_u} (could NOT ask, HTTP ${_code} — this is not 'absent')"
        continue
      fi
      if [[ -n "$(sonar_match_active_login "$_u")" ]]; then
        echo "  account ${_u} — active local login, will be removed and anonymized"
      else
        echo "  account ${_u} (absent)"
      fi
    done
  fi
  echo
  ok "dry run complete — nothing was changed. Re-run without --dry-run to apply."
  exit 0
fi

confirm_or_exit "Remove ${#REMOVED[@]} user(s) [${REMOVED[*]}] completely, keeping ${KEPT[*]}?"

# ── 1. the GitOps half: lower userCount and let Argo prune ───────────────────────────────────────
# Delegated in full. `ws scale-users` owns the ordering, the sync discipline and the htpasswd rewrite.
step "[1/7] lowering userCount ${LIVE_COUNT} → ${KEEP} via ws scale-users (Argo prunes the per-user world)" \
  "$WS_BIN" scale-users "$KEEP" --yes

# ── 2. OpenShift User + Identity objects ─────────────────────────────────────────────────────────
delete_identities() {
  local u rc=0
  for u in "${REMOVED[@]}"; do
    if oc get user "$u" >/dev/null 2>&1; then
      if oc delete user "$u" >/dev/null 2>&1; then
        ok "  user/${u} deleted"
      else
        err "  could not delete user/${u}"
        rc=1
      fi
    else
      skip "  user/${u} already absent"
    fi
    # The Identity name is "<idp>:<username>"; the workshop IdP is always 'workshop-users' —
    # bootstrap/install.sh appends exactly that entry to the OAuth singleton.
    if oc get identity "workshop-users:${u}" >/dev/null 2>&1; then
      if oc delete identity "workshop-users:${u}" >/dev/null 2>&1; then
        ok "  identity/workshop-users:${u} deleted"
      else
        err "  could not delete identity/workshop-users:${u}"
        rc=1
      fi
    else
      skip "  identity/workshop-users:${u} already absent"
    fi
  done
  return "$rc"
}
step "[2/7] deleting OpenShift User + Identity objects" delete_identities

# ── 3. Gitea accounts, their repositories, and their scaffold orgs ───────────────────────────────
delete_gitea_users() {
  local u org code rc=0
  if ! gitea_connect; then
    err "  could not reach the Gitea admin API (route/${GITEA_NS} or the admin credential) — Gitea accounts NOT removed"
    err "  fix: oc get route gitea -n ${GITEA_NS} && oc get gitea gitea -n ${GITEA_NS} -o jsonpath='{.status.adminPassword}'"
    return 1
  fi
  for u in "${REMOVED[@]}"; do
    info "  ${u}…"
    # The scaffold org FIRST: a Gitea org is its own owner, so a user purge never takes it, and an org
    # that still holds repositories cannot be deleted.
    org="${u}-${SCAFFOLD_ORG_SUFFIX}"
    code="$(gitea_api GET "/api/v1/orgs/${org}")"
    if [[ "$code" == "200" ]]; then
      gitea_delete_owner_repos "$org" org || rc=1
      code="$(gitea_api DELETE "/api/v1/orgs/${org}")"
      case "$code" in
        204|200|404) ok "  org ${org} removed" ;;
        *) err "  could not delete org ${org} (HTTP ${code})"; rc=1 ;;
      esac
    else
      skip "  org ${org} absent"
    fi
    # purge=true is what makes this work at all: without it Gitea refuses (422) to delete a user who
    # still owns repositories, and every attendee owns their module forks.
    code="$(gitea_api GET "/api/v1/users/${u}")"
    if [[ "$code" != "200" ]]; then
      skip "  Gitea account ${u} absent"
      continue
    fi
    code="$(gitea_api DELETE "/api/v1/admin/users/${u}?purge=true")"
    case "$code" in
      204|200|404) ok "  Gitea account ${u} purged (repositories included)" ;;
      *)
        err "  could not purge Gitea account ${u} (HTTP ${code}) — deleting its repositories first, then retrying"
        gitea_delete_owner_repos "$u" user || true
        code="$(gitea_api DELETE "/api/v1/admin/users/${u}?purge=true")"
        case "$code" in
          204|200|404) ok "  Gitea account ${u} removed on retry" ;;
          *) err "  Gitea account ${u} still present (HTTP ${code}) — remove it by hand at https://${GITEA_HOST}/-/admin/users"; rc=1 ;;
        esac
        ;;
    esac
  done
  return "$rc"
}
step "[3/7] purging Gitea accounts, repositories and scaffold orgs" delete_gitea_users

# ── 4. SonarQube accounts ────────────────────────────────────────────────────────────────────────
# Beside Gitea, and for the same reason: another external tool whose accounts are rows in its own
# database, seeded create-if-absent, that no Argo prune can reach.
#
# WHY ANONYMIZE AND NOT A PLAIN DEACTIVATE — all four behaviours measured live on SonarQube 26.5
# (Community Build, chart 2026.3.1) on 2026-08-01:
#   • POST /api/users/deactivate (no anonymize) → the account cannot authenticate, but the LOGIN STAYS
#     RESERVED: it moves to /api/users/search?deactivated=true and still owns the name "user2".
#   • …and POST /api/users/create on a reserved login REACTIVATES it. It happens to apply the new
#     password today, so a plain deactivate would appear to work — but only because two unrelated
#     behaviours line up (the seed's existence check is active-only, and create-as-reactivate resets
#     the password). Neither is contractual, and the v2 create verb that eventually replaces the
#     seed's deprecated one is not obliged to reactivate at all. A wipe that leaves a reserved login
#     behind is one API change away from re-arming the collision it was written to remove.
#   • Anonymize renames the row to sq-removed-<random> and FREES the login: the next cohort's seed
#     then creates a genuinely new account, on the new password, with no inherited state.
#     Verified end to end — anonymized, re-created, authenticated on the new password, rejected on
#     the old one.
# So: anonymize. "Removed" then means the same thing here as `purge=true` does for Gitea.
#
# v2 first because /api/users/* is deprecated since 10.4 (the server's own /api/webservices/list says
# so) and v2 users-management is its replacement. The v1 fallback is not dead code: an ADOPTED
# SonarQube may predate 10.4, and its deactivate carries the anonymize parameter from 9.7 onward.
delete_sonarqube_users() {
  local u id code rc=0 connect_rc=0
  sonarqube_connect || connect_rc=$?
  if [[ "$connect_rc" -eq 2 ]]; then
    skip "  ${SONAR_NS} not present (SonarQube not installed) — no accounts to remove"
    return 0
  fi
  if [[ "$connect_rc" -ne 0 ]]; then
    err "  could not reach the SonarQube admin API (route/${SONAR_NS} or the sonarqube-admin credential)"
    err "  — accounts NOT removed. This is NOT 'already clean': a SonarQube account is local:true, so"
    err "  every removed attendee keeps a WORKING login until this step succeeds. Re-run after fixing."
    err "  fix: oc get route sonarqube -n ${SONAR_NS} && oc get secret sonarqube-admin -n ${SONAR_NS}"
    return 1
  fi
  for u in "${REMOVED[@]}"; do
    code="$(sonar_api GET "/api/v2/users-management/users?q=${u}")"
    if [[ "$code" == "200" ]]; then
      id="$(sonar_match_active_login "$u")"
      if [[ -z "$id" ]]; then
        skip "  SonarQube account ${u} already absent"
        continue
      fi
      code="$(sonar_api DELETE "/api/v2/users-management/users/${id}?anonymize=true")"
      case "$code" in
        204|200|404) ok "  SonarQube account ${u} removed and anonymized (login freed)" ;;
        *) err "  could not remove SonarQube account ${u} (HTTP ${code}) — remove it by hand at https://${SONAR_HOST}/admin/users"; rc=1 ;;
      esac
      continue
    fi
    if [[ "$code" != "404" ]]; then
      err "  could not query SonarQube for ${u} (HTTP ${code}) — account NOT removed, and NOT confirmed absent"
      rc=1
      continue
    fi
    # 404 on the v2 collection = this SonarQube predates v2 users-management. Fall back to v1.
    code="$(sonar_api GET "/api/users/search?q=${u}")"
    if [[ "$code" != "200" ]]; then
      err "  could not query SonarQube for ${u} (HTTP ${code}, v1 API) — account NOT removed, and NOT confirmed absent"
      rc=1
      continue
    fi
    if [[ -z "$(sonar_match_active_login "$u")" ]]; then
      skip "  SonarQube account ${u} already absent"
      continue
    fi
    code="$(sonar_api POST /api/users/deactivate "login=${u}" "anonymize=true")"
    case "$code" in
      204|200|404) ok "  SonarQube account ${u} removed and anonymized (login freed, v1 API)" ;;
      *) err "  could not remove SonarQube account ${u} (HTTP ${code}, v1 API) — remove it by hand at https://${SONAR_HOST}/admin/users"; rc=1 ;;
    esac
  done
  return "$rc"
}
step "[4/7] removing SonarQube accounts (anonymized, so the login is freed)" delete_sonarqube_users

# ── 5. Keycloak realms ───────────────────────────────────────────────────────────────────────────
delete_keycloak_realms() {
  local u kc host secret admin pass token cfg form code rc=0
  if ! oc get namespace "$SSO_NS" >/dev/null 2>&1; then
    skip "  ${SSO_NS} not present (auth stack not installed) — no realms to remove"
    return 0
  fi
  # The import CR is un-rendered the moment userCount drops, so Argo prunes it; delete any straggler
  # ourselves BEFORE touching the realm, or a CR still standing lets the operator re-import what we
  # just deleted. Safe: the chart no longer renders it, so Argo will not put it back.
  for u in "${REMOVED[@]}"; do
    if oc get keycloakrealmimport "realm-${u}" -n "$SSO_NS" >/dev/null 2>&1; then
      oc delete keycloakrealmimport "realm-${u}" -n "$SSO_NS" --wait=true --timeout=120s >/dev/null 2>&1 || true
    fi
  done
  kc="$(oc get keycloak -n "$SSO_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$kc" ]]; then
    skip "  no Keycloak CR in ${SSO_NS} — import CRs removed, realms left as-is"
    return 0
  fi
  host="$(oc get route keycloak -n "$SSO_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  secret="${kc}-initial-admin"
  admin="$(oc get secret "$secret" -n "$SSO_NS" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  pass="$(oc get secret "$secret" -n "$SSO_NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "$host" || -z "$admin" || -z "$pass" ]]; then
    warn "  could not read the Keycloak admin credential (${SSO_NS}/${secret}) or the keycloak route —"
    warn "  the import CRs are gone but the realms remain. Remove by hand: Keycloak admin console →"
    warn "  realm-<user> → Realm settings → Delete."
    return 0
  fi
  form="$(mktemp)"; chmod 600 "$form"
  cfg="$(mktemp)"; chmod 600 "$cfg"
  # Credentials travel through 0600 files, never argv — this can run on a shared bastion.
  printf 'grant_type=password&client_id=admin-cli&username=%s&password=%s' "$admin" "$pass" > "$form"
  token="$(curl -ks --data "@${form}" \
    "https://${host}/realms/master/protocol/openid-connect/token" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)"
  rm -f "$form"
  if [[ -z "$token" ]]; then
    rm -f "$cfg"
    warn "  could not obtain a Keycloak admin token — the import CRs are gone but the realms remain"
    return 0
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$cfg"
  for u in "${REMOVED[@]}"; do
    code="$(curl -ks -K "$cfg" -o /dev/null -w '%{http_code}' -X DELETE \
      "https://${host}/admin/realms/realm-${u}" 2>/dev/null || true)"
    case "$code" in
      204|200) ok "  realm realm-${u} deleted" ;;
      404)     skip "  realm realm-${u} already absent" ;;
      *)       err "  could not delete realm realm-${u} (HTTP ${code:-000})"; rc=1 ;;
    esac
  done
  rm -f "$cfg"
  return "$rc"
}
step "[5/7] deleting Keycloak realms for the removed users" delete_keycloak_realms

# ── 6. student-Argo local account passwords ──────────────────────────────────────────────────────
delete_student_argo_accounts() {
  local u rc=0 patch=""
  if ! oc get secret argocd-secret -n "$STUDENT_ARGO_NS" >/dev/null 2>&1; then
    skip "  ${STUDENT_ARGO_NS}/argocd-secret not present — nothing to clean"
    return 0
  fi
  for u in "${REMOVED[@]}"; do
    patch="${patch}\"accounts.${u}.password\":null,\"accounts.${u}.passwordMtime\":null,"
  done
  if [[ -z "$patch" ]]; then
    return 0
  fi
  patch="{\"data\":{${patch%,}}}"
  if oc patch secret argocd-secret -n "$STUDENT_ARGO_NS" --type merge -p "$patch" >/dev/null 2>&1; then
    ok "  local Argo account password keys removed for ${#REMOVED[@]} user(s)"
  else
    err "  could not patch ${STUDENT_ARGO_NS}/argocd-secret"
    rc=1
  fi
  return "$rc"
}
step "[6/7] removing student-Argo local account passwords" delete_student_argo_accounts

# ── 7. per-user hook leftovers in the Gitea namespace ────────────────────────────────────────────
step "[7/7] sweeping per-user entry-hook leftovers in ${GITEA_NS}" \
  sweep_gitea_hook_leftovers "${REMOVED[@]}"

echo
if [[ "$STEP_FAILED" -eq 0 ]]; then
  ok "cohort wiped — ${#REMOVED[@]} user(s) removed; ${KEPT[*]} intact with a working login; the platform is untouched."
else
  err "wipe finished with failures — read the ledger below and re-run (every step is idempotent)."
fi
echo "   verify: oc get ns -l workshop.redhat.com/owner=ogsr | grep -E '^${USER_PREFIX}'   (expect only ${KEPT[*]})"
echo "           oc get users                                                       (expect only ${KEPT[*]} + your admin)"
echo "           oc get group workshop-attendees -o jsonpath='{.users[*]}'; echo    (expect ${KEPT[*]})"
echo "           ws status                                                          (cohort dashboard)"
echo "   note  : the oauth-openshift pods roll (~1 min) before the login changes take effect:"
echo "           oc rollout status deploy/oauth-openshift -n openshift-authentication"
echo "   re-run: ws scale-users N grows the cohort back — no reinstall needed."

if [[ "$STEP_FAILED" -ne 0 ]]; then
  exit 1
fi
