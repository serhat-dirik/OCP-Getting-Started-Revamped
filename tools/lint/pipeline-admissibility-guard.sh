#!/usr/bin/env bash
# pipeline-admissibility-guard.sh — prove that tools/verify/_lib.sh's admissibility predicate still
# tells a Pipeline that CAN run from one that cannot.
#
# WHY THIS EXISTS. On 2026-08-07 the pipelines-fundamentals and app-security-testing Pipelines gained
# a second PVC-backed workspace (a persistent Maven cache). On any cluster in Tekton's default
# Affinity Assistant mode — `coschedule: workspaces`, which is the OPERATOR default and what
# platform-portfolio leaves in place — a TaskRun may mount exactly ONE PersistentVolumeClaim, so
# every run of both modules died 27 seconds in with `TaskRunValidationFailed` /
# "[User error] more than one PersistentVolumeClaim is bound", before a step started and therefore
# with no logs at all. Both verify scripts reported all-green throughout: they asserted the Pipeline
# object existed and the cache CLAIM existed, and both were perfectly present.
#
# `pipeline_pvc_workspaces_ok` (tools/verify/_lib.sh) is the check that closed that hole, and it is
# the ONE assertion in either script whose failure means "this module cannot run". A predicate that
# important must not be able to go quietly wrong, and it is exactly the shape that can: it returns 0
# in the common case, it reads two cluster objects, and nobody re-runs the broken pipeline to check.
#
# WHAT THIS GUARD DOES — it EXECUTES the real predicate, never greps it. The functions are extracted
# verbatim from tools/verify/_lib.sh (tools/lint/_extract-func.sh) and driven against a stubbed `oc`
# through eight cases whose right answers are known from a live cluster (cluster-6xxpf, OCP 4.22.8 /
# OpenShift Pipelines 1.23.1, 2026-08-08): the same two Pipelines were applied broken and fixed with
# the cluster mode held constant, and this predicate returned 1 (naming `unit-test`, then
# `sast-sonar`) and then 0. A source scan proves the text; only execution proves the behaviour.
#
# THE EIGHT CASES, and why each is here rather than being "more of the same":
#   [a] restrictive mode, a task with TWO PVC-backed workspaces  → 1, and it must NAME the task.
#       The regression itself. The name is asserted because the hint an attendee reads is built from
#       PIPELINE_PVC_CONFLICT — a detector that fires with an empty name sends them nowhere.
#   [b] restrictive mode, every task with one                    → 0. The false-positive direction.
#       A check that reddens a working module costs every other ✅ its credibility.
#   [c] permissive mode (pipelineruns), a task with TWO          → 0. The cap genuinely does not
#       apply there — measured, not assumed: with coschedule=pipelineruns the identical two-PVC
#       Pipeline ran to completion in 11m10s. Asserting the constraint anyway would be inventing one.
#   [d] mode UNSET, a task with TWO                              → 1. THE DIRECTION THAT MUST NEVER
#       FLIP. An empty `.spec.pipeline.coschedule` is not "no mode", it is the operator default, and
#       the default is the restrictive one. A predicate that read absence as permission would pass
#       every stock cluster — i.e. exactly the clusters the regression broke.
#   [e] restrictive mode, a task with two workspaces of which only ONE is PVC-backed → 0. This is
#       app-security-testing's real shape: `zap-work` and `k6-work` are declared like any other
#       workspace and every runner binds them `emptyDir: {}`. The caller passes the PVC-backed set
#       for this reason, and a predicate that ignored it would fail a capstone that runs fine.
#   [f] a task binding that omits `workspace:` → resolved by the Task's own workspace name → 1.
#       Tekton's own defaulting rule. Missing it would read the pipeline-level name as empty and
#       silently stop counting, which is a false PASS on a genuinely broken Pipeline.
#   [g] restrictive mode, ONE task binding TWO of its own workspaces to the SAME pipeline workspace
#       → 0. The predicate counts CLAIMS, and this is one claim at two subPaths. Legal, and Tekton
#       admits it: measured 2026-08-13 on the intra-run Maven cache probe for parasol-claims-
#       devsecops (PipelineRun p1-probe-2ws-7t7rq Succeeded, its pod carrying a single volume
#       mounted twice). An earlier draft incremented once per BINDING and called this a conflict,
#       so a capstone that runs perfectly went ❌ — and the workaround written into
#       pipelines/pipeline/parasol-claims-devsecops.yaml's own comment was "anyone reviving this
#       idea has to fix that helper". This case is that fix, pinned.
#   [h] restrictive mode, one task binding the SAME workspace twice AND a genuinely second PVC
#       workspace → 1, naming the task. [g]'s companion and the reason it cannot be satisfied
#       cheaply: "stop counting after the first PVC binding" would pass [g] and this one turns it
#       straight back into the 2026-08-07 regression. Deduplicating is not the same as capping.
#
# WHAT PROVES THE CASES THEMSELVES — the witness table.
#
# NEITHER coverage meta-tool in tools/lint can see these cases. _canary-coverage.py mutates Python
# ASTs and cannot reach Bash at all; _check-coverage.sh reads Bash but only understands a run_check()
# driver plus top-level check_*() detector functions, and this guard's cases are inline [a]…[h]
# blocks driving functions extracted from another file. It therefore names this guard in its
# not-inspected list, and that is expected to stay true — the shape has not changed. What changed on
# 2026-08-23 is that the cases stopped relying on being seen by a meta-tool and started proving
# themselves, because "it ships a --self-test" was never the same claim as "each of its cases can
# still fail".
#
# The mechanism: run_check records the id of every case that objects (CASES_FAILED), and each canary
# asserts the EXACT set, not just the exit code. Most mutants trip several cases, so an rc-only
# assertion let any one of them carry the canary — measured before the change, blinding [a],
# [a-name], [b], [c], [f], [h] or [h-name] one at a time left --self-test at 1. Seven of the ten
# objections were proving nothing. Now blinding any single one changes a set and --self-test exits 2.
#
#   case      witnessed by   the blinding shows up as
#   [a]       canary 2, 3    the set loses `a`
#   [a-name]  canary 7, 8    the set loses `a-name`
#   [b]       canary 7       the set loses `b`      ← had NO canary at all before 2026-08-23
#   [c]       canary 3       the set loses `c`
#   [d]       canary 1, 2, 3 canary 1 goes UNDETECTED (it is its only case); 2 and 3 lose `d`
#   [e]       canary 4, 7    canary 4 goes UNDETECTED; 7 loses `e`
#   [f]       canary 2, 3    the set loses `f`
#   [g]       canary 6, 7    canary 6 goes UNDETECTED; 7 loses `g`
#   [h]       canary 2, 3    the set loses `h`
#   [h-name]  canary 7, 8    the set loses `h-name` ← had NO canary at all before 2026-08-23
#
# The extraction preamble is witnessed by canary 5, whose expected set is EMPTY: rc 2 with any id
# recorded would mean the battery ran against a library missing the function under test.
#
# Verified by hand, since no meta-tool can do it: each of the ten `_fail <id>` lines replaced with
# `:` in a scratch copy, one at a time, `--self-test` exiting 2 on all ten. Re-verify that way after
# adding or removing a case — and update the expected set of every canary the new case objects to,
# or the canaries will report the addition as a blinding.
#
# Exit codes (the shared contract):
#   0  the predicate behaves correctly in all eight cases
#   1  it does not — or, under --self-test, every planted canary was correctly caught
#   2  the guard could not do its job (the functions could not be extracted, a canary went
#      UNdetected, or a canary was caught by the WRONG set of cases — one of its detectors has gone
#      blind even though the exit code still looks right). Never confuse this with a clean result.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "${LINT_DIR}/_parse-guard-args.sh"
# shellcheck source=tools/lint/_extract-func.sh
source "${LINT_DIR}/_extract-func.sh"

