#!/usr/bin/env bash
# _check-coverage.sh — proves a guard's DRIVER still calls every detector the guard DECLARES.
#
# ORIGIN (2026-08-01). The house rule "every guard ships a canary and CI asserts --self-test exits
# EXACTLY 1" has a hole, found by an audit that blinded each detector in turn: exit 1 proves
# SOMETHING was detected, not that EACH detector works — and it proves nothing at all about the
# DRIVER. Measured on six guards, fifteen call sites: deleting a `check_*` CALL from run_check()
# (as opposed to breaking the check function itself) left --self-test at 1 AND the real run at 0.
# Every canary still fired, because self_test() calls the detectors DIRECTLY; only run_check() had
# stopped calling one. Two of those guards gate a destructive teardown on clusters we do not own.
#
# THE MECHANISM. Each detector records the fact that it ran; the driver asserts, at the end of every
# run, that every detector it DECLARES was recorded. The expectation is derived from `declare -F`,
# not from a hand-maintained list and not from the driver's own source — so it cannot be satisfied
# by the same edit that breaks it, and a NEW detector is covered the moment it is written:
#
#   • a new check_*() that run_check() forgot to call        → assert fires (declared, never ran)
#   • a new check_*() that forgot its own `ran_check` line   → assert fires (declared, never ran)
#   • an existing call site deleted                          → assert fires
#
# All three land as rc=2 ("the guard could not inspect what it claims to inspect"), so the plain run
# stops being 0 and --self-test's "Proof 0: the real tree passes" stops being 1. CI's exit-exactly-1
# assertion catches it either way.
#
# WIRING (three lines per guard):
#   source .../_check-coverage.sh          # next to the _extract-func.sh source line
#   check_foo() { ran_check; … }           # FIRST statement of every detector
#   run_check() { coverage_reset; …; if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi }
#
# A detector legitimately called more than once per run (a per-target loop) declares its
# multiplicity: CHECK_COVERAGE_EXPECT="check_carried_keys=2" — space-separated fn=N pairs. Getting
# that number wrong is loud, never silent.
#
# Runnable standalone, like _extract-func.sh:
#   bash tools/lint/_check-coverage.sh              → META-SCAN: every *-guard.sh in tools/lint/ that
#                                                     has a run_check() and check_*() detectors is
#                                                     actually wired to this file (rc 0 = all wired).
#                                                     That is what stops the fix itself from rotting
#                                                     as guards are added.
#   bash tools/lint/_check-coverage.sh --self-test  → the assertion catches a blinded driver, stays
#                                                     silent on a wired one, and the meta-scan catches
#                                                     an unwired guard (rc 1 = every canary caught).
# Sourcing (the normal path, from a guard) runs neither.

_COVERAGE_LOG=""

_cov_err() { echo "❌ $*" >&2; }
_cov_note() { echo "   $*" >&2; }

# Clear the ledger. Called at the top of run_check() so each run is judged on its own.
coverage_reset() { _COVERAGE_LOG=""; }

# Record that the calling detector executed. With no argument it records its CALLER's name, so the
# line is copy-paste identical in every detector and cannot drift from the function it sits in.
# shellcheck disable=SC2120  # the name arg is OPTIONAL by design: with none, the function
# records its CALLER, which is what every detector uses. Call sites that pass nothing are
# correct, so SC2119/SC2120 are noise here rather than a finding.
ran_check() {  # [name] ->
  local name="${1:-}"
  if [[ -z "$name" ]]; then name="${FUNCNAME[1]:-<top-level>}"; fi
  _COVERAGE_LOG="${_COVERAGE_LOG}${name}"$'\n'
}

# Every function named check_* currently defined in this shell. This is the expectation, and it is
# derived from the DECLARATIONS — the one place a deleted call site cannot also edit.
_coverage_declared() {
  declare -F | awk '{print $NF}' | grep -E '^check_' | sort -u
}

