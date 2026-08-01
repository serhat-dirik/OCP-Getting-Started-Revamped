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
#
# ── 2026-08-01: this guard had NO --self-test mode at all ─────────────────────────────────────────
# `route-tls-guard.sh --self-test` — the house flag, spelled correctly — exited 0 with a green
# result. The argument was discarded in silence and the PLAIN check ran, which passes on a healthy
# tree by definition. CI ran this file as a gate with nothing whatsoever asserting that its detection
# still works, and a maintainer reaching for the documented flag to justify a change was handed a
# green tick that proved nothing. Its canaries did run, but only inline during the plain run, so the
# one thing the house convention exists to state — "every detector fired against a planted defect,
# exit EXACTLY 1" — was unavailable at any invocation.
#
# The canaries now live in self_test(), the whole check is a function that takes its two input halves
# as parameters, and each half can therefore be driven to ZERO and to a genuine TRUNCATION and shown
# to exit 2. Truncation passing outright was a real defect in this file earlier the same night;
# proving the floors catch it needs the ability to feed the check a smaller world, which an
# unparameterised top-level script cannot do.
#
# Exit codes: 0 contract holds · 1 a Route is missing TLS (or, under --self-test, every canary was
# correctly caught) · 2 this guard could not inspect what it claims to (scope collapse, a blind
# detector, a missed canary, no helm).
#
# NOTE ON `set -uo pipefail` — deliberately WITHOUT `-e`. `helm template … ; hrc=$?` below reads the
# render's exit status by hand so a failed render is reported as a render failure rather than killing
# the script mid-scan, and every detector here returns non-zero as a normal finding. Adding -e breaks
# both. Do not add it.
set -uo pipefail

# Resolved BEFORE the cd below, which moves us to the repo root.
LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "${LINT_DIR}/_parse-guard-args.sh"

cd "$(dirname "$0")/../.." || exit 1

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

# Floors are set below today's measurement and above anything a plausible truncation produces
# (see _scope.py). Named constants rather than literals inside run_check so the self-test's
# truncation canaries can be read next to the number they are meant to trip.
HELM_FLOOR=40        # 28 charts × 2 value permutations = 56 today; one chart's worth is 2.
GITOPS_FLOOR=10      # 16 today.
PORTFOLIO_FLOOR=2    # 2 today (sonarqube, keycloak) — the floor IS the count; see run_check.

# The default world. Space-separated strings, not arrays: under bash 3.2 + `set -u` — the macOS
# default — `"${empty[@]}"` raises "unbound variable" and the resulting crash exits 1, which CI's
# exit-exactly-1 assertion reads as a PASSING self-test. Same reasoning as _parse-guard-args.sh.
CHART_SPEC_DEFAULT="gitops/entry-states/*/Chart.yaml gitops/workshop-config/Chart.yaml helm/bootstrap/Chart.yaml"
GITOPS_ROOT_DEFAULT="gitops"
PORTFOLIO_ROOT_DEFAULT="platform-portfolio"

# Counters, set by the two halves. Read by run_check's floor assertions and its summary line.
helm_inspected=0
static_inspected=0
static_gitops=0
static_portfolio=0

# ── half 1: rendered Helm charts ────────────────────────────────────────────────────────────────
helm_half() {  # <chart-glob-spec> → 0 clean · 1 a Route is missing TLS or a chart failed to render
  local chart_spec="$1" chart d vals out err hrc label rc=0
  helm_inspected=0
  echo "== rendered Helm charts =="
  # shellcheck disable=SC2086  # $chart_spec is a space-separated list of GLOBS and must undergo
  # both word-splitting and pathname expansion here. Quoting it turns 28 charts into one literal
  # path that does not exist — the exact scope collapse the floor below is there to catch, so this
  # is load-bearing rather than sloppy.
  for chart in $chart_spec; do
    [ -f "$chart" ] || continue
    d="$(dirname "$chart")"
    # `solve=true` is not cosmetic: it is the flag that emits the stage/prod Routes which the
    # default render omits entirely. Any future flag that gates extra Routes belongs here too.
    for vals in "" "solve=true"; do
      out="$tmp/render.yaml"
      err="$tmp/render.err"
      # A FAILED render used to pass this guard silently. stderr went to /dev/null and the exit
      # status was never read, so `helm template` blowing up left an EMPTY $out — and an empty file
      # contains no plain-HTTP Routes, so check_file happily reported clean. The guard would have
      # gone green on a chart that cannot render at all, which is the same inspects-nothing failure
      # this repo has now hit in three different tools. The status is checked, and a render failure
      # is fatal.
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
      # An empty render is not a pass either: a chart that emits nothing under a flag that is
      # supposed to add Routes is a defect worth surfacing, not a clean scan.
      if [ ! -s "$out" ]; then
        echo "  ❌ $label — rendered EMPTY; refusing to count that as inspected"
        rc=1
        continue
      fi
      check_file "$out" "$label" || rc=1
      helm_inspected=$((helm_inspected + 1))
    done
  done
  return "$rc"
}

