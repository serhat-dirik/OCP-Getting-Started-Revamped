#!/usr/bin/env bash
# shellcheck shell=bash
# CI shellchecks every tracked *.sh, and these are FIXTURES: they source a relative library
# that is not on shellcheck's input list (SC1091), and c3 leaves a variable unused ON PURPOSE
# because modelling a caller that never sources the reader is the entire canary (SC2034).
# shellcheck disable=SC1091,SC2034
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
