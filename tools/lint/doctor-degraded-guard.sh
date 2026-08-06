#!/usr/bin/env bash
# doctor-degraded-guard.sh — `ws doctor` against a recorded cluster, in the states nobody can see.
#
# ORIGIN (2026-08-06). Half of `ws doctor`'s rows carry a third outcome — ⚠ "I could not look",
# which is deliberately not ❌ and deliberately does not fail the run, because a false red on a
# healthy attendee costs trust in every ✅ beside it. That family of branches fires ONLY for an
# identity that cannot read cluster-scoped objects, and on the clusters this project develops on the
# attendees usually can. So the degraded report is first rendered on a customer's cluster, in front
# of an attendee, with nobody watching — and it has been wrong there twice already:
#
#   • the rows themselves used to print ❌: "IdP missing — bootstrap adds it", shown to someone who
#     had logged in THROUGH that IdP seconds earlier, and "user1-dev missing — workshop-config not
#     synced" on the line under a green workshop-config;
#   • then the rows were fixed and the SUMMARY was not, so the same run ended "✅ environment looks
#     good" with six ⚠ rows above it (measured live, user3 on cluster-65prs, 2026-08-06).
#
# Both are invisible to review: each produces a plausible, quiet, complete-looking report. Neither is
# reachable from a maintainer's admin shell. So this gate records the cluster instead.
#
# WHAT IT DOES. It runs the REAL tools/ws/ws with a recorded `oc` and `curl` at the front of PATH and
# compares what it prints, row for row and mark for mark, with the last line and the exit status,
# against three recordings that differ only in what the cluster answered:
#
#   attendee-forbidden  an attendee: everything they may read is healthy, six reads are Forbidden.
#                       Every one of those six must be ⚠ and none may be ❌; the verdict must say the
#                       run did not fully check the environment, and must count what it did check;
#                       and the exit code must stay 0 — a healthy attendee whose world is merely
#                       partly unreadable is not a failing environment.
#   admin-readable      cluster-admin, nothing wrong: the plain green line, the count equal to the
#                       number of rows, and NO caveat. This direction matters as much as the other —
#                       a caveat printed on a clean run is one people learn to ignore, which is how
#                       tools/verify/_lib.sh's not-applicable outcome once told attendees whose run
#                       was fully graded that it "did NOT fully verify the lab".
#   platform-down       an attendee on a broken platform: a genuine ❌ and ungraded rows in the same
#                       report. The failure must lead, the not-graded count must ride along beside
#                       it, and the exit code must be 1 — "some rows were unreadable" may never
#                       soften a real failure into an inspection problem.
#
# Nothing is mocked inside ws. The shell that runs on a cluster is the shell that runs here; only the
# cluster is a recording, and an `oc` or `curl` call the recording does not model is a FINDING rather
# than an empty answer (see the fixtures' cmd-stub.py for why that has to be true).
#
# WHAT IT CANNOT CHECK, stated so nobody reads a green tick as more than it is. The recording is of
# what `oc` PRINTED, so the jsonpaths and go-templates inside ws are data here, not code — a wrong
# field selector is invisible to this gate, and `ws doctor` on a live cluster stays the acceptance
# test for one. It says nothing about whether the cluster is healthy; it says the reporter is honest.
# Two rows are also out of its reach by construction and pinned elsewhere: the entry-verify row's
# graded branches (they shell out to a verify script, a second process with its own cluster reads —
# tools/lint/verify-summary-skip-guard.sh holds that contract) and the "(Degraded by design)"
# continuation line under the Argo row, which no recording here produces.
#
# Detectors, each with a canary of its own in --self-test:
#   [1] check_row_marks       every row appears, in order, with the mark the recording requires
#   [2] check_verdict_line    the closing line is EXACTLY what the recorded report must end with
#   [3] check_exit_code       the process status matches the recording
#   [4] check_modelled_calls  no `oc`/`curl` call escaped the recording
#
# Exit codes:
#   0  every recorded case reproduces
#   1  a case no longer reproduces — or, under --self-test, every canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (missing file, unusable sandbox), which
#      is never a pass
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lint/_check-coverage.sh
source "${LINT_DIR}/_check-coverage.sh"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "${LINT_DIR}/_parse-guard-args.sh"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*" >&2; }

