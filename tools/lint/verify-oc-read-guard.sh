#!/usr/bin/env bash
# verify-oc-read-guard.sh — pins the oc_read contract (commit 51eb1b6) so it cannot silently erode.
#
# ORIGIN. 51eb1b6 fixed 154 blind reads across tools/verify/*.sh: `oc get … 2>/dev/null` cannot tell
# "the object is not there" (a real ❌) from "the cluster did not answer" (a real ⚠, never the
# attendee's fault) — both come back as an empty string. `oc_read` in _lib.sh keeps stdout and stderr
# apart and returns three outcomes; `check` routes any `oc` invocation through it. Nothing about that
# fix stops the NEXT commit from undoing it, one line at a time, in three different ways:
#
#   [1] a NEW stderr-silenced `oc` read in a tools/verify/*.sh predicate, bypassing oc_read entirely
#       — `oc … 2>/dev/null`, `oc … >/dev/null 2>&1` or `oc … &>/dev/null`; all three are blind in
#       exactly the same way, and the second is the commonest shape in this tree.
#   [2] a module script re-defining deploy_ready / deploy_ready_min / cm_key_set locally — a copy
#       silently SHADOWS the shared _lib.sh definition for that one caller, the exact failure mode
#       that let six copies of an extraction walker drift apart before tools/lint/_extract-func.sh
#       deduplicated them (2026-07-31).
#   [3] the three-outcome contract itself regressing inside oc_read — specifically NotFound folded
#       back into "succeeded". Not hypothetical: 51eb1b6's own commit message says its FIRST draft
#       shipped exactly this, and it made a PodDisruptionBudget-missing check PASS in a namespace
#       that had none. Only a full non-entry-only run caught it; every entry-only run looked clean
#       because those particular objects existed.
#
# [1] IS A RATCHET, NOT AN AMNESTY. 51eb1b6's own commit message: "108 silenced reads remain in
# per-module predicates … the conversion is mechanical, but the lane stopped where it had live state
# to diff against rather than converting fifteen scripts blind." Those reads are KNOWN, ACKNOWLEDGED
# debt, not a clean baseline — a guard that failed on all of them today would be disabled within the
# week. BASELINE_TABLE below is the exact per-file count this guard's own detector measures against
# the tree as of 2026-08-01 (by LINE, so a line carrying two `oc … 2>/dev/null` reads — e.g. an outer
# `oc get devworkspaces … "$(oc get cm … 2>/dev/null)"` — counts once; this is why the total differs
# from the commit message's own by-READ tally, not a disagreement about which reads are blind). A
# file's count may only stay AT or FALL BELOW its baseline; a file absent from the table — including
# any brand-new module's verify script — gets baseline 0, so a single occurrence anywhere new fails
# immediately. Converting a listed file's reads to oc_read/oc_present/oc_absent should lower its
# baseline entry in the same change, or the ratchet stops ratcheting.
#
# ALLOWED, deliberately, per _lib.sh's own comments — read them before widening either exclusion:
#   • curl probes. A line with NO `oc` token never matches [1] at all (a pure `curl … 2>/dev/null` has
#     nothing to exclude) — "an app not answering IS the measured outcome, unlike an API that could
#     not be asked" (tools/verify/README.md). An `oc exec … -- curl …` line DOES carry an `oc` token
#     and is still counted: the ambiguity oc_read exists for (could the API connection itself be
#     established) is exactly as live there as anywhere else.
#   • gitea_host()'s route-then-domain fallback (`oc get route gitea … 2>/dev/null || true`, then
#     `oc get ingresses.config.openshift.io cluster … 2>/dev/null || true`) is excluded BY NAME, not by
#     the `|| true` shape in general — `|| true` alone is not a safety property here, it is what most
#     of the acknowledged debt above already does. gitea_host does not care WHY the route read failed;
#     it falls back to domain derivation either way and returns an empty string on total failure, which
#     every caller already treats as "could not determine the host". Named because that specific
#     design call is the only one this guard was told to trust; a new function inventing its own
#     "fall back regardless of why" is a NEW instance of the pattern, not this one.
#
# [3] is EXECUTED, never grepped — a source scan proves the text, not the behaviour. The real oc_read
# is extracted verbatim (tools/lint/_extract-func.sh) and driven against a stubbed `oc` for three
# scripted answers (NotFound, Forbidden, connection-refused) plus a real success, and the canary
# reproduces the regression byte-for-byte: the ONE `return 1` in oc_read (the NotFound/default arm at
# the bottom of its case statement) flipped to `return 0`.
#
# Exit codes: 0 contract holds · 1 contract broken, or under --self-test every canary was correctly
# caught · 2 this guard could not inspect what it claims to (extraction failed, tree missing).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "${LINT_DIR}/_parse-guard-args.sh"
# shellcheck source=tools/lint/_extract-func.sh
source "${LINT_DIR}/_extract-func.sh"
# shellcheck source=tools/lint/_check-coverage.sh
source "${LINT_DIR}/_check-coverage.sh"

