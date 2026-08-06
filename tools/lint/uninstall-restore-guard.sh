#!/usr/bin/env bash
# uninstall-restore-guard.sh — the adopted-Argo-CD controller-sizing restore contract, gated.
#
# ORIGIN (2026-07-31). platform-portfolio/argocd-bootstrap/install.sh grew a consent prompt before
# raising an ADOPTED Argo CD controller's memory. Its text promised, verbatim:
#
#     "The prior value is recorded and ogsr-uninstall.sh restores it."
#
# It was false twice over. The prompt recorded argocd_controller_memory_prior +
# argocd_controller_memory_changed_by_us, and NOTHING anywhere read either key; meanwhile
# ogsr-uninstall.sh had a branch reading a DIFFERENT key (gitops_argocd_controller_resources_b64)
# which did not restore anything either — it printed a manual `oc edit` hint and moved on. Two keys
# for one fact, zero restores, and a user-facing promise that the workshop leaves no trace.
#
# That defect class is invisible to every other gate in this repo: both sides are valid shell, both
# sides lint clean, and the only way to notice is to run a real teardown on a real adopted cluster
# and look at a CR nobody looks at. So it gets a gate.
#
# WHAT IT CHECKS
#   [1] KEY SYMMETRY. Every uninstall-state key whose name mentions argocd/controller that an
#       INSTALLER writes must be READ by bootstrap/ogsr-uninstall.sh, and vice versa. A write-only
#       key is the exact shape of the original defect; a read-only key is a restore that can never
#       fire. Scoped to argocd/controller key names on purpose — that keeps it allowlist-free, so
#       it cannot rot into a list of exemptions nobody re-reads.
#   [2] RESTORE BEHAVIOUR. restore_argocd_controller_resources() is extracted from ogsr-uninstall.sh
#       and executed against stub `oc`/`state`, with the patches it issues recorded. Four cases:
#         a. consent recorded, NO prior recorded  → ONE merge patch setting resources to null
#            (an empty prior means the CR carried no explicit .spec.controller.resources, and
#            restoring that is REMOVING the field — never writing a number back);
#         b. consent recorded, prior recorded     → ONE json patch `add`-ing the recorded block
#            verbatim (a merge patch would union our four keys with the prior's and leave
#            requests.memory behind — union is not restoration);
#         c. NO consent recorded                  → NO patch at all (we never write to an adopted
#            CR we cannot prove we changed);
#         d. consent recorded, CR absent          → NO patch, no error (the org may have removed it).
#
# Runnable standalone (CI lint gate) and by hand; needs nothing but bash + grep + awk + base64.
#
# --self-test proves both detectors FIRE before a clean run on the real tree is worth anything:
# SEVEN canaries, one per declared property — both directions of [1], and all five cases of [2].
# Exit 1 = every canary was caught AND the real tree is clean under the same detectors; that is a
# PASS, matching the house convention where CI asserts the self-test step exits exactly 1.
# Exit 2 = a detector is blind, or the harness itself is broken.
#
# EVERY CANARY IS ASSERTED ON THE SPECIFIC MESSAGE for the property it breaks, and DENIES the
# messages it must not trip — never on the exit code alone (2026-08-06). [1]'s canary was measured
# INERT before this: it built its tree by copying ogsr-uninstall.sh and ONE synthetic installer,
# omitting the two real writers, so the two genuine keys the teardown reads looked unwritten and the
# detector fired THREE errors — one for the planted write-only key and two spurious "READ but never
# written" ones. Deleting the write-only assertion, the only one that names the 2026-07-31 defect,
# left --self-test still reporting 1: the guard was certified by the collateral damage of a mutant
# broken more widely than intended (a missing file), which is failure mode 1 exactly. The canary
# tree is now the REAL tree plus one appended defect, so exactly one message can fire.
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

UNINSTALL="bootstrap/ogsr-uninstall.sh"
FUNC="restore_argocd_controller_resources"
# Every file that writes into the ogsr-uninstall-state ConfigMap.
WRITERS=(
  "bootstrap/install.sh"
  "platform-portfolio/argocd-bootstrap/install.sh"
  "helm/bootstrap/templates/job-state-capture.yaml"
)