LIB_DEFAULT="tools/verify/_lib.sh"

ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }

# CASES_FAILED — the ids of the cases that objected on the last run_check, in case order (`a,d,f,h`).
#
# This is what makes each inline case individually PROVEN rather than merely present. The cases are
# not top-level check_*() functions, so tools/lint/_check-coverage.sh cannot see them and
# _canary-coverage.py cannot reach Bash at all; without the id, a canary is satisfied by ANY ONE of
# the cases that object to it. Measured on this guard 2026-08-23, before this variable existed:
# blinding [a], [a-name], [b], [c], [f], [h] or [h-name] one at a time left --self-test at 1 — seven
# of the ten objections were proving nothing. Each canary now asserts the EXACT set, so blinding any
# single objection changes that set and --self-test exits 2.
CASES_FAILED=""

# _fail <case-id> — the ONE way a case objects. Recording the id and failing the run are the same
# act deliberately: if a case could still redden run_check without naming itself, an objection could
# be blinded while the set stayed intact and the witness would be worthless.
_fail() { CASES_FAILED="${CASES_FAILED}${CASES_FAILED:+,}${1}"; }

# ── the stub cluster ─────────────────────────────────────────────────────────────────────────────
#
# One `oc` for both reads the predicate makes, keyed on the resource in $2 exactly as the real
# invocations spell it. Deliberately NOT keyed on a substring of the whole argv: the plural is
# written in full at both call sites (`tektonconfigs.operator.tekton.dev`, `pipelines.tekton.dev`)
# because bare plurals are ambiguous on a cluster with MTA or Knative installed, and a stub that
# matched loosely would keep passing if a call site lost the qualification.
_write_stub() {  # <file> <coschedule-value> <pipeline-jsonpath-output>
  local file="$1" mode="$2" body="$3"
  {
    printf 'oc() {\n'
    # SC2016 all through this block, deliberately: every one of these is the TEXT of the stub being
    # written to a file, and $2 must reach the stub unexpanded so it names the stub's own argument.
    # shellcheck disable=SC2016
    printf '  case "${2:-}" in\n'
    printf '    tektonconfigs.operator.tekton.dev) printf %%s %q; return 0 ;;\n' "$mode"
    printf '    pipelines.tekton.dev)              printf %%s %q; return 0 ;;\n' "$body"
    printf '  esac\n'
    # An unrecognised read is NOT silence: silence is how oc_read spells "could not ask", which
    # would make an unstubbed call look like an inconclusive cluster instead of a broken stub.
    # shellcheck disable=SC2016
    printf '  printf "pipeline-admissibility-guard: stub asked for an unexpected resource: %%s\\n" "${2:-<none>}" >&2\n'
    printf '  return 1\n'
    printf '}\n'
  } > "$file"
}

