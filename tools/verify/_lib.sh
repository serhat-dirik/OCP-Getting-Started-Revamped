#!/usr/bin/env bash
# shellcheck disable=SC2034  # USER_NAME/ENTRY_ONLY/SOLVE_MODE are consumed by the sourcing verify script
# Shared helpers for per-module verify scripts (tools/verify/mNN.sh).
# Contract: each script takes --user U (default user1) and optional --entry-only,
# checks ENTRY state (what `ws start` materializes) and, unless --entry-only,
# END state (what a completed lab looks like); exits 0 only if all checks pass.
# Output style: one line per check, ✅/❌ + fix hint. CI runs these standalone.

VERIFY_PASS=0
VERIFY_FAIL=0
# Third outcome, and it is NOT a pass: a check the caller could not evaluate (see warn()). Counted so
# verify_summary can say so — for eleven of these scripts the summary used to swallow it entirely.
VERIFY_SKIP=0

check() {  # check "<description>" <command...>  — pass/fail one assertion
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "✅ ${desc}"
    VERIFY_PASS=$((VERIFY_PASS+1))
    return 0
  else
    echo "❌ ${desc}"
    VERIFY_FAIL=$((VERIFY_FAIL+1))
    return 1
  fi
}

hint() { echo "   ↳ fix: $*"; }

# A ConfigMap whose values are written by an Argo Sync hook rather than rendered by the chart —
# maas-config / maas-config-env in the AI entry states — EXISTS from the moment the chart applies, so
# `oc get cm` passing is no longer evidence that anything wired it up. The chart deliberately renders
# metadata only (the model comes from the cluster's MaaS Secret, not from git), which means an existence
# check would go green on a ConfigMap the hook never filled. Assert the key the workloads actually read.
cm_key_set() {  # namespace configmap key → 0 when that key exists and is non-empty
  [ -n "$(oc get configmap "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null)" ]
}

# INCONCLUSIVE, never a failure — for a check the CALLER cannot evaluate (no impersonation rights, an
# in-cluster-only endpoint on an off-cluster run). Deliberately does NOT touch the pass/FAIL counters:
# a false ❌ destroys attendee trust in every other ✅ (tools/verify/README.md, contract).
# It DOES count as a skip, because "not a failure" is not the same as "graded and fine" — see
# verify_summary. Follow every warn with a hint saying WHERE the check can be answered.
warn() { echo "⚠ $* — SKIPPED (not a failure)"; VERIFY_SKIP=$((VERIFY_SKIP+1)); }

# Neutral note (skipped/context lines) — matches ws's own info style so smoke output is unchanged
# when a verify script shadows it. Standalone verify scripts (multi-tenancy-workload-security/networking-dev-devops) rely on this being defined.
info() { echo "▶ $*"; }

# THREE outcomes in, three outcomes out. The banner used to know only pass/fail, so a run in which
# every GRADED outcome was skipped still ended "✅ all 7 checks passed", exit 0 — false completeness
# in 11 of 26 scripts (audit 2026-07-31; worst case multi-tenancy-workload-security, where all six
# end-state RBAC outcomes — the entire lesson — sit behind one impersonation guard). The fix is here,
# not in warn(): a check that genuinely cannot run must still never print ❌.
#
# EXIT CODE, deliberately: skipped-but-nothing-failed exits 0 by DEFAULT. `ws prep` reads
# `<script> --entry-only`'s rc as a boolean "is this world already prepared?" (tools/ws/ws cmd_prep),
# and a non-zero rc there tells the attendee their environment is broken and offers to WIPE it — a
# destructive false alarm on a healthy world. `ws smoke` reads the same rc as a G1 ❌. So the BANNER
# carries the signal for humans, and automation that must fail closed opts in with VERIFY_STRICT=1
# and gets rc 3 — distinct from 1 (a check actually FAILED) and 2 (usage error, parse_verify_args).
verify_summary() {  # call at end of every script
  echo
  local graded=$((VERIFY_PASS+VERIFY_FAIL))
  if (( VERIFY_FAIL > 0 )); then
    if (( VERIFY_SKIP > 0 )); then
      echo "❌ ${VERIFY_FAIL} of ${graded} checks failed · ⚠ ${VERIFY_SKIP} SKIPPED (not graded)"
    else
      echo "❌ ${VERIFY_FAIL} of ${graded} checks failed"
    fi
    exit 1
  fi
  if (( VERIFY_SKIP > 0 )); then
    echo "⚠ ${VERIFY_PASS} passed · ${VERIFY_SKIP} SKIPPED (not graded) — this run did NOT fully verify the lab"
    echo "   ↳ each ⚠ line above says where its check can be answered; re-run there for a complete result"
    # `if`, not `[[ … ]] && exit 3`: under the callers' `set -e` a false one-liner would return 1 from
    # this function and kill the script — turning a skip into the exit 1 the whole design avoids.
    if [[ "${VERIFY_STRICT:-0}" == "1" ]]; then
      exit 3
    fi
    exit 0
  fi
  echo "✅ all ${VERIFY_PASS} checks passed"
  exit 0
}

parse_verify_args() {  # sets USER_NAME, ENTRY_ONLY, SOLVE_MODE from "$@"
  USER_NAME="user1"
  ENTRY_ONLY="false"
  # SOLVE_MODE=true ONLY when validating a `ws solve` result (ws verify <m> --solve, or CI). A script may
  # then hard-assert its ws-solve-<module> marker. A plain `ws verify` — the attendee's own closing verify
  # after doing the lab BY HAND — leaves SOLVE_MODE=false, so a marker that only `ws solve` stamps must NOT
  # be asserted (the lab's real OUTCOME checks carry the proof; a false ❌ on a correctly-completed lab
  # destroys trust in every other ✅).
  SOLVE_MODE="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) USER_NAME="$2"; shift 2;;
      --entry-only) ENTRY_ONLY="true"; shift;;
      --solve) SOLVE_MODE="true"; shift;;
      *) echo "unknown arg: $1" >&2; exit 2;;
    esac
  done
}
