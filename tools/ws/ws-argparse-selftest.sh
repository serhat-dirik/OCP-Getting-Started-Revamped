#!/usr/bin/env bash
# ws-argparse-selftest.sh — the ws CLI accepts the attendee as EITHER `--user U` or a bare `userN`.
# This proves the two spellings can never DISAGREE without ws refusing, on every verb that takes one.
#
# THE DEFECT THIS PINS (measured on the shipped parser, 2026-08-12, before the fix):
#
#     ws prep m07 user3 --user user4      →  silently acted on user4
#     ws prep m07 --user user4 user3      →  died "conflicting users"
#
# One check existed, and it lived only in the POSITIONAL branch, so it asked "was --user already
# given?" and never the other way round. Whichever spelling came LAST simply overwrote the other.
# `ws prep` detects leftovers and offers to WIPE them, so the silent order destroyed the wrong
# attendee's world — and afterwards the wipe is indistinguishable from a normal prep, so there is no
# way to tell it happened. The same last-wins shape was live in rebuild-images, maas show and maas
# set in BOTH orders, and as a repeated `--user U --user V` in git-refresh, session-refresh and
# passwd. Every one of those combinations is asserted below.
#
#   bash tools/ws/ws-argparse-selftest.sh              → the shipped tools/ws/ws
#                                                        (rc 0 contract holds · 1 broken · 2 could not inspect)
#   bash tools/ws/ws-argparse-selftest.sh --self-test  → every assertion catches its own canary (rc 1)
#
# HOW IT RUNS THE REAL PARSER WITHOUT A CLUSTER. tools/ws/ws is sourceable (its trailing
# `BASH_SOURCE[0] == $0` guard), so each case sources the SHIPPED file — real main(), real
# require_user_token, real user_conflict_guard — replaces the dispatch targets with stubs that print
# the resolved identity and exit, and calls main(). `oc` is additionally replaced by a function that
# refuses and shouts, so a missed stub cannot reach a cluster: it shows up as SELFTEST-VIOLATION in
# the output instead. Nothing here shells out to `ws` and nothing here needs a login.
#
# WHY THE CANARIES ARE FUNCTION OVERRIDES rather than a sed-mutated copy: the detector is a named
# function (user_conflict_guard / unexpected_positional), so neutering it is one line and exercises
# the REAL parser with only the detector removed. A sed on the file would prove that a particular
# text pattern still exists, which is a different and weaker claim. The self-test asserts the
# neutering actually took effect — a canary that "passes" because the override missed is a canary
# that proves nothing, which is the failure mode tools/lint/_parse-guard-args.sh was written for.
#
# NOTE FOR WHOEVER WIRES THIS INTO CI: it is deliberately NOT in tools/lint (this change's author was
# scoped to tools/ws/). If it is moved there it must either adopt tools/lint/_parse-guard-args.sh or
# be added to that file's _PGA_EXEMPT with a reason, or the meta-scan will report it as UNPARSED.
set -uo pipefail

WS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${WS_DIR}/ws"

fail() { echo "❌ $*" >&2; }
note() { echo "   $*" >&2; }
pass() { echo "✅ $*"; }

usage() {
  echo "usage: $(basename "$0") [--self-test]"
  echo
  echo "  (no arguments)  assert the shipped tools/ws/ws refuses two disagreeing attendee spellings"
  echo "                  exit 0 = contract holds · 1 = contract broken · 2 = could not inspect"
  echo "  --self-test     neuter each detector and prove every assertion it protects then FAILS"
  echo "                  exit 1 = every canary was correctly caught (this is the PASS)"
  echo "  -h, --help      this message"
}