# The `<task>|<taskWs>:<pipelineWs>,` lines the predicate's own jsonpath produces. Written out by
# hand rather than generated from a Pipeline so the fixtures stay readable AND so a change to that
# jsonpath is caught here: if the predicate stops emitting this shape, every case below moves.
FIXTURE_TWO_PVC='fetch-source|output:shared-workspace,
unit-test|source:shared-workspace,maven-cache:maven-cache,
build-image|source:shared-workspace,'
FIXTURE_ONE_PVC='fetch-source|output:shared-workspace,
unit-test|source:shared-workspace,
build-image|source:shared-workspace,'
# dast-zap takes the checkout AND an emptyDir workspace — two bindings, one PVC.
FIXTURE_MIXED='fetch-source|output:shared-workspace,
dast-zap|source:shared-workspace,zap-work:zap-work,'
# `workspace:` omitted on the second binding: Tekton defaults it to the Task's own workspace name,
# so this task really does bind maven-cache twice over from the assistant's point of view.
FIXTURE_DEFAULTED='fetch-source|output:shared-workspace,
unit-test|source:shared-workspace,maven-cache:,'
# TWO of the task's OWN workspaces onto ONE pipeline workspace — the shape the intra-run Maven cache
# experiment produced. `source` and `cache` are distinct task workspaces; both resolve to
# shared-workspace, so the TaskRun mounts ONE claim at two subPaths and Tekton admits it.
FIXTURE_SAME_WS_TWICE='fetch-source|output:shared-workspace,
unit-test|source:shared-workspace,cache:shared-workspace,'
# The same doubled binding PLUS a genuinely second claim. Distinct claims = 2, so this must fail —
# a predicate that deduplicates by giving up after the first PVC binding would pass it.
FIXTURE_SAME_WS_PLUS_SECOND='fetch-source|output:shared-workspace,
unit-test|source:shared-workspace,cache:shared-workspace,maven-cache:maven-cache,'

