#!/usr/bin/env bash
# FIXTURE for tools/lint/attendee-verb-guard.py — not a real verify script.
set -euo pipefail
USER_NAME="${1:-user1}"
NS="${USER_NAME}-dev"
hint() { echo "$*"; }
check() { :; }
check "solved marker" oc get cm ws-solve-demo -n "$NS" || hint "run: ws solve demo --user ${USER_NAME}"
