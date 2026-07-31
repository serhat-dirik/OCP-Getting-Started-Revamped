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

# ── the API's answer, classified — do not swallow errors with `2>/dev/null` ────────────────────────
#
# `oc get … 2>/dev/null` cannot tell "the object you were told to create is not there" (a real,
# gradeable ❌) from "the cluster did not answer" (throttling, an apiserver blip, an expired token, a
# network hiccup — not the attendee's lab, and not gradeable at all). Both come back as an empty
# string, so the attendee is told their correct work is wrong. The project's rule is that a false ❌
# destroys attendee trust in every other ✅, so this is a trust bug, not a cosmetic one.
#
# oc_read is the third-outcome primitive: it runs one `oc` read, keeps stdout and stderr apart, and
# says which KIND of answer came back. Same shape jobs-batch-kueue's ClusterQueue guard and
# gitops-fundamentals' Argo access-plane guard already use by hand — this is that pattern, once.
#
# Sets OC_OUT (stdout, no trailing newline) and OC_ERR (stderr, flattened to one line).
#   rc 0 → THE API ANSWERED. OC_OUT may be empty, and empty is a real answer: the object or the field
#          is genuinely absent, which must stay a ❌. NotFound is folded in here on purpose.
#   rc 1 → THE API COULD NOT BE ASKED, and VERIFY_INCONCLUSIVE is set to 1 so check() reports ⚠ SKIP
#          instead of ❌. Never a pass either — "cannot tell" is its own outcome, not optimism.
#
# CLASSIFICATION IS AN ALLOWLIST OF "COULD NOT ASK", NOT OF "ABSENT" — deliberately, and this is the
# load-bearing choice. Defaulting the unknown case to inconclusive would quietly downgrade genuine
# absences to skips the moment a message we did not foresee appeared, and a skip that should have
# been a ❌ is the same trust bug pointed the other way. So: anything not recognised as a transport,
# credential or authorization failure is treated as the server's real answer and still fails loudly.
# It also keeps `oc auth can-i`'s plain "no" (rc 1, stderr only a namespace-scope Warning) a ❌.
#
# Patterns below were captured from a live 4.20 cluster, 2026-08-01, not from memory:
#   NotFound      Error from server (NotFound): deployments.apps "x" not found            → ANSWERED
#   no such CRD   error: the server doesn't have a resource type "widgets"                → ANSWERED
#                 (the operator is not installed — a real platform failure worth a ❌)
#   refused       The connection to the server 127.0.0.1:59999 was refused - did you …    → could not ask
#   expired token error: You must be logged in to the server (Unauthorized)               → could not ask
#                 couldn't get current server API group list: the server has asked for …  → could not ask
#   timeout       Unable to connect to the server: net/http: request canceled … Client.Timeout
#                 … context deadline exceeded                                             → could not ask
#   forbidden     Error from server (Forbidden): … cannot list resource … at the cluster scope
#                 (rule 10: not this identity's check to run — see tools/verify/README.md)
VERIFY_INCONCLUSIVE=0
OC_OUT=""
OC_ERR=""
oc_read() {  # oc_read <oc args…> → OC_OUT/OC_ERR; rc 0 = oc succeeded, 1 = real NO, 2 = could not ask
  local errfile rc=0
  # One short-lived file per call rather than a process-wide one plus a trap: verify scripts exit
  # through verify_summary's `exit`, and an EXIT trap installed here would fight any the script sets.
  errfile="$(mktemp "${TMPDIR:-/tmp}/ogsr-verify.XXXXXX")" || {
    OC_OUT=""; OC_ERR="could not create a temp file for stderr"; VERIFY_INCONCLUSIVE=1; return 2
  }
  # `|| rc=$?` and not a bare assignment: under the callers' `set -e` a failing command substitution
  # in an assignment kills the script outright, which is the one thing this helper must never do.
  OC_OUT="$(oc "$@" 2>"$errfile")" || rc=$?
  # An attendee has to be able to READ this. client-go prefixes five identical klog "Unhandled Error"
  # lines (E0801 02:00:31.256518 … memcache.go:265) to every connection failure, and dumping them raw
  # buried the one human-readable sentence oc prints last under ~1.5 kB of noise. Drop the klog lines,
  # flatten what remains, cap it: the classification below still reads the FULL text from the file's
  # own content via this same variable, and every pattern it matches survives the trim.
  OC_ERR="$(sed -e '/^[EWIF][0-9]\{4\} [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/d' "$errfile" | tr '\n' ' ' | tr -s ' ')"
  # Nothing but klog noise (some failures print only that) → fall back to the raw text so the
  # classification is never handed an empty string it would misread as "the server's real answer".
  [[ -n "${OC_ERR// /}" ]] || OC_ERR="$(tr '\n' ' ' <"$errfile" | tr -s ' ')"
  OC_ERR="${OC_ERR#"${OC_ERR%%[![:space:]]*}"}"   # trim leading space
  rm -f "$errfile"
  if (( rc == 0 )); then
    return 0
  fi
  # rc 1 vs rc 2 is the WHOLE POINT and an earlier draft got it wrong: folding NotFound into rc 0
  # made `check "PodDisruptionBudget parasol-claims exists" oc get pdb …` PASS on a namespace that had
  # no PDB at all (caught by diffing a full run against HEAD on user7, 2026-08-01). A genuine absence
  # is a real answer and must stay a ❌ — only "could not ask" may become ⚠.
  case "$OC_ERR" in
    *"(Forbidden)"*|*" is forbidden"*|\
    *"(Unauthorized)"*|*"must be logged in to the server"*|*"asked for the client to provide credentials"*|\
    *"(TooManyRequests)"*|*"(ServiceUnavailable)"*|*"(InternalError)"*|*"(ServerTimeout)"*|*"(Timeout)"*|\
    *"Unable to connect to the server"*|*"connection to the server"*|*"connection refused"*|\
    *"context deadline exceeded"*|*"Client.Timeout"*|*"i/o timeout"*|*"TLS handshake timeout"*|\
    *"no such host"*|*"connection reset by peer"*|*"network is unreachable"*|*"no route to host"*|\
    *"currently unable to handle the request"*|*"unable to retrieve the complete list of server APIs"*|\
    *"couldn't get current server API group list"*|*"etcdserver:"*|*"unexpected EOF"*|\
    *"no configuration has been provided"*|*"Missing or incomplete configuration"*)
      OC_OUT=""
      VERIFY_INCONCLUSIVE=1
      return 2
      ;;
    *)
      # NotFound, "doesn't have a resource type", and anything else not recognised as a transport or
      # credential failure: the server's real answer. Still a ❌ — unchanged from before this helper.
      OC_OUT=""
      return 1
      ;;
  esac
}

