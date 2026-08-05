#!/usr/bin/env bash
# verify-summary-skip-guard.sh — the attendee verify banner may not claim a pass it did not grade.
#
# ORIGIN (2026-07-31, full 26/26 audit of tools/verify/). _lib.sh has THREE outcomes — pass, fail and
# warn (INCONCLUSIVE: a check this caller cannot evaluate) — and verify_summary knew only TWO. warn()
# deliberately did not touch the counters, so a run in which every GRADED outcome was skipped still
# ended:
#
#     ✅ all 7 checks passed        (exit 0)
#
# In multi-tenancy-workload-security.sh all six end-state RBAC outcomes — the entire lesson — sit
# behind one IMPERSONATE_OK guard; a caller without that capability graded nothing and was told it
# passed. securing-apps-keycloak.sh printed, verbatim, "this is NOT a pass" and the banner then said
# it was. Eleven of twenty-six scripts had the shape.
#
# The defect was never warn(). The project's rule is that a false ❌ destroys attendee trust in every
# other ✅, so a check that genuinely cannot run must NOT fail — every author who reached for warn was
# right. What overstated the run was the BANNER. This guard therefore pins BOTH halves: the banner
# must tell the truth, AND a skip must still never become a failure.
#
# WHAT IT CHECKS — by EXECUTING the real warn()/verify_summary() from tools/verify/_lib.sh under a
# harness that runs `set -euo pipefail`, exactly like the scripts that source it:
#   [1] SKIP IS COUNTED. N warn calls are reported as N skipped. Also proves warn() is safe under
#       `set -e`: `((VERIFY_SKIP++))` returns 1 on the first call, which kills a sourcing script
#       outright — the harness would then produce no banner at all.
#   [2] BANNER HONESTY. pass>0 with skips must NOT print "all N checks passed"; it must name the skip
#       count and mark it ungraded. A clean run (no skips) MUST still print the plain green claim —
#       a gate that demanded a caveat on every run would just be trained away. Failures + skips
#       report both.
#   [3] EXIT CONTRACT. Skipped-but-nothing-failed exits 0 BY DEFAULT and that is load-bearing:
#       tools/ws/ws cmd_prep reads `<script> --entry-only`'s rc as a boolean "is this world already
#       prepared?", and a non-zero rc tells the attendee their healthy environment is broken and
#       offers to WIPE it; ws smoke reads the same rc as a G1 ❌. Automation that must fail closed
#       opts in with VERIFY_STRICT=1 → rc 3, distinct from 1 (a check FAILED) and 2 (usage error).
#   [4] WS DOCTOR'S RC MAPPING. `ws doctor` (tools/ws/ws) is the first opted-in caller: its "entry
#       verify (strict)" row runs a module's verify script under VERIFY_STRICT=1 and classifies the rc
#       through doctor_verify_rc_outcome(). Executed the real function, extracted like [1]-[3] extract
#       the real _lib.sh: rc 3 must map to skip (never fail) — a doctor that turned VERIFY_STRICT's
#       information back into a false failure would defeat the reason it opted in.
#
# Runnable standalone (CI lint gate) and by hand; needs nothing but bash + grep + sed + awk.
#
# --self-test plants four canaries, each a real regression shape: the pre-fix counter-blind warn()
# for [1], the pre-fix two-outcome verify_summary() for [2], a strict-by-default flip for [3], and
# ws doctor's classifier miscounting rc 3 as fail for [4]. Exit 1 = every canary was caught AND the
# real tree is clean under the same detectors; that is a PASS, matching the house convention where CI
# asserts the self-test step exits exactly 1. Exit 2 = a detector is blind, or the harness is broken.
#
# Exit codes:
#   0  contract holds
#   1  contract broken — or, under --self-test, every canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (extraction failed, file missing)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/lint/_extract-func.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_extract-func.sh"
# shellcheck source=tools/lint/_check-coverage.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-coverage.sh"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_parse-guard-args.sh"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }

