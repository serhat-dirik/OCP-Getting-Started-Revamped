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
# through six cases whose right answers are known from a live cluster (cluster-6xxpf, OCP 4.22.8 /
# OpenShift Pipelines 1.23.1, 2026-08-08): the same two Pipelines were applied broken and fixed with
# the cluster mode held constant, and this predicate returned 1 (naming `unit-test`, then
# `sast-sonar`) and then 0. A source scan proves the text; only execution proves the behaviour.
#
# THE SIX CASES, and why each is here rather than being "more of the same":
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

  return "$rc"
}

# ── self-test ────────────────────────────────────────────────────────────────────────────────────
#
# Each canary is a one-line MUTATION of a copy of the real _lib.sh — the plausible way to get this
# predicate wrong, not a synthetic one — and every mutation must be caught by run_check. A canary
# that goes undetected is exit 2: it means this guard would certify the mutated predicate as fine.
_self_test() {
  local src="$1" tmp fail=0 rc
  tmp="$(mktemp -d)"

  cp "$src" "${tmp}/clean.sh"
  run_check "${tmp}/clean.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "the real predicate passes all six cases"
  else bad "the REAL predicate failed the case battery (rc=${rc}) — see the plain run for which case"; fail=1; fi

  # Canary 1: absence read as permission. The exact inversion case [d] exists for.
  sed 's/OC_OUT:-workspaces/OC_OUT:-pipelineruns/' "$src" > "${tmp}/c1.sh"
  run_check "${tmp}/c1.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 1 ]]; then ok "canary 1 caught: an unset coschedule defaulted to the PERMISSIVE mode"
  else bad "canary 1 UNDETECTED (rc=${rc}) — a predicate that reads absence as permission passes this guard"; fail=1; fi

  # Canary 2: off-by-one on the cap. Two PVCs would be tolerated and three would not.
  sed 's/if (( n > 1 )); then/if (( n > 2 )); then/' "$src" > "${tmp}/c2.sh"
  run_check "${tmp}/c2.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 1 ]]; then ok "canary 2 caught: the cap raised from one PVC to two"
  else bad "canary 2 UNDETECTED (rc=${rc}) — the regression itself would pass this guard"; fail=1; fi

  # Canary 3: the mode gate inverted, so the check only runs where it does not apply.
  # shellcheck disable=SC2016  # the $ are literal text in a sed script, not expansions
  sed 's/\[\[ "\$AFFINITY_ASSISTANT_MODE" == "workspaces" \]\] || return 0/[[ "$AFFINITY_ASSISTANT_MODE" != "workspaces" ]] || return 0/' "$src" > "${tmp}/c3.sh"
  run_check "${tmp}/c3.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 1 ]]; then ok "canary 3 caught: the restrictive-mode gate inverted"
  else bad "canary 3 UNDETECTED (rc=${rc}) — the predicate could grade the wrong clusters"; fail=1; fi

  # Canary 4: the PVC-backed set ignored, so every workspace counts. Fails [e].
  # shellcheck disable=SC2016  # ditto — literal $ inside a sed script
  sed 's/if \[\[ "\$pipe_ws" == "\$want" \]\]; then n=\$((n+1)); break; fi/n=$((n+1)); break/' "$src" > "${tmp}/c4.sh"
  run_check "${tmp}/c4.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 1 ]]; then ok "canary 4 caught: every workspace counted, PVC-backed or not"
  else bad "canary 4 UNDETECTED (rc=${rc}) — emptyDir workspaces would red-flag a working capstone"; fail=1; fi

  # Canary 5: the function renamed out from under the extractor. Must be rc 2 (could not inspect),
  # NOT rc 1 — "I could not look" and "I looked and it is broken" are different answers, and only
  # one of them should let a maintainer go on believing the predicate was checked.
  sed 's/^pipeline_pvc_workspaces_ok() {/pipeline_pvc_workspaces_okay() {/' "$src" > "${tmp}/c5.sh"
  run_check "${tmp}/c5.sh" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 2 ]]; then ok "canary 5 caught: a renamed predicate reports 'could not inspect', not 'clean'"
  else bad "canary 5 UNDETECTED (rc=${rc}, expected 2) — a guard pointing at nothing must never read as a pass"; fail=1; fi

  rm -rf "$tmp"
  if [[ "$fail" -ne 0 ]]; then
    bad "self-test FAILED — this guard cannot be trusted on the real tree"
    return 2
  fi
  printf '  pipeline-admissibility-guard: self-test passed (five canaries, every one caught)\n'
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
  0) printf 'pipeline-admissibility-guard: clean (pipeline_pvc_workspaces_ok executed against 6 stubbed clusters).\n' ;;
  1) printf '\n%s\n'   "  tools/verify/_lib.sh's admissibility predicate no longer distinguishes a Pipeline that"
     printf '%s\n'     "  can run from one that cannot. Both pipelines-fundamentals and app-security-testing"
     printf '%s\n'     "  depend on it to fail a module whose runs die at validation with no logs — the exact"
     printf '%s\n\n'   "  defect their verify scripts reported all-green over on 2026-08-07." ;;
esac
exit "$RC"
