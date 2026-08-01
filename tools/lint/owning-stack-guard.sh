#!/usr/bin/env bash
# owning-stack-guard.sh — the fix-hint stack-attribution lookup, gated.
#
# ORIGIN. bootstrap/install.sh's assert_single_operatorgroup() names the offending Application's
# owning stack in its undo hint (`oc -n openshift-gitops patch application pp-${stack} …`), read via
# owning_stack_of_app(): a `yq`-over-platform-portfolio/stacks/**/apps/*.yaml lookup with no cluster
# dependency at all. operatorgroup-uniqueness-guard.sh already exercises assert_single_operatorgroup()
# under a STUBBED owning_stack_of_app() (its own header explains why: that guard's contract is
# bash + awk + sed only) — which means the lookup itself has never been driven, on a real cluster or
# off one. A wrong answer here does not fail an install; it hands an SA a copy-paste remediation
# command that patches the WRONG stack's app-of-apps while the real offender's sync policy stays
# armed and keeps re-creating the OperatorGroup that caused the incident in the first place.
#
# WHAT IT CHECKS, against owning_stack_of_app() extracted verbatim from bootstrap/install.sh, run
# against real temp fixture trees shaped like platform-portfolio/stacks/<stack>/apps/*.yaml (no `oc`,
# no cluster, no stub needed — the function only ever touches the filesystem and `yq`):
#
#   (a) exactly one candidate file, its metadata.name matches the app → that file's grandparent
#       directory name (the stack).
#   (b) no candidate file's metadata.name matches the app → "<unknown>", never a guess.
#   (c) EXACT-NAME GUARD: a file whose metadata.name is a near-miss (the app name plus a suffix, or
#       vice versa) must NOT match. A substring/prefix match here would misattribute e.g. an app
#       named "pp-keycloak" to whichever stack happens to also ship "pp-keycloak-operator" first in
#       glob order — a wrong fix-hint that still executes cleanly, so nothing else would ever catch it.
#   (d) multiple stacks in the fixture, several with non-matching apps of their own → the correct
#       stack is still picked out, independent of glob/directory order.
#   (e) ROBUSTNESS: a malformed (unparsable) YAML file sits ahead of the real match in glob order →
#       yq's failure on it is swallowed (`2>/dev/null`, compared against "" which can never equal a
#       real app name) and the walk continues to the real match instead of aborting the whole lookup.
#   (f) REAL-TREE GROUND TRUTH: three known app/stack pairs actually shipped in
#       platform-portfolio/stacks/ resolve correctly, and a made-up app name resolves to "<unknown>" —
#       proof this generalizes past the synthetic fixtures.
#
# Runnable standalone (CI lint gate) and by hand; needs bash + yq (mikefarah v4 syntax, same as
# bootstrap/install.sh's own hard dependency check) + basename/dirname. Exits 2 rather than guessing
# if yq is missing — a lookup this guard cannot itself drive proves nothing either way.
#
# --self-test proves the detector actually fires before a clean run on the real tree is worth
# anything: it plants a canary that drops the exact-name comparison — the one line that turns "scan
# every candidate file" into "return the FIRST candidate file, regardless of whether its name
# matches" — reproducing case (c)'s failure shape (and, worse, turning every should-be "<unknown>"
# into a confident wrong answer). Exit 1 = the canary was caught AND the real tree is clean under the
# same detector; that is a PASS, matching the house convention where CI asserts the self-test step
# exits exactly 1. Exit 2 = the detector is blind, or the harness itself is broken.
#
# Exit codes:
#   0  contract holds
#   1  contract broken — or, under --self-test, the canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (extraction failed, yq missing, file missing)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/lint/_extract-func.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_extract-func.sh"
# shellcheck source=tools/lint/_check-coverage.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-coverage.sh"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_parse-guard-args.sh"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }

INSTALL="bootstrap/install.sh"
FUNC="owning_stack_of_app"

# ── extraction ────────────────────────────────────────────────────────────────
# Extracted, never sourced: install.sh runs a full cluster install at top level. Extraction failure
# is exit 2, never a silent pass. extract_func lives in _extract-func.sh, sourced above, shared with
# the other guards under tools/lint/ rather than copy-pasted per guard.

# ── fixture builder ───────────────────────────────────────────────────────────
# Lays down platform-portfolio/stacks/<stack>/apps/<file>.yaml under a fresh temp root, mirroring the
# real repo shape that owning_stack_of_app() walks (SCRIPT_DIR/../platform-portfolio/stacks/*/apps/*.yaml,
# with SCRIPT_DIR standing in for bootstrap/).
#   write_app <root> <stack> <filename> <metadata-name>
write_app() {
  local root="$1" stack="$2" fname="$3" name="$4" dir
  dir="${root}/platform-portfolio/stacks/${stack}/apps"
  mkdir -p "$dir"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: %s\n' "$name" > "${dir}/${fname}"
}

