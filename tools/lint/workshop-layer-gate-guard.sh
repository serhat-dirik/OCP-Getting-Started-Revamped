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
# WHAT IT CHECKS, against TWO functions extracted from bootstrap/install.sh. Every assertion carries
# a [case/property] TAG, and the tag is the first thing its failure message prints — the self-test's
# canary table asserts on those tags, so "which assertion fired" is a measured fact rather than an
# inference from the exit code (see THE TAGS, below):
#
#   [1] wait_for_workshop_layer_healthy() — the poll loop (60 attempts, stubbed instant via a
#       no-op `sleep`). Two cases, both driven through a REAL stubbed `oc`, not a canned variable:
#         a. never reaches Healthy/Synced  → returns 1 [1a/rc], sets WORKSHOP_LAYER_OK=false
#            [1a/flag], and the stub's call-count FILE (not a variable — see note below) shows all
#            60 iterations ran [1a/attempts], proving the loop was not silently shortened.
#         b. reaches Healthy/Synced on the Nth attempt → returns 0 [1b/rc], WORKSHOP_LAYER_OK is
#            left UNSET (the default-true path) [1b/flag], and the call count shows the loop broke
#            early at N [1b/attempts], proving the eventual-success retry path still works and this
#            guard isn't just failing on everything.
#
#   [2] emit_bootstrap_verdict() — the final decision. Three assertions per case, checked
#       SEPARATELY, because a gate that exits 1 while still printing "complete" is exactly the
#       false-green this whole guard exists to catch:
#         a. WORKSHOP_LAYER_OK=false → returns NON-ZERO [2a/rc], AND stdout does NOT contain
#            "workshop bootstrap complete" (banner suppressed) [2a/banner], AND DOES contain
#            "INCOMPLETE" [2a/incomplete].
#         b. WORKSHOP_LAYER_OK=true (or unset, the real default) → returns 0 [2b/rc], stdout DOES
#            contain the completion banner [2b/banner], and does NOT contain "INCOMPLETE"
#            [2b/no-incomplete] — the positive control; a detector that fires on every input proves
#            nothing.
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
# --self-test proves the detectors actually fire before a clean run on the real tree is worth
# anything. ONE CANARY PER ASSERTION, plus the composite historical shape.
#
# WHY THAT MANY (audit, 2026-08-06). This guard shipped with two canaries — a dropped
# WORKSHOP_LAYER_OK=false and the swallowed `return 1`. Measured by deleting each assertion in turn
# and re-running: only ONE of the fourteen (the [1a/flag] assertion) made --self-test stop exiting 1,
# and ten were never reached by either canary at all — including both loop-length proofs
# ([1a/attempts], [1b/attempts]) and the ENTIRE positive control ([1b/*], [2b/*]), the very case
# whose header comment says "a detector that fires on every input proves nothing". They were
# certified without ever being proven.
#
# THE TAGS are what closed that hole. Each canary declares the EXACT SET of assertion tags it must
# provoke, and the self-test fails if the set differs — too few (the assertion is inert, or a
# neighbour is silently covering for it) or too many (the mutant is broken outright and is failing
# assertions it never actually exercised, which certifies them for the wrong reason). Deleting any
# one assertion therefore shrinks some canary's fired set and reddens the self-test.
#
# Exit 1 = every canary was caught by exactly its own assertions AND the real tree is clean under the
# same detectors; that is a PASS, matching the house convention where CI asserts the self-test step
# exits exactly 1. Exit 2 = an assertion is blind, a canary is a no-op, or the harness itself is
# broken.
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

INSTALL="bootstrap/install.sh"
FN_WAIT="wait_for_workshop_layer_healthy"
FN_VERDICT="emit_bootstrap_verdict"

# ── extraction ────────────────────────────────────────────────────────────────
# Extracted, never sourced: install.sh runs a full cluster install at top level. Extraction failure
# is exit 2, never a silent pass. Written to a real FILE (see the portability note above).
# extract_func lives in _extract-func.sh, sourced above; shared with the other guards under
# tools/lint/ rather than copy-pasted per guard.

