#!/usr/bin/env bash
# CANARY. The teardown half reverted to a hardcoded list while the install half stayed on the shared
# reader. No glob anywhere, so PER-STACK-GLOB cannot see it — and yet the two halves now disagree
# about what a stack shipped, which is the whole thing the contract forbids.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

enumerate_operators() {
  local stack="$1" rel
  for rel in apps/enabled.yaml apps/disabled.yaml; do
    echo "would enumerate from ${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/${rel}"
  done
}
