#!/usr/bin/env bash
# ogsr-cohort-lib.sh — shared helpers for the two cluster-lifecycle operations that replaced uninstall
# as the workshop's everyday path:
#
#   bootstrap/ogsr-wipe-users.sh   clear the cohort, keep a working sample (user1 survives, login included)
#   bootstrap/ogsr-reset.sh        keep the cohort, clear everything the labs and attendees created
#
# SOURCED, never executed. It defines functions and default configuration and runs nothing at import,
# so a caller can source it, override any OGSR_* / *_NS value, and then call in.
#
# WHY A LIBRARY AND NOT TWO COPIES. The first draft of these scripts carried a byte-identical block in
# both files with a lint guard asserting the copies had not drifted. That is the same shape as the six
# hand-copied walkers in tools/lint/ that were deduplicated on 2026-07-31 — five of which shared a bug
# the sixth had already fixed, invisible because every copy looked correct on its own. A drift guard
# proves the copies MATCH; it cannot notice that both are wrong. One definition, one place to fix.
#
# Everything here is read-mostly or idempotent. The two genuinely destructive verbs live in the
# callers, where the plan text that describes them also lives.

# ── configuration (override by exporting before sourcing, or by assigning after) ──────────────────
# SC2034 on the next block: shellcheck lints this file in isolation and cannot see that every value
# here is read by the two SOURCING callers (STUDENT_ARGO_NS and SSO_NS only in ogsr-wipe-users.sh,
# SCAFFOLD_ORG_SUFFIX in both). Exporting them to silence it would leak workshop namespace names into
# the environment of `ws` and every `oc` this script runs, which is a worse trade than a directive.
# shellcheck disable=SC2034
ARGO_NS="${WS_ARGO_NS:-openshift-gitops}"
# shellcheck disable=SC2034
GITEA_NS="${WS_GITEA_NS:-ogsr-gitea}"
# shellcheck disable=SC2034
STUDENT_ARGO_NS="${WS_STUDENT_ARGO_NS:-ogsr-student-gitops}"
# shellcheck disable=SC2034
SSO_NS="${WS_SSO_NS:-sso-workshop}"
# shellcheck disable=SC2034
USER_PREFIX="${WS_USER_PREFIX:-user}"
# developer-hub-golden-paths gives each attendee a dedicated Gitea org to scaffold into ({user}-svcs);
# the suffix is that chart's scaffoldOrgSuffix. A variable so a chart rename is a one-line change.
# shellcheck disable=SC2034
SCAFFOLD_ORG_SUFFIX="${WS_SCAFFOLD_ORG_SUFFIX:-svcs}"

# Set by the callers' argument parsing; defaulted here so `set -u` is safe if a caller sources first.
DRY_RUN="${DRY_RUN:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

ok()   { echo "✅ $*"; }
err()  { echo "❌ $*" >&2; }
warn() { echo "⚠️  $*" >&2; }
info() { echo "▶ $*"; }
skip() { echo "➖ $*"; }
die()  { err "$*"; exit 1; }

# ── step resilience ──────────────────────────────────────────────────────────────────────────────
# Steps report and CONTINUE. A half-finished cohort operation that says nothing is worse than a
# reported failure: the LATER steps are the ones that remove identities and repositories, and an early
# Gitea outage must not silently skip them. The caller's EXIT trap prints the ledger however we leave.
#
# ogsr-uninstall.sh printed "[3/8]" and stopped once, in 2026-07-25, because of a `cond && cmd` as the
# last statement of a function called as a bare command: the AND-list returns 1, the function returns
# 1, and `set -e` kills the script. Steps 4-8 never ran and nothing on screen said so. Every function
# in this file and in both callers is written with explicit `if` blocks for that reason — never
# `[[ … ]] && cmd` — and step() swallows a non-zero rc rather than letting it propagate at all.
STEP_LEDGER=""
STEP_FAILED=0

step() {  # <label> <command…> — run it, record the outcome, never abort the script
  local label="$1"; shift
  info "$label"
  local rc=0
  "$@" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    STEP_LEDGER="${STEP_LEDGER}  ✅ ${label}"$'\n'
  else
    STEP_LEDGER="${STEP_LEDGER}  ❌ ${label} (rc=${rc})"$'\n'
    # Read by both callers' closing verdict + exit code; invisible to shellcheck across the source.
    # shellcheck disable=SC2034
    STEP_FAILED=1
    err "step failed (rc=${rc}): ${label} — continuing; see the ledger at the end"
  fi
  return 0
}

print_ledger() {
  if [[ -z "$STEP_LEDGER" ]]; then
    return 0
  fi
  echo
  echo "── step ledger ─────────────────────────────────────────────"
  printf '%s' "$STEP_LEDGER"
}

