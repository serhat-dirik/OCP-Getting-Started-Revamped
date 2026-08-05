#!/usr/bin/env bash
#
# Render apps/parasol-service-template/skeleton/ the way RHDH's scaffolder renders it, so the
# result can be built and tested like any other Maven module.
#
# Why this exists: the skeleton ships a real @QuarkusTest (src/test/java/.../InfoResourceTest.java)
# that nothing ever ran. apps-test.yml's discovery walk deliberately skips this directory, and it is
# right to: the raw pom's <artifactId> is the scaffolder placeholder "${{ values.name }}", which
# Maven rejects outright with "does not match a valid id pattern". So the module was excluded from
# the test gate for a true reason, and then had no gate of any kind.
#
# It is not inert. This is the golden-path template the RHDH module has every attendee scaffold
# from; template.yaml's fetch:template step renders it and publish:gitea pushes the result into the
# attendee's own Gitea org. A skeleton whose test no longer compiles does not fail in CI — it fails
# live, in front of a room, the first time an attendee runs the build command their generated
# README told them to run.
#
# The substitution below is not an approximation of fetch:template — for this skeleton it is
# exactly it. The skeleton uses two placeholders, name and owner, and the drift checks in
# resolve_placeholders() refuse to render if that stops being true.
#
# Usage: render-skeleton.sh <output-dir> [service-name] [owner]
#        render-skeleton.sh --self-test
# Exits 1 on any drift between the skeleton, this renderer, and template.yaml.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skeleton="$here/skeleton"
template="$here/template.yaml"

if [ "${1:-}" = "--self-test" ]; then
  self_test=1
  out=""
  svc_name="parasol-ci-probe"
  svc_owner="parasol"
else
  self_test=0
  out="${1:?usage: render-skeleton.sh <output-dir> [service-name] [owner]}"
  svc_name="${2:-parasol-ci-probe}"
  svc_owner="${3:-parasol}"
fi

# The placeholder keys this renderer knows how to substitute. Adding one here means adding a
# corresponding substitution in render() below.
known_keys=(name owner)

die() {
  echo "::error::render-skeleton: $*" >&2
  exit 1
}

# Both values are interpolated into a perl program below, so keep them to the shape RHDH's own
# `name` parameter allows (its template.yaml pattern is a DNS-label-ish slug). This is input
# hygiene, not policy: a value containing a slash or a quote would corrupt the substitution.
for v in "$svc_name" "$svc_owner"; do
  case "$v" in
    *[!a-z0-9-]* | "" | -* )
      die "invalid value '$v': use lowercase alphanumerics and dashes, not starting with a dash." ;;
  esac
done

# Keys actually referenced by the skeleton tree, e.g. `${{ values.name }}` -> name.
used_keys() {
  grep -rEoh '\$\{\{[[:space:]]*values\.[A-Za-z0-9_]+[[:space:]]*\}\}' "$skeleton" 2>/dev/null \
    | sed -E 's/.*values\.([A-Za-z0-9_]+).*/\1/' \
    | sort -u
}

# Keys template.yaml actually hands to fetch:template. Parsed positionally rather than with yq so
# this script has no dependency beyond coreutils: find the fetch:template step, take the `values:`
# mapping that follows it, and collect the keys indented under it.
supplied_keys() {
  awk '
    /^[[:space:]]*action:[[:space:]]*fetch:template[[:space:]]*$/ { in_step = 1; next }
    in_step && match($0, /^[[:space:]]*values:[[:space:]]*$/) {
      match($0, /^[[:space:]]*/); values_indent = RLENGTH
      in_values = 1; in_step = 0; next
    }
    in_values {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      match($0, /^[[:space:]]*/); indent = RLENGTH
      if (indent <= values_indent) { in_values = 0; next }
      if (match($0, /^[[:space:]]*[A-Za-z0-9_]+:/)) {
        key = $0
        sub(/^[[:space:]]*/, "", key)
        sub(/:.*$/, "", key)
        print key
      }
    }
  ' "$template" | sort -u
}

resolve_placeholders() {
  [ -d "$skeleton" ] || die "skeleton directory not found at $skeleton"
  [ -f "$template" ] || die "template.yaml not found at $template"

  # A skeleton with no test is a green gate that proves nothing about the thing being gated.
  local tests
  tests="$(find "$skeleton/src/test/java" -name '*Test.java' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$tests" -gt 0 ] || die \
    "skeleton has no *Test.java under src/test/java. This gate exists to run the skeleton's" \
    "tests; with none there it would report green having verified nothing."

  local used known supplied
  used="$(used_keys)"
  known="$(printf '%s\n' "${known_keys[@]}" | sort -u)"
  supplied="$(supplied_keys)"

  [ -n "$supplied" ] || die \
    "could not parse any values: keys out of the fetch:template step in template.yaml." \
    "Either the step moved or this parser is broken — refusing to render against an unknown" \
    "contract."

  # Drift 1: the skeleton uses a placeholder this renderer cannot substitute. Rendering anyway
  # would leave a literal placeholder in the pom and fail Maven with a confusing error.
  local unknown
  unknown="$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$known") || true)"
  if [ -n "$unknown" ]; then
    die "the skeleton references placeholder key(s) this renderer does not substitute:" \
      "$(echo "$unknown" | tr '\n' ' ')- teach render() in $0 how to render them."
  fi
}