# ── the harness ──────────────────────────────────────────────────────────────────────────────────
# _run <neuter> <argv…> → merged stdout+stderr; rc is what ws exited with.
#
# `@call <fn> <args…>` calls one shipped function directly instead of going through main(), so the
# detector's own contract can be asserted separately from its call sites.
#
# Nearly every function below is a stub that main() reaches BY NAME after this file redefines it, so
# the linter sees a definition nothing calls. That is SC2317 on 0.9.x (the version CI installs from
# apt on ubuntu-latest) and SC2329 on >=0.10 (what `koalaman/shellcheck:stable` gives you locally),
# so BOTH codes are named or the directive silences nothing on one of the two. Scoped to the whole
# function: a bare directive line applies only to the command that follows it, which left 20
# findings standing the first time. Note also that a comment beginning with the linter's own name is
# parsed as a DIRECTIVE, so the paragraph above deliberately never starts a line with it.
# shellcheck disable=SC2317,SC2329
_run() {
  local neuter="$1"; shift
  (
    WS_REEXECED=1            # skip ws_stay_current: no git fetch, no re-exec, no mirror
    export WS_REEXECED
    KUBECONFIG=/dev/null     # belt: nothing below may reach a cluster
    export KUBECONFIG
    # shellcheck source=/dev/null
    source "$WS" || exit 97

    # The belt. A stub this file forgot must be LOUD, not a silent cluster call.
    #
    # The ONE exception is a bare `oc whoami`, answered with a fake attendee. That is not
    # convenience — it is what makes the unexpected_positional canary mean anything. When that
    # detector is neutered, `ws prep m07 usr3` drops the token and user_arg falls back to whoami, so
    # the defect is "prep silently ran for SOMEBODY ELSE". With whoami failing, the neutered run just
    # died "not logged in" and the canary could not tell a dropped token from a broken harness.
    # No cluster is contacted either way; --show-server and every other subcommand still shout.
    oc() {
      if [[ "${1:-}" == "whoami" && $# -eq 1 ]]; then echo "user99"; return 0; fi
      echo "SELFTEST-VIOLATION: oc was called with: $*" >&2
      return 1
    }

    # Terminal stubs. Each one prints the identity the parser actually resolved and stops there.
    # They read their caller's locals by bash's dynamic scoping — the same mechanism ws's own
    # pod_i/pod_x helpers rely on — which is how the self-parsing verbs report their resolved value.
    cmd_list()   { echo "PARSE-OK user=";           exit 0; }
    cmd_prep()   { echo "PARSE-OK user=$1 module=$2"; exit 0; }
    cmd_start()  { echo "PARSE-OK user=$1 module=$2"; exit 0; }
    cmd_verify() { echo "PARSE-OK user=$1 module=$2 extra=${*:3}"; exit 0; }
    cmd_smoke()  { echo "PARSE-OK user=$1 module=$2"; exit 0; }
    cmd_reset()  { echo "PARSE-OK user=$1 module=$2"; exit 0; }
    cmd_solve()  { echo "PARSE-OK user=$1 module=$2"; exit 0; }
    cmd_doctor() { echo "PARSE-OK user=$1";           exit 0; }
    cmd_status() { echo "PARSE-OK user=$1";           exit 0; }
    cmd_diag()   { echo "PARSE-OK user=$1 module=${2:-}"; exit 0; }
    cmd_maas_show() { echo "PARSE-OK user=${1:-}";    exit 0; }

    # The self-parsing verbs keep their own parse loop, so the stub goes on the first thing each one
    # does AFTER that loop. git-refresh is the exception that forces per-verb stubbing: it calls
    # need_oc BEFORE parsing, so need_oc cannot be the stop for it.
    case "${1:-}" in
      git-refresh)
        need_oc() { :; }
        force_mirror_sync() { echo "PARSE-OK user=${target:-}"; exit 0; } ;;
      session-refresh)
        need_oc() { echo "PARSE-OK user=${target:-}"; exit 0; } ;;
      rebuild-images)
        need_oc() { :; }
        rebuild_begin() { echo "PARSE-OK user=${scope:-}"; exit 0; } ;;
      passwd)
        need_oc() { echo "PARSE-OK user=${target_user:-}"; exit 0; } ;;
      maas)
        need_oc() { echo "PARSE-OK user=${scope_user:-}"; exit 0; } ;;
    esac

    # ── the canary switch ──
    case "$neuter" in
      conflict)   user_conflict_guard()  { return 0; } ;;
      positional) unexpected_positional() { return 0; } ;;
      "")         : ;;
      *)          echo "SELFTEST-HARNESS: unknown neuter '${neuter}'" >&2; exit 98 ;;
    esac

    if [[ "${1:-}" == "@call" ]]; then
      shift
      "$@"
      exit $?
    fi
    main "$@"
  ) 2>&1
}

# ── assertion recording ──────────────────────────────────────────────────────────────────────────
# Each assertion belongs to a CLASS, and a class is what a canary neuters:
#   conflict    — protected by user_conflict_guard
#   positional  — protected by unexpected_positional
#   control     — must hold in EVERY mode, neutered or not. These are what stop a canary from
#                 "passing" because the override simply broke the parser: a neuter that also
#                 flipped a control would be caught here rather than certified.
R_OK=0
R_BAD=0
R_DETAIL=""      # "class|label|detail" per failing assertion, newline separated
R_SEEN=""        # "class|label" per assertion attempted, newline separated

