#!/usr/bin/env bash
# cohort-ops-guard.sh — the invariants that keep the two cluster-lifecycle operations honest.
#
#   bootstrap/ogsr-wipe-users.sh   clear the cohort, keep a working sample
#   bootstrap/ogsr-reset.sh        keep the cohort, clear what the labs created
#   bootstrap/ogsr-cohort-lib.sh   their shared library
#
# Both are DESTRUCTIVE and both run against clusters we do not own. Four of the five detectors below
# exist because the obvious way to write these scripts is silently wrong:
#
#   1. HAND DELETION IS UNDONE BY SELF-HEAL. workshop-config syncs prune:true selfHeal:true and
#      renders every per-user object from .Values.userCount. `oc delete ns user3-dev` succeeds, and
#      Argo puts it back within seconds — the operator sees a correct namespace list minutes later for
#      entirely the wrong reason. The ONLY correct removal is to lower userCount and let Argo prune.
#      check_no_selfheal_fight forbids the hand-deletion shapes and forbids patching userCount here
#      (that patch, and its sync discipline, belong to ws scale-users).
#   2. A RE-IMPLEMENTED ENGINE DRIFTS. The per-module purge contract lives in the entry states'
#      ws-meta.yaml and is driven by tools/ws/ws; the deletion ORDER inside it caused a SEV1 once.
#      check_ws_delegation proves each script still calls the ws verb it claims to delegate to.
#   3. A DESTRUCTIVE SCRIPT WITHOUT A GATE. check_destructive_gate proves --dry-run exists, exits
#      before the first mutation, and that a non-TTY run without --yes refuses.
#   4. `set -e` + `cond && cmd` KILLS THE SCRIPT when it is the last statement of a function called as
#      a bare command — ogsr-uninstall.sh printed "[3/8]" and stopped, silently skipping every
#      reversal step, for exactly this. check_no_and_list_shape forbids the shape outright rather than
#      asking a reader to decide whether a given instance is currently fatal.
#   5. THE COPIES COME BACK. The shared helpers were a byte-identical block in both scripts before
#      they were a library. check_lib_is_single_source proves both callers source it and that neither
#      re-defines a function it already provides — a local re-definition silently overrides the
#      library for that caller only, which is the six-copied-walkers bug in miniature.
#
#   bash tools/lint/cohort-ops-guard.sh              → the real tree (rc 0 clean · 1 finding · 2 could not inspect)
#   bash tools/lint/cohort-ops-guard.sh --self-test  → every detector catches its own canary (rc 1)
set -uo pipefail

LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LINT_DIR}/../.." && pwd)"

# shellcheck source=tools/lint/_extract-func.sh
source "${LINT_DIR}/_extract-func.sh"
# shellcheck source=tools/lint/_check-coverage.sh
source "${LINT_DIR}/_check-coverage.sh"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "${LINT_DIR}/_parse-guard-args.sh"

# Set by run_check so the detectors can be pointed at canary fixtures instead of the real tree.
WIPE_SH=""
RESET_SH=""
LIB_SH=""

fail()  { echo "❌ $*" >&2; }
note()  { echo "   $*" >&2; }
pass()  { echo "✅ $*"; }

# ── detectors ────────────────────────────────────────────────────────────────────────────────────

check_no_selfheal_fight() {  # → 1 when a script deletes/patches what workshop-config owns
  ran_check
  local f base rc=0 hits
  for f in "$WIPE_SH" "$RESET_SH"; do
    base="$(basename "$f")"
    # Hand-deleting a per-user Namespace/Project. Argo re-creates it from userCount within seconds.
    # `oc delete ns -l …` is caught by the same pattern on purpose: a label selector does not make the
    # deletion survive self-heal, it just deletes more of them.
    hits="$(grep -nE '^[^#]*oc[[:space:]]+delete[[:space:]]+(ns|namespace|namespaces|project|projects)\b' "$f" || true)"
    if [[ -n "$hits" ]]; then
      fail "${base}: deletes a Namespace/Project by hand — workshop-config (prune:true selfHeal:true) re-creates it within seconds."
      note "The ONLY removal that survives is lowering userCount and letting Argo prune: delegate to 'ws scale-users N'."
      note "$hits"
      rc=1
    fi
    # Patching userCount here would duplicate ws scale-users' patch WITHOUT its sync discipline
    # (never sync while an operation is Running; hard refresh, settle, then sync).
    hits="$(grep -nE '^[^#]*(oc[[:space:]]+patch[[:space:]]+application|userCount.*\"value\"|/helm/parameters/)' "$f" | grep -v 'read the workshop-config' || true)"
    if [[ -n "$hits" ]]; then
      fail "${base}: patches the workshop-config Application (or its helm parameters) directly."
      note "That patch and its Argo sync discipline belong to tools/ws/ws cmd_scale_users. Delegate instead."
      note "$hits"
      rc=1
    fi
  done
  return "$rc"
}