assert_all_checks_ran() {  # → 0 every declared detector ran as often as expected, 2 otherwise
  local fn want got pair declared rc=0
  declared="$(_coverage_declared)" || declared=""
  if [[ -z "$declared" ]]; then
    _cov_err "COVERAGE: no check_* detector functions are declared in this guard."
    _cov_note "This assertion derives its expectation from the declared detectors; with none"
    _cov_note "declared it can prove nothing. Name the detectors check_* or drop the assertion."
    return 2
  fi

  while IFS= read -r fn; do
    [[ -n "$fn" ]] || continue
    want=1
    # Intentional word splitting: CHECK_COVERAGE_EXPECT is a space-separated list of fn=N pairs.
    # shellcheck disable=SC2086
    for pair in ${CHECK_COVERAGE_EXPECT:-}; do
      if [[ "${pair%%=*}" == "$fn" ]]; then want="${pair##*=}"; fi
    done
    got="$(printf '%s' "$_COVERAGE_LOG" | grep -cxF -- "$fn")" || got=0
    if [[ "$got" -ne "$want" ]]; then
      _cov_err "COVERAGE: detector ${fn}() ran ${got}×, expected ${want}× — the driver no longer calls it as declared."
      _cov_note "A dropped call site is invisible to every canary: --self-test calls the detectors"
      _cov_note "directly, so they all still pass while the real run silently stops checking. Re-wire"
      _cov_note "${fn} in run_check(), or delete the function."
      if [[ "$got" -gt 0 ]]; then
        _cov_note "If ${fn} is genuinely meant to run ${got}× per run, say so: CHECK_COVERAGE_EXPECT=\"${fn}=${got}\"."
      fi
      rc=2
    fi
  done <<< "$declared"
  return "$rc"
}