WS="tools/ws/ws"
FIXTURES="${LINT_DIR}/doctor-degraded-fixtures"
STUB="${FIXTURES}/cmd-stub.py"
CASES=(attendee-forbidden admin-readable platform-down)
# Four detectors × three cases. Getting this number wrong is loud, never silent (_check-coverage.sh).
CHECK_COVERAGE_EXPECT="check_row_marks=3 check_verdict_line=3 check_exit_code=3 check_modelled_calls=3"

# Set by run_case, read by the detectors: one ws run answers all four questions, and re-running it
# per detector would quadruple the cost for nothing.
CASE_OUT=""
CASE_RC=0
CASE_UNKNOWN=""

# ── the recording format ──────────────────────────────────────────────────────
# One record per line: <type> TAB <fields…>. `#` comments and blank lines are ignored. See any
# .case file for the vocabulary.
records() {  # <type> <case-file> → the matching lines, fields intact
  awk -F'\t' -v want="$1" '$1 == want' "$2"
}
field() {  # <n> <line> → the nth TAB-separated field
  printf '%s' "$2" | cut -d$'\t' -f"$1"
}

# ── the sandbox ───────────────────────────────────────────────────────────────
# A COPY of ws, so a canary's mutation can never be left behind in the working tree if this script is
# interrupted, and so REPO_ROOT points at the sandbox: doctor must not find the real tools/verify and
# start shelling out to verify scripts the recording does not model.
prepare_sandbox() {  # <ws-source> <dir> → 0, or 2 if the sandbox cannot be built
  local src="$1" dir="$2" tool
  mkdir -p "${dir}/tools/ws" "${dir}/bin" || return 2
  cp "$src" "${dir}/${WS}" || return 2
  chmod +x "${dir}/${WS}" || return 2
  cp "$STUB" "${dir}/bin/cmd-stub.py" || return 2
  for tool in oc curl; do
    # `--as <tool>`: the stub answers as whichever command it was invoked for, and saying which one
    # explicitly beats inferring it from argv[0] — a shim that execs python3 passes the SCRIPT's name,
    # not its own, so the inference would silently pick the wrong table.
    # shellcheck disable=SC2016  # the $(dirname "$0") / "$@" are the SHIM's, written out verbatim —
    # expanding them here would bake this guard's own argv into the stub.
    printf '#!/bin/sh\nexec python3 "$(dirname "$0")/cmd-stub.py" --as %s "$@"\n' "$tool" \
      > "${dir}/bin/${tool}" || return 2
    chmod +x "${dir}/bin/${tool}" || return 2
  done
  return 0
}

run_case() {  # <sandbox> <case-file> → runs ws once; sets CASE_OUT/CASE_RC/CASE_UNKNOWN. 2 = could not run
  local dir="$1" case_file="$2" argv_line argv
  argv_line="$(records argv "$case_file" | head -1)"
  argv="$(field 2 "$argv_line")"
  if [[ -z "$argv" ]]; then
    bad "${case_file##*/}: no 'argv' record — the recording does not say what to run."
    return 2
  fi
  CASE_OUT="${dir}/output.txt"
  CASE_UNKNOWN="${dir}/unknown-calls.log"
  : > "$CASE_UNKNOWN"
  # Merged, not separated. A doctor ROW is printed by two calls — `printf "  %-28s" label` and then
  # ok()/nok()/skip()/unknown() — and while all of them are on stdout today, die()/warn() are not:
  # reading one stream alone would show a label with no verdict and every assertion would silently
  # test the wrong text. One pipe reproduces what a terminal shows.
  CASE_RC=0
  # Word splitting on $argv is intended: the recording stores the ws command line as text.
  # shellcheck disable=SC2086
  env -i PATH="${dir}/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$dir" \
      KUBECONFIG="${dir}/no-such-kubeconfig" \
      WS_STUB_CASE="$case_file" WS_STUB_UNKNOWN="$CASE_UNKNOWN" \
      bash "${dir}/${WS}" $argv > "$CASE_OUT" 2>&1 || CASE_RC=$?
  return 0
}

