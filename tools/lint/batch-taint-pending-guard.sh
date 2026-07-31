#!/usr/bin/env bash
# batch-taint-pending-guard.sh — the batch-pool taint starvation gate, gated.
#
# ORIGIN. bootstrap/install.sh's assert_no_batch_taint_pending() exists because of the exact incident
# diagnosed live 2026-07-30: on a 2-worker cluster, tainting one worker for the batch pool left the
# survivor at 99% memory requests, RHACS central-db (8Gi + 4 CPU) Pending for 3h+, Central
# crashlooping on a DB that never came up, and the trusted-supply-chain module's scan gate dead — with
# the install reporting every Argo app Healthy the whole time. The assert reads well (it even reasons
# carefully about attribution: a stock CRC node carries its own disk-pressure taint, so a bare "was
# something Pending" check would blame our taint for something that is not ours), but it had never
# been driven — proving it live means starving a real namespace on a real cluster. This guard drives
# it under a stubbed `oc`, repeatably, without touching a cluster.
#
# WHAT IT CHECKS, against assert_no_batch_taint_pending() from bootstrap/install.sh:
#
#   (0) BATCH_TAINTED=false (no taint applied this run) → returns 0, prints the skip note, and
#       touches `oc` ZERO times — proven via a call-count FILE (see the subshell note below), not by
#       reading the code, so a future refactor that starts querying the cluster on the skip path
#       cannot pass this silently.
#   (a) taint applied, zero Pending pods cluster-wide → returns 0, reports "0 Pending pods... nothing
#       to flag" (a real, reportable outcome — not a silent pass, per the function's own header note).
#   (b) taint applied, a Pending pod exists but TOLERATES our taint key → excluded from concern,
#       returns 0, "none blocked by the ... taint".
#   (c) THE REAL INCIDENT SHAPE: a Pending pod does not tolerate our taint, its FailedScheduling event
#       cites an untolerated taint, and our taint is the ONLY blocking taint on the batch node →
#       returns NON-ZERO, and the message names the RHACS central-db incident text verbatim (proof
#       this is reporting the real thing, not a generic message that happens to satisfy a grep).
#   (d) THE FALSE-POSITIVE THIS ASSERT EXISTS TO AVOID: a Pending pod cites an untolerated taint, but
#       the batch node ALSO carries an unrelated blocking taint (e.g. disk-pressure) → returns 0 (not
#       attributable to us), but still surfaces a warning naming the ambiguity — proof the attribution
#       logic the header comment describes is real, not just asserted in prose.
#
# ON THE `oc`-IN-A-SUBSHELL TRAP (case 0). `oc` calls inside this function are read via `$(oc …)` and
# `<(oc …)` — both fork subshells — so a stub that counts "was I called" in an ordinary shell variable
# would increment a copy that vanishes the instant the subshell exits, and a broken skip-path (one
# that quietly starts querying the cluster) would look identical to "never called" from the outside.
# The call counter here is a FILE, read-incremented-written on every invocation, for exactly that
# reason (the same trap workshop-layer-gate-guard.sh documents for its own poll-loop check).
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
# anything: it plants a canary that drops the `flagged=$((flagged + 1))` increment — the one line
# that turns "a Pending pod is blocked by our taint alone" into a reported failure — so case (c), the
# real incident shape, would silently fall through to the "none blocked" pass message instead. Exit
# 1 = the canary was caught AND the real tree is clean under the same detector; that is a PASS,
# matching the house convention where CI asserts the self-test step exits exactly 1. Exit 2 = the
# detector is blind, or the harness itself is broken.
#
# Exit codes:
#   0  contract holds
#   1  contract broken — or, under --self-test, the canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (extraction failed, file missing)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }

INSTALL="bootstrap/install.sh"
FN_ASSERT="assert_no_batch_taint_pending"