# ── meta-scan: are the guards themselves wired? ───────────────────────────────────────────────────
# Static, deliberately: it must hold for guards this process never runs. A guard qualifies if it has
# a run_check() driver AND at least one check_*() detector — the exact shape the audit broke.
coverage_wiring_scan() {  # <lint-dir> → 0 all wired, 1 a guard is unwired, 2 nothing inspected
  local dir="$1" f base n=0 rc=0 body fn fnbody
  for f in "$dir"/*-guard.sh; do
    [[ -f "$f" ]] || continue
    grep -q '^run_check()' "$f" || continue
    grep -qE '^check_[A-Za-z0-9_]*\(\)' "$f" || continue
    base="$(basename "$f")"
    n=$((n + 1))

    if ! grep -q '_check-coverage.sh' "$f"; then
      _cov_err "WIRING: ${base} has a run_check() driver and check_*() detectors but never sources _check-coverage.sh."
      _cov_note "Without it, deleting a check_* call from run_check() leaves --self-test at 1 and the"
      _cov_note "real run at 0 — the detector is silently unwired. See the header of this file."
      rc=1
      continue
    fi

    body="$(extract_func "$f" run_check)"
    if ! grep -q 'coverage_reset' <<< "$body"; then
      _cov_err "WIRING: ${base}'s run_check() does not call coverage_reset — the ledger carries over between runs."
      rc=1
    fi
    if ! grep -q 'assert_all_checks_ran' <<< "$body"; then
      _cov_err "WIRING: ${base}'s run_check() does not call assert_all_checks_ran — nothing proves it still calls its detectors."
      rc=1
    fi

    while IFS= read -r fn; do
      [[ -n "$fn" ]] || continue
      fnbody="$(extract_func "$f" "$fn")"
      if [[ -z "$fnbody" ]]; then
        _cov_err "WIRING: ${base}'s ${fn}() could not be extracted — the scan cannot inspect what it claims to."
        rc=1
        continue
      fi
      if ! grep -q 'ran_check' <<< "$fnbody"; then
        _cov_err "WIRING: ${base}'s ${fn}() never calls ran_check — it would count as 'never ran' and the assertion would fire on a healthy tree."
        rc=1
      fi
    done < <(grep -oE '^check_[A-Za-z0-9_]*' "$f" | sort -u)
  done

  if [[ "$n" -eq 0 ]]; then
    _cov_err "WIRING: no guard with a run_check() driver was found under ${dir} — the scan inspected nothing."
    return 2
  fi
  if [[ "$rc" -eq 0 ]]; then
    echo "✅ wiring: ${n} guard(s) with a run_check() driver, every declared detector registered and asserted"
  fi
  return "$rc"
}

# ── standalone ───────────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  _COV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=tools/lint/_extract-func.sh
  source "${_COV_DIR}/_extract-func.sh"

  # Runtime probe: run a fake driver that calls SOME of the detectors declared in a subshell, and
  # report what assert_all_checks_ran made of it. `blind` names the detector whose call is dropped.
  _cov_probe() {  # <blind|none> [expect-pairs] → rc of assert_all_checks_ran
    (
      check_alpha() { ran_check; return 0; }
      check_beta()  { ran_check; return 0; }
      CHECK_COVERAGE_EXPECT="${2:-}"
      coverage_reset
      check_alpha
      if [[ "$1" != "check_beta" ]]; then check_beta; fi
      if [[ "${3:-}" == "twice" ]]; then check_beta; fi
      assert_all_checks_ran >/dev/null 2>&1
    )
  }

  if [[ "${1:-}" == "--self-test" ]]; then
    # Proof 0: the real tree is wired. An assertion that fires on everything proves nothing either.
    _real_rc=0
    coverage_wiring_scan "$_COV_DIR" >/dev/null 2>&1 || _real_rc=$?
    if [[ "$_real_rc" -ne 0 ]]; then
      _cov_err "SELF-TEST FAILED: tools/lint is not fully wired (rc=${_real_rc}). Run without --self-test."
      exit 2
    fi

    # Canary A — the audit's exact move: a declared detector whose call site is gone.
    _rc=0; _cov_probe check_beta || _rc=$?
    if [[ "$_rc" -ne 2 ]]; then
      _cov_err "SELF-TEST FAILED: a declared detector that never ran was NOT caught (rc=${_rc}) — the assertion is blind."
      exit 2
    fi

    # Canary B — the healthy shape must stay SILENT, or every guard reddens for no reason.
    _rc=0; _cov_probe none || _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      _cov_err "SELF-TEST FAILED: a fully-wired driver was reported as broken (rc=${_rc}) — the assertion cries wolf."
      exit 2
    fi

    # Canary C — multiplicity: a detector declared to run twice, run once, is a dropped call site.
    _rc=0; _cov_probe none "check_beta=2" || _rc=$?
    if [[ "$_rc" -ne 2 ]]; then
      _cov_err "SELF-TEST FAILED: a detector declared 2× but run 1× was NOT caught (rc=${_rc}) — CHECK_COVERAGE_EXPECT is decorative."
      exit 2
    fi
    _rc=0; _cov_probe none "check_beta=2" twice || _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      _cov_err "SELF-TEST FAILED: a detector declared 2× and run 2× was reported as broken (rc=${_rc})."
      exit 2
    fi

    # Canary D — the meta-scan catches a guard that has detectors and a driver but no wiring. Built
    # as a real file, because that is what the scan reads.
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    cat > "${_tmp}/unwired-guard.sh" <<'FIXTURE'
#!/usr/bin/env bash
check_thing() { return 0; }
run_check() { check_thing; return $?; }
FIXTURE
    _rc=0; coverage_wiring_scan "$_tmp" >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 1 ]]; then
      _cov_err "SELF-TEST FAILED: an unwired guard was NOT caught by the meta-scan (rc=${_rc})."
      exit 2
    fi

    # Canary E — and it stays silent on a correctly wired one, so the scan is not just "always fails".
    rm -f "${_tmp}/unwired-guard.sh"
    cat > "${_tmp}/wired-guard.sh" <<'FIXTURE'
#!/usr/bin/env bash
source "$(dirname "$0")/_check-coverage.sh"
check_thing() { ran_check; return 0; }
run_check() {
  coverage_reset
  local rc=0
  check_thing || rc=1
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}
FIXTURE
    _rc=0; coverage_wiring_scan "$_tmp" >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      _cov_err "SELF-TEST FAILED: a correctly wired guard was reported unwired (rc=${_rc}) — the meta-scan cries wolf."
      exit 2
    fi

    echo "✅ self-test ok — dropped call site caught, wired driver silent, multiplicity enforced, unwired guard caught, wired guard silent."
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    exit 1
  fi

  coverage_wiring_scan "$_COV_DIR"
  exit $?
fi
