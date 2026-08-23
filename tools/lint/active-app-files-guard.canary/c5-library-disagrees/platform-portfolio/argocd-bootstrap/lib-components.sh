#!/usr/bin/env bash
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