VERIFY_DIR="${REPO_ROOT}/tools/verify"
LIB_SH="${VERIFY_DIR}/_lib.sh"

bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }
ok()   { echo "✅ $*"; }

# ── [1] the ratchet table ──────────────────────────────────────────────────────────────────────────
# One line per file, "<basename> <count>". A file not listed here defaults to baseline 0.
#
# Re-measured 2026-08-01 against the committed tree after the second conversion pass. Seven files
# reached ZERO and their rows are GONE rather than set to 0 — an absent file defaults to baseline 0, so
# deleting the row is what protects them: a single new silenced read in any of them now fails outright.
# Converted and proven byte-identical against live cluster 2 (healthy + genuine-absence + unreachable-API
# runs diffed against `git archive HEAD`): agentic-ai (4), ai-assisted-development (8), app-modernization
# (4), deployment-targets-scheduling (7), gitops-fundamentals (5), jobs-batch-kueue (9),
# serverless-zero-to-hero (4) — 41 lines, table total 98 → 57. No file's count rose.
#
# ── 2026-08-01, SAME DAY: the detector was matching HALF the debt ────────────────────────────────
# The header above documented `oc … 2>/dev/null` and the detector matched that literal string only.
# It never saw `>/dev/null 2>&1`, which is the MORE COMMON shape here — it is what an existence
# probe and a negation are written as:
#
#     deploy_present() { oc get deploy "$1" -n "$2" >/dev/null 2>&1; }
#     ! oc get networkpolicy default-deny-all -n "$NS" >/dev/null 2>&1
#
# Both silence stderr exactly as thoroughly as `2>/dev/null` and are blind in exactly the same way: a
# throttled API, an expired token or a network blip is indistinguishable from "the object is not
# there", and the attendee gets a false ❌ for correct work. Measured against the committed tree: 58
# additional LINES across 13 files, every one of them invisible to the old detector and therefore
# passing at whatever baseline the file happened to carry. tools/verify/networking-dev-devops.sh was
# the worst case — it carried ZERO of the old shape, so it had no row at all and sat at baseline 0
# while holding TEN blind reads.
#
# NOT ABSORBED SILENTLY. The table below is the honest re-measurement, and the debt it now admits to
# is 115 lines, not 57. Which files moved (old → new): build-deliver 3→4, eventing-deep-dive 3→9,
# gitops-at-scale 6→8, multi-tenancy-workload-security 4→9, networking-dev-devops 0→10 (NEW ROW),
# packaging-distributing 2→7, platform-orientation 4→5, registry-images-catalog-governance 8→15,
# resilience-multicluster-dr 10→22, securing-apps-keycloak 3→5, service-mesh-advanced-gateways 6→13.
# Six rows are unchanged. No file's count fell, because nothing was converted in this change — the
# detector simply stopped being half-blind.
#
# STILL A RATCHET, DELIBERATELY. A zero-tolerance gate over 58 newly-visible violations would be
# switched off inside a week, and these reads are pre-existing debt, not a regression someone just
# introduced. Recording them makes the size of the debt visible instead of laundering it. The
# direction of travel is unchanged: a count may only stay put or FALL, and converting a file's reads
# to oc_read/oc_present/oc_absent should lower its row in the same change.
#
# NOT matched, on purpose: `oc … 2>&1 >/dev/null` (one instance, jobs-batch-kueue.sh:198,
# `cq_err="$(oc get clusterqueue "$CQ" -o name 2>&1 >/dev/null || true)"`). The order is reversed:
# stderr goes to the ORIGINAL stdout and is captured, stdout is discarded. That is a deliberate
# capture-the-error idiom — the opposite of silencing one — and folding it in would punish the shape
# that keeps the diagnosis.
BASELINE_TABLE="
app-security-testing.sh 1
build-deliver.sh 4
developer-hub-golden-paths.sh 1
devspaces-inner-loop.sh 1
eventing-deep-dive.sh 9
gitops-at-scale.sh 8
multi-tenancy-workload-security.sh 9
networking-dev-devops.sh 10
observability-health-scale.sh 2
packaging-distributing.sh 7
pipelines-fundamentals.sh 1
platform-orientation.sh 5
registry-images-catalog-governance.sh 15
resilience-multicluster-dr.sh 22
securing-apps-keycloak.sh 5
service-mesh-advanced-gateways.sh 13
trusted-supply-chain.sh 2
"

