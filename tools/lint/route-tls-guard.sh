#!/usr/bin/env bash
# Fail if any browser-facing Route we own ships without TLS termination.
#
# WHY THIS EXISTS. A plain-HTTP Route looks fine from the terminal and is broken in a browser:
# the OpenShift console renders a Route link as https, browsers HSTS-upgrade it, and the attendee
# gets "Application is not available" while `curl http://…` cheerfully returns 200. That asymmetry
# is why the defect survived review twice.
#
#   2026-07-27  six entry-state Routes found plain, fixed.
#   2026-07-28  the config-multienv _helpers.tpl Route was STILL plain — it renders the stage and
#               prod Routes, and it only renders under `solve=true`, so the CI `helm template <dir>`
#               (default values) never even produced it. Caught by hand on a live cluster.
#
# So this guard renders each chart under EVERY values permutation that materially changes what is
# emitted — not just the defaults — and checks every Route in the result.
#
# Vendored upstream charts are skipped: we do not patch third-party chart internals. Where such a
# chart needs TLS it is configured through its own values (e.g. sonarqube's OpenShift.route.tls).
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
rc=0

# $1: path to a YAML file, $2: label.
#
# The YAML is passed as a PATH, never on stdin. `python3 - <<'PY'` already uses stdin to deliver
# the script itself, so a piped document would be swallowed and `sys.stdin.read()` would return
# "" — which means every input parses as "no Routes found" and the check passes vacuously. The
# first version of this guard had exactly that bug and reported `ok` for all 74 inputs while
# inspecting none of them. A guard that cannot fail is worse than no guard.
check_file() {
  local path="$1" label="$2"
  python3 - "$path" "$label" <<'PY'
import sys, re
path, label = sys.argv[1], sys.argv[2]
with open(path) as fh:
    docs = fh.read().split("\n---")
bad = []
for d in docs:
    if not re.search(r'^\s*kind:\s*Route\s*$', d, re.M):
        continue
    name = (re.search(r'^\s*name:\s*(\S+)', d, re.M) or [None, "<unnamed>"])[1]
    ns = (re.search(r'^\s*namespace:\s*(\S+)', d, re.M) or [None, "-"])[1]
    if not re.search(r'^\s*termination:\s*\S', d, re.M):
        bad.append(f"{ns}/{name}")
if bad:
    print(f"  FAIL {label}")
    for b in bad:
        print(f"        Route without tls.termination: {b}")
    sys.exit(1)
print(f"  ok   {label}")
PY
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Counted per HALF, not in total: the two halves fail independently (a renamed chart directory
# empties the first; a moved manifest tree or a broken grep empties the second), and a single
# counter lets a healthy half hide a dead one behind a reassuring "74 inputs inspected".
helm_inspected=0
static_inspected=0

echo "== rendered Helm charts =="
for chart in gitops/entry-states/*/Chart.yaml gitops/workshop-config/Chart.yaml helm/bootstrap/Chart.yaml; do
  [ -f "$chart" ] || continue
  d="$(dirname "$chart")"
  # `solve=true` is not cosmetic: it is the flag that emits the stage/prod Routes which the
  # default render omits entirely. Any future flag that gates extra Routes belongs here too.
  for vals in "" "solve=true"; do
    out="$tmp/render.yaml"
    err="$tmp/render.err"
    # A FAILED render used to pass this guard silently. stderr went to /dev/null and the exit status
    # was never read, so `helm template` blowing up left an EMPTY $out — and an empty file contains
    # no plain-HTTP Routes, so check_file happily reported clean. The guard would have gone green on
    # a chart that cannot render at all, which is the same inspects-nothing failure this repo has
    # now hit in three different tools. The status is checked, and a render failure is fatal.
    if [ -z "$vals" ]; then
      helm template t "$d" --set user=user1 >"$out" 2>"$err"; hrc=$?
      label="$d (defaults)"
    else
      helm template t "$d" --set user=user1 --set "$vals" >"$out" 2>"$err"; hrc=$?
      label="$d ($vals)"
    fi
    if [ "$hrc" -ne 0 ]; then
      echo "  ❌ $label — helm template FAILED (exit $hrc); this guard cannot inspect what did not render"
      sed 's/^/       /' "$err" | head -5
      rc=1
      continue
    fi
    # An empty render is not a pass either: a chart that emits nothing under a flag that is supposed
    # to add Routes is a defect worth surfacing, not a clean scan.
    if [ ! -s "$out" ]; then
      echo "  ❌ $label — rendered EMPTY; refusing to count that as inspected"
      rc=1
      continue
    fi
    check_file "$out" "$label" || rc=1
    helm_inspected=$((helm_inspected + 1))
  done
done

echo "== static manifests (kustomize bases, raw YAML) =="
while IFS= read -r f; do
  case "$f" in
    */charts/*) continue ;;   # vendored upstream chart internals — not ours to patch
  esac
  check_file "$f" "$f" || rc=1
  static_inspected=$((static_inspected + 1))
done < <(grep -rl --include='*.yaml' --include='*.yml' '^kind: Route' gitops platform-portfolio 2>/dev/null)

# Self-test. A guard that silently inspects nothing reports a perfect score — this one did
# exactly that in its first version. Feed it a Route that MUST be rejected and fail loudly if
# it is not, so "all ok" can never again mean "I read nothing".
printf 'apiVersion: route.openshift.io/v1\nkind: Route\nmetadata:\n  name: canary\nspec:\n  to:\n    kind: Service\n    name: x\n' >"$tmp/canary.yaml"
if check_file "$tmp/canary.yaml" "canary" >/dev/null 2>&1; then
  echo "  SELF-TEST FAILED: guard accepted a Route with no TLS — it is not actually checking."
  rc=1
else
  echo "  self-test ok — guard rejects a TLS-less Route"
fi

# …and the canary only proves check_file works. It says NOTHING about whether either half fed it
# anything: both loops can drop to zero inputs while the line above still prints "self-test ok".
# Assert each half separately, naming the half that went dark and what to look at.
if [ "$helm_inspected" -eq 0 ]; then
  echo "  ❌ SELF-TEST FAILED: the Helm half rendered ZERO inputs — no chart matched"
  echo "       gitops/entry-states/*/Chart.yaml, gitops/workshop-config, helm/bootstrap."
  echo "       A renamed or moved chart directory silently empties this half; fix the glob."
  rc=1
fi
if [ "$static_inspected" -eq 0 ]; then
  echo "  ❌ SELF-TEST FAILED: the static half inspected ZERO manifests — no file under gitops/ or"
  echo "       platform-portfolio/ matched '^kind: Route'. Either every Route moved, or the grep"
  echo "       stopped matching (indented kind:, .yml vs .yaml, a new tree not in the search list)."
  rc=1
fi
if [ "$rc" -eq 0 ]; then
  echo "  inputs inspected: ${helm_inspected} rendered chart(s) + ${static_inspected} static manifest(s)"
fi

if [ "$rc" -ne 0 ]; then
  echo
  echo "A browser-facing Route is missing TLS. Add to its spec:"
  echo "    tls:"
  echo "      termination: edge"
  echo "      insecureEdgeTerminationPolicy: Allow"
  echo "Use Allow, not Redirect — several labs curl the route over plain http and a Redirect"
  echo "returns an empty 302 to them."
fi
exit "$rc"
