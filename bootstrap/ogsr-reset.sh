#!/usr/bin/env bash
# ogsr-reset.sh — keep the cohort, clear the content. Re-run the workshop for the next group.
#
# The workshop is no longer something you uninstall; it is something you hand over and re-run. This
# script returns the cluster to its immediately-post-install state WITHOUT removing anyone: every
# attendee keeps their login, their namespaces, their Gitea account and their Keycloak realm, and
# every installed component stays exactly where it is. What goes is everything the LABS and the
# ATTENDEES created.
#
#   ./bootstrap/ogsr-reset.sh --dry-run             # print the CLEAR/KEEP plan; change nothing
#   ./bootstrap/ogsr-reset.sh                       # interactive confirm, then reset
#   ./bootstrap/ogsr-reset.sh --yes                 # no prompt (CI / scripted)
#   ./bootstrap/ogsr-reset.sh --restart-terminals   # also cycle the cockpit pods for the new group
#
# ── WHAT "IMMEDIATELY POST-INSTALL" MEANS HERE ───────────────────────────────────────────────────
#   • entry-state Applications gone     — every entry-<module>-<user> in the GitOps namespace
#   • attendee namespaces empty         — workloads, PVCs, attendee secrets/configmaps and lab CRs
#                                         removed; the namespace SHELL, its quota, LimitRange and
#                                         workshop-owned RBAC survive with the same UID
#   • attendee Argo apps gone           — everything they created in the student-gitops control plane
#   • Gitea back to seeded fork state   — the per-user forks are DELETED, so the next `ws start`
#                                         re-forks them clean from the canonical parasol/* repos, and
#                                         the attendee's <user>-svcs scaffold org is emptied
#
# The per-module purge logic is not re-invented here. Every entry state declares what its module owns
# (purgeNamespaces / purgeAppsNamespace / purgeAppsProject in gitops/entry-states/*/ws-meta.yaml) and
# `ws` drives it; a cluster-wide reset is that same logic iterated over every user and module, which
# is exactly what `ws cohort-reset` already does (tools/ws/ws, cmd_cohort_reset) — including the
# load-bearing SEV1 ordering (attendee Argo apps FIRST so a selfHeal app cannot re-deploy into a
# namespace mid-purge; entry apps LAST so the resources-finalizer never deadlocks on a PVC an attendee
# pod still pins). This script DELEGATES to it, and adds the half that lives outside Kubernetes:
#
#   • Gitea repositories. They are not k8s objects, so no namespace purge and no Argo prune can reach
#     them. An attendee's fork carries their commits, their branches and their broken merge from the
#     last session; leaving it makes the next group's first `git clone` a lie.
#   • The <user>-svcs scaffold org (developer-hub-golden-paths). A Gitea org is a separate owner from
#     the user, so it is invisible to anything keyed on the attendee's own namespace.
#   • Entry-hook leftovers in the Gitea namespace. Fork/seed hooks are Helm hooks with
#     BeforeHookCreation, so Argo does not track them and deleting the entry Application leaves the
#     Job, its ServiceAccount and its Role behind.
#
# ── WHAT IS NEVER TOUCHED ────────────────────────────────────────────────────────────────────────
# Nobody is removed and nothing is uninstalled. Logins, htpasswd, the OAuth IdP, User/Identity
# objects, the workshop-attendees group, userCount, Keycloak and its per-user realms, every operator
# and platform-portfolio stack, the shared ogsr-* layer, and every admin-supplied credential (MaaS
# key, shared workshop password, Gitea/Keycloak admin credentials) are all left exactly as they are.
#
# Idempotent: safe to re-run, and safe to run twice in a row. Already-absent objects are skipped with
# a printed reason.
#
# NOT the same thing as, and deliberately not a variant of:
#   ws reset <module> --user U     — ONE module for ONE attendee (attendee-facing: `ws prep`)
#   bootstrap/ogsr-wipe-users.sh   — REMOVES the cohort (keeps user1 as a working sample)
#   bootstrap/ogsr-uninstall.sh    — removes the workshop from the cluster entirely
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WS_BIN="${REPO_ROOT}/tools/ws/ws"

DRY_RUN="false"
ASSUME_YES="false"
RESTART_TERMINALS="false"

# shellcheck source=bootstrap/ogsr-cohort-lib.sh
source "${SCRIPT_DIR}/ogsr-cohort-lib.sh"

usage() {
  # 2,54 = the header comment block minus the shebang (ws's own --help does the same).
  # Re-count 54 whenever that block grows, or --help
  # truncates mid-sentence.
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,54p'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)                     DRY_RUN="true"; shift ;;
    --yes|-y)                      ASSUME_YES="true"; shift ;;
    --restart-terminals|--restart) RESTART_TERMINALS="true"; shift ;;
    -h|--help)                     usage ;;
    *)                             err "unknown argument '$1'"; usage ;;
  esac