# ── [1] key symmetry ──────────────────────────────────────────────────────────
# Keys are written two ways: through record_once <key>, and through a raw
# `oc patch configmap … -p '{"data":{"<key>":…}}'` (the portfolio installer has no record_once).
# Both forms are matched; only key names mentioning argocd/controller are considered.
keys_written() {  # root →
  local root="$1" f
  for f in "${WRITERS[@]}"; do
    [[ -f "${root}/${f}" ]] || continue
    grep -ohE 'record_once[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "${root}/${f}" 2>/dev/null \
      | awk '{print $2}'
    # \"data\":{\"key\"  and  "data":{"key"  — the escaped and unescaped spellings.
    grep -ohE '\\?"data\\?":\{\\?"[A-Za-z_][A-Za-z0-9_]*\\?"' "${root}/${f}" 2>/dev/null \
      | sed -E 's/.*\{\\?"//; s/\\?"$//'
  done | grep -E 'argocd|controller' | sort -u
}

keys_read() {  # root →
  local root="$1"
  [[ -f "${root}/${UNINSTALL}" ]] || return 0
  grep -ohE 'state[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "${root}/${UNINSTALL}" 2>/dev/null \
    | awk '{print $2}' \
    | grep -E 'argocd|controller' | sort -u
}

check_key_symmetry() {  # root → 0 clean, 1 asymmetric, 2 nothing to inspect
  ran_check
  local root="$1" written read_ k rc=0 n=0
  written="$(keys_written "$root")"
  read_="$(keys_read "$root")"

  if [[ -z "$written" && -z "$read_" ]]; then
    bad "[1] no argocd/controller state keys found at all in ${root} — the detector is looking at the wrong files."
    return 2
  fi

  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    n=$((n + 1))
    if ! printf '%s\n' "$read_" | grep -qx "$k"; then
      bad "[1] state key '${k}' is WRITTEN by an installer but never read by ${UNINSTALL}."
      note "    A write-only restore key is the 2026-07-31 defect verbatim: install records it,"
      note "    the prompt promises teardown will use it, and teardown has never heard of it."
      rc=1
    fi
  done <<< "$written"

  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    if ! printf '%s\n' "$written" | grep -qx "$k"; then
      bad "[1] state key '${k}' is READ by ${UNINSTALL} but no installer ever writes it."
      note "    That branch can never fire — the restore it guards is dead code."
      rc=1
    fi
  done <<< "$read_"

  if [[ "$rc" -eq 0 ]]; then
    ok "[1] key symmetry: ${n} argocd/controller state key(s), every one written AND read"
    note "    $(printf '%s' "$written" | tr '\n' ' ')"
  fi
  return "$rc"
}

# ── [2] restore behaviour ─────────────────────────────────────────────────────
# The function is extracted, not sourced: ogsr-uninstall.sh runs a full teardown at top level and
# must never be sourced by a linter. Extraction failure is exit 2, never a silent pass.
# extract_func (2-arg: file, name) lives in _extract-func.sh, sourced above, shared with the other
# guards under tools/lint/; this guard's only target is $FUNC, so every call site passes it explicitly.

# Runs the extracted function once under stubs and echoes every `oc patch` argv it issued.
# T_* inputs: CHANGED, B64, CR_PRESENT, LIVE_MEM, DRY.
run_case() {  # func_file changed b64 cr_present live_mem dry → patch log on stdout; rc from the fn
  local func_file="$1" harness log rc=0
  harness="$(mktemp)"; log="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "DRY_RUN='${6}'"
    echo "ARGO_NS='openshift-gitops'"
    echo "SCRIPT_DIR='${REPO_ROOT}/bootstrap'"
    echo "T_CHANGED='${2}'"
    echo "T_B64='${3}'"
    echo "T_CR_PRESENT='${4}'"
    echo "T_LIVE_MEM='${5}'"
    echo "PATCH_LOG='${log}'"
    cat <<'STUBS'
ok()   { echo "ok: $*"; }
err()  { echo "err: $*" >&2; }
state() {
  case "$1" in
    argocd_controller_resources_changed_by_us) printf '%s' "$T_CHANGED" ;;
    gitops_argocd_controller_resources_b64)    printf '%s' "$T_B64" ;;
    *) : ;;
  esac
  return 0
}
# Only two oc verbs can be reached from this function. `get` answers presence and the live memory
# read; `patch` is RECORDED and never executed — the whole point of the harness.
oc() {
  local verb="$1"
  if [[ "$verb" == "get" ]]; then
    case " $* " in
      *" -o jsonpath="*) printf '%s' "$T_LIVE_MEM"; return 0 ;;
    esac
    [[ "$T_CR_PRESENT" == "true" ]] && return 0
    return 1
  fi
  if [[ "$verb" == "patch" ]]; then
    printf '%s\n' "$*" >> "$PATCH_LOG"
    return 0
  fi
  return 0
}
# yq is not a CI dependency of this guard, and the legacy branch calls it twice for two different
# things. Answer both faithfully, or the legacy sub-branches all collapse into one and the guard
# reports "no patch issued" for a reason it never actually exercised:
#   • `-p=json` over STDIN  → the RECORDED prior's limits.memory
#   • anything else          → the canonical target from the override file (6Gi)
yq() {
  case " $* " in
    *" -p=json "*)
      sed -n 's/.*"limits":{[^}]*"memory":"\([^"]*\)".*/\1/p'
      return 0 ;;
  esac
  printf '6Gi'
  return 0
}
STUBS
    cat "$func_file"
    echo "${FUNC}"
  } > "$harness"
  bash "$harness" >/dev/null 2>&1 || rc=$?
  cat "$log"
  rm -f "$harness" "$log"
  return "$rc"
}

