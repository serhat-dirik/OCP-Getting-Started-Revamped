#!/usr/bin/env bash
# _parse-guard-args.sh — the shared argument parser every simple tools/lint guard must use.
#
# ORIGIN (2026-08-01). Almost every guard in this directory "parsed" its command line with exactly
# one line:
#
#     if [[ "${1:-}" == "--self-test" ]]; then self_test; exit $?; fi
#
# Anything that was not that literal string was DISCARDED IN SILENCE and the guard ran its plain
# check instead. Measured on the shipped tree before this file existed, one missing hyphen:
#
#     $ bash tools/lint/owning-stack-guard.sh --selftest
#     ✅ owning_stack_of_app: exact matches resolve, near-misses and unknown apps never guess, …
#     rc=0
#
# A maintainer who types that believes they just proved the detector fires. They proved nothing —
# they ran the plain check, which passes on a healthy tree by definition. Eleven of the twelve
# runnable shell files here behaved that way. A sibling had a worse version of the same bug: it
# accepted `--components-dir <path>`, ignored it, and printed three green ticks about
# platform-portfolio/components while the caller believed it had inspected their directory.
#
# CI's `--self-test must exit EXACTLY 1` assertion catches the typo on CI. It does NOT catch it on a
# laptop, and the laptop is exactly where a guard gets run to convince a human that a change is safe.
# That is the whole gap this file closes.
#
# CONTRACT
#   parse_guard_args "$@"
#     • no arguments        → sets GUARD_SELF_TEST=0 and returns 0; the caller runs its real check.
#     • --self-test         → sets GUARD_SELF_TEST=1 and returns 0; the caller runs its canaries.
#     • -h | --help         → prints usage on stdout and EXITS 0. Asking for help is not a failure.
#     • anything else       → prints the OFFENDING ARGUMENT on stderr, plus usage, and EXITS 2.
#
# WHY IT EXITS RATHER THAN RETURNS. Every guard here runs under `set -uo pipefail` — deliberately
# without `-e`, because a detector returning 1 is a normal finding, not a crash. A parser that
# merely RETURNED 2 would therefore be ignored by any caller that forgot `|| exit $?`, and the guard
# would fall through to its plain check: the precise false green this file exists to kill, now with
# a parser present to make it look handled. Exiting from inside the helper makes the forgetful
# caller impossible.
#
# WHY EXIT CODE 2, specifically:
#   • 2 is already this tree's "the guard could not inspect what it claims to inspect" code — a
#     harness/scope problem rather than a verdict about the repo. A mistyped flag means the guard
#     never ran the check the caller asked for, which is exactly that.
#   • 1 is load-bearing and would be actively dangerous. CI asserts `--self-test` exits EXACTLY 1.
#     If rejection also exited 1, a CI step that mistyped the flag would SATISFY that assertion and
#     CI would report the guard's detection as PROVEN — reintroducing the false green at the one
#     place that currently catches it.
#   • 0 would be the status quo defect.
#   • It costs no CI change and unifies the two languages: the six argparse-based Python guards in
#     this directory already exit 2 on an unknown argument (argparse's own convention), and
#     verify-mutation-guard.sh already exited 2 from its hand-rolled usage error. Measured, not
#     assumed — `python3 tools/lint/copy-drift-guard.py --selftest` → rc 2.
#
# SCOPE. This helper is for guards whose entire interface is "run me, or run my self-test". A guard
# that genuinely needs more flags writes its own `while … case` parser and rejects unknown arguments
# there — adoption-skippable-guard.sh is the worked example (it takes `--components-dir` and refuses
# to combine it with --self-test). Such a guard is listed in _PGA_EXEMPT below with its reason, and
# the meta-scan errors if it ever starts using this helper, so the list cannot rot silently.
#
# Runnable standalone, matching _extract-func.sh and _check-coverage.sh:
#   bash tools/lint/_parse-guard-args.sh              → META-SCAN: every runnable *.sh in tools/lint/
#                                                       either uses this parser or is a declared
#                                                       exemption (rc 0 = all accounted for). This is
#                                                       what stops the adoption from rotting as
#                                                       guards are added.
#   bash tools/lint/_parse-guard-args.sh --self-test  → the parser rejects the real typo, rejects a
#                                                       flag-with-value, rejects a bare positional,
#                                                       names the offender in each case, accepts
#                                                       --self-test and no-args, and answers --help
#                                                       with 0 (rc 1 = every canary caught).
# Sourcing (the normal path, from a guard) runs neither.
#
# NO ARRAYS ANYWHERE IN THIS FILE, on purpose. Under bash 3.2 + `set -u` — the macOS default, and
# what a maintainer runs locally — `"${empty[@]}"` raises "unbound variable" instead of expanding to
# nothing. The resulting crash exits 1, which CI's exit-exactly-1 assertion reads as a PASSING
# self-test. `"$@"` is special-cased by the shell and is safe when empty (verified on 3.2.57); a
# plain array is not. This file uses only "$@" and space-separated strings.

