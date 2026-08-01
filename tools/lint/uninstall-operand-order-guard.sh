#!/usr/bin/env bash
# uninstall-operand-order-guard.sh — the uninstall's two ORDERING contracts, gated.
#
# ORIGIN (2026-07-31, one teardown, two defects, both of which reported success).
#
# [A] THE CHECKER LOOKED TOO LATE. ogsr-uninstall.sh records `crds_created` — the CRDs that exist on
#     this cluster because WE installed an operator — by reading each CSV's own
#     .spec.customresourcedefinitions.owned. The only call site was inside the CSV-cleanup step, which
#     runs AFTER the cascade. The cascade had already taken 15 of the 19 CSVs, so the capture recorded
#     17 CRDs while 165 were still registered. ogsr-check-clean.sh section [9/9] then reported those 17
#     as the complete list, in its highest-confidence "exact" mode, and the run ended "clean". The
#     number was not small; it was meaningless, and it was dressed as certainty.
#
# [B] OPENSHIFT PIPELINES WAS LEFT ORPHANED AND RUNNING. After the uninstall the Pipelines CSV and
#     Subscription were gone while TektonConfig was still alive with 18 pods and a bound 1Gi PVC. The
#     Pipelines operator creates TektonConfig for ITSELF, so it carries no Argo tracking-id, so no
#     Application owns it and no cascade can ever prune it. Nothing managed it; nothing ever would.
#     Every pod read 1/1, which is exactly why nobody noticed.
#
# THE TWO INVARIANTS, and why neither is visible to any other gate in this repo (both halves are valid,
# lint-clean shell, and the only symptom is a cluster nobody re-inspects after a "successful" teardown):
#
#   [1] CAPTURE BEFORE DESTRUCTION. The owned-CRD capture runs in the pre-cascade snapshot, gated by
#       the same state predicate that authorises a CSV deletion, so an ADOPTED operator's CRDs are
#       never filed as ours.
#   [2] ORDER IN main. The operand step runs AFTER reconciliation is stopped (or an app-of-apps
#       re-creates what it removes) and BEFORE the cascade (or the operator that must process the
#       operand's finalizer is already gone).
#   [3] THE OPERAND STEP'S OWN SCOPE. Cluster-scoped operands of operators WE created, never anything
#       Argo tracks (the cascade orders those better), never anything marked adopted; two passes, so a
#       child operand an operator re-creates from a not-yet-deleted parent is still caught.
#   [4] NO EXACT MODE WITHOUT PROOF. ogsr-check-clean.sh calls its CRD list "exact" only when the state
#       carries crds_created_capture=pre-cascade. Anything else is reported as unverifiable — which
#       makes the verdict "needs a human decision" instead of "clean".
#
# Runnable standalone (CI lint gate) and by hand; needs nothing but bash + grep + awk + sed.
#
# --self-test proves all four detectors FIRE before a clean run on the real tree means anything. Every
# canary is the real defect shape, built by mutating the real function: the capture call removed, the
# operand step moved after the cascade, the Argo-tracked guard removed, the scope flipped to
# Namespaced, the second pass removed, and the capture-phase proof removed. Exit 1 = every canary was
# caught AND the real tree is clean under the same detectors; that is a PASS, matching the house
# convention where CI asserts the self-test step exits exactly 1.
# Exit 2 = a detector is blind, or the harness itself is broken.
#
# NOTE ON THE HARNESS, twice learned the hard way in this repo:
#   • a stub `oc` runs inside `$( )`, i.e. in a SUBSHELL, so anything it records in a shell VARIABLE is
#     discarded the moment the substitution ends. Every stub here records to a FILE.
#   • `[[ -s file ]]` on a PROCESS SUBSTITUTION is platform-dependent (macOS reports the bytes buffered
#     in the pipe as st_size, Linux reports 0), so every extraction is materialised to a real file
#     before it is size-checked.
#
# Exit codes:
#   0  both orderings hold
#   1  broken — or, under --self-test, every canary was correctly detected
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
CHECKCLEAN="bootstrap/ogsr-check-clean.sh"

