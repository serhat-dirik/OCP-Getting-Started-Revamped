#!/usr/bin/env bash
# operatorgroup-uniqueness-guard.sh — the OperatorGroup-singleton hard gate, gated.
#
# ORIGIN. bootstrap/install.sh's assert_single_operatorgroup() is the last thing standing between an
# install and the exact defect that cost a silently-unmanaged adopted cert-manager on a test cluster
# (2026-07-25): our component applied its own OperatorGroup into a namespace that already had one
# (an org-owned cert-manager-operator's), OLM does not reject the second OperatorGroup — it fails
# EVERY CSV in that namespace (phase Failed, reason TooManyOperatorGroups) while the operator's
# Deployments keep running 1/1, so nothing looks wrong until the org's next upgrade silently does
# nothing. The assert reads well and is the only thing standing in front of that, but it had never
# been driven — proving it live means breaking a namespace others depend on. This guard drives it
# under a stubbed `oc`, repeatably, without touching a cluster.
#
# WHAT IT CHECKS, against assert_single_operatorgroup() (+ its operatorgroup_counts() helper,
# extracted alongside it so the test exercises the real counting code too) from bootstrap/install.sh:
#
#   (a) a clean cluster (every namespace holds at most one OperatorGroup) → returns 0, prints the
#       pass banner, never mentions degradation.
#   (b) THE REAL FAILURE SHAPE: our own OperatorGroup (carrying our owner label) lands in a namespace
#       that already has one that is not ours → returns NON-ZERO, the pass banner is suppressed, the
#       degradation warning fires, and the undo hint names OUR OperatorGroup for removal (never
#       theirs — deleting the org's own OperatorGroup would be a second act of the same defect).
#   (c) POSITIVE CONTROL: a namespace already holds two OperatorGroups and NEITHER is ours (a
#       collision this install did not cause) → returns 0, the pass banner still prints, and the
#       degradation warning does NOT fire. A detector that fails every multi-OperatorGroup namespace
#       regardless of who added it would fail installs for pre-existing states we cannot fix, so this
#       case matters as much as (b): proof the gate distinguishes "we broke this" from "already broken".
#
# owning_stack_of_app() (only reached on the (b) fix-hint path, to name the offending stack) is
# stubbed rather than extracted: it shells out to `yq` over platform-portfolio/stacks/**/apps/*.yaml,
# and this guard's contract is bash + awk + sed only (see uninstall-restore-guard.sh's `yq` stub for
# the same reasoning) — its own correctness is not this gate's concern.
#
# ON PORTABILITY. Extracted function text is always written to a real temp FILE before being sourced
# into a test harness, never held only in a process-substitution pipe: `-s` on a process substitution
# reports the buffered byte count on macOS/BSD and 0 on Linux, so a `[[ -s "$x" ]]` guard over one
# would pass locally and fail on CI ubuntu for a reason that has nothing to do with what is being
# tested (this exact shape bit uninstall-state-lifetime-guard.sh's self-test, 2026-07-31).
#
# Runnable standalone (CI lint gate) and by hand; needs nothing but bash + awk + sed.
#
# --self-test proves the detector actually fires before a clean run on the real tree is worth
# anything: it plants a canary that drops the `bad=1` assignment — the one line that turns "we found
# OUR OperatorGroup colliding with the org's" into a failure — reproducing the exact shape of a
# detector blind to the incident it exists to catch (case (b) would then wrongly return 0 with the
# pass banner intact). Exit 1 = the canary was caught AND the real tree is clean under the same
# detector; that is a PASS, matching the house convention where CI asserts the self-test step exits
# exactly 1. Exit 2 = the detector is blind, or the harness itself is broken.
#
# Exit codes:
#   0  contract holds
#   1  contract broken — or, under --self-test, the canary was correctly detected
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

INSTALL="bootstrap/install.sh"
FN_ASSERT="assert_single_operatorgroup"
FN_COUNTS="operatorgroup_counts"

