#!/usr/bin/env bash
# seed-drift-guard.sh — prove that hand-copied seed files are still byte-identical to their source.
#
# Some GitOps entry states cannot mount an app's resources directly, so they carry a COPY of a
# file that lives in apps/. A copy that nobody diffs drifts, and this class of drift is silent:
# the chart renders, Argo syncs, the Job reports success, and the difference only shows up as a
# broken exercise in the room.
#
# It has already happened once. gitops/entry-states/deployment-targets-scheduling/files/import.sql
# is described in its own chart as "synced from apps/parasol-claims/src/main/resources/import.sql",
# and it silently lost the CREATE SEQUENCE for claim_number_seq that POST /api/claims draws its
# numbers from — in the one entry state (solve) where the app runs schema-management=none and this
# copy is the ONLY thing that creates it.
#
# Usage:
#   tools/lint/seed-drift-guard.sh              # check every declared pair; non-zero on drift
#   tools/lint/seed-drift-guard.sh --self-test  # prove detection works; MUST exit 1
#
# Exit codes (deliberately the same contract as tools/lint/curl-format-guard.py, so the workflow
# steps read alike):
#   0  every declared pair is identical / self-test not requested
#   1  drift found — or, under --self-test, the canary was correctly detected
#   2  the guard could not do its job (a declared file is missing, the pair list is empty, or the
#      self-test canary went UNdetected). Never confuse this with a clean result.
#
# Adding a pair: append "source|copy" to PAIRS below, both paths relative to the repo root.
set -euo pipefail

# Every hand-maintained copy that must match its source, as "source|copy".
PAIRS=(
  "apps/parasol-claims/src/main/resources/import.sql|gitops/entry-states/deployment-targets-scheduling/files/import.sql"
)

repo_root() {
  git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel
}

# Report drift between two files. 0 = identical, 1 = differs. Prints a diff when they differ.
compare_pair() {
  local source="$1" copy="$2"
  if cmp -s "$source" "$copy"; then
    return 0
  fi
  echo "DRIFT: $copy is no longer a byte-identical copy of $source"
  diff -u "$source" "$copy" | sed 's/^/    /' || true
  return 1
}

# Prove the comparison actually fires: copy a real pair into a temp dir, drop one line from the
# copy, and check that compare_pair says so. A guard whose detector is broken reports "clean"
# forever, which is worse than no guard at all.
self_test() {
  local root="$1" tmp source_rel copy_rel
  IFS='|' read -r source_rel copy_rel <<< "${PAIRS[0]}"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now, on purpose: the trap must survive the function
  trap "rm -rf '$tmp'" RETURN

  cp "$root/$source_rel" "$tmp/source"
  # The canary: the copy is missing one line — exactly the shape of the real 2026-07-29 drift,
  # where the copy had lost its CREATE SEQUENCE statement.
  grep -v '^CREATE SEQUENCE' "$root/$source_rel" > "$tmp/copy"

  if cmp -s "$tmp/source" "$tmp/copy"; then
    echo "::error::seed-drift-guard self-test could not build a canary — $source_rel has no" \
         "CREATE SEQUENCE line to drop, so the fixture is identical to its source."
    return 2
  fi

  echo "self-test: comparing a deliberately drifted copy of $source_rel…"
  if compare_pair "$tmp/source" "$tmp/copy" > /dev/null 2>&1; then
    echo "::error::seed-drift-guard SELF-TEST FAILED — a copy with a line removed compared as" \
         "identical. The guard is blind; a clean result on the real tree means nothing."
    return 2
  fi

  # Same detector, matching files: must come back clean, or the guard cries wolf on every commit.
  cp "$root/$source_rel" "$tmp/copy"
  if ! compare_pair "$tmp/source" "$tmp/copy" > /dev/null 2>&1; then
    echo "::error::seed-drift-guard SELF-TEST FAILED — two identical files compared as drifted."
    return 2
  fi

  echo "self-test ok — the guard rejected its canary and passed an identical pair."
  return 1
}

main() {
  local root checked=0 drifted=0 source_rel copy_rel pair
  root="$(repo_root)"

  if [ "${#PAIRS[@]}" -eq 0 ]; then
    echo "::error::seed-drift-guard has no pairs declared — refusing to report clean over an" \
         "empty scope."
    return 2
  fi

  if [ "${1:-}" = "--self-test" ]; then
    self_test "$root"
    return $?
  fi

  for pair in "${PAIRS[@]}"; do
    IFS='|' read -r source_rel copy_rel <<< "$pair"
    if [ ! -f "$root/$source_rel" ]; then
      echo "::error::seed-drift-guard: declared source $source_rel does not exist. It was moved" \
           "or renamed; update PAIRS in $0 rather than leaving the gate pointing at nothing."
      return 2
    fi
    if [ ! -f "$root/$copy_rel" ]; then
      echo "::error::seed-drift-guard: declared copy $copy_rel does not exist. It was moved or" \
           "renamed; update PAIRS in $0 rather than leaving the gate pointing at nothing."
      return 2
    fi
    checked=$((checked + 1))
    if ! compare_pair "$root/$source_rel" "$root/$copy_rel"; then
      drifted=$((drifted + 1))
    fi
  done

  if [ "$drifted" -gt 0 ]; then
    echo
    echo "::error::$drifted of $checked seed copies drifted from their source. Re-copy the file" \
         "(cp source copy) — never hand-edit the copy — and bump the chart version so Argo's" \
         "manifest cache picks the change up."
    return 1
  fi

  echo "seed-drift-guard: clean ($checked pair(s) checked, byte-identical)."
  return 0
}

main "$@"