# The rows the report actually printed, as "label<TAB>mark". A row is a line that starts with exactly
# two spaces and then something visible; the ⚠/➖/✅/❌ glyph is where the label ends. Deliberately not
# a fixed-column parse: the mirror row's label is longer than the %-28s field and its mark follows
# with no gap at all, which is exactly the row a column-counting parser would drop. The blank-label
# continuation line under the Argo row (30 spaces, then ✅) and the verdict's own follow-up line
# (three spaces, then ↳) both fail the "two spaces then visible" test, which is why neither is a row.
report_rows() {  # <output-file> → label<TAB>mark per row
  awk '
    /^  [^ ]/ {
      idx = match($0, /✅|❌|➖|⚠/)
      if (idx == 0) next
      label = substr($0, 3, idx - 3)
      sub(/[ \t]+$/, "", label)
      printf "%s\t%s\n", label, substr($0, idx, RLENGTH)
    }' "$1"
}

# The closing verdict, and the line under it. The verdict is the LAST line that starts with a glyph
# in column 1 — every row's glyph is indented, so nothing else can be mistaken for it.
verdict_and_after() {  # <output-file> → the verdict line, then the line following it
  awk '
    /^(✅|❌|➖|⚠)/ { verdict = $0; want = NR + 1; after = ""; next }
    NR == want    { after = $0 }
    END           { print verdict; print after }' "$1"
}

# ── [1] every row, in order, with the right mark ──────────────────────────────
check_row_marks() {  # <case-file> → 0 clean, 1 finding
  ran_check
  local case_file="$1" name="${1##*/}" want got
  want="$(records row "$case_file" | cut -d$'\t' -f2,3)"
  got="$(report_rows "$CASE_OUT")"
  if [[ "$want" == "$got" ]]; then
    ok "[1] ${name}: $(printf '%s\n' "$want" | grep -c .) rows, each with the recorded mark"
    return 0
  fi
  bad "[1] ${name}: the report's rows are not what this cluster must produce."
  note "    A ⚠ that has turned ❌ here is the false red this whole fixture exists for: it is shown"
  note "    to an attendee whose environment is fine, and it costs trust in every ✅ beside it."
  note "    expected:"
  printf '%s\n' "$want" | sed 's/^/       /' >&2
  note "    got:"
  printf '%s\n' "${got:-(no rows at all)}" | sed 's/^/       /' >&2
  return 1
}

# ── [2] the closing verdict, exactly ──────────────────────────────────────────
check_verdict_line() {  # <case-file> → 0 clean, 1 finding
  ran_check
  local case_file="$1" name="${1##*/}" want_verdict want_after got got_verdict got_after
  want_verdict="$(field 2 "$(records verdict "$case_file" | head -1)")"
  want_after="$(field 2 "$(records after "$case_file" | head -1)")"
  got="$(verdict_and_after "$CASE_OUT")"
  got_verdict="$(printf '%s' "$got" | sed -n '1p')"
  got_after="$(printf '%s' "$got" | sed -n '2p')"
  if [[ "$want_verdict" == "$got_verdict" && "$want_after" == "$got_after" ]]; then
    ok "[2] ${name}: ${got_verdict}"
    return 0
  fi
  bad "[2] ${name}: the report does not end with the line this cluster must produce."
  note "    expected: ${want_verdict}"
  note "              ${want_after:-(nothing after it)}"
  note "    got:      ${got_verdict:-(no verdict line at all)}"
  note "              ${got_after:-(nothing after it)}"
  note "    The last line is the one an SA pastes into chat and an attendee reads first. It may not"
  note "    claim more than the rows above it did, and it may not caveat a run that was fully graded."
  return 1
}