baseline_for() {  # <basename> → integer, 0 if not listed
  awk -v f="$1" '$1==f{print $2; found=1} END{if(!found) print 0}' <<< "$BASELINE_TABLE"
}

# A line counts iff: not a comment, silences stderr into /dev/null in one of the shapes below, AND
# carries a standalone `oc` token (so a pure curl probe — no `oc` token at all — never matches). Read
# from STDIN so the same matcher applies to a whole file and to an extracted function's body text
# alike, and counted BY LINE, so a line carrying two silenced reads counts once.
#
# The three silencing shapes, all equally blind:
#   2>/dev/null              stderr discarded, stdout kept — the shape 51eb1b6 converted.
#   >/dev/null 2>&1          both discarded — the existence-probe / negation idiom, and the MORE
#                            COMMON one here; invisible to this detector until 2026-08-01.
#   &>/dev/null              bash shorthand for the same thing. Zero instances today; matched so the
#                            obvious one-character bypass does not exist the day someone reaches for it.
# The optional [[:space:]]* after `2>` / `&>` and the required whitespace before `2>&1` are what make
# `2> /dev/null` and `> /dev/null 2>&1` count too. `2>&1 >/dev/null` deliberately does NOT match —
# see the BASELINE_TABLE header.
OC_SILENCED_RE='2>[[:space:]]*/dev/null|>[[:space:]]*/dev/null[[:space:]]+2>&1|&>[[:space:]]*/dev/null'

oc_devnull_lines() {
  grep -vE '^[[:space:]]*#' | grep -E "$OC_SILENCED_RE" | grep -E '(^|[^A-Za-z0-9_])oc([^A-Za-z0-9_]|$)'
}

count_oc_devnull_violations() {  # <file> → integer, gitea_host()'s body excluded
  local f="$1" total gh gh_count=0
  total="$(oc_devnull_lines < "$f" | wc -l | tr -d ' ')"
  gh="$(extract_func "$f" gitea_host)"
  if [[ -n "$gh" ]]; then
    gh_count="$(printf '%s\n' "$gh" | oc_devnull_lines | wc -l | tr -d ' ')"
  fi
  echo $(( total - gh_count ))
}

