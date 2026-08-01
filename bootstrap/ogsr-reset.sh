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
# ── WHAT THIS DOES *NOT* CLEAR — a real scope boundary, not an oversight ─────────────────────────
# "Immediately post-install" above means the KUBERNETES and GIT state. Four kinds of attendee state
# live outside both and survive this reset. Handing a cluster to a NEW group without knowing that is
# how last week's attendee's work turns up in this week's attendee's session:
#
#   • the cockpit HOME directory. /home/lab-user is a per-user PVC (showroom-home-<user> in the
#     showroom namespace), not an emptyDir — so clones, edited files, shell history, generated
#     kubeconfigs and anything they saved survive, and --restart-terminals does NOT clear them
#     (a restart re-mounts the same volume). Modules are authored to be re-run-safe against a dirty
#     home (commit 727cd1d), which covers the SAME attendee re-running a lab; it does not cover a
#     DIFFERENT person inheriting the volume.
#   • per-user Keycloak realm CONTENTS. realm-<user> is created once by a KeycloakRealmImport that
#     the operator does not re-import over a realm that already exists, so clients/users the
#     securing-apps-keycloak lab created stay.
#   • server-side state in shared tools: SonarQube projects and analyses, RHDH catalog entities,
#     MTA/Tackle portfolio applications. These live in those products' databases, not as per-user
#     Kubernetes objects, so no namespace purge reaches them.
#   • Gitea personal access tokens and SSH keys on the attendee's account (the account is kept by
#     design; only its REPOSITORIES are cleared).
#
# If a re-run must be clean of those too, that is a bigger operation than this one — say so to the
# next group's instructor rather than assuming this covered it.
#
# ── HOW LONG IT TAKES ────────────────────────────────────────────────────────────────────────────
# The delegated purge is ~450 sequential `oc` calls per attendee (13 label-discovered namespaces
# x ~34 calls each, plus the Argo work). At the ~0.56 s per call measured against an RHDP cluster on
# 2026-08-01 that is roughly 4-5 minutes PER USER — about 35-45 minutes for a cohort of 8, longer if
# an entry app's resources-finalizer has to be waited out. It prints a line per namespace, so it is
# not silent, but it is slow: do not assume it has hung.
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
  # The header comment block: everything after the shebang, up to the first line that is not a comment.
  # COMPUTED, not a hard-coded line count. The previous form ended at a literal `54` with a note to
  # re-count it whenever the block grew — a note that is only ever read after --help has already
  # truncated mid-sentence, which is the same class of rot as a hard-coded CI job count.
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
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

# ── reserved live sessions ───────────────────────────────────────────────────────────────────────
# WS_RESERVED_USERS exists so a session that is live mid-demo is never disturbed, and `ws git-refresh
# --restart-terminals` honours it. This operation CANNOT: step 1 delegates to `ws cohort-reset`, which
# acts on the whole workshop-attendees group and accepts no exclusion flag — so filtering the list
# here would spare a reserved user in the plan text and wipe their namespaces one line later.
# A guard that half-works is worse than none, so refuse loudly instead. (Follow-up for the PM: an
# --exclude on `ws cohort-reset` is what would turn this refusal into a real option.)
_RESERVED="${WS_RESERVED_USERS:-}"
if [[ -n "${_RESERVED// /}" ]]; then
  _hits=""
  for _u in "${USERS[@]}"; do
    if [[ " ${_RESERVED} " == *" ${_u} "* ]]; then _hits="${_hits}${_u} "; fi
  done
  if [[ -n "$_hits" ]]; then
    err "WS_RESERVED_USERS names live session(s) this reset would wipe: ${_hits% }"
    err "  the per-user purge is delegated to 'ws cohort-reset', which has no exclusion flag — a"
    err "  reserved attendee cannot be spared, so nothing has been changed."
    die "refusing. Unset WS_RESERVED_USERS once those sessions are finished, then re-run."
  fi