# Pulls "KEY=<value>" back out of a harness transcript so a failure message can NAME what it
# measured instead of dumping the whole transcript and leaving the reader to diff it by eye.
# "<absent>" when the line never appeared — itself a measurement, and never a disjunction.
field() {  # <transcript> <key> → the key's value, or <absent>
  local v
  v="$(printf '%s\n' "$1" | grep -m1 "^${2}=" | cut -d= -f2-)"
  printf '%s' "${v:-<absent>}"
}

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
  ran_check
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[1x/extract] the extracted ${FN_WAIT}() is EMPTY (0 bytes) — the guard cannot inspect what it claims to."
    note "    ${INSTALL} no longer defines a function by that name at column 0, or the walker broke."
    return 2
  fi

  # (a) never becomes healthy → timeout: rc=1, WORKSHOP_LAYER_OK=false, all 60 attempts taken.
  out="$(run_wait "$func_file" 0)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=1'; then
    bad "[1a/rc] a layer that never reaches Healthy/Synced must return 1 — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'WLO=false'; then
    bad "[1a/flag] the timeout must record WORKSHOP_LAYER_OK=false — measured WLO=$(field "$out" WLO)."
    note "    without that flag the final gate has nothing to gate on, which is the a6407a5 defect."
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'CALLS=60'; then
    bad "[1a/attempts] the never-healthy case must take all 60 poll attempts — measured CALLS=$(field "$out" CALLS)."
    note "    fewer attempts means the loop was silently shortened — a real broken layer would be"
    note "    declared failed before selfHeal ever had a fair 10-minute chance to fix it."
    rc=1
  fi

  # (b) becomes healthy on attempt 3 → success: rc=0, WORKSHOP_LAYER_OK untouched, loop broke early.
  out="$(run_wait "$func_file" 3)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[1b/rc] a layer that reaches Healthy/Synced on attempt 3 must return 0 — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'WLO=<unset>'; then
    bad "[1b/flag] WORKSHOP_LAYER_OK must stay UNSET on success (the default-true path) — measured WLO=$(field "$out" WLO)."
    note "    a flag left at false on a healthy layer makes every good install report INCOMPLETE."
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'CALLS=3'; then
    bad "[1b/attempts] the loop must break at attempt 3, the attempt that first read Healthy/Synced —"
    note "    measured CALLS=$(field "$out" CALLS)."
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
  ran_check
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[2x/extract] the extracted ${FN_VERDICT}() is EMPTY (0 bytes) — the guard cannot inspect what it claims to."
    note "    ${INSTALL} no longer defines a function by that name at column 0, or the walker broke."
    return 2
  fi

  # (a) the failure branch — all three assertions checked SEPARATELY, on purpose.
  out="$(run_verdict "$func_file" false)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=1'; then
    bad "[2a/rc] WORKSHOP_LAYER_OK=false must return NON-ZERO — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'workshop bootstrap complete'; then
    bad "[2a/banner] WORKSHOP_LAYER_OK=false printed the success banner — 'workshop bootstrap complete'"
    note "    was emitted on a layer that never came up. This is the a6407a5 defect verbatim (❌ printed,"
    note "    then ✅ 'workshop bootstrap complete' printed anyway)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
    bad "[2a/incomplete] WORKSHOP_LAYER_OK=false must say INCOMPLETE — no line containing 'INCOMPLETE' was emitted."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (b) positive control — a detector that fires on every input proves nothing.
  out="$(run_verdict "$func_file" true)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[2b/rc] WORKSHOP_LAYER_OK=true must return 0 — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'workshop bootstrap complete'; then
    bad "[2b/banner] WORKSHOP_LAYER_OK=true must print the completion banner — no line containing"
    note "    'workshop bootstrap complete' was emitted, so a good install would look like a failed one."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
    bad "[2b/no-incomplete] WORKSHOP_LAYER_OK=true printed the INCOMPLETE warning on a HEALTHY layer."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[2] final verdict: layer-not-OK returns non-zero with the banner suppressed; layer-OK returns"
    note "    0 with the banner intact — checked as separate assertions, not just the exit code"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # <root> → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
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
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── canaries ──────────────────────────────────────────────────────────────────
# Each canary is ONE realistic regression applied to the REAL extracted text of the function named
# in the table below — never to a re-implementation of it, and never to the guard's own assertions.
# Full-line replacements throughout: awk's sub() treats `&` in the replacement as the matched text,
# and several of these lines contain `&&`.
#
# The `$HEALTH`, `$0`, `$(seq …)` and friends below are LITERAL TEXT being written into (or matched
# against) install.sh's own source, not expansions of anything in this script.
# shellcheck disable=SC2016
canary_mutate() {  # <id> → mutated function text on stdout, real function text on stdin
  case "$1" in
    # ── [1] wait_for_workshop_layer_healthy ──
    timeout-returns-zero)
      awk '$0=="  return 1"{print "  return 0  # CANARY: the timeout stops failing"; next}
           {print}' ;;
    timeout-forgets-flag)
      # The fix ITSELF, undone: the timeout no longer records the failure for the final gate.
      awk '$0=="  WORKSHOP_LAYER_OK=false"{print "  : # CANARY: dropped -- the timeout records nothing"; next}
           {print}' ;;
    loop-shortened)
      awk '/for _i in \$\(seq 1 60\); do/{print "  for _i in $(seq 1 5); do  # CANARY: loop silently shortened"; next}
           {print}' ;;
    success-returns-nonzero)
      awk '/workshop-config is Synced\/Healthy/{a=1}
           a && $0=="    return 0"{print "    return 1  # CANARY: a layer that DID come up is reported as failed"; a=0; next}
           {print}' ;;
    flag-set-unconditionally)
      # The pessimistic-init slip: set the flag false up front, forget to clear it on success. Every
      # good install then reports INCOMPLETE and exits 1.
      awk '$0=="  HEALTH=\"\"; SYNC=\"\""{print "  HEALTH=\"\"; SYNC=\"\"; WORKSHOP_LAYER_OK=false  # CANARY: never cleared on success"; next}
           {print}' ;;
    break-removed)
      awk '/&& break$/{print "    [[ \"$HEALTH\" == \"Healthy\" && \"$SYNC\" == \"Synced\" ]] && : # CANARY: never breaks out of the poll loop"; next}
           {print}' ;;

    # ── [2] emit_bootstrap_verdict ──
    verdict-returns-zero)
      awk '$0=="    return 1"{print "    return 0  # CANARY: the not-OK verdict stops failing"; next}
           {print}' ;;
    verdict-falls-through)
      # THE ORIGINAL a6407a5 DEFECT, reproduced: the failure branch's `return 1` is swallowed, so
      # execution falls through to the success banner regardless of WORKSHOP_LAYER_OK.
      awk '$0=="    return 1"{print "    : # CANARY: swallowed -- falls through to the success banner"; next}
           {print}' ;;
    banner-hoisted)
      awk 'NR==1{print; print "  ok \"workshop bootstrap complete\"  # CANARY: banner emitted above the gate"; next}
           {print}' ;;
    incomplete-not-named)
      # The replacement must not itself contain the word the assertion greps for. The first draft
      # of this canary explained itself as "the INCOMPLETE marker is gone" and therefore printed
      # INCOMPLETE, satisfying [2a/incomplete] and going undetected — a canary that mutates the
      # message and then re-supplies the very token under test proves nothing.
      awk '/workshop bootstrap INCOMPLETE/{print "    err \"workshop bootstrap did not finish (CANARY: the marker word is gone) — the platform installed but the workshop layer did not\""; next}
           {print}' ;;
    healthy-returns-nonzero)
      awk '$0=="}"{print "  return 1  # CANARY: a healthy layer still exits non-zero"}
           {print}' ;;
    banner-suppressed-on-success)
      awk '$0=="  ok \"workshop bootstrap complete\""{print "  : # CANARY: the completion banner is gone"; next}
           {print}' ;;
    incomplete-warning-hoisted)
      awk 'NR==1{print; print "  err \"workshop bootstrap INCOMPLETE — CANARY: emitted unconditionally\""; next}
           {print}' ;;
  esac
}