# Drift 2 is checked separately because it is a defect in the template, not in this renderer: a
# placeholder the skeleton uses but template.yaml never supplies renders as literal
# "${{ values.x }}" text inside the attendee's generated repository.
check_template_supplies_everything() {
  local missing
  missing="$(comm -23 <(used_keys) <(supplied_keys) || true)"
  if [ -n "$missing" ]; then
    die "the skeleton references placeholder key(s) that template.yaml's fetch:template step" \
      "does not supply: $(echo "$missing" | tr '\n' ' ')- every attendee scaffolding this" \
      "template would get the literal placeholder text in their generated repo."
  fi
}

render() {
  rm -rf "$out"
  mkdir -p "$out"
  cp -R "$skeleton"/. "$out"/

  # Substitute only in files that actually carry a placeholder, so nothing else is rewritten.
  local f
  # SC2016 throughout this function is the point: these single-quoted strings are the literal
  # scaffolder placeholder text we are searching for, not shell expansions we want expanded.
  # shellcheck disable=SC2016
  while IFS= read -r f; do
    perl -pi -e "
      s/\\\$\\{\\{\\s*values\\.name\\s*\\}\\}/$svc_name/g;
      s/\\\$\\{\\{\\s*values\\.owner\\s*\\}\\}/$svc_owner/g;
    " "$f"
  done < <(grep -rlF '${{' "$out" || true)

  # Belt and braces: whatever the drift checks reasoned about, the rendered tree must contain no
  # scaffolder placeholder at all. This is the check that cannot be fooled by a parser bug above.
  local residual
  # shellcheck disable=SC2016
  residual="$(grep -rn '\${{' "$out" || true)"
  if [ -n "$residual" ]; then
    die "rendered tree still contains scaffolder placeholders:"$'\n'"$residual"
  fi
}

# --- self-test -------------------------------------------------------------------------------
#
# Exit-code contract, matching the guards under tools/lint:
#   1 = every planted defect was detected by name AND the unmutated skeleton still renders clean.
#       This is the PASSING outcome; CI asserts exactly 1.
#   0 = guard blind (nothing detected).
#   2 = a case went undetected, the benign case wrongly fired, or the fixture could not be built.
#
# Each case mutates a full COPY of this directory (script, skeleton and template.yaml together)
# and runs the copied script against it, so the real tree is never touched.
run_self_test() {
  local tmp total=0 detected=0 problems=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  _case() { # label, mutation, expected-substring
    local label="$1" mutation="$2" expect="$3" work="$tmp/case-$((total + 1))" rc=0 output
    total=$((total + 1))
    mkdir -p "$work"
    cp -R "$here"/. "$work"/
    if ! ( cd "$work" && eval "$mutation" ); then
      echo "SELF-TEST FIXTURE BROKEN: could not apply mutation for '$label'"
      problems=$((problems + 1))
      return 0
    fi
    output="$("$work/render-skeleton.sh" "$work/rendered" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "UNDETECTED: '$label' rendered successfully — this defect would reach an attendee."
      problems=$((problems + 1))
    elif ! printf '%s' "$output" | grep -qF "$expect"; then
      echo "MISDIAGNOSED: '$label' failed (rc=$rc) but not for the expected reason."
      echo "  expected to see: $expect"
      problems=$((problems + 1))
    else
      echo "detected: $label"
      detected=$((detected + 1))
    fi
  }

  # The mutation strings below are shell fragments eval'd inside the fixture copy, and the
  # placeholder text in them is meant to stay literal — SC2016 is describing the intent.
  # shellcheck disable=SC2016
  _case "skeleton uses a placeholder the renderer cannot substitute" \
    'printf "%s\n" "# \${{ values.bogusKey }}" >> skeleton/README.md' \
    "does not substitute"

  _case "template.yaml stops supplying a key the skeleton uses" \
    'perl -0pi -e "s/\n[[:space:]]+owner: \\\$\{\{ parameters\.owner \}\}//"  template.yaml' \
    "does not supply"

  _case "skeleton loses its test suite" \
    'rm -f skeleton/src/test/java/com/parasol/service/InfoResourceTest.java' \
    "no *Test.java"

  # shellcheck disable=SC2016
  _case "a non-values placeholder survives rendering" \
    'printf "%s\n" "# \${{ parameters.sneaky }}" >> skeleton/README.md' \
    "still contains scaffolder placeholders"

  # Benign case: the real, unmutated tree must render cleanly. A guard that fires on everything is
  # as useless as one that fires on nothing.
  local benign_rc=0
  ( cd "$tmp" && cp -R "$here"/. . && ./render-skeleton.sh "$tmp/benign-out" ) >/dev/null 2>&1 \
    || benign_rc=$?
  if [ "$benign_rc" -ne 0 ]; then
    echo "FALSE POSITIVE: the unmutated skeleton failed to render (rc=$benign_rc)."
    problems=$((problems + 1))
  else
    echo "clean: unmutated skeleton renders without complaint"
  fi

  echo "self-test: $detected/$total planted defects detected, $problems problem(s)"
  if [ "$problems" -gt 0 ]; then return 2; fi
  if [ "$detected" -eq 0 ]; then return 0; fi
  if [ "$detected" -ne "$total" ]; then return 2; fi
  return 1
}

if [ "$self_test" -eq 1 ]; then
  rc=0
  run_self_test || rc=$?
  exit "$rc"
fi

resolve_placeholders
check_template_supplies_everything
render

echo "render-skeleton: rendered $skeleton -> $out (name=$svc_name, owner=$svc_owner)"
