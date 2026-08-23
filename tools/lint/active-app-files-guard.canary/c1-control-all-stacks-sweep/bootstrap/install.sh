#!/usr/bin/env bash
# shellcheck shell=bash
# CI shellchecks every tracked *.sh, and these are FIXTURES: they source a relative library
# that is not on shellcheck's input list (SC1091), and c3 leaves a variable unused ON PURPOSE
# because modelling a caller that never sources the reader is the entire canary (SC2034).
# shellcheck disable=SC1091,SC2034
# CONTROL, not a canary. Two legitimate all-stacks sweeps of the kind this repo really ships:
# owning_stack_of_app() (a reverse lookup for a fix hint) and check-teardown-invariants.sh's
# "every AUTHORED child Application declares a sync-wave" walk. Both ask a question the DIRECTORY is
# the right authority for, and a disabled app file must satisfy both on the day someone enables it.
# If this case ever produces a finding, the guard has started reddening on correct work.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKS_DIR="${SCRIPT_DIR}/../platform-portfolio/stacks"
PORTFOLIO_DIR="${SCRIPT_DIR}/../platform-portfolio"
. "${SCRIPT_DIR}/../platform-portfolio/argocd-bootstrap/lib-components.sh"

snapshot_operators() {
  local stack="$1" rel
  while IFS= read -r rel; do
    echo "would record from ${STACKS_DIR}/${stack}/${rel}"
  done < <(active_app_files "$stack")
}

owning_stack_of_app() {
  local app="$1" f
  for f in "${SCRIPT_DIR}/../platform-portfolio/stacks"/*/apps/*.yaml; do
    [[ -e "$f" ]] || continue
    grep -q "name: ${app}" "$f" || continue
    basename "$(dirname "$(dirname "$f")")"; return 0
  done
  echo "<unknown>"
}

every_app_declares_a_wave() {
  local app
  for app in "${PORTFOLIO_DIR}"/stacks/*/apps/*.yaml; do
    [[ -e "$app" ]] || continue
    grep -q 'sync-wave' "$app" || echo "no wave: $app"
  done
}