_record() {  # <class> <label> <ok|detail>
  R_SEEN="${R_SEEN}${1}|${2}"$'\n'
  if [[ "$3" == "ok" ]]; then
    R_OK=$((R_OK + 1))
  else
    R_BAD=$((R_BAD + 1))
    R_DETAIL="${R_DETAIL}${1}|${2}|${3}"$'\n'
  fi
}

# expect_refusal <class> <label> <needle…> -- <argv…>
#   ws must exit 1 AND the message must contain every needle. rc alone is not enough: `ws prep m07
#   user3 --user user4` exited 1 for a dozen unrelated reasons during development, and a canary
#   judged on rc would have certified a detector that never ran (tools/lint/cohort-ops-guard.sh
#   records the same lesson — six of its fourteen assertions were deletable without changing rc).
expect_refusal() {
  local class="$1" label="$2"; shift 2
  local needles=() out rc=0 n
  while [[ $# -gt 0 && "$1" != "--" ]]; do needles+=("$1"); shift; done
  shift   # the --
  out="$(_run "$NEUTER" "$@")" || rc=$?
  if [[ "$rc" -eq 97 || "$rc" -eq 98 ]]; then
    _record "$class" "$label" "HARNESS: could not source/dispatch (rc ${rc}): ${out}"; return
  fi
  if grep -q 'SELFTEST-VIOLATION' <<<"$out"; then
    _record "$class" "$label" "HARNESS: reached oc — a stub is missing: ${out}"; return
  fi
  if [[ "$rc" -ne 1 ]]; then
    _record "$class" "$label" "got ${rc}, expected 1 (a refusal); output: $(tr '\n' ' ' <<<"$out")"; return
  fi
  for n in "${needles[@]}"; do
    if ! grep -qF -- "$n" <<<"$out"; then
      _record "$class" "$label" "refused, but the message never said '${n}'; output: $(tr '\n' ' ' <<<"$out")"; return
    fi
  done
  _record "$class" "$label" ok
}

# expect_accepted <class> <label> <expected-user> -- <argv…>
#   The redundancy case, and the over-fire control for every refusal above it. ws must get through
#   the parser and resolve exactly the identity named — silently.
expect_accepted() {
  local class="$1" label="$2" want="$3"; shift 3
  shift   # the --
  local out rc=0
  out="$(_run "$NEUTER" "$@")" || rc=$?
  if [[ "$rc" -eq 97 || "$rc" -eq 98 ]]; then
    _record "$class" "$label" "HARNESS: could not source/dispatch (rc ${rc}): ${out}"; return
  fi
  if grep -q 'SELFTEST-VIOLATION' <<<"$out"; then
    _record "$class" "$label" "HARNESS: reached oc — a stub is missing: ${out}"; return
  fi
  if [[ "$rc" -ne 0 ]]; then
    _record "$class" "$label" "refused a harmless command (rc ${rc}): $(tr '\n' ' ' <<<"$out")"; return
  fi
  if ! grep -qF "PARSE-OK user=${want}" <<<"$out"; then
    _record "$class" "$label" "resolved the wrong identity (wanted user=${want}): $(tr '\n' ' ' <<<"$out")"; return
  fi
  _record "$class" "$label" ok
}

# expect_quiet <class> <label> -- <argv…>
#   The detector's own over-fire control: called directly, it must return 0 and say NOTHING. A guard
#   that returns 0 while printing a warning would train people to ignore it.
expect_quiet() {
  local class="$1" label="$2"; shift 2
  shift   # the --
  local out rc=0
  out="$(_run "$NEUTER" "$@")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _record "$class" "$label" "got ${rc}, expected 0 (silent acceptance); output: $(tr '\n' ' ' <<<"$out")"; return
  fi
  if [[ -n "$out" ]]; then
    _record "$class" "$label" "returned 0 but printed: $(tr '\n' ' ' <<<"$out")"; return
  fi
  _record "$class" "$label" ok
}

# ── the suite ────────────────────────────────────────────────────────────────────────────────────
# Runs against whatever NEUTER is set to. Called once per mode.
run_suite() {
  R_OK=0; R_BAD=0; R_DETAIL=""; R_SEEN=""
  local v

  # 1. The detector's own contract, called directly. Separated from its call sites so a wiring bug
  #    and a logic bug cannot be mistaken for each other.
  expect_refusal conflict "guard: user3 vs user4 names both" \
    "two different attendees" "'user3'" "'user4'" -- @call user_conflict_guard user3 user4 prep
  expect_refusal conflict "guard: --all-users vs user3 names the SCOPE mistake" \
    "DIFFERENT scopes" "user3" -- @call user_conflict_guard --all-users user3 start
  expect_refusal conflict "guard: user3 vs --all-users (other order)" \
    "DIFFERENT scopes" "user3" -- @call user_conflict_guard user3 --all-users start

  # 2. Every verb main() parses, in BOTH orders. The second order is the one that was silent.
  for v in prep start verify smoke reset solve; do
    expect_refusal conflict "${v}: positional user3 then --user user4 (THE measured defect)" \
      "two different attendees" "'user3'" "'user4'" -- "$v" m07 user3 --user user4
    expect_refusal conflict "${v}: --user user4 then positional user3" \
      "two different attendees" "'user3'" "'user4'" -- "$v" m07 --user user4 user3
    expect_accepted control "${v}: the two spellings AGREE — proceeds silently" user3 \
      -- "$v" m07 user3 --user user3
    expect_accepted control "${v}: the two spellings AGREE, other order" user3 \
      -- "$v" m07 --user user3 user3
  done
  for v in doctor status diag; do
    expect_refusal conflict "${v}: positional user3 then --user user4" \
      "two different attendees" "'user3'" "'user4'" -- "$v" user3 --user user4
    expect_refusal conflict "${v}: --user user4 then positional user3" \
      "two different attendees" "'user3'" "'user4'" -- "$v" --user user4 user3
    expect_accepted control "${v}: the two spellings AGREE" user3 -- "$v" user3 --user user3
  done

  # 3. The verbs that parse their own flags — main()'s gate never sees these, so each re-implements
  #    the binding and each needed the gate wired separately.
  expect_refusal conflict "rebuild-images: positional then --user" \
    "two different attendees" "'user3'" "'user4'" -- rebuild-images user3 --user user4
  expect_refusal conflict "rebuild-images: --user then positional" \
    "two different attendees" "'user3'" "'user4'" -- rebuild-images --user user4 user3
  expect_accepted control "rebuild-images: spellings agree" user3 -- rebuild-images user3 --user user3

  expect_refusal conflict "maas show: positional then --user" \
    "two different attendees" "'user3'" "'user4'" -- maas show user3 --user user4
  expect_refusal conflict "maas show: --user then positional" \
    "two different attendees" "'user3'" "'user4'" -- maas show --user user4 user3
  expect_accepted control "maas show: spellings agree" user3 -- maas show user3 --user user3

  expect_refusal conflict "maas set: positional then --user" \
    "two different attendees" "'user3'" "'user4'" -- maas set user3 --user user4
  expect_refusal conflict "maas set: --user then positional" \
    "two different attendees" "'user3'" "'user4'" -- maas set --user user4 user3

  # 4. Repeated --user. Same shape, one spelling: git-refresh/session-refresh/passwd take no
  #    positional user at all, so this is the only way to give them two disagreeing identities.
  expect_refusal conflict "prep: --user user3 --user user4" \
    "two different attendees" "'user3'" "'user4'" -- prep m07 --user user3 --user user4
  expect_refusal conflict "git-refresh: --user user3 --user user4" \
    "two different attendees" "'user3'" "'user4'" -- git-refresh --user user3 --user user4
  expect_refusal conflict "session-refresh: --user user3 --user user4" \
    "two different attendees" "'user3'" "'user4'" -- session-refresh --user user3 --user user4
  expect_refusal conflict "passwd: --user user3 --user user4" \
    "two different attendees" "'user3'" "'user4'" -- passwd --user user3 --user user4
  expect_refusal conflict "rebuild-images: --user user3 --user user4" \
    "two different attendees" "'user3'" "'user4'" -- rebuild-images --user user3 --user user4
  expect_accepted control "git-refresh: repeated --user AGREES" user3 \
    -- git-refresh --restart-terminals --user user3 --user user3
  expect_accepted control "session-refresh: repeated --user AGREES" user3 \
    -- session-refresh --user user3 --user user3
  expect_accepted control "passwd: repeated --user AGREES" user3 -- passwd --user user3 --user user3

  # 5. --all-users is a SCOPE, and mixing it with a named attendee silently widened `ws start` from
  #    one attendee to the whole cohort. Its own message, because "two different attendees" is not
  #    what went wrong.
  expect_refusal conflict "start: positional user3 then --all-users (silent cohort widening)" \
    "DIFFERENT scopes" "user3" -- start m07 user3 --all-users
  expect_refusal conflict "start: --all-users then positional user3" \
    "DIFFERENT scopes" "user3" -- start m07 --all-users user3

  # 6. A bare token that is not a user and not the module used to be dropped in silence, and the
  #    command then acted on whoever `oc whoami` returned — or, for doctor/status, on the WHOLE
  #    COHORT. Same class as bug #102, quieter.
  expect_refusal positional "prep: mistyped attendee 'usr3' is not swallowed" \
    "unexpected argument 'usr3'" "userN" -- prep m07 usr3
  expect_refusal positional "doctor: mistyped attendee does not silently widen to the cohort" \
    "unexpected argument 'usr3'" -- doctor usr3
  expect_refusal positional "status: mistyped attendee is named" \
    "unexpected argument 'usr3'" -- status usr3
  expect_refusal positional "diag: a third bare token is refused" \
    "unexpected argument 'usr3'" -- diag m07 usr3

  # 7. Controls the fix must not have broken. Every one of these was a working command before.
  expect_accepted control "prep: bare positional alone still works" user3 -- prep m07 user3
  expect_accepted control "prep: --user alone still works" user3 -- prep m07 --user user3
  expect_accepted control "prep: --yes still reaches cmd_prep" user3 -- prep m07 user3 --yes
  expect_accepted control "verify: dash flags still pass through to the verify script" user3 \
    -- verify m07 user3 --entry-only
  expect_accepted control "diag: module + user still resolve" user3 -- diag user3 m07
  expect_accepted control "list: no attendee, so a stray token keeps today's tolerance" "" -- list mm
  expect_quiet control "guard: identical values are harmless redundancy — 0, silently" \
    -- @call user_conflict_guard user3 user3 prep
  expect_quiet control "guard: nothing bound yet — 0, silently" \
    -- @call user_conflict_guard "" user4 prep

  # 8. The shape checks that already existed must still fire, and must WIN over the conflict gate:
  #    `--user 1` is one thing to fix, not an argument about which attendee was meant.
  expect_refusal control "shape: user3x is still rejected as a bad token" \
    "bad user token 'user3x'" -- prep m07 user3x
  expect_refusal control "shape: --user 1 is still rejected (bug #102)" \
    "you meant 'user1'" -- prep m07 --user 1
  expect_refusal control "shape: 'user3 --user 1' names the TYPO, not a conflict" \
    "you meant 'user1'" -- prep m07 user3 --user 1
}

# ── modes ────────────────────────────────────────────────────────────────────────────────────────
NEUTER=""

_report_failures() {
  local line
  while IFS='|' read -r class label detail; do
    [[ -n "${class:-}" ]] || continue
    fail "${class}: ${label}"
    note "$detail"
  done <<<"$R_DETAIL"
  line=""   # keep shellcheck from thinking `line` is unused if the loop body changes
  : "$line"
}

run_real() {  # → 0 contract holds, 1 broken, 2 nothing inspected
  NEUTER=""
  run_suite
  if [[ $((R_OK + R_BAD)) -eq 0 ]]; then
    fail "the suite ran no assertions at all — nothing was inspected."
    return 2
  fi
  if [[ "$R_BAD" -ne 0 ]]; then
    fail "tools/ws/ws does not refuse every disagreeing attendee spelling (${R_BAD} of $((R_OK + R_BAD)) assertions failed):"
    _report_failures
    return 1
  fi
  pass "ws refuses two disagreeing attendee spellings on every verb that takes one (${R_OK} assertions):"
  echo "   both orders of positional-vs---user across prep/start/verify/smoke/reset/solve/doctor/status/diag,"
  echo "   rebuild-images and maas show|set; repeated --user on git-refresh/session-refresh/passwd; --all-users"
  echo "   mixed with a named attendee; a mistyped attendee token is named instead of dropped; and agreeing"
  echo "   spellings, --yes, --entry-only and the existing shape checks all still behave exactly as before."
  return 0
}

# A canary run: neuter ONE detector and require every assertion it protects to fail — and to fail in
# the RIGHT way. "Some assertion failed" is not proof: the neutered detector must let the bad input
# through to a resolved identity (rc 0), which is precisely the silent defect. Controls must be
# untouched, or the neuter broke the parser rather than the detector and certifies nothing.
run_canary() {  # <neuter> <class-it-protects> → 0 every canary caught, 1 not caught
  local neuter="$1" class="$2"
  NEUTER="$neuter"
  run_suite
  local n_class=0 n_slipped=0 lbl detail c
  while IFS='|' read -r c lbl; do
    [[ "${c:-}" == "$class" ]] && n_class=$((n_class + 1))
  done <<<"$R_SEEN"
  if [[ "$n_class" -eq 0 ]]; then
    fail "canary '${neuter}': the suite has no '${class}' assertions — the canary would certify nothing."
    return 1
  fi
  # every failing assertion of this class, and WHY it failed
  local caught=0
  while IFS='|' read -r c lbl detail; do
    [[ "${c:-}" == "$class" ]] || continue
    caught=$((caught + 1))
    if ! grep -q 'got 0,' <<<"$detail"; then
      fail "canary '${neuter}': '${lbl}' failed, but not by letting the input through — ${detail}"
      note "a canary that fires for the wrong reason proves the assertion is fragile, not that the detector works."
      return 1
    fi
    n_slipped=$((n_slipped + 1))
  done <<<"$R_DETAIL"
  if [[ "$caught" -ne "$n_class" ]]; then
    fail "canary '${neuter}': only ${caught} of ${n_class} '${class}' assertions failed with the detector removed."
    note "the ones that still passed are not testing ${neuter} — they would go green with the guard deleted."
    _report_failures
    return 1
  fi
  # The over-fire proof: neutering one detector must not disturb anything else.
  local other_bad=0
  while IFS='|' read -r c lbl detail; do
    [[ -n "${c:-}" ]] || continue
    if [[ "$c" != "$class" ]]; then
      fail "canary '${neuter}': it also broke a ${c} assertion — '${lbl}': ${detail}"
      other_bad=1
    fi
  done <<<"$R_DETAIL"
  if [[ "$other_bad" -ne 0 ]]; then
    note "the override changed more than the detector, so 'every assertion failed' would mean nothing."
    return 1
  fi
  pass "canary '${neuter}': all ${n_slipped} '${class}' assertions let the bad input through to a resolved identity; every control held."
  return 0
}

self_test() {
  # Proof 0. Canaries certify a detector against a tree the detector already passes. If the real run
  # is red, saying "the canaries fired" would be a green tick over a broken CLI.
  NEUTER=""
  run_suite
  if [[ "$R_BAD" -ne 0 ]]; then
    fail "SELF-TEST could not run: the shipped tools/ws/ws fails ${R_BAD} of its own assertions."
    _report_failures
    note "run without --self-test and fix the tree first."
    return 2
  fi

  # The overrides must actually shadow something. An override of a function that was renamed would
  # leave the real detector in place, every canary assertion would keep passing, and the failure
  # would read as "the detector is fine" — the exact inversion this file exists to prevent.
  local fn
  for fn in user_conflict_guard unexpected_positional; do
    if ! grep -qE "^${fn}\(\)" "$WS"; then
      fail "SELF-TEST could not run: tools/ws/ws defines no ${fn}() — the canary override would shadow nothing."
      return 2
    fi
  done

  run_canary conflict   conflict   || return 1
  run_canary positional positional || return 1

  pass "self-test ok — with user_conflict_guard neutered every conflict assertion resolves an identity"
  echo "   instead of refusing, and with unexpected_positional neutered every mistyped token is silently"
  echo "   dropped again; in both runs the controls (agreeing spellings, --yes, --entry-only, the shape"
  echo "   checks) stayed green, so each canary implicates exactly one detector."
  # House convention (tools/lint/_parse-guard-args.sh): --self-test exits EXACTLY 1 on success.
  return 1
}

# ── entry point ──────────────────────────────────────────────────────────────────────────────────
# Own parser rather than tools/lint/_parse-guard-args.sh — this file is outside tools/lint and must
# not couple to it. It obeys the same contract: an unrecognised argument is NAMED and exits 2, never
# silently ignored, because a mistyped flag that falls through to the plain run is a maintainer
# believing they proved something they never ran.
SELF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           fail "unknown argument: '$1'"; usage >&2; exit 2 ;;
  esac
done

if [[ ! -r "$WS" ]]; then
  fail "cannot read ${WS} — nothing to inspect."
  exit 2
fi

if [[ "$SELF" -eq 1 ]]; then
  self_test
  exit $?
fi
run_real
exit $?