check_restore_behaviour() {  # func_file → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local func_file="$1" out rc=0
  local prior_json='{"limits":{"memory":"3Gi"},"requests":{"memory":"1Gi"}}'
  local prior_b64
  prior_b64="$(printf '%s' "$prior_json" | base64 | tr -d '\n')"

  if [[ ! -s "$func_file" ]]; then
    bad "[2] could not extract ${FUNC}() — the guard cannot inspect what it claims to."
    return 2
  fi

  # (a) consent, EMPTY prior → remove the field with a merge-patch null.
  out="$(run_case "$func_file" true "" true 6Gi false)"
  if [[ "$(printf '%s' "$out" | grep -c .)" -ne 1 ]]; then
    bad "[2a] empty prior: expected exactly ONE patch, got: ${out:-<none>}"; rc=1
  elif ! printf '%s' "$out" | grep -q -- '--type merge'; then
    bad "[2a] empty prior: expected a MERGE patch, got: ${out}"; rc=1
  elif ! printf '%s' "$out" | grep -q '"resources":null'; then
    bad "[2a] empty prior must REMOVE .spec.controller.resources (merge-patch null), not write a value back."
    note "    got: ${out}"
    rc=1
  fi

  # (b) consent, recorded prior → json `add` of that exact block, no null.
  out="$(run_case "$func_file" true "$prior_b64" true 6Gi false)"
  if [[ "$(printf '%s' "$out" | grep -c .)" -ne 1 ]]; then
    bad "[2b] recorded prior: expected exactly ONE patch, got: ${out:-<none>}"; rc=1
  elif ! printf '%s' "$out" | grep -q -- '--type json'; then
    bad "[2b] recorded prior: expected a JSON patch (a merge patch unions instead of replacing), got: ${out}"; rc=1
  elif ! printf '%s' "$out" | grep -q '"op":"add"'; then
    bad "[2b] recorded prior: expected op=add on /spec/controller/resources, got: ${out}"; rc=1
  elif ! printf '%s' "$out" | grep -qF "$prior_json"; then
    bad "[2b] recorded prior: the recorded block was not patched back verbatim."
    note "    want: ${prior_json}"
    note "    got:  ${out}"
    rc=1
  fi

  # (c) NO consent recorded → never touch an adopted CR, in EVERY legacy shape. All three are run
  # because they are three different branches: the FSC entry point (records a prior, never patches,
  # live limit still the org's), a pre-consent-gate install (live limit is our target), and a cluster
  # that shipped at the target already.
  local legacy live
  for legacy in "${prior_b64}:2Gi" "${prior_b64}:6Gi" "$(printf '%s' '{"limits":{"memory":"6Gi"}}' | base64 | tr -d '\n'):6Gi"; do
    live="${legacy##*:}"
    out="$(run_case "$func_file" "" "${legacy%:*}" true "$live" false)"
    if [[ -n "$out" ]]; then
      bad "[2c] no consent recorded (live=${live}), yet the CR was patched: ${out}"; rc=1
    fi
  done

  # (d) consent, but the CR is gone → tolerate, patch nothing.
  out="$(run_case "$func_file" true "$prior_b64" false "" false)"
  if [[ -n "$out" ]]; then
    bad "[2d] CR absent, yet a patch was issued: ${out}"; rc=1
  fi

  # (e) dry-run must change nothing, in both restore shapes.
  out="$(run_case "$func_file" true "" true 6Gi true)$(run_case "$func_file" true "$prior_b64" true 6Gi true)"
  if [[ -n "$out" ]]; then
    bad "[2e] --dry-run issued a patch: ${out}"; rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[2] restore behaviour: empty prior removes the field, recorded prior is replaced verbatim,"
    note "    no consent → no write, absent CR → no write, dry-run → no write"
  fi
  return "$rc"
}