# ── extraction ────────────────────────────────────────────────────────────────
# Extracted, never sourced: install.sh runs a full cluster install at top level. Extraction failure
# is exit 2, never a silent pass. Written to a real FILE (see the portability note above).
# extract_func lives in _extract-func.sh, sourced above; shared with the other guards under
# tools/lint/ rather than copy-pasted per guard.

# ── harness ───────────────────────────────────────────────────────────────────
# Runs assert_single_operatorgroup() (+ operatorgroup_counts()) under a stubbed `oc`, one scenario
# per call, and echoes combined stdout+stderr followed by "RC=<n>".
run_og() {  # <func_file> <scenario: clean|ours_added|preexisting> → banner text, then "RC=<n>"
  local func_file="$1" scenario="$2" harness
  local baseline="" ours_names="" all_names="" tracking="" csv=""
  case "$scenario" in
    clean)
      # two namespaces, one OperatorGroup each — nothing ever exceeds count 1.
      baseline=$'ns-a og-a 3d\nns-b og-b 3d'
      ;;
    ours_added)
      # THE INCIDENT SHAPE: our OperatorGroup (og-ours, carries our owner label) added into ns-a,
      # which already held the org's own (og-theirs).
      baseline=$'ns-a og-ours 3d\nns-a og-theirs 30d'
      ours_names="og-ours"
      all_names=$'operatorgroups.operators.coreos.com/og-ours\noperatorgroups.operators.coreos.com/og-theirs'
      tracking="workshop-config:Application"
      csv="cert-manager-operator.v1.14.0 Failed TooManyOperatorGroups"
      ;;
    preexisting)
      # ns-a already holds two OperatorGroups and neither carries our owner label — not our defect.
      baseline=$'ns-a og-x 3d\nns-a og-y 3d'
      ;;
  esac
  harness="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "OWNER_LABEL='workshop.redhat.com/owner=ogsr'"
    echo "OG_BASELINE=''"
    echo "BASELINE_ROWS=$(printf '%q' "$baseline")"
    echo "OURS_NAMES=$(printf '%q' "$ours_names")"
    echo "ALL_OG_NAMES=$(printf '%q' "$all_names")"
    echo "TRACKING_ID=$(printf '%q' "$tracking")"
    echo "CSV_ROWS=$(printf '%q' "$csv")"
    cat <<'STUBS'
ok()   { echo "ok: $*"; }
err()  { echo "err: $*" >&2; }
warn() { echo "warn: $*" >&2; }
# Only reached on the fix-hint path in scenario (b); real one shells out to yq (see file header).
owning_stack_of_app() { echo "platform-portfolio"; }
oc() {
  case "$*" in
    *"-A --no-headers"*)         printf '%s\n' "$BASELINE_ROWS" ;;
    *"get csv -n"*)               printf '%s\n' "$CSV_ROWS" ;;
    *"tracking-id"*)              printf '%s' "$TRACKING_ID" ;;
    *"-o name"*)                  printf '%s\n' "$ALL_OG_NAMES" ;;
    *"-l "*"jsonpath="*)          printf '%s' "$OURS_NAMES" ;;
    *) : ;;
  esac
  return 0
}
STUBS
    cat "$func_file"
    echo "${FN_ASSERT}"
    # $? is PATTERN for the harness script to expand when IT runs, not here.
    # shellcheck disable=SC2016
    echo 'echo "RC=$?"'
  } > "$harness"
  bash "$harness" 2>&1
  rm -f "$harness"
}