# ── extraction ────────────────────────────────────────────────────────────────
# Extracted, never sourced: install.sh runs a full cluster install at top level. Extraction failure
# is exit 2, never a silent pass. Written to a real FILE (see the portability note above).
extract_func() {  # <file> <name> → function text on stdout
  awk -v fn="$2" '
    index($0, fn "() {") == 1 { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

# ── harness ───────────────────────────────────────────────────────────────────
# Runs assert_no_batch_taint_pending() under a stubbed `oc`, one scenario per call, and echoes
# combined stdout+stderr, then "RC=<n>", then "CALLS=<n>" (oc invocation count, read back from the
# call-count FILE — see the subshell note above).
run_batch() {  # <func_file> <scenario: skip|zero|tolerates|blocked|ambiguous> → banner, RC=, CALLS=
  local func_file="$1" scenario="$2" harness count_file
  local tainted=true node_taints="" pending_pods="" tolerations="" event_msg=""
  case "$scenario" in
    skip)
      tainted=false
      ;;
    zero)
      node_taints="workshop.redhat.com/pool=NoSchedule"
      pending_pods=""
      ;;
    tolerates)
      node_taints="workshop.redhat.com/pool=NoSchedule"
      pending_pods=$'ns-a pod-a'
      tolerations="workshop.redhat.com/pool other-key"
      ;;
    blocked)
      # THE REAL INCIDENT SHAPE: our taint is the ONLY blocking taint on the node.
      node_taints="workshop.redhat.com/pool=NoSchedule"
      pending_pods=$'rhacs-operator-system central-db-0'
      tolerations=""
      event_msg="0/2 nodes are available: 1 Insufficient memory, 1 node(s) had untolerated taint(s)."
      ;;
    ambiguous)
      # the batch node ALSO carries an unrelated taint (e.g. disk-pressure) — not attributable to us.
      node_taints=$'workshop.redhat.com/pool=NoSchedule\nnode.kubernetes.io/disk-pressure=NoSchedule'
      pending_pods=$'ns-b pod-b'
      tolerations=""
      event_msg="0/1 nodes are available: 1 node(s) had untolerated taint(s)."
      ;;
  esac
  harness="$(mktemp)"; count_file="$(mktemp)"; printf '0' > "$count_file"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "BATCH_TAINTED='${tainted}'"
    echo "MIN_BATCH_POOL_FOR_TAINT=3"
    echo "POOL_LABEL_KEY='workshop.redhat.com/pool'"
    echo "BATCH_NODE='worker-0'"
    echo "NODE_TAINTS=$(printf '%q' "$node_taints")"
    echo "PENDING_PODS=$(printf '%q' "$pending_pods")"
    echo "TOLERATIONS=$(printf '%q' "$tolerations")"
    echo "EVENT_MSG=$(printf '%q' "$event_msg")"
    echo "CALL_COUNT_FILE='${count_file}'"
    cat <<'STUBS'
ok()   { echo "ok: $*"; }
err()  { echo "err: $*" >&2; }
warn() { echo "warn: $*" >&2; }
info() { echo "info: $*"; }
# Call counter is a FILE, not a variable: every branch below is reached only via `$(oc …)` or
# `<(oc …)`, both subshells — a variable increment here would never be visible to the caller.
oc() {
  local n
  n=$(($(cat "$CALL_COUNT_FILE") + 1)); printf '%s' "$n" > "$CALL_COUNT_FILE"
  case "$*" in
    *".spec.taints"*)      printf '%s\n' "$NODE_TAINTS" ;;
    *"status.phase=Pending"*) printf '%s\n' "$PENDING_PODS" ;;
    *".spec.tolerations"*) printf '%s' "$TOLERATIONS" ;;
    *"reason=FailedScheduling"*) printf '%s' "$EVENT_MSG" ;;
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
  echo "CALLS=$(cat "$count_file")"
  rm -f "$harness" "$count_file"
}