# Build one canary and prove it is a real, PARSABLE mutation of the real function before trusting
# anything it does. Both failure modes are caught here rather than downstream:
#   • a canary that changed nothing (the line it anchors on was renamed) is caught by nothing and
#     proves nothing — it would sail through as "the detector stayed green, so it must be fine";
#   • a canary that no longer PARSES fails every assertion at once for a reason that has nothing to
#     do with the property under test, certifying assertions it never actually exercised.
build_canary() {  # <fn> <id> <outfile> → 0 built, 2 unbuildable
  local fn="$1" id="$2" out="$3" src="${3}.src"
  extract_func "${REPO_ROOT}/${INSTALL}" "$fn" > "$src"
  if [[ ! -s "$src" ]]; then
    bad "SELF-TEST FAILED: canary '${id}' — ${fn}() could not be extracted from ${INSTALL}."
    rm -f "$src"; return 2
  fi
  canary_mutate "$id" < "$src" > "$out"
  if cmp -s "$src" "$out"; then
    bad "SELF-TEST FAILED: canary '${id}' changed NOTHING — the line it anchors on is no longer in ${fn}()."
    note "    a no-op canary is caught by nothing and proves nothing. Re-anchor it on the current text."
    rm -f "$src"; return 2
  fi
  if ! bash -n "$out" 2>/dev/null; then
    bad "SELF-TEST FAILED: canary '${id}' does not parse as bash — a mutant that is broken OUTRIGHT"
    note "    fails every assertion at once, which certifies assertions it never actually exercised."
    rm -f "$src"; return 2
  fi
  rm -f "$src"
  return 0
}

