#!/usr/bin/env bash
# Make sure {user}-cicd holds a finished, green PipelineRun of the module's five-Task pipeline —
# and DO NOT rebuild one if it already does.
#
# WHY THE SKIP MATTERS. `ws solve pipelines-fundamentals` runs the real build-test-deploy pipeline:
# ~9 minutes warm, up to ~13 cold (ws-meta declares waitSeconds: 1200). The shot that needs it is
# blocked on a human OAuth login, and a human's window is the scarce resource in this whole pass —
# spending the first quarter-hour of it rebuilding a run that is already sitting in the namespace is
# exactly the waste RUNBOOK.md's Phase 0 exists to prevent. So this script asks first.
#
# Usage: tools/media/stage-pipelines-fundamentals.sh <user>
#
# Note it deliberately does NOT purge on the happy path. `ws start pipelines-fundamentals` purges
# {user}-cicd and evicts trusted-supply-chain / app-security-testing (declared both ways in
# ws-meta.yaml), so re-running it for no reason destroys another module's state as a side effect.

set -euo pipefail

USER_SLOT="${1:?usage: stage-pipelines-fundamentals.sh <user>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="${USER_SLOT}-cicd"

# A run counts only if its Succeeded condition is True. "A PipelineRun exists" is not the same claim:
# a failed or still-running one photographs as the wrong picture, and url_sh cannot tell them apart.
green_run() {
  oc -n "$NS" get pipelinerun \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' \
    2>/dev/null | awk '$2=="True"{print $1}' | tail -1
}

existing="$(green_run || true)"
if [ -n "$existing" ]; then
  echo "  [stage:m07] reusing the green run already in ${NS}: ${existing}"
  exit 0
fi

echo "  [stage:m07] no green run in ${NS} — materialising and solving (this can take ~13 min)"
"${REPO_ROOT}/tools/ws/ws" start pipelines-fundamentals --user "$USER_SLOT"
"${REPO_ROOT}/tools/ws/ws" solve pipelines-fundamentals --user "$USER_SLOT"

run="$(green_run || true)"
if [ -z "$run" ]; then
  echo "  [stage:m07] solve finished but no Succeeded PipelineRun is present — do not shoot"
  oc -n "$NS" get pipelinerun
  exit 1
fi
echo "  [stage:m07] green run: ${run}"
