#!/usr/bin/env bash
# adoption-skippable-guard.sh — a component may not lose adoption-skippability in silence.
#
# ORIGIN (2026-08-01). argocd-bootstrap/install.sh §0 SKIPS a component on a cluster that already
# runs that operator, but only for components is_operator_only() calls "operator-only". That
# classifier reads FILENAMES: kustomization, namespace*, operatorgroup*, subscription* and nothing
# else. 49a7e28 added one ordinary file — components/openshift-pipelines/tekton-config.yaml — and
# thereby revoked that component's eligibility. Nothing said so. On a customer cluster already
# running Pipelines we now install our Subscription over theirs and re-channel an operator we
# promised not to touch.
#
# WHY THE EXISTING GATE DID NOT CATCH IT. platform-portfolio/hack/check-adoption-skip.sh proves that
# whatever is CURRENTLY skippable is SAFE to skip. It has no memory: a component that stops being
# skippable simply stops being examined, so the check passed through the regression without ever
# printing the word "openshift-pipelines". (It was also, separately, wired into no CI workflow at
# all — see the `adoption-skip` job added alongside this one.) A green gate that cannot mention the
# incident that motivated it is coverage-shaped decoration.
#
# WHAT THIS CHECKS. platform-portfolio/hack/adoption-skippable.snapshot is a GENERATED, committed
# record of every component's adoption verdict. This guard re-derives it — through the very same
# generator, which drives is_operator_only() itself rather than a copy — and diffs. Any difference
# is a failure, classified so the message names the consequence:
#
#   skippable → installs-more   ADOPTION DEMOTION. The regression above. Loudest message.
#   installs-more → skippable   ADOPTION PROMOTION. Safe-looking, still reviewed: it changes what
#                               the installer will silently drop on someone else's cluster.
#   present only in the tree    NEW COMPONENT whose adoption verdict nobody has looked at.
#   present only in the file    COMPONENT REMOVED.
#
# WHY THE SNAPSHOT CANNOT ROT. It is never typed. One command regenerates it from the real tree, the
# guard re-derives through the same code path on every push, and there is exactly one implementation
# of the derivation (lib-components.sh, sourced) — check_classifier_is_shared() proves the generator
# has not grown a second one. The failure mode a hand-maintained list would have (drifting quietly
# from reality) is the failure mode this guard is built to make impossible.
#
# Runnable standalone (CI lint gate) and by hand; needs bash + awk + the portfolio tree. No cluster,
# no kustomize, no yq.
#
# --self-test proves the detector fires before a clean run means anything. Its first canary IS the
# incident: a scratch copy of the real component tree with ONE extra file added to a currently
# skippable component, checked against the real snapshot. If that does not go red, the guard cannot
# catch what it was written for. Exit 1 = every canary caught AND the real tree clean, matching the
# house convention where CI asserts the self-test exits exactly 1.
#
# Exit codes:
#   0  the tree's adoption verdicts match the committed snapshot
#   1  drift — or, under --self-test, every canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (missing snapshot, generator, or library)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lint/_extract-func.sh
source "${LINT_DIR}/_extract-func.sh"
# shellcheck source=tools/lint/_check-coverage.sh
source "${LINT_DIR}/_check-coverage.sh"

GEN="${REPO_ROOT}/platform-portfolio/hack/gen-adoption-skippable.sh"
LIB="${REPO_ROOT}/platform-portfolio/argocd-bootstrap/lib-components.sh"
SNAPSHOT="${REPO_ROOT}/platform-portfolio/hack/adoption-skippable.snapshot"
COMPONENTS="${REPO_ROOT}/platform-portfolio/components"
REGEN_CMD="platform-portfolio/hack/gen-adoption-skippable.sh --write"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }

# Comments, blank lines and column padding stripped: what remains is "<verdict> <component>" per
# line, which is what the two sides are compared on. One implementation, two entry points — the
# committed file and the generator's stdout must be reduced by exactly the same rules or the
# comparison would report drift that is only formatting.
normalize_stream() {  # stdin → "<verdict> <component>" per line
  awk '/^[[:space:]]*#/ { next } NF == 0 { next } { print $1, $2 }'
}