# write_broken <root> <stack> <filename> — a file yq cannot parse (unbalanced flow mapping), planted
# ahead of a real match to prove case (e): its yq failure must not abort the walk.
write_broken() {
  local root="$1" stack="$2" fname="$3" dir
  dir="${root}/platform-portfolio/stacks/${stack}/apps"
  mkdir -p "$dir"
  printf 'metadata: [this is not valid yaml: {{{\n' > "${dir}/${fname}"
}

# Runs the extracted function against one fixture root and echoes its stdout (the stack name, or
# "<unknown>"). SCRIPT_DIR is pointed at "<root>/bootstrap" (need not itself hold any files — the
# function only ever globs SCRIPT_DIR/../platform-portfolio/stacks/*/apps/*.yaml) so the relative
# ../platform-portfolio/stacks hop lands exactly where the fixture put it, unmodified from the real code.
run_owning_stack() {  # func_file root app → stack name on stdout
  local func_file="$1" root="$2" app="$3" harness out
  mkdir -p "${root}/bootstrap"
  harness="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "SCRIPT_DIR=$(printf '%q' "${root}/bootstrap")"
    cat "$func_file"
    printf '%s %q\n' "$FUNC" "$app"
  } > "$harness"
  out="$(bash "$harness" 2>/dev/null)"
  rm -f "$harness"
  printf '%s' "$out"
}

