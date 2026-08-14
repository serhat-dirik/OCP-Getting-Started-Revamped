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
# Exit codes (the shared contract):
#   0  the predicate behaves correctly in all six cases
#   1  it does not — or, under --self-test, every planted canary was correctly caught
#   2  the guard could not do its job (the functions could not be extracted, or a canary went
#      UNdetected). Never confuse this with a clean result.
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
run_check() {
  local lib="$1" rc=0 out got

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
    rc=1
  else
    got="$(_field "$out" CONFLICT)"
    if [[ "$got" != "unit-test" ]]; then
      bad "[a] the offending task must be named in PIPELINE_PVC_CONFLICT; got '${got}', expected 'unit-test'."
      note "The attendee-facing hint is built from that variable — an empty name sends them nowhere."
      rc=1
    fi
  fi

  # [b] the false-positive direction
  out="$(run_case "$lib" workspaces "$FIXTURE_ONE_PVC" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "0" ]]; then
    bad "[b] a Pipeline with one PVC-backed workspace per task must PASS; got rc=${got:-<none>}. Output: ${out}"
    note "A false ❌ on a working module destroys attendee trust in every other ✅."
    rc=1
  fi

  # [c] the permissive mode really is permissive
  out="$(run_case "$lib" pipelineruns "$FIXTURE_TWO_PVC" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "0" ]]; then
    bad "[c] coschedule=pipelineruns lifts the one-PVC cap and must PASS; got rc=${got:-<none>}. Output: ${out}"
    note "Measured on cluster-6xxpf 2026-08-08: the identical two-PVC Pipeline ran to completion"
    note "in that mode. Failing it here would invent a constraint the cluster does not enforce."
    rc=1
  fi

  # [d] absence is the operator default, and the default is restrictive
  out="$(run_case "$lib" "" "$FIXTURE_TWO_PVC" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "1" ]]; then
    bad "[d] an UNSET coschedule must be read as the restrictive default and FAIL; got rc=${got:-<none>}. Output: ${out}"
    note "An empty .spec.pipeline.coschedule is what a stock cluster reports. Reading it as"
    note "permission would pass exactly the clusters this whole check exists to protect."
    rc=1
  fi

  # [e] an emptyDir workspace is not a PVC
  out="$(run_case "$lib" workspaces "$FIXTURE_MIXED" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "0" ]]; then
    bad "[e] a task binding one PVC workspace plus one NON-PVC workspace must PASS; got rc=${got:-<none>}. Output: ${out}"
    note "app-security-testing's dast-zap/perf-k6 shape. zap-work and k6-work are declared like"
    note "any other workspace and bound emptyDir by every runner — counting them fails a"
    note "capstone that runs perfectly."
    rc=1
  fi

  # [f] Tekton's own defaulting rule for an omitted `workspace:`
  out="$(run_case "$lib" workspaces "$FIXTURE_DEFAULTED" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "1" ]]; then
    bad "[f] a binding that omits 'workspace:' defaults to the Task's own name and must still count; got rc=${got:-<none>}. Output: ${out}"
    note "Reading the omitted field as an empty pipeline-workspace name silently stops counting —"
    note "a false PASS on a Pipeline that is genuinely broken."
    rc=1
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
    rc=1
  fi

  # [h] deduplicating must not become "stop counting"
  out="$(run_case "$lib" workspaces "$FIXTURE_SAME_WS_PLUS_SECOND" shared-workspace maven-cache)"
  got="$(_field "$out" RC)"
  if [[ "$got" != "1" ]]; then
    bad "[h] a doubled binding PLUS a genuinely second PVC workspace is TWO claims and must FAIL; got rc=${got:-<none>}. Output: ${out}"
    note "This is [g] read too eagerly: a predicate that stops counting after the first PVC binding"
    note "satisfies [g] and is the 2026-08-07 regression again. Dedupe, do not cap."
    rc=1
  else
    got="$(_field "$out" CONFLICT)"
    if [[ "$got" != "unit-test" ]]; then
      bad "[h] the offending task must be named in PIPELINE_PVC_CONFLICT; got '${got}', expected 'unit-test'."
      note "The attendee-facing hint is built from that variable — an empty name sends them nowhere."
      rc=1
    fi
  fi

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

# _canary <n> <expected-rc> <src> <dst> <sed-expr> <caught-msg> <missed-msg> → 0 caught, 1 not
_canary() {
  local n="$1" want="$2" src="$3" dst="$4" expr="$5" caught="$6" missed="$7" rc=0
  _mutate "$n" "$src" "$dst" "$expr" || return 1
  run_check "$dst" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    ok "canary ${n} caught: ${caught}"
    return 0
  fi
  bad "canary ${n} UNDETECTED (rc=${rc}, expected ${want}) — ${missed}"
  return 1
}

_self_test() {
  local src="$1" tmp fail=0 rc
  tmp="$(mktemp -d)"

  cp "$src" "${tmp}/clean.sh"
  run_check "${tmp}/clean.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "the real predicate passes all eight cases"
  else bad "the REAL predicate failed the case battery (rc=${rc}) — see the plain run for which case"; fail=1; fi

  # Canary 1: absence read as permission. The exact inversion case [d] exists for.
  _canary 1 1 "$src" "${tmp}/c1.sh" 's/OC_OUT:-workspaces/OC_OUT:-pipelineruns/' \
    "an unset coschedule defaulted to the PERMISSIVE mode" \
    "a predicate that reads absence as permission passes this guard" || fail=1

  # Canary 2: off-by-one on the cap. Two PVCs would be tolerated and three would not.
  _canary 2 1 "$src" "${tmp}/c2.sh" 's/if (( n > 1 )); then/if (( n > 2 )); then/' \
    "the cap raised from one PVC to two" \
    "the regression itself would pass this guard" || fail=1

  # Canary 3: the mode gate inverted, so the check only runs where it does not apply.
  # shellcheck disable=SC2016  # the $ are literal text in a sed script, not expansions
  _canary 3 1 "$src" "${tmp}/c3.sh" \
    's/\[\[ "\$AFFINITY_ASSISTANT_MODE" == "workspaces" \]\] || return 0/[[ "$AFFINITY_ASSISTANT_MODE" != "workspaces" ]] || return 0/' \
    "the restrictive-mode gate inverted" \
    "the predicate could grade the wrong clusters" || fail=1

  # Canary 4: the PVC-backed set ignored, so every workspace counts. Fails [e]. Anchored on the
  # per-binding reset rather than on the match itself: forcing is_pvc high before the loop makes
  # every workspace look PVC-backed, and the anchor is a whole line that cannot be reflowed away.
  _canary 4 1 "$src" "${tmp}/c4.sh" 's/is_pvc=0/is_pvc=1/' \
    "every workspace counted, PVC-backed or not" \
    "emptyDir workspaces would red-flag a working capstone" || fail=1

  # Canary 5: the function renamed out from under the extractor. Must be rc 2 (could not inspect),
  # NOT rc 1 — "I could not look" and "I looked and it is broken" are different answers, and only
  # one of them should let a maintainer go on believing the predicate was checked.
  _canary 5 2 "$src" "${tmp}/c5.sh" 's/^pipeline_pvc_workspaces_ok() {/pipeline_pvc_workspaces_okay() {/' \
    "a renamed predicate reports 'could not inspect', not 'clean'" \
    "a guard pointing at nothing must never read as a pass" || fail=1

  # Canary 6: the distinct-claims fix reverted — the membership test neutered so every PVC-backed
  # BINDING counts again. This is the predicate exactly as it shipped before 2026-08-14, and case
  # [g] is the only thing that fails on it: [a]-[f] all still pass, which is precisely why the
  # defect survived a guard with five canaries and six cases.
  # shellcheck disable=SC2016  # literal $ inside a sed script, not an expansion
  _canary 6 1 "$src" "${tmp}/c6.sh" 's/"\$seen" != /"" != /' \
    "the claim-dedupe reverted to counting bindings" \
    "one PVC at two subPaths would again fail a capstone that runs perfectly" || fail=1

  rm -rf "$tmp"
  if [[ "$fail" -ne 0 ]]; then
    bad "self-test FAILED — this guard cannot be trusted on the real tree"
    return 2
  fi
  printf '  pipeline-admissibility-guard: self-test passed (six canaries, every one caught)\n'
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
