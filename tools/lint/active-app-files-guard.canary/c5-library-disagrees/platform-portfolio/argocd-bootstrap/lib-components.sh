#!/usr/bin/env bash
# shellcheck shell=bash
# CI shellchecks every tracked *.sh, and these are FIXTURES: they source a relative library
# that is not on shellcheck's input list (SC1091), and c3 leaves a variable unused ON PURPOSE
# because modelling a caller that never sources the reader is the entire canary (SC2034).
# shellcheck disable=SC1091,SC2034
# CANARY. The shared reader rewritten to answer from the DIRECTORY. Every textual check in the guard
# stays green — one definition, in the right file, and every consumer sources and calls it — while
# every consumer silently inherits the original defect. Only executing it can see this.
active_app_files() {
  local f
  for f in "${STACKS_DIR}/${1}/apps"/*.yaml; do
    [[ -e "$f" ]] || continue
    echo "apps/$(basename "$f")"
  done
}