# ── extraction ────────────────────────────────────────────────────────────────
# Functions are EXTRACTED, never sourced: ogsr-uninstall.sh runs a full teardown at top level.
# Extraction failure is exit 2, never a silent pass. extract_func (incl. its one-line-function fix —
# ogsr-check-clean.sh's state_get() is written on a single line) lives in _extract-func.sh, sourced
# above; it is shared with the other guards under tools/lint/ rather than copy-pasted per guard.
extract_many() {  # <file> <out> <name…> — concatenate several functions into one sourceable file
  local file="$1" out="$2" fn
  shift 2
  : > "$out"
  for fn in "$@"; do
    extract_func "$file" "$fn" >> "$out"
    printf '\n' >> "$out"
  done
  return 0
}

CAPTURE_FUNCS=(capture_installed_csvs record_created_crds crd_owned_index csv_delete_authorized_by_state)
OPERAND_FUNCS=(step_delete_operator_operands cluster_scoped_created_crds)
SECTION_FUNCS=(section_crds found state_get state_ops)

# The capture's module-level globals are LIFTED FROM THE REAL FILE, never re-typed here: they carry the
# initial values the whole de-dup idiom depends on (a space-padded " ", not ""), and `set -u` makes a
# missing one fatal inside the harness rather than visibly wrong. The count is asserted so a rename
# fails the guard loudly instead of quietly testing a shape the script does not have.
CAPTURE_GLOBALS_RE='^(CRDS_CREATED_SET|CRDS_CAPTURED_CSVS|CRDS_CAPTURE_PHASE|CRD_OWNED_INDEX|CRD_OWNED_INDEX_LOADED)='
CAPTURE_GLOBALS_N=5

build_capture_file() {  # <uninstall-file> <out> → 0 ok, 2 could not build
  local src="$1" out="$2" n fns
  : > "$out"
  grep -E "$CAPTURE_GLOBALS_RE" "$src" >> "$out"
  n="$(grep -cE "$CAPTURE_GLOBALS_RE" "$out")"
  if [[ "$n" -ne "$CAPTURE_GLOBALS_N" ]]; then
    bad "expected ${CAPTURE_GLOBALS_N} capture globals in ${src}, found ${n}."
    note "    The harness would run against a shape the real script does not have. Refusing to report a pass."
    return 2
  fi
  fns="$(mktemp)"
  extract_many "$src" "$fns" "${CAPTURE_FUNCS[@]}"
  cat "$fns" >> "$out"
  rm -f "$fns"
  return 0
}