normalize() {  # <file> → "<verdict> <component>" per line
  normalize_stream < "$1"
}

verdict_of() {  # <normalized-text> <component> → that component's verdict, or "" if absent
  awk -v c="$2" '$2 == c { print $1; exit }' <<< "$1"
}

# ── detector: the snapshot is a usable artifact, not an empty file wearing a green tick ───────────
check_snapshot_shape() {  # <snapshot-file> → 0 usable, 1 broken, 2 absent
  # shellcheck disable=SC2119  # no arg on purpose — ran_check records its caller
  ran_check
  local snap="$1" body skippable bad_verdicts rc=0

  if [[ ! -f "$snap" ]]; then
    bad "${snap#"${REPO_ROOT}/"} not found — there is no expected-skippable set to check against."
    note "Generate it: ${REGEN_CMD}"
    return 2
  fi

  body="$(normalize "$snap")"
  if [[ -z "$body" ]]; then
    bad "the snapshot holds no verdict lines at all."
    note "An empty expected set is satisfied by any tree, including one where adoption has been"
    note "switched off entirely. Regenerate: ${REGEN_CMD}"
    return 1
  fi

  bad_verdicts="$(awk '$1 != "skippable" && $1 != "installs-more" { print NR": "$0 }' <<< "$body")"
  if [[ -n "$bad_verdicts" ]]; then
    bad "the snapshot carries verdicts that are neither skippable nor installs-more:"
    while IFS= read -r line; do [[ -n "$line" ]] && note "$line"; done <<< "$bad_verdicts"
    note "It is a generated file — do not hand-edit it. Regenerate: ${REGEN_CMD}"
    rc=1
  fi

  # The vacuity guard. A snapshot recording nothing skippable is trivially matched by a classifier
  # that has stopped classifying — the exact shape of "an unrun gate is worse than none". The
  # portfolio ships operator-only components; if it genuinely stops shipping any, adoption is dead
  # and that deserves a red light, not a silent pass.
  skippable="$(grep -c '^skippable ' <<< "$body")"
  if [[ "$skippable" -eq 0 ]]; then
    bad "the snapshot records no skippable component at all — adoption is either dead or unmeasured."
    note "Every component being installs-more means install.sh §0 can never skip anything, so this"
    note "gate would pass no matter what the classifier does. Investigate before regenerating."
    rc=1
  fi

  [[ "$rc" -eq 0 ]] && ok "snapshot shape: ${skippable} skippable / $(grep -c . <<< "$body") components, verdicts well-formed"
  return "$rc"
}