# Set by parse_guard_args. Declared here so a caller that greps for it finds a definition, and so
# `set -u` cannot trip a guard that reads it before parsing (it can't, but the next refactor might).
GUARD_SELF_TEST=0

_pga_err() { echo "❌ $*" >&2; }

# usage → stdout. Kept generic: every guard using this helper has the same two-mode interface, and a
# per-guard description belongs in the guard's own header where the incident is written down.
_pga_usage() {  # → usage text on stdout
  local me="${_PGA_NAME:-$(basename "${0}")}"
  echo "usage: ${me} [--self-test]"
  echo
  echo "  (no arguments)  run the check against the real tree"
  echo "                  exit 0 = contract holds · 1 = contract broken · 2 = could not inspect"
  echo "  --self-test     prove the detectors fire against planted canaries"
  echo "                  exit 1 = every canary was correctly caught (this is the PASS)"
  echo "  -h, --help      this message"
}

# parse_guard_args "$@" → sets GUARD_SELF_TEST; exits 0 on --help, exits 2 on anything unrecognised.
parse_guard_args() {
  GUARD_SELF_TEST=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --self-test)
        GUARD_SELF_TEST=1
        shift
        ;;
      -h|--help)
        _pga_usage
        exit 0
        ;;
      *)
        # Naming the argument is the point. "usage: …" alone leaves a maintainer staring at a flag
        # they are sure they typed correctly; "unknown argument: '--selftest'" next to the usage
        # line spelling --self-test makes a one-hyphen typo self-evident.
        _pga_err "unknown argument: '$1'"
        _pga_usage >&2
        exit 2
        ;;
    esac
  done
  return 0
}