# run_case <lib> <coschedule> <pipeline-output> <pvc-workspace…> → stdout "RC=<n> CONFLICT=<task>"
#
# `|| rc=$?`, never a bare call: the harness runs under `set -euo pipefail` like the verify scripts
# the predicate is written for, and rc 1 is a DESIGNED outcome here — a bare call would kill the
# harness before it could report the very thing it is measuring.
run_case() {
  local lib="$1" mode="$2" body="$3"; shift 3
  local script stub rc a
  stub="$(mktemp)"; script="$(mktemp)"
  _write_stub "$stub" "$mode" "$body"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    cat "$stub"
    extract_func "$lib" oc_read
    extract_func "$lib" affinity_assistant_mode
    extract_func "$lib" pipeline_pvc_workspaces_ok
    printf 'OC_OUT=""; OC_ERR=""; VERIFY_INCONCLUSIVE=0\n'
    printf 'AFFINITY_ASSISTANT_MODE=""; PIPELINE_PVC_CONFLICT=""\n'
    printf 'rc=0\n'
    printf 'pipeline_pvc_workspaces_ok p ns'
    for a in "$@"; do printf ' %q' "$a"; done
    printf ' || rc=$?\n'
    # shellcheck disable=SC2016
    printf 'printf "RC=%%s CONFLICT=%%s\\n" "$rc" "$PIPELINE_PVC_CONFLICT"\n'
  } > "$script"
  bash "$script" 2>/dev/null
  rc=$?
  rm -f "$script" "$stub"
  return "$rc"
}

_field() {  # <harness-output> <field> → value
  sed -nE "s/.*${2}=([^ ]*).*/\\1/p" <<< "$1"
}