check_operatorgroup_gate() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "could not extract ${FN_ASSERT}() (+ ${FN_COUNTS}()) — the guard cannot inspect what it claims to."
    return 2
  fi

  # (a) clean cluster: no namespace holds more than one OperatorGroup.
  out="$(run_og "$func_file" clean)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[a] clean cluster: expected ${FN_ASSERT} to return 0."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'every namespace holds at most one'; then
    bad "[a] clean cluster: expected the pass banner, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'degraded'; then
    bad "[a] clean cluster: the degradation warning fired with nothing to flag."
    rc=1
  fi

  # (b) THE REAL FAILURE SHAPE — checked as several separate assertions, not just the exit code,
  # because a gate that exits 1 while still printing the pass banner is exactly the false-green class
  # this whole guard exists to catch.
  out="$(run_og "$func_file" ours_added)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=1'; then
    bad "[b] our OperatorGroup collided with the org's: expected ${FN_ASSERT} to return 1."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'every namespace holds at most one'; then
    bad "[b] the pass banner printed even though OUR OperatorGroup collided with the org's — this is"
    note "    the 2026-07-25 defect verbatim: OLM fails their CSV, pods keep running, nothing looks wrong."
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'degraded'; then
    bad "[b] expected the degradation warning naming OLM's TooManyOperatorGroups behaviour."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'delete operatorgroup og-ours'; then
    bad "[b] expected the undo hint to name OUR OperatorGroup (og-ours) for removal, never the org's."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (c) POSITIVE CONTROL: two pre-existing OperatorGroups, neither ours. A detector that fires on
  # every multi-OperatorGroup namespace regardless of cause proves nothing.
  out="$(run_og "$func_file" preexisting)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[c] pre-existing collision we did not cause: expected ${FN_ASSERT} to return 0."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'degraded'; then
    bad "[c] the degradation warning fired for a collision this install never caused."
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'pre-existing, left alone'; then
    bad "[c] expected the pre-existing-collision note, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "OperatorGroup uniqueness: clean cluster passes, our OperatorGroup added next to the org's FAILS"
    note "with the degradation warning + undo hint, pre-existing unrelated collisions do not fire"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # <root> → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
  local root="$1" rc=0 sub=0 func_file
  if [[ ! -f "${root}/${INSTALL}" ]]; then
    bad "${root}/${INSTALL} not found"
    return 2
  fi
  func_file="$(mktemp)"
  {
    extract_func "${root}/${INSTALL}" "$FN_COUNTS"
    extract_func "${root}/${INSTALL}" "$FN_ASSERT"
  } > "$func_file"

  check_operatorgroup_gate "$func_file" || sub=$?
  rm -f "$func_file"
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# One canary, the real defect shape. It must be CAUGHT, and the real tree must be clean under the
# same detector — anything else means the gate is decorative.
self_test() {
  local real_rc canary_rc f

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$REPO_ROOT" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # Canary — drop the ONE line that turns "our OperatorGroup collided with the org's" into a failure.
  # Byte-for-byte the real function with that assignment removed: case (b) would then leave bad=0,
  # take the early "$bad -eq 0" success branch, and return 0 with the pass banner intact — a detector
  # blind to the exact incident this gate exists to catch.
  f="$(mktemp)"
  {
    extract_func "${REPO_ROOT}/${INSTALL}" "$FN_COUNTS"
    extract_func "${REPO_ROOT}/${INSTALL}" "$FN_ASSERT" \
      | sed 's/^    bad=1$/    : # CANARY: dropped — collisions we cause are no longer flagged/'
  } > "$f"
  if grep -q '^    bad=1$' "$f"; then
    bad "SELF-TEST FAILED: could not build the dropped-bad canary — the assignment it mutates was not found."
    rm -f "$f"
    return 2
  fi
  canary_rc=0
  check_operatorgroup_gate "$f" >/dev/null 2>&1 || canary_rc=$?
  rm -f "$f"
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the dropped-bad=1 canary was NOT detected (rc=${canary_rc}) — the detector is blind."
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0), dropped-bad=1 canary (our own collision going unflagged) caught."
  return 1
}

# Rejects anything that is not --self-test / -h / --help, naming the offender, exit 2. Before this
# existed a one-hyphen typo (`--selftest`) silently ran the plain check and printed a green tick.
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

run_check "$REPO_ROOT"
exit $?
