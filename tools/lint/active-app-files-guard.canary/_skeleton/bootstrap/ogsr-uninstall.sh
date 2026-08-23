#!/usr/bin/env bash
# shellcheck shell=bash
# CI shellchecks every tracked *.sh, and these are FIXTURES: they source a relative library
# that is not on shellcheck's input list (SC1091), and c3 leaves a variable unused ON PURPOSE
# because modelling a caller that never sources the reader is the entire canary (SC2034).
# shellcheck disable=SC1091,SC2034
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