run_check() {  # root → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
  local root="$1" func_file rc=0 sub=0
  if [[ ! -f "${root}/${UNINSTALL}" ]]; then
    bad "${root}/${UNINSTALL} not found"
    return 2
  fi
  check_key_symmetry "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  func_file="$(mktemp)"
  extract_func "${root}/${UNINSTALL}" "$FUNC" > "$func_file"
  sub=0
  check_restore_behaviour "$func_file" || sub=$?
  rm -f "$func_file"
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Seven canaries, each the real defect shape for one declared property. All must be CAUGHT — by the
# assertion that NAMES that property, proven from the message — and the real tree must be clean under
# the same detectors. Anything else means the gate is decorative.

# Copies the whole inspected surface (the teardown + every writer) into <dir>, unmutated. Canaries
# then APPEND their one defect to one file, so the detector has nothing else to complain about.
# Building the tree from a subset instead is what made [1]'s canary inert — see the header.
materialize_tree() {  # <dir> → 0 built, 2 a source file was missing
  local dir="$1" f
  for f in "$UNINSTALL" "${WRITERS[@]}"; do
    if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
      bad "SELF-TEST FAILED: cannot build a canary tree — ${REPO_ROOT}/${f} does not exist."
      return 2
    fi
    mkdir -p "${dir}/$(dirname "$f")"
    cp "${REPO_ROOT}/${f}" "${dir}/${f}"
  done
  return 0
}

# Materializes $FUNC with one sed applied, and proves the sed actually changed something — a sed that
# silently matches nothing yields the REAL function, which passes, which reads as "detector blind".
build_canary_func() {  # <out-file> <sed-expr> → 0 built, 2 the mutation never applied
  local out="$1" expr="$2" pristine
  pristine="${out}.pristine"
  extract_func "${REPO_ROOT}/${UNINSTALL}" "$FUNC" > "$pristine"
  sed "$expr" "$pristine" > "$out"
  if [[ ! -s "$out" ]]; then
    bad "SELF-TEST FAILED: canary not built — ${FUNC}() extracted as empty, so there was nothing to mutate."
    return 2
  fi
  if cmp -s "$pristine" "$out"; then
    bad "SELF-TEST FAILED: canary not built — sed '${expr}' changed no line of ${FUNC}(), so the mutant IS the real function."
    return 2
  fi
  return 0
}

# Proves a canary was caught BY THE NAMED ASSERTION: rc exactly 1, every <want> message present,
# every <deny> message absent. Both lists are newline-separated fragments.
expect_canary() {  # <label> <detector-fn> <arg> <wants> <denies> → 0 proven, 2 not
  local label="$1" detector="$2" arg="$3" wants="$4" denies="$5" out rc=0 m
  out="$("$detector" "$arg" 2>&1)" || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: ${label}: ${detector} returned ${rc}; a caught canary returns exactly 1."
    return 2
  fi
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    if ! printf '%s\n' "$out" | grep -qF -- "$m"; then
      bad "SELF-TEST FAILED: ${label}: ${detector} failed, but never printed '${m}'."
      note "    It caught this canary on a DIFFERENT assertion, so the one that names this property is"
      note "    unproven — it could be deleted and --self-test would still report 1."
      return 2
    fi
  done <<< "$wants"
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    if printf '%s\n' "$out" | grep -qF -- "$m"; then
      bad "SELF-TEST FAILED: ${label}: ${detector} also printed '${m}', a property this canary does not break."
      note "    The mutant is broken more widely than the one mechanism it names, so it would certify"
      note "    that neighbouring assertion without ever testing it."
      return 2
    fi
  done <<< "$denies"
  return 0
}

self_test() {
  local tmp real_rc f
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$REPO_ROOT" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # ── [1] canary A — the 2026-07-31 defect: an installer records a restore key nobody reads.
  materialize_tree "$tmp/write-only" || return 2
  cat >> "$tmp/write-only/platform-portfolio/argocd-bootstrap/install.sh" <<'CANARY'

# CANARY: files a controller-memory prior into the state ConfigMap that no teardown ever reads.
oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge \
  -p "{\"data\":{\"argocd_controller_memory_prior\":\"${CUR_MEM}\"}}"
CANARY
  expect_canary "write-only restore key" check_key_symmetry "$tmp/write-only" \
    "state key 'argocd_controller_memory_prior' is WRITTEN by an installer but never read by" \
    'is READ by' || return 2

  # ── [1] canary B — the mirror-image defect, which had no canary at all before 2026-08-06: teardown
  # branches on a key no installer writes, so the restore it guards can never fire.
  materialize_tree "$tmp/read-only" || return 2
  cat >> "$tmp/read-only/${UNINSTALL}" <<'CANARY'

# CANARY: a restore branch keyed on a value no installer records — permanently dead code.
restore_orphan_canary() {
  local prior
  prior="$(state argocd_controller_orphan_prior)"
  [[ -n "$prior" ]] || return 0
  oc -n "$ARGO_NS" patch argocd openshift-gitops --type merge -p "$prior"
}
CANARY
  expect_canary "read-only restore key (dead branch)" check_key_symmetry "$tmp/read-only" \
    "state key 'argocd_controller_orphan_prior' is READ by" \
    'is WRITTEN by an installer' || return 2

  # ── [2a] the empty-prior defect: restoring "no explicit resources" by writing a number back
  # instead of removing the field.
  f="$tmp/c-writes-a-number-back.sh"
  build_canary_func "$f" 's|{"spec":{"controller":{"resources":null}}}|{"spec":{"controller":{"resources":{"limits":{"memory":"2Gi"}}}}}|' || return 2
  expect_canary "empty prior writes 2Gi back instead of removing the field" check_restore_behaviour "$f" \
    '[2a] empty prior must REMOVE .spec.controller.resources (merge-patch null), not write a value back.' \
    "$(printf '%s\n' '[2a] empty prior: expected exactly ONE patch' \
        '[2a] empty prior: expected a MERGE patch' '[2b] ' '[2c] ' '[2d] ' '[2e] ')" || return 2

  # ── [2a]/[2b] the ORIGINAL 2026-07-31 shape, once per branch: the restore path reports success
  # having written nothing at all (the defect as found printed a manual `oc edit` hint and moved on).
  # Both branches get their own canary because they are separate code paths — proving one says
  # nothing about the other, and each is the sole restore for its half of the contract.
  f="$tmp/c-empty-prior-never-patches.sh"
  # `$(oc patch` is TEXT in ogsr-uninstall.sh; single quotes keep sed matching that literal instead
  # of this script running a command substitution.
  # shellcheck disable=SC2016
  build_canary_func "$f" 's|^    out="\$(oc patch argocd|    out="$(: oc patch argocd|' || return 2
  expect_canary "empty prior: reports success without removing the field" check_restore_behaviour "$f" \
    '[2a] empty prior: expected exactly ONE patch, got: <none>' \
    "$(printf '%s\n' '[2b] ' '[2c] ' '[2d] ' '[2e] ')" || return 2

  f="$tmp/c-recorded-prior-never-patches.sh"
  # Same literal `$(oc patch`, at the two-column indent of the recorded-prior branch.
  # shellcheck disable=SC2016
  build_canary_func "$f" 's|^  out="\$(oc patch argocd|  out="$(: oc patch argocd|' || return 2
  expect_canary "recorded prior: reports success without patching it back" check_restore_behaviour "$f" \
    '[2b] recorded prior: expected exactly ONE patch, got: <none>' \
    "$(printf '%s\n' '[2a] ' '[2c] ' '[2d] ' '[2e] ')" || return 2

  # ── [2b] union is not restoration: a merge patch keeps every key the prior block did not set, so
  # requests.memory=2Gi survives a "restore" of a prior that only carried limits.memory.
  f="$tmp/c-merge-instead-of-json.sh"
  build_canary_func "$f" 's/--type json \\$/--type merge \\/' || return 2
  expect_canary "recorded prior replayed as a merge patch (unions instead of replacing)" check_restore_behaviour "$f" \
    '[2b] recorded prior: expected a JSON patch' \
    "$(printf '%s\n' '[2a] ' '[2c] ' '[2d] ' '[2e] ')" || return 2

  # ── [2a] a JSON patch cannot express "remove this field" the way a merge-patch null does, so the
  # removal branch silently stops removing anything.
  f="$tmp/c-removal-as-json-patch.sh"
  build_canary_func "$f" 's/--type merge \\$/--type json \\/' || return 2
  expect_canary "empty prior removed with a json patch instead of a merge-patch null" check_restore_behaviour "$f" \
    '[2a] empty prior: expected a MERGE patch' \
    "$(printf '%s\n' '[2a] empty prior: expected exactly ONE patch' \
        '[2a] empty prior must REMOVE' '[2b] ' '[2c] ' '[2d] ' '[2e] ')" || return 2

  # ── [2b] `replace` requires the path to already exist; `add` creates or replaces it. On a CR whose
  # controller block was removed in between, a replace-based restore fails and restores nothing.
  f="$tmp/c-op-replace.sh"
  build_canary_func "$f" 's/\\"op\\":\\"add\\"/\\"op\\":\\"replace\\"/g' || return 2
  expect_canary "recorded prior patched with op=replace instead of op=add" check_restore_behaviour "$f" \
    '[2b] recorded prior: expected op=add on /spec/controller/resources' \
    "$(printf '%s\n' '[2b] recorded prior: expected exactly ONE patch' \
        '[2b] recorded prior: expected a JSON patch' \
        '[2b] recorded prior: the recorded block was not patched back verbatim' \
        '[2a] ' '[2c] ' '[2d] ' '[2e] ')" || return 2

  # ── [2b] the right patch verb at the right path carrying the WRONG value: an empty object wipes
  # the org's sizing while every structural check above still passes.
  f="$tmp/c-value-not-verbatim.sh"
  # `${prior}` is the text ogsr-uninstall.sh interpolates into its patch body — matching it literally
  # is the point; expanding it here would match nothing.
  # shellcheck disable=SC2016
  build_canary_func "$f" 's|\\"value\\":${prior}}\]|\\"value\\":{}}]|g' || return 2
  expect_canary "recorded prior replaced by an empty object" check_restore_behaviour "$f" \
    '[2b] recorded prior: the recorded block was not patched back verbatim' \
    "$(printf '%s\n' '[2b] recorded prior: expected exactly ONE patch' \
        '[2b] recorded prior: expected a JSON patch' \
        '[2b] recorded prior: expected op=add' \
        '[2a] ' '[2c] ' '[2d] ' '[2e] ')" || return 2

  # ── [2c] the trace-leaving defect: patch an adopted CR without a consent record, i.e. without any
  # proof the workshop is the thing that changed it.
  f="$tmp/c-patches-without-consent.sh"
  # `$changed` is ogsr-uninstall.sh's local variable, matched as text.
  # shellcheck disable=SC2016
  build_canary_func "$f" 's/^  if \[\[ "\$changed" != "true" \]\]; then$/  if false; then # CANARY: consent no longer required/' || return 2
  expect_canary "patches an adopted CR with no consent recorded" check_restore_behaviour "$f" \
    '[2c] no consent recorded' \
    "$(printf '%s\n' '[2a] ' '[2b] ' '[2d] ' '[2e] ')" || return 2

  # ── [2d] the org may have removed the CR between install and teardown; patching it back is both an
  # error we would report as ours and a resurrection of an object its owner deleted.
  f="$tmp/c-patches-absent-cr.sh"
  # `$ARGO_NS` is text in the line being replaced, not a value to substitute.
  # shellcheck disable=SC2016
  build_canary_func "$f" 's|^  if ! oc get argocd openshift-gitops -n "\$ARGO_NS" >/dev/null 2>&1; then$|  if false; then # CANARY: absent CR no longer tolerated|' || return 2
  expect_canary "patches a CR the org already removed" check_restore_behaviour "$f" \
    '[2d] CR absent, yet a patch was issued' \
    "$(printf '%s\n' '[2a] ' '[2b] ' '[2c] ' '[2e] ')" || return 2

  # ── [2e] --dry-run must be readable by anyone deciding whether to run the real teardown.
  f="$tmp/c-dry-run-writes.sh"
  # `$DRY_RUN` is text in both of ogsr-uninstall.sh's dry-run guards; the sed is unanchored so it
  # disables both, which is what makes the two dry-run shapes in [2e] testable at once.
  # shellcheck disable=SC2016
  build_canary_func "$f" 's/if \[\[ "\$DRY_RUN" == "true" \]\]; then/if false; then # CANARY: dry-run now writes/' || return 2
  expect_canary "--dry-run writes to the cluster" check_restore_behaviour "$f" \
    '[2e] --dry-run issued a patch' \
    "$(printf '%s\n' '[2a] ' '[2b] ' '[2c] ' '[2d] ')" || return 2

  ok "self-test ok — real tree clean (rc=0); write-only and read-only key canaries caught, and every"
  note "   assertion of [2] proven by its own canary: no patch, wrong patch type, wrong op, wrong value,"
  note "   value written back instead of removed, no consent, absent CR, dry-run."
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
