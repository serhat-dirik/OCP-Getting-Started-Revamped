#!/usr/bin/env bash
# CANARY. Partially converted, which is the realistic reintroduction: one walk on the shared reader,
# a second one still globbing. The glob is written exactly as the shipped defect was — with the
# closing quote INSIDE the path, ahead of the /*.yaml — so this fixture also proves the scanner's
# quote-stripping, not just its regex.
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

snapshot_namespaces() {
  local stack="$1" app
  for app in "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps"/*.yaml; do
    [[ -e "$app" ]] || continue
    echo "would record namespaces from $app"
  done
}
