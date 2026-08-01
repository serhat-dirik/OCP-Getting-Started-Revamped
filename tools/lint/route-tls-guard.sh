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

# ── scope floors ────────────────────────────────────────────────────────────────────────────────
# The bash counterpart of tools/lint/_scope.py, and it follows that file's contract deliberately:
# a dimension below its floor is rc=2 ("the guard could not inspect what it claims to"), never a
# clean 0 and never 1 ("the tree has a defect"). Those are different facts and CI should be able to
# tell them apart.
#
# A FLOOR, NOT A NON-ZERO CHECK. This guard used to assert only `-eq 0` per half. Measured
# 2026-08-01: narrowing the chart glob to a single entry-state took the Helm half from 56 renders to
# 2 and the guard still exited 0, and dropping platform-portfolio from the static grep took that half
# from 18 to 16 — silently un-checking the sonarqube and keycloak Routes — and also exited 0. Zero is
# the accident that is easy to catch; truncation is the likelier one and was invisible.
scope_check() {  # <dimension> <actual> <floor> <why> [quiet] → 0 met, 2 collapsed
  local dim="$1" actual="$2" floor="$3" why="$4" quiet="${5:-}"
  # Spelled as a full `if`, not `cond && return 0`: the && form inside a function is the shape that
  # silently skipped teardown steps elsewhere in this repo once `set -e` was in play.
  if [ "$actual" -ge "$floor" ]; then
    return 0
  fi
  if [ -z "$quiet" ]; then
    echo "  ❌ SCOPE COLLAPSE: ${dim} — inspected ${actual}, floor is ${floor}."
    echo "       ${why}"
    echo "       A guard that reports clean over a collapsed input set reports success over work it"
    echo "       did not do. If the shrink is deliberate, lower the floor in the same change and say why."
  fi
  return 2
}

# Counted per HALF, not in total: the halves fail independently (a renamed chart directory empties
# the first; a moved manifest tree or a broken grep empties the second), and a single counter lets a
# healthy half hide a dead one behind a reassuring "74 inputs inspected". The static half is split
# again per TREE, because the grep takes two roots and losing one of them is the exact truncation
# measured above — a combined static count of 16-of-18 looks entirely healthy.
helm_inspected=0
static_inspected=0
static_gitops=0
static_portfolio=0

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
  # Bucketed by tree so each root carries its own floor; a root that stops matching cannot hide
  # behind the other one's count.
  case "$f" in
    gitops/*)             static_gitops=$((static_gitops + 1)) ;;
    platform-portfolio/*) static_portfolio=$((static_portfolio + 1)) ;;
  esac
done < <(grep -rl --include='*.yaml' --include='*.yml' '^kind: Route' gitops platform-portfolio 2>/dev/null)

# Self-test. A guard that silently inspects nothing reports a perfect score — this one did
# exactly that in its first version. Feed it a Route that MUST be rejected and fail loudly if
# it is not, so "all ok" can never again mean "I read nothing".
printf 'apiVersion: route.openshift.io/v1\nkind: Route\nmetadata:\n  name: canary\nspec:\n  to:\n    kind: Service\n    name: x\n' >"$tmp/canary.yaml"
if check_file "$tmp/canary.yaml" "canary" >/dev/null 2>&1; then
  echo "  ❌ SELF-TEST FAILED: guard accepted a Route with no TLS — it is not actually checking."
  # rc=2, not 1: a blind detector is "this guard is broken", the same class as a collapsed scope.
  # rc=1 is reserved for "the tree has a Route missing TLS", which is a fact about the tree and
  # sends the reader to a completely different fix.
  rc=2
else
  echo "  self-test ok — guard rejects a TLS-less Route"
fi

# The canary above only proves check_file works. The floors below prove something was FED to it —
# and they need their own canary, or they are exactly the unrun gate this repo keeps rediscovering.
# Run inline on every invocation, so CI's existing step exercises it with no extra wiring.
if scope_check "canary" 0 1 "canary" quiet; then
  echo "  ❌ SELF-TEST FAILED: scope_check accepted 0 inputs against a floor of 1 — every floor"
  echo "       below is decorative and a half that goes dark would report clean."
  rc=2
elif ! scope_check "canary" 5 5 "canary" quiet; then
  echo "  ❌ SELF-TEST FAILED: scope_check rejected a dimension that exactly MEETS its floor — it"
  echo "       would redden main on a healthy tree."
  rc=2
else
  echo "  self-test ok — scope floors reject a collapsed dimension and accept one that meets its floor"
fi

# Each half asserted separately, naming what went dark and what to look at. Floors are set below
# today's measurement and above anything a plausible truncation produces (see _scope.py).
scope_rc=0
scope_check "rendered Helm charts" "$helm_inspected" 40 \
  "28 charts × 2 value permutations = 56 today. One chart's worth is 2, so a floor of 40 cannot be
       met by a glob that collapsed to a single directory. Look at the chart glob: a renamed or moved
       entry-state silently empties this half." || scope_rc=2
scope_check "static manifests under gitops/" "$static_gitops" 10 \
  "16 today. Either Routes moved out of gitops/, or the grep stopped matching them (an indented
       'kind:', .yml vs .yaml, a new subtree the search never visits)." || scope_rc=2
scope_check "static manifests under platform-portfolio/" "$static_portfolio" 2 \
  "2 today (sonarqube, keycloak) — the floor is the exact count because the set is this small, so
       removing one is an editorial act that should re-state its own floor rather than pass quietly.
       Dropping this root from the grep took the combined static count from 18 to 16, which is why
       this dimension is counted separately at all." || scope_rc=2

# A collapsed scope OUTRANKS a finding: over an input set this guard cannot vouch for, neither
# "clean" nor "N Routes are broken" is a trustworthy answer.
if [ "$scope_rc" -ne 0 ]; then
  rc=2
fi

if [ "$rc" -eq 0 ]; then
  echo "  inputs inspected: ${helm_inspected} rendered chart(s) + ${static_inspected} static" \
       "manifest(s) (${static_gitops} gitops/, ${static_portfolio} platform-portfolio/)"
fi

# Only the TLS advice, and only when a Route is actually the problem. Printing "add tls.termination"
# under a scope collapse sends the reader to fix a Route that was never inspected.
if [ "$rc" -eq 1 ]; then
  echo
  echo "A browser-facing Route is missing TLS. Add to its spec:"
  echo "    tls:"
  echo "      termination: edge"
  echo "      insecureEdgeTerminationPolicy: Allow"
  echo "Use Allow, not Redirect — several labs curl the route over plain http and a Redirect"
  echo "returns an empty 302 to them."
fi
exit "$rc"