# ── half 2: static manifests ────────────────────────────────────────────────────────────────────
# Counted per TREE, not in total: the roots fail independently (a moved manifest tree or a broken
# grep empties one of them), and a single counter lets a healthy root hide a dead one behind a
# reassuring "18 inputs inspected". Dropping platform-portfolio from the grep took the combined
# static count from 18 to 16, which looks entirely healthy — that is why each root is counted alone.
static_scan_root() {  # <root> <counter-name> → 0 clean · 1 a Route is missing TLS
  local root="$1" counter="$2" f n=0 rc=0
  [ -n "$root" ] || { eval "$counter=0"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */charts/*) continue ;;   # vendored upstream chart internals — not ours to patch
    esac
    check_file "$f" "$f" || rc=1
    n=$((n + 1))
    static_inspected=$((static_inspected + 1))
  done < <(grep -rl --include='*.yaml' --include='*.yml' '^kind: Route' "$root" 2>/dev/null)
  eval "$counter=$n"
  return "$rc"
}

static_half() {  # <gitops-root> <portfolio-root> → 0 clean · 1 a Route is missing TLS
  local grt="$1" prt="$2" rc=0
  static_inspected=0
  static_gitops=0
  static_portfolio=0
  echo "== static manifests (kustomize bases, raw YAML) =="
  static_scan_root "$grt" static_gitops || rc=1
  static_scan_root "$prt" static_portfolio || rc=1
  return "$rc"
}

# ── the check ───────────────────────────────────────────────────────────────────────────────────
run_check() {  # <chart-glob-spec> <gitops-root> <portfolio-root> → 0 clean · 1 finding · 2 could not inspect
  local chart_spec="$1" grt="$2" prt="$3" rc=0 scope_rc=0

  helm_half "$chart_spec" || rc=1
  static_half "$grt" "$prt" || rc=1

  # Each half asserted separately, naming what went dark and what to look at.
  scope_check "rendered Helm charts" "$helm_inspected" "$HELM_FLOOR" \
    "28 charts × 2 value permutations = 56 today. One chart's worth is 2, so a floor of ${HELM_FLOOR} cannot be
       met by a glob that collapsed to a single directory. Look at the chart glob: a renamed or moved
       entry-state silently empties this half." || scope_rc=2
  scope_check "static manifests under gitops/" "$static_gitops" "$GITOPS_FLOOR" \
    "16 today. Either Routes moved out of gitops/, or the grep stopped matching them (an indented
       'kind:', .yml vs .yaml, a new subtree the search never visits)." || scope_rc=2
  scope_check "static manifests under platform-portfolio/" "$static_portfolio" "$PORTFOLIO_FLOOR" \
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
  return "$rc"
}

# ── canaries ────────────────────────────────────────────────────────────────────────────────────
_rtg_fail() { echo "❌ SELF-TEST FAILED: $*" >&2; }

_expect_rc() {  # <label> <want> <got> → 0 match, 1 mismatch (and prints)
  local label="$1" want="$2" got="$3"
  if [ "$got" -ne "$want" ]; then
    _rtg_fail "${label} → rc=${got}, expected ${want}."
    return 1
  fi
  return 0
}

self_test() {  # → 1 every canary caught (the PASS) · 2 a canary was missed or the tree is broken
  local seen=0 got d

  # Proof 0: the real tree passes under the real defaults. A guard that fires on everything proves
  # nothing, and every truncation canary below is only meaningful against a baseline that is clean.
  got=0
  run_check "$CHART_SPEC_DEFAULT" "$GITOPS_ROOT_DEFAULT" "$PORTFOLIO_ROOT_DEFAULT" >/dev/null 2>&1 || got=$?
  if ! _expect_rc "the real tree satisfies the contract under the real defaults" 0 "$got"; then
    echo "   Run 'bash tools/lint/route-tls-guard.sh' without --self-test to see the finding." >&2
    return 2
  fi

  # ── detector canaries: check_file itself ──────────────────────────────────────────────────────
  # A — a Route with no tls.termination MUST be rejected. This is THE canary: the first version of
  # this guard reported `ok` for all 74 inputs while parsing none of them.
  printf 'apiVersion: route.openshift.io/v1\nkind: Route\nmetadata:\n  name: canary\nspec:\n  to:\n    kind: Service\n    name: x\n' >"$tmp/canary-plain.yaml"
  got=0; check_file "$tmp/canary-plain.yaml" canary >/dev/null 2>&1 || got=$?
  _expect_rc "canary A (a Route with no tls.termination must be rejected)" 1 "$got" || seen=1

  # B — and an edge-terminated Route must be ACCEPTED. Without this, a check_file hard-wired to
  # `return 1` would satisfy canary A and redden main on a perfectly healthy tree; A alone cannot
  # tell a working detector from one that rejects everything.
  printf 'apiVersion: route.openshift.io/v1\nkind: Route\nmetadata:\n  name: canary\nspec:\n  to:\n    kind: Service\n    name: x\n  tls:\n    termination: edge\n    insecureEdgeTerminationPolicy: Allow\n' >"$tmp/canary-tls.yaml"
  got=0; check_file "$tmp/canary-tls.yaml" canary >/dev/null 2>&1 || got=$?
  _expect_rc "canary B (an edge-terminated Route must be accepted)" 0 "$got" || seen=1

  # ── detector canaries: scope_check itself ─────────────────────────────────────────────────────
  # C — zero inputs against any floor is a collapse, never a pass. If this is inert every floor
  # below it is decoration and a half that goes dark reports clean.
  got=0; scope_check canary 0 1 canary quiet || got=$?
  _expect_rc "canary C (scope_check must reject 0 inputs against a floor of 1)" 2 "$got" || seen=1

  # D — and a dimension that exactly MEETS its floor must pass, or the guard reddens main on a
  # healthy tree. platform-portfolio sits exactly on its floor today, so this is not academic.
  got=0; scope_check canary 5 5 canary quiet || got=$?
  _expect_rc "canary D (scope_check must accept a dimension that exactly meets its floor)" 0 "$got" || seen=1

  # ── scope floor canaries: the HELM half ───────────────────────────────────────────────────────
  # E — the helm half at ZERO. A renamed or moved chart tree empties the glob; the static half is
  # left at its real values so the only thing that can produce rc=2 here is the helm floor.
  got=0
  run_check "no/such/path/*/Chart.yaml" "$GITOPS_ROOT_DEFAULT" "$PORTFOLIO_ROOT_DEFAULT" >/dev/null 2>&1 || got=$?
  _expect_rc "canary E (helm half at ZERO renders)" 2 "$got" || seen=1

  # F — the helm half TRUNCATED, not zero: one real entry-state, which renders 2 of the real 56 and
  # passes cleanly on its own. THIS is the shape that passed outright earlier tonight — a non-empty,
  # entirely healthy-looking scan over 4% of the intended input set.
  got=0
  run_check "gitops/entry-states/platform-orientation/Chart.yaml" "$GITOPS_ROOT_DEFAULT" "$PORTFOLIO_ROOT_DEFAULT" >/dev/null 2>&1 || got=$?
  _expect_rc "canary F (helm half TRUNCATED to 2 of 56 renders)" 2 "$got" || seen=1

  # ── scope floor canaries: the STATIC half ─────────────────────────────────────────────────────
  # G — the static half at ZERO, both roots dark at once (a moved manifest tree, a broken grep).
  d="$(mktemp -d)"
  got=0
  run_check "$CHART_SPEC_DEFAULT" "$d" "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary G (static half at ZERO for both roots)" 2 "$got" || seen=1

  # H — the gitops root TRUNCATED to 2 of its 16 files (workshop-config only, the 14 under
  # entry-states and promotion dropped), with platform-portfolio left healthy at its real 2.
  # Nonzero, healthy-looking, and still a collapse.
  got=0
  run_check "$CHART_SPEC_DEFAULT" "gitops/workshop-config" "$PORTFOLIO_ROOT_DEFAULT" >/dev/null 2>&1 || got=$?
  _expect_rc "canary H (gitops root TRUNCATED, portfolio root healthy)" 2 "$got" || seen=1

  # I — and the mirror image: the platform-portfolio root truncated to 1 of 2 (sonarqube only,
  # keycloak silently un-checked) with gitops left healthy. This is the measured 18→16 incident with
  # the surviving half still reporting a comfortable count.
  got=0
  run_check "$CHART_SPEC_DEFAULT" "$GITOPS_ROOT_DEFAULT" "platform-portfolio/components/sonarqube" >/dev/null 2>&1 || got=$?
  _expect_rc "canary I (portfolio root TRUNCATED to 1 of 2, gitops root healthy)" 2 "$got" || seen=1

  # ── end-to-end canaries, ONE PER HALF ─────────────────────────────────────────────────────────
  # A — D prove check_file works in isolation. Only these prove that each half actually FEEDS it the
  # tree and PROPAGATES its verdict: measured 2026-08-01, dropping the `|| rc=1` from the helm half's
  # check_file call left every other canary here green, because nothing else plants a defect a
  # RENDER has to surface. Each half therefore gets its own end-to-end canary.
  #
  # One scratch copy serves both: gitops/workshop-config/templates/showroom.yaml is simultaneously a
  # static manifest the grep finds AND a Helm template that renders six Routes under the DEFAULT
  # values, so stripping its `termination:` lines is a defect both halves must independently catch.
  # `insecureEdgeTerminationPolicy:` survives the sed (capital T after "termination"), which keeps
  # the fixture realistic rather than gutting the whole tls block.
  d="$(mktemp -d)"
  cp -R gitops "$d/gitops"
  cp -R helm "$d/helm"
  sed -i.bak '/termination:/d' "$d/gitops/workshop-config/templates/showroom.yaml"
  rm -f "$d/gitops/workshop-config/templates/showroom.yaml.bak"

  # J — the STATIC half: the mutated copy as the gitops root, real charts, real portfolio root. Same
  # file count as the real tree, so both floors are still met and rc=2 cannot mask the finding.
  got=0
  run_check "$CHART_SPEC_DEFAULT" "$d/gitops" "$PORTFOLIO_ROOT_DEFAULT" >/dev/null 2>&1 || got=$?
  _expect_rc "canary J (TLS-less Route reaches the STATIC half, scope intact)" 1 "$got" || seen=1

  # K — the HELM half: the mutated copy's charts, real static roots. Same 56 renders, so the helm
  # floor is still met and the only thing that can produce rc=1 is a rendered Route without TLS.
  got=0
  run_check "$d/gitops/entry-states/*/Chart.yaml $d/gitops/workshop-config/Chart.yaml $d/helm/bootstrap/Chart.yaml" \
    "$GITOPS_ROOT_DEFAULT" "$PORTFOLIO_ROOT_DEFAULT" >/dev/null 2>&1 || got=$?
  _expect_rc "canary K (TLS-less Route reaches the HELM half, scope intact)" 1 "$got" || seen=1
  rm -rf "$d"

  if [ "$seen" -ne 0 ]; then
    return 2
  fi
  echo "✅ self-test ok — TLS-less Route rejected and an edge-terminated one accepted; scope_check"
  echo "   rejects a collapsed dimension and accepts one exactly at its floor; each input half caught"
  echo "   at ZERO and at a genuine TRUNCATION, independently, with the other half healthy; and each"
  echo "   half surfaces a real TLS-less Route as rc=1. Real tree clean under the defaults."
  # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
  return 1
}

# ── entry point ─────────────────────────────────────────────────────────────────────────────────
parse_guard_args "$@"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# helm is not optional for this guard. Without it every render fails, the helm half returns 1, and
# the reader is told to add tls.termination to a Route that was never rendered — advice about a
# defect that does not exist. A missing tool is "could not inspect", which is rc 2.
if ! command -v helm >/dev/null 2>&1; then
  echo "  ❌ helm not found on PATH — this guard renders every chart and cannot inspect what it cannot render." >&2
  exit 2
fi

if [ "$GUARD_SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

rc=0
run_check "$CHART_SPEC_DEFAULT" "$GITOPS_ROOT_DEFAULT" "$PORTFOLIO_ROOT_DEFAULT" || rc=$?

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
