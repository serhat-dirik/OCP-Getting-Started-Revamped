#!/usr/bin/env bash
# uninstall-state-lifetime-guard.sh — the uninstall-state ConfigMap's LIFETIME contract, gated.
#
# ORIGIN (2026-07-31). bootstrap/ogsr-uninstall.sh deletes the ogsr-system namespace, which is where
# the ogsr-uninstall-state ConfigMap lives. That ConfigMap is the record of what the workshop changed
# and must put back. So the record of what to undo lived inside the thing being undone:
#
#   install #1 snapshots the org's Argo CD controller sizing (2Gi) → install raises it to 6Gi →
#   teardown declines to put it back (it cannot prove the change was ours) → teardown deletes
#   ogsr-system, and with it the 2Gi record → install #2 finds a fresh, empty state ConfigMap and
#   first-write-wins-records OUR 6Gi as "the org's original" → every future teardown either
#   "preserves" 6Gi as something the org always had, or, once the workshop's target moves, patches
#   the org's CR back to a number we invented and reports success.
#
# Measured on a live cluster the same day: recorded prior {"limits":{"memory":"2Gi"},…}, live CR at
# 6Gi, no consent key — one more cycle from becoming the recorded baseline permanently.
#
# THE INVARIANT: a value recorded as "the org's original" must never be a value we ourselves wrote.
# It is upheld by three mechanics, and this guard exists because all three are invisible to every
# other gate in the repo (valid shell, lint-clean, symptom visible only on a twice-installed cluster):
#
#   [1] RESIDUE ACCOUNTING. Every restore path that walks away leaving the workshop's value on an
#       object we do not own calls residue_record. A silent no-restore is the defect verbatim.
#   [2] CONDITIONAL STATE DELETION. ogsr-system is deleted only when the residue ledger is EMPTY.
#       With residue the ConfigMap is pruned to the unrestored prior values and the namespace is
#       kept as the receipt for a trace the cluster already carries.
#   [3] CARRIED KEYS ARE AUTHORITATIVE. Every install-side record_once refuses to write a key named
#       in the carried residue_keys — present (the org's value) or absent (the org had none). A
#       capture path that re-derives such a key from the live cluster re-creates the whole bug.
#
# Runnable standalone (CI lint gate) and by hand; needs nothing but bash + grep + awk + sed + base64.
#
# --self-test proves all four detectors FIRE before a clean run on the real tree means anything, with
# twelve canaries: restore branches with their residue_record removed (both objects, and both indents
# of the argo one, because those are separate branches), one that records residue it never earned, a
# dry-run that writes, a state-namespace delete that ignores the ledger plus one that never deletes, a
# carried ConfigMap missing the ledger key, a dry-run carry that writes, a record_once with the
# carried-key guard removed, one that overwrites, one that never writes, and a writer that ignores
# the carried ledger. Exit 1 = every canary was caught AND the real
# tree is clean under the same detectors; that is a PASS, matching the house convention where CI
# asserts the self-test step exits exactly 1. Exit 2 = a detector is blind, or the harness is broken.
#
# EVERY CANARY IS ASSERTED ON THE SPECIFIC MESSAGE for the property it breaks, and DENIES the
# messages it must not trip — never on the exit code alone (2026-08-06). Before that, three canaries
# each tripped SEVERAL assertions at once and no single assertion in [2] was load-bearing: the
# unconditional-delete canary fired both "the namespace was DELETED" and "no ConfigMap was written",
# so either could be deleted with --self-test still reporting 1, and the three remaining [2]
# assertions (a clean ledger DOES delete, the carried ConfigMap carries its keys, --dry-run writes
# nothing) had no canary at all. An assertion no canary can fail is an assertion CI is not running.
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
# [3] runs once per record_once writer (bootstrap/install.sh and the capture Job), so its expected
# multiplicity is declared: dropping EITHER call site must fail the coverage assertion, not half of it.
CHECK_COVERAGE_EXPECT="check_carried_keys=2"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }

UNINSTALL="bootstrap/ogsr-uninstall.sh"
INSTALL="bootstrap/install.sh"
CAPTURE_JOB="helm/bootstrap/templates/job-state-capture.yaml"
# Every file that writes a restore-source value into the uninstall-state ConfigMap. The portfolio's
# consent gate is here too: it is the one writer with no record_once to hang the rule on, so [4]
# checks it structurally instead.
WRITERS=(
  "bootstrap/install.sh"
  "platform-portfolio/argocd-bootstrap/install.sh"
  "helm/bootstrap/templates/job-state-capture.yaml"
)

# ── extraction ────────────────────────────────────────────────────────────────
# Functions are EXTRACTED, never sourced: ogsr-uninstall.sh runs a full teardown at top level and
# install.sh runs a full install. Extraction failure is exit 2, never a silent pass.
# extract_func / extract_func_indented (incl. the one-line-function fix, and the de-indent the
# capture Job's YAML block scalar needs — see _extract-func.sh) live there, sourced above; shared
# with the other guards under tools/lint/ rather than copy-pasted per guard.