check_no_new_raw_oc_devnull() {  # <verify-dir> → 0 within baseline, 1 a file exceeds it, 2 inspected nothing
  ran_check
  local dir="$1" f base actual base_count rc=0 n=0
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    n=$((n + 1))
    base="$(basename "$f")"
    actual="$(count_oc_devnull_violations "$f")"
    base_count="$(baseline_for "$base")"
    if [[ "$actual" -gt "$base_count" ]]; then
      bad "[1] ${base}: ${actual} stderr-silenced 'oc' read line(s) outside gitea_host() (2>/dev/null, >/dev/null 2>&1 or &>/dev/null), baseline allows ${base_count} (excess $((actual - base_count)))."
      note "    Each one hides a real API failure (throttling, an expired token, a blip) as a genuine"
      note "    absence — the attendee gets a false ❌ for correct work. Route it through oc_read /"
      note "    oc_present / oc_absent (tools/verify/_lib.sh) instead of adding another one."
      rc=1
    fi
  done
  shopt -u nullglob
  if [[ "$n" -eq 0 ]]; then
    bad "[1] ${dir}: zero *.sh files found — this detector inspected nothing."
    return 2
  fi
  [[ "$rc" -eq 0 ]] && ok "[1] no tools/verify/*.sh file exceeds its recorded stderr-silenced-oc-read baseline"
  return "$rc"
}

# ── [2] shared-predicate shadowing ────────────────────────────────────────────────────────────────
check_no_local_predicate_shadow() {  # <verify-dir> → 0 none shadowed, 1 a module redefines a shared predicate, 2 inspected nothing
  ran_check
  local dir="$1" f base fn rc=0 n=0
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    base="$(basename "$f")"
    [[ "$base" == "_lib.sh" ]] && continue   # the one legitimate definition site
    n=$((n + 1))
    for fn in deploy_ready deploy_ready_min cm_key_set; do
      if grep -qE "^${fn}\\(\\)[[:space:]]*\\{" "$f"; then
        bad "[2] ${base}: re-defines ${fn}(), which tools/verify/_lib.sh already provides."
        note "    A local copy silently SHADOWS the library for THIS caller only — the two definitions"
        note "    then drift apart while both look correct in isolation (the exact six-copies-of-a-"
        note "    walker failure tools/lint/_extract-func.sh was deduplicated to stop). Delete it, or"
        note "    move the change into _lib.sh so every caller gets it."
        rc=1
      fi
    done
  done
  shopt -u nullglob
  if [[ "$n" -eq 0 ]]; then
    bad "[2] ${dir}: zero non-_lib.sh *.sh files found — this detector inspected nothing."
    return 2
  fi
  [[ "$rc" -eq 0 ]] && ok "[2] no module verify script redefines deploy_ready / deploy_ready_min / cm_key_set"
  return "$rc"
}

# ── [3] the three-outcome contract, EXECUTED ─────────────────────────────────────────────────────────
# Fixtures for `oc`'s three real shapes (captured live 2026-08-01, same text _lib.sh's own header
# cites) plus a genuine success. Written once per run, not per case — cheap and avoids quoting the
# error text through multiple layers of sed/printf.
_write_oc_read_stubs() {  # <dir> → writes stub-notfound.sh / stub-forbidden.sh / stub-refused.sh / stub-success.sh
  local d="$1"
  cat > "${d}/stub-notfound.sh" <<'STUB'
oc() {
  printf ''
  printf 'Error from server (NotFound): deployments.apps "widget" not found\n' >&2
  return 1
}
STUB
  cat > "${d}/stub-forbidden.sh" <<'STUB'
oc() {
  printf ''
  printf 'Error from server (Forbidden): deployments.apps "widget" is forbidden: User "system:serviceaccount:x:y" cannot get resource "deployments" in API group "apps" in the namespace "ns"\n' >&2
  return 1
}
STUB
  cat > "${d}/stub-refused.sh" <<'STUB'
oc() {
  printf ''
  printf 'The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?\n' >&2
  return 1
}
STUB
  cat > "${d}/stub-success.sh" <<'STUB'
oc() {
  printf '1'
  return 0
}
STUB
}