LIB="tools/verify/_lib.sh"
# `ws doctor` (2026-08-01) gained its own VERIFY_STRICT=1 call site — an "entry verify (strict)" row
# — and the rc it gets back is classified by a standalone doctor_verify_rc_outcome() precisely so this
# guard can pin it the same way it pins _lib.sh's own verify_summary, instead of a second guard file.
WS_CLI="tools/ws/ws"

# ── harness ───────────────────────────────────────────────────────────────────
# The library is EXECUTED, not pattern-matched: the only thing that matters is what an attendee sees
# and what a caller's `if` branches on. _lib.sh is safe to source (it defines functions and sets
# counters, nothing else), but the functions are extracted anyway so a canary copy of one of them can
# be swapped in for the real one — that is what makes the self-test possible.
# `set -euo pipefail` in the harness mirrors every real verify script's own header.
run_case() {  # warn_file summary_file pass fail warns strict [na_file] [nas] → banner on stdout, rc
  local warn_file="$1" summary_file="$2" pass="$3" fail="$4" warns="$5" strict="$6"
  local na_file="${7:-}" nas="${8:-0}"
  local harness rc=0
  harness="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo "export VERIFY_STRICT='${strict}'"
    # VERIFY_NA is deliberately NOT initialised unless the case supplies na(). _lib.sh does set it,
    # but verify_summary must survive being read with it unset — so cases [1]-[4] run with it UNSET,
    # and that is precisely what pins the `${VERIFY_NA:-0}` read. A bare $VERIFY_NA there aborts the
    # harness under `set -u` and detector [1] reports "produced NO banner at all". Case [5] supplies both.
    echo 'VERIFY_PASS=0; VERIFY_FAIL=0; VERIFY_SKIP=0'
    cat "$warn_file"
    if [[ -n "$na_file" ]]; then
      echo 'VERIFY_NA=0'
      cat "$na_file"
    fi
    cat "$summary_file"
    echo "VERIFY_PASS=${pass}"
    echo "VERIFY_FAIL=${fail}"
    # Skips are produced through the REAL warn(), never by poking the counter — the coupling between
    # "an author called warn" and "the banner knows" is half of what is being tested. Their output is
    # discarded so stdout carries the banner alone.
    # A C-style loop, not `seq 1 N`: BSD seq counts DOWN for `seq 1 0` and emitted two skips where
    # the case wanted none — the harness must be able to express "zero skips" exactly.
    echo "for ((_i=0; _i<${warns}; _i++)); do warn \"harness-skip \${_i}\" >/dev/null; done"
    # Not-applicables go through the REAL na(), for the same reason skips go through the real warn():
    # the coupling between "an author called na" and "the banner knows" is half of what [5] tests.
    if [[ -n "$na_file" ]]; then
      echo "for ((_j=0; _j<${nas}; _j++)); do na \"harness-na \${_j}\" >/dev/null; done"
    fi
    echo 'verify_summary'
  } > "$harness"
  bash "$harness" 2>/dev/null || rc=$?
  rm -f "$harness"
  return "$rc"
}

# "✅ all 7 checks passed" — the complete-pass claim, in the shape the banner has always printed it.
claims_complete_pass() { grep -qE 'all [0-9]+ checks passed' <<< "$1"; }
mentions_skip()        { grep -qiE 'skip' <<< "$1"; }
mentions_ungraded()    { grep -qiE 'not graded|did NOT fully verify' <<< "$1"; }
mentions_na()          { grep -qiE 'not applicable' <<< "$1"; }