# Absence, asked safely. `! oc get … 2>/dev/null` and `[[ -z "$(oc get … 2>/dev/null)" ]]` both
# certify a clean slate from an API that never answered — the one direction this whole change must
# never take, since a wrongly-green entry check sends `ws prep` down its "already prepared" fast path.
oc_absent() {  # <oc get args…> → 0 only when the API ANSWERED and nothing is there
  local rc=0
  oc_read "$@" || rc=$?
  if (( rc == 2 )); then return 1; fi   # could not ask → ⚠ via the flag, never a certified clean slate
  if (( rc == 1 )); then return 0; fi   # NotFound → genuinely absent
  [[ -z "$OC_OUT" ]]                    # rc 0: an empty list is also genuinely absent
}

oc_present() {  # <oc get args…> → 0 only when the API ANSWERED and something is there
  oc_read "$@" || return 1
  [[ -n "$OC_OUT" ]]
}

check() {  # check "<description>" <command...>  — pass/fail/SKIP one assertion
  local desc="$1"; shift
  local rc=0
  # Cleared per check so the flag can only describe THIS assertion; only oc_read ever raises it, so a
  # predicate that never touches oc_read behaves exactly as it did before this helper existed.
  VERIFY_INCONCLUSIVE=0
  if [[ "${1:-}" == "oc" ]]; then
    # Every `check "…" oc get …` call site in this suite (103 of them, counted 2026-08-01) gets the
    # three-outcome treatment with no change at the call site: the classification belongs to the tool,
    # not to 103 hand-written repetitions of it.
    shift
    oc_read "$@" || rc=$?
  else
    "$@" >/dev/null 2>&1 || rc=$?
  fi
  if (( rc == 0 )); then
    echo "✅ ${desc}"
    VERIFY_PASS=$((VERIFY_PASS+1))
    return 0
  fi
  # The FLAG, not the rc, carries the classification: predicates return whatever they like (curl's
  # exit codes reach here too), and only oc_read can raise the flag. rc alone would collide.
  if (( VERIFY_INCONCLUSIVE == 1 )); then
    # Truncated HERE, not in oc_read: the classification must see the whole message, the attendee
    # only needs the gist. One line, not a paragraph — this sits in a list of ✅s.
    local why="${OC_ERR:0:160}"
    [[ "${#OC_ERR}" -le 160 ]] || why="${why}…"
    # "Refused to answer" and "could not answer" are different problems with different next steps, and
    # telling an attendee to retry an RBAC denial wastes their time. Split the message accordingly.
    case "$OC_ERR" in
      *"(Forbidden)"*|*" is forbidden"*)
        warn "${desc} — not readable as this identity${why:+ (${why})}"
        hint "not yours to fix and not graded: this check asks for something your account may not read, so it has no verdict here. Run it where it can be answered — your own cockpit terminal for your own namespaces, or an instructor/CI run for cluster-wide objects"
        ;;
      *)
        warn "${desc} — the cluster API did not answer${why:+ (${why})}"
        hint "not your lab, and not graded: the cluster could not be asked, so this check has no verdict. Re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor"
        ;;
    esac
    # Returns 0 so the call site's own `|| hint \"…\"` — which tells the attendee to redo work they
    # may well have done correctly — does NOT fire. The ⚠ line above is the whole verdict.
    return 0
  fi
  echo "❌ ${desc}"
  VERIFY_FAIL=$((VERIFY_FAIL+1))
  return 1
}