# ── [1] residue accounting ────────────────────────────────────────────────────
# Runs one restore function under stubs and echoes two lines:
#   PATCHES=<n>   how many times it wrote to the cluster
#   RESIDUE=<comma-separated keys>  what it admitted it could not put back
# T_* inputs drive the branches; T_PATCH_RC forces a failing write.
run_restore() {  # <func_file> <fn> <env-assignments…> → "PATCHES=n" + "RESIDUE=…"
  local func_file="$1" fn="$2"; shift 2
  local harness plog rlog a
  harness="$(mktemp)"; plog="$(mktemp)"; rlog="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "SCRIPT_DIR='${REPO_ROOT}/bootstrap'"
    echo "ARGO_NS='openshift-gitops'"
    echo "PATCH_LOG='${plog}'"
    echo "RESIDUE_LOG='${rlog}'"
    # Defaults first, so a case only has to name what it varies.
    echo "DRY_RUN='false'; T_CHANGED=''; T_B64=''; T_CR_PRESENT='true'; T_LIVE_MEM=''"
    echo "T_PATCH_RC='0'; T_MON_EXISTED=''; T_MON_PRIOR=''"
    for a in "$@"; do echo "$a"; done
    cat <<'STUBS'
ok()   { echo "ok: $*"; }
err()  { echo "err: $*" >&2; }
del_obj() { printf 'del_obj %s\n' "$*" >> "$PATCH_LOG"; return 0; }
residue_record() { printf '%s\n' "$1" >> "$RESIDUE_LOG"; return 0; }
state() {
  case "$1" in
    argocd_controller_resources_changed_by_us) printf '%s' "$T_CHANGED" ;;
    gitops_argocd_controller_resources_b64)    printf '%s' "$T_B64" ;;
    monitoring_cm_existed)                     printf '%s' "$T_MON_EXISTED" ;;
    monitoring_uwm_prior)                      printf '%s' "$T_MON_PRIOR" ;;
    *) : ;;
  esac
  return 0
}
# `get` answers presence and the live-memory read; `patch`/`apply` are RECORDED, never executed —
# and can be made to FAIL, which is the branch that turns an intended restore into residue.
oc() {
  local verb="$1"
  case "$verb" in
    get)
      case " $* " in *" -o jsonpath="*) printf '%s' "$T_LIVE_MEM"; return 0 ;; esac
      case " $* " in *" -o yaml "*)     printf 'data:\n  config.yaml: |\n    enableUserWorkload: true\n'; return 0 ;; esac
      [[ "$T_CR_PRESENT" == "true" ]] && return 0
      return 1 ;;
    patch|apply)
      printf '%s\n' "$*" >> "$PATCH_LOG"
      return "$T_PATCH_RC" ;;
  esac
  return 0
}
# The legacy branch calls yq twice for two different things; answering only one collapses every
# legacy sub-branch into a single path and the guard reports a reason it never exercised.
yq() {
  case " $* " in
    *" -p=json "*) sed -n 's/.*"limits":{[^}]*"memory":"\([^"]*\)".*/\1/p'; return 0 ;;
  esac
  printf '6Gi'
  return 0
}
STUBS
    cat "$func_file"
    echo "$fn"
  } > "$harness"
  bash "$harness" >/dev/null 2>&1
  echo "PATCHES=$(grep -c . "$plog" 2>/dev/null || echo 0)"
  echo "RESIDUE=$(sort -u "$rlog" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  rm -f "$harness" "$plog" "$rlog"
  return 0
}

expect_restore() {  # <label> <want_patches|any> <want_residue> <func_file> <fn> <env…>
  local label="$1" want_p="$2" want_r="$3" func_file="$4" fn="$5"; shift 5
  local out got_p got_r
  out="$(run_restore "$func_file" "$fn" "$@")"
  got_p="$(printf '%s\n' "$out" | grep -m1 '^PATCHES=' | cut -d= -f2)"
  got_r="$(printf '%s\n' "$out" | grep -m1 '^RESIDUE=' | cut -d= -f2-)"
  if [[ "$want_p" != "any" && "$got_p" != "$want_p" ]]; then
    bad "[1] ${label}: expected ${want_p} cluster write(s), got ${got_p}"
    return 1
  fi
  if [[ "$got_r" != "$want_r" ]]; then
    bad "[1] ${label}: expected residue '${want_r:-<none>}', got '${got_r:-<none>}'"
    note "    A restore path that leaves the workshop's value on the org's object without recording"
    note "    residue lets step 9 delete the only record of what that object used to be."
    return 1
  fi
  return 0
}

ARGO_KEY="gitops_argocd_controller_resources_b64"
MON_KEY="monitoring_uwm_prior"