# ── [1] the owned-CRD capture runs pre-cascade, and only for operators we created ──
# The fixture is deliberately the measured shape: two operators, one created by us and one adopted,
# each owning a distinct CRD. A capture that records the adopted operator's CRD would put
# `oc delete crd` next to an object the org owns, so the negative half matters more than the positive.
run_capture() {  # <func_file> → "CRDS=<space-separated>" + "PHASE=<value>"
  local func_file="$1" harness oclog
  harness="$(mktemp)"; oclog="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "OC_LOG='${oclog}'"
    echo "CSV_SNAPSHOT=''; CSV_SNAPSHOT_TAKEN='false'"
    cat <<'STUBS'
ok()   { echo "ok: $*"; }
err()  { echo "err: $*" >&2; }
csv_index() { printf '\n'; return 0; }
# Two recorded operators: ours-created and the org's-adopted.
enumerate_operators() {
  printf 'ours-operator ours-ns created ours-package\n'
  printf 'theirs-operator theirs-ns adopted theirs-package\n'
  return 0
}
resolve_operator_csv() { printf '%s.v1.0.0|fixture\n' "$1"; return 0; }
state() {
  case "$1" in
    op_ours-operator)   printf 'created:ours-ns' ;;
    op_theirs-operator) printf 'adopted:theirs-ns' ;;
    *) printf '%s' "${2:-}" ;;
  esac
  return 0
}
# FILE-recorded, never a variable: this runs inside $( ) and a variable would vanish with the subshell.
# ARGV-sensitive, so the batched index and the per-CSV fallback are told apart (`-A` is the whole
# difference) and one can never answer with the other's payload. Both paths are exercised: the index
# for the ordinary run, the fallback for a cluster whose jsonpath form came back empty.
oc() {
  printf '%s\n' "$*" >> "$OC_LOG"
  case " $* " in
    *' -A '*'customresourcedefinitions.owned'*)
      # the batched owned-CRD index: "<ns>|<csv>|<crd> …" per ORIGINAL CSV
      printf 'ours-ns|ours-operator.v1.0.0|ours.example.com \n'
      printf 'theirs-ns|theirs-operator.v1.0.0|theirs.example.com \n'
      return 0 ;;
    *'customresourcedefinitions.owned'*)
      case " $* " in
        *' ours-operator.v1.0.0 '*)   printf 'ours.example.com \n' ;;
        *' theirs-operator.v1.0.0 '*) printf 'theirs.example.com \n' ;;
      esac
      return 0 ;;
  esac
  return 0
}
STUBS
    cat "$func_file"
    echo 'capture_installed_csvs'
    # printf, not echo: this is harness SOURCE being written out, so the \n must reach the file
    # un-expanded. The $-refs belong to the generated harness, hence the single quotes.
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "CRDS=%s\n" "$(printf "%s" "$CRDS_CREATED_SET" | xargs || true)"'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "PHASE=%s\n" "$CRDS_CAPTURE_PHASE"'
  } > "$harness"
  bash "$harness" 2>/dev/null | grep -E '^(CRDS|PHASE)='
  rm -f "$harness" "$oclog"
  return 0
}

check_capture() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local func_file="$1" out crds phase rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[1] could not extract the capture functions — the guard cannot inspect what it claims to."
    return 2
  fi
  out="$(run_capture "$func_file")"
  crds="$(printf '%s\n' "$out" | grep -m1 '^CRDS=' | cut -d= -f2-)"
  phase="$(printf '%s\n' "$out" | grep -m1 '^PHASE=' | cut -d= -f2-)"

  case " ${crds} " in
    *' ours.example.com '*) ;;
    *)
      bad "[1] the pre-cascade capture recorded NO CRD for an operator the state says WE created."
      note "    This is the 2026-07-31 defect verbatim: the capture then only happens in the CSV-cleanup"
      note "    step, by which time the cascade has already deleted most of the CSVs it reads — 17 CRDs"
      note "    recorded of 165 still registered, reported as the complete list in 'exact' mode."
      note "    got: '${crds:-<nothing>}'"
      rc=1 ;;
  esac
  case " ${crds} " in
    *' theirs.example.com '*)
      bad "[1] the capture recorded an ADOPTED operator's CRD as one of ours."
      note "    ogsr-check-clean.sh prints 'oc delete crd <name>' beside an exact-mode CRD, and deleting"
      note "    a CRD deletes every instance of it cluster-wide. That is not recoverable."
      note "    got: '${crds}'"
      rc=1 ;;
  esac
  if [[ "$phase" != "pre-cascade" ]]; then
    bad "[1] CRDS_CAPTURE_PHASE is '${phase:-<empty>}', not 'pre-cascade'."
    note "    Downstream refuses 'exact' without this proof, so an unset flag silently downgrades every"
    note "    future check-clean run to the heuristic name-token guesser."
    rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    ok "[1] the owned-CRD capture runs pre-cascade, records our operator's CRDs, refuses the org's,"
    note "    and stamps the pre-cascade proof"
  fi
  return "$rc"
}

# ── [2] main's step order ─────────────────────────────────────────────────────
# Structural, and deliberately so: the whole defect is WHERE a call sits relative to two others.
STEP_STOP="step_stop_reconciliation"
STEP_OPERANDS="step_delete_operator_operands"
STEP_CASCADE="cascade_delete_applications"