need_tools() {  # every external binary these scripts cannot degrade without
  local missing=0 t
  for t in oc curl python3; do
    if ! command -v "$t" >/dev/null 2>&1; then
      err "required tool '${t}' not found on PATH"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "install the missing tool(s) and re-run — oc (OpenShift CLI), curl, python3 (JSON parsing)"
  fi
  if ! oc whoami >/dev/null 2>&1; then
    die "not logged in to a cluster — run 'oc login' (or export KUBECONFIG) and re-run"
  fi
}

require_ws() {  # <path> — both operations delegate their engine half to the ws CLI; refuse without it
  local ws_bin="$1" what="$2"
  if [[ ! -x "$ws_bin" ]]; then
    die "${ws_bin} not found or not executable — run this from a full checkout of the workshop repo (copying bootstrap/ alone is not enough: ${what})"
  fi
}

# ── cohort discovery — NEVER assume 8 ────────────────────────────────────────────────────────────
live_user_count() {  # → workshop-config's LIVE userCount helm parameter, or empty when unreadable.
  # THE authoritative cohort size: it is what Argo will actually render on the next sync. The admin
  # picks it at install time (bootstrap/vars.yaml `users:`, default 5) and `ws scale-users` is the only
  # thing that moves it — so it may be 5, 8, 30 or anything else. Deliberately NOT read from the repo's
  # gitops/workshop-config/values.yaml default, which goes stale the moment a cluster is ever scaled.
  oc get application workshop-config -n "$ARGO_NS" \
    -o jsonpath='{.spec.source.helm.parameters[?(@.name=="userCount")].value}' 2>/dev/null || true
}

group_users() {  # → space-separated attendee usernames from the workshop-attendees group ("" if none).
  # The SECOND opinion on cohort size, and the authority on who actually EXISTS. The group is rendered
  # from userCount, so the two normally agree; when they do not, a scale is still converging (or was
  # interrupted) and the CALLER decides which to trust. Never used alone to size a destructive sweep.
  oc get group workshop-attendees -o jsonpath='{.users[*]}' 2>/dev/null || true
}

count_words() {  # <string> → how many whitespace-separated words it holds (0 for empty)
  local s="$1"
  if [[ -z "${s// /}" ]]; then
    printf '0'
    return 0
  fi
  # shellcheck disable=SC2086  # word splitting is the measurement, not an accident
  set -- $s
  printf '%s' "$#"
}

indent_list() {  # <pad> — re-print stdin with <pad> in front of every line (dry-run plan formatting)
  local pad="$1" line
  while IFS= read -r line; do
    printf '%s%s\n' "$pad" "$line"
  done
}

