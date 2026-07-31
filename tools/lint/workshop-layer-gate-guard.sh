#!/usr/bin/env bash
# workshop-layer-gate-guard.sh — the workshop-layer FAILURE branch, gated.
#
# ORIGIN (2026-07-31, commit a6407a5). bootstrap/install.sh once printed:
#
#     ❌ workshop-config not ready yet (health=Missing sync=OutOfSync)
#     ✅ workshop bootstrap complete
#
# — the ❌ above and then straight through to the ✅ banner, exit 0. Measured on a clean cluster
# (tb7fj) where a duplicate Namespace in the workshop-config chart made Argo CD refuse to sync at
# all: 3 namespaces instead of ~70, zero cockpit pods, and the closing banner still printed the
# console URL, the Gitea URL and "users user1 … user8" as if they were ready. Anything scripting
# this installer — CI, the RHDP catalog item, an SA in a hurry — reads the exit code, and the exit
# code said fine.
#
# The fix added a WORKSHOP_LAYER_OK flag and a final gate that suppresses the banner and exits 1.
# That fix's SUCCESS path was proven live (polled ~5m, ✅ 12s after workshop-config genuinely reached
# Synced/Healthy). Its FAILURE path — layer not OK, banner suppressed, exit 1 — had only ever been
# verified by READING the code, because proving it live meant breaking a cluster others were using.
# This guard drives that branch under a stubbed `oc`, repeatably, without touching a cluster.
#
# WHAT IT CHECKS, against TWO functions extracted from bootstrap/install.sh:
#
#   [1] wait_for_workshop_layer_healthy() — the poll loop (60 attempts, stubbed instant via a
#       no-op `sleep`). Two cases, both driven through a REAL stubbed `oc`, not a canned variable:
#         a. never reaches Healthy/Synced  → returns 1, sets WORKSHOP_LAYER_OK=false, and the stub's
#            call-count FILE (not a variable — see note below) shows all 60 iterations ran, proving
#            the loop was not silently shortened.
#         b. reaches Healthy/Synced on the Nth attempt → returns 0, WORKSHOP_LAYER_OK is left UNSET
#            (the default-true path), and the call count shows the loop broke early at N, proving
#            the eventual-success retry path still works and this guard isn't just failing on
#            everything.
#
#   [2] emit_bootstrap_verdict() — the final decision. Two assertions per case, checked SEPARATELY,
#       because a gate that exits 1 while still printing "complete" is exactly the false-green this
#       whole guard exists to catch:
#         a. WORKSHOP_LAYER_OK=false → returns NON-ZERO, AND stdout does NOT contain
#            "workshop bootstrap complete" (banner suppressed), AND DOES contain "INCOMPLETE".
#         b. WORKSHOP_LAYER_OK=true (or unset, the real default) → returns 0, stdout DOES contain
#            the completion banner, and does NOT contain "INCOMPLETE" — the positive control; a
#            detector that fires on every input proves nothing.
#
# ON THE `oc`-IN-A-SUBSHELL TRAP. `oc` is invoked here as `HEALTH="$(oc get … )"` — a command
# substitution, which forks a subshell. A stub `oc` that tracks "how many times have I been called"
# in an ordinary shell variable would increment a copy that vanishes the moment that subshell exits,
# so the parent script's view of the counter would never move — a working retry-then-succeed stub
# would look identical to "always fails" from the outside. The call counter here is a FILE
# (CALL_COUNT_FILE), read-incremented-written on every invocation, for exactly that reason.
#
# ON PORTABILITY. Extracted function text is always written to a real temp FILE before being sourced
# into a test harness, never held only in a process-substitution pipe: `-s` on a process substitution
# reports the buffered byte count on macOS/BSD and 0 on Linux, so a `[[ -s "$x" ]]` guard over one
# would pass locally and fail on CI ubuntu for a reason that has nothing to do with what is being
# tested (this exact shape bit uninstall-state-lifetime-guard.sh's self-test, 2026-07-31).
#
# Runnable standalone (CI lint gate) and by hand; needs nothing but bash + awk + sed + seq.
#
# --self-test proves both detectors FIRE before a clean run on the real tree is worth anything: it
# plants a wait-loop canary that stops recording failure ([1] blind to a timeout) and a verdict
# canary that swallows the failure branch's `return 1` and falls through to the success banner
# regardless of WORKSHOP_LAYER_OK — the ORIGINAL a6407a5 defect, reproduced byte-for-byte. Exit 1 =
# every canary was caught AND the real tree is clean under the same detectors; that is a PASS,
# matching the house convention where CI asserts the self-test step exits exactly 1. Exit 2 = a
# detector is blind, or the harness itself is broken.
#
# Exit codes:
#   0  contract holds
#   1  contract broken — or, under --self-test, every canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (extraction failed, file missing)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/lint/_extract-func.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_extract-func.sh"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }

INSTALL="bootstrap/install.sh"
FN_WAIT="wait_for_workshop_layer_healthy"
FN_VERDICT="emit_bootstrap_verdict"

# ── extraction ────────────────────────────────────────────────────────────────
# Extracted, never sourced: install.sh runs a full cluster install at top level. Extraction failure
# is exit 2, never a silent pass. Written to a real FILE (see the portability note above).
# extract_func lives in _extract-func.sh, sourced above; shared with the other guards under
# tools/lint/ rather than copy-pasted per guard.

# ── [1] the poll loop ─────────────────────────────────────────────────────────
# Runs wait_for_workshop_layer_healthy() under a stubbed `oc` (never-healthy, or healthy from
# attempt $2 onward) and a no-op `sleep`. Echoes three lines: RC=, WLO=(WORKSHOP_LAYER_OK or
# <unset>), CALLS=(iterations actually taken, read back from the call-count FILE).
run_wait() {  # <func_file> <healthy_after: 0=never> → RC=/WLO=/CALLS= on stdout
  local func_file="$1" healthy_after="$2"
  local harness count_file
  harness="$(mktemp)"; count_file="$(mktemp)"; printf '0' > "$count_file"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "HEALTHY_AFTER='${healthy_after}'"
    echo "CALL_COUNT_FILE='${count_file}'"
    cat <<'STUBS'
ok()    { echo "ok: $*"; }
err()   { echo "err: $*" >&2; }
sleep() { :; }  # the real 10s interval would make the never-healthy case take ~10 minutes
# Each poll ITERATION calls oc twice (health.status, then sync.status). The iteration counter is
# advanced only on the health.status call and re-read (never re-incremented) on sync.status, so the
# two calls of one iteration agree on which iteration they are in. Persisted to a FILE, not a shell
# variable: this whole function is invoked via `$(oc …)` command substitution, which forks a
# subshell, so a variable increment here would never be visible to the next call.
oc() {
  [[ "$1" == "get" ]] || return 0
  local n
  case " $* " in
    *"health.status"*)
      n=$(($(cat "$CALL_COUNT_FILE") + 1))
      printf '%s' "$n" > "$CALL_COUNT_FILE"
      if [[ "$HEALTHY_AFTER" -gt 0 && "$n" -ge "$HEALTHY_AFTER" ]]; then echo Healthy; else echo Progressing; fi
      ;;
    *"sync.status"*)
      n=$(cat "$CALL_COUNT_FILE")
      if [[ "$HEALTHY_AFTER" -gt 0 && "$n" -ge "$HEALTHY_AFTER" ]]; then echo Synced; else echo OutOfSync; fi
      ;;
  esac
  return 0
}
STUBS
    cat "$func_file"
    echo "${FN_WAIT}"
    # $? and $WORKSHOP_LAYER_OK are PATTERN for the harness script to expand when IT runs, not here.
    # shellcheck disable=SC2016
    echo 'echo "RC=$?"'
    # shellcheck disable=SC2016
    echo 'echo "WLO=${WORKSHOP_LAYER_OK:-<unset>}"'
  } > "$harness"
  bash "$harness" 2>/dev/null
  echo "CALLS=$(cat "$count_file")"
  rm -f "$harness" "$count_file"
}