run_step_line() {  # <file> <fn> → the line number of its run_step invocation ("" when absent)
  awk -v fn="$2" '/^run_step /, /[^\\]$/ { if (index($0, fn)) { print NR; exit } }' "$1"
}

check_order() {  # <uninstall-file> → 0 correct, 1 wrong, 2 nothing to inspect
  ran_check
  local f="$1" l_stop l_operand l_cascade rc=0
  if [[ ! -f "$f" ]]; then bad "[2] ${f} not found"; return 2; fi
  l_stop="$(run_step_line "$f" "$STEP_STOP")"
  l_operand="$(run_step_line "$f" "$STEP_OPERANDS")"
  l_cascade="$(run_step_line "$f" "$STEP_CASCADE")"
  if [[ -z "$l_stop" || -z "$l_cascade" ]]; then
    bad "[2] could not locate the run_step calls for ${STEP_STOP} / ${STEP_CASCADE} — the detector is"
    note "    looking at the wrong file, or main was restructured. Refusing to report a pass."
    return 2
  fi
  if [[ -z "$l_operand" ]]; then
    bad "[2] there is no run_step call for ${STEP_OPERANDS} at all."
    note "    Operands the operator created for itself carry no Argo tracking-id, so the cascade cannot"
    note "    prune them and nothing else ever will. Measured: TektonConfig alive with 18 pods and a"
    note "    bound 1Gi PVC after a teardown that reported success."
    return 1
  fi
  if [[ "$l_operand" -lt "$l_stop" ]]; then
    bad "[2] ${STEP_OPERANDS} runs BEFORE ${STEP_STOP} (line ${l_operand} < ${l_stop})."
    note "    An app-of-apps still on automated:{selfHeal} re-creates whatever the step removes."
    rc=1
  fi
  if [[ "$l_operand" -gt "$l_cascade" ]]; then
    bad "[2] ${STEP_OPERANDS} runs AFTER ${STEP_CASCADE} (line ${l_operand} > ${l_cascade})."
    note "    The cascade is what starts dismantling the operators. An operand's finalizer can only run"
    note "    while its own controller is alive; after the cascade it can NEVER complete, and the object"
    note "    needs a human with a finalizer patch."
    rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    ok "[2] main order holds: ${STEP_STOP} (${l_stop}) → ${STEP_OPERANDS} (${l_operand}) → ${STEP_CASCADE} (${l_cascade})"
  fi
  return "$rc"
}

