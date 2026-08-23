#!/usr/bin/env bash
# shellcheck shell=bash
# CI shellchecks every tracked *.sh, and these are FIXTURES: they source a relative library
# that is not on shellcheck's input list (SC1091), and c3 leaves a variable unused ON PURPOSE
# because modelling a caller that never sources the reader is the entire canary (SC2034).
# shellcheck disable=SC1091,SC2034
# CANARY. Calls the reader and never sources it. Under `set -u` an undefined command is a 127, and
# inside a process substitution that reads as "this stack ships no apps" — a silent empty answer.
set -euo pipefail
STACKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../platform-portfolio/stacks" && pwd)"

report() {
  local stack="$1" rel
  while IFS= read -r rel; do
    echo "$rel"
  done < <(active_app_files "$stack")
}
