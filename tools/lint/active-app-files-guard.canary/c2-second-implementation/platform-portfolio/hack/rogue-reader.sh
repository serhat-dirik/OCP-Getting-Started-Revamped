#!/usr/bin/env bash
# shellcheck shell=bash
# CI shellchecks every tracked *.sh, and these are FIXTURES: they source a relative library
# that is not on shellcheck's input list (SC1091), and c3 leaves a variable unused ON PURPOSE
# because modelling a caller that never sources the reader is the entire canary (SC2034).
# shellcheck disable=SC1091,SC2034
# CANARY. A second definition of the shared reader. This is precisely how the original defect got
# in: one derivation in a library, a hand-rolled one beside it, and the two drift.
set -euo pipefail

active_app_files() {
  grep -E '^  - apps/' "${STACKS_DIR}/${1}/kustomization.yaml" | sed 's|^  - ||'
}