fi

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
echo "WILL *NOT* CLEAR — attendee state that lives outside Kubernetes and Git (read this before"
echo "handing the cluster to a NEW group; see the header for the detail):"
echo "  • the cockpit HOME directory — /home/lab-user is a per-user PVC; --restart-terminals re-mounts"
echo "    the same volume rather than emptying it"
echo "  • per-user Keycloak realm CONTENTS (clients/users the securing-apps-keycloak lab created)"
echo "  • SonarQube projects/analyses, RHDH catalog entities, MTA portfolio apps (product databases)"
echo "  • Gitea personal access tokens and SSH keys on the kept attendee account"
echo
echo "Expect roughly 4-5 minutes PER USER (~450 sequential oc calls each) — about"
echo "$(( ${#USERS[@]} * 4 ))-$(( ${#USERS[@]} * 5 )) minutes for this cohort. It is slow, not hung: a line prints per namespace."
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
  # Listed by NAME prefix here, but `ws cohort-reset` selects them by the workshop.redhat.com/user
  # LABEL. Those two sets are normally identical (verified live 2026-08-01: 21/21 entry apps carried
  # the label) — but an app materialized by a `ws` that predates the label carries the name without it
  # and would be listed here and NOT purged. Say so at plan time rather than discovering it after.
  if ! _all_apps="$(oc get applications -n "$ARGO_NS" -o name 2>/dev/null)"; then
    warn "  could not read Applications in ${ARGO_NS} — this part of the plan is UNKNOWN, not empty"
    _all_apps=""
  fi
  _apps="$(printf '%s\n' "$_all_apps" | sed 's|.*/||' | grep '^entry-' || true)"
  if [[ -n "$_apps" ]]; then
    indent_list "  " <<< "$_apps"
    _labelled="$(oc get applications -n "$ARGO_NS" -l 'workshop.redhat.com/user' -o name 2>/dev/null | sed 's|.*/||' | grep -c '^entry-' || true)"
    _named="$(printf '%s\n' "$_apps" | grep -c . || true)"
    if [[ "$_labelled" != "$_named" ]]; then
      warn "  ${_named} entry app(s) by name but only ${_labelled} carry workshop.redhat.com/user —"
      warn "  the unlabelled ones will NOT be purged (delete them by hand, or re-materialize them first)"
    fi
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
      # rc 3 from gitea_owner_repos means the API did not answer. Printing "(none)" for that would tell
      # the operator the sweep has nothing to do when in fact it could not look.
      _list_rc=0
      _repos="$(gitea_owner_repos "$_u" user)" || _list_rc=$?
      if [[ "$_list_rc" -ne 0 ]]; then
        warn "  ${_u}: could NOT list repositories (API did not answer) — UNKNOWN, not empty"
      elif [[ -n "$_repos" ]]; then
        echo "  ${_u}:"
        indent_list "     " <<< "$_repos"
      else
        echo "  ${_u}: (none)"
      fi
      _org="${_u}-${SCAFFOLD_ORG_SUFFIX}"
      _code="$(gitea_api GET "/api/v1/orgs/${_org}")"
      if [[ "$_code" == "200" ]]; then
        _list_rc=0
        _repos="$(gitea_owner_repos "$_org" org)" || _list_rc=$?
        if [[ "$_list_rc" -ne 0 ]]; then
          warn "  ${_org}: could NOT list repositories (API did not answer) — UNKNOWN, not empty"
        elif [[ -n "$_repos" ]]; then
          echo "  ${_org} (org emptied, org kept):"
          indent_list "     " <<< "$_repos"
        else
          echo "  ${_org}: (org present, already empty)"
        fi
      elif [[ "$_code" != "404" ]]; then
        warn "  ${_org}: Gitea answered HTTP ${_code} — could not tell whether the scaffold org exists"
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
step "[1/4] purging every attendee's module state via ws cohort-reset" run_cohort_reset

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
    # ONLY 404 means "this attendee has no Gitea account". Every other non-200 is the API declining to
    # answer — most often 401 from a rotated admin credential, which returns 401 on /api/v1/users/<u>
    # exactly as it does on every other path (measured live, 2026-08-01). Reading that as "absent" is
    # what turns a reset that deleted nothing into a green run.
    code="$(gitea_api GET "/api/v1/users/${u}")"
    if [[ "$code" == "404" ]]; then
      skip "  Gitea account ${u} absent — nothing to clear"
      continue
    fi
    if [[ "$code" != "200" ]]; then
      err "  Gitea answered HTTP ${code} for account ${u} — could not tell whether it exists, so its"
      err "  repositories were NOT cleared. This is a failure, not an empty account."
      rc=1
      continue
    fi
    gitea_delete_owner_repos "$u" user || rc=1
    org="${u}-${SCAFFOLD_ORG_SUFFIX}"
    code="$(gitea_api GET "/api/v1/orgs/${org}")"
    if [[ "$code" == "200" ]]; then
      # EMPTIED, not deleted: the scaffold hook re-creates repos inside it but treats the org itself as
      # pre-existing, and an attendee who is still on this cluster keeps owning it.
      gitea_delete_owner_repos "$org" org || rc=1
    elif [[ "$code" == "404" ]]; then
      skip "  org ${org} absent"
    else
      err "  Gitea answered HTTP ${code} for org ${org} — scaffold org NOT emptied"
      rc=1
    fi
  done
  return "$rc"
}
step "[2/4] returning Gitea to its seeded fork state" reset_gitea_content

