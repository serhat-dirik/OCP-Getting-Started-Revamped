#!/usr/bin/env bash
#
# gen-attributes.sh — generate the AsciiDoc product-version attribute partial from
# versions.yaml (the single source of truth, 01-ARCHITECTURE §6).
#
# Content references product versions ONLY through these attributes (04-STYLE-GUIDE §5):
# a page writes `{gitops_version}`, never the literal "1.21.1".
#
# ---------------------------------------------------------------------------------------------
# TWO FAMILIES OF ATTRIBUTE, from two different fields. Telling them apart IS the point.
# ---------------------------------------------------------------------------------------------
#
#   :<key>_version:   <- versions.yaml `version:`   the GROUNDED-ON READING — what we last SAW
#   :<key>_minimum:   <- versions.yaml `minimum:`   the SUPPORT FLOOR — what we PROMISE
#
# One `:<key>_version:` per top-level entry that has a `version:` field (entries without one —
# zap / gateway_api / udn / maas / the ocp_* core-feature rows — are skipped), and one
# `:<key>_minimum:` per entry that has a `minimum:` field. Most entries have only the first.
#
# WHY THE SPLIT EXISTS, measured: `startingCSV` appears ZERO times in this repository. All 24
# Subscriptions under platform-portfolio/ resolve from an OLM channel — or from the package's
# defaultChannel where `spec.channel` is deliberately omitted — with `installPlanApproval:
# Automatic`, so OLM z-stream-upgrades them in place and nothing caps them. A `version:` is
# therefore what we observed on the day we looked, a build-time snapshot, and NOT what the
# reader's cluster runs. Two entries drifted unattended to prove it: the Service Mesh operator
# walked 3.3.5 -> 3.4.0 -> 3.4.1 on its own, and RHDH went 1.9.7 -> 1.10.3 when its `fast`
# channel rolled. A `minimum:` moves only when a human decides to raise it.
#
# THE AUTHORING RULE:
#   * Prose that names a release FOR THE READER renders the FLOOR — "{service_mesh_minimum} or
#     newer". A floor is a promise this project can keep on a cluster it has never seen.
#   * A dated record of what WE ran is a FROZEN LITERAL beside its date ("performed on OpenShift
#     4.22.5, 2026-07-31") — never an attribute of either family. An attribute there silently
#     re-dates the record every time versions.yaml moves, converting a measurement into a claim
#     about a release nobody ran it on.
#   * The GROUNDED-ON reading is for MAINTAINERS, not pages. `{<key>_version}` earns a place in
#     rendered prose only where the value is REPO-pinned and so genuinely predicts what the
#     reader will see — {quarkus_version} (eight poms under apps/, images built in-cluster from
#     this repo) and {istio_version} (the Sail Istio CR names an exact patch, so the data plane
#     does not float the way the operator does). Where a CHANNEL decides the value, it does not.
#
# NOT EMITTED, deliberately — do not "complete" these:
#   * `grounded_on:` (ocp only). It is the maintainer's reading of the build cluster. Minting
#     {ocp_grounded_on} would put the one value that must never reach a page one keystroke away.
#   * A floor for any `ocp*` key. tools/lint/version-anchor-guard.py enforces
#     ATTR_RE = \{(ocp[A-Za-z0-9_]*_version|ocp_version)\} — it matches only the _version
#     spelling, so an {ocp_minimum} or {ocp_image_policy_minimum} would be an UNGUARDED SYNONYM
#     for an attribute that guard exists to police. Extend the guard first if that is ever wanted.
#
# THE OPENSHIFT RELEASE INVERTS THE FIELD NAMES, and that is where this bites hardest:
#   {ocp_version} is already versions.yaml's supported FLOOR. The ocp: entry spells its floor
#   `version:` (marked "# minimum, not a cap") and its grounded-on reading `grounded_on:` — the
#   INVERSE of service_mesh: and istio:. It is frozen at content-build time and is not a reading
#   of the reader's cluster. That reading is {cluster_ocp_version}, which is NOT generated here:
#   it is a soft attribute in content/antora.yml + showroom/site*.yml that bootstrap/install.sh
#   sets per deploy from the live cluster. Read the mechanism at that attribute in
#   content/antora.yml. tools/lint/version-anchor-guard.py keeps {ocp_version} and bare 4.NN
#   literals out of concept/lab/wrapup. {ocp_image_policy_version} is a floor spelled `version:`
#   too — the minor the feature GA'd in. Both keep the _version spelling for guard coverage.
#
# Idempotent: same versions.yaml -> byte-identical output. CI runs this and then
# `git diff --exit-code` on the output file as a drift gate — if versions.yaml changed
# without regenerating, CI fails.
#
# Usage:  tools/gen-attributes.sh          # regenerate in place
#         tools/gen-attributes.sh --check  # exit 1 if the committed file is stale
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions_file="${repo_root}/versions.yaml"
out_file="${repo_root}/content/modules/ROOT/partials/version-attributes.adoc"