# Which assertions a detector run actually reported. Every failure message begins with its own
# [case/property] tag, so this is a measurement of WHICH assertions fired — not an inference from
# the exit code, which cannot tell three simultaneous failures from one.
reported_tags() {  # <detector output> → sorted, comma-joined tag list
  printf '%s\n' "$1" | grep -oE '\[[a-z0-9]{1,2}/[a-z-]+\]' | sort -u | tr '\n' ','
}
norm_tags() {  # <comma-separated tags> → sorted, comma-joined, deduplicated
  printf '%s' "$1" | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ','
}

# ── self-test ─────────────────────────────────────────────────────────────────
self_test() {
  local real_rc canary_rc out got want f n=0
  local id fn detector expect label

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$REPO_ROOT" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # Proof 1: both extraction guards, DRIVEN rather than read. An empty extraction must be rc 2
  # ("could not inspect"), never rc 1 ("the installer is broken") and never a green run.
  for detector in check_wait_gate check_verdict_gate; do
    out="$("$detector" /dev/null 2>&1)"; canary_rc=$?
    if [[ "$canary_rc" -ne 2 ]]; then
      bad "SELF-TEST FAILED: ${detector} did not report an EMPTY extracted function as uninspectable —"
      note "    it returned ${canary_rc}, expected 2. A failed extraction must never read as a verdict about the installer."
      return 2
    fi
    got="$(reported_tags "$out")"
    case "$detector" in
      check_wait_gate)    want="$(norm_tags '[1x/extract]')" ;;
      check_verdict_gate) want="$(norm_tags '[2x/extract]')" ;;
    esac
    if [[ "$got" != "$want" ]]; then
      bad "SELF-TEST FAILED: ${detector}'s empty-extraction path fired ${got:-<no assertions>}, expected exactly ${want}."
      return 2
    fi
  done

  # Proof 2…N: one canary per assertion, each declaring the EXACT SET of tags it must provoke.
  # Too few = that assertion is inert (or a neighbour is covering for it); too many = the mutant is
  # broken outright and is failing assertions it never exercised.
  while IFS='|' read -r id fn detector expect label; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    f="$(mktemp)"
    if ! build_canary "$fn" "$id" "$f"; then rm -f "$f" "${f}.src"; return 2; fi
    out="$("$detector" "$f" 2>&1)"; canary_rc=$?
    rm -f "$f"
    if [[ "$canary_rc" -ne 1 ]]; then
      bad "SELF-TEST FAILED: canary '${id}' (${label}) — ${detector} returned ${canary_rc}, expected 1."
      note "    the assertion(s) that should have caught it: ${expect}"
      note "    detector output: $(printf '%s' "$out" | tr '\n' ' ')"
      return 2
    fi
    got="$(reported_tags "$out")"; want="$(norm_tags "$expect")"
    if [[ "$got" != "$want" ]]; then
      bad "SELF-TEST FAILED: canary '${id}' (${label}) fired the WRONG assertions."
      note "    expected exactly: ${want:-<none>}"
      note "    actually fired  : ${got:-<none>}"
      note "    a tag that is missing means that assertion is inert — certified without ever being proven."
      note "    a tag that is extra means the mutant is failing an assertion it does not actually exercise."
      note "    detector output: $(printf '%s' "$out" | tr '\n' ' ')"
      return 2
    fi
  done <<'CANARIES'