done

trap 'gitea_cleanup; print_ledger' EXIT

need_tools
require_ws "$WS_BIN" "the per-module purge logic is ws cohort-reset"

# ── discover the cohort (never assume 8) ─────────────────────────────────────────────────────────
# The GROUP is authoritative here, not userCount: this operation touches only users who EXIST, and
# `ws cohort-reset` enumerates the same group. userCount is read purely as a cross-check, so a
# half-converged scale shows up in the plan rather than being discovered afterwards.
LIVE_COUNT="$(live_user_count)"
GROUP_USERS="$(group_users)"
if [[ -z "$GROUP_USERS" ]]; then
  die "the workshop-attendees group is empty or unreadable — is the workshop layer installed? try: ws doctor"
fi
USERS=()
for _u in $GROUP_USERS; do
  USERS+=("$_u")
done

echo "ogsr-reset — clear what the labs created, keep the cohort (nothing is uninstalled)"
echo
echo "Cohort          : ${#USERS[@]} user(s) — from the workshop-attendees group"
echo "workshop-config : userCount=${LIVE_COUNT:-<unreadable>}"
if [[ "$LIVE_COUNT" =~ ^[0-9]+$ ]] && [[ "${#USERS[@]}" != "$LIVE_COUNT" ]]; then
  warn "the group has ${#USERS[@]} member(s) but userCount=${LIVE_COUNT} — a prior scale may still be converging; this reset acts on the group"
fi
echo
echo "WILL CLEAR, for each of ${#USERS[@]} user(s) [${USERS[*]}]:"
echo "  • entry-*-<user> Argo apps in ${ARGO_NS} (every module's entry state; finalizers handled)"
echo "  • attendee-created Argo apps/appsets in ${STUDENT_ARGO_NS} (project proj-<user>)"
echo "  • the CONTENTS of every <user>-* namespace (label-discovered, not a hardcoded suffix list):"
echo "    workloads, PVCs, attendee secrets/configmaps, lab CRs, stale entry markers"
echo "  • every Gitea repository the attendee owns — the next 'ws start' re-forks them clean from"
echo "    the canonical parasol/* seeds"
echo "  • the attendee's <user>-${SCAFFOLD_ORG_SUFFIX} Gitea scaffold org is EMPTIED (the org itself stays)"
echo "  • per-user entry-hook leftovers (Jobs/SA/Role/RoleBinding) in ${GITEA_NS}"
echo
echo "WILL KEEP — untouched:"
echo "  • every attendee: login, htpasswd entry, User/Identity, workshop-attendees membership"
echo "  • every per-user namespace SHELL, with its quota, LimitRange and workshop-owned RBAC"
echo "  • Gitea itself and every attendee ACCOUNT; the canonical parasol/* repos and the git mirror"
echo "  • Keycloak and every per-user realm (realm-<user> in ${SSO_NS})"
echo "  • every installed component and operator, the platform-portfolio stacks (pp-*), workshop-config"
echo "  • the shared ogsr-* layer, and every admin-supplied credential (MaaS key, shared workshop"
echo "    password, Gitea/Keycloak admin credentials) — those came from the admin via install.sh"
if [[ "$RESTART_TERMINALS" == "true" ]]; then
  echo "  • per-user cockpits — RESTARTED at the end (--restart-terminals)"
else
  echo "  • per-user cockpits (left running; add --restart-terminals to cycle them for the new group)"
fi
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "── DRY RUN — the exact live state that WOULD be cleared ────────────────────"
  echo
  echo "delegated per-user purge:"
  if [[ "$RESTART_TERMINALS" == "true" ]]; then
    echo "  ${WS_BIN} cohort-reset --yes --restart-terminals"
  else
    echo "  ${WS_BIN} cohort-reset --yes"
  fi
  echo
  echo "entry-state Applications in ${ARGO_NS}:"
  _apps="$(oc get applications -n "$ARGO_NS" -o name 2>/dev/null | sed 's|.*/||' | grep '^entry-' || true)"
  if [[ -n "$_apps" ]]; then
    indent_list "  " <<< "$_apps"
  else
    echo "  (none)"
  fi
  echo
  echo "attendee namespaces whose CONTENTS would be purged (shells kept):"
  for _u in "${USERS[@]}"; do
    _ns="$(oc get ns -l "workshop.redhat.com/user=${_u}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
    echo "  ${_u}: ${_ns:-<none>}"
  done
  echo
  echo "Gitea repositories that would be deleted (re-forked on the next 'ws start'):"
  if gitea_connect; then
    for _u in "${USERS[@]}"; do
      _repos="$(gitea_owner_repos "$_u" user)"
      if [[ -n "$_repos" ]]; then
        echo "  ${_u}:"
        indent_list "     " <<< "$_repos"
      else
        echo "  ${_u}: (none)"
      fi
      _org="${_u}-${SCAFFOLD_ORG_SUFFIX}"
      _code="$(gitea_api GET "/api/v1/orgs/${_org}")"
      if [[ "$_code" == "200" ]]; then
        _repos="$(gitea_owner_repos "$_org" org)"
        if [[ -n "$_repos" ]]; then
          echo "  ${_org} (org emptied, org kept):"
          indent_list "     " <<< "$_repos"
        else
          echo "  ${_org}: (org present, already empty)"
        fi
      fi
    done
  else
    warn "could not reach the Gitea admin API — the Gitea half of the plan could not be enumerated"
  fi
  echo
  ok "dry run complete — nothing was changed. Re-run without --dry-run to apply."
  exit 0
