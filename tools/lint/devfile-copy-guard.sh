#!/usr/bin/env bash
# The devspaces-inner-loop entry chart carries a COPY of the attendee's devfile, because Helm can
# only read files inside its own chart directory. The chart splices that file's components and
# commands into the DevWorkspace it declares, so the workspace an attendee is handed is exactly what
# their repo describes — same image, same Java 21 pinning, same Quarkus dev-mode command.
#
# A copy drifts. If someone edits apps/parasol-claims/devfile.yaml (adds a component, bumps the UDI
# tag with the Dev Spaces version) and the chart copy stays behind, the attendee's workspace quietly
# stops matching the devfile the lab tells them to read — and exercise 4, which has them edit that
# devfile and restart from it, starts from a different place than the page describes. Nothing fails;
# it just silently teaches the wrong thing.
#
# Exit codes: 0 the two files are identical · 1 they have drifted, or under --self-test the canary
# was correctly caught · 2 this guard could not inspect what it claims to (a file is missing).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="apps/parasol-claims/devfile.yaml"
COPY="gitops/entry-states/devspaces-inner-loop/files/devfile.yaml"

ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; }

compare() { # compare <root> — 0 identical, 1 drifted, 2 cannot inspect
  local root="$1"
  if [[ ! -f "${root}/${SOURCE}" ]]; then bad "missing ${SOURCE}"; return 2; fi
  if [[ ! -f "${root}/${COPY}" ]]; then
    bad "missing ${COPY} — the chart cannot render its DevWorkspace without it"; return 2
  fi
  if cmp -s "${root}/${SOURCE}" "${root}/${COPY}"; then return 0; fi
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  # A guard that has never been shown to fire cannot certify a clean tree.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/$(dirname "$SOURCE")" "$tmp/$(dirname "$COPY")"
  printf 'schemaVersion: 2.2.0\ncomponents: [a]\n' > "$tmp/$SOURCE"
  cp "$tmp/$SOURCE" "$tmp/$COPY"

  compare "$tmp" >/dev/null; clean_rc=$?
  # Canary: drift the copy by one line, exactly as a forgotten edit would.
  printf 'components: [a, b]\n' >> "$tmp/$COPY"
  compare "$tmp" >/dev/null; drift_rc=$?
  # Canary: remove the copy entirely.
  rm -f "$tmp/$COPY"
  compare "$tmp" >/dev/null; gone_rc=$?

  fail=0
  [[ "$clean_rc" -eq 0 ]] && ok "identical copies pass"        || { bad "identical copies did NOT pass (rc=$clean_rc)"; fail=1; }
  [[ "$drift_rc"  -eq 1 ]] && ok "a drifted copy is caught"     || { bad "drift was NOT caught (rc=$drift_rc)"; fail=1; }
  [[ "$gone_rc"   -eq 2 ]] && ok "a missing copy is caught"     || { bad "missing copy was NOT caught (rc=$gone_rc)"; fail=1; }
  if [[ "$fail" -ne 0 ]]; then
    bad "self-test FAILED — this guard cannot be trusted on the real tree"
    exit 2
  fi
  printf '  devfile-copy-guard: self-test passed (every canary caught)\n'
  exit 1   # by convention: a successful self-test exits 1, so CI can assert detection works
fi

compare "$REPO_ROOT"; rc=$?
case "$rc" in
  0) printf 'devfile-copy-guard: clean (%s matches %s).\n' "$COPY" "$SOURCE" ;;
  1) bad "${COPY} has DRIFTED from ${SOURCE}"
     printf '\n%s\n' "  The entry chart splices the copy into the DevWorkspace it declares, so the attendee's"
     printf '%s\n'   "  workspace would no longer match the devfile the lab has them read and edit."
     printf '%s\n\n' "  Fix: cp ${SOURCE} ${COPY}"
     diff -u "${REPO_ROOT}/${COPY}" "${REPO_ROOT}/${SOURCE}" | head -20 ;;
esac
exit "$rc"