user_index() {  # <username> → its numeric suffix, or empty when the name is not <prefix><digits>
  local u="$1"
  if [[ "$u" =~ ^${USER_PREFIX}([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

confirm_or_exit() {  # <prompt> — destructive gate: --yes, else a TTY y/N, else refuse
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "not a terminal and no --yes given — re-run with --yes (or --dry-run to see the plan first)"
  fi
  local reply
  read -r -p "$1 [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    info "nothing changed. Re-run when ready (or use --dry-run)."
    exit 0
  fi
}

# ── Gitea admin API ──────────────────────────────────────────────────────────────────────────────
# Gitea repositories are not Kubernetes objects, so no namespace purge and no Argo prune can ever
# reach them — this is the half of both operations that has to be done by API.
#
# Same admin-credential discovery idiom as ws's _gitea_admin_creds and the gitea-user-seed hook's own
# Job script. The credential goes into a 0600 curl config rather than `-u user:pass`, so it never
# appears in the process table of a shared bastion.
GITEA_HOST=""
GITEA_CFG=""
GITEA_BODY=""

gitea_cleanup() {
  if [[ -n "$GITEA_CFG" ]]; then rm -f "$GITEA_CFG"; fi
  if [[ -n "$GITEA_BODY" ]]; then rm -f "$GITEA_BODY"; fi
}

gitea_connect() {  # → 0 when the admin API is reachable; sets GITEA_HOST/GITEA_CFG/GITEA_BODY
  if [[ -n "$GITEA_CFG" ]]; then
    return 0   # already connected — idempotent, so the dry-run enumerator and a step can both call it
  fi
  local host user pass
  host="$(oc get route gitea -n "$GITEA_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    return 1
  fi
  user="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.spec.giteaAdminUser}' 2>/dev/null || true)"
  if [[ -z "$user" ]]; then user="gitea-admin"; fi
  pass="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.status.adminPassword}' 2>/dev/null || true)"
  if [[ -z "$pass" ]]; then
    pass="$(oc get secret gitea-admin-credentials -n "$GITEA_NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  if [[ -z "$pass" ]]; then
    return 1
  fi
  GITEA_HOST="$host"
  GITEA_CFG="$(mktemp)"; chmod 600 "$GITEA_CFG"
  GITEA_BODY="$(mktemp)"; chmod 600 "$GITEA_BODY"
  printf 'user = "%s:%s"\n' "$user" "$pass" > "$GITEA_CFG"
  return 0
}

gitea_api() {  # <METHOD> <path> → HTTP status on stdout; response body left in $GITEA_BODY
  local method="$1" path="$2" code
  code="$(curl -ks -K "$GITEA_CFG" -o "$GITEA_BODY" -w '%{http_code}' \
    -X "$method" -H 'Accept: application/json' "https://${GITEA_HOST}${path}" 2>/dev/null || true)"
  if [[ -z "$code" ]]; then code="000"; fi
  printf '%s' "$code"
}

gitea_json_names() {  # → the "name" field of every object in $GITEA_BODY's array, one per line
  # python3, not grep: Gitea does not promise compact JSON, and a repository DESCRIPTION containing the
  # literal text '"name":' would make a regex hand back a repository that does not exist — which, in a
  # function whose only caller then issues DELETE, is the worst possible failure mode.
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if isinstance(data, dict):
    data = data.get("data", [])
for item in data or []:
    if isinstance(item, dict) and item.get("name"):
        print(item["name"])
' "$GITEA_BODY" 2>/dev/null || true
}

gitea_owner_repos() {  # <owner> <user|org> → every repo name that owner owns, one per line, paged
  local owner="$1" kind="$2" page=1 code names count
  while [[ "$page" -le 20 ]]; do
    if [[ "$kind" == "org" ]]; then
      code="$(gitea_api GET "/api/v1/orgs/${owner}/repos?limit=50&page=${page}")"
    else
      code="$(gitea_api GET "/api/v1/users/${owner}/repos?limit=50&page=${page}")"
    fi
    if [[ "$code" != "200" ]]; then
      return 0
    fi
    names="$(gitea_json_names)"
    if [[ -z "$names" ]]; then
      return 0
    fi
    printf '%s\n' "$names"
    count="$(printf '%s\n' "$names" | grep -c . || true)"
    if [[ "$count" -lt 50 ]]; then
      return 0
    fi
    page=$((page + 1))
  done
  return 0
}

gitea_delete_owner_repos() {  # <owner> <user|org> — delete every repo under that owner (idempotent)
  # Owner-SCOPED by construction: the canonical parasol/* seed repos and the git mirror belong to the
  # `parasol` ORG, so no call keyed on an attendee username or on <user>-svcs can ever reach them.
  local owner="$1" kind="$2" repo code deleted=0 repos
  repos="$(gitea_owner_repos "$owner" "$kind")"
  if [[ -z "$repos" ]]; then
    skip "  ${owner}: no repositories"
    return 0
  fi
  local rc=0
  while IFS= read -r repo; do
    if [[ -z "$repo" ]]; then
      continue
    fi
    code="$(gitea_api DELETE "/api/v1/repos/${owner}/${repo}")"
    case "$code" in
      204|200|404) deleted=$((deleted + 1)); echo "     ✓ ${owner}/${repo}" ;;
      *) err "  could not delete ${owner}/${repo} (HTTP ${code}) — check the Gitea admin credential and re-run"; rc=1 ;;
    esac
  done <<< "$repos"
  ok "  ${owner}: ${deleted} repository/ies removed"
  return "$rc"
}

sweep_gitea_hook_leftovers() {  # <user…> — clear per-user entry-hook objects in the Gitea namespace
  # Entry-state fork/seed hooks run as Jobs (+ SA/Role/RoleBinding/ConfigMap) in the Gitea namespace,
  # carrying workshop.redhat.com/user. They are Helm HOOKS with BeforeHookCreation, so Argo does not
  # track them and deleting the entry Application leaves them behind. Label-scoped, so nothing shared
  # is ever in range.
  local u kinds="job,serviceaccount,role,rolebinding,configmap"
  for u in "$@"; do
    oc delete "$kinds" -n "$GITEA_NS" -l "workshop.redhat.com/user=${u}" \
      --ignore-not-found >/dev/null 2>&1 || true
  done
  ok "  ${GITEA_NS}: hook leftovers swept for $# user(s)"
  return 0
}

# Executed rather than sourced is always a mistake — say so instead of silently doing nothing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "❌ ogsr-cohort-lib.sh is a library — source it, do not run it." >&2
  echo "   the two operations it backs are: bootstrap/ogsr-wipe-users.sh and bootstrap/ogsr-reset.sh" >&2
  exit 2
fi