check_ws_delegation() {  # → 1 when a script stopped delegating its engine half to ws
  ran_check
  local rc=0
  # The trailing [[:space:]] is load-bearing: without it a typo'd 'scale-usersX' still matches the
  # prefix and the canary that proves this detector works passes for the wrong reason.
  # shellcheck disable=SC2016  # a grep PATTERN: $WS_BIN must stay literal, not expand to this
  # guard's own (empty) variable.
  if ! grep -qE '\$WS_BIN"?[[:space:]]+scale-users[[:space:]]' "$WIPE_SH"; then
    fail "$(basename "$WIPE_SH"): never invokes 'ws scale-users' — the cohort prune has been re-implemented or dropped."
    note "Lowering userCount, the SEV1-safe purge ordering and the htpasswd rewrite all live in cmd_scale_users."
    rc=1
  fi
  # shellcheck disable=SC2016  # grep PATTERN, see above.
  if ! grep -qE '\$WS_BIN"?[[:space:]]+cohort-reset[[:space:]]' "$RESET_SH"; then
    fail "$(basename "$RESET_SH"): never invokes 'ws cohort-reset' — the per-module purge has been re-implemented or dropped."
    note "purgeNamespaces / purgeAppsNamespace / purgeAppsProject are declared per module in gitops/entry-states/*/ws-meta.yaml and driven by ws."
    rc=1
  fi
  return "$rc"
}

check_destructive_gate() {  # → 1 when --dry-run or the confirmation gate is missing/ineffective
  ran_check
  local f base rc=0
  for f in "$WIPE_SH" "$RESET_SH"; do
    base="$(basename "$f")"
    if ! grep -q -- '--dry-run)' "$f"; then
      fail "${base}: no --dry-run option. A destructive cluster-wide operation must be able to print its plan first."
      rc=1
    fi
    # The dry-run branch must LEAVE, not fall through into the mutations below it. awk, not
    # `grep -Pzo`: -P is a GNU extension, so a PCRE version of this check would inspect one thing on
    # CI's ubuntu-latest and something else on a maintainer's macOS — an unrun gate wearing a green
    # tick. An 'exit 0' at the script's own indent level, AFTER the DRY_RUN test, is the condition.
    if ! awk '/DRY_RUN.*==.*"true"/{found=1} found && /^  exit 0$/{ok=1} END{exit !ok}' "$f"; then
      fail "${base}: the --dry-run branch never reaches an 'exit 0' — a dry run would fall through into the real mutations."
      rc=1
    fi
    if ! grep -q 'confirm_or_exit' "$f"; then
      fail "${base}: no confirm_or_exit call — the operation would run unconfirmed."
      rc=1
    fi
  done
  # And the gate itself must still refuse a non-TTY run that did not pass --yes. Checked in the
  # library, where the one implementation lives.
  local body
  body="$(extract_func "$LIB_SH" confirm_or_exit)"
  if [[ -z "$body" ]]; then
    fail "$(basename "$LIB_SH"): confirm_or_exit() could not be extracted — the gate cannot be inspected."
    return 2
  fi
  if ! grep -q '\-t 0' <<< "$body"; then
    fail "$(basename "$LIB_SH"): confirm_or_exit() no longer checks for a TTY — a piped run would proceed without confirmation."
    rc=1
  fi
  if ! grep -q 'die' <<< "$body"; then
    fail "$(basename "$LIB_SH"): confirm_or_exit() no longer refuses the non-TTY, no --yes case."
    rc=1
  fi
  return "$rc"
}

check_no_and_list_shape() {  # → 1 on `cond && cmd` — fatal under set -e inside a bare-called function
    ran_check
  local f base rc=0 hits
  for f in "$WIPE_SH" "$RESET_SH" "$LIB_SH"; do
    base="$(basename "$f")"
    # `[[ … ]] && cmd` / `[ … ] && cmd` as a statement. `cmd || true` and `if [[ … ]]; then` are fine;
    # so is `a && b` inside an `if` condition, which is why the match is anchored to a statement start.
    hits="$(grep -nE '^[[:space:]]*(\[\[|\[)[^#]*(\]\]|\])[[:space:]]*&&' "$f" || true)"
    if [[ -n "$hits" ]]; then
      fail "${base}: uses the '[[ cond ]] && cmd' statement shape."
      note "As the last statement of a function called as a bare command, the AND-list returns 1, the"
      note "function returns 1, and set -e kills the script mid-way — ogsr-uninstall.sh printed '[3/8]'"
      note "and stopped, silently skipping steps 4-8, for exactly this. Convert it to an if block."
      note "$hits"
      rc=1
    fi
  done
  return "$rc"
}

