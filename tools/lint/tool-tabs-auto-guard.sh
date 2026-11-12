#!/usr/bin/env bash
# tool-tabs-auto-guard.sh — `cockpit_tool_tabs: auto` resolves the way INSTALL.md §6 says, in BOTH copies.
#
# The rule (bootstrap/ogsr-tool-tabs-lib.sh): exactly one redirect-type identity provider and no kubeadmin
# Secret → embedded; anything else → mixed (Console, Dev Spaces, Argo CD open in a new browser tab),
# because oauth-openshift then renders its own chooser/login page and no frame shows it. A wrong
# `embedded` is the costly direction: those three tabs go blank for every attendee.
#
# Drives the real function under a stubbed `oc`, from two places: the lib bootstrap/install.sh and
# `adm doctor` source, and the copy in helm/bootstrap/templates/job-cockpit-attributes.yaml (that Job's
# image has no repo). Same table for both, so the copies cannot drift in behaviour.
#
# --self-test plants one mutant per rule (kubeadmin ignored, password IdP read as redirect, "one" read
# as "at least one", legacy workshop-users counted, unreadable kubeadmin read as absent) and requires
# the table to catch each, then runs the real tree.
#
# Exit codes: 0 both copies resolve every case · 1 a case resolves wrong, or under --self-test every
# canary was caught and the tree is clean · 2 could not inspect (a copy is missing or a mutant is a no-op).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/lint/_extract-func.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_extract-func.sh"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_parse-guard-args.sh"

LIB="bootstrap/ogsr-tool-tabs-lib.sh"
JOB="helm/bootstrap/templates/job-cockpit-attributes.yaml"
FN="cockpit_tool_tabs_auto"

ok()  { printf '  ✅ %s\n' "$*"; }
bad() { printf '  ❌ %s\n' "$*"; }

# case | identity providers (name:type,…) | kubeadmin Secret | OAuth read | expected mode
CASES='one OIDC IdP|rhbk:OpenID|absent|ok|embedded
OIDC + HTPasswd|rhbk:OpenID,local:HTPasswd|absent|ok|mixed
two OIDC IdPs (chooser)|rhbk:OpenID,corp:OpenID|absent|ok|mixed
one HTPasswd IdP|local:HTPasswd|absent|ok|mixed
one LDAP IdP|corp:LDAP|absent|ok|mixed
one GitHub IdP|gh:GitHub|absent|ok|embedded
one OIDC IdP + kubeadmin|rhbk:OpenID|present|ok|mixed
no IdP||absent|ok|mixed
OIDC + legacy workshop-users (install retires it)|rhbk:OpenID,workshop-users:HTPasswd|absent|ok|embedded
OAuth not readable|rhbk:OpenID|absent|forbidden|unknown
kubeadmin Secret not readable|rhbk:OpenID|forbidden|ok|unknown'

# Stub `oc`: answers the two reads the rule makes, with the real CLI's output shapes. Shipped into the
# harness shell by `declare -f`, so shellcheck cannot see the call.
stub_oc() {
  # shellcheck disable=SC2317,SC2329  # SC2317 on 0.9.x (CI), SC2329 on >=0.10
  oc() {
    case "$*" in
      "get oauth cluster"*)
        if [[ "$STUB_OAUTH" == forbidden ]]; then
          echo 'Error from server (Forbidden): oauths.config.openshift.io "cluster" is forbidden' >&2; return 1
        fi
        [[ -z "$STUB_IDPS" ]] || printf '%s\n' "$STUB_IDPS" | tr ',:' '\n\t' ;;
      "get secret kubeadmin"*)
        case "$STUB_KA" in
          present) echo "secret/kubeadmin" ;;
          absent) echo 'Error from server (NotFound): secrets "kubeadmin" not found' >&2; return 1 ;;
          *) echo 'Error from server (Forbidden): secrets "kubeadmin" is forbidden' >&2; return 1 ;;
        esac ;;
      *) echo "stub oc: unexpected call: oc $*" >&2; return 99 ;;
    esac
  }
}

run_table() {  # <file holding the function> → 0 every case right, 1 otherwise (prints the misses)
  local fnfile="$1" name idps ka oauth want got rc misses=0
  while IFS='|' read -r name idps ka oauth want; do
    rc=0
    got="$(STUB_IDPS="$idps" STUB_KA="$ka" STUB_OAUTH="$oauth" bash -c '
      set -euo pipefail; '"$(declare -f stub_oc)"'; stub_oc; source "$1"; '"$FN"'' _ "$fnfile")" || rc=$?
    got="${got%%$'\t'*}"
    if [[ "$got" != "$want" ]] || { [[ "$want" == unknown ]] && [[ "$rc" -ne 2 ]]; } \
       || { [[ "$want" != unknown ]] && [[ "$rc" -ne 0 ]]; }; then
      bad "${name}: got '${got}' (rc ${rc}), want '${want}'"; misses=$((misses + 1))
    fi
  done <<< "$CASES"
  [[ "$misses" -eq 0 ]]
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

copies() {  # → writes $TMP/lib.sh and $TMP/job.sh; rc 2 when either is missing
  [[ -f "${REPO_ROOT}/${LIB}" ]] || { bad "missing ${LIB}"; return 2; }
  extract_func "${REPO_ROOT}/${LIB}" "$FN" > "$TMP/lib.sh"
  extract_func_indented "${REPO_ROOT}/${JOB}" "$FN" > "$TMP/job.sh" 2>/dev/null
  [[ -s "$TMP/lib.sh" ]] || { bad "${FN}() not found in ${LIB}"; return 2; }
  [[ -s "$TMP/job.sh" ]] || { bad "${FN}() not found in ${JOB} (at its 14-column script indent)"; return 2; }
}

check_tree() {
  local rc=0 f
  for f in lib job; do
    if run_table "$TMP/$f.sh"; then ok "${f} copy: every case resolves as documented"; else rc=1; fi
  done
  return "$rc"
}

parse_guard_args "$@"
copies || exit 2

if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  fail=0
  # label @ sed pattern @ replacement (BRE; none contains "/" or "@")
  while IFS='@' read -r label from to; do
    sed "s/${from}/${to}/" "$TMP/lib.sh" > "$TMP/mutant.sh"
    if cmp -s "$TMP/lib.sh" "$TMP/mutant.sh"; then bad "canary '${label}' changed nothing — fix its pattern"; exit 2; fi
    if run_table "$TMP/mutant.sh" >/dev/null; then bad "canary NOT caught: ${label}"; fail=1
    else ok "canary caught: ${label}"; fi
  done <<'MUTANTS'
kubeadmin ignored@ka="yes"@ka=""
password IdP read as redirect@HTPasswd|LDAP|Keystone|BasicAuth)@NOPE)
"exactly one" read as "at least one"@"$count" -eq 1@"$count" -ge 1
legacy workshop-users counted@ && "$n" != workshop-users@
unreadable kubeadmin read as absent@'not ?found'@'.'
MUTANTS
  [[ "$fail" -eq 0 ]] || { bad "self-test FAILED — a rule can regress unseen"; exit 2; }
  check_tree || { bad "self-test: the real tree fails the table"; exit 2; }
  printf '  tool-tabs-auto-guard: self-test passed (every canary caught, tree clean)\n'
  exit 1
fi

check_tree || { printf '\n  Fix the rule in %s and keep the copy in %s identical.\n' "$LIB" "$JOB"; exit 1; }
printf 'tool-tabs-auto-guard: clean (both copies resolve all cases).\n'
