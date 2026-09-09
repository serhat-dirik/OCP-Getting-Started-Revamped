#!/usr/bin/env bash
# FIXTURE for tools/lint/stack-wiring-guard.py. The BASELINE stacks are always installed and are
# read out of this initialiser rather than assumed, so a broken RE_BASELINE would silently shrink
# what the guard thinks install.sh can enable. Here 'progressive-delivery' is in the baseline and
# has no directory on disk: wired-but-absent fires ONLY if the baseline was actually parsed, which
# is what makes this fixture RE_BASELINE's witness.
set -euo pipefail
stack_toggle() { echo "true"; }
AUTH="$(stack_toggle auth auth)"
STACKS="core-devtools,batch,progressive-delivery"
[[ "$AUTH" == "true" ]] && STACKS="${STACKS},auth"
echo "$STACKS"