if ! command -v yq >/dev/null 2>&1; then
  echo "❌ yq (github.com/mikefarah/yq) not found on PATH — needed to read versions.yaml." >&2
  echo "   Install it or run this in CI where it is provisioned." >&2
  exit 1
fi

if [ ! -f "$versions_file" ]; then
  echo "❌ versions.yaml not found at ${versions_file}." >&2
  exit 1
fi

verified="$(yq eval '.verified // "unknown"' "$versions_file")"

# Build the partial in a temp file, then move into place (atomic, and lets --check diff).
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

{
  echo "// GENERATED by tools/gen-attributes.sh from versions.yaml — DO NOT EDIT BY HAND."
  echo "// Product versions for content prose (04-STYLE-GUIDE §5). Regenerate after editing"
  echo "// versions.yaml; CI fails if this file drifts from the source of truth."
  echo "// versions.yaml verified: ${verified}"
  echo "//"
  # One `:<key>_version: <value>` per top-level map entry that has a non-null version.
  # `to_entries` preserves document order -> deterministic, idempotent output.
  yq eval \
    'to_entries | .[]
       | select(.value | type == "!!map")
       | select(.value.version != null)
       | ":" + .key + "_version: " + (.value.version | tostring)' \
    "$versions_file"
  echo "//"
  echo "// SUPPORT FLOORS — a DIFFERENT family, minted from versions.yaml \`minimum:\`. A floor is"
  echo "// the oldest release this workshop is built to work on, so it is safe to assert to a"
  echo "// reader: write \"{service_mesh_minimum} or newer\". The :*_version: attributes above are"
  echo "// the grounded-on reading — what we last observed — and are NOT a fact about the reader's"
  echo "// cluster, because every operator here auto-upgrades on its channel. Read the header of"
  echo "// tools/gen-attributes.sh before putting either family into rendered prose."
  # Same `to_entries` ordering rule as above -> deterministic, idempotent output.
  yq eval \
    'to_entries | .[]
       | select(.value | type == "!!map")
       | select(.value.minimum != null)
       | ":" + .key + "_minimum: " + (.value.minimum | tostring)' \
    "$versions_file"
} > "$tmp_file"

if [ "${1:-}" = "--check" ]; then
  if [ ! -f "$out_file" ] || ! diff -q "$out_file" "$tmp_file" >/dev/null 2>&1; then
    echo "❌ ${out_file#"${repo_root}/"} is stale." >&2
    echo "   Fix: run tools/gen-attributes.sh and commit the result." >&2
    if [ -f "$out_file" ]; then
      diff -u "$out_file" "$tmp_file" >&2 || true
    fi
    exit 1
  fi
  echo "✅ version-attributes.adoc is in sync with versions.yaml (verified ${verified})."
  exit 0
fi

mkdir -p "$(dirname "$out_file")"
mv "$tmp_file" "$out_file"
trap - EXIT
# Report the two families separately — a contributor who adds a `minimum:` needs to see the
# second count move. `|| true` because grep -c exits 1 on zero matches (it still prints 0).
n_version="$(grep -c '^:[a-z0-9_]*_version:' "$out_file" || true)"
n_minimum="$(grep -c '^:[a-z0-9_]*_minimum:' "$out_file" || true)"
echo "✅ Wrote ${out_file#"${repo_root}/"} (${n_version} version + ${n_minimum} minimum attributes, verified ${verified})."