# ── detector: the tree's verdicts still equal the committed ones ──────────────────────────────────
check_snapshot_matches() {  # <components-dir> <snapshot-file> → 0 match, 1 drift, 2 uninspectable
  # shellcheck disable=SC2119
  ran_check
  local dir="$1" snap="$2" derived expected comp dv sv rc=0

  if [[ ! -f "$GEN" ]]; then
    bad "${GEN#"${REPO_ROOT}/"} not found — nothing to re-derive the verdicts with."
    return 2
  fi
  [[ -f "$snap" ]] || return 2   # already reported by check_snapshot_shape

  if ! derived="$(bash "$GEN" --components-dir "$dir" 2>&1)"; then
    bad "the generator failed on ${dir}: ${derived}"
    return 2
  fi
  derived="$(normalize_stream <<< "$derived")"
  expected="$(normalize "$snap")"

  if [[ "$derived" == "$expected" ]]; then
    ok "adoption verdicts match the committed snapshot for all $(grep -c . <<< "$derived") components"
    return 0
  fi

  # Same set, classified per component so the message names the consequence rather than dumping a diff.
  while read -r dv comp; do
    [[ -n "$comp" ]] || continue
    sv="$(verdict_of "$expected" "$comp")"
    if [[ -z "$sv" ]]; then
      bad "NEW COMPONENT: ${comp} is in the tree but not in the snapshot (derived: ${dv})."
      note "Its adoption verdict has never been reviewed. Regenerate and read the diff: ${REGEN_CMD}"
      rc=1
    elif [[ "$sv" == "skippable" && "$dv" != "skippable" ]]; then
      bad "ADOPTION DEMOTION: ${comp} was adoption-skippable and is not any more."
      note "install.sh §0 can no longer skip it, so on a cluster that ALREADY runs this operator the"
      note "portfolio installs its own Subscription over the org's and re-channels an operator we"
      note "promised not to touch. is_operator_only() classifies by FILENAME, so this is usually one"
      note "added file — exactly the 2026-08-01 openshift-pipelines regression (tekton-config.yaml,"
      note "49a7e28), which every other gate passed through in silence."
      note "Fix: keep the component operator-only (move the extra resource into its own component),"
      note "or accept the loss deliberately, regenerate (${REGEN_CMD}) and say why in the commit."
      rc=1
    elif [[ "$sv" != "$dv" ]]; then
      bad "ADOPTION PROMOTION: ${comp} became adoption-skippable (${sv} → ${dv})."
      note "Safe-looking, still reviewed: it changes what the installer will silently DROP on a"
      note "cluster that already runs this operator. Confirm nothing the workshop needs went with it,"
      note "then regenerate: ${REGEN_CMD}"
      rc=1
    fi
  done <<< "$derived"

  while read -r sv comp; do
    [[ -n "$comp" ]] || continue
    if [[ -z "$(verdict_of "$derived" "$comp")" ]]; then
      bad "COMPONENT REMOVED: ${comp} is in the snapshot but no longer in the tree (was: ${sv})."
      note "Regenerate: ${REGEN_CMD}"
      rc=1
    fi
  done <<< "$expected"

  # Set-equal but not text-equal: duplicated or hand-reordered lines. The file is generated; a human
  # edit to it is drift even when it happens to describe the same verdicts.
  if [[ "$rc" -eq 0 ]]; then
    bad "the snapshot describes the right verdicts but is not what the generator emits (order or duplicate lines)."
    note "It is a generated file. Regenerate rather than hand-edit: ${REGEN_CMD}"
    rc=1
  fi
  return "$rc"
}

# ── detector: the verdicts come from the installer's classifier, not a second copy of it ──────────
check_classifier_is_shared() {  # → 0 shared, 1 re-implemented, 2 uninspectable
  # shellcheck disable=SC2119
  ran_check
  local body f rc=0

  for f in "$GEN" "$LIB"; do
    if [[ ! -f "$f" ]]; then
      bad "${f#"${REPO_ROOT}/"} not found — cannot prove the derivation uses the shared classifier."
      return 2
    fi
  done

  grep -q '^is_operator_only()' "$LIB" || {
    bad "lib-components.sh no longer defines is_operator_only() — the snapshot's meaning is undefined."
    return 2
  }

  if ! grep -q 'lib-components.sh' "$GEN"; then
    bad "the generator does not source lib-components.sh."
    note "The snapshot would then record a SECOND opinion about skippability. install.sh's real"
    note "decision could drift from it in either direction and this gate would keep passing."
    rc=1
  fi
  if grep -qE '^[[:space:]]*is_operator_only\(\)' "$GEN"; then
    bad "the generator defines its own is_operator_only() — that is a copy of the installer's decision."
    note "lib-components.sh exists so the skip decision and the proof it is safe are the same code."
    rc=1
  fi

  body="$(extract_func "$GEN" derive_verdicts)"
  if [[ -z "$body" ]]; then
    bad "could not extract derive_verdicts() from the generator — the guard cannot inspect what it claims to."
    return 2
  fi
  if ! grep -q 'is_operator_only' <<< "$body"; then
    bad "the generator's derive_verdicts() never calls is_operator_only()."
    note "Whatever it records, it is not the verdict install.sh §0 acts on."
    rc=1
  fi

  [[ "$rc" -eq 0 ]] && ok "the snapshot is derived through lib-components.sh's own is_operator_only() — one implementation"
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # <components-dir> <snapshot-file> → 0 clean, 1 drift, 2 uninspectable
  coverage_reset
  local dir="$1" snap="$2" rc=0 sub

  # Every detector runs on every pass, deliberately: a broken snapshot shape must not hide the
  # verdict comparison, and vice versa. Severity is folded (2 wins over 1 wins over 0), never
  # short-circuited — a detector that does not run is a detector whose canary proves nothing, and
  # assert_all_checks_ran below would rightly turn that into rc=2.
  sub=0; check_snapshot_shape "$snap" || sub=$?
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi

  sub=0; check_snapshot_matches "$dir" "$snap" || sub=$?
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 && "$rc" -ne 2 ]]; then rc=1; fi

  sub=0; check_classifier_is_shared || sub=$?
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 && "$rc" -ne 2 ]]; then rc=1; fi

  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site leaves
  # every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