check_residue_accounting() {  # <argo_func_file> <mon_func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local af="$1" mf="$2" rc=0
  local prior_2g prior_6g garbage
  prior_2g="$(printf '%s' '{"limits":{"memory":"2Gi"}}' | base64 | tr -d '\n')"
  prior_6g="$(printf '%s' '{"limits":{"memory":"6Gi"}}' | base64 | tr -d '\n')"
  garbage="$(printf '%s' 'not-json' | base64 | tr -d '\n')"

  if [[ ! -s "$af" || ! -s "$mf" ]]; then
    bad "[1] could not extract the restore functions — the guard cannot inspect what it claims to."
    return 2
  fi

  # ── the adopted Argo CD controller sizing ───────────────────────────────────
  # THE measured case: no consent recorded, the live limit IS our target, the recorded prior is not.
  # A workshop install raised it, this run is not putting it back → that is residue.
  expect_restore "no consent, live at our target" 0 "$ARGO_KEY" "$af" restore_argocd_controller_resources \
    "T_CHANGED=''" "T_B64='${prior_2g}'" "T_LIVE_MEM='6Gi'" || rc=1
  # No consent and the live limit is NOT our target → no install ever raised it → no residue.
  expect_restore "no consent, live is the org's own" 0 "" "$af" restore_argocd_controller_resources \
    "T_CHANGED=''" "T_B64='${prior_2g}'" "T_LIVE_MEM='2Gi'" || rc=1
  # The org shipped at our target → we changed nothing → no residue.
  expect_restore "no consent, org already at target" 0 "" "$af" restore_argocd_controller_resources \
    "T_CHANGED=''" "T_B64='${prior_6g}'" "T_LIVE_MEM='6Gi'" || rc=1
  # Consent + a successful restore → the value is back, nothing to carry.
  expect_restore "consent, restore succeeds" 1 "" "$af" restore_argocd_controller_resources \
    "T_CHANGED='true'" "T_B64='${prior_2g}'" "T_LIVE_MEM='6Gi'" || rc=1
  # Consent + a FAILED restore → our value is still on the org's CR.
  expect_restore "consent, restore patch fails" any "$ARGO_KEY" "$af" restore_argocd_controller_resources \
    "T_CHANGED='true'" "T_B64='${prior_2g}'" "T_LIVE_MEM='6Gi'" "T_PATCH_RC='1'" || rc=1
  # Consent + empty prior + a successful removal → nothing to carry.
  expect_restore "consent, empty prior removed" 1 "" "$af" restore_argocd_controller_resources \
    "T_CHANGED='true'" "T_B64=''" "T_LIVE_MEM='6Gi'" || rc=1
  # Consent + empty prior + a FAILED removal → the CR still carries a resources block it never had.
  expect_restore "consent, empty-prior removal fails" any "$ARGO_KEY" "$af" restore_argocd_controller_resources \
    "T_CHANGED='true'" "T_B64=''" "T_LIVE_MEM='6Gi'" "T_PATCH_RC='1'" || rc=1
  # Consent + an unusable recorded prior → refused, and our sizing stays.
  expect_restore "consent, prior is not JSON" 0 "$ARGO_KEY" "$af" restore_argocd_controller_resources \
    "T_CHANGED='true'" "T_B64='${garbage}'" "T_LIVE_MEM='6Gi'" || rc=1
  # The CR is gone — nothing of ours is on this cluster, so nothing to carry.
  expect_restore "consent, CR absent" 0 "" "$af" restore_argocd_controller_resources \
    "T_CHANGED='true'" "T_B64='${prior_2g}'" "T_CR_PRESENT='false'" || rc=1
  # --dry-run changes nothing, so it creates no NEW residue either.
  expect_restore "dry-run, recorded prior" 0 "" "$af" restore_argocd_controller_resources \
    "T_CHANGED='true'" "T_B64='${prior_2g}'" "T_LIVE_MEM='6Gi'" "DRY_RUN='true'" || rc=1

  # ── cluster-monitoring-config ───────────────────────────────────────────────
  # The second instance of the same defect class: the ConfigMap pre-existed WITHOUT
  # enableUserWorkload, we added it, and this branch only prints a manual hint.
  expect_restore "monitoring: we added the key, cannot remove it" 0 "$MON_KEY" "$mf" restore_monitoring \
    "T_MON_EXISTED='true'" "T_MON_PRIOR='absent'" || rc=1
  expect_restore "monitoring: prior false, restored" any "" "$mf" restore_monitoring \
    "T_MON_EXISTED='true'" "T_MON_PRIOR='false'" || rc=1
  expect_restore "monitoring: prior true, preserved" 0 "" "$mf" restore_monitoring \
    "T_MON_EXISTED='true'" "T_MON_PRIOR='true'" || rc=1
  expect_restore "monitoring: CM was ours, deleted" any "" "$mf" restore_monitoring \
    "T_MON_EXISTED='false'" "T_MON_PRIOR='absent'" || rc=1

  if [[ "$rc" -eq 0 ]]; then
    ok "[1] residue accounting: every no-restore path that leaves our value behind records residue,"
    note "    and every path that genuinely restored (or never changed anything) records none"
  fi
  return "$rc"
}

