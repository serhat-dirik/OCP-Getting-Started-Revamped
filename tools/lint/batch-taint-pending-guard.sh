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
# WHAT IT CHECKS, against assert_no_batch_taint_pending() from bootstrap/install.sh. Every assertion
# carries a [case/property] TAG, and the tag is the first thing its failure message prints — the
# self-test's canary table asserts on those tags, so "which assertion fired" is a measured fact
# rather than an inference from the exit code (see THE TAGS, below):
#
#   (0) BATCH_TAINTED=false (no taint applied this run) → returns 0 [0/rc], prints the skip note
#       [0/note], and touches `oc` ZERO times [0/oc] — proven via a call-count FILE (see the subshell
#       note below), not by reading the code, so a future refactor that starts querying the cluster
#       on the skip path cannot pass this silently.
#   (a) taint applied, zero Pending pods cluster-wide → returns 0 [a/rc], reports "0 Pending pods...
#       nothing to flag" [a/report] (a real, reportable outcome — not a silent pass, per the
#       function's own header note).
#   (b) taint applied, a Pending pod TOLERATES our taint (and is Pending citing some OTHER node's
#       untolerated taint, which is what makes the tolerations check load-bearing rather than
#       decorative) → excluded from concern, returns 0 [b/rc], "none blocked by the ... taint"
#       [b/report].
#   (c) THE REAL INCIDENT SHAPE: a Pending pod does not tolerate our taint, its FailedScheduling event
#       cites an untolerated taint, and our taint is the ONLY blocking taint on the batch node →
#       returns NON-ZERO [c/rc], does NOT print the pass summary [c/no-pass], and the message names
#       the RHACS central-db incident text verbatim [c/incident] (proof this is reporting the real
#       thing, not a generic message that happens to satisfy a grep).
#   (d) THE FALSE-POSITIVE THIS ASSERT EXISTS TO AVOID: a Pending pod cites an untolerated taint, but
#       the batch node ALSO carries an unrelated blocking taint (e.g. disk-pressure) → returns 0
#       [d/rc] (not attributable to us), but still surfaces a warning naming the competing taint
#       [d/named] — proof the attribution logic the header comment describes is real, not just
#       asserted in prose.
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
# anything. ONE CANARY PER ASSERTION, plus the composite historical shape.
#
# WHY THAT MANY (audit, 2026-08-06). This guard shipped with a SINGLE canary — the dropped
# `flagged=$((flagged + 1))` increment. Measured by deleting each assertion in turn and re-running:
# ALL THIRTEEN could be deleted with --self-test still exiting 1, and nine of them (every assertion
# about cases 0, a, b and d — including the zero-oc-calls proof this header makes a point of, and the
# whole of the false-positive case (d)) were never reached by any canary at all. They were certified
# without ever being proven. The single canary only ever exercised case (c).
#
# THE TAGS are what closed that hole. Each canary declares the EXACT SET of assertion tags it must
# provoke, and the self-test fails if the set differs — too few (the assertion is inert, or a
# neighbour is silently covering for it) or too many (the mutant is broken outright and is failing
# assertions it never actually exercised, which certifies them for the wrong reason). Deleting any
# one assertion therefore shrinks some canary's fired set and reddens the self-test.
#
# Exit 1 = every canary was caught by exactly its own assertions AND the real tree is clean under the
# same detector; that is a PASS, matching the house convention where CI asserts the self-test step
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
FN_ASSERT="assert_no_batch_taint_pending"

# ── extraction ────────────────────────────────────────────────────────────────
# Extracted, never sourced: install.sh runs a full cluster install at top level. Extraction failure
# is exit 2, never a silent pass. Written to a real FILE (see the portability note above).
# extract_func lives in _extract-func.sh, sourced above; shared with the other guards under
# tools/lint/ rather than copy-pasted per guard.

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
      # This pod is Pending citing an untolerated taint — SOMEBODY ELSE'S (the control-plane taint),
      # which is the realistic shape and the only one that makes case (b) mean anything. The real
      # function greps the event text for "untolerated taint" without asking WHICH taint, so the
      # tolerations check is the single line standing between this pod and a false alarm. With an
      # empty event here (as this scenario carried until 2026-08-06) that line could be deleted and
      # the scenario would not notice — the pod would be dropped by the event grep instead.
      event_msg="0/3 nodes are available: 1 node(s) had untolerated taint(s) {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu."
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