# ── [1] a skip is counted ─────────────────────────────────────────────────────
check_skip_counted() {  # warn_file summary_file → 0 correct, 1 wrong
  ran_check
  local wf="$1" sf="$2" out rc=0 n
  for n in 1 3; do
    out="$(run_case "$wf" "$sf" 5 0 "$n" 0)"
    if [[ -z "$out" ]]; then
      bad "[1] ${n} warn call(s) produced NO banner at all — warn() aborted the run."
      note "    Under the callers' \`set -euo pipefail\` an arithmetic form such as ((VERIFY_SKIP++))"
      note "    returns 1 on the first call and kills the sourcing script. Use VERIFY_SKIP=\$((VERIFY_SKIP+1))."
      rc=1
      continue
    fi
    # The count must land on a line that ALSO mentions the skip: "⚠ 5 passed" carries digits of its
    # own, so a bare "does the banner contain N" would go green on a banner that never mentions skips.
    if ! grep -iE 'skip' <<< "$out" | grep -qE "(^|[^0-9])${n}([^0-9]|\$)"; then
      bad "[1] ${n} warn call(s) were not reported as ${n} skipped. Banner: ${out}"
      note "    warn() must increment VERIFY_SKIP — a skip the summary cannot see is a skip the attendee never hears about."
      rc=1
    fi
  done
  [[ "$rc" -eq 0 ]] && ok "[1] every warn() is counted, and warn() is safe under set -e"
  return "$rc"
}

# ── [2] the banner does not overstate the run ────────────────────────────────
check_banner_honesty() {  # warn_file summary_file → 0 correct, 1 wrong
  ran_check
  local wf="$1" sf="$2" out rc=0

  # (a) the 2026-07-31 defect verbatim: 7 graded passes, 6 ungraded outcome checks.
  out="$(run_case "$wf" "$sf" 7 0 6 0)"
  if claims_complete_pass "$out"; then
    bad "[2a] 6 checks were SKIPPED and the banner still claimed a complete pass: ${out}"
    note "    This is multi-tenancy-workload-security's whole lesson going ungraded behind one"
    note "    IMPERSONATE_OK guard while the attendee reads ✅ all 7 checks passed."
    rc=1
  elif ! mentions_skip "$out" || ! grep -q '6' <<< "$out"; then
    bad "[2a] the banner must name the 6 skipped checks. Banner: ${out}"; rc=1
  elif ! mentions_ungraded "$out"; then
    bad "[2a] the banner must say the skipped checks were NOT GRADED — 'skipped' alone reads as 'fine'. Banner: ${out}"; rc=1
  fi

  # (b) a genuinely complete run must still get the plain green claim. A gate that forced a caveat
  # onto every run would teach attendees to ignore the caveat, which is the same bug with extra steps.
  out="$(run_case "$wf" "$sf" 7 0 0 0)"
  if ! claims_complete_pass "$out"; then
    bad "[2b] a run with 0 skips and 0 failures must still print the plain '✅ all 7 checks passed'. Banner: ${out}"; rc=1
  fi

  # (c) failures and skips together: neither may hide the other.
  out="$(run_case "$wf" "$sf" 3 2 1 0)"
  if ! grep -q '2' <<< "$out" || ! mentions_skip "$out"; then
    bad "[2c] with 2 failures AND 1 skip the banner must report both. Banner: ${out}"; rc=1
  fi

  # (d) a skip must never be printed as a failure — the doctrine the fix must not trade away.
  out="$(run_case "$wf" "$sf" 7 0 6 0)"
  if grep -q '❌' <<< "$out"; then
    bad "[2d] a run with NO failures printed a ❌ banner: ${out}"
    note "    Turning skips into failures manufactures false ❌ across eleven modules — a false ❌"
    note "    destroys attendee trust in every other ✅ (tools/verify/README.md)."
    rc=1
  fi

  [[ "$rc" -eq 0 ]] && ok "[2] banner honesty: skips are named and marked ungraded, a clean run keeps its plain ✅, no false ❌"
  return "$rc"
}