check_batch_taint_gate() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "could not extract ${FN_ASSERT}() — the guard cannot inspect what it claims to."
    return 2
  fi

  # (0) no taint applied this run → skip cleanly, and never touch the cluster to decide that.
  out="$(run_batch "$func_file" skip)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[0] BATCH_TAINTED=false: expected ${FN_ASSERT} to return 0."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'skipped'; then
    bad "[0] BATCH_TAINTED=false: expected the skip note, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'CALLS=0'; then
    bad "[0] BATCH_TAINTED=false: expected ZERO oc invocations, got: $(printf '%s\n' "$out" | grep '^CALLS=')"
    note "    a skip path that queries the cluster anyway defeats the point of skipping."
    rc=1
  fi

  # (a) taint applied, zero Pending pods cluster-wide — a real, reportable outcome, not a silent pass.
  out="$(run_batch "$func_file" zero)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[a] zero Pending pods: expected ${FN_ASSERT} to return 0."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'inspected 0 Pending pod'; then
    bad "[a] zero Pending pods: expected the explicit '0 Pending pods' report, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (b) a Pending pod exists but tolerates our taint key — out of this check's scope.
  out="$(run_batch "$func_file" tolerates)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[b] pod tolerates the batch taint: expected ${FN_ASSERT} to return 0."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'none blocked'; then
    bad "[b] pod tolerates the batch taint: expected the 'none blocked' report, got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (c) THE REAL INCIDENT SHAPE — checked as several separate assertions, because a gate that exits 1
  # while still printing "none blocked" is exactly the false-green class this guard exists to catch.
  out="$(run_batch "$func_file" blocked)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=1'; then
    bad "[c] pod blocked solely by our taint: expected ${FN_ASSERT} to return 1."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'none blocked'; then
    bad "[c] the 'none blocked' pass message printed even though a pod IS blocked by our taint alone —"
    note "    this is the 2026-07-30 RHACS central-db incident verbatim (Healthy apps, Pending DB)."
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'RHACS central-db'; then
    bad "[c] expected the message to name the 2026-07-30 RHACS central-db incident (proof this is the"
    note "    real report text, not a generic message that happens to satisfy a grep)."
    note "    got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (d) THE FALSE POSITIVE THIS ASSERT MUST AVOID: the node also carries an unrelated taint (e.g.
  # disk-pressure) — not attributable to us, must NOT hard-fail, but must still surface the ambiguity.
  out="$(run_batch "$func_file" ambiguous)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[d] node carries an unrelated blocking taint too: expected ${FN_ASSERT} to return 0 (not"
    note "    attributable to our taint), got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'disk-pressure'; then
    bad "[d] expected the ambiguity to be surfaced by name (disk-pressure), got: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "batch-taint Pending check: skip touches oc zero times; zero/tolerating pods pass cleanly; a"
    note "pod blocked solely by our taint FAILS naming the real incident; a co-tainted node does not"
    note "fail but still surfaces the ambiguity"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # <root> → 0 clean, 1 broken, 2 uninspectable
  local root="$1" rc=0 sub=0 func_file
  if [[ ! -f "${root}/${INSTALL}" ]]; then
    bad "${root}/${INSTALL} not found"
    return 2
  fi
  func_file="$(mktemp)"
  extract_func "${root}/${INSTALL}" "$FN_ASSERT" > "$func_file"

  check_batch_taint_gate "$func_file" || sub=$?
  rm -f "$func_file"
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
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

  # Canary — drop the increment that turns "a Pending pod is blocked solely by our taint" into a
  # counted failure. Byte-for-byte the real function with that one line removed: case (c), the real
  # incident shape, would then leave flagged=0 and fall through to the "none blocked" pass message —
  # a detector blind to the exact incident this gate exists to catch.
  f="$(mktemp)"
  # shellcheck disable=SC2016
  extract_func "${REPO_ROOT}/${INSTALL}" "$FN_ASSERT" \
    | sed 's/^      flagged=\$((flagged + 1))$/      : # CANARY: dropped -- blocked pods go uncounted/' > "$f"
  # shellcheck disable=SC2016
  if grep -q '^      flagged=\$((flagged + 1))$' "$f"; then
    bad "SELF-TEST FAILED: could not build the dropped-flagged canary — the increment it mutates was not found."
    rm -f "$f"
    return 2
  fi
  canary_rc=0
  check_batch_taint_gate "$f" >/dev/null 2>&1 || canary_rc=$?
  rm -f "$f"
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the dropped-flagged canary was NOT detected (rc=${canary_rc}) — the detector is blind."
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0), dropped-flagged canary (blocked pods going uncounted) caught."
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

run_check "$REPO_ROOT"
exit $?
