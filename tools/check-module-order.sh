#!/usr/bin/env bash
# check-module-order.sh — the guard that keeps the Antora nav in sync with modules.yaml.
#
# modules.yaml is the SINGLE SOURCE OF TRUTH for module order (position = number, decoupled
# from slug — owner decision 2026-07-17). The sidebar nav is hand-maintained AsciiDoc, so the
# two can drift. This check asserts they agree:
#   • nav-workshop.adoc (the canonical teaching order) MUST equal modules.yaml order exactly.
#   • nav-demo.adoc / nav-instructor.adoc MUST be an in-order SUBSEQUENCE of modules.yaml
#     (they render the same order today but may present presenter/instructor subsets later).
# Every slug referenced by any nav MUST exist in modules.yaml.
#
# Runnable standalone (CI lint gate) and by `ws`; dependency-light — yq v4 if present, else a
# tiny awk fallback (no hard yq dependency, matching the ws CLI's graceful-degradation idiom).
#
# --self-test builds a throwaway modules.yaml + nav fixture tree under mktemp, proves the check
# passes on a correctly-ordered fixture, then proves it FAILS on a genuine cross-module reorder —
# two DIFFERENT slugs swapped, not the same-slug no-op swap that produced a false negative on this
# guard's first hand-test (nothing had actually changed, so of course nothing fired). Never reads
# or writes the real tree. Exit 1 = both proofs held (detects the swap, stays quiet on the good
# fixture) — this is a *pass*, matching the house convention of other tools/lint/*.py self-tests,
# where CI asserts the self-test step itself exits exactly 1. Exit 2 = the guard is blind or the
# fixture harness itself is broken.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok()  { echo "✅ $*"; }
err() { echo "❌ $*" >&2; }