# Pulls "KEY=<value>" back out of a harness transcript so a failure message can NAME what it
# measured instead of dumping the whole transcript and leaving the reader to diff it by eye.
# "<absent>" when the line never appeared — itself a measurement, and never a disjunction.
field() {  # <transcript> <key> → the key's value, or <absent>
  local v
  v="$(printf '%s\n' "$1" | grep -m1 "^${2}=" | cut -d= -f2-)"
  printf '%s' "${v:-<absent>}"
}

check_batch_taint_gate() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[x/extract] the extracted ${FN_ASSERT}() is EMPTY (0 bytes) — the guard cannot inspect what it claims to."
    note "    ${INSTALL} no longer defines a function by that name at column 0, or the walker broke."
    return 2
  fi

  # (0) no taint applied this run → skip cleanly, and never touch the cluster to decide that.
  out="$(run_batch "$func_file" skip)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[0/rc] BATCH_TAINTED=false must return 0 — measured RC=$(field "$out" RC) from ${FN_ASSERT}()."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'skipped'; then
    bad "[0/note] BATCH_TAINTED=false must report the skip — no line containing 'skipped' was emitted."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -qx 'CALLS=0'; then
    bad "[0/oc] BATCH_TAINTED=false must query the cluster ZERO times — measured CALLS=$(field "$out" CALLS) oc invocation(s)."
    note "    a skip path that queries the cluster anyway defeats the point of skipping."
    rc=1
  fi

  # (a) taint applied, zero Pending pods cluster-wide — a real, reportable outcome, not a silent pass.
  out="$(run_batch "$func_file" zero)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[a/rc] zero Pending pods cluster-wide must return 0 — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'inspected 0 Pending pod'; then
    bad "[a/report] zero Pending pods must be REPORTED — no line containing 'inspected 0 Pending pod' was emitted."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (b) a Pending pod exists, tolerates our taint, and is Pending citing SOMEBODY ELSE'S untolerated
  # taint — out of this check's scope, and the case that proves the tolerations exclusion is real.
  out="$(run_batch "$func_file" tolerates)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[b/rc] a Pending pod that TOLERATES the batch taint must return 0 — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'none blocked'; then
    bad "[b/report] a tolerating pod must be reported as not blocked — no line containing 'none blocked' was emitted."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (c) THE REAL INCIDENT SHAPE — checked as several separate assertions, because a gate that exits 1
  # while still printing "none blocked" is exactly the false-green class this guard exists to catch.
  out="$(run_batch "$func_file" blocked)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=1'; then
    bad "[c/rc] a Pending pod blocked SOLELY by our taint must return 1 — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if printf '%s\n' "$out" | grep -q 'none blocked'; then
    bad "[c/no-pass] the 'none blocked' PASS summary was printed while a pod IS blocked by our taint alone."
    note "    this is the 2026-07-30 RHACS central-db incident verbatim (Healthy apps, Pending DB)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'RHACS central-db'; then
    bad "[c/incident] the failure must NAME the 2026-07-30 RHACS central-db incident — no line containing"
    note "    'RHACS central-db' was emitted (proof this is the real report text, not a generic message"
    note "    that happens to satisfy a grep)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi

  # (d) THE FALSE POSITIVE THIS ASSERT MUST AVOID: the node also carries an unrelated taint (e.g.
  # disk-pressure) — not attributable to us, must NOT hard-fail, but must still surface the ambiguity.
  out="$(run_batch "$func_file" ambiguous)"
  if ! printf '%s\n' "$out" | grep -qx 'RC=0'; then
    bad "[d/rc] a batch node carrying an unrelated blocking taint too must return 0 (not attributable to"
    note "    our taint) — measured RC=$(field "$out" RC)."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
    rc=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'disk-pressure'; then
    bad "[d/named] the competing taint must be NAMED in the warning — no line containing 'disk-pressure'"
    note "    was emitted, so the ambiguity is invisible to whoever has to triage it."
    note "    transcript: $(printf '%s' "$out" | tr '\n' ' ')"
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
  coverage_reset
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
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── canaries ──────────────────────────────────────────────────────────────────
# Each canary is ONE realistic regression applied to the REAL extracted text of
# assert_no_batch_taint_pending() — never to a re-implementation of it, and never to the guard's own
# assertions. Full-line replacements throughout: awk's sub() treats `&` in the replacement as the
# matched text, and several of these lines contain `&&`.
#
# The `$flagged`, `$0`, `${ns}` and friends below are LITERAL TEXT being written into (or matched
# against) install.sh's own source, not expansions of anything in this script.
# shellcheck disable=SC2016
canary_mutate() {  # <id> → mutated function text on stdout, real function text on stdin
  case "$1" in
    skip-returns-nonzero)
      awk '/check: skipped/{a=1}
           a && $0=="    return 0"{print "    return 1  # CANARY: the skip path now reports failure"; a=0; next}
           {print}' ;;
    skip-goes-silent)
      awk '/check: skipped/{print "    : # CANARY: the skip note is gone"; next}
           {print}' ;;
    skip-queries-cluster)
      awk '/check: skipped/{a=1}
           a && $0=="    return 0"{print "    : # CANARY: falls through into the oc queries"; a=0; next}
           {print}' ;;
    zero-returns-nonzero)
      awk '/inspected 0 Pending pods/{a=1}
           a && $0=="    return 0"{print "    return 1  # CANARY: an empty cluster is reported as a failure"; a=0; next}
           {print}' ;;
    zero-goes-silent)
      awk '/inspected 0 Pending pods/{print "    : # CANARY: the 0-Pending outcome is no longer reported"; next}
           {print}' ;;
    tolerating-pod-not-excluded)
      awk '/this pod opted in/{print "      : # CANARY: a pod that tolerates our taint is no longer excluded"; next}
           {print}' ;;
    none-blocked-message-gone)
      awk '/none blocked by the/{print "    : # CANARY: the pass summary is no longer printed"; next}
           {print}' ;;
    blocked-not-counted)
      # THE HISTORICAL SHAPE, and until 2026-08-06 the guard's only canary: the increment that turns
      # "a Pending pod is blocked by our taint alone" into a reported failure is dropped, so case (c)
      # leaves flagged=0 and falls through to the "none blocked" pass message.
      awk '/^      flagged=\$\(\(flagged \+ 1\)\)$/{print "      : # CANARY: dropped -- blocked pods go uncounted"; next}
           {print}' ;;
    blocked-returns-zero)
      awk '$0=="  return 1"{print "  return 0  # CANARY: the incident shape stops failing the install"; next}
           {print}' ;;
    pass-message-printed-anyway)
      # The composite false-green [c/no-pass] exists for: the summary is emitted before the verdict is
      # decided, so a failing run prints the PASS line and then fails. Two anchored lines.
      awk '$0 ~ /^  if \[\[ "\$flagged" -eq 0 \]\]; then$/{print "  if [[ \"$flagged\" -ge 0 ]]; then  # CANARY: summary printed before the verdict"; next}
           /none blocked by the/{a=1}
           a && $0=="    return 0"{print "    [[ \"$flagged\" -eq 0 ]] && return 0"; a=0; next}
           {print}' ;;
    incident-not-named)
      awk '/RHACS central-db Pending behind/{print "  err \"  free capacity on the other worker(s) (CANARY: the incident is no longer named)\""; next}
           {print}' ;;
    ambiguous-also-flagged)
      # The attribution logic still WARNS, but counts the pod anyway — the false positive returns.
      awk '/^      ambiguous=\$\(\(ambiguous \+ 1\)\)$/{print "      ambiguous=$((ambiguous + 1)); flagged=$((flagged + 1))  # CANARY: counted anyway"; next}
           {print}' ;;
    ambiguity-not-named)
      awk '/is Pending citing an untolerated taint/{print "    warn \"  ${ns}/${pod} is Pending citing an untolerated taint (CANARY: the competing taints are no longer named): ${evt}\""; next}
           {print}' ;;
  esac
}