fi

confirm_or_exit "Clear all lab content for ${#USERS[@]} user(s) [${USERS[*]}], keeping every login and namespace?"

# ── 1. the Kubernetes half: delegated in full ────────────────────────────────────────────────────
# `ws cohort-reset` owns the per-module purge contract (ws-meta purgeNamespaces / purgeAppsNamespace /
# purgeAppsProject) and the deletion ORDER. Re-implementing either here is how the two drift apart,
# and the ordering is the part that caused a SEV1 once already.
run_cohort_reset() {
  if [[ "$RESTART_TERMINALS" == "true" ]]; then
    "$WS_BIN" cohort-reset --yes --restart-terminals
  else
    "$WS_BIN" cohort-reset --yes
  fi
}
step "[1/3] purging every attendee's module state via ws cohort-reset" run_cohort_reset

# ── 2. Gitea back to seeded fork state ───────────────────────────────────────────────────────────
# The forks are DELETED rather than force-reset to the seed. Every entry-state fork job is written
# create-if-absent (it probes /api/v1/repos/<user>/<repo> and forks only on a miss), so an absent repo
# is precisely the state the next `ws start` expects — and it is the only state that also clears the
# attendee's branches, their commits and any repo they created by hand. The canonical parasol/* repos
# and the git mirror are ORG-owned and therefore out of range of an owner-scoped sweep by construction.
reset_gitea_content() {
  local u org code rc=0
  if ! gitea_connect; then
    err "  could not reach the Gitea admin API (route/${GITEA_NS} or the admin credential) — attendee repositories NOT cleared"
    err "  fix: oc get route gitea -n ${GITEA_NS} && oc get gitea gitea -n ${GITEA_NS} -o jsonpath='{.status.adminPassword}'"
    return 1
  fi
  for u in "${USERS[@]}"; do
    info "  ${u}…"
    code="$(gitea_api GET "/api/v1/users/${u}")"
    if [[ "$code" != "200" ]]; then
      skip "  Gitea account ${u} absent (HTTP ${code}) — nothing to clear"
      continue
    fi
    gitea_delete_owner_repos "$u" user || rc=1
    org="${u}-${SCAFFOLD_ORG_SUFFIX}"
    code="$(gitea_api GET "/api/v1/orgs/${org}")"
    if [[ "$code" == "200" ]]; then
      # EMPTIED, not deleted: the scaffold hook re-creates repos inside it but treats the org itself as
      # pre-existing, and an attendee who is still on this cluster keeps owning it.
      gitea_delete_owner_repos "$org" org || rc=1
    else
      skip "  org ${org} absent"
    fi
  done
  return "$rc"
}
step "[2/3] returning Gitea to its seeded fork state" reset_gitea_content

# ── 3. per-user hook leftovers in the Gitea namespace ────────────────────────────────────────────
step "[3/3] sweeping per-user entry-hook leftovers in ${GITEA_NS}" \
  sweep_gitea_hook_leftovers "${USERS[@]}"

echo
if [[ "$STEP_FAILED" -eq 0 ]]; then
  ok "reset complete — ${#USERS[@]} attendee(s) back to their immediately-post-install state; nothing uninstalled, nobody removed."
else
  err "reset finished with failures — read the ledger below and re-run (every step is idempotent)."
fi
echo "   verify: oc get applications -n ${ARGO_NS} | grep entry-        (expect none)"
echo "           oc get all -n ${USERS[0]}-dev                          (expect empty)"
echo "           oc get ns -l workshop.redhat.com/user=${USERS[0]}       (expect the shells, still there)"
echo "           ws status                                              (cohort dashboard)"
echo "   next  : an attendee's 'ws prep <module>' from their cockpit re-materializes any module cleanly."

if [[ "$STEP_FAILED" -ne 0 ]]; then
  exit 1
fi