# ── [3] exit contract ─────────────────────────────────────────────────────────
check_exit_contract() {  # warn_file summary_file → 0 correct, 1 wrong
  ran_check
  local wf="$1" sf="$2" rc=0 got

  # (a) DEFAULT: skips but no failures → rc 0. tools/ws/ws cmd_prep branches on this rc and offers a
  # destructive wipe when it is non-zero; ws smoke turns it into a G1 ❌. Neither file is editable
  # from a verify-script change, so the default must stay 0 and the BANNER carries the signal.
  got=0; run_case "$wf" "$sf" 7 0 6 0 >/dev/null || got=$?
  if [[ "$got" -ne 0 ]]; then
    bad "[3a] skips with no failures must exit 0 by default; got rc=${got}."
    note "    ws prep reads '<script> --entry-only' as a boolean and a non-zero rc tells an attendee"
    note "    with a healthy world that it is broken, then offers to WIPE it."
    rc=1
  fi

  # (b) STRICT: the machine-readable signal, opt-in so no existing caller changes behaviour.
  got=0; run_case "$wf" "$sf" 7 0 6 1 >/dev/null || got=$?
  if [[ "$got" -ne 3 ]]; then
    bad "[3b] VERIFY_STRICT=1 with skips must exit 3 (not 1 = a check FAILED, not 2 = usage); got rc=${got}."
    rc=1
  fi

  # (c) STRICT + clean → still 0. (d) STRICT + failure → 1, failure outranks skip.
  got=0; run_case "$wf" "$sf" 7 0 0 1 >/dev/null || got=$?
  [[ "$got" -ne 0 ]] && { bad "[3c] VERIFY_STRICT=1 on a fully-graded clean run must exit 0; got rc=${got}."; rc=1; }
  got=0; run_case "$wf" "$sf" 3 2 1 1 >/dev/null || got=$?
  [[ "$got" -ne 1 ]] && { bad "[3d] a failed check must exit 1 whether or not anything was skipped; got rc=${got}."; rc=1; }

  [[ "$rc" -eq 0 ]] && ok "[3] exit contract: default 0 (callers unbroken), VERIFY_STRICT=1 → 3 on skips, 1 on failure"
  return "$rc"
}

# ── [4] ws doctor's strict-mode rc → outcome mapping ─────────────────────────
# `ws doctor` opts into VERIFY_STRICT=1 on its "entry verify (strict)" row and reads the rc back
# through doctor_verify_rc_outcome() (tools/ws/ws). The whole point of that opt-in collapses if the
# mapping quietly turns rc 3 (skip-only) back into a doctor FAILURE — this executes the REAL function,
# extracted the same way [1]-[3] execute the real _lib.sh, so a regression there is caught here rather
# than only in a human reading doctor's output.
check_doctor_rc_mapping() {  # doctor_fn_file → 0 correct, 1 wrong
  ran_check
  local fn_file="$1" rc=0 pair code expect actual
  for pair in "0=pass" "3=skip" "1=fail" "2=fail"; do
    code="${pair%%=*}"; expect="${pair##*=}"
    actual="$(bash -c "$(cat "$fn_file"); doctor_verify_rc_outcome ${code}" 2>/dev/null)" || actual=""
    if [[ "$actual" != "$expect" ]]; then
      bad "[4] doctor_verify_rc_outcome ${code} => '${actual:-<empty>}', want '${expect}'."
      if [[ "$code" == "3" ]]; then
        note "    rc 3 is VERIFY_STRICT's skip-only signal — mapping it to fail would make ws doctor"
        note "    manufacture a failure out of information an operator asked for (owner decision: doctor"
        note "    and CI opt in, ws prep/ws smoke stay untouched)."
      fi
      rc=1
    fi
  done
  [[ "$rc" -eq 0 ]] && ok "[4] ws doctor's rc classifier: 0→pass, 3→skip (never fail), 1/2→fail"
  return "$rc"
}