# Ordered slug list from modules.yaml. yq v4 if available; otherwise parse the flat list with
# awk (each entry is `- slug: <slug>` on its own line, in order — see modules.yaml).
manifest_slugs() {  # modules_yaml →
  local modules_yaml="$1"
  if command -v yq >/dev/null 2>&1; then
    yq -r '.modules[].slug' "$modules_yaml"
  else
    awk '/^[[:space:]]*-[[:space:]]*slug:[[:space:]]*/ {
           s=$0; sub(/^.*slug:[[:space:]]*/,"",s); gsub(/["'\''[:space:]]/,"",s); print s
         }' "$modules_yaml"
  fi
}

# Ordered, de-duplicated slugs as they first appear in a nav file's xref link targets
# (`xref:<slug>/<page>.adoc[...]`). `xref:index.adoc[...]` has no slug segment and is skipped.
nav_slugs() {  # navfile →
  grep -oE 'xref:[a-z0-9][a-z0-9-]*/' "$1" 2>/dev/null \
    | sed -E 's#^xref:##; s#/$##' \
    | awk '!seen[$0]++'
}

# demo/instructor navs MUST be an in-order subsequence of modules.yaml, all slugs known. Reads
# and mutates the caller's local `fail`/`mapfile_manifest` via bash's dynamic scoping (this is
# only ever called from inside run_check, same as the pre-refactor global-var version).
check_subsequence() {  # navfile →
  local nav="$1" name; name="$(basename "$nav")"
  [[ -f "$nav" ]] || { err "missing $nav"; fail=1; return; }
  local nav_order; nav_order="$(nav_slugs "$nav")"
  # Walk the manifest once; every nav slug must appear, in order. An unknown or out-of-order
  # slug leaves the pointer unmatched at the end.
  local remaining="$mapfile_manifest" s hit=0 miss=""
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if grep -qxF "$s" <<< "$mapfile_manifest"; then
      # advance `remaining` past this slug; if not found ahead, it's out of order
      if grep -qxF "$s" <<< "$remaining"; then
        remaining="$(awk -v k="$s" 'found{print} $0==k{found=1}' <<< "$remaining")"
      else
        miss="${miss} ${s}(order)"; hit=1
      fi
    else
      miss="${miss} ${s}(unknown)"; hit=1
    fi
  done <<< "$nav_order"
  if [[ "$hit" == 0 ]]; then
    ok "${name} is an in-order subset of modules.yaml ($(echo "$nav_order" | grep -c .) modules)"
  else
    err "${name} disagrees with modules.yaml:${miss}"; fail=1
  fi
}

# Runs the full order/subsequence check against a given modules.yaml + nav directory. Prints
# ✅/❌ lines and returns 0 (consistent), 1 (drift found), or 2 (missing/empty manifest).
run_check() {  # modules_yaml nav_dir →
  local modules_yaml="$1" nav_dir="$2"
  [[ -f "$modules_yaml" ]] || { err "modules.yaml not found ($modules_yaml)"; return 2; }

  local fail=0 mapfile_manifest
  mapfile_manifest="$(manifest_slugs "$modules_yaml")"
  [[ -n "$mapfile_manifest" ]] || { err "modules.yaml lists no modules"; return 2; }

  # 1) nav-workshop MUST equal modules.yaml exactly.
  local workshop_nav="${nav_dir}/nav-workshop.adoc"
  if [[ -f "$workshop_nav" ]]; then
    local nav_order
    nav_order="$(nav_slugs "$workshop_nav")"
    if [[ "$nav_order" == "$mapfile_manifest" ]]; then
      ok "nav-workshop.adoc order matches modules.yaml ($(echo "$mapfile_manifest" | grep -c .) modules)"
    else
      err "nav-workshop.adoc order does NOT match modules.yaml — reconcile the two (position = number)."
      echo "   --- diff (< modules.yaml   > nav-workshop) ---" >&2
      diff <(echo "$mapfile_manifest") <(echo "$nav_order") >&2 || true
      fail=1
    fi
  else
    err "missing $workshop_nav"; fail=1
  fi

  # 2) demo + instructor navs.
  check_subsequence "${nav_dir}/nav-demo.adoc"
  check_subsequence "${nav_dir}/nav-instructor.adoc"

  if [[ "$fail" == 0 ]]; then
    ok "module order is consistent across modules.yaml and all navs"
    return 0
  fi
  err "module-order check FAILED — see above."
  return 1
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/partials"
  cat > "$tmp/modules.yaml" <<'YAML'
modules:
  - slug: alpha
  - slug: bravo
  - slug: charlie
YAML

  # GOOD fixture: nav-workshop matches modules.yaml exactly; demo/instructor are in-order subsets.
  cat > "$tmp/partials/nav-workshop.adoc" <<'ADOC'
* xref:alpha/concept.adoc[Alpha]
* xref:bravo/concept.adoc[Bravo]
* xref:charlie/concept.adoc[Charlie]
ADOC
  cp "$tmp/partials/nav-workshop.adoc" "$tmp/partials/nav-demo.adoc"
  cp "$tmp/partials/nav-workshop.adoc" "$tmp/partials/nav-instructor.adoc"

  local good_rc=0
  run_check "$tmp/modules.yaml" "$tmp/partials" >/dev/null 2>&1 || good_rc=$?

  # BAD fixture: swap bravo and charlie — a genuine cross-module reorder of two DIFFERENT slugs.
  # (Swapping two lines that share the same slug would be a no-op and prove nothing — that is
  # exactly the false negative this guard's first hand-test produced.)
  cat > "$tmp/partials/nav-workshop.adoc" <<'ADOC'
* xref:alpha/concept.adoc[Alpha]
* xref:charlie/concept.adoc[Charlie]
* xref:bravo/concept.adoc[Bravo]
ADOC

  local bad_rc=0
  run_check "$tmp/modules.yaml" "$tmp/partials" >/dev/null 2>&1 || bad_rc=$?

  if [[ "$good_rc" -ne 0 ]]; then
    err "SELF-TEST FAILED: the correctly-ordered fixture was wrongly flagged (rc=$good_rc)."
    return 2
  fi
  if [[ "$bad_rc" -ne 1 ]]; then
    err "SELF-TEST FAILED: the two-slug reorder canary was NOT detected (rc=$bad_rc) — the guard is blind."
    return 2
  fi
  ok "self-test ok — correctly-ordered fixture passes (rc=0) and the swapped-order canary is caught (rc=1)."
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

MODULES_YAML="${WS_MODULES_YAML:-${REPO_ROOT}/modules.yaml}"
NAV_DIR="${REPO_ROOT}/content/modules/ROOT/partials"
run_check "$MODULES_YAML" "$NAV_DIR"
exit $?