timeout-returns-zero|wait_for_workshop_layer_healthy|check_wait_gate|[1a/rc]|the poll-loop timeout stops returning failure
timeout-forgets-flag|wait_for_workshop_layer_healthy|check_wait_gate|[1a/flag]|THE FIX UNDONE: the timeout no longer records WORKSHOP_LAYER_OK=false
loop-shortened|wait_for_workshop_layer_healthy|check_wait_gate|[1a/attempts]|the 60-attempt poll loop is silently shortened to 5
success-returns-nonzero|wait_for_workshop_layer_healthy|check_wait_gate|[1b/rc]|a layer that DID come up is reported as failed
flag-set-unconditionally|wait_for_workshop_layer_healthy|check_wait_gate|[1b/flag]|WORKSHOP_LAYER_OK is set false up front and never cleared on success
break-removed|wait_for_workshop_layer_healthy|check_wait_gate|[1b/attempts]|the loop keeps polling for 10 minutes after Healthy/Synced
verdict-returns-zero|emit_bootstrap_verdict|check_verdict_gate|[2a/rc]|the not-OK verdict stops exiting non-zero
verdict-falls-through|emit_bootstrap_verdict|check_verdict_gate|[2a/rc],[2a/banner]|THE a6407a5 DEFECT: the return is swallowed and the banner prints anyway
banner-hoisted|emit_bootstrap_verdict|check_verdict_gate|[2a/banner]|the success banner is emitted above the gate
incomplete-not-named|emit_bootstrap_verdict|check_verdict_gate|[2a/incomplete]|the failure stops saying INCOMPLETE
healthy-returns-nonzero|emit_bootstrap_verdict|check_verdict_gate|[2b/rc]|a healthy layer's verdict returns non-zero
banner-suppressed-on-success|emit_bootstrap_verdict|check_verdict_gate|[2b/banner]|the completion banner stops printing on a healthy layer
incomplete-warning-hoisted|emit_bootstrap_verdict|check_verdict_gate|[2b/no-incomplete]|the INCOMPLETE warning is emitted unconditionally
CANARIES

  ok "self-test ok — real tree clean (rc=0); ${n} canaries + both empty-extraction paths, each caught"
  note "by exactly the assertion(s) written for it (deleting any one assertion shrinks a canary's"
  note "fired tag set and reddens this run)."
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
