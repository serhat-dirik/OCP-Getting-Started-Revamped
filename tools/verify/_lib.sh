#!/usr/bin/env bash
# Shared helpers for per-module verify scripts (tools/verify/mNN.sh).
# Contract: each script takes --user U (default user1) and optional --entry-only,
# checks ENTRY state (what `ws start` materializes) and, unless --entry-only,
# END state (what a completed lab looks like); exits 0 only if all checks pass.
# Output style: one line per check, ✅/❌ + fix hint. CI runs these standalone.

VERIFY_PASS=0
VERIFY_FAIL=0

check() {  # check "<description>" <command...>  — pass/fail one assertion
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "✅ ${desc}"
    VERIFY_PASS=$((VERIFY_PASS+1))
    return 0
  else
    echo "❌ ${desc}"
    VERIFY_FAIL=$((VERIFY_FAIL+1))
    return 1
  fi
}

hint() { echo "   ↳ fix: $*"; }

verify_summary() {  # call at end of every script
  echo
  if (( VERIFY_FAIL == 0 )); then
    echo "✅ all ${VERIFY_PASS} checks passed"
    exit 0
  else
    echo "❌ ${VERIFY_FAIL} of $((VERIFY_PASS+VERIFY_FAIL)) checks failed"
    exit 1
  fi
}

parse_verify_args() {  # sets USER_NAME, ENTRY_ONLY from "$@"
  USER_NAME="user1"
  ENTRY_ONLY="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) USER_NAME="$2"; shift 2;;
      --entry-only) ENTRY_ONLY="true"; shift;;
      *) echo "unknown arg: $1" >&2; exit 2;;
    esac
  done
}
