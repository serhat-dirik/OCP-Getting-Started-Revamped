#!/usr/bin/env bash
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