# ── 3. per-user hook leftovers in the Gitea namespace ────────────────────────────────────────────
step "[3/4] sweeping per-user entry-hook leftovers in ${GITEA_NS}" \
  sweep_gitea_hook_leftovers "${USERS[@]}"

# ── 4. verify — assert the NEGATIVE, and never read "could not ask" as "not there" ───────────────
# The steps above report what they DID; this reports what is now TRUE. They are not the same claim: a
# delete that was swallowed, an Argo controller that put something back, or an entry app that carries
# the entry- name without the user label all leave the steps green and the cluster dirty.
#
# Every check here fails CLOSED. A read that errors is ❌ "could not verify" — never a ✅ — because a
# teardown that cannot see the cluster has proved nothing about it. And the KEEP half is asserted too:
# a reset that removed the namespaces or the cohort would otherwise look like a particularly thorough
# success.
verify_reset() {
  local u rc=0 apps entry_named entry_labelled n ns_list leftovers repos list_rc grp gitea_up=0
  echo
  # Connect once, outside the loop: gitea_connect caches, but on FAILURE it clears the cache and
  # re-reports, so calling it per user would print the same failure once per attendee.
  if gitea_connect; then
    gitea_up=1
  else
    err "  Gitea admin API unavailable — repository removal is UNVERIFIED for the whole cohort"
    rc=1
  fi

  # (a) the cohort still exists — this operation must never remove anybody.
  grp="$(group_users)"
  n="$(count_words "$grp")"
  if [[ "$n" == "${#USERS[@]}" ]]; then
    ok "  cohort intact: ${n} member(s) still in workshop-attendees"
  else
    err "  workshop-attendees now has ${n} member(s), started with ${#USERS[@]} — reset must NEVER remove a user"
    rc=1
  fi

  # (b) no entry-state Applications left, counted BOTH by name and by the label cohort-reset selects on.
  if ! apps="$(oc get applications -n "$ARGO_NS" -o name 2>/dev/null)"; then
    err "  could NOT read Applications in ${ARGO_NS} — entry-state removal is UNVERIFIED"
    rc=1
  else
    entry_named="$(printf '%s\n' "$apps" | sed 's|.*/||' | grep -c '^entry-' || true)"
    entry_labelled="$(oc get applications -n "$ARGO_NS" -l 'workshop.redhat.com/user' -o name 2>/dev/null | sed 's|.*/||' | grep -c '^entry-' || true)"
    if [[ "$entry_named" -eq 0 ]]; then
      ok "  no entry-* Applications remain in ${ARGO_NS}"
    else
      err "  ${entry_named} entry-* Application(s) still in ${ARGO_NS} (${entry_labelled} of them carry the user label)"
      err "  inspect: oc get applications -n ${ARGO_NS} | grep entry-"
      rc=1
    fi
  fi

  for u in "${USERS[@]}"; do
    # (c) the namespace SHELLS survive. This is the half the owner cares about most: keep the users.
    if ! ns_list="$(oc get ns -l "workshop.redhat.com/user=${u}" -o name 2>/dev/null)"; then
      err "  ${u}: could NOT list namespaces — the KEEP half is UNVERIFIED"
      rc=1
    else
      n="$(printf '%s\n' "$ns_list" | grep -c . || true)"
      if [[ "$n" -ge 1 ]]; then
        ok "  ${u}: ${n} namespace shell(s) still present (compare with the pre-reset count you recorded)"
      else
        err "  ${u}: NO namespaces left — reset must keep every shell; this is a destroyed attendee"
        rc=1
      fi
    fi

    # (d) no attendee-created Argo apps left in their student-gitops project.
    if oc get ns "$STUDENT_ARGO_NS" >/dev/null 2>&1; then
      # Same jsonpath idiom as cohort_purge_student_apps (escaped double quotes — k8s jsonpath filters
      # want them, and grep -c exits 1 on a count of 0, so the assignment is guarded rather than trusted).
      n="$(oc get applications.argoproj.io -n "$STUDENT_ARGO_NS" \
            -o jsonpath="{range .items[?(@.spec.project==\"proj-${u}\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null | grep -c . || true)"
      if [[ -z "$n" ]]; then n=0; fi
      if [[ "$n" -eq 0 ]]; then
        ok "  ${u}: no attendee Argo apps left in proj-${u}"
      else
        err "  ${u}: ${n} attendee Argo app(s) still in proj-${u} (${STUDENT_ARGO_NS}) — a selfHeal survivor re-deploys into the purged namespaces"
        rc=1
      fi
    fi

    # (e) no per-user entry-hook leftovers in the Gitea namespace.
    if ! leftovers="$(oc get job,serviceaccount,role,rolebinding,configmap -n "$GITEA_NS" \
          -l "workshop.redhat.com/user=${u}" -o name 2>/dev/null)"; then
      err "  ${u}: could NOT list hook leftovers in ${GITEA_NS} — UNVERIFIED"
      rc=1
    else
      n="$(printf '%s\n' "$leftovers" | grep -c . || true)"
      if [[ "$n" -eq 0 ]]; then
        ok "  ${u}: no entry-hook leftovers in ${GITEA_NS}"
      else
        err "  ${u}: ${n} entry-hook object(s) still in ${GITEA_NS}"
        rc=1
      fi
    fi

    # (f) the attendee owns no Gitea repositories. rc 3 = the API did not answer, which is a ❌.
    if [[ "$gitea_up" -eq 1 ]]; then
      list_rc=0
      repos="$(gitea_owner_repos "$u" user)" || list_rc=$?
      if [[ "$list_rc" -ne 0 ]]; then
        err "  ${u}: could NOT list Gitea repositories — repository removal is UNVERIFIED"
        rc=1
      elif [[ -z "$repos" ]]; then
        ok "  ${u}: owns no Gitea repositories (the next 'ws start' re-forks them clean)"
      else
        err "  ${u}: still owns Gitea repositories — $(printf '%s' "$repos" | tr '\n' ' ')"
        rc=1
      fi
    fi
  done
  return "$rc"
}
step "[4/4] verifying the reset (asserts what is TRUE, not what was attempted)" verify_reset

echo
if [[ "$STEP_FAILED" -eq 0 ]]; then
  ok "reset complete and VERIFIED — ${#USERS[@]} attendee(s) back to their immediately-post-install state;"
  echo "   nothing uninstalled, nobody removed. Note the WILL-NOT-CLEAR list above before a NEW group starts."
else
  err "reset finished with failures — read the ledger below and re-run (every step is idempotent)."
fi
echo "   re-check by hand: oc get applications -n ${ARGO_NS} | grep entry-   (expect none)"
echo "                     oc get all -n ${USERS[0]}-dev                     (expect empty)"
echo "                     oc get ns -l workshop.redhat.com/user=${USERS[0]}  (expect the shells, still there)"
echo "                     ws status                                        (cohort dashboard)"
echo "   RE-CHECK AGAIN IN ~5 MINUTES. workshop-config syncs with prune+selfHeal, and an Argo"
echo "   reconcile that lands after this script exits is the one thing a same-second check cannot see."
echo "   next  : an attendee's 'ws prep <module>' from their cockpit re-materializes any module cleanly."

if [[ "$STEP_FAILED" -ne 0 ]]; then
  exit 1
fi