# ── [3] the exit status ───────────────────────────────────────────────────────
check_exit_code() {  # <case-file> → 0 clean, 1 finding
  ran_check
  local case_file="$1" name="${1##*/}" want
  want="$(field 2 "$(records exit "$case_file" | head -1)")"
  if [[ "$CASE_RC" == "$want" ]]; then
    ok "[3] ${name}: exit ${CASE_RC}"
    return 0
  fi
  bad "[3] ${name}: exit ${CASE_RC}, expected ${want}."
  note "    \`ws doctor\` is attendee-runnable and its status is consumed as pass/fail. A run that"
  note "    could not READ part of the world is not a broken world: making it non-zero fails every"
  note "    healthy attendee, which trades an overclaiming ✅ for a false ❌. A genuinely failing"
  note "    check must still exit 1 — an ungraded row may never soften one into an inspection note."
  return 1
}

# ── [4] nothing was asked that the recording does not model ───────────────────
check_modelled_calls() {  # <case-file> → 0 clean, 1 finding
  ran_check
  local case_file="$1" name="${1##*/}" unknown
  unknown="$(sort -u "$CASE_UNKNOWN" 2>/dev/null)"
  if [[ -z "$unknown" ]]; then
    ok "[4] ${name}: every oc/curl call came from the recording"
    return 0
  fi
  bad "[4] ${name}: the report asked the cluster something the recording does not model, so part of"
  note "    it came from no data at all:"
  printf '%s\n' "$unknown" | sed 's/^/       /' >&2
  note "    Doctor's reads are all written \`|| true\` / \`2>/dev/null\`, so an unanswered one is"
  note "    silently empty and its row grades on nothing. Record the call, then re-read the row."
  return 1
}