# ── [5] not-applicable is a COMPLETE outcome, not a missing one ──────────────
# U8-F-03. warn() was carrying two meanings — "I could not evaluate this" and "this does not apply
# here" — and the banner could only report the pessimistic one, so a run in which everything gradeable
# WAS graded still told the attendee it "did NOT fully verify the lab". The exemplar is
# deployment-targets-scheduling's batch-pool taint, deliberately withheld by bootstrap below a
# 3-worker floor, whose own comment already read "not graded either way".
#
# The risk this detector exists to contain is the OPPOSITE one: na() must not become a quiet way to
# silence warn(). So (c) pins that a real skip still dominates a run that also has not-applicables.
check_na_semantics() {  # warn_file summary_file na_file → 0 correct, 1 wrong
  ran_check
  local wf="$1" sf="$2" nf="$3" out rc=0 got

  # (a) an NA-only run is COMPLETE: it keeps the plain green claim, does not call itself incomplete,
  #     and still accounts for the line the attendee can see above it.
  out="$(run_case "$wf" "$sf" 7 0 0 0 "$nf" 1)"
  if ! claims_complete_pass "$out"; then
    bad "[5a] 7 passed + 1 not-applicable must still print the plain '✅ all 7 checks passed'. Banner: ${out}"
    note "    A not-applicable check is not a MISSING one — the condition it grades does not exist here."
    rc=1
  fi
  if mentions_ungraded "$out"; then
    bad "[5a] an NA-only run must NOT say the run was ungraded/incomplete. Banner: ${out}"
    note "    This is U8-F-03 verbatim: a fully-graded run telling the attendee it 'did NOT fully verify'."
    note "    A caveat printed when nothing is wrong is a caveat attendees learn to ignore."
    rc=1
  fi
  if ! mentions_na "$out"; then
    bad "[5a] the banner must still ACCOUNT for the not-applicable check. Banner: ${out}"; rc=1
  fi

  # (b) the exit contract is UNCHANGED by not-applicables, including under VERIFY_STRICT=1. rc 3 means
  #     "something went ungraded" and that is simply false here; ws prep/ws smoke branch on this rc.
  got=0; run_case "$wf" "$sf" 7 0 0 0 "$nf" 1 >/dev/null || got=$?
  if [[ "$got" -ne 0 ]]; then bad "[5b] an NA-only run must exit 0; got rc=${got}."; rc=1; fi
  got=0; run_case "$wf" "$sf" 7 0 0 1 "$nf" 1 >/dev/null || got=$?
  if [[ "$got" -ne 0 ]]; then
    bad "[5b] VERIFY_STRICT=1 on an NA-only run must STILL exit 0 — rc 3 claims something went ungraded; got rc=${got}."
    rc=1
  fi

  # (c) THE ONE THAT MATTERS: a real skip still dominates. Otherwise na() is a laundering mechanism.
  out="$(run_case "$wf" "$sf" 7 0 2 0 "$nf" 1)"
  if claims_complete_pass "$out" || ! mentions_ungraded "$out"; then
    bad "[5c] 2 SKIPPED alongside 1 not-applicable must still report an INCOMPLETE run. Banner: ${out}"
    note "    If NA can mask a skip, na() becomes a way to silence warn() — the exact false green this"
    note "    whole banner design exists to prevent."
    rc=1
  fi
  got=0; run_case "$wf" "$sf" 7 0 2 1 "$nf" 1 >/dev/null || got=$?
  if [[ "$got" -ne 3 ]]; then
    bad "[5c] VERIFY_STRICT=1 with a real skip must still exit 3 regardless of not-applicables; got rc=${got}."; rc=1
  fi

  # (d) NA is counted, and na() is safe under set -e — the ((x++)) trap already pinned for warn().
  out="$(run_case "$wf" "$sf" 5 0 0 0 "$nf" 3)"
  if [[ -z "$out" ]]; then
    bad "[5d] 3 na() calls produced NO banner at all — na() aborted the run."
    note "    Under the callers' \`set -euo pipefail\` ((VERIFY_NA++)) returns 1 on the first call and"
    note "    kills the sourcing script. Use VERIFY_NA=\$((VERIFY_NA+1))."
    rc=1
  elif ! grep -iE 'not applicable' <<< "$out" | grep -qE "(^|[^0-9])3([^0-9]|\$)"; then
    bad "[5d] 3 na() calls were not reported as 3 not applicable. Banner: ${out}"; rc=1
  fi

  # (e) and it never manufactures a ❌ — the doctrine no outcome may trade away.
  out="$(run_case "$wf" "$sf" 7 0 0 0 "$nf" 3)"
  if grep -q '❌' <<< "$out"; then
    bad "[5e] a run with NO failures printed a ❌ banner: ${out}"; rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[5] not-applicable: a complete run keeps its plain ✅ and rc 0, a real skip still dominates, NA counted, never ❌"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
extract_pair() {  # lib_file warn_out summary_out → 0 ok, 2 extraction failed
  local lib="$1"
  extract_func "$lib" warn           > "$2"
  extract_func "$lib" verify_summary > "$3"
  if [[ ! -s "$2" || ! -s "$3" ]]; then
    bad "could not extract warn()/verify_summary() from ${lib} — the guard cannot inspect what it claims to."
    return 2
  fi
  return 0
}

extract_na() {  # lib_file na_out → 0 ok, 2 extraction failed
  extract_func "$1" na > "$2"
  if [[ ! -s "$2" ]]; then
    bad "could not extract na() from ${1} — the guard cannot inspect what it claims to."
    note "    na() is the fourth outcome (U8-F-03). If it was removed, detector [5] must go with it;"
    note "    a guard that silently stops inspecting an outcome is worse than no guard at all."
    return 2
  fi
  return 0
}

extract_doctor_fn() {  # ws_cli_file fn_out → 0 ok, 2 extraction failed
  local ws_cli="$1"
  extract_func "$ws_cli" doctor_verify_rc_outcome > "$2"
  if [[ ! -s "$2" ]]; then
    bad "could not extract doctor_verify_rc_outcome() from ${ws_cli} — the guard cannot inspect what it claims to."
    return 2
  fi
  return 0
}

run_check() {  # warn_file summary_file doctor_fn_file na_file → 0 clean, 1 broken
  coverage_reset
  local wf="$1" sf="$2" dff="$3" nf="$4" rc=0
  check_skip_counted  "$wf" "$sf" || rc=1
  check_banner_honesty "$wf" "$sf" || rc=1
  check_exit_contract  "$wf" "$sf" || rc=1
  check_doctor_rc_mapping "$dff" || rc=1
  check_na_semantics  "$wf" "$sf" "$nf" || rc=1
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Four canaries, each a real regression shape. All must be CAUGHT, and the real tree must be clean
# under the same detectors — anything else means the gate is decorative.
self_test() {
  local tmp wf sf dff nf real_rc got
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  wf="$tmp/warn.sh"; sf="$tmp/summary.sh"; dff="$tmp/doctor-rc.sh"; nf="$tmp/na.sh"
  extract_pair "${REPO_ROOT}/${LIB}" "$wf" "$sf" || return 2
  extract_na "${REPO_ROOT}/${LIB}" "$nf" || return 2
  extract_doctor_fn "${REPO_ROOT}/${WS_CLI}" "$dff" || return 2

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$wf" "$sf" "$dff" "$nf" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real ${LIB}/${WS_CLI} do not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # Canary A — the pre-fix warn(), verbatim: prints ⚠ and touches no counter.
  cat > "$tmp/warn-blind.sh" <<'CANARY'
warn() { echo "⚠ $* — SKIPPED (not a failure)"; }
CANARY
  got=0; check_skip_counted "$tmp/warn-blind.sh" "$sf" >/dev/null 2>&1 || got=$?
  if [[ "$got" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the counter-blind warn() canary was NOT detected (rc=${got}) — detector [1] is blind."
    return 2
  fi

  # Canary B — the pre-fix verify_summary(), verbatim: two outcomes, so six skipped checks vanish and
  # the run ends "✅ all 7 checks passed".
  cat > "$tmp/summary-two-outcome.sh" <<'CANARY'
verify_summary() {
  echo
  if (( VERIFY_FAIL == 0 )); then
    echo "✅ all ${VERIFY_PASS} checks passed"
    exit 0
  else
    echo "❌ ${VERIFY_FAIL} of $((VERIFY_PASS+VERIFY_FAIL)) checks failed"
    exit 1
  fi
}
CANARY
  got=0; check_banner_honesty "$wf" "$tmp/summary-two-outcome.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the two-outcome verify_summary() canary was NOT detected (rc=${got}) — detector [2] is blind."
    return 2
  fi

  # Canary C — the opposite over-correction: strict behaviour ON by default, so a skip exits non-zero
  # for every caller. Byte-for-byte the real function with the strict gate forced open.
  # shellcheck disable=SC2016  # ${VERIFY_STRICT:-0} is the LITERAL text being matched in the
  # extracted function — expanding it here would search for the guard's own environment instead.
  sed 's|if \[\[ "${VERIFY_STRICT:-0}" == "1" \]\]; then|if true; then|' "$sf" > "$tmp/summary-strict-default.sh"
  if ! grep -q 'if true; then' "$tmp/summary-strict-default.sh"; then
    bad "SELF-TEST FAILED: could not build the strict-by-default canary — the VERIFY_STRICT gate it mutates was not found."
    return 2
  fi
  got=0; check_exit_contract "$wf" "$tmp/summary-strict-default.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the strict-by-default canary was NOT detected (rc=${got}) — detector [3] is blind."
    return 2
  fi

  # Canary D — ws doctor's classifier miscounting rc 3 (skip-only) as fail instead of skip. Byte-for-
  # byte the real doctor_verify_rc_outcome() with its rc-3 arm changed from `skip` to `fail`.
  sed 's/3) echo skip ;;/3) echo fail ;;/' "$dff" > "$tmp/doctor-rc-miscounts-skip.sh"
  if ! grep -q '3) echo fail ;;' "$tmp/doctor-rc-miscounts-skip.sh"; then
    bad "SELF-TEST FAILED: could not build the doctor-rc-miscounts-skip canary — the rc-3 arm it mutates was not found."
    return 2
  fi
  got=0; check_doctor_rc_mapping "$tmp/doctor-rc-miscounts-skip.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the doctor-rc-miscounts-skip canary was NOT detected (rc=${got}) — detector [4] is blind."
    return 2
  fi

  # Canary E — the U8-F-03 defect itself, reintroduced: an na() that increments VERIFY_SKIP, i.e. the
  # conflation of "does not apply here" with "could not be evaluated". A fully-graded run then tells
  # the attendee it did NOT fully verify — exactly what user8 reported.
  cat > "$tmp/na-counts-as-skip.sh" <<'CANARY'
na() { echo "➖ $* — not applicable on this cluster (not a failure)"; VERIFY_SKIP=$((VERIFY_SKIP+1)); }
CANARY
  got=0; check_na_semantics "$wf" "$sf" "$tmp/na-counts-as-skip.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" -ne 1 ]]; then
    bad "SELF-TEST FAILED: an na() that counts as a SKIP was NOT detected (rc=${got}) — detector [5] is blind."
    return 2
  fi

  # Canary F — the reverse over-correction: na() laundering a genuine skip. If verify_summary let a
  # not-applicable outweigh a real warn(), an inconclusive run would print green. Built by making the
  # summary treat any NA as license to claim a complete pass.
  cat > "$tmp/summary-na-launders-skip.sh" <<'CANARY'
verify_summary() {
  echo
  if (( VERIFY_FAIL > 0 )); then
    echo "❌ ${VERIFY_FAIL} of $((VERIFY_PASS+VERIFY_FAIL)) checks failed"
    exit 1
  fi
  if (( ${VERIFY_NA:-0} > 0 )); then
    echo "✅ all ${VERIFY_PASS} checks passed (${VERIFY_NA} not applicable to this cluster)"
    exit 0
  fi
  if (( VERIFY_SKIP > 0 )); then
    echo "⚠ ${VERIFY_PASS} passed · ${VERIFY_SKIP} SKIPPED (not graded) — this run did NOT fully verify the lab"
    if [[ "${VERIFY_STRICT:-0}" == "1" ]]; then exit 3; fi
    exit 0
  fi
  echo "✅ all ${VERIFY_PASS} checks passed"
  exit 0
}
CANARY
  got=0; check_na_semantics "$wf" "$tmp/summary-na-launders-skip.sh" "$nf" >/dev/null 2>&1 || got=$?
  if [[ "$got" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a summary letting NA mask a real SKIP was NOT detected (rc=${got}) — detector [5c] is blind."
    note "    That shape turns na() into a way to silence warn(), which is a false green across every"
    note "    script that adopts it."
    return 2
  fi

  # Canary G — a bare \$VERIFY_NA read in verify_summary. Cases [1]-[4] deliberately run with the
  # counter UNSET, so under the callers' `set -u` this aborts before any banner is printed; detector
  # [1] is what notices. This is what keeps the `${VERIFY_NA:-0}` form from being "tidied" away.
  # shellcheck disable=SC2016  # matching the LITERAL ${VERIFY_NA:-0} text in the extracted function
  sed 's|${VERIFY_NA:-0}|$VERIFY_NA|g' "$sf" > "$tmp/summary-bare-na-read.sh"
  if ! grep -q 'VERIFY_NA' "$tmp/summary-bare-na-read.sh"; then
    bad "SELF-TEST FAILED: could not build the bare-VERIFY_NA canary — the guarded read it mutates was not found."
    return 2
  fi
  got=0; check_skip_counted "$wf" "$tmp/summary-bare-na-read.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a bare \$VERIFY_NA read was NOT detected (rc=${got}) — verify_summary would abort for any caller predating the counter."
    return 2
  fi

  ok "self-test ok — real ${LIB}/${WS_CLI} clean (rc=0); counter-blind warn, two-outcome banner, strict-by-default, doctor-rc-miscounts-skip, na-counts-as-skip, na-launders-skip and bare-NA-read canaries all caught."
  return 1
}

# Rejects anything that is not --self-test / -h / --help, naming the offender, exit 2. Before this
# existed a one-hyphen typo (`--selftest`) silently ran the plain check and printed a green tick.
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

if [[ ! -f "${REPO_ROOT}/${LIB}" ]]; then
  bad "${REPO_ROOT}/${LIB} not found"
  exit 2
fi
if [[ ! -f "${REPO_ROOT}/${WS_CLI}" ]]; then
  bad "${REPO_ROOT}/${WS_CLI} not found"
  exit 2
fi
WARN_FILE="$(mktemp)"; SUMMARY_FILE="$(mktemp)"; DOCTOR_FN_FILE="$(mktemp)"; NA_FILE="$(mktemp)"
extract_pair "${REPO_ROOT}/${LIB}" "$WARN_FILE" "$SUMMARY_FILE" \
  || { rm -f "$WARN_FILE" "$SUMMARY_FILE" "$DOCTOR_FN_FILE" "$NA_FILE"; exit 2; }
extract_na "${REPO_ROOT}/${LIB}" "$NA_FILE" \
  || { rm -f "$WARN_FILE" "$SUMMARY_FILE" "$DOCTOR_FN_FILE" "$NA_FILE"; exit 2; }
extract_doctor_fn "${REPO_ROOT}/${WS_CLI}" "$DOCTOR_FN_FILE" \
  || { rm -f "$WARN_FILE" "$SUMMARY_FILE" "$DOCTOR_FN_FILE" "$NA_FILE"; exit 2; }
RC=0
run_check "$WARN_FILE" "$SUMMARY_FILE" "$DOCTOR_FN_FILE" "$NA_FILE" || RC=$?
rm -f "$WARN_FILE" "$SUMMARY_FILE" "$DOCTOR_FN_FILE" "$NA_FILE"
exit "$RC"