hint() { echo "   ↳ fix: $*"; }

# A ConfigMap whose values are written by an Argo Sync hook rather than rendered by the chart —
# maas-config / maas-config-env in the AI entry states — EXISTS from the moment the chart applies, so
# `oc get cm` passing is no longer evidence that anything wired it up. The chart deliberately renders
# metadata only (the model comes from the cluster's MaaS Secret, not from git), which means an existence
# check would go green on a ConfigMap the hook never filled. Assert the key the workloads actually read.
cm_key_set() {  # namespace configmap key → 0 when that key exists and is non-empty
  oc_read get configmap "$2" -n "$1" -o jsonpath="{.data.$3}" || return 1
  [[ -n "$OC_OUT" ]]
}

# ── hoisted from the modules ──────────────────────────────────────────────────────────────────────
# deploy_ready was copy-pasted, byte-for-byte apart from its argument style, into NINETEEN verify
# scripts backing FIFTY-ONE call sites (counted 2026-08-01) — every copy swallowing the API error the
# same way. Nineteen places to get the same fix wrong is the argument for it living here once.
# Both historical call styles are supported so no call site had to change: scripts that set a single
# NS pass just the name, the rest pass name + namespace explicitly.
deploy_ready() {  # <deployment> [namespace] → at least one ready replica
  oc_read get deploy "$1" -n "${2:-${NS:-}}" -o jsonpath='{.status.readyReplicas}' || return 1
  [[ -n "$OC_OUT" && "$OC_OUT" -ge 1 ]]
}

# >=, never ==: several labs have the attendee deliberately exceed the overlay's canonical replica
# count (config-multienv's prod Challenge, gitops-fundamentals Exercise D), and an exact match would
# false-fail a correctly-completed lab.
deploy_ready_min() {  # <deployment> <namespace> <n> → at least n ready replicas
  oc_read get deploy "$1" -n "$2" -o jsonpath='{.status.readyReplicas}' || return 1
  [[ -n "$OC_OUT" && "$OC_OUT" -ge "$3" ]]
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