# ── [3] the operand step's scope ──────────────────────────────────────────────
# LIVE INSTANCES ARE A FILE, not a variable. The step reads them through `oc get` inside $( ), which is
# a subshell — a variable-backed fixture would never see the deletes and pass 2 would be untestable.
run_operands() {  # <func_file> <dry> → the delete log
  local func_file="$1" dry="$2" harness dellog live
  harness="$(mktemp)"; dellog="$(mktemp)"; live="$(mktemp)"
  # "<crd> <instance>" per line, as the cluster would answer right now.
  {
    printf 'clusterscoped.example.com ours-operand\n'
    printf 'clusterscoped.example.com argo-tracked-operand\n'
    printf 'clusterscoped.example.com adopted-operand\n'
    printf 'namespaced.example.com namespaced-operand\n'
    printf 'parent.example.com the-parent\n'
  } > "$live"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "DRY_RUN='${dry}'"
    echo "CASCADE_TIMEOUT=900"
    # child BEFORE parent on purpose: pass 1 scans child while it does not exist yet, then deletes the
    # parent, which is what makes the operator re-create the child. Only a second pass can see it.
    echo "CRDS_CREATED_SET=' clusterscoped.example.com namespaced.example.com child.example.com parent.example.com '"
    echo "CRDS_CAPTURE_PHASE='pre-cascade'"
    echo "DEL_LOG='${dellog}'"
    echo "LIVE='${live}'"
    cat <<'STUBS'
ok()   { echo "ok: $*"; }
err()  { echo "err: $*" >&2; }
argo_manages() { [[ "$2" == "argo-tracked-operand" ]]; }
is_protected() { [[ "$2" == "adopted-operand" ]]; }
oc() {
  local verb="$1"; shift
  case "$verb" in
    get)
      case "$1" in
        customresourcedefinitions.apiextensions.k8s.io)
          printf 'clusterscoped.example.com|Cluster\n'
          printf 'parent.example.com|Cluster\n'
          printf 'child.example.com|Cluster\n'
          printf 'namespaced.example.com|Namespaced\n'
          return 0 ;;
        *)
          awk -v c="$1" '$1==c {print $2}' "$LIVE"
          return 0 ;;
      esac ;;
    delete)
      printf 'delete %s\n' "$*" >> "$DEL_LOG"
      # The cluster now really is short one object — that is what makes pass 2 a real second look.
      awk -v c="$1" -v n="$2" '!($1==c && $2==n)' "$LIVE" > "${LIVE}.tmp" && mv "${LIVE}.tmp" "$LIVE"
      # Deleting the parent is what un-blocks its child: until then the operator keeps re-creating it,
      # which is the whole reason this step takes two passes.
      if [[ "$1" == "parent.example.com" ]]; then
        printf 'child.example.com the-child\n' >> "$LIVE"
      fi
      return 0 ;;
  esac
  return 0
}
STUBS
    cat "$func_file"
    echo 'step_delete_operator_operands'
  } > "$harness"
  bash "$harness" >/dev/null 2>&1
  cat "$dellog"
  rm -f "$harness" "$dellog" "$live" "${live}.tmp"
  return 0
}

check_operand_scope() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[3] could not extract step_delete_operator_operands — the guard cannot inspect what it claims to."
    return 2
  fi
  out="$(run_operands "$func_file" false)"

  if ! grep -q 'clusterscoped.example.com ours-operand' <<< "$out"; then
    bad "[3] the cluster-scoped operand of an operator WE created was NOT deleted."
    note "    That object is the defect: no Argo owner, no namespace to take it, and once its operator"
    note "    goes nothing on the cluster will ever remove it."
    note "    got: ${out:-<nothing deleted>}"
    rc=1
  fi
  if ! grep -q -- '--wait=true' <<< "$out"; then
    bad "[3] the delete did not BLOCK (--wait=true absent)."
    note "    Returning before the finalizer completes is how the operand ends up orphaned anyway: the"
    note "    next steps remove the very controller that still had to run it."
    rc=1
  fi
  if grep -q 'argo-tracked-operand' <<< "$out"; then
    bad "[3] an operand Argo currently tracks was deleted here."
    note "    The ordered cascade prunes it in reverse sync-wave order, which is strictly better"
    note "    ordering than this step has. Racing it only breaks that."
    rc=1
  fi
  if grep -q 'adopted-operand' <<< "$out"; then
    bad "[3] an operand marked Prune=false,Delete=false (the org's) was deleted."
    rc=1
  fi
  if grep -q 'namespaced.example.com' <<< "$out"; then
    bad "[3] a NAMESPACED operand was deleted by this step."
    note "    The step's scope argument is that a namespaced operand dies with the namespace step 10"
    note "    removes; widening it silently makes this step responsible for objects it never waits on."
    rc=1
  fi
  if ! grep -q 'child.example.com the-child' <<< "$out"; then
    bad "[3] a child operand re-created after the first pass survived — the second pass is missing."
    note "    An operator re-creates a child from a parent that has not gone yet, and CRDS_CREATED_SET"
    note "    carries no parent-child order, so one pass cannot be enough."
    rc=1
  fi

  # --dry-run must touch nothing at all.
  out="$(run_operands "$func_file" true)"
  if [[ -n "$out" ]]; then
    bad "[3] --dry-run deleted something: ${out}"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[3] operand scope holds: our cluster-scoped operands are deleted blocking, Argo-tracked and"
    note "    adopted and namespaced ones are left alone, re-created children are caught, dry-run writes nothing"
  fi
  return "$rc"
}