# ── [2] conditional state deletion ────────────────────────────────────────────
# Runs carry_residue_or_delete_state_ns under stubs and echoes what it did to the cluster.
run_carry() {  # <func_file> <residue-keys-newline-sep> <dry> → action log
  local func_file="$1" keys="$2" dry="$3" harness log
  harness="$(mktemp)"; log="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "STATE_NS='ogsr-system'; STATE_CM='ogsr-uninstall-state'"
    echo "OWNER_LABEL='workshop.redhat.com/owner=ogsr'"
    echo "DRY_RUN='${dry}'"
    echo "ACTION_LOG='${log}'"
    printf "RESIDUE_KEYS='%s'\n" "$keys"
    echo "RESIDUE_NOTES='some/thing: put it back by hand"
    echo "'"
    echo 'DELETED_WS_NS=()'
    cat <<'STUBS'
ok()   { echo "ok: $*"; }
err()  { echo "err: $*" >&2; }
sub()  { "$@" || true; }
del_obj() { printf 'DELETE-NS %s\n' "$2" >> "$ACTION_LOG"; return 0; }
state() { printf 'recorded-value-of-%s' "$1"; return 0; }
date() { printf '2026-07-31T00:00:00Z'; return 0; }
oc() {
  case "$1" in
    create) printf 'CREATE-CM %s\n' "$*" >> "$ACTION_LOG" ;;
    delete) printf 'DELETE-CM %s\n' "$*" >> "$ACTION_LOG" ;;
    label)  printf 'LABEL-CM\n' >> "$ACTION_LOG" ;;
  esac
  return 0
}
STUBS
    cat "$func_file"
    echo 'carry_residue_or_delete_state_ns'
  } > "$harness"
  bash "$harness" >/dev/null 2>&1
  cat "$log"
  rm -f "$harness" "$log"
  return 0
}

check_state_deletion() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[2] could not extract carry_residue_or_delete_state_ns() — the guard cannot inspect what it claims to."
    return 2
  fi

  # Clean teardown: nothing to confess → the state namespace goes, as it always has.
  out="$(run_carry "$func_file" "" false)"
  if ! printf '%s' "$out" | grep -q '^DELETE-NS ogsr-system'; then
    bad "[2] empty residue ledger: the state namespace was NOT deleted. A clean teardown must leave no trace."
    note "    got: ${out:-<nothing>}"
    rc=1
  fi

  # Residue: the namespace must SURVIVE, and the ConfigMap must be rewritten to carry the keys.
  out="$(run_carry "$func_file" $'gitops_argocd_controller_resources_b64\nmonitoring_uwm_prior\n' false)"
  if printf '%s' "$out" | grep -q '^DELETE-NS ogsr-system'; then
    bad "[2] residue recorded, yet the state namespace was DELETED — this is the 2026-07-31 defect verbatim:"
    note "    the only record of the org's prior values goes with it, and the next install snapshots"
    note "    the workshop's own leftovers as the baseline."
    rc=1
  fi
  if ! printf '%s' "$out" | grep -q '^CREATE-CM'; then
    bad "[2] residue recorded, but no ConfigMap was written — the prior values are recorded nowhere."
    note "    got: ${out:-<nothing>}"
    rc=1
  else
    local k
    for k in gitops_argocd_controller_resources_b64 monitoring_uwm_prior residue_keys residue_notes; do
      if ! printf '%s' "$out" | grep -q "from-literal=${k}="; then
        bad "[2] the carried ConfigMap does not contain '${k}'."
        note "    got: ${out}"
        rc=1
      fi
    done
  fi

  # --dry-run must change nothing at all, in both shapes.
  out="$(run_carry "$func_file" $'gitops_argocd_controller_resources_b64\n' true)$(run_carry "$func_file" "" true)"
  if printf '%s' "$out" | grep -q '^CREATE-CM\|^DELETE-CM'; then
    bad "[2] --dry-run wrote to the cluster: ${out}"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[2] state deletion is conditional: empty ledger removes the namespace, residue keeps it and"
    note "    prunes the ConfigMap to the unrestored prior values; dry-run writes nothing"
  fi
  return "$rc"
}

# ── [3] carried keys are authoritative on capture ─────────────────────────────
run_record_once() {  # <func_file> <carried> <key> <existing-value> → "PATCH" or ""
  local func_file="$1" carried="$2" key="$3" existing="$4" harness log
  harness="$(mktemp)"; log="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "STATE_NS='ogsr-system'; STATE_CM='ogsr-uninstall-state'; CM='ogsr-uninstall-state'"
    printf "RESIDUE_KEYS_CARRIED='%s'\n" "$carried"
    printf "T_EXISTING='%s'\n" "$existing"
    echo "PATCH_LOG='${log}'"
    cat <<'STUBS'
oc() {
  case "$1" in
    get)   printf '%s' "$T_EXISTING" ;;
    patch) printf 'PATCH %s\n' "$*" >> "$PATCH_LOG" ;;
  esac
  return 0
}
STUBS
    cat "$func_file"
    printf "record_once '%s' 'VALUE-WE-JUST-READ-OFF-THE-CLUSTER'\n" "$key"
  } > "$harness"
  bash "$harness" >/dev/null 2>&1
  cat "$log"
  rm -f "$harness" "$log"
  return 0
}

