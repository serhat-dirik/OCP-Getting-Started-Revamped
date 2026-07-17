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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_YAML="${WS_MODULES_YAML:-${REPO_ROOT}/modules.yaml}"
NAV_DIR="${REPO_ROOT}/content/modules/ROOT/partials"

ok()  { echo "✅ $*"; }
err() { echo "❌ $*" >&2; }

[[ -f "$MODULES_YAML" ]] || { err "modules.yaml not found ($MODULES_YAML)"; exit 2; }

# Ordered slug list from modules.yaml. yq v4 if available; otherwise parse the flat list with
# awk (each entry is `- slug: <slug>` on its own line, in order — see modules.yaml).
manifest_slugs() {
  if command -v yq >/dev/null 2>&1; then
    yq -r '.modules[].slug' "$MODULES_YAML"
  else
    awk '/^[[:space:]]*-[[:space:]]*slug:[[:space:]]*/ {
           s=$0; sub(/^.*slug:[[:space:]]*/,"",s); gsub(/["'\''[:space:]]/,"",s); print s
         }' "$MODULES_YAML"
  fi
}

# Ordered, de-duplicated slugs as they first appear in a nav file's xref link targets
# (`xref:<slug>/<page>.adoc[...]`). `xref:index.adoc[...]` has no slug segment and is skipped.
nav_slugs() {  # navfile →
  grep -oE 'xref:[a-z0-9][a-z0-9-]*/' "$1" 2>/dev/null \
    | sed -E 's#^xref:##; s#/$##' \
    | awk '!seen[$0]++'
}

fail=0
mapfile_manifest="$(manifest_slugs)"
[[ -n "$mapfile_manifest" ]] || { err "modules.yaml lists no modules"; exit 2; }

# 1) nav-workshop MUST equal modules.yaml exactly.
workshop_nav="${NAV_DIR}/nav-workshop.adoc"
if [[ -f "$workshop_nav" ]]; then
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

# 2) demo + instructor navs MUST be an in-order subsequence of modules.yaml, all slugs known.
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
check_subsequence "${NAV_DIR}/nav-demo.adoc"
check_subsequence "${NAV_DIR}/nav-instructor.adoc"

if [[ "$fail" == 0 ]]; then
  ok "module order is consistent across modules.yaml and all navs"
  exit 0
fi
err "module-order check FAILED — see above."
exit 1
