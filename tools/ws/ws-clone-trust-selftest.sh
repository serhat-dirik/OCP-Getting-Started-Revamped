#!/usr/bin/env bash
# ws-clone-trust-selftest.sh — `ws` must be able to run git in its own clone when another uid owns
# the clone's directory, which is how every cockpit terminal is built (root-owned emptyDir mount,
# arbitrary-uid shell).
#
# WHY IT EXISTS. git refuses a repo whose directory another user owns ("dubious ownership"), and
# ws's self-heal read that refusal as "not a git clone" and quietly did nothing. Every terminal kept
# the catalog it booted with: on 2026-11-15, user2 still listed 25 modules after the split, and
# `ws prep health-resources-autoscaling` died "unknown module". Nothing was red; it only looked like
# a broken workshop.
#
#   bash tools/ws/ws-clone-trust-selftest.sh              → the shipped tools/ws/ws
#                                                           (rc 0 contract holds · 1 broken · 2 cannot inspect)
#   bash tools/ws/ws-clone-trust-selftest.sh --self-test  → every assertion catches its canary (rc 1)
#
# HOW IT RUNS WITHOUT A CLUSTER OR A SECOND UID: GIT_TEST_ASSUME_DIFFERENT_OWNER=1 makes git treat
# every repo as owned by someone else, the cockpit's exact condition. This sources the SHIPPED ws
# (sourceable by its BASH_SOURCE guard) and runs git the way heal_clone does. The canary drops the
# trust ws exports, and must go red, which also proves the knob works on this git.
set -uo pipefail

WS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WS="${WS_DIR}/ws"

# check <canary 0|1> → prints one PASS/FAIL line per assertion; rc = number of failures
check() {
  (
    WS_REEXECED=1; KUBECONFIG=/dev/null; export WS_REEXECED KUBECONFIG
    # A caller's own command-scope entry: ws must append to it, not overwrite it.
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=ws-selftest
    # shellcheck source=/dev/null
    source "$WS" || exit 97
    if [[ "$1" == 1 ]]; then unset GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1; export GIT_CONFIG_COUNT=1; fi
    # Only ws's trust may count: actions/checkout adds a GLOBAL safe.directory for the workspace,
    # which would trust the clone on its own and make the canary unable to fail.
    export GIT_TEST_ASSUME_DIFFERENT_OWNER=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    f=0
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then echo "PASS git works in a clone another uid owns"
    else echo "FAIL git refused the clone (dubious ownership) — heal_clone would silently skip"; f=$((f+1)); fi
    if [[ "$(git -C "$REPO_ROOT" config user.name 2>/dev/null)" == ws-selftest ]]; then echo "PASS caller's GIT_CONFIG_* entry survived"
    else echo "FAIL caller's GIT_CONFIG_* entry was lost or unreadable"; f=$((f+1)); fi
    exit "$f"
  )
}

if [[ ! -r "$WS" ]] || ! git -C "$WS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "cannot inspect: needs ${WS} inside a git checkout"; exit 2
fi

case "${1:-}" in
  "")          check 0; rc=$?; [[ $rc -eq 0 ]] && exit 0; [[ $rc -eq 97 ]] && exit 2; exit 1 ;;
  --self-test) out="$(check 1)"; rc=$?; echo "$out"
               [[ $rc -eq 97 ]] && exit 2
               # Only the trust assertion has a canary; the caller-entry one must still pass.
               if grep -q '^FAIL git refused' <<<"$out" && grep -q '^PASS caller' <<<"$out"; then
                 echo "self-test ok — dropping ws's trust was caught"; exit 1
               fi
               echo "self-test BROKEN — the canary was not caught (does this git honour GIT_TEST_ASSUME_DIFFERENT_OWNER?)"; exit 2 ;;
  *)           echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