# run_check <lib> → 0 every case correct · 1 a case is wrong · 2 the predicate could not be extracted
#
# Also sets CASES_FAILED to the ids of the cases that objected. Reset here, not at declaration:
# _canary calls this repeatedly in the SAME shell, so a set left over from the previous canary would
# be read as this one's.
run_check() {
  local lib="$1" rc=0 out got
  CASES_FAILED=""

  local fn
  for fn in oc_read affinity_assistant_mode pipeline_pvc_workspaces_ok; do
    if [[ -z "$(extract_func "$lib" "$fn")" ]]; then
      bad "${fn}() could not be extracted from ${lib} — this guard inspected nothing."
      note "It was renamed, moved, or reformatted so its definition no longer starts at column 0."
      return 2
    fi
  done

  # [a] the regression itself
  out="$(run_case "$lib" workspaces "$FIXTURE_TWO_PVC" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "1" ]]; then
    bad "[a] two PVC-backed workspaces on one task must fail in the default mode; got rc=${got:-<none>}. Output: ${out}"
    note "This is the 2026-08-07 regression verbatim. A pass here is a verify suite that goes"
    note "green over a module whose every run dies in 27 seconds with no logs."
    _fail a
  else
    got="$(_field "$out" CONFLICT)"
    if [[ "$got" != "unit-test" ]]; then
      bad "[a] the offending task must be named in PIPELINE_PVC_CONFLICT; got '${got}', expected 'unit-test'."
      note "The attendee-facing hint is built from that variable — an empty name sends them nowhere."
      _fail a-name
    fi
  fi

  # [b] the false-positive direction
  out="$(run_case "$lib" workspaces "$FIXTURE_ONE_PVC" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "0" ]]; then
    bad "[b] a Pipeline with one PVC-backed workspace per task must PASS; got rc=${got:-<none>}. Output: ${out}"
    note "A false ❌ on a working module destroys attendee trust in every other ✅."
    _fail b
  fi

  # [c] the permissive mode really is permissive
  out="$(run_case "$lib" pipelineruns "$FIXTURE_TWO_PVC" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "0" ]]; then
    bad "[c] coschedule=pipelineruns lifts the one-PVC cap and must PASS; got rc=${got:-<none>}. Output: ${out}"
    note "Measured on cluster-6xxpf 2026-08-08: the identical two-PVC Pipeline ran to completion"
    note "in that mode. Failing it here would invent a constraint the cluster does not enforce."
    _fail c
  fi

  # [d] absence is the operator default, and the default is restrictive
  out="$(run_case "$lib" "" "$FIXTURE_TWO_PVC" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "1" ]]; then
    bad "[d] an UNSET coschedule must be read as the restrictive default and FAIL; got rc=${got:-<none>}. Output: ${out}"
    note "An empty .spec.pipeline.coschedule is what a stock cluster reports. Reading it as"
    note "permission would pass exactly the clusters this whole check exists to protect."
    _fail d
  fi

  # [e] an emptyDir workspace is not a PVC
  out="$(run_case "$lib" workspaces "$FIXTURE_MIXED" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "0" ]]; then
    bad "[e] a task binding one PVC workspace plus one NON-PVC workspace must PASS; got rc=${got:-<none>}. Output: ${out}"
    note "app-security-testing's dast-zap/perf-k6 shape. zap-work and k6-work are declared like"
    note "any other workspace and bound emptyDir by every runner — counting them fails a"
    note "capstone that runs perfectly."
    _fail e
  fi

  # [f] Tekton's own defaulting rule for an omitted `workspace:`
  out="$(run_case "$lib" workspaces "$FIXTURE_DEFAULTED" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "1" ]]; then
    bad "[f] a binding that omits 'workspace:' defaults to the Task's own name and must still count; got rc=${got:-<none>}. Output: ${out}"
    note "Reading the omitted field as an empty pipeline-workspace name silently stops counting —"
    note "a false PASS on a Pipeline that is genuinely broken."
    _fail f
  fi

  # [g] one PVC at two subPaths is ONE claim — the false-positive direction, distinct-claims edition
  out="$(run_case "$lib" workspaces "$FIXTURE_SAME_WS_TWICE" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "0" ]]; then
    bad "[g] two task workspaces mapped to the SAME pipeline workspace is ONE PVC and must PASS; got rc=${got:-<none>}. Output: ${out}"
    note "The predicate must count DISTINCT CLAIMS, not bindings. Measured 2026-08-13: probe"
    note "PipelineRun p1-probe-2ws-7t7rq Succeeded with a single volume mounted at two subPaths."
    note "Counting bindings reddens 'ws verify app-security-testing' on a capstone that runs fine —"
    note "and pipelines/pipeline/parasol-claims-devsecops.yaml's own comment names this helper."
    _fail g
  fi

  # [h] deduplicating must not become "stop counting"
  out="$(run_case "$lib" workspaces "$FIXTURE_SAME_WS_PLUS_SECOND" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "1" ]]; then
    bad "[h] a doubled binding PLUS a genuinely second PVC workspace is TWO claims and must FAIL; got rc=${got:-<none>}. Output: ${out}"
    note "This is [g] read too eagerly: a predicate that stops counting after the first PVC binding"
    note "satisfies [g] and is the 2026-08-07 regression again. Dedupe, do not cap."
    _fail h
  else
    got="$(_field "$out" CONFLICT)"
    if [[ "$got" != "unit-test" ]]; then
      bad "[h] the offending task must be named in PIPELINE_PVC_CONFLICT; got '${got}', expected 'unit-test'."
      note "The attendee-facing hint is built from that variable — an empty name sends them nowhere."
      _fail h-name
    fi
  fi

  # The verdict is DERIVED from the recorded set rather than tracked alongside it. Two counters for
  # one fact drift: an objection that bumped rc without naming itself would redden the real tree
  # while leaving every canary's set unchanged — the exact blind spot the ids exist to close.
  [[ -z "$CASES_FAILED" ]] || rc=1
  return "$rc"
}