check_lib_is_single_source() {  # → 1 when a caller stops sourcing the lib, or shadows one of its functions
  ran_check
  local f base rc=0 fn body lib_fns
  lib_fns="$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$LIB_SH" | sed 's/()$//' | sort -u)"
  if [[ -z "$lib_fns" ]]; then
    fail "$(basename "$LIB_SH"): no functions found — the library could not be inspected."
    return 2
  fi
  for f in "$WIPE_SH" "$RESET_SH"; do
    base="$(basename "$f")"
    if ! grep -qE '^source .*ogsr-cohort-lib\.sh' "$f"; then
      fail "${base}: does not source bootstrap/ogsr-cohort-lib.sh — the shared helpers have been copied back in."
      note "Six hand-copied walkers in tools/lint/ were deduplicated on 2026-07-31: five shared a bug the"
      note "sixth had already fixed, invisible because each copy looked correct on its own. One definition."
      rc=1
      continue
    fi
    while IFS= read -r fn; do
      if [[ -z "$fn" ]]; then
        continue
      fi
      body="$(extract_func "$f" "$fn")"
      if [[ -n "$body" ]]; then
        fail "${base}: re-defines ${fn}(), which bootstrap/ogsr-cohort-lib.sh already provides."
        note "A local re-definition silently overrides the library for THIS caller only — the two"
        note "operations then behave differently while both look correct in isolation. Delete it, or"
        note "move the change into the library so both callers get it."
        rc=1
      fi
    done <<< "$lib_fns"
  done
  return "$rc"
}

# ── driver ───────────────────────────────────────────────────────────────────────────────────────
run_check() {  # <bootstrap-dir> → 0 clean · 1 finding · 2 could not inspect
  coverage_reset
  local dir="$1" rc=0 f
  WIPE_SH="${dir}/ogsr-wipe-users.sh"
  RESET_SH="${dir}/ogsr-reset.sh"
  LIB_SH="${dir}/ogsr-cohort-lib.sh"
  for f in "$WIPE_SH" "$RESET_SH" "$LIB_SH"; do
    if [[ ! -f "$f" ]]; then
      fail "${f} not found — this guard inspected nothing."
      return 2
    fi
  done

  local one=0
  check_no_selfheal_fight   || one=$?; if [[ "$one" -gt "$rc" ]]; then rc="$one"; fi
  one=0; check_ws_delegation       || one=$?; if [[ "$one" -gt "$rc" ]]; then rc="$one"; fi
  one=0; check_destructive_gate    || one=$?; if [[ "$one" -gt "$rc" ]]; then rc="$one"; fi
  one=0; check_no_and_list_shape   || one=$?; if [[ "$one" -gt "$rc" ]]; then rc="$one"; fi
  one=0; check_lib_is_single_source || one=$?; if [[ "$one" -gt "$rc" ]]; then rc="$one"; fi

  if [[ "$rc" -ne 2 ]]; then
    assert_all_checks_ran || rc=2
  fi
  return "$rc"
}

# ── canaries ─────────────────────────────────────────────────────────────────────────────────────
# Each canary is a REAL copy of the tree's own scripts with one specific defect injected, so a canary
# can never pass for a reason unrelated to the defect (an empty file would trip every detector at
# once and prove nothing about any of them).
_canary_dir() {  # <sed-target-file> <sed-expr> → a temp bootstrap dir with that edit applied
  local target="$1" expr="$2" d
  d="$(mktemp -d)"
  cp "${REPO_ROOT}/bootstrap/ogsr-wipe-users.sh" \
     "${REPO_ROOT}/bootstrap/ogsr-reset.sh" \
     "${REPO_ROOT}/bootstrap/ogsr-cohort-lib.sh" "$d/"
  if [[ -n "$target" ]]; then
    sed -i.bak "$expr" "${d}/${target}"
    rm -f "${d}/${target}.bak"
  fi
  printf '%s' "$d"
}

_expect_rc() {  # <label> <want-rc> <dir> → 0 when run_check returned exactly want-rc
  local label="$1" want="$2" dir="$3" got=0
  run_check "$dir" >/dev/null 2>&1 || got=$?
  rm -rf "$dir"
  if [[ "$got" -ne "$want" ]]; then
    fail "SELF-TEST FAILED: ${label} → rc=${got}, expected ${want}."
    return 1
  fi
  return 0
}