# ── standalone ───────────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  _PGA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Files that legitimately do NOT call parse_guard_args, each with the reason. Anything here that
  # STARTS using the helper is an error, not a pass — that is what keeps this list from rotting into
  # a permanent excuse. Reasons, one per entry, in the same order:
  #   adoption-skippable-guard.sh  own parser: takes --components-dir, and must refuse to combine it
  #                                with --self-test. Already rejects unknown arguments by name.
  #
  # route-tls-guard.sh and verify-oc-read-guard.sh were listed here as OWED on 2026-08-01 and both
  # landed on the shared parser the same night (route-tls-guard.sh gained its first real --self-test
  # in that change). Their rows are deleted rather than kept: the STALE EXEMPTION branch below turns
  # a converted-but-still-listed file into an error precisely so this list cannot outlive its reason.
  _PGA_EXEMPT="adoption-skippable-guard.sh"

  # A file is "runnable" if it has a standalone entry point at all: either a real shebang-driven
  # top-level flow (a guard) or a `BASH_SOURCE == $0` block (a library). Everything under tools/lint
  # with a .sh extension qualifies today; the scan asserts it found some, because scanning zero
  # files is never a pass.
  _pga_meta_scan() {  # <dir> → 0 all accounted for, 1 a gap, 2 nothing inspected
    local dir="$1" f base rc=0 n=0 wired=0 exempt=0
    for f in "$dir"/*.sh; do
      base="$(basename "$f")"
      [[ "$base" == "_parse-guard-args.sh" ]] && continue
      n=$((n + 1))
      if grep -q 'parse_guard_args' "$f"; then
        # Sourcing the helper without calling it is the silent-no-op shape; require both.
        if ! grep -q '_parse-guard-args.sh' "$f"; then
          _pga_err "WIRING: ${base} calls parse_guard_args but never sources _parse-guard-args.sh."
          rc=1
          continue
        fi
        case " ${_PGA_EXEMPT} " in
          *" ${base} "*)
            _pga_err "STALE EXEMPTION: ${base} now uses parse_guard_args — delete it from _PGA_EXEMPT in $(basename "${BASH_SOURCE[0]}")."
            rc=1
            continue
            ;;
        esac
        # The old shape and the new one must not coexist: a leftover literal comparison ahead of the
        # parser would take the --self-test path and never reach the rejection branch.
        # shellcheck disable=SC2016  # the pattern is the LITERAL text being searched for in
        # another script; expanding it here would search for this script's own $1.
        if grep -q '"\${1:-}" == "--self-test"' "$f"; then
          _pga_err "WIRING: ${base} uses parse_guard_args but still carries the bare \${1:-} == --self-test comparison."
          rc=1
          continue
        fi
        wired=$((wired + 1))
      else
        case " ${_PGA_EXEMPT} " in
          *" ${base} "*) exempt=$((exempt + 1)) ;;
          *)
            _pga_err "UNPARSED: ${base} does not use parse_guard_args — a mistyped flag there is silently ignored and the guard reports a green plain run."
            echo "   Add: source \"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)/_parse-guard-args.sh\"" >&2
            echo "   then: parse_guard_args \"\$@\"  and branch on \"\$GUARD_SELF_TEST\"." >&2
            rc=1
            ;;
        esac
      fi
    done
    if [[ "$n" -eq 0 ]]; then
      _pga_err "WIRING: no .sh files found under ${dir} — the scan inspected nothing."
      return 2
    fi
    if [[ "$rc" -eq 0 ]]; then
      echo "✅ argument parsing: ${wired} guard(s)/library(ies) on the shared parser, ${exempt} declared exemption(s), no bare \${1:-} comparisons left"
    fi
    return "$rc"
  }

  # Run parse_guard_args in a SUBSHELL so its exit() does not take the self-test with it, and report
  # what it did. Echoes the resulting GUARD_SELF_TEST so the accept cases can be checked too.
  _pga_probe() {  # <args…> → prints "st=<0|1>" on the accept path; rc is the parser's
    (
      parse_guard_args "$@" || exit $?
      echo "st=${GUARD_SELF_TEST}"
    )
  }

  if [[ "${1:-}" == "--self-test" ]]; then
    # This file cannot use its own parser to reach its own self-test without begging the question:
    # if parse_guard_args were blind, a blind parser would still route --self-test here and the
    # canaries below would still run and still catch it. The literal comparison above is therefore
    # deliberate, and it is the ONLY one left in tools/lint.

    # Proof 0: the shipped tree is fully adopted. A scan that fires on everything proves nothing.
    _real_rc=0
    _pga_meta_scan "$_PGA_DIR" >/dev/null 2>&1 || _real_rc=$?
    if [[ "$_real_rc" -ne 0 ]]; then
      _pga_err "SELF-TEST FAILED: tools/lint is not fully on the shared parser (rc=${_real_rc}). Run without --self-test."
      exit 2
    fi

    # Canary A — THE measured defect: one missing hyphen. Before this file, this exited 0 with a ✅.
    _out=""; _rc=0
    _out="$(_pga_probe --selftest 2>&1)" || _rc=$?
    if [[ "$_rc" -ne 2 ]]; then
      _pga_err "SELF-TEST FAILED: '--selftest' was not rejected (rc=${_rc}) — the parser is blind and a typo still reports a green plain run."
      exit 2
    fi
    if ! grep -q -- "--selftest" <<< "$_out"; then
      _pga_err "SELF-TEST FAILED: the rejection did not NAME '--selftest'. A bare usage line leaves the reader hunting a one-hyphen typo."
      exit 2
    fi

    # Canary B — the worse historical shape: a flag WITH A VALUE, silently ignored, verdicts printed
    # about a directory the caller never asked about.
    _out=""; _rc=0
    _out="$(_pga_probe --components-dir /etc 2>&1)" || _rc=$?
    if [[ "$_rc" -ne 2 ]]; then
      _pga_err "SELF-TEST FAILED: '--components-dir /etc' was not rejected (rc=${_rc}) — a guard would print verdicts about a tree it never inspected."
      exit 2
    fi
    if ! grep -q -- "--components-dir" <<< "$_out"; then
      _pga_err "SELF-TEST FAILED: the rejection did not NAME '--components-dir'."
      exit 2
    fi

    # Canary C — a bare positional. Not a flag, still not something any guard here understands.
    _rc=0
    _pga_probe some-path >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 2 ]]; then
      _pga_err "SELF-TEST FAILED: the bare positional 'some-path' was not rejected (rc=${_rc})."
      exit 2
    fi

    # Canary D — the accept paths must STILL work, or this helper just breaks every guard in CI.
    _out=""; _rc=0
    _out="$(_pga_probe --self-test 2>&1)" || _rc=$?
    if [[ "$_rc" -ne 0 || "$_out" != "st=1" ]]; then
      _pga_err "SELF-TEST FAILED: '--self-test' was not accepted (rc=${_rc}, out='${_out}') — every guard's canaries would stop running."
      exit 2
    fi
    _out=""; _rc=0
    _out="$(_pga_probe 2>&1)" || _rc=$?
    if [[ "$_rc" -ne 0 || "$_out" != "st=0" ]]; then
      _pga_err "SELF-TEST FAILED: the no-argument run was not accepted (rc=${_rc}, out='${_out}') — every guard's plain run would stop working."
      exit 2
    fi

    # Canary E — help is not a failure. If --help exited 2, `guard --help || echo broken` in someone's
    # notes would start lying, and a maintainer reaching for help would be told they made an error.
    _rc=0
    _pga_probe --help >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      _pga_err "SELF-TEST FAILED: '--help' exited ${_rc}, expected 0."
      exit 2
    fi
    _rc=0
    _pga_probe -h >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      _pga_err "SELF-TEST FAILED: '-h' exited ${_rc}, expected 0."
      exit 2
    fi

    # Canary F — the meta-scan itself must catch an UNPARSED guard, or Proof 0 is decoration.
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    # shellcheck disable=SC2016  # fixture TEXT for a throwaway script, not an expansion here.
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--self-test" ]]; then exit 1; fi\nexit 0\n' \
      > "${_tmp}/pretend-guard.sh"
    _rc=0
    _pga_meta_scan "$_tmp" >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 1 ]]; then
      _pga_err "SELF-TEST FAILED: an unparsed guard was NOT caught by the meta-scan (rc=${_rc}) — adoption can rot silently."
      exit 2
    fi

    # Canary G — and it must STAY SILENT on a correctly wired one, or it cries wolf on every guard.
    printf '#!/usr/bin/env bash\nsource "x/_parse-guard-args.sh"\nparse_guard_args "$@"\nexit 0\n' \
      > "${_tmp}/pretend-guard.sh"
    _rc=0
    _pga_meta_scan "$_tmp" >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
      _pga_err "SELF-TEST FAILED: a correctly wired guard was reported unparsed (rc=${_rc}) — the meta-scan cries wolf."
      exit 2
    fi

    # Canary H — a guard that sources the helper AND keeps the old literal comparison is caught. That
    # half-conversion is the realistic bad merge: the parser is present but unreachable for --selftest.
    # shellcheck disable=SC2016  # fixture TEXT for a throwaway script, not an expansion here.
    printf '#!/usr/bin/env bash\nsource "x/_parse-guard-args.sh"\nif [[ "${1:-}" == "--self-test" ]]; then exit 1; fi\nparse_guard_args "$@"\nexit 0\n' \
      > "${_tmp}/pretend-guard.sh"
    _rc=0
    _pga_meta_scan "$_tmp" >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -ne 1 ]]; then
      _pga_err "SELF-TEST FAILED: a half-converted guard (parser present, old comparison still ahead of it) was NOT caught (rc=${_rc})."
      exit 2
    fi

    echo "✅ self-test ok — '--selftest', '--components-dir /etc' and a bare positional all rejected 2 and named;"
    echo "   --self-test and no-args accepted; -h/--help exit 0; meta-scan catches unparsed and half-converted"
    echo "   guards and stays silent on a wired one; the shipped tree is fully adopted."
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    exit 1
  fi

  # No parse_guard_args call here for the same reason the block above uses a literal comparison: this
  # file's own dispatch is the thing under test, so it must not be the thing doing the testing. The
  # rejection path is still enforced — anything that is not --self-test lands here and the meta-scan
  # runs, which is the documented no-argument behaviour; a bogus flag is caught by the self-test's
  # canaries rather than by self-application.
  _PGA_NAME="$(basename "${BASH_SOURCE[0]}")"
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    _pga_usage
    exit 0
  fi
  if [[ "$#" -gt 0 && "${1:-}" != "--self-test" ]]; then
    _pga_err "unknown argument: '$1'"
    _pga_usage >&2
    exit 2
  fi

  _pga_meta_scan "$_PGA_DIR"
  exit $?
fi