# ── self-test ────────────────────────────────────────────────────────────────────────────────────
#
# Each canary is a one-line MUTATION of a copy of the real _lib.sh — the plausible way to get this
# predicate wrong, not a synthetic one — and every mutation must be caught by run_check. A canary
# that goes undetected is exit 2: it means this guard would certify the mutated predicate as fine.

# _mutate <n> <src> <dst> <sed-expr> → 0 when the mutation actually landed.
#
# A canary whose sed matched NOTHING is byte-identical to the real predicate. run_check then passes
# it, the old code printed "canary N UNDETECTED", and a maintainer went hunting for a hole in a
# detector that was fine — the real fault being an anchor that had moved. This is not hypothetical:
# canary 4's anchor moved on 2026-08-14, when the predicate was fixed to count distinct claims and
# its one-line `if … then n=$((n+1)); break; fi` became a multi-line block. The cmp tells "the
# mutant was not built" apart from "the mutant was not caught". Same helper, same reason, as
# _build() in verify-summary-skip-guard.sh.
_mutate() {  # <n> <src> <dst> <sed-expr> → 0 built, 1 the sed matched nothing
  local n="$1" src="$2" dst="$3" expr="$4"
  sed "$expr" "$src" > "$dst"
  if cmp -s "$src" "$dst"; then
    bad "canary ${n} COULD NOT BE BUILT — its sed matched nothing, so the mutant is byte-identical"
    note "to the real predicate. The anchor it targets was renamed or reformatted; the canary is"
    note "proving nothing, which is NOT the same as the predicate being clean."
    return 1
  fi
  return 0
}

