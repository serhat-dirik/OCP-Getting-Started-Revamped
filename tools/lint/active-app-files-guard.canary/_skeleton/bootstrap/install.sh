#!/usr/bin/env bash
# Skeleton peer 1, in the CONVERTED shape: sources the shared reader, never globs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKS_DIR="${SCRIPT_DIR}/../platform-portfolio/stacks"
. "${SCRIPT_DIR}/../platform-portfolio/argocd-bootstrap/lib-components.sh"

snapshot_operators() {
  local stack="$1" rel
  while IFS= read -r rel; do
    echo "would record from ${STACKS_DIR}/${stack}/${rel}"
  done < <(active_app_files "$stack")
}
