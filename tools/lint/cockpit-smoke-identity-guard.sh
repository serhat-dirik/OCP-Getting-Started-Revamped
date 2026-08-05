#!/usr/bin/env bash
# cockpit-smoke-identity-guard.sh — the smoke gate must run in the REAL cockpit terminal, as the attendee.
#
# ORIGIN (SEV2-G, 2026-08-06). The cockpit smoke is the only gate that touches the surface attendees
# actually touch: the ttyd terminal inside showroom-<user>, logged in as <user>. A smoke that runs
# `ws` from a maintainer laptop against a cluster-admin kubeconfig proves nothing about it, and when
# one did, three defect classes walked past it into the owner's first live session:
#
#   • `ws` was not on the terminal's interactive PATH — measured again 2026-08-06 on user5's live
#     cockpit: `bash -ic` finds /home/lab-user/ocp-getting-started/tools/ws/ws, a NON-interactive
#     `bash -c` in the same container finds nothing, and a maintainer shell finds its own checkout.
#   • the terminal answered as the showroom ServiceAccount, not as the attendee. From a laptop
#     `oc whoami` says `admin` and the mismatch is unobservable.
#   • peer namespaces were listable by an attendee who should only ever see their own — an admin
#     shell can list every namespace on the cluster, so the isolation check silently inverts.
#
# Every one of those is invisible from an admin shell by construction: it has ws on PATH,
# cluster-admin rights, and a different HOME. Only the attendee's own terminal can answer them.
#
# WHAT THIS GUARD CAN AND CANNOT PROVE — read this before quoting a green run as evidence.
# CI has no cluster, no cockpit and no attendee, so it cannot smoke anything. The real proof is
# `tools/ws/ws smoke <module> <userN>` against a live cockpit; THIS guard is strictly weaker and a
# green run of it is NOT a smoke pass. What CI can hold is the CONTRACT — that the gate still drives
# the attendee's real terminal rather than the host shell — so the regression that produced SEV2-G
# cannot land unnoticed between on-cluster runs. Keep the two claims apart in any report.
#
# WHY `bash -ic` AND NOT `bash -c` / `bash -lc`. The cockpit exports the workshop PATH from the
# terminal's ~/.bashrc, and the stock skel .bashrc early-returns for a non-interactive shell — so a
# bare `oc exec … -- bash -c 'ws …'` reports "ws: command not found" on a perfectly healthy cockpit
# (a test artifact), while `bash -lc` sources the login files instead and misses the same block.
# Only an INTERACTIVE shell reproduces what the attendee types into ttyd.
#
# WHY `-c <container>`. The cockpit pod runs three containers (nginx, content, terminal). Without an
# explicit selector `oc exec` takes the FIRST one — verified live 2026-08-06: it lands in nginx,
# where there is no ws and no attendee kubeconfig, and the gate grades a container no attendee ever
# sees.
#
# Checks (each one a canary in --self-test):
#   [1] tools/ws/ws defines an exec helper that reaches the cockpit through an INTERACTIVE shell
#       (`oc exec … -c <container> -- bash -ic`), the container is the ttyd terminal, and no cockpit
#       exec uses a login shell.
#   [2] cmd_smoke DRIVES the attendee path through that helper: `ws prep`, `ws verify` and the
#       identity assertion (`oc whoami`) all travel into the pod, and the helper is what the gate
#       actually runs on.
#   [3] cmd_smoke never falls back to the host: no local cmd_prep/cmd_verify/verify-script call, and
#       no attendee entrypoint smuggled through the NON-interactive helper.
#
# Exit codes:
#   0  contract holds
#   1  contract broken — or, under --self-test, every canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (file missing, extraction failed)
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

WS="tools/ws/ws"
FUNC="cmd_smoke"
# The attendee entrypoints. Each one MUST be typed into the attendee's own terminal to mean anything:
# `ws prep` exercises materialization under the attendee's RBAC, `ws verify` grades the entry state
# with the attendee's reads, and `oc whoami` is the identity assertion itself.
ENTRYPOINTS=('ws prep' 'ws verify' 'oc whoami')

