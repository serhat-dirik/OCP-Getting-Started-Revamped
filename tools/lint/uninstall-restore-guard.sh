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
# it plants a write-only `argocd_controller_memory_prior` fixture for [1], and a mutated copy of
# the restore function whose empty-prior branch writes 2Gi back instead of removing the field for
# [2] — the precise defect shape in each case. Exit 1 = every canary was caught AND the real tree
# is clean under the same detectors; that is a PASS, matching the house convention where CI asserts
# the self-test step exits exactly 1. Exit 2 = a detector is blind, or the harness itself is broken.
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
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Two canaries, each the real defect shape. Both must be CAUGHT, and the real tree must be clean
# under the same detectors — anything else means the gate is decorative.
self_test() {
  local tmp canary_func real_rc bad_key_rc bad_func_rc
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

  # Canary A — the 2026-07-31 defect: an installer records a restore key nobody reads.
  mkdir -p "$tmp/bootstrap" "$tmp/platform-portfolio/argocd-bootstrap" "$tmp/helm/bootstrap/templates"
  cp "${REPO_ROOT}/${UNINSTALL}" "$tmp/${UNINSTALL}"
  cat > "$tmp/platform-portfolio/argocd-bootstrap/install.sh" <<'CANARY'
#!/usr/bin/env bash
# CANARY: writes a controller-memory restore key that no teardown reads.
oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge \
  -p "{\"data\":{\"argocd_controller_memory_prior\":\"${CUR_MEM}\"}}"
CANARY
  bad_key_rc=0
  check_key_symmetry "$tmp" >/dev/null 2>&1 || bad_key_rc=$?
  if [[ "$bad_key_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the write-only 'argocd_controller_memory_prior' canary was NOT detected (rc=${bad_key_rc}) — detector [1] is blind."
    return 2
  fi

  # Canary B — the empty-prior defect: restoring "no explicit resources" by writing a number back
  # instead of removing the field. Byte-for-byte the real function, with one branch broken.
  canary_func="$tmp/canary-func.sh"
  extract_func "${REPO_ROOT}/${UNINSTALL}" "$FUNC" \
    | sed 's|{"spec":{"controller":{"resources":null}}}|{"spec":{"controller":{"resources":{"limits":{"memory":"2Gi"}}}}}|' \
    > "$canary_func"
  if ! grep -q '"memory":"2Gi"' "$canary_func"; then
    bad "SELF-TEST FAILED: could not build the empty-prior canary — the merge-patch null it mutates was not found."
    return 2
  fi
  bad_func_rc=0
  check_restore_behaviour "$canary_func" >/dev/null 2>&1 || bad_func_rc=$?
  if [[ "$bad_func_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the write-a-number-back canary was NOT detected (rc=${bad_func_rc}) — detector [2] is blind."
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0), write-only-key canary caught, empty-prior canary caught."
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

run_check "$REPO_ROOT"
exit $?
