#!/usr/bin/env bash
# FIXTURE for tools/lint/stack-wiring-guard.py — a miniature bootstrap/install.sh, never executed by
# the workshop. It carries only the two shapes the guard parses: the STACKS baseline and the
# conditional appends.
set -euo pipefail
stack_toggle() { echo "true"; }
AUTH="$(stack_toggle auth auth)"
TRUST="$(stack_toggle trust trust)"
GHOST="$(stack_toggle ghost ghost)"
STACKS="core-devtools,batch,progressive-delivery"
[[ "$AUTH" == "true" ]] && STACKS="${STACKS},auth"
[[ "$TRUST" == "true" ]] && STACKS="${STACKS},trust"
[[ "$GHOST" == "true" ]] && STACKS="${STACKS},ghost"
echo "$STACKS"