# ── [4] no exact mode without proof of when the capture ran ───────────────────
run_section_crds() {  # <func_file> <state-kv> → the section's output
  local func_file="$1" kv="$2" harness
  harness="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "STATE_NS='ogsr-system'"
    printf "STATE_KV='%s'\n" "$kv"
    echo "CRD_INDEX='ours.example.com|ours-operator'"
    echo "N_ADOPTED=0; N_HEALTH=0; N_WS=0; N_TRACE=0; N_DECIDE=0"
    cat <<'STUBS'
hdr()  { :; }
note() { printf 'NOTE %s\n' "$*"; }
none() { printf 'NONE %s\n' "${1:-none}"; }
sub()  { printf 'SUB %s\n' "$*"; }
report_decide() { printf 'DECIDE %s\n' "$4"; N_DECIDE=$((N_DECIDE + 1)); }
crd_candidates_for() { printf 'ours.example.com\n'; return 0; }
crd_matches_adopted() { return 1; }
run_parallel() { local l; while IFS= read -r l; do printf '%s|1\n' "$l"; done; return 0; }
STUBS
    cat "$func_file"
    echo 'section_crds'
    # Harness source again — see run_capture() for why this is printf and single-quoted.
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "N_DECIDE=%s\n" "$N_DECIDE"'
  } > "$harness"
  bash "$harness" 2>&1
  rm -f "$harness"
  return 0
}