# Build one canary and prove it is a real, PARSABLE mutation of the real function before trusting
# anything it does. Both failure modes are caught here rather than downstream:
#   • a canary that changed nothing (the line it anchors on was renamed) is caught by nothing and
#     proves nothing — it would sail through as "the detector stayed green, so it must be fine";
#   • a canary that no longer PARSES fails every assertion at once for a reason that has nothing to
#     do with the property under test, certifying assertions it never actually exercised.
build_canary() {  # <id> <outfile> → 0 built, 2 unbuildable
  local id="$1" out="$2" src="${2}.src"
  extract_func "${REPO_ROOT}/${INSTALL}" "$FN_ASSERT" > "$src"
  if [[ ! -s "$src" ]]; then
    bad "SELF-TEST FAILED: canary '${id}' — ${FN_ASSERT}() could not be extracted from ${INSTALL}."
    rm -f "$src"; return 2
  fi
  canary_mutate "$id" < "$src" > "$out"
  if cmp -s "$src" "$out"; then
    bad "SELF-TEST FAILED: canary '${id}' changed NOTHING — the line it anchors on is no longer in ${FN_ASSERT}()."
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
  local id expect label

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$REPO_ROOT" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # Proof 1: the extraction guard, DRIVEN rather than read. An empty extraction must be rc 2
  # ("could not inspect"), never rc 1 ("the installer is broken") and never a green run.
  out="$(check_batch_taint_gate /dev/null 2>&1)"; canary_rc=$?
  if [[ "$canary_rc" -ne 2 ]]; then
    bad "SELF-TEST FAILED: an EMPTY extracted function was not reported as uninspectable — the detector"
    note "    returned ${canary_rc}, expected 2. A failed extraction must never read as a verdict about the installer."
    return 2
  fi
  got="$(reported_tags "$out")"; want="$(norm_tags '[x/extract]')"
  if [[ "$got" != "$want" ]]; then
    bad "SELF-TEST FAILED: the empty-extraction path fired ${got:-<no assertions>}, expected exactly ${want}."
    return 2
  fi

  # Proof 2…N: one canary per assertion, each declaring the EXACT SET of tags it must provoke.
  # Too few = that assertion is inert (or a neighbour is covering for it); too many = the mutant is
  # broken outright and is failing assertions it never exercised.
  while IFS='|' read -r id expect label; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    f="$(mktemp)"
    if ! build_canary "$id" "$f"; then rm -f "$f" "${f}.src"; return 2; fi
    out="$(check_batch_taint_gate "$f" 2>&1)"; canary_rc=$?
    rm -f "$f"
    if [[ "$canary_rc" -ne 1 ]]; then
      bad "SELF-TEST FAILED: canary '${id}' (${label}) — the detector returned ${canary_rc}, expected 1."
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
skip-returns-nonzero|[0/rc]|the no-taint skip path returns non-zero
skip-goes-silent|[0/note]|the no-taint skip path reports nothing at all
skip-queries-cluster|[0/oc]|the skip path falls through and queries the cluster anyway
zero-returns-nonzero|[a/rc]|a cluster with no Pending pods is reported as a failure
zero-goes-silent|[a/report]|the 0-Pending outcome becomes a silent pass
tolerating-pod-not-excluded|[b/rc],[b/report]|a pod that tolerates the batch taint is no longer excluded
none-blocked-message-gone|[b/report]|the "none blocked" summary stops being printed
blocked-not-counted|[c/rc],[c/no-pass],[c/incident]|THE 2026-07-30 SHAPE: blocked pods go uncounted
blocked-returns-zero|[c/rc]|a pod blocked solely by our taint stops failing the install
pass-message-printed-anyway|[c/no-pass]|the pass summary prints alongside the failure it contradicts
incident-not-named|[c/incident]|the failure stops naming the RHACS central-db incident
ambiguous-also-flagged|[d/rc]|a co-tainted node is hard-failed again — the false positive returns
ambiguity-not-named|[d/named]|the ambiguity warning stops naming the competing taint
CANARIES

  ok "self-test ok — real tree clean (rc=0); ${n} canaries + the empty-extraction path, each caught by"
  note "exactly the assertion(s) written for it (deleting any one assertion shrinks a canary's fired"
  note "tag set and reddens this run)."
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
