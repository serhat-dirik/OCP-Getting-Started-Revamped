#!/usr/bin/env bash
# CANARY. A second definition of the shared reader. This is precisely how the original defect got
# in: one derivation in a library, a hand-rolled one beside it, and the two drift.
set -euo pipefail

active_app_files() {
  grep -E '^  - apps/' "${STACKS_DIR}/${1}/kustomization.yaml" | sed 's|^  - ||'
}