check_exact_needs_proof() {  # <func_file> → 0 correct, 1 wrong, 2 harness broken
  ran_check
  local func_file="$1" out rc=0
  if [[ ! -s "$func_file" ]]; then
    bad "[4] could not extract section_crds — the guard cannot inspect what it claims to."
    return 2
  fi

  # (a) the honest case: the list AND the proof it was taken before the cascade.
  out="$(run_section_crds "$func_file" 'crds_created=ours.example.com
crds_created_capture=pre-cascade
op_ours-operator=created:ours-ns')"
  if ! grep -q 'exact' <<< "$out"; then
    bad "[4] a list carrying crds_created_capture=pre-cascade was NOT reported in exact mode."
    note "    The proof exists precisely so the exact mode can be trusted; refusing it always makes"
    note "    the mode dead code and sends every run back to the name-token guesser."
    note "    got: ${out}"
    rc=1
  fi
  if grep -q 'N_DECIDE=0' <<< "$out"; then :; else
    bad "[4] a proven-pre-cascade list still raised a 'needs a human decision' finding."
    note "    got: ${out}"
    rc=1
  fi

  # (b) the measured case: a list with no proof of when it was taken.
  out="$(run_section_crds "$func_file" 'crds_created=ours.example.com
op_ours-operator=created:ours-ns')"
  if grep -qE '\[exact|mode.*exact|\(exact' <<< "$out"; then
    bad "[4] a list with NO capture-phase proof was still reported in 'exact' mode."
    note "    This is the 2026-07-31 defect: a capture taken after the cascade sees only the CSVs the"
    note "    cascade had not yet deleted (17 of 165 CRDs), and calling that fragment exact turns an"
    note "    unknown into a false all-clear."
    note "    got: ${out}"
    rc=1
  fi
  if grep -q 'N_DECIDE=0' <<< "$out"; then
    bad "[4] a list with NO capture-phase proof produced no 'needs a human decision' finding."
    note "    A gate that cannot verify must SAY it cannot verify; a silent downgrade still lets the"
    note "    run end with the ✅ clean verdict, which is the outcome that hid this for a whole cycle."
    note "    got: ${out}"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "[4] exact mode requires crds_created_capture=pre-cascade; without it the section reports that"
    note "    it cannot verify, and the verdict can no longer be 'clean'"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # <root> → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
  local root="$1" rc=0 sub=0 f
  local cap_f op_f sec_f
  for f in "$UNINSTALL" "$CHECKCLEAN"; do
    if [[ ! -f "${root}/${f}" ]]; then bad "${root}/${f} not found"; return 2; fi
  done
  cap_f="$(mktemp)"; op_f="$(mktemp)"; sec_f="$(mktemp)"
  build_capture_file "${root}/${UNINSTALL}" "$cap_f" || { rm -f "$cap_f" "$op_f" "$sec_f"; return 2; }
  extract_many "${root}/${UNINSTALL}"  "$op_f"  "${OPERAND_FUNCS[@]}"
  extract_many "${root}/${CHECKCLEAN}" "$sec_f" "${SECTION_FUNCS[@]}"

  sub=0; check_capture "$cap_f" || sub=$?
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_order "${root}/${UNINSTALL}" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi
  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_operand_scope "$op_f" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi
  if [[ "$rc" -ne 2 ]]; then
    sub=0; check_exact_needs_proof "$sec_f" || sub=$?
    if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  fi

  rm -f "$cap_f" "$op_f" "$sec_f"
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Every canary below is the real function with ONE line mutated into the defect shape. Each mutation is
# asserted to have actually applied — a sed that matched nothing would otherwise "detect" a canary that
# was never planted, which is the same unrun-gate failure this file exists to prevent.
self_test() {
  local tmp real_rc canary_rc f
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

  # Canary A — the 2026-07-31 defect verbatim: the capture happens only in the post-cascade CSV step,
  # so the pre-cascade pass records nothing.
  f="$tmp/canary-capture.sh"
  build_capture_file "${REPO_ROOT}/${UNINSTALL}" "$f" || return 2
  # The $-refs are part of the PATTERN being matched in the extracted source, not variables
  # to expand here — the single quotes are intentional.
  # shellcheck disable=SC2016
  sed -i.bak 's/^      record_created_crds "\$csv" "\$ns"$/      : # canary: capture removed/' "$f"
  if ! grep -q 'canary: capture removed' "$f"; then
    bad "SELF-TEST FAILED: could not build the late-capture canary — the record_created_crds call it mutates was not found."
    return 2
  fi
  canary_rc=0; check_capture "$f" >/dev/null 2>&1 || canary_rc=$?
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the late-capture canary was NOT detected (rc=${canary_rc}) — detector [1] is blind."
    return 2
  fi

  # Canary B — the capture records the ADOPTED operator too (authorization gate removed).
  f="$tmp/canary-authz.sh"
  build_capture_file "${REPO_ROOT}/${UNINSTALL}" "$f" || return 2
  # The $-refs are part of the PATTERN being matched in the extracted source, not variables
  # to expand here — the single quotes are intentional.
  # shellcheck disable=SC2016
  sed -i.bak 's/^    if csv_delete_authorized_by_state "\$name" "\$ns"; then$/    if true; then # canary: authz gate removed/' "$f"
  if ! grep -q 'canary: authz gate removed' "$f"; then
    bad "SELF-TEST FAILED: could not build the unauthorized-capture canary — the authorization gate it mutates was not found."
    return 2
  fi
  canary_rc=0; check_capture "$f" >/dev/null 2>&1 || canary_rc=$?
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the unauthorized-capture canary was NOT detected (rc=${canary_rc}) — detector [1] is blind to the org's CRDs."
    return 2
  fi

  # Canary C — the operand step moved back after the cascade, i.e. the ordering undone. The whole
  # run_step invocation is lifted out (it is written across a continuation line) and re-emitted at the
  # end, which is unambiguously after the cascade.
  local l_op l_start canary_op canary_casc
  f="$tmp/canary-order.sh"
  l_op="$(run_step_line "${REPO_ROOT}/${UNINSTALL}" "$STEP_OPERANDS")"
  if [[ -z "$l_op" ]]; then
    bad "SELF-TEST FAILED: could not locate the operand run_step in the real tree — nothing to mutate."
    return 2
  fi
  l_start="$l_op"
  if [[ "$(sed -n "$((l_op - 1))p" "${REPO_ROOT}/${UNINSTALL}")" == run_step\ * ]]; then
    l_start=$((l_op - 1))
  fi
  awk -v s="$l_start" -v e="$l_op" '
    NR >= s && NR <= e { held = held $0 "\n"; next }
    { print }
    END { printf "%s", held }
  ' "${REPO_ROOT}/${UNINSTALL}" > "$f"
  canary_op="$(run_step_line "$f" "$STEP_OPERANDS")"
  canary_casc="$(run_step_line "$f" "$STEP_CASCADE")"
  if [[ -z "$canary_op" || -z "$canary_casc" || "$canary_op" -lt "$canary_casc" ]]; then
    bad "SELF-TEST FAILED: could not build the wrong-order canary — the operand run_step was not moved after the cascade."
    return 2
  fi
  canary_rc=0; check_order "$f" >/dev/null 2>&1 || canary_rc=$?
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the wrong-order canary was NOT detected (rc=${canary_rc}) — detector [2] is blind."
    return 2
  fi

  # Canary D — the Argo-tracked guard removed: the step races the cascade for objects Argo orders better.
  f="$tmp/canary-argo.sh"
  extract_many "${REPO_ROOT}/${UNINSTALL}" "$f" "${OPERAND_FUNCS[@]}"
  # The $-refs are part of the PATTERN being matched in the extracted source, not variables
  # to expand here — the single quotes are intentional.
  # shellcheck disable=SC2016
  sed -i.bak 's/^        if argo_manages "\$crd" "\$inst"; then$/        if false; then # canary: argo guard removed/' "$f"
  if ! grep -q 'canary: argo guard removed' "$f"; then
    bad "SELF-TEST FAILED: could not build the races-the-cascade canary — the argo_manages guard it mutates was not found."
    return 2
  fi
  canary_rc=0; check_operand_scope "$f" >/dev/null 2>&1 || canary_rc=$?
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the races-the-cascade canary was NOT detected (rc=${canary_rc}) — detector [3] is blind."
    return 2
  fi

  # Canary E — one pass instead of two: a child operand re-created from a live parent survives.
  f="$tmp/canary-onepass.sh"
  extract_many "${REPO_ROOT}/${UNINSTALL}" "$f" "${OPERAND_FUNCS[@]}"
  sed -i.bak 's/^  for pass in 1 2; do$/  for pass in 1; do # canary: second pass removed/' "$f"
  if ! grep -q 'canary: second pass removed' "$f"; then
    bad "SELF-TEST FAILED: could not build the one-pass canary — the two-pass loop it mutates was not found."
    return 2
  fi
  canary_rc=0; check_operand_scope "$f" >/dev/null 2>&1 || canary_rc=$?
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the one-pass canary was NOT detected (rc=${canary_rc}) — detector [3] does not test re-creation."
    return 2
  fi

  # Canary F — the checker back to claiming exact with no proof of when the capture ran.
  f="$tmp/canary-exact.sh"
  extract_many "${REPO_ROOT}/${CHECKCLEAN}" "$f" "${SECTION_FUNCS[@]}"
  # The $-refs are part of the PATTERN being matched in the extracted source, not variables
  # to expand here — the single quotes are intentional.
  # shellcheck disable=SC2016
  sed -i.bak 's/^  if \[ -n "\$exact" \] && \[ "\$phase" != "pre-cascade" \]; then$/  if false; then # canary: proof requirement removed/' "$f"
  if ! grep -q 'canary: proof requirement removed' "$f"; then
    bad "SELF-TEST FAILED: could not build the unproven-exact canary — the capture-phase guard it mutates was not found."
    return 2
  fi
  canary_rc=0; check_exact_needs_proof "$f" >/dev/null 2>&1 || canary_rc=$?
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the unproven-exact canary was NOT detected (rc=${canary_rc}) — detector [4] is blind."
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0); late-capture, unauthorized-capture, wrong-order,"
  note "   races-the-cascade, one-pass and unproven-exact canaries all caught."
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