check_carried_keys() {  # <label> <func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local label="$1" func_file="$2" out rc=0
  local key="gitops_argocd_controller_resources_b64"
  if [[ ! -s "$func_file" ]]; then
    bad "[3] ${label}: could not extract record_once() — the guard cannot inspect what it claims to."
    return 2
  fi

  # Carried AND absent from the ConfigMap. Absence is the org's answer too (for the Argo key it
  # encodes "the CR carried no explicit resources"), so filling it in is the corruption.
  out="$(run_record_once "$func_file" " ${key} " "$key" "")"
  if [[ -n "$out" ]]; then
    bad "[3] ${label}: record_once WROTE a carried key that the teardown deliberately left unset."
    note "    A carried key is authoritative present or absent — re-deriving it from the live cluster"
    note "    records the workshop's own leftover as the org's original."
    note "    got: ${out}"
    rc=1
  fi

  # Carried and present → untouched (first-write-wins already covers it; assert it anyway).
  out="$(run_record_once "$func_file" " ${key} " "$key" "the-orgs-real-prior")"
  if [[ -n "$out" ]]; then
    bad "[3] ${label}: record_once overwrote a carried key that already had the org's value: ${out}"
    rc=1
  fi

  # NOT carried and unset → this is an ordinary first capture and must still be recorded, or the
  # guard would be satisfied by a record_once that writes nothing at all.
  out="$(run_record_once "$func_file" "" "$key" "")"
  if [[ -z "$out" ]]; then
    bad "[3] ${label}: record_once wrote NOTHING on an ordinary first capture — the snapshot is dead."
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[3] ${label}: carried residue keys are never re-derived (present or absent), ordinary keys still record"
  fi
  return "$rc"
}

# ── [4] every writer consults the carried ledger ──────────────────────────────
# [3] proves the rule inside record_once, but the portfolio's consent gate writes the prior with a
# raw `oc patch` and has no record_once to hang it on — and that is the writer that fires on exactly
# the cluster shape this whole mechanism exists for (an ADOPTED Argo CD). Structural, deliberately:
# a file that files a restore-source value into the state ConfigMap without ever reading residue_keys
# cannot be honouring the carried record, whatever its internals look like.
RESTORE_SOURCE_KEY="gitops_argocd_controller_resources_b64"

