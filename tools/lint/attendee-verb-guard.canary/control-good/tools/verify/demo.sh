#!/usr/bin/env bash
# FIXTURE for tools/lint/attendee-verb-guard.py — not a real verify script.
set -euo pipefail
USER_NAME="${1:-user1}"
NS="${USER_NAME}-dev"
hint() { echo "$*"; }
check() { :; }
check "namespace exists" oc get ns "$NS" || hint "run: ws prep demo (or ws start demo --user ${USER_NAME})"
check "marker present" oc get cm ws-entry-demo -n "$NS" || hint "ws reset demo"
