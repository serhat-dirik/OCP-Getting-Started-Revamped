#!/usr/bin/env bash
# Skeleton peer 2, in the CONVERTED shape: the same reader from the same file as peer 1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKS_DIR="${SCRIPT_DIR}/../platform-portfolio/stacks"
. "${SCRIPT_DIR}/../platform-portfolio/argocd-bootstrap/lib-components.sh"

enumerate_operators() {
  local stack="$1" rel
  while IFS= read -r rel; do
    echo "would enumerate from ${STACKS_DIR}/${stack}/${rel}"
  done < <(active_app_files "$stack")
}