check_owning_stack() {  # func_file → 0 correct, 1 wrong, 2 harness broken
  # shellcheck disable=SC2119  # no arg on purpose - ran_check records its caller
  ran_check
  local func_file="$1" root out rc=0

  if [[ ! -s "$func_file" ]]; then
    bad "could not extract ${FUNC}() — the guard cannot inspect what it claims to."
    return 2
  fi
  if ! command -v yq >/dev/null 2>&1; then
    bad "yq not found — ${FUNC}() cannot be driven without the same dependency bootstrap/install.sh requires."
    return 2
  fi

  # (a) exactly one candidate, matching → its stack.
  root="$(mktemp -d)"
  write_app "$root" "core-devtools" "cert-manager.yaml" "pp-cert-manager"
  out="$(run_owning_stack "$func_file" "$root" "pp-cert-manager")"
  if [[ "$out" != "core-devtools" ]]; then
    bad "[a] single matching candidate: expected 'core-devtools', got '${out}'."
    rc=1
  fi
  rm -rf "$root"

  # (b) no candidate matches → "<unknown>", never a guess.
  root="$(mktemp -d)"
  write_app "$root" "auth" "keycloak.yaml" "pp-keycloak"
  out="$(run_owning_stack "$func_file" "$root" "pp-does-not-exist")"
  if [[ "$out" != "<unknown>" ]]; then
    bad "[b] no candidate matches: expected '<unknown>', got '${out}'."
    note "    a wrong guess here hands an SA a fix-hint command aimed at the wrong stack."
    rc=1
  fi
  rm -rf "$root"

  # (c) EXACT-NAME GUARD: near-miss names (superstring / substring of the real app) must not match.
  root="$(mktemp -d)"
  write_app "$root" "auth" "keycloak.yaml" "pp-keycloak"
  write_app "$root" "auth" "keycloak-operator.yaml" "pp-keycloak-operator"
  out="$(run_owning_stack "$func_file" "$root" "pp-keycloak")"
  if [[ "$out" != "auth" ]]; then
    bad "[c] exact match among near-misses: expected 'auth' for pp-keycloak, got '${out}'."
    rc=1
  fi
  out="$(run_owning_stack "$func_file" "$root" "pp-key")"
  if [[ "$out" != "<unknown>" ]]; then
    bad "[c] EXACT-NAME GUARD failed: 'pp-key' is a substring of shipped app names but matches none of"
    note "    them exactly — expected '<unknown>', got '${out}'. A substring match here misattributes"
    note "    every near-miss app to whichever stack happens to sort first."
    rc=1
  fi
  rm -rf "$root"

  # (d) multiple stacks, several with non-matching apps of their own → the correct one is still found.
  root="$(mktemp -d)"
  write_app "$root" "appsec" "sonarqube.yaml" "pp-sonarqube"
  write_app "$root" "batch" "keda.yaml" "pp-keda"
  write_app "$root" "trust" "rhacs-central.yaml" "pp-rhacs-central"
  out="$(run_owning_stack "$func_file" "$root" "pp-rhacs-central")"
  if [[ "$out" != "trust" ]]; then
    bad "[d] multi-stack fixture: expected 'trust' for pp-rhacs-central, got '${out}'."
    rc=1
  fi
  rm -rf "$root"

  # (e) ROBUSTNESS: an unparsable YAML file sits ahead of the real match in glob order — yq's
  # failure on it must be swallowed, not abort the whole lookup.
  root="$(mktemp -d)"
  write_broken "$root" "batch" "0-broken.yaml"
  write_app "$root" "batch" "keda.yaml" "pp-keda"
  out="$(run_owning_stack "$func_file" "$root" "pp-keda")"
  if [[ "$out" != "batch" ]]; then
    bad "[e] a malformed YAML candidate ahead of the real match broke the lookup: expected 'batch', got '${out}'."
    note "    yq's failure on the broken file must be swallowed (2>/dev/null, compares against \"\"),"
    note "    not abort the walk before it reaches the real match."
    rc=1
  fi
  rm -rf "$root"

  # (f) REAL-TREE GROUND TRUTH — three app/stack pairs actually shipped today, plus one that does
  # not exist anywhere in the portfolio.
  local pair app want
  for pair in "pp-cert-manager:core-devtools" "pp-keycloak:auth" "pp-rhacs-central:trust"; do
    app="${pair%%:*}"; want="${pair##*:}"
    out="$(run_owning_stack "$func_file" "$REPO_ROOT" "$app")"
    if [[ "$out" != "$want" ]]; then
      bad "[f] real tree: expected ${app} → ${want}, got '${out}'."
      rc=1
    fi
  done
  out="$(run_owning_stack "$func_file" "$REPO_ROOT" "pp-this-app-does-not-exist")"
  if [[ "$out" != "<unknown>" ]]; then
    bad "[f] real tree: a made-up app name should resolve to '<unknown>', got '${out}'."
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "owning_stack_of_app: exact matches resolve, near-misses and unknown apps never guess,"
    note "    a malformed candidate ahead of the real match does not abort the walk, real-tree pairs hold"
  fi
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────
run_check() {  # root → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
  local root="$1" rc=0 sub=0 func_file
  if [[ ! -f "${root}/${INSTALL}" ]]; then
    bad "${root}/${INSTALL} not found"
    return 2
  fi
  func_file="$(mktemp)"
  extract_func "${root}/${INSTALL}" "$FUNC" > "$func_file"

  check_owning_stack "$func_file" || sub=$?
  rm -f "$func_file"
  if [[ "$sub" -eq 2 ]]; then rc=2; elif [[ "$sub" -ne 0 ]]; then rc=1; fi
  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site
  # leaves every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# One canary, the real defect shape. It must be CAUGHT, and the real tree must be clean under the
# same detector — anything else means the gate is decorative.
self_test() {
  local real_rc canary_rc f

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$REPO_ROOT" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # Canary — drop the exact-name comparison that gates the `return 0`. Byte-for-byte the real
  # function, with the `[[ "$(yq …)" == "$app" ]] ||` guard neutered into an unconditional pass —
  # i.e. "return the FIRST candidate file's stack, regardless of whether its name matches anything".
  # That is the exact wrong-fix-hint shape: every app query (including ones that should read
  # "<unknown>") now confidently names a stack, and it is very often the WRONG one.
  f="$(mktemp)"
  # shellcheck disable=SC2016  # the sed PROGRAM is deliberately single-quoted so $(yq …) stays
  # literal (a pattern to match against the extracted source), never shell-expanded.
  extract_func "${REPO_ROOT}/${INSTALL}" "$FUNC" \
    | sed 's/^    \[\[ "\$(yq -r .*$/    true \&\& : # CANARY: exact-name comparison dropped — first candidate always wins/' \
    > "$f"
  if ! grep -q 'CANARY: exact-name comparison dropped' "$f"; then
    bad "SELF-TEST FAILED: could not build the dropped-comparison canary — the line it mutates was not found."
    rm -f "$f"
    return 2
  fi
  canary_rc=0
  check_owning_stack "$f" >/dev/null 2>&1 || canary_rc=$?
  rm -f "$f"
  if [[ "$canary_rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: the dropped exact-name-comparison canary was NOT detected (rc=${canary_rc}) — the detector is blind."
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0), dropped-exact-name-comparison canary (first candidate always wins) caught."
  return 1
}

# Rejects anything that is not --self-test / -h / --help, naming the offender, exit 2. Before this
# existed a one-hyphen typo (`--selftest`) silently ran the plain check and printed a green tick.
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

run_check "$REPO_ROOT"
exit $?