scratch_components() {  # → a temp copy of the real component tree, path on stdout
  local dst
  dst="$(mktemp -d)"
  cp -R "${COMPONENTS}/." "${dst}/" 2>/dev/null
  # charts/ is gitignored and inflated locally by `kustomize build --enable-helm`; CI never has it.
  # Dropping it keeps the copy identical to what a fresh checkout classifies. (It cannot change a
  # verdict either way: kustomize only inflates charts/ for a component declaring helmCharts, and
  # that declaration already disqualifies the component on its own.)
  rm -rf "${dst}"/*/charts
  printf '%s' "$dst"
}

first_skippable() {  # <snapshot-file> → the first component the snapshot calls skippable
  awk '/^[[:space:]]*#/ { next } $1 == "skippable" { print $2; exit }' "$1"
}

self_test() {
  local rc out victim scratch snap snap_sed tmp saved_gen

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  rc=0
  run_check "$COMPONENTS" "$SNAPSHOT" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not match the committed snapshot (rc=${rc}). Run without --self-test."
    return 2
  fi

  victim="$(first_skippable "$SNAPSHOT")"
  if [[ -z "$victim" ]]; then
    bad "SELF-TEST FAILED: the snapshot names no skippable component, so the regression cannot be reproduced."
    return 2
  fi

  # Canary A, part 1 — an UNTOUCHED copy of the real tree must still pass. Without this the next
  # assertion proves only that the guard dislikes temp directories.
  scratch="$(scratch_components)"
  rc=0
  run_check "$scratch" "$SNAPSHOT" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: an unmodified copy of the real component tree was reported as drifted (rc=${rc})."
    rm -rf "$scratch"
    return 2
  fi

  # Canary A, part 2 — THE INCIDENT, reproduced. One extra file in a currently skippable component
  # is the entire 2026-08-01 regression: is_operator_only() classifies by filename, so this revokes
  # adoption eligibility with no other visible change. The guard must go red AND name the demotion.
  # Deliberately named so it can never accidentally match one of the classifier's allowed globs
  # (namespace*/operatorgroup*/subscription*) whatever the victim component happens to be called.
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: canary-operand\n' \
    > "${scratch}/${victim}/zz-canary-operand.yaml"
  rc=0
  out="$(run_check "$scratch" "$SNAPSHOT" 2>&1)" || rc=$?
  rm -rf "$scratch"
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: adding one file to ${victim} did NOT fail the check (rc=${rc})."
    note "That is the exact regression this guard exists for. It is decorative as written."
    return 2
  fi
  if ! grep -q "ADOPTION DEMOTION: ${victim} " <<< "$out"; then
    bad "SELF-TEST FAILED: the check failed on the added-file canary but never named ${victim} as a demotion."
    note "A red light that does not say which component lost adoption eligibility sends the reader"
    note "looking in the wrong place. Got: $(head -3 <<< "$out" | tr '\n' ' ')"
    return 2
  fi

  # Canary B — the other direction. A component the snapshot calls installs-more while the tree says
  # skippable must also fail: the set of things install.sh may silently drop cannot grow unreviewed.
  snap="$(mktemp)"
  # [[:space:]]+ rather than a literal run of spaces: the snapshot's column padding is the
  # generator's business, and a canary that silently stops matching when that changes is a canary
  # that stops testing.
  snap_sed="s/^skippable[[:space:]]+${victim}\$/installs-more ${victim}/"
  sed -E "$snap_sed" "$SNAPSHOT" > "$snap"
  if ! grep -q "^installs-more ${victim}\$" "$snap"; then
    bad "SELF-TEST FAILED: could not build the promotion canary — the ${victim} line was not found."
    rm -f "$snap"; return 2
  fi
  rc=0
  out="$(run_check "$COMPONENTS" "$snap" 2>&1)" || rc=$?
  rm -f "$snap"
  if [[ "$rc" -ne 1 ]] || ! grep -q "ADOPTION PROMOTION: ${victim} " <<< "$out"; then
    bad "SELF-TEST FAILED: a component gaining skippability was not caught as a promotion (rc=${rc})."
    return 2
  fi

  # Canary C — vacuity. A snapshot with no skippable line is satisfied by a classifier that has
  # stopped classifying; the shape detector must say so in those words, not just report a mismatch.
  snap="$(mktemp)"
  sed -E 's/^skippable[[:space:]]+/installs-more /' "$SNAPSHOT" > "$snap"
  rc=0
  out="$(run_check "$COMPONENTS" "$snap" 2>&1)" || rc=$?
  rm -f "$snap"
  if [[ "$rc" -ne 1 ]] || ! grep -q 'records no skippable component at all' <<< "$out"; then
    bad "SELF-TEST FAILED: a snapshot recording nothing skippable was not flagged as vacuous (rc=${rc})."
    return 2
  fi

  # Canary D — a missing snapshot is rc=2 ("could not inspect"), never a quiet 0. CI's
  # exit-exactly-1 assertion turns that into a red too.
  tmp="$(mktemp -d)"
  rc=0
  run_check "$COMPONENTS" "${tmp}/does-not-exist.snapshot" >/dev/null 2>&1 || rc=$?
  rm -rf "$tmp"
  if [[ "$rc" -ne 2 ]]; then
    bad "SELF-TEST FAILED: a missing snapshot returned rc=${rc}, expected 2 (uninspectable)."
    return 2
  fi

  # Canary E — the derivation must come from the installer's own classifier. Point the guard at a
  # generator that has grown its own is_operator_only(), and check_classifier_is_shared must object.
  tmp="$(mktemp -d)"
  {
    echo '#!/usr/bin/env bash'
    echo '# no lib-components.sh here'
    echo 'is_operator_only() { return 0; }'
    echo 'derive_verdicts() { echo "skippable x"; }'
  } > "${tmp}/gen.sh"
  # Saved and restored explicitly, not `GEN=… check_classifier_is_shared`: a variable assignment
  # prefixing a SHELL FUNCTION call is not reliably reverted afterwards, which would leave every
  # later check pointed at the fixture.
  saved_gen="$GEN"
  GEN="${tmp}/gen.sh"
  rc=0
  out="$(check_classifier_is_shared 2>&1)" || rc=$?
  GEN="$saved_gen"
  rm -rf "$tmp"
  if [[ "$rc" -ne 1 ]] || ! grep -q 'defines its own is_operator_only' <<< "$out"; then
    bad "SELF-TEST FAILED: a generator carrying its own copy of the classifier was not caught (rc=${rc})."
    return 2
  fi

  ok "self-test ok — untouched copy clean; one added file to ${victim} caught as an ADOPTION DEMOTION;"
  note "    promotion caught; vacuous snapshot caught; missing snapshot is rc=2; a re-implemented"
  note "    classifier is caught. Real tree matches the committed snapshot (rc=0)."
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

run_check "$COMPONENTS" "$SNAPSHOT"
exit $?