# _canary <n> <expected-rc> <expected-cases> <src> <dst> <sed-expr> <caught-msg> <missed-msg>
#         → 0 caught by exactly the right cases, 1 not
#
# <expected-cases> is the comma-joined, case-ordered set of ids that MUST object to this mutant —
# empty for a canary that never reaches the battery (canary 5, which fails extraction). Asserting the
# exact set, not merely the exit code, is the whole point: most mutants trip several cases, so an
# rc-only assertion lets any ONE of them carry the canary while the rest go unproven. With the set
# pinned, blinding a single case changes it and this reports the blinding instead of shrugging.
_canary() {
  # ARITY CHECKED, and `${8:-}` rather than `$8`, because the alternative is a crash that exits 1 —
  # the ONE code that means "self-test passed, every canary caught". Measured 2026-08-23: a call site
  # left at this function's previous seven arguments dies on `$8: unbound variable` under `set -u`,
  # bash exits 1, and CI's `--self-test must exit EXACTLY 1` assertion reads a guard that never
  # finished running as a clean bill of health. A wrong call must reach the rc-2 path like any other
  # broken harness, so the check runs before anything can trip over a missing argument.
  if (( $# != 8 )); then
    bad "canary ${1:-?}: _canary needs 8 arguments (n want cases src dst expr caught missed), got $#."
    note "A stale call site. Left to \`set -u\` this exits 1, which is indistinguishable from a"
    note "self-test that passed — so it is reported here instead, and the self-test exits 2."
    return 1
  fi
  local n="$1" want="$2" want_cases="$3" src="$4" dst="$5" expr="$6" caught="$7" missed="${8:-}" rc=0
  _mutate "$n" "$src" "$dst" "$expr" || return 1
  run_check "$dst" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    bad "canary ${n} UNDETECTED (rc=${rc}, expected ${want}) — ${missed}"
    return 1
  fi
  if [[ "$CASES_FAILED" != "$want_cases" ]]; then
    bad "canary ${n} was caught, but by the WRONG cases: got '${CASES_FAILED:-<none>}', expected '${want_cases:-<none>}'."
    note "The exit code is right and the detectors are NOT. Either a case stopped objecting to a"
    note "mutant it must object to — the blind spot these ids exist to catch — or a case was added,"
    note "removed or renamed and this expectation was not updated with it. Read the difference: an"
    note "id that vanished is a detector to fix, an id that appeared is an expectation to widen."
    return 1
  fi
  ok "canary ${n} caught by [${want_cases:-extraction}]: ${caught}"
  return 0
}

_self_test() {
  local src="$1" tmp fail=0 rc
  tmp="$(mktemp -d)"

  cp "$src" "${tmp}/clean.sh"
  run_check "${tmp}/clean.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 && -z "$CASES_FAILED" ]]; then ok "the real predicate passes all eight cases"
  else bad "the REAL predicate failed the case battery (rc=${rc}, cases '${CASES_FAILED:-<none>}') — see the plain run"; fail=1; fi

  # Canary 1: absence read as permission. The exact inversion case [d] exists for.
  _canary 1 1 "d" "$src" "${tmp}/c1.sh" 's/OC_OUT:-workspaces/OC_OUT:-pipelineruns/' \
    "an unset coschedule defaulted to the PERMISSIVE mode" \
    "a predicate that reads absence as permission passes this guard" || fail=1

  # Canary 2: off-by-one on the cap. Two PVCs would be tolerated and three would not.
  _canary 2 1 "a,d,f,h" "$src" "${tmp}/c2.sh" 's/if (( n > 1 )); then/if (( n > 2 )); then/' \
    "the cap raised from one PVC to two" \
    "the regression itself would pass this guard" || fail=1

  # Canary 3: the mode gate inverted, so the check only runs where it does not apply. [d] is in its
  # set alongside the restrictive-mode cases because an UNSET coschedule resolves to `workspaces`
  # before the gate is reached — the inverted gate then waves it through, which is the same cluster
  # the regression broke.
  # shellcheck disable=SC2016  # the $ are literal text in a sed script, not expansions
  _canary 3 1 "a,c,d,f,h" "$src" "${tmp}/c3.sh" \
    's/\[\[ "\$AFFINITY_ASSISTANT_MODE" == "workspaces" \]\] || return 0/[[ "$AFFINITY_ASSISTANT_MODE" != "workspaces" ]] || return 0/' \
    "the restrictive-mode gate inverted" \
    "the predicate could grade the wrong clusters" || fail=1

  # Canary 4: the PVC-backed set ignored, so every workspace counts. Fails [e]. Anchored on the
  # per-binding reset rather than on the match itself: forcing is_pvc high before the loop makes
  # every workspace look PVC-backed, and the anchor is a whole line that cannot be reflowed away.
  _canary 4 1 "e" "$src" "${tmp}/c4.sh" 's/is_pvc=0/is_pvc=1/' \
    "every workspace counted, PVC-backed or not" \
    "emptyDir workspaces would red-flag a working capstone" || fail=1

  # Canary 5: the function renamed out from under the extractor. Must be rc 2 (could not inspect),
  # NOT rc 1 — "I could not look" and "I looked and it is broken" are different answers, and only
  # one of them should let a maintainer go on believing the predicate was checked. Its expected case
  # set is EMPTY, and that is an assertion too: run_check must bail at the extraction preamble, so a
  # single id here would mean the battery ran against a library missing the very function under test.
  _canary 5 2 "" "$src" "${tmp}/c5.sh" 's/^pipeline_pvc_workspaces_ok() {/pipeline_pvc_workspaces_okay() {/' \
    "a renamed predicate reports 'could not inspect', not 'clean'" \
    "a guard pointing at nothing must never read as a pass" || fail=1

  # Canary 6: the distinct-claims fix reverted — the membership test neutered so every PVC-backed
  # BINDING counts again. This is the predicate exactly as it shipped before 2026-08-14, and case
  # [g] is the only thing that fails on it: [a]-[f] all still pass, which is precisely why the
  # defect survived a guard with five canaries and six cases.
  # shellcheck disable=SC2016  # literal $ inside a sed script, not an expansion
  _canary 6 1 "g" "$src" "${tmp}/c6.sh" 's/"\$seen" != /"" != /' \
    "the claim-dedupe reverted to counting bindings" \
    "one PVC at two subPaths would again fail a capstone that runs perfectly" || fail=1

  # Canary 7: the cap tightened by one instead of loosened — `n > 0`, so a SINGLE PVC-backed
  # workspace is called a conflict. Canary 2's mirror image, and the only mutant any of the
  # must-PASS cases object to: added 2026-08-23 because [b] — the false-positive direction, the case
  # whose whole job is to stop a working module going ❌ — had no canary at all, and neither did
  # either PIPELINE_PVC_CONFLICT name assertion. Both fall out of this one mutant: every fixture's
  # `fetch-source` binds one PVC workspace, so it now trips first and is named instead of
  # `unit-test`, which is exactly how a real off-by-one would misdirect the attendee's hint.
  _canary 7 1 "a-name,b,e,g,h-name" "$src" "${tmp}/c7.sh" 's/if (( n > 1 )); then/if (( n > 0 )); then/' \
    "the cap tightened from one PVC to none — a working module reddened, and the wrong task named" \
    "a predicate that reddens every Pipeline with a workspace at all passes this guard" || fail=1

  # Canary 8: the verdict kept, the NAME dropped. rc stays 1 on [a] and [h], so an rc-only guard sees
  # nothing wrong, and the attendee gets `❌ … conflicting PVC workspaces on task ''`. This is the
  # cheap refactor failure — the assignment lost while the `return 1` beside it survives — and it is
  # the one both name assertions are for.
  # shellcheck disable=SC2016  # literal $ inside a sed script, not an expansion
  _canary 8 1 "a-name,h-name" "$src" "${tmp}/c8.sh" 's/PIPELINE_PVC_CONFLICT="\$task"/PIPELINE_PVC_CONFLICT=""/' \
    "the conflicting task no longer named, though the verdict is still right" \
    "the hint an attendee reads would point at no task and this guard would not notice" || fail=1

  rm -rf "$tmp"
  if [[ "$fail" -ne 0 ]]; then
    bad "self-test FAILED — this guard cannot be trusted on the real tree"
    return 2
  fi
  printf '  pipeline-admissibility-guard: self-test passed (eight canaries, each caught by exactly the cases that must object)\n'
  return 1
}

parse_guard_args "$@"

LIB="${REPO_ROOT}/${LIB_DEFAULT}"
if [[ ! -f "$LIB" ]]; then
  bad "${LIB_DEFAULT} does not exist — the predicate this guard executes lives there."
  exit 2
fi

if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  _self_test "$LIB"
  exit $?
fi

run_check "$LIB"; RC=$?
case "$RC" in
  0) printf 'pipeline-admissibility-guard: clean (pipeline_pvc_workspaces_ok executed against 8 stubbed clusters).\n' ;;
  1) printf '\n%s\n'   "  tools/verify/_lib.sh's admissibility predicate no longer distinguishes a Pipeline that"
     printf '%s\n'     "  can run from one that cannot. Both pipelines-fundamentals and app-security-testing"
     printf '%s\n'     "  depend on it to fail a module whose runs die at validation with no logs — the exact"
     printf '%s\n\n'   "  defect their verify scripts reported all-green over on 2026-08-07." ;;
esac
exit "$RC"
