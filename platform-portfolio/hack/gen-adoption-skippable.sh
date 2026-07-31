#!/usr/bin/env bash
# gen-adoption-skippable.sh — derive which components argocd-bootstrap/install.sh §0 is allowed to
# ADOPT-SKIP, using the installer's OWN classifier, and print it in the committed snapshot format.
# READ-ONLY: reads component directories, never touches a cluster.
#
#   WHY A SNAPSHOT EXISTS AT ALL. is_operator_only() classifies a component by FILENAME, so a
#   component's adoption eligibility is a property of its directory listing — and adding one
#   ordinary-looking file silently revokes it. That is the 2026-08-01 openshift-pipelines regression:
#   49a7e28 added tekton-config.yaml, the component stopped being skippable, and NOTHING said so.
#   hack/check-adoption-skip.sh stayed green the whole time, because it only ever proves that
#   whatever is CURRENTLY skippable is safe to skip — it has no memory of what used to be.
#   The consequence is not cosmetic: on a customer cluster that already runs that operator we stop
#   skipping the component and install our Subscription over theirs, re-channelling an operator we
#   promised not to touch.
#
#   WHY IT CANNOT ROT. The snapshot is never typed. It is emitted by this script, from
#   is_operator_only() itself — sourced, not re-implemented — over the real component tree, and
#   tools/lint/adoption-skippable-guard.sh re-derives it the same way on every CI run and diffs.
#   So the committed file cannot disagree with reality without reddening, the derivation cannot
#   drift from the installer's decision (there is only one), and a change to the set is a reviewable
#   diff line rather than an invisible property of a directory listing. A hand-maintained list would
#   have exactly the failure mode this guard exists to catch.
#
# Usage:
#   gen-adoption-skippable.sh                      # print the snapshot to stdout
#   gen-adoption-skippable.sh --write              # rewrite hack/adoption-skippable.snapshot
#   gen-adoption-skippable.sh --components-dir DIR # classify DIR's components instead (guard use)
#
# Exit 0 = snapshot emitted. Exit 2 = nothing to classify, or the classifier library is missing —
# never an empty snapshot, which would silently disarm the gate that reads it.
set -euo pipefail

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTFOLIO_DIR="$(cd "${HACK_DIR}/.." && pwd)"
LIB="${PORTFOLIO_DIR}/argocd-bootstrap/lib-components.sh"
SNAPSHOT="${HACK_DIR}/adoption-skippable.snapshot"
COMPONENTS_DIR="${PORTFOLIO_DIR}/components"
WRITE=0
COMPONENTS_OVERRIDDEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write) WRITE=1; shift ;;
    --components-dir)
      [[ $# -ge 2 ]] || { echo "❌ --components-dir needs a directory" >&2; exit 2; }
      COMPONENTS_DIR="$2"; COMPONENTS_OVERRIDDEN=1; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "❌ unknown argument: $1 — see --help" >&2; exit 2 ;;
  esac
done

# Writing the canonical snapshot from a scratch component tree would commit a verdict set that
# describes nothing shipped. The guard passes --components-dir; it never passes --write.
if [[ "$WRITE" -eq 1 && "$COMPONENTS_OVERRIDDEN" -eq 1 ]]; then
  echo "❌ --write and --components-dir are mutually exclusive: refusing to overwrite the shipped" >&2
  echo "   snapshot with verdicts derived from a different tree." >&2
  exit 2
fi

[[ -f "$LIB" ]] || { echo "❌ ${LIB} not found — the installer's classifier is what this derives from" >&2; exit 2; }
[[ -d "$COMPONENTS_DIR" ]] || { echo "❌ ${COMPONENTS_DIR} is not a directory" >&2; exit 2; }

# shellcheck disable=SC1090  # runtime-derived path; lib-components.sh is linted standalone
. "$LIB"

derive_verdicts() {  # <components-dir> → "<verdict> <component>" per line, LC_ALL=C sorted by component
  local dir="$1" d comp n=0 out=""
  for d in "$dir"/*/; do
    # A trailing slash is not cosmetic here: is_operator_only() strips "${dir}/" as a literal
    # prefix, so ".../cert-manager/" leaves every relative path unmatched and the component is
    # classified installs-more no matter what it contains. Measured 2026-08-01.
    d="${d%/}"
    [[ -d "$d" ]] || continue
    # The same file that makes a directory a component for the installer: no kustomization, no
    # child Application, nothing to adopt or skip.
    [[ -f "${d}/kustomization.yaml" ]] || continue
    comp="$(basename "$d")"
    n=$((n + 1))
    # Accumulated rather than piped straight into sort: an error path inside a pipeline's left-hand
    # subshell cannot stop the caller, and the failure mode it would leave behind is an EMPTY
    # snapshot that every consumer reads as "nothing is skippable" — green, and wrong.
    if is_operator_only "$d"; then
      out="${out}$(printf '%-13s %s' 'skippable' "$comp")"$'\n'
    else
      out="${out}$(printf '%-13s %s' 'installs-more' "$comp")"$'\n'
    fi
  done
  if [[ "$n" -eq 0 ]]; then
    echo "❌ no component (a directory with a kustomization.yaml) under ${dir}" >&2
    return 2
  fi
  # -b is load-bearing: without it a sort key starts at the leading BLANKS of field 2, so the
  # 4 spaces padding "skippable" sort ahead of the 1 space padding "installs-more" and the file comes
  # out grouped by verdict instead of by component. Sorted by component, a demotion is one line
  # changing in place — the diff a reviewer can actually read.
  printf '%s' "$out" | LC_ALL=C sort -b -k2,2
}

emit_header() {
  cat <<'HDR'
# platform-portfolio adoption-skippable snapshot — GENERATED, DO NOT HAND-EDIT.
#
# One line per component under platform-portfolio/components/, carrying the verdict
# argocd-bootstrap/install.sh §0 uses to decide whether it may SKIP that component on a cluster that
# already runs the operator:
#
#   skippable      is_operator_only() = true. The component installs an operator and NOTHING else,
#                  so dropping it on an adopting cluster loses nothing.
#   installs-more  The component also ships operands, config, RBAC or workloads. It is NOT skippable;
#                  on a cluster already running that operator the portfolio installs over it.
#
# Regenerate, then READ THE DIFF:  platform-portfolio/hack/gen-adoption-skippable.sh --write
# Gate: tools/lint/adoption-skippable-guard.sh (CI job `adoption-skippable`).
#
# skippable → installs-more is a REGRESSION unless it was intended: it means one added file revoked
# a component's adoption eligibility, and the customer cluster that already runs that operator now
# gets our Subscription applied over theirs. That is exactly what shipped unnoticed on 2026-08-01
# (openshift-pipelines, 49a7e28). Do not regenerate a demotion away without saying why in the commit.
HDR
}

if [[ "$WRITE" -eq 1 ]]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  { emit_header; derive_verdicts "$COMPONENTS_DIR"; } > "$tmp"
  mv "$tmp" "$SNAPSHOT"
  trap - EXIT
  echo "✅ wrote ${SNAPSHOT} ($(grep -c '^skippable' "$SNAPSHOT") skippable, $(grep -c '^installs-more' "$SNAPSHOT") installs-more)"
  echo "   ↳ review the diff before committing — a skippable → installs-more line is an adoption regression."
  exit 0
fi

emit_header
derive_verdicts "$COMPONENTS_DIR"