# run_oc_read_case <lib-file> <stub-file> <oc-args…> → stdout "RC=<n> INCONCLUSIVE=<0|1> OUT=<text>"
#
# Runs under `set -euo pipefail`, exactly like the real verify scripts oc_read is written for — and
# the call is guarded with `|| rc=$?`, not bare, because a bare call whose function RETURNS non-zero
# (rc 1 or 2 are both non-zero BY DESIGN here) would itself be killed by that same `-e` before this
# harness ever reached its own reporting line. That is the identical trap CLAUDE.md's "set -e + cond
# && cmd" note describes for a different shape; this harness cannot demonstrate oc_read's contract
# while falling into it.
run_oc_read_case() {
  local lib="$1" stub="$2" script rc a
  shift 2
  script="$(mktemp)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    cat "$stub"
    extract_func "$lib" oc_read
    printf 'OC_OUT=""; OC_ERR=""; VERIFY_INCONCLUSIVE=0\n'
    printf 'rc=0\n'
    printf 'oc_read'
    for a in "$@"; do printf ' %q' "$a"; done
    printf ' || rc=$?\n'
    # shellcheck disable=SC2016
    printf 'printf "RC=%%s INCONCLUSIVE=%%s OUT=%%s\\n" "$rc" "$VERIFY_INCONCLUSIVE" "$OC_OUT"\n'
  } > "$script"
  bash "$script" 2>/dev/null
  rc=$?
  rm -f "$script"
  return "$rc"
}

_oc_read_field() {  # <harness-output> <field-name> → value
  sed -nE "s/.*${2}=([^ ]*).*/\\1/p" <<< "$1"
}