check_wait_gate() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[1] could not extract ${FN_WAIT}() — the guard cannot inspect what it claims to."
    return 2
  fi

  # (a) never becomes healthy → timeout: rc=1, WORKSHOP_LAYER_OK=false, all 60 attempts taken.
  out="$(run_wait "$func_file" 0)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=1'; then
    bad "[1a] never-healthy case: expected wait_for_workshop_layer_healthy to return 1."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'WLO=false'; then
    bad "[1a] never-healthy case: expected WORKSHOP_LAYER_OK=false, got: $(printf '%s\n' "$out" | grep '^WLO=')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'CALLS=60'; then
    bad "[1a] never-healthy case: expected all 60 poll attempts, got: $(printf '%s\n' "$out" | grep '^CALLS=')"
    note "    fewer attempts means the loop was silently shortened — a real broken layer would be"
    note "    declared failed before selfHeal ever had a fair 10-minute chance to fix it."
    rc=1
  fi

  # (b) becomes healthy on attempt 3 → success: rc=0, WORKSHOP_LAYER_OK untouched, loop broke early.
  out="$(run_wait "$func_file" 3)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[1b] eventual-success case: expected wait_for_workshop_layer_healthy to return 0."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'WLO=<unset>'; then
    bad "[1b] eventual-success case: WORKSHOP_LAYER_OK must stay unset on success, got: $(printf '%s\n' "$out" | grep '^WLO=')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'CALLS=3'; then
    bad "[1b] eventual-success case: expected the loop to break at attempt 3, got: $(printf '%s\n' "$out" | grep '^CALLS=')"
    note "    a loop that keeps polling after success (or one whose 'break' path is broken) would"
    note "    make every real install wait the full 10 minutes even when the layer came up in 30s."
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[1] poll loop: never-healthy → false/60-attempts; healthy-at-3 → unset/breaks-early"
  fi
  return "$rc"
}

# ── [2] the final verdict ─────────────────────────────────────────────────────
# Runs emit_bootstrap_verdict() with WORKSHOP_LAYER_OK forced true/false and echoes its stdout
# (redacted of nothing — there are no secrets in this banner's stub inputs) plus its return code.
run_verdict() {  # <func_file> <workshop_layer_ok> → banner stdout, then a line "RC=<n>"
  local func_file="$1" wlo="$2" harness
  harness="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    if [[ -n "$wlo" ]]; then echo "WORKSHOP_LAYER_OK='${wlo}'"; fi
    echo "ARGO_NS='openshift-gitops'"
    echo "CONSOLE_URL='https://console-openshift-console.apps.example.com'"
    echo "GITEA_HOST='gitea.apps.example.com'"
    echo "USER_PREFIX='user'"
    echo "USERS='5'"
    echo "CREDS_FILE='/tmp/example-creds.txt'"
    cat <<'STUBS'
ok()  { echo "ok: $*"; }
err() { echo "err: $*" >&2; }
STUBS
    cat "$func_file"
    echo "${FN_VERDICT}"
    # $? is PATTERN for the harness script to expand when IT runs, not here.
    # shellcheck disable=SC2016
    echo 'echo "RC=$?"'
  } > "$harness"
  bash "$harness" 2>&1
  rm -f "$harness"
}