# Helper names are DISCOVERED, never hardcoded: a rename must not silently switch this guard off.
# An interactive cockpit exec is the only shape that reproduces ttyd.
interactive_helpers() {  # root → helper names, one per line
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[^#]*oc exec[^#]*bash[[:space:]]+-ic' \
    "${1}/${WS}" 2>/dev/null | sed -E 's/\(\).*//' | sort -u
}
# The non-interactive twin is legitimate — clean captures (a git HEAD) must not have the MOTD spliced
# into them — but it is NOT the attendee's shell and must never carry an entrypoint.
noninteractive_helpers() {  # root → helper names, one per line
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[^#]*oc exec[^#]*bash[[:space:]]+-c[[:space:]]' \
    "${1}/${WS}" 2>/dev/null | sed -E 's/\(\).*//' | sort -u
}
# newline-separated names → an ERE alternation. Used with a leading [^A-Za-z0-9_] so a longer
# identifier that merely ENDS in a helper's name cannot count as a call.
alternation() { tr '\n' '|' | sed -E 's/\|+$//'; }

# ── [1] the exec helper reaches the real terminal ─────────────────────────────
check_interactive_exec_helper() {  # root → 0 clean, 1 broken, 2 uninspectable
  ran_check
  local root="$1" names rc=0
  if [[ ! -f "${root}/${WS}" ]]; then
    bad "[1] ${WS} not found under ${root} — nothing to inspect."
    return 2
  fi

  names="$(interactive_helpers "$root")"
  if [[ -z "$names" ]]; then
    bad "[1] no helper in ${WS} execs the cockpit through an INTERACTIVE shell (oc exec … -- bash -ic)."
    note "    Without one the gate cannot be running what the attendee types: a non-interactive"
    note "    shell skips the terminal's ~/.bashrc, so 'ws' is not on PATH and the gate reports a"
    note "    healthy cockpit as broken — or, worse, the run moved back to the maintainer's shell,"
    note "    which is the SEV2-G defect verbatim."
    rc=1
  else
    ok "[1] cockpit exec helper(s): $(printf '%s' "$names" | tr '\n' ' ')— oc exec … -- bash -ic"
  fi

  if [[ -n "$names" ]] && ! grep -qE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[^#]*oc exec[^#]*[[:space:]]-c[[:space:]][^#]*bash[[:space:]]+-ic' "${root}/${WS}"; then
    bad "[1] the interactive exec helper does not select a container (-c <container>)."
    note "    The cockpit pod runs nginx + content + terminal; with no selector oc exec takes the"
    note "    FIRST container, which has neither ws nor the attendee's kubeconfig."
    rc=1
  fi

  if ! grep -qE "^SMOKE_CONTAINER=[\"']?terminal[\"']?[[:space:]]*(#.*)?$" "${root}/${WS}"; then
    bad "[1] SMOKE_CONTAINER is not the ttyd 'terminal' container."
    note "    Grading any other container grades an image the attendee never types into."
    rc=1
  fi

  if grep -qE 'oc exec[^#]*bash[[:space:]]+-lc' "${root}/${WS}"; then
    bad "[1] a cockpit exec uses a LOGIN shell (bash -lc)."
    note "    The terminal's PATH is exported from ~/.bashrc, which a login shell does not source;"
    note "    -lc reintroduces the ws-not-found false failure that -ic exists to avoid."
    rc=1
  fi
  return "$rc"
}

# ── [2] the smoke drives the attendee path through it ─────────────────────────
check_smoke_drives_cockpit() {  # root → 0 clean, 1 broken, 2 uninspectable
  ran_check
  local root="$1" body names alt uses ep rc=0
  if [[ ! -f "${root}/${WS}" ]]; then
    bad "[2] ${WS} not found under ${root} — nothing to inspect."
    return 2
  fi
  body="$(extract_func "${root}/${WS}" "$FUNC")"
  if [[ -z "$body" ]]; then
    bad "[2] could not extract ${FUNC}() from ${WS} — the gate may have been renamed or removed."
    return 2
  fi
  names="$(interactive_helpers "$root")"
  if [[ -z "$names" ]]; then
    bad "[2] no interactive exec helper exists to drive the smoke through — see [1]."
    return 2
  fi
  alt="$(printf '%s\n' "$names" | alternation)"

  uses="$(printf '%s\n' "$body" | grep -cE "^[^#]*[^A-Za-z0-9_](${alt})[[:space:]]")"
  if [[ "$uses" -lt 3 ]]; then
    bad "[2] ${FUNC}() calls the cockpit exec helper only ${uses} time(s) — it is not what the gate runs on."
    rc=1
  else
    ok "[2] ${FUNC}() runs ${uses} checks inside the attendee's terminal"
  fi

  for ep in "${ENTRYPOINTS[@]}"; do
    if ! printf '%s\n' "$body" | grep -qE "^[^#]*[^A-Za-z0-9_](${alt})[[:space:]].*${ep}"; then
      bad "[2] '${ep}' is not driven through the cockpit exec helper in ${FUNC}()."
      note "    Run from the host it answers as the maintainer: ws is the checkout's, oc is"
      note "    cluster-admin, HOME is the laptop's. That is a different world from the attendee's."
      rc=1
    fi
  done
  [[ "$rc" -ne 0 ]] || ok "[2] ws prep · ws verify · oc whoami all execute as the attendee"
  return "$rc"
}

# ── [3] no host-side fallback ─────────────────────────────────────────────────
check_no_hostside_entrypoints() {  # root → 0 clean, 1 broken, 2 uninspectable
  ran_check
  local root="$1" body hits nonint alt ep rc=0
  if [[ ! -f "${root}/${WS}" ]]; then
    bad "[3] ${WS} not found under ${root} — nothing to inspect."
    return 2
  fi
  body="$(extract_func "${root}/${WS}" "$FUNC")"
  if [[ -z "$body" ]]; then
    bad "[3] could not extract ${FUNC}() from ${WS}."
    return 2
  fi

  # (a) the local verbs and the module's own verify script. `source "${VERIFY_DIR}/_lib.sh"` is fine
  # and deliberately not matched: the gate borrows the ✅/❌ idiom, it does not run a check locally.
  # shellcheck disable=SC2016  # an ERE, not a string: "\$script" must reach grep as literal text
  hits="$(printf '%s\n' "$body" | grep -nE '^[^#]*([^A-Za-z0-9_]|^)(cmd_prep|cmd_verify)[[:space:]]|^[^#]*"\$script"')"
  if [[ -n "$hits" ]]; then
    bad "[3] ${FUNC}() runs an attendee entrypoint on the HOST:"
    printf '%s\n' "$hits" | sed 's/^/       /' >&2
    note "    That is the SEV2-G defect: the gate grades the maintainer's shell and reports it as"
    note "    the attendee's. Route it through the cockpit exec helper instead."
    rc=1
  fi

  # (b) an entrypoint smuggled through the non-interactive helper — same pod, wrong shell.
  nonint="$(noninteractive_helpers "$root")"
  if [[ -n "$nonint" ]]; then
    alt="$(printf '%s\n' "$nonint" | alternation)"
    for ep in "${ENTRYPOINTS[@]}"; do
      hits="$(printf '%s\n' "$body" | grep -nE "^[^#]*[^A-Za-z0-9_](${alt})[[:space:]].*${ep}")"
      if [[ -n "$hits" ]]; then
        bad "[3] '${ep}' runs through the NON-interactive exec helper (no ~/.bashrc, so no ws on PATH):"
        printf '%s\n' "$hits" | sed 's/^/       /' >&2
        rc=1
      fi
    done
  fi

  [[ "$rc" -ne 0 ]] || ok "[3] no host-side or non-interactive fallback in ${FUNC}()"
  return "$rc"
}

run_check() {  # root → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
  local root="$1" rc=0 sub=0
  check_interactive_exec_helper "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  sub=0; check_smoke_drives_cockpit "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  sub=0; check_no_hostside_entrypoints "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site leaves
  # every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Canaries are MUTATIONS OF THE REAL FILE, not a synthetic stand-in: each one is a single edit of the
# shape a refactor would actually make, so a canary that stops reproducing is itself a signal.
mutate_ws() {  # tmp sed-expr… → writes tmp/tools/ws/ws, echoes its root
  local tmp="$1"; shift
  mkdir -p "${tmp}/tools/ws"
  local args=() e
  for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "${REPO_ROOT}/${WS}" > "${tmp}/${WS}"
  printf '%s' "$tmp"
}

self_test() {
  local tmp real_rc rc
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

  # Canary A — the exec drops to a non-interactive shell. Reproduces the "ws: command not found on a
  # healthy cockpit" artifact measured live on user5.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" 's/bash -ic/bash -c/' >/dev/null
  rc=0; check_interactive_exec_helper "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a non-interactive cockpit exec was NOT detected (rc=${rc}) — detector [1] is blind."
    return 2
  fi

  # Canary B — a login shell instead of an interactive one.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" 's/bash -ic/bash -lc/' >/dev/null
  rc=0; check_interactive_exec_helper "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: 'bash -lc' was NOT detected (rc=${rc}) — detector [1] is blind to login shells."
    return 2
  fi

  # Canary C — the container selector goes away and the exec lands in nginx.
  rm -rf "${tmp:?}/tools"
  # shellcheck disable=SC2016  # a sed script: $SMOKE_CONTAINER is the text being deleted from ws
  mutate_ws "$tmp" 's/ -c "\$SMOKE_CONTAINER"//' >/dev/null
  rc=0; check_interactive_exec_helper "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a missing -c <container> was NOT detected (rc=${rc}) — detector [1] is blind."
    return 2
  fi

  # Canary D — the SEV2-G shape itself: `ws prep` stops travelling into the pod.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" 's/pod_i "ws prep/run_local "ws prep/' >/dev/null
  if ! grep -q 'run_local "ws prep' "${tmp}/${WS}"; then
    bad "SELF-TEST FAILED: could not build the host-side-prep canary — the pod_i call it mutates was not found."
    return 2
  fi
  rc=0; check_smoke_drives_cockpit "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: 'ws prep' leaving the cockpit was NOT detected (rc=${rc}) — detector [2] is blind."
    return 2
  fi

  # Canary E — a local verify verb called from inside the gate.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" "s/^cmd_smoke() {/cmd_smoke() {\n  cmd_verify \"\$user\" \"\$module\"/" >/dev/null
  # shellcheck disable=SC2016  # searching for the literal text the canary just wrote into the copy
  if ! grep -q 'cmd_verify "\$user" "\$module"' "${tmp}/${WS}"; then
    bad "SELF-TEST FAILED: could not build the host-side-verify canary — ${FUNC}()'s opening line was not found."
    return 2
  fi
  rc=0; check_no_hostside_entrypoints "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a host-side cmd_verify call was NOT detected (rc=${rc}) — detector [3] is blind."
    return 2
  fi

  # Canary F — the file is not there at all. Must be "could not inspect" (2), never a clean 0.
  rm -rf "${tmp:?}/tools"
  rc=0; run_check "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 2 ]]; then
    bad "SELF-TEST FAILED: a missing ${WS} reported rc=${rc}, not 2 — the guard would pass on nothing."
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0); non-interactive, login-shell, no-container, host-side-prep,"
  note "host-side-verify and missing-file canaries all caught."
  return 1
}

# Rejects anything that is not --self-test / -h / --help, naming the offender, exit 2.
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

run_check "$REPO_ROOT"
rc=$?
case "$rc" in
  0) printf 'cockpit-smoke-identity-guard: clean — the smoke gate still runs in the attendee cockpit.\n'
     printf '%s\n' "  (Contract only. CI has no cockpit: the real proof is 'tools/ws/ws smoke <module> <userN>'.)" ;;
  1) printf '\n%s\n' "  A smoke that does not run in the attendee's terminal proves nothing about the surface" >&2
     printf '%s\n\n'  "  attendees touch — it grades the maintainer's shell. Fix before trusting any G1 result." >&2 ;;
esac
exit "$rc"
