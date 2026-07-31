#!/usr/bin/env bash
# _extract-func.sh — shared "materialize a shell function from a real script" walker.
#
# Sourced by the tools/lint/*-guard.sh scripts that drive REAL install/uninstall code rather than a
# reimplementation of it (extraction, never sourcing the real script — bootstrap/install.sh and
# bootstrap/ogsr-uninstall.sh run a full imperative flow at top level, and sourcing them would
# execute it). Extraction failure is the caller's problem: this file never exits or prints on the
# empty-match case, it just yields no output, exactly like the walkers it replaces did.
#
# ORIGIN (2026-07-31). Six guards each carried a hand-copied version of this walker, and every copy
# but one terminated a function's body at a bare `}` on its own line. That breaks on a ONE-LINE
# function such as bootstrap/ogsr-check-clean.sh's:
#   state_get() { grep -m1 "^${1}=" <<< "$STATE_KV" | cut -d= -f2- ; }
# — there is no bare `}` line to stop at, so extraction runs off the end of the function and
# swallows every subsequent definition in the file, which then silently OVERRIDES the guard's own
# stubs. The guard still runs and still reports success; the defect is invisible. One guard
# (uninstall-operand-order-guard.sh) had already independently fixed this in its own copy; this file
# generalizes that fix and removes the other five copies rather than patching each by hand.
#
# THE FIX: also stop the moment the OPENING line already closes its own brace
# ($0 ~ /}[ \t]*$/) — i.e. treat "name() { ...; }" as a complete, one-line match instead of falling
# through to "wait for a bare closing brace that will never come".
#
# extract_func <file> <name>
#   → function text on stdout. Matches a function whose definition starts at column 0 of a line,
#     spelled "name() {" or "name(){".
#
# extract_func_indented <file> <name>
#   → same, but first de-indents a fixed 14-column prefix. The one caller
#     (uninstall-state-lifetime-guard.sh) needs this because its target function is embedded in a
#     YAML block scalar (helm/bootstrap/templates/job-state-capture.yaml), so every line — including
#     the one that would otherwise match at column 0 — carries that indent.
extract_func() {  # <file> <name> → function text on stdout
  awk -v fn="$2" '
    index($0, fn "() {") == 1 || index($0, fn "(){") == 1 {
      inside = 1
      if ($0 ~ /}[ \t]*$/) { print; exit }
    }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

extract_func_indented() {  # <file> <name> → function text on stdout, de-indented
  sed -E 's/^ {14}//' "$1" | awk -v fn="$2" '
    index($0, fn "() {") == 1 || index($0, fn "(){") == 1 {
      inside = 1
      if ($0 ~ /}[ \t]*$/) { print; exit }
    }
    inside { print }
    inside && $0 == "}" { exit }
  '
}

# ── canary: proves the one-line case is actually handled, not just fixed-in-one-place ─────────────
# Reimplementation of the ORIGINAL (broken) walker, kept ONLY so --self-test can show the canary
# fixture really does reproduce the swallow on the pre-fix logic. Never used by any guard.
_extract_func_broken_reference() {
  awk -v fn="$2" '
    index($0, fn "() {") == 1 { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

_extract_func_self_test() {
  local tmp rc=0 out
  tmp="$(mktemp)"
  cat > "$tmp" <<'FIXTURE'
one_liner() { echo "hi"; }
after() { echo "after-body"; }
FIXTURE

  # Proof A: the fixture is the real defect shape — the broken walker DOES swallow "after".
  if ! _extract_func_broken_reference "$tmp" one_liner | grep -q '^after() {'; then
    echo "❌ SELF-TEST FAILED: the one-liner fixture does not reproduce the swallow under the pre-fix walker — this canary is not testing the real bug." >&2
    rm -f "$tmp"
    return 2
  fi

  # Proof B: the walker every guard now sources does NOT swallow it, and extracts the one-liner
  # verbatim (nothing more, nothing less).
  out="$(extract_func "$tmp" one_liner)"
  if grep -q 'after' <<< "$out"; then
    echo "❌ SELF-TEST FAILED: extract_func swallowed the definition after a one-line function — the bug is back." >&2
    rc=2
  elif [[ "$out" != 'one_liner() { echo "hi"; }' ]]; then
    echo "❌ SELF-TEST FAILED: extract_func did not extract the one-liner verbatim (got: '${out}')." >&2
    rc=2
  else
    echo "✅ one-line function extraction stops at its own closing brace and does not swallow later definitions"
  fi
  rm -f "$tmp"

  # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
  if [[ "$rc" -eq 0 ]]; then return 1; fi
  return "$rc"
}

# Runnable standalone, matching the other tools/lint/*.sh gates: `bash tools/lint/_extract-func.sh`
# proves the fixed walker handles the real one-line function in the tree (rc 0); `--self-test` proves
# the fix is load-bearing (rc 1). Sourcing (the normal path, from a guard) runs neither.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  if [[ "${1:-}" == "--self-test" ]]; then
    _extract_func_self_test
    exit $?
  fi

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  CHECKCLEAN="${REPO_ROOT}/bootstrap/ogsr-check-clean.sh"
  if [[ ! -f "$CHECKCLEAN" ]]; then
    echo "❌ ${CHECKCLEAN} not found" >&2
    exit 2
  fi
  real_out="$(extract_func "$CHECKCLEAN" state_get)"
  if [[ -z "$real_out" ]]; then
    echo "❌ extract_func could not find state_get() in ${CHECKCLEAN}" >&2
    exit 2
  fi
  if grep -q '^state_ops' <<< "$real_out"; then
    echo "❌ extract_func swallowed state_ops() while extracting the one-line state_get() from ${CHECKCLEAN}" >&2
    exit 1
  fi
  echo "✅ extract_func handles ${CHECKCLEAN}'s one-line state_get() without swallowing state_ops()"
  exit 0
fi