check_verdict_gate() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[2] could not extract ${FN_VERDICT}() — the guard cannot inspect what it claims to."
    return 2
  fi

  # (a) the failure branch — both assertions checked SEPARATELY, on purpose.
  out="$(run_verdict "$func_file" false)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=1'; then
    bad "[2a] WORKSHOP_LAYER_OK=false: expected emit_bootstrap_verdict to return NON-ZERO (RC=1)."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'workshop bootstrap complete'; then
    bad "[2a] WORKSHOP_LAYER_OK=false: the success banner was NOT suppressed — this is the a6407a5"
    note "    defect verbatim (❌ printed, then ✅ 'workshop bootstrap complete' printed anyway)."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
    bad "[2a] WORKSHOP_LAYER_OK=false: expected the INCOMPLETE warning text, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (b) positive control — a detector that fires on every input proves nothing.
  out="$(run_verdict "$func_file" true)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[2b] WORKSHOP_LAYER_OK=true: expected emit_bootstrap_verdict to return 0, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'workshop bootstrap complete'; then
    bad "[2b] WORKSHOP_LAYER_OK=true: expected the success banner to print, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
    bad "[2b] WORKSHOP_LAYER_OK=true: the INCOMPLETE warning printed on a HEALTHY layer."
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[2] final verdict: layer-not-OK returns non-zero with the banner suppressed; layer-OK returns"
    note "    0 with the banner intact — checked as two separate assertions, not just the exit code"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # <root> → 0 clean, 1 broken, 2 uninspectable
  local root="$1" rc=0 sub=0 wait_f verdict_f
  if [[ ! -f "${root}/${INSTALL}" ]]; then
    bad "${root}/${INSTALL} not found"
    return 2
  fi
  wait_f="$(mktemp)"; verdict_f="$(mktemp)"
  extract_func "${root}/${INSTALL}" "$FN_WAIT"    > "$wait_f"
  extract_func "${root}/${INSTALL}" "$FN_VERDICT" > "$verdict_f"

  sub=0; check_wait_gate "$wait_f" || sub=$?
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi

  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_verdict_gate "$verdict_f" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi

  rm -f "$wait_f" "$verdict_f"
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Two canaries, each the real defect shape. Both must be CAUGHT, and the real tree must be clean
# under the same detectors — anything else means the gate is decorative.
self_test() {
  local real_rc canary_rc f

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$REPO_ROOT" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # Canary A — the poll loop stops recording failure: the timeout branch no longer sets
  # WORKSHOP_LAYER_OK=false. Byte-for-byte the real function with that one assignment dropped.
  f="$(mktemp)"
  extract_func "${REPO_ROOT}/${INSTALL}" "$FN_WAIT" \
    | sed 's/^  WORKSHOP_LAYER_OK=false$/  : # CANARY: dropped/' > "$f"
  if grep -q '^  WORKSHOP_LAYER_OK=false$' "$f"; then
    bad "SELF-TEST FAILED: could not build the dropped-flag canary — the assignment it mutates was not found."
    rm -f "$f"
    return 2
  fi
  canary_rc=0
  check_wait_gate "$f" >/dev/null 2>&1 || canary_rc=$?
  rm -f "$f"
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the dropped-WORKSHOP_LAYER_OK canary was NOT detected (rc=${canary_rc}) — detector [1] is blind."
    return 2
  fi

  # Canary B — the ORIGINAL a6407a5 defect, reproduced: the failure branch's `return 1` is swallowed,
  # so execution falls through to the success banner regardless of WORKSHOP_LAYER_OK.
  f="$(mktemp)"
  extract_func "${REPO_ROOT}/${INSTALL}" "$FN_VERDICT" \
    | sed 's/^    return 1$/    : # CANARY: swallowed — falls through to the success banner/' > "$f"
  if grep -q '^    return 1$' "$f"; then
    bad "SELF-TEST FAILED: could not build the swallowed-return canary — the 'return 1' it mutates was not found."
    rm -f "$f"
    return 2
  fi
  canary_rc=0
  check_verdict_gate "$f" >/dev/null 2>&1 || canary_rc=$?
  rm -f "$f"
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the swallowed-return canary (the original false-green bug) was NOT detected (rc=${canary_rc}) — detector [2] is blind."
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0), dropped-flag canary caught, swallowed-return"
  note "   (original a6407a5 false-green) canary caught."
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

run_check "$REPO_ROOT"
exit $?