check_writers_read_residue() {  # <root> → 0 clean, 1 broken, 2 nothing to inspect
  ran_check
  local root="$1" f rc=0 n=0
  for f in "${WRITERS[@]}"; do
    [[ -f "${root}/${f}" ]] || continue
    grep -q "$RESTORE_SOURCE_KEY" "${root}/${f}" || continue
    n=$((n + 1))
    if ! grep -q 'data\.residue_keys' "${root}/${f}"; then
      bad "[4] ${f} writes ${RESTORE_SOURCE_KEY} but never reads .data.residue_keys."
      note "    A writer that ignores the carried ledger re-derives the prior from a cluster that"
      note "    still carries OUR value — the 2026-07-31 state-lifetime defect, one writer at a time."
      rc=1
    fi
  done
  if [[ "$n" -eq 0 ]]; then
    bad "[4] no writer of ${RESTORE_SOURCE_KEY} found at all in ${root} — the detector is looking at the wrong files."
    return 2
  fi
  if [[ "$rc" -eq 0 ]]; then
    ok "[4] all ${n} writer(s) of ${RESTORE_SOURCE_KEY} consult the carried residue ledger first"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # <root> → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
  local root="$1" rc=0 sub=0 f
  local argo_f mon_f carry_f ro_install_f ro_job_f
  for f in "$UNINSTALL" "$INSTALL" "$CAPTURE_JOB"; do
    if [[ ! -f "${root}/${f}" ]]; then bad "${root}/${f} not found"; return 2; fi
  done

  argo_f="$(mktemp)"; mon_f="$(mktemp)"; carry_f="$(mktemp)"
  ro_install_f="$(mktemp)"; ro_job_f="$(mktemp)"
  extract_func "${root}/${UNINSTALL}" restore_argocd_controller_resources > "$argo_f"
  extract_func "${root}/${UNINSTALL}" restore_monitoring                  > "$mon_f"
  extract_func "${root}/${UNINSTALL}" carry_residue_or_delete_state_ns    > "$carry_f"
  extract_func "${root}/${INSTALL}"   record_once                         > "$ro_install_f"
  extract_func_indented "${root}/${CAPTURE_JOB}" record_once              > "$ro_job_f"

  sub=0; check_residue_accounting "$argo_f" "$mon_f" || sub=$?
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi

  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_state_deletion "$carry_f" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi
  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_carried_keys "bootstrap/install.sh" "$ro_install_f" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi
  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_carried_keys "helm/bootstrap state-capture Job" "$ro_job_f" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi
  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_writers_read_residue "$root" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi

  rm -f "$argo_f" "$mon_f" "$carry_f" "$ro_install_f" "$ro_job_f"
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Eleven canaries, each the real defect shape for one declared property. All must be CAUGHT — by the
# assertion that NAMES that property, proven from the message — and the real tree must be clean under
# the same detectors. Anything else means the gate is decorative.

# Materializes <pristine> with one sed applied, and proves the sed actually changed something: a sed
# that silently matches nothing yields the REAL function, which passes, which reads as "blind
# detector" and sends the next reader hunting in the wrong file.
#
# Every input here is a REAL file, never <(extract_func …). check_residue_accounting guards its
# inputs with `[[ ! -s "$mf" ]]`, and `-s` on a process-substitution pipe is platform-dependent:
# BSD/macOS reports the bytes currently buffered in the pipe as st_size, so the test passes, while
# Linux reports 0, so it fails. That is why this self-test once returned 1 locally and 2 on CI
# ubuntu — the guard decided it "could not extract the restore functions" and declared its own
# detector blind. A guard whose result depends on the OS is not a guard.
build_mutant() {  # <out-file> <pristine-file> <sed-expr> → 0 built, 2 the mutation never applied
  local out="$1" pristine="$2" expr="$3"
  if [[ ! -s "$pristine" ]]; then
    bad "SELF-TEST FAILED: canary not built — ${pristine##*/} is empty, so extraction failed before any mutation ran."
    return 2
  fi
  sed "$expr" "$pristine" > "$out"
  if cmp -s "$pristine" "$out"; then
    bad "SELF-TEST FAILED: canary not built — sed '${expr}' changed no line of ${pristine##*/}, so the mutant IS the real function."
    return 2
  fi
  return 0
}

# Proves a canary was caught BY THE NAMED ASSERTION: rc exactly 1, every <want> message present,
# every <deny> message absent. Both lists are newline-separated fragments.
expect_canary() {  # <label> <wants> <denies> <detector> [args…] → 0 proven, 2 not
  local label="$1" wants="$2" denies="$3"; shift 3
  local out rc=0 m
  out="$("$@" 2>&1)" || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: ${label}: ${1} returned ${rc}; a caught canary returns exactly 1."
    return 2
  fi
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    if ! printf '%s\n' "$out" | grep -qF -- "$m"; then
      bad "SELF-TEST FAILED: ${label}: ${1} failed, but never printed '${m}'."
      note "    It caught this canary on a DIFFERENT assertion, so the one that names this property is"
      note "    unproven — it could be deleted and --self-test would still report 1."
      return 2
    fi
  done <<< "$wants"
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    if printf '%s\n' "$out" | grep -qF -- "$m"; then
      bad "SELF-TEST FAILED: ${label}: ${1} also printed '${m}', a property this canary does not break."
      note "    The mutant is broken more widely than the one mechanism it names, so it would certify"
      note "    that neighbouring assertion without ever testing it."
      return 2
    fi
  done <<< "$denies"
  return 0
}

self_test() {
  local tmp real_rc f g
  local p_argo p_mon p_carry p_ro
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

  # The unmutated originals every canary is built from, and the healthy partner each detector needs.
  p_argo="$tmp/p-argo.sh"; p_mon="$tmp/p-mon.sh"; p_carry="$tmp/p-carry.sh"; p_ro="$tmp/p-record-once.sh"
  extract_func "${REPO_ROOT}/${UNINSTALL}" restore_argocd_controller_resources > "$p_argo"
  extract_func "${REPO_ROOT}/${UNINSTALL}" restore_monitoring                  > "$p_mon"
  extract_func "${REPO_ROOT}/${UNINSTALL}" carry_residue_or_delete_state_ns    > "$p_carry"
  extract_func "${REPO_ROOT}/${INSTALL}"   record_once                         > "$p_ro"

  # ── [1] canary A — a restore path that declines to restore and says nothing about it. Three of the
  # four argo residue_record calls sit at six-column indent; the fourth (the failed json-patch path)
  # does not, and the deny below proves this sed left it alone rather than blanking the function.
  f="$tmp/c-argo-silent.sh"
  build_mutant "$f" "$p_argo" 's/^      residue_record gitops_argocd_controller_resources_b64 \\$/      : \\/' || return 2
  expect_canary "restore declines silently (no residue recorded)" \
    "$(printf '%s\n' \
        "[1] no consent, live at our target: expected residue '${ARGO_KEY}', got '<none>'" \
        "[1] consent, empty-prior removal fails: expected residue '${ARGO_KEY}', got '<none>'" \
        "[1] consent, prior is not JSON: expected residue '${ARGO_KEY}', got '<none>'")" \
    "$(printf '%s\n' '[1] consent, restore patch fails' 'cluster write(s), got' '[1] monitoring')" \
    check_residue_accounting "$f" "$p_mon" || return 2

  # ── [1] canary A2 — the FOURTH residue_record, the one the sed above deliberately leaves alone
  # because it sits at four columns rather than six: the failed json-patch path. Same defect, its own
  # branch, and nothing about canary A says this branch is watched.
  f="$tmp/c-argo-silent-failed-patch.sh"
  build_mutant "$f" "$p_argo" 's/^    residue_record gitops_argocd_controller_resources_b64 \\$/    : \\/' || return 2
  expect_canary "failed restore patch leaves our sizing on the CR unrecorded" \
    "[1] consent, restore patch fails: expected residue '${ARGO_KEY}', got '<none>'" \
    "$(printf '%s\n' '[1] no consent, live at our target' '[1] consent, empty-prior removal fails' \
        '[1] consent, prior is not JSON' 'cluster write(s), got' '[1] monitoring')" \
    check_residue_accounting "$f" "$p_mon" || return 2

  # ── [1] canary B — the OPPOSITE error, which had no canary before 2026-08-06: residue recorded for
  # a change no install ever made. Over-recording is not harmless — it keeps ogsr-system forever, so
  # a teardown that genuinely left no trace still reports one and never removes its own namespace.
  f="$tmp/c-argo-over-records.sh"
  # `$live_mem` / `$target_mem` are ogsr-uninstall.sh's locals, matched as TEXT — double quotes here
  # would expand to empty strings and the sed would match nothing.
  # shellcheck disable=SC2016
  build_mutant "$f" "$p_argo" 's/^    elif \[\[ "\$live_mem" != "\$target_mem" \]\]; then$/    elif false; then # CANARY: never recognises the org'"'"'s own value/' || return 2
  expect_canary "residue recorded for a value the org set itself" \
    "[1] no consent, live is the org's own: expected residue '<none>', got '${ARGO_KEY}'" \
    "$(printf '%s\n' '[1] no consent, live at our target' '[1] no consent, org already at target' \
        'cluster write(s), got' '[1] monitoring')" \
    check_residue_accounting "$f" "$p_mon" || return 2

  # ── [1] canary C — --dry-run writes to the org's CR. This is the one canary that proves
  # expect_restore's CLUSTER-WRITE assertion rather than its residue assertion; without it the write
  # count could be dropped entirely and every other canary here would still pass.
  f="$tmp/c-argo-dry-run-writes.sh"
  # `$DRY_RUN` is text in the guard being disabled; unanchored on purpose so both of the function's
  # dry-run early-returns go, which is what lets the recorded-prior dry-run case reach a patch.
  # shellcheck disable=SC2016
  build_mutant "$f" "$p_argo" 's/if \[\[ "\$DRY_RUN" == "true" \]\]; then/if false; then # CANARY: dry-run now writes/' || return 2
  expect_canary "--dry-run patches the adopted CR" \
    '[1] dry-run, recorded prior: expected 0 cluster write(s), got 1' \
    "$(printf '%s\n' 'expected residue' '[1] monitoring')" \
    check_residue_accounting "$f" "$p_mon" || return 2

  # ── [1] canary D — the SECOND object under the same contract. restore_monitoring is a separate
  # function on a separate ConfigMap, so nothing about the argo canaries above says its residue path
  # is checked; before this it had no canary of its own.
  g="$tmp/c-mon-silent.sh"
  build_mutant "$g" "$p_mon" 's/^      residue_record monitoring_uwm_prior \\$/      : \\/' || return 2
  expect_canary "monitoring key we added is left behind unrecorded" \
    "[1] monitoring: we added the key, cannot remove it: expected residue '${MON_KEY}', got '<none>'" \
    "$(printf '%s\n' 'cluster write(s), got' '[1] no consent' '[1] consent')" \
    check_residue_accounting "$p_argo" "$g" || return 2

  # ── [2] canary A — the original bug: delete the state namespace whatever the ledger says.
  f="$tmp/c-carry-always-deletes.sh"
  # $RESIDUE_KEYS is part of the PATTERN being matched in the extracted source, not a variable to
  # expand here — the single quotes are intentional.
  # shellcheck disable=SC2016
  build_mutant "$f" "$p_carry" 's/^  if \[\[ -z "\$RESIDUE_KEYS" \]\]; then$/  if true; then/' || return 2
  expect_canary "state namespace deleted despite recorded residue" \
    "$(printf '%s\n' '[2] residue recorded, yet the state namespace was DELETED' \
        '[2] residue recorded, but no ConfigMap was written')" \
    "$(printf '%s\n' '[2] empty residue ledger' '[2] the carried ConfigMap does not contain' \
        '[2] --dry-run wrote to the cluster')" \
    check_state_deletion "$f" || return 2

  # ── [2] canary B — the mirror image, previously untested: a CLEAN teardown that keeps ogsr-system.
  # "Leave no trace" fails in both directions, and a namespace nobody expected is what an org sees.
  f="$tmp/c-carry-never-deletes.sh"
  # `$STATE_NS` is text in the del_obj call being removed, not a variable of this script.
  # shellcheck disable=SC2016
  build_mutant "$f" "$p_carry" 's/^    sub del_obj namespace "\$STATE_NS"$/    : # CANARY: a clean teardown no longer removes its own namespace/' || return 2
  expect_canary "clean ledger leaves the state namespace behind" \
    '[2] empty residue ledger: the state namespace was NOT deleted' \
    "$(printf '%s\n' '[2] residue recorded, yet the state namespace was DELETED' \
        '[2] residue recorded, but no ConfigMap was written' \
        '[2] the carried ConfigMap does not contain' '[2] --dry-run wrote to the cluster')" \
    check_state_deletion "$f" || return 2

  # ── [2] canary C — the carried ConfigMap written WITHOUT residue_keys. Everything looks right (the
  # namespace survives, the ConfigMap exists, the prior values are in it) and detector [4]'s whole
  # mechanism is dead: every writer consults .data.residue_keys, and there is now nothing to consult.
  f="$tmp/c-carry-drops-ledger-key.sh"
  build_mutant "$f" "$p_carry" 's|^  args+=("--from-literal=residue_keys=|  #CANARY args+=("--from-literal=residue_keys=|' || return 2
  expect_canary "carried ConfigMap omits the residue_keys ledger" \
    "[2] the carried ConfigMap does not contain 'residue_keys'." \
    "$(printf '%s\n' '[2] empty residue ledger' '[2] residue recorded, yet the state namespace was DELETED' \
        '[2] residue recorded, but no ConfigMap was written' '[2] --dry-run wrote to the cluster')" \
    check_state_deletion "$f" || return 2

  # ── [2] canary D — --dry-run rewrites the state ConfigMap. Previously untested, and the reason
  # anyone trusts `ogsr-uninstall.sh --dry-run` on a cluster they do not own.
  f="$tmp/c-carry-dry-run-writes.sh"
  # `$DRY_RUN` is text in carry_residue_or_delete_state_ns's own guard; anchored to two columns so it
  # hits only that function's copy.
  # shellcheck disable=SC2016
  build_mutant "$f" "$p_carry" 's/^  if \[\[ "\$DRY_RUN" == "true" \]\]; then$/  if false; then # CANARY: dry-run now writes/' || return 2
  expect_canary "--dry-run rewrites the state ConfigMap" \
    '[2] --dry-run wrote to the cluster' \
    "$(printf '%s\n' '[2] empty residue ledger' '[2] residue recorded, yet the state namespace was DELETED' \
        '[2] residue recorded, but no ConfigMap was written' '[2] the carried ConfigMap does not contain')" \
    check_state_deletion "$f" || return 2

  # ── [3] canary A — a capture that re-derives a carried key from the live cluster.
  f="$tmp/c-record-once-rederives.sh"
  # $k is part of the PATTERN being matched in the extracted source, not a variable to expand here.
  # shellcheck disable=SC2016
  build_mutant "$f" "$p_ro" 's/^    \*" \$k "\*)$/    NEVER-MATCHES)/' || return 2
  expect_canary "carried key re-derived from the live cluster" \
    '[3] re-derive: record_once WROTE a carried key that the teardown deliberately left unset.' \
    "$(printf '%s\n' 'record_once overwrote a carried key' 'record_once wrote NOTHING')" \
    check_carried_keys "re-derive" "$f" || return 2

  # ── [3] canary B — BOTH skip conditions gone. The overwrite assertion is unreachable while
  # first-write-wins stands (a carried key that already holds the org's value is skipped twice over),
  # so the only honest canary for it breaks both — which is exactly what a refactor of this
  # five-line function would do.
  # Each step writes a NEW file: `sed expr f > f` truncates f before sed opens it, and the mutant
  # would come out empty — which build_mutant reports as "the sed matched nothing".
  g="$tmp/c-record-once-overwrites-step1.sh"
  f="$tmp/c-record-once-overwrites.sh"
  # shellcheck disable=SC2016
  build_mutant "$g" "$p_ro" 's/^    \*" \$k "\*)$/    NEVER-MATCHES)/' || return 2
  # shellcheck disable=SC2016
  build_mutant "$f" "$g" 's/^  \[\[ -n "\$cur" \]\] && return 0$/  : # CANARY: first-write-wins gone/' || return 2
  expect_canary "carried key with the org's value overwritten" \
    "$(printf '%s\n' "[3] overwrite: record_once overwrote a carried key that already had the org's value" \
        '[3] overwrite: record_once WROTE a carried key that the teardown deliberately left unset.')" \
    'record_once wrote NOTHING' \
    check_carried_keys "overwrite" "$f" || return 2

  # ── [3] canary C — record_once that never records. Without this the detector would be satisfied by
  # a capture that writes nothing at all, and "never re-derives a carried key" is trivially true of a
  # function that never writes.
  f="$tmp/c-record-once-never-writes.sh"
  # `$STATE_CM` is text in record_once's patch line. The replacement deliberately keeps it spelled the
  # same, so the only difference is the leading `:` that turns the write into a no-op.
  # shellcheck disable=SC2016
  build_mutant "$f" "$p_ro" 's/^  oc patch configmap "\$STATE_CM"/  : oc patch configmap "$STATE_CM"/' || return 2
  expect_canary "ordinary first capture records nothing" \
    '[3] dead-snapshot: record_once wrote NOTHING on an ordinary first capture — the snapshot is dead.' \
    "$(printf '%s\n' 'record_once WROTE a carried key' 'record_once overwrote a carried key')" \
    check_carried_keys "dead-snapshot" "$f" || return 2

  # ── [4] canary — the portfolio consent gate with its carried-ledger read stripped out: it would
  # file the live (already-ours) sizing as the org's original the moment the workshop's target moves.
  mkdir -p "$tmp/writers"
  for f in "${WRITERS[@]}"; do
    mkdir -p "$tmp/writers/$(dirname "$f")"
    grep -v 'data\.residue_keys' "${REPO_ROOT}/${f}" > "$tmp/writers/${f}"
  done
  if grep -rq 'data\.residue_keys' "$tmp/writers"; then
    bad "SELF-TEST FAILED: could not build the ignores-carried-ledger canary — every writer still contains a .data.residue_keys read after stripping it."
    return 2
  fi
  expect_canary "writer ignores the carried residue ledger" \
    "writes ${RESTORE_SOURCE_KEY} but never reads .data.residue_keys" \
    'no writer of' \
    check_writers_read_residue "$tmp/writers" || return 2

  ok "self-test ok — real tree clean (rc=0); twelve canaries, each caught by the assertion that names"
  note "   its property: residue under- and over-recorded, dry-run writes on both objects, the state"
  note "   namespace deleted and not deleted, a ledger-less carried ConfigMap, record_once re-deriving,"
  note "   overwriting and never writing, and a writer ignoring the carried ledger."
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