self_test() {
  local bad=0 d

  # Proof 0: the REAL tree passes. A guard that fires on everything proves nothing.
  if ! _expect_rc "the real bootstrap/ tree is clean" 0 "$(_canary_dir '' '')"; then
    fail "run 'bash tools/lint/cohort-ops-guard.sh' without --self-test to see the finding."
    return 2
  fi

  # Canary A — hand-deleting a namespace instead of lowering userCount (the self-heal trap).
  d="$(_canary_dir ogsr-reset.sh '1a\
oc delete ns user3-dev')"
  if ! _expect_rc "canary A (hand namespace delete)" 1 "$d"; then bad=1; fi

  # Canary A' — patching the workshop-config Application directly instead of delegating.
  d="$(_canary_dir ogsr-wipe-users.sh '1a\
oc patch application workshop-config -n openshift-gitops --type=json -p "[]"')"
  if ! _expect_rc "canary A2 (direct workshop-config patch)" 1 "$d"; then bad=1; fi

  # Canary B — the ws delegation removed (a re-implemented engine that will drift).
  d="$(_canary_dir ogsr-reset.sh 's/cohort-reset --yes/cohort-resetX --yes/g')"
  if ! _expect_rc "canary B (ws cohort-reset delegation dropped)" 1 "$d"; then bad=1; fi

  # Canary C — the dry-run branch no longer exits, so a dry run falls through into the mutations.
  d="$(_canary_dir ogsr-wipe-users.sh 's/^  exit 0$/  : /')"
  if ! _expect_rc "canary C (dry-run falls through)" 1 "$d"; then bad=1; fi

  # Canary C' — the confirmation gate stops refusing a non-TTY run.
  d="$(_canary_dir ogsr-cohort-lib.sh 's/if \[\[ ! -t 0 \]\]; then/if false; then/')"
  if ! _expect_rc "canary C2 (non-TTY confirmation gate defanged)" 1 "$d"; then bad=1; fi

  # Canary D — the set -e AND-list shape reintroduced.
  # shellcheck disable=SC2016  # sed PROGRAM text: $x is fixture source, not an expansion.
  d="$(_canary_dir ogsr-cohort-lib.sh '1a\
[[ -n "$x" ]] && echo hi')"
  if ! _expect_rc "canary D (set -e '&&' statement shape)" 1 "$d"; then bad=1; fi

  # Canary E — a caller stops sourcing the library.
  d="$(_canary_dir ogsr-reset.sh 's|^source .*ogsr-cohort-lib.sh|: |')"
  if ! _expect_rc "canary E (library no longer sourced)" 1 "$d"; then bad=1; fi

  # Canary E' — a caller shadows a library function with its own copy. This is the exact shape the
  # byte-identical-block design would have re-introduced, and no other detector sees it.
  d="$(_canary_dir ogsr-wipe-users.sh '1a\
gitea_connect() {\
  return 1\
}')"
  if ! _expect_rc "canary E2 (library function shadowed by a local copy)" 1 "$d"; then bad=1; fi

  # Canary F — the coverage assertion itself: a detector that is declared but never called must be
  # caught as rc=2, not silently tolerated.
  local cov=0
  (
    # Declared to be seen by `declare -F` and DELIBERATELY never called — that is the whole canary.
    # SC2317 on 0.9.x, SC2329 on >=0.10: both are named so the directive works on CI and locally.
    # shellcheck disable=SC2317,SC2329
    check_never_called() { ran_check; return 0; }
    run_check "${REPO_ROOT}/bootstrap" >/dev/null 2>&1
  ) || cov=$?
  if [[ "$cov" -ne 2 ]]; then
    fail "SELF-TEST FAILED: a declared-but-never-called detector was not caught (rc=${cov}) — the coverage assertion is inert."
    bad=1
  fi

  if [[ "$bad" -ne 0 ]]; then
    return 2
  fi
  pass "self-test ok — self-heal fight, dropped delegation, fall-through dry run, defanged gate, '&&' shape, unsourced library, shadowed helper and an uncalled detector all caught."
  # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
  return 1
}

# Rejects anything that is not --self-test / -h / --help, naming the offender, exit 2. Before this
# existed a one-hyphen typo (`--selftest`) silently ran the plain check and printed a green tick.
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

RC=0
run_check "${REPO_ROOT}/bootstrap" || RC=$?
if [[ "$RC" -eq 0 ]]; then
  pass "cohort ops: no self-heal fight, both engines delegated to ws, dry-run + confirmation gates intact, no set -e '&&' shapes, one shared library with no shadowed helpers."
fi
exit "$RC"