# ── the driver ────────────────────────────────────────────────────────────────
run_check() {  # <ws-source> → 0 clean, 1 findings, 2 could not inspect
  coverage_reset
  local ws_src="$1" rc=0 case_name case_file tmp crc
  if [[ ! -f "$ws_src" ]]; then
    bad "${ws_src} not found — scanning nothing is not a pass."
    return 2
  fi
  if [[ ! -f "$STUB" ]]; then
    bad "${STUB} not found — the recorded oc/curl is missing, so nothing below would be a cluster."
    return 2
  fi
  for case_name in "${CASES[@]}"; do
    case_file="${FIXTURES}/${case_name}.case"
    if [[ ! -f "$case_file" ]]; then
      bad "recording ${case_name}.case is missing — a case that cannot run is not a case that passed."
      return 2
    fi
    tmp="$(mktemp -d)" || return 2
    prepare_sandbox "$ws_src" "$tmp" || { rm -rf "$tmp"; bad "could not build the sandbox for ${case_name}."; return 2; }
    if ! run_case "$tmp" "$case_file"; then rm -rf "$tmp"; return 2; fi
    crc=0
    check_row_marks      "$case_file" || crc=1
    check_verdict_line   "$case_file" || crc=1
    check_exit_code      "$case_file" || crc=1
    check_modelled_calls "$case_file" || crc=1
    [[ "$crc" -eq 0 ]] || rc=1
    rm -rf "$tmp"
  done
  # Nothing above proves the driver still CALLS every detector this guard declares — a deleted call
  # site leaves each canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Every canary is a MUTATION OF THE REAL SCRIPT — the smallest edit that reintroduces one defect —
# and each one names the single detector that must catch it ON ITS OWN. That last part is the lesson
# from rebuild-scan-guard: it counted a mutant as caught if either of its two halves fired, and ten
# of its detectors could then be neutered one at a time with CI green, because the halves were
# signing off each other's regressions. A detector proven only by a mutant that also trips three
# others is not proven.
MUTATED_WS=""

mutate_ws() {  # <dst> <old> <new> → 0 replaced, 1 the text was not there (a no-op mutation)
  MUT_OLD="$2" MUT_NEW="$3" python3 -c '
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
if old not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
' "${REPO_ROOT}/${WS}" "$1"
}

expect_caught() {  # <name> <case> <detector> <old> <new> <why> → 0 caught, 1 not
  local name="$1" case_name="$2" detector="$3" old="$4" new="$5" why="$6"
  local case_file="${FIXTURES}/${case_name}.case" tmp rc=0
  tmp="$(mktemp -d)" || return 1
  MUTATED_WS="${tmp}/mutated-ws"
  if ! mutate_ws "$MUTATED_WS" "$old" "$new"; then
    rm -rf "$tmp"
    bad "SELF-TEST FAILED: mutant ${name} found nothing to replace — tools/ws/ws was reworded, so"
    note "the mutation is a no-op and proves nothing. Re-express the defect; do not delete the canary."
    return 1
  fi
  prepare_sandbox "$MUTATED_WS" "$tmp" || { rm -rf "$tmp"; return 1; }
  if ! run_case "$tmp" "$case_file"; then rm -rf "$tmp"; return 1; fi
  "$detector" "$case_file" >/dev/null 2>&1 || rc=$?
  rm -rf "$tmp"
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: mutant ${name} was NOT caught by ${detector} alone (rc=${rc}) — ${why}"
    note "That detector passes with the defect present, so a clean run of it means nothing. Do not"
    note "widen the canary to another detector: the point is that each one proves its own claim."
    return 1
  fi
  return 0
}

# shellcheck disable=SC2016  # every mutant below quotes tools/ws/ws SOURCE TEXT, so `${pass}` and
# friends must stay single-quoted and unexpanded: they are the bytes being matched, not variables.
self_test() {
  local real_rc failures=0

  # Proof 0: the real tree reproduces all three recordings. A suite that fails on the real thing
  # proves nothing about any mutant.
  real_rc=0
  run_check "${REPO_ROOT}/${WS}" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not reproduce its own recordings (rc=${real_rc})."
    note "Run without --self-test to see which case, which row and which line."
    return 2
  fi

  # [2] The defect this fixture was written the day after: the rows tell the truth and the summary
  # does not. Nothing else about the run changes — same rows, same marks, same exit code.
  expect_caught summary-verdict-silenced attendee-forbidden check_verdict_line \
    '    unknown "${pass} of ${rows} checks passed · ${ungraded} NOT GRADED${na_note} — this run did NOT fully check the environment"' \
    '    ok "environment looks good"' \
    "a report with six ungraded rows ends '✅ environment looks good' again" || failures=1

  # [2] The opposite error, and the cheapest wrong way to fix the one above: caveat everything. A
  # warning on a run with nothing wrong is a warning people learn to skip.
  expect_caught clean-run-gains-a-caveat admin-readable check_verdict_line \
    '  if (( ungraded > 0 )); then
    unknown "${pass} of ${rows} checks passed' \
    '  if (( ungraded >= 0 )); then
    unknown "${pass} of ${rows} checks passed' \
    "a fully graded, entirely healthy run is told it did not fully check the environment" || failures=1

  # [2] A real failure loses the fact that part of the run was never graded — the reader is left
  # believing the two failures are the whole story.
  expect_caught failure-verdict-drops-not-graded platform-down check_verdict_line \
    '    nok "${failed} of ${rows} checks failed — fix hints above${ungraded_note}${na_note}"' \
    '    nok "${failed} of ${rows} checks failed — fix hints above${na_note}"' \
    "the ❌ verdict stops saying that six more rows were never graded" || failures=1

  # [1] The false red itself, in the smallest form it takes: one ⚠ row decides it is a ❌.
  expect_caught ungraded-row-turned-red attendee-forbidden check_row_marks \
    '    unknown "not checked (needs cluster-admin to read the attendee group)"' \
    '    nok "not checked (needs cluster-admin to read the attendee group)"; fail=1' \
    "an attendee who simply cannot read the group is told their cohort is broken" || failures=1

  # [1] The row is still computed and still printed, under a label nothing looks for — which is how a
  # row silently stops being the thing anyone greps for. Changes no count and no status.
  expect_caught row-label-renamed attendee-forbidden check_row_marks \
    '  printf "  %-28s" "workshop IdP"' \
    '  printf "  %-28s" "idp"' \
    "a row is renamed and every report that looked for it now finds nothing" || failures=1

  # [3] The exit-code contract, stated as a canary: an attendee's healthy-but-partly-unreadable run
  # must not become non-zero. Same rows, same verdict — only the status moves.
  expect_caught partial-run-exits-nonzero attendee-forbidden check_exit_code \
    '    echo "   ↳ each ⚠ line above says what could not be read and who can read it; re-run there for a complete picture"
    return 0' \
    '    echo "   ↳ each ⚠ line above says what could not be read and who can read it; re-run there for a complete picture"
    exit 1' \
    "a healthy attendee whose cluster reads were partly denied now fails the check" || failures=1

  # [3] And the other direction: a genuinely failing environment reporting success.
  expect_caught failure-run-exits-zero platform-down check_exit_code \
    '    nok "${failed} of ${rows} checks failed — fix hints above${ungraded_note}${na_note}"
    exit 1' \
    '    nok "${failed} of ${rows} checks failed — fix hints above${ungraded_note}${na_note}"
    exit 0' \
    "a broken platform exits 0 while the ❌ rows sit on screen" || failures=1

  # [4] A read nobody recorded. The row it belongs to still prints, still looks right, and is now
  # grading an answer that never came — the one defect shape that leaves the report intact.
  expect_caught unmodelled-read-introduced attendee-forbidden check_modelled_calls \
    '  local idp_out idp_rc=0' \
    '  oc get clusterversion version >/dev/null 2>&1 || true
  local idp_out idp_rc=0' \
    "ws asks the cluster something the recording does not model and nothing says so" || failures=1

  # A missing recording must be "could not inspect" (2), never a clean 0: a case that cannot run is
  # not a case that passed.
  local saved=("${CASES[@]}") rc=0
  CASES=(no-such-case)
  run_check "${REPO_ROOT}/${WS}" >/dev/null 2>&1 || rc=$?
  CASES=("${saved[@]}")
  if [[ "$rc" -ne 2 ]]; then
    bad "SELF-TEST FAILED: a missing recording reported rc=${rc}, not 2 — the guard would pass on nothing."
    failures=1
  fi

  if [[ "$failures" -ne 0 ]]; then return 2; fi
  ok "self-test ok — the real tree reproduces all ${#CASES[@]} recordings, and all eight reintroduced"
  echo "   defects are caught by the one detector each is meant to prove: summary-verdict-silenced,"
  echo "   clean-run-gains-a-caveat, failure-verdict-drops-not-graded, ungraded-row-turned-red,"
  echo "   row-label-renamed, partial-run-exits-nonzero, failure-run-exits-zero,"
  echo "   unmodelled-read-introduced (plus the missing-recording canary)."
  return 1
}

# Rejects anything that is not --self-test / -h / --help, naming the offender, exit 2.
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

run_check "${REPO_ROOT}/${WS}"
rc=$?
case "$rc" in
  0) printf 'doctor-degraded-guard: clean — %s recorded clusters reproduce, rows, verdict and exit status.\n' "${#CASES[@]}"
     printf '%s\n' "  (A recording, not a cluster: it says the reporter is honest, never that a cluster is healthy.)" ;;
  1) printf '\n%s\n' "  ws doctor no longer reports what a recorded cluster must produce. Its failure mode is a" >&2
     printf '%s\n\n'  "  plausible report, not an error — treat a finding here as a wrong answer already shipping." >&2 ;;
esac
exit "$rc"