check_oc_read_notfound_not_folded() {  # <lib-file-or-snippet> → 0 all three outcomes classified correctly, 1 wrong, 2 could not extract
  ran_check
  local lib="$1" rc=0 out got_rc got_inc
  local stubdir; stubdir="$(mktemp -d)"
  _write_oc_read_stubs "$stubdir"

  if [[ -z "$(extract_func "$lib" oc_read)" ]]; then
    bad "[3] oc_read() could not be extracted from ${lib} — this detector inspected nothing."
    rm -rf "$stubdir"
    return 2
  fi

  # (a) NotFound is a real NO — the exact regression: folding it into rc 0 made a missing-object
  # check PASS. Must stay rc=1, and must NOT raise VERIFY_INCONCLUSIVE (that would make it a ⚠, the
  # opposite mistake — an absence going ungraded instead of a false pass).
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-notfound.sh" get deploy widget -n ns -o 'jsonpath={.status.readyReplicas}')"
  got_rc="$(_oc_read_field "$out" RC)"; got_inc="$(_oc_read_field "$out" INCONCLUSIVE)"
  if [[ "$got_rc" != "1" ]]; then
    bad "[3a] NotFound must classify as a real NO (rc=1); got rc=${got_rc:-<none>}. Output: ${out}"
    note "    Folding NotFound into rc 0 made a check for a missing PodDisruptionBudget PASS on a"
    note "    namespace that had none — the first draft of oc_read shipped exactly this."
    rc=1
  elif [[ "$got_inc" != "0" ]]; then
    bad "[3a] NotFound must NOT set VERIFY_INCONCLUSIVE; got ${got_inc:-<none>}. Output: ${out}"
    rc=1
  fi

  # (b) Forbidden — could not ask, ⚠ not ❌ (rule 10: not this identity's check to run).
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-forbidden.sh" get deploy widget -n ns)"
  got_rc="$(_oc_read_field "$out" RC)"; got_inc="$(_oc_read_field "$out" INCONCLUSIVE)"
  if [[ "$got_rc" != "2" || "$got_inc" != "1" ]]; then
    bad "[3b] Forbidden must be 'could not ask' (rc=2, VERIFY_INCONCLUSIVE=1); got rc=${got_rc:-<none>} inconclusive=${got_inc:-<none>}. Output: ${out}"
    rc=1
  fi

  # (c) connection refused — could not ask, same as (b) but the transport-failure branch of the case.
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-refused.sh" get deploy widget -n ns)"
  got_rc="$(_oc_read_field "$out" RC)"; got_inc="$(_oc_read_field "$out" INCONCLUSIVE)"
  if [[ "$got_rc" != "2" || "$got_inc" != "1" ]]; then
    bad "[3c] connection-refused must be 'could not ask' (rc=2, VERIFY_INCONCLUSIVE=1); got rc=${got_rc:-<none>} inconclusive=${got_inc:-<none>}. Output: ${out}"
    rc=1
  fi

  # (d) a genuine success must still classify as rc=0 — a detector that only ever demanded "not 0"
  # would trivially pass on ANY nonzero rc, including a NotFound miscategorized as could-not-ask.
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-success.sh" get deploy widget -n ns -o 'jsonpath={.status.readyReplicas}')"
  got_rc="$(_oc_read_field "$out" RC)"
  if [[ "$got_rc" != "0" ]]; then
    bad "[3d] a genuine oc success must classify as rc=0; got rc=${got_rc:-<none>}. Output: ${out}"
    rc=1
  fi

  rm -rf "$stubdir"
  [[ "$rc" -eq 0 ]] && ok "[3] oc_read: NotFound stays a real NO, Forbidden/connection-refused stay 'could not ask', success stays a pass"
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────────────────────────
run_check() {  # <verify-dir> <lib-file> → 0 clean · 1 finding(s) · 2 could not inspect
  coverage_reset
  local dir="$1" lib="$2" rc=0 one=0

  check_no_new_raw_oc_devnull "$dir" || one=$?
  [[ "$one" -gt "$rc" ]] && rc="$one"

  one=0; check_no_local_predicate_shadow "$dir" || one=$?
  [[ "$one" -gt "$rc" ]] && rc="$one"

  one=0; check_oc_read_notfound_not_folded "$lib" || one=$?
  [[ "$one" -gt "$rc" ]] && rc="$one"

  if [[ "$rc" -ne 2 ]]; then
    assert_all_checks_ran || rc=2
  fi
  return "$rc"
}

# ── canaries ─────────────────────────────────────────────────────────────────────────────────────
# Each canary is a real copy of the tree's own tools/verify/*.sh with ONE defect injected — an empty
# fixture trips every detector at once and proves nothing about any of them.
_canary_verify_dir() {  # [target-basename] [sed-expr] → a temp copy of tools/verify/ with the edit applied
  local target="$1" expr="$2" d
  d="$(mktemp -d)"
  cp "${VERIFY_DIR}"/*.sh "$d"/
  if [[ -n "$target" ]]; then
    sed -i.bak "$expr" "${d}/${target}"
    rm -f "${d}/${target}.bak"
  fi
  printf '%s' "$d"
}

_expect_rc() {  # <label> <want-rc> <got-rc> → 0 match, 1 mismatch (and prints)
  local label="$1" want="$2" got="$3"
  if [[ "$got" -ne "$want" ]]; then
    bad "SELF-TEST FAILED: ${label} → rc=${got}, expected ${want}."
    return 1
  fi
  return 0
}

# Extracts oc_read verbatim and flips its ONE `return 1` (the NotFound/default case arm) to
# `return 0` — reproducing 51eb1b6's own first-draft regression, not a made-up mutation.
_build_notfound_folding_canary() {  # → path to a temp file containing the mutated oc_read()
  local body mutated tmp
  body="$(extract_func "$LIB_SH" oc_read)"
  if [[ -z "$body" ]]; then
    bad "could not extract oc_read() from ${LIB_SH} to build the NotFound-folding canary."
    return 2
  fi
  mutated="${body/return 1/return 0}"
  if [[ "$mutated" == "$body" ]]; then
    bad "could not build the NotFound-folding canary — no 'return 1' found in the extracted oc_read() to mutate."
    return 2
  fi
  tmp="$(mktemp)"
  printf '%s\n' "$mutated" > "$tmp"
  printf '%s' "$tmp"
}

self_test() {
  local bad_seen=0 d got mutated_file cov

  # Proof 0: the real tree passes. A guard that fires on everything proves nothing.
  got=0; run_check "$VERIFY_DIR" "$LIB_SH" >/dev/null 2>&1 || got=$?
  if ! _expect_rc "the real tools/verify/ tree satisfies the contract" 0 "$got"; then
    bad "run 'bash tools/lint/verify-oc-read-guard.sh' without --self-test to see the finding."
    return 2
  fi

  # Canary [1]-A — a file's ratchet exceeded: one new raw 'oc … 2>/dev/null' appended beyond baseline.
  # shellcheck disable=SC2016  # sed PROGRAM text: this is fixture source for the copy, not an expansion.
  d="$(_canary_verify_dir platform-orientation.sh '$a\
oc get secret ratchet-canary -n foo -o jsonpath="{.data.x}" 2>/dev/null')"
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-A (a file's ratchet baseline exceeded)" 1 "$got" || bad_seen=1

  # Canary [1]-B — a brand-new file (absent from BASELINE_TABLE, i.e. baseline 0) with one occurrence.
  # This is what a NEW module's verify script introducing the shape for the first time looks like.
  d="$(_canary_verify_dir '' '')"
  printf 'oc get secret new-module-canary -n foo -o jsonpath="{.data.x}" 2>/dev/null\n' > "${d}/zzz-not-a-real-module.sh"
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-B (unlisted file, baseline 0, one occurrence)" 1 "$got" || bad_seen=1

  # Canary [1]-C — gitea_host()'s named exclusion, isolated: a fixture containing ONLY its real
  # two-line fallback (both lines DO match the raw shape) must stay clean against its unlisted (0)
  # baseline, or the exclusion is not actually applied.
  d="$(mktemp -d)"
  cat > "${d}/only-gitea-host.sh" <<'FIXTURE'
gitea_host() {
  local host domain
  host="$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-ogsr-gitea.${domain}"
  fi
  echo "$host"
}
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-C (gitea_host's own fallback excluded, isolated fixture)" 0 "$got" || bad_seen=1

  # Canary [1]-D — a pure curl probe (no 'oc' token at all) must stay clean, unlisted baseline or not.
  d="$(mktemp -d)"
  cat > "${d}/only-curl.sh" <<'FIXTURE'
probe() { curl -ksf --max-time 15 "https://example.com/health" 2>/dev/null | grep -q ok; }
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-D (pure curl probe stays clean)" 0 "$got" || bad_seen=1

  # Canary [1]-E — the `>/dev/null 2>&1` shape, which this detector was blind to until 2026-08-01.
  # Appended to a file at its recorded baseline, so ONLY the extended matcher can turn it into a
  # finding: with the old literal-'2>/dev/null' matcher this canary is silently clean.
  # shellcheck disable=SC2016  # sed PROGRAM text: fixture source for the copy, not an expansion.
  d="$(_canary_verify_dir platform-orientation.sh '$a\
oc get ns default >/dev/null 2>&1')"
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-E ('>/dev/null 2>&1' existence probe, the shape the detector used to miss)" 1 "$got" || bad_seen=1

  # Canary [1]-F — the `&>/dev/null` shorthand, the one-character bypass of [1]-E. Zero instances in
  # the tree today, which is exactly why it needs a canary rather than a measurement.
  d="$(mktemp -d)"
  cat > "${d}/only-ampersand.sh" <<'FIXTURE'
route_present() { oc get route parasol-web -n "$1" &>/dev/null; }
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-F ('&>/dev/null' shorthand, unlisted file at baseline 0)" 1 "$got" || bad_seen=1

  # Canary [1]-G — the NEGATIVE canary for the extension: `2>&1 >/dev/null` REVERSES the order, so
  # stderr goes to the original stdout and is captured while stdout is discarded. That keeps the
  # diagnosis rather than silencing it, and jobs-batch-kueue.sh:198 does exactly this on purpose.
  # Without this canary a lazily-widened regex would quietly start punishing the good shape.
  d="$(mktemp -d)"
  cat > "${d}/only-captured-stderr.sh" <<'FIXTURE'
cq_probe() { cq_err="$(oc get clusterqueue "$1" -o name 2>&1 >/dev/null || true)"; }
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-G (NEGATIVE: '2>&1 >/dev/null' captures stderr and must stay clean)" 0 "$got" || bad_seen=1

  # Canary [2] — a module script shadows a shared predicate with a local copy.
  d="$(_canary_verify_dir platform-orientation.sh '1i\
deploy_ready() { return 0; }')"
  got=0; check_no_local_predicate_shadow "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [2] (deploy_ready() shadowed locally)" 1 "$got" || bad_seen=1

  # Canary [3] — the NotFound-folding regression, byte-for-byte: oc_read's one `return 1` flipped to
  # `return 0`. Must be caught, and must be caught specifically on the NotFound case (not by accident
  # on the success case, which the mutation does not touch).
  mutated_file="$(_build_notfound_folding_canary)"
  if [[ -z "$mutated_file" ]]; then
    bad "SELF-TEST FAILED: could not build the NotFound-folding canary."
    return 2
  fi
  got=0; check_oc_read_notfound_not_folded "$mutated_file" >/dev/null 2>&1 || got=$?
  rm -f "$mutated_file"
  _expect_rc "canary [3] (NotFound folded into rc 0, oc_read's first-draft regression)" 1 "$got" || bad_seen=1

  # Canary — coverage wiring: a detector declared but never called by run_check must be rc=2, never
  # silently tolerated. Mirrors cohort-ops-guard.sh's own canary F.
  cov=0
  (
    # shellcheck disable=SC2317,SC2329
    check_never_called() { ran_check; return 0; }
    run_check "$VERIFY_DIR" "$LIB_SH" >/dev/null 2>&1
  ) || cov=$?
  if [[ "$cov" -ne 2 ]]; then
    bad "SELF-TEST FAILED: a declared-but-never-called detector was not caught (rc=${cov}) — the coverage assertion is inert."
    bad_seen=1
  fi

  if [[ "$bad_seen" -ne 0 ]]; then
    return 2
  fi
  ok "self-test ok — ratchet-exceeded, unlisted-file, '>/dev/null 2>&1', '&>/dev/null', predicate shadow,"
  ok "   NotFound-folding and an uncalled detector all caught; gitea_host exclusion, pure-curl probe and"
  ok "   the stderr-CAPTURING '2>&1 >/dev/null' shape all stay clean; real tree within baseline."
  # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
  return 1
}

parse_guard_args "$@"

if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

if [[ ! -d "$VERIFY_DIR" ]]; then
  bad "${VERIFY_DIR} not found"
  exit 2
fi
if [[ ! -f "$LIB_SH" ]]; then
  bad "${LIB_SH} not found"
  exit 2
fi
RC=0
run_check "$VERIFY_DIR" "$LIB_SH" || RC=$?
if [[ "$RC" -eq 0 ]]; then
  ok "verify-oc-read-guard: no new stderr-silenced 'oc' reads beyond baseline, no shared-predicate shadowing, oc_read's three-outcome contract intact."
fi
exit "$RC"
