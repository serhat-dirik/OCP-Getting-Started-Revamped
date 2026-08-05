#!/usr/bin/env bash
# check-adoption-skip — prove the three properties automatic component adoption rests on.
# READ-ONLY: renders manifests with kustomize, never touches a cluster.
#
#   SAFETY   argocd-bootstrap/install.sh §0 SKIPS a component when this cluster already runs that
#            operator, but only if the component is "operator-only" — it contributes nothing but the
#            operator install. That verdict comes from is_operator_only(), which reads FILENAMES.
#            This check re-derives it from the RENDERED manifests: every resource an operator-only
#            component emits must be a Namespace, an OperatorGroup or a Subscription. A stray operand
#            in a file called subscription-extra.yaml would pass the filename test and fail here,
#            which is exactly the drift that would ship a silently incomplete workshop.
#
#   NOT CHECKED HERE — and this is the gap that let the 2026-08-01 openshift-pipelines regression
#            ship. Both properties below are quantified over whatever is CURRENTLY skippable, so a
#            component that STOPS being skippable simply stops being examined: 49a7e28 added
#            components/openshift-pipelines/tekton-config.yaml, is_operator_only() (which reads
#            filenames) demoted the component, and this check stayed green without ever printing the
#            word "openshift-pipelines". The expected-skippable set lives in
#            hack/adoption-skippable.snapshot and is gated by tools/lint/adoption-skippable-guard.sh
#            (CI job `adoption-skippable`); this file answers "is skipping safe?", that one answers
#            "is the set of things we may skip still what we agreed to?".
#
#   MECHANICS A skip is delivered as a kustomize `$patch: delete` on the parent Application, not by
#            editing the repo. This check renders every stack with each of its skippable components
#            simulated as skipped and asserts the child Application is GONE and every other child
#            survives byte-identically. `$patch: delete` is a strategic-merge directive; the JSON6902
#            form cannot delete a resource, and a silent no-op patch would install the operator we
#            just promised the cluster's owner we would not touch.
#
#   VIABILITY (property 3, added 2026-08-05 after this file printed
#            "✅ automatic component adoption is safe across the portfolio" over a live break).
#            Properties 1 and 2 together say: the child Application disappears and every OTHER child
#            is byte-identical. Both were true of `keycloak-operator`, and the green line even
#            counted the survivor — "leaves 1 sibling(s) untouched". Untouched is not the same as
#            still able to work. components/keycloak-operator/namespace.yaml was the ONLY thing in
#            the portfolio that created namespace `sso-workshop`; its sibling `keycloak` ships six
#            resources INTO that namespace, creates none of its own, and its child Application
#            carries no CreateNamespace=true. Skip the operator component and the survivor is intact
#            and non-viable. Counting siblings is not checking them.
#            The same reasoning applies one level up: an OperatorGroup is what scopes an operator to
#            a namespace, so removing the only OperatorGroup covering a namespace where a sibling
#            places operand CRs leaves those CRs with no controller — the CR applies, Argo goes
#            green, and nothing ever reconciles it. That failure is quieter than a missing namespace,
#            which is why it is asserted separately rather than folded into the namespace rule.
#
#            Quantified over the CURRENTLY skippable set, deliberately, and unlike the
#            openshift-pipelines gap that is sound here: a component that stops being skippable is a
#            component the installer will never drop, so its viability stops mattering. The set is
#            printed either way (examined AND not-examined, by name) so a silently shrinking
#            candidate list cannot masquerade as a clean run, and hack/adoption-skippable.snapshot
#            plus tools/lint/adoption-skippable-guard.sh make the shrinking itself reviewable.
#
#   LEDGER   Property 3 found a real strand the hour it landed: components/keycloak-operator is the
#            SOLE creator of namespace `sso-workshop` and the SOLE component scoping an OperatorGroup
#            to it, while sibling `keycloak` ships operand CRs there and creates neither. The owner's
#            call was that install.sh REFUSES loudly rather than skipping (§0's strand branch, which
#            runs this same detector), and that making RHBK genuinely coexist with an org's own
#            Keycloak operator is a SEPARATE, DEFERRED decision. So the defect legitimately outlives
#            this gate — and a gate that is permanently red is a gate people stop reading.
#            KNOWN_STRANDS below declares that exact strand by component + kind + namespace + sibling.
#            A strand it names reports ⚠ DECLARED and does NOT fail the run; any other strand is still
#            ❌ and still exits 1, which is the whole point — the gate stays live for NEW breaks.
#            The ledger cannot rot silently either: an entry matching no strand in this run FAILS and
#            says to delete it, so the day somebody fixes keycloak the ledger cannot go on asserting a
#            defect that is gone. That is the stale-doc failure this project keeps paying for, and the
#            same two-directional ratchet as tools/lint/_canary-coverage.py's EXEMPT/KNOWN_UNPROVEN.
#            Adding an entry is an OWNER decision, not a way to get CI green — see README § Adoption.
#
# Usage: ./hack/check-adoption-skip.sh [--self-test]
#   --self-test  drive the property-3 detector AND the ledger against hand-built fixtures and prove
#                each fires; exits 1 when every canary behaves, matching the convention CI asserts on.
# Exit 0 = all three properties hold, modulo strands the ledger declares. Exit 1 = violations listed
# above, or a ledger entry that has gone stale. Exit 2 = missing tooling, an argument this script does
# not support, or a malformed ledger (all three mean it never checked what you asked it to).
set -euo pipefail

PORTFOLIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS_DIR="${PORTFOLIO_DIR}/stacks"
REPO_ROOT="$(cd "${PORTFOLIO_DIR}/.." && pwd)"
ARGO_NS="openshift-gitops"
FAILURES=0
DECLARED=0        # strands matched by KNOWN_STRANDS — accepted debt, reported but never counted as failures
DECLARED_LINES="" # "<comp> <kind> <ns> <sib> <reason>" per declared strand, reprinted in the summary block

# The installer's own classifier and patch renderer — sourced, never re-implemented.
# shellcheck disable=SC1091  # lib-components.sh is linted standalone; its path is runtime-derived
. "${PORTFOLIO_DIR}/argocd-bootstrap/lib-components.sh"

ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
hint() { echo "     ↳ $*"; }
warn() { echo "  ⚠ DECLARED $*"; }   # accepted debt: named in KNOWN_STRANDS, so NOT counted as a failure

# ── KNOWN_STRANDS — declared, accepted, dated adoption debt ────────────────────────────────────────
# One line per strand the portfolio is KNOWN to carry and has DECIDED not to fix yet. Format:
#
#   <component> <NS|OG> <namespace> <sibling> :: <YYYY-MM-DD> | <why it is accepted> | decision: <who/what defers it>
#
# The four key fields must match a strand exactly (they are compared verbatim against the detector's
# own "<kind> <ns> <sibling>" output for that component), so an entry can never accidentally cover a
# strand nobody looked at. Both halves of the reason are mandatory and enforced by ledger_lint(): a
# date, a justification, and the decision that keeps it open. Growing this list is an OWNER decision —
# it converts a red gate into accepted debt, which is exactly the move that needs a name against it.
#
# EMITTED by a function, not assigned with `VAR=$(cat <<'EOF' … )`. Measured on 2026-08-06: bash 3.2
# (the shell on every macOS maintainer box) mis-parses an apostrophe inside a quoted heredoc nested in
# a command substitution — "an org's own operator" alone made the whole file a syntax error, while the
# identical heredoc in a function body parses clean. A ledger is prose humans will edit; it must not
# detonate on the first possessive somebody types.
known_strands() {  # → the declared ledger, one entry per line
  cat <<'EOF'
keycloak-operator NS sso-workshop keycloak :: 2026-08-05 | keycloak-operator solely creates namespace sso-workshop; sibling keycloak deploys six resources there and creates none of its own. install.sh §0 REFUSES adoption on this strand rather than silently skipping, so no cluster installs incomplete. | decision: owner deferred functional RHBK coexistence (letting an organisation's own Keycloak operator manage our operands) to a separate decision; until it is taken the loud refusal is the intended behaviour, not a bug to route around
keycloak-operator OG sso-workshop keycloak :: 2026-08-05 | keycloak-operator solely scopes an OperatorGroup to sso-workshop; sibling keycloak places operand CRs there, which without that group would apply, report Synced in Argo, and never reconcile. The same install.sh §0 refusal covers it. | decision: owner deferred functional RHBK coexistence to a separate decision; kept apart from the NS entry because an uncontrolled operand fails more quietly than a missing namespace, so fixing one does not retire the other
EOF
}

ledger_lint() {  # <ledger-file> — reject a malformed entry loudly; a ledger we cannot parse checks nothing
  # Character classes, not `{4}`: BSD/macOS awk has not always supported interval expressions, and
  # this file already avoids the equivalent BSD grep traps.
  awk -v D='^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ' '
    !NF || $1 ~ /^#/ { next }
    {
      i = index($0, " :: ")
      if (!i) { print "line " NR ": no \" :: \" separating the key from the reason"; bad = 1; next }
      key = substr($0, 1, i - 1); why = substr($0, i + 4)
      if (split(key, f, /[ \t]+/) != 4)
        { print "line " NR ": key must be exactly <component> <NS|OG> <namespace> <sibling>"; bad = 1 }
      else if (f[2] != "NS" && f[2] != "OG")
        { print "line " NR ": kind \"" f[2] "\" is neither NS nor OG"; bad = 1 }
      if (why !~ D) { print "line " NR ": reason must start with a YYYY-MM-DD date"; bad = 1 }
      if (why !~ /\| decision: [^ ]/) { print "line " NR ": reason must end with \"| decision: <...>\""; bad = 1 }
    }
    END { exit bad }' "$1"
}

strand_reason() {  # <ledger> <comp> <kind> <ns> <sib> → print the declared reason; rc 1 when undeclared
  awk -v c="$2" -v k="$3" -v n="$4" -v s="$5" '
    !NF || $1 ~ /^#/ { next }
    $1 == c && $2 == k && $3 == n && $4 == s {
      i = index($0, " :: "); print substr($0, i + 4); found = 1; exit }
    END { exit !found }' "$1"
}

report_strand() {  # <ledger> <stack> <comp> <kind> <ns> <sib> — ❌ (counts) or ⚠ DECLARED (does not)
  # Returns 0 on BOTH paths on purpose. It is called bare from the property-3 loop, and a bare-called
  # function whose last statement evaluates false takes the whole script down under `set -e` — the
  # shape that silently skipped cleanup_created_operators' steps 4-8 on 2026-07-25 (CLAUDE.md).
  local ledger="$1" stack="$2" comp="$3" kind="$4" ns="$5" sib="$6" why
  if why="$(strand_reason "$ledger" "$comp" "$kind" "$ns" "$sib")"; then
    DECLARED=$((DECLARED + 1))
    DECLARED_LINES="${DECLARED_LINES}${DECLARED_LINES:+$'\n'}${comp} ${kind} ${ns} ${sib} ${why}"
    # The reason is NOT repeated here — the summary block at the end prints it once, in full, where a
    # reader is looking for accepted debt rather than scanning per-component ticks.
    warn "${comp} (stack ${stack}) ${kind} strand on ${ns} → sibling ${sib}: known, accepted, NOT fixed"
    return 0
  fi
  case "$kind" in
    NS) bad "${comp} (stack ${stack}) alone creates namespace ${ns}, but sibling ${sib} deploys into it and creates none of its own" ;;
    OG) bad "${comp} (stack ${stack}) alone scopes an OperatorGroup to ${ns}, but sibling ${sib} places operand CRs there — skipping it leaves them with no controller" ;;
    *)  bad "${comp} (stack ${stack}) strands ${sib} in ${ns} (${kind})" ;;
  esac
  return 0
}

report_stale_declarations() {  # <ledger> <observed-file> — a declaration outliving its defect is a FAILURE
  # The half of the ratchet that stops the ledger rotting. An entry naming a strand this run did not
  # observe means either the defect was fixed or the component stopped being skippable; either way the
  # entry now asserts something untrue, and a ledger nobody is forced to prune is a stale doc with a
  # green tick over it. Same rule as _canary-coverage.py's "key no longer enumerates" error.
  local ledger="$1" observed="$2" key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! grep -qxF "$key" "$observed"; then
      bad "KNOWN_STRANDS declares '${key}' but this run observed no such strand"
      hint "Either it was fixed (delete the entry — a ledger must not outlive its defect), or the"
      hint "component stopped being skippable, in which case it can never be dropped and needs no entry."
    fi
  done < <(awk 'NF && $1 !~ /^#/ { print $1, $2, $3, $4 }' "$ledger")
  return 0
}

# Arguments are refused rather than ignored. A script that discards an argument still prints the
# ticks and exits 0, and that verdict describes a run nobody asked for — the exact misreading
# tools/lint/adoption-skippable-guard.sh was rewritten for on 2026-08-01.
SELF_TEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    # Derived, not a line range: `sed -n '2,45p'` was already cutting the Usage and exit-code lines
    # off its own help text before the LEDGER section pushed the header down further. A hard-coded
    # count in a file that grows is a stale doc waiting to happen (CLAUDE.md says so about this repo's
    # own lint-job count). Print the leading comment block, stop at the first line of code.
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/ && NF) exit; print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "❌ unknown argument: $1 — see --help" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Materialised once so the ledger readers take a FILE — which is what lets --self-test drive the very
# same functions against fixture ledgers instead of a re-implementation of them.
LEDGER="${WORK}/known-strands.ledger"
known_strands > "$LEDGER"
if ! ledger_problems="$(ledger_lint "$LEDGER")"; then
  echo "❌ KNOWN_STRANDS is malformed — refusing to run, because a ledger this script cannot parse" >&2
  echo "   silently declares nothing and would report accepted debt as a fresh break (or vice versa):" >&2
  # sed, not `printf '   %s\n'`: the format is applied once per ARGUMENT, so a multi-line variable
  # gets exactly one indent and every problem after the first hangs off the left margin.
  printf '%s\n' "$ledger_problems" | sed 's/^/   /' >&2
  exit 2
fi

self_test() {  # drive the SHARED strand detector AND the ledger against planted fixtures; prove both fire
  # An unrun gate is worse than none, so CI runs this first and asserts it exits EXACTLY 1.
  #   A-C  the detector: catches a planted strand (A), stays silent on two look-alikes (B, C).
  #   D-F  the KNOWN_STRANDS ratchet, which is what lets the real run exit 0 over accepted debt:
  #        an UNDECLARED strand still counts toward the exit code (D), a DECLARED one counts zero (E),
  #        and an entry that no longer matches any strand FAILS while a live one does not (F).
  # D-F call the very functions the real run calls and measure their effect on the real FAILURES
  # counter, then restore it — a re-implementation of the accounting could pass while the gate is
  # broken. Fact tables and ledgers are hand-built here (no kustomize/yq), so this proves live on any
  # box. Exit 1 = every canary behaved (healthy); exit 2 = one did not (do not trust a green run).
  local ft="${WORK}/self-test.facts" good=0 total=0 out
  local lf="${WORK}/self-test.ledger" ob="${WORK}/self-test.observed" probe="${WORK}/self-test.probe"
  local before delta keep_declared keep_lines
  echo "▶ self-test: the strand detector fires on a planted strand, and the ledger accepts only what it names"

  # A — the keycloak topology, replayed: an operator-only component ALONE creates + scopes a namespace
  # a non-skipped sibling deploys into. The detector MUST fire.
  cat > "$ft" <<'EOF'
stack fx-operator fx
opts fx-operator -
creates fx-operator fx-ns
ogns fx-operator fx-ns
uses fx-operator fx-ns
stack fx-instance fx
opts fx-instance -
uses fx-instance fx-ns
EOF
  total=$((total + 1))
  out="$(component_strands "$ft" fx-operator || true)"
  if [[ -n "$out" ]]; then
    good=$((good + 1)); ok "A keycloak topology: strand CAUGHT ($(printf '%s' "$out" | tr '\n' ';'))"
  else
    bad "A keycloak topology: the planted strand was NOT caught — the detector is dead"
  fi

  # B — the sibling's child App carries CreateNamespace=true, so it self-provisions. NOT a strand.
  cat > "$ft" <<'EOF'
stack fx-operator fx
opts fx-operator -
creates fx-operator fx-ns
uses fx-operator fx-ns
stack fx-instance fx
opts fx-instance CreateNamespace=true
uses fx-instance fx-ns
EOF
  total=$((total + 1))
  if [[ -z "$(component_strands "$ft" fx-operator || true)" ]]; then
    good=$((good + 1)); ok "B sibling sets CreateNamespace=true: correctly NOT flagged"
  else
    bad "B sibling sets CreateNamespace=true: wrongly flagged — a false positive would block a valid install"
  fi

  # C — the sibling creates the namespace itself. NOT a strand.
  cat > "$ft" <<'EOF'
stack fx-operator fx
opts fx-operator -
creates fx-operator fx-ns
uses fx-operator fx-ns
stack fx-instance fx
opts fx-instance -
creates fx-instance fx-ns
uses fx-instance fx-ns
EOF
  total=$((total + 1))
  if [[ -z "$(component_strands "$ft" fx-operator || true)" ]]; then
    good=$((good + 1)); ok "C sibling creates the namespace itself: correctly NOT flagged"
  else
    bad "C sibling creates the namespace itself: wrongly flagged (false positive)"
  fi

  # D — a strand the ledger does NOT name is still ❌ and still contributes to the exit code. The
  # fixture ledger is deliberately non-empty but names a DIFFERENT strand: an empty one would let a
  # lookup that never matches anything pass, and a lookup that matches everything fail loudly here.
  cat > "$lf" <<'EOF'
other-operator NS other-ns other-sibling :: 2026-08-05 | fixture: declares an unrelated strand | decision: fixture
EOF
  total=$((total + 1))
  before="$FAILURES"; keep_declared="$DECLARED"; keep_lines="$DECLARED_LINES"
  # Redirected to a FILE, not captured with $(…): command substitution runs a subshell, and the
  # increment to FAILURES this canary exists to measure would be discarded with it.
  report_strand "$lf" fx fx-operator NS fx-ns fx-instance > "$probe" 2>&1
  delta=$((FAILURES - before))
  FAILURES="$before"; DECLARED="$keep_declared"; DECLARED_LINES="$keep_lines"   # leave no residue
  if [[ "$delta" -eq 1 ]] && grep -q '❌' "$probe"; then
    good=$((good + 1)); ok "D undeclared strand: still ❌ and still counted — the gate stays live for NEW strands"
  else
    bad "D undeclared strand: contributed ${delta} failure(s) — the ledger is swallowing strands it never declared"
  fi

  # E — the same strand, now named by the ledger: reported as accepted debt, worth ZERO failures.
  # This is the property that lets the real run exit 0 while keycloak stays knowingly broken.
  cat > "$lf" <<'EOF'
fx-operator NS fx-ns fx-instance :: 2026-08-05 | fixture: declares exactly this strand | decision: fixture
EOF
  total=$((total + 1))
  before="$FAILURES"; keep_declared="$DECLARED"; keep_lines="$DECLARED_LINES"
  report_strand "$lf" fx fx-operator NS fx-ns fx-instance > "$probe" 2>&1
  delta=$((FAILURES - before))
  FAILURES="$before"; DECLARED="$keep_declared"; DECLARED_LINES="$keep_lines"
  if [[ "$delta" -eq 0 ]] && grep -q 'DECLARED' "$probe" && ! grep -q '❌' "$probe"; then
    good=$((good + 1)); ok "E declared strand: reported ⚠ DECLARED, added 0 failures"
  else
    bad "E declared strand: added ${delta} failure(s) — a declared strand would still redden the gate forever"
  fi

  # F — the anti-rot half. One entry matches an observed strand, one names a strand that is gone.
  # Exactly the stale entry must fail; the live one must stay quiet (the over-fire control, since a
  # staleness check that flags everything would "pass" a one-sided assertion).
  printf 'fx-operator NS fx-ns fx-instance\n' > "$ob"
  cat > "$lf" <<'EOF'
fx-operator NS fx-ns fx-instance :: 2026-08-05 | fixture: still matches a real strand | decision: fixture
gone-operator OG gone-ns gone-sibling :: 2026-08-05 | fixture: defect fixed, entry left behind | decision: fixture
EOF
  total=$((total + 1))
  before="$FAILURES"
  report_stale_declarations "$lf" "$ob" > "$probe" 2>&1
  delta=$((FAILURES - before)); FAILURES="$before"
  if [[ "$delta" -eq 1 ]] && grep -q 'gone-operator' "$probe" && ! grep -q 'fx-operator' "$probe"; then
    good=$((good + 1)); ok "F stale entry: the declaration that outlived its defect FAILED, the live one stayed quiet"
  else
    bad "F stale entry: ${delta} failure(s) — a ledger entry could outlive the defect it describes"
  fi

  echo
  if [[ "$good" -eq "$total" ]]; then
    echo "✅ self-test: ${good}/${total} detector + ledger canaries behaved — the strand gate is live."
    echo "   Exiting 1 BY DESIGN (the planted strand was caught); the CI step asserts this exact code."
    exit 1
  fi
  echo "❌ self-test: only ${good}/${total} canaries behaved — the detector or its ledger is unreliable."
  echo "   Refusing to let a green real run be trusted while the gate cannot catch a planted break."
  exit 2
}

# --self-test needs neither kustomize nor yq (it builds fact tables by hand, not from rendered
# manifests), so it runs BEFORE the render-tool check — a maintainer can prove the gate live anywhere.
if [[ "$SELF_TEST" == "1" ]]; then
  self_test   # exits 1 when every canary behaves (the code CI asserts on), 2 when one does not
fi

for tool in kustomize yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "❌ ${tool} not found in PATH — install it, then re-run"; exit 2; }
done

# ── property-3 machinery ──────────────────────────────────────────────────────
# A flat fact table, because bash 3.2 (the shell on every macOS maintainer box) has no associative
# arrays. One "<verb> <component> <value>" per line:
#   creates <comp> <ns>   the component RENDERS a Namespace object of that name
#   ogns    <comp> <ns>   it renders an OperatorGroup in that namespace
#   uses    <comp> <ns>   it places at least one resource there (or the child App targets it)
#   opts    <comp> <csv>  the child Application's syncOptions, "-" when it has none
#   stack   <comp> <name> the stack whose apps/ file syncs it
yq_names() {  # stdin: a rendered manifest stream, $1: a yq expression → one clean name per line
  # yq prints a `---` between documents and `null` for an absent field; awk, not grep -vE, because
  # BSD grep rejects the empty alternative that filtering both with one pattern would need.
  yq -r "$1" - | awk '$0 != "" && $0 != "---" && $0 != "null"' | sort -u
}

collect_facts() {  # <facts-file> — render every ACTIVE component of every stack, once
  local out="$1" stack_dir stack app cpath cdir comp rendered dest opts n
  : > "$out"
  for stack_dir in "${STACKS_DIR}"/*/; do
    stack="$(basename "$stack_dir")"
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      cpath="$(component_path_of "$stack" "$app" || true)"
      [[ -n "$cpath" ]] || continue
      cdir="${REPO_ROOT}/${cpath}"
      comp="$(basename "$cpath")"
      if ! rendered="$(kustomize build --enable-helm "$cdir" 2>/dev/null)"; then
        # Property 1 already reports a build failure for a skippable component; for a non-skippable
        # one we record nothing rather than inventing facts, and say so.
        echo "unrendered ${comp} -" >> "$out"
        continue
      fi
      dest="$(yq -r '.spec.destination.namespace // ""' "${STACKS_DIR}/${stack}/${app}")"
      opts="$(yq -r '(.spec.syncPolicy.syncOptions // []) | join(",")' "${STACKS_DIR}/${stack}/${app}")"
      echo "stack ${comp} ${stack}" >> "$out"
      echo "opts ${comp} ${opts:--}" >> "$out"
      while IFS= read -r n; do echo "creates ${comp} ${n}" >> "$out"; done \
        < <(printf '%s\n' "$rendered" | yq_names 'select(.kind == "Namespace") | .metadata.name')
      while IFS= read -r n; do echo "ogns ${comp} ${n}" >> "$out"; done \
        < <(printf '%s\n' "$rendered" | yq_names 'select(.kind == "OperatorGroup") | .metadata.namespace')
      while IFS= read -r n; do echo "uses ${comp} ${n}" >> "$out"; done \
        < <({ echo "$dest"; printf '%s\n' "$rendered" | yq -r '.metadata.namespace // ""' -; } \
              | awk '$0 != "" && $0 != "---" && $0 != "null"' | sort -u)
    done < <(active_app_files "$stack")
  done
}

# The strand detector (component_strands) and its _fact_has helper live in lib-components.sh, sourced
# above. The installer and this gate MUST reach the same verdict, so that logic is defined ONCE and
# shared; this file only BUILDS the fact table (collect_facts, from rendered manifests) and CONSUMES
# the verdict. An earlier draft re-implemented the detector here with yq — retired for that reason.

# Kinds an operator-only component is allowed to render. Anything else is an operand, config or
# workload the workshop would silently lose if the component were skipped.
OPERATOR_ONLY_KINDS='^(Namespace|OperatorGroup|Subscription)/'

echo "▶ [1/3] operator-only components render nothing but namespace + OperatorGroup + Subscription"
SKIPPABLE=""   # "<stack> <apps-file> <component> <child-app>" per skippable component
NOT_SKIPPABLE=""   # names only — printed by property 3 so a shrinking candidate set stays visible
for stack_dir in "${STACKS_DIR}"/*/; do
  stack="$(basename "$stack_dir")"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    # `|| true` is what makes the next line reachable. component_path_of is a grep|sed pipeline, so
    # under `set -o pipefail` an app file with no `path:` fails the substitution and `set -e` kills
    # the run HERE — the "no path, skip it" guard below never gets to execute. Same silent-death class
    # as the one that skipped uninstall steps 4-8 on 2026-07-25 (fix 8722a79).
    cpath="$(component_path_of "$stack" "$app" || true)"
    [[ -n "$cpath" ]] || continue
    cdir="${REPO_ROOT}/${cpath}"
    comp="$(basename "$cpath")"
    child="$(yaml_scalar "${STACKS_DIR}/${stack}/${app}" metadata name)"
    [[ -n "$child" ]] || child="pp-${comp}"
    if ! is_operator_only "$cdir"; then
      NOT_SKIPPABLE="${NOT_SKIPPABLE}${NOT_SKIPPABLE:+ }${comp}"
      continue
    fi
    SKIPPABLE="${SKIPPABLE}${SKIPPABLE:+$'\n'}${stack} ${app} ${comp} ${child}"

    if ! rendered="$(kustomize build --enable-helm "$cdir" 2>/dev/null)"; then
      bad "${comp}: classified operator-only but kustomize build fails"
      continue
    fi
    printf '%s\n' "$rendered" \
      | yq -r '[(.kind // "?"), (.metadata.name // "?")] | join("/")' - > "${WORK}/kinds.txt"
    offenders="$(grep -vE "$OPERATOR_ONLY_KINDS" "${WORK}/kinds.txt" || true)"
    if [[ -n "$offenders" ]]; then
      bad "${comp}: classified operator-only, but renders $(printf '%s' "$offenders" | tr '\n' ' ')"
      hint "install.sh §0 would DROP this component on a cluster that already runs the operator,"
      hint "taking those resources with it. Either move them to their own component, or rename the"
      hint "file so is_operator_only() stops matching (lib-components.sh)."
    else
      ok "${comp} (stack ${stack}) — skippable, renders only operator install resources"
    fi
  done < <(active_app_files "$stack")
done
[[ -n "$SKIPPABLE" ]] || bad "no skippable component found at all — is_operator_only() matches nothing"

# yq emits a `---` separator between documents and prints `null` for an empty stream, so the raw
# name list needs normalising before two renders can be compared.
app_names() {  # <kustomize dir> → one child Application name per line
  # awk, not grep -vE: BSD grep rejects an empty alternative, so `---|null|` is not portable.
  kustomize build "$1" 2>/dev/null \
    | yq -r '.metadata.name' - \
    | awk '$0 != "" && $0 != "---" && $0 != "null"'
}

echo "▶ [2/3] a simulated skip removes exactly one child Application from the rendered stack"
while read -r stack app comp child; do
  [[ -n "$stack" ]] || continue
  : "$app"
  rm -rf "${WORK}/sim"; mkdir -p "${WORK}/sim"
  cp -R "${STACKS_DIR}/${stack}" "${WORK}/sim/"
  simdir="${WORK}/sim/${stack}"

  before="$(app_names "${STACKS_DIR}/${stack}")"
  if [[ -z "$before" ]]; then
    bad "${stack}: renders no child Applications at all"; continue
  fi
  # Exactly what install.sh §2 hands Argo CD in spec.source.kustomize.patches. Argo appends those to
  # the stack's kustomization, which is what this reproduces.
  { echo "patches:"; skip_patch_block "$child" "$comp" "simulated skip" "$ARGO_NS"; } \
    >> "${simdir}/kustomization.yaml"
  if ! kustomize build "$simdir" >/dev/null 2>&1; then
    bad "${stack}/${comp}: kustomize build fails WITH the skip patch"
    hint "the \$patch: delete block in lib-components.sh no longer renders — see skip_patch_block()"
    continue
  fi
  after="$(app_names "$simdir")"

  expected="$(printf '%s\n' "$before" | grep -vx "$child" || true)"
  if printf '%s\n' "$after" | grep -qx "$child"; then
    bad "${stack}/${comp}: ${child} SURVIVED the skip patch — the operator would still be installed"
    hint "\$patch: delete must be a strategic-merge patch; JSON6902 cannot delete a resource"
  elif [[ "$after" != "$expected" ]]; then
    bad "${stack}/${comp}: the skip patch changed other children of the stack"
    hint "expected: $(printf '%s' "$expected" | tr '\n' ' ')"
    hint "rendered: $(printf '%s' "$after"    | tr '\n' ' ')"
  else
    ok "${stack}: skipping ${comp} removes ${child} and leaves $(printf '%s\n' "$after" | grep -c . ) sibling(s) untouched"
  fi
done <<< "$SKIPPABLE"

echo "▶ [3/3] skipping an operator-only component strands no sibling in a namespace only it provides"
# Properties 1-2 say the child Application disappears and every OTHER child renders byte-identically.
# Both were TRUE of keycloak-operator, and [2/2] even counted the survivor — but "untouched" is not
# "still able to work". collect_facts() renders every active component once; the SHARED detector
# (lib-components.sh component_strands) then reads that fact table and reports any sibling left
# deploying into a namespace, or placing operand CRs under an OperatorGroup, that ONLY the skipped
# component provides. The installer runs the same detector over its own (grep-built) table.
FACTS="${WORK}/facts.txt"
collect_facts "$FACTS"
OBSERVED="${WORK}/observed-strands.txt"
: > "$OBSERVED"   # must exist even when the portfolio has no strands at all — the staleness check reads it
EXAMINED=""
while read -r stack app comp child; do
  [[ -n "$comp" ]] || continue
  : "$app" "$child"
  EXAMINED="${EXAMINED}${EXAMINED:+ }${comp}"
  strands="$(component_strands "$FACTS" "$comp" || true)"
  if [[ -z "$strands" ]]; then
    ok "${comp} (stack ${stack}) — safe to skip: no sibling depends on a namespace only it provides"
    continue
  fi
  undeclared=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r kind ns sib <<< "$line"
    # Recorded BEFORE the verdict, so the staleness check sees every strand that really exists —
    # including ones that failed. An entry is stale when the strand is GONE, not when it is red.
    echo "${comp} ${kind} ${ns} ${sib}" >> "$OBSERVED"
    strand_reason "$LEDGER" "$comp" "$kind" "$ns" "$sib" >/dev/null || undeclared=1
    report_strand "$LEDGER" "$stack" "$comp" "$kind" "$ns" "$sib"
  done <<< "$strands"
  if [[ "$undeclared" -eq 1 ]]; then
    hint "install.sh §0 would DROP ${comp} on a cluster already running its operator, taking the namespace(s) above with it."
    hint "Fix: move the Namespace/OperatorGroup into the sibling (or a shared base), or drop the stack on adoption."
  else
    hint "install.sh §0 REFUSES adoption of ${comp} rather than skipping it, so no cluster installs incomplete."
    hint "Accepted debt, not a clean bill: fixing it is an owner decision — see README § Adoption."
  fi
done <<< "$SKIPPABLE"

# The ledger's second direction: an entry that names no strand this run observed is now a lie.
report_stale_declarations "$LEDGER" "$OBSERVED"

# The doc comment promises the candidate set is printed either way, so a silently shrinking set of
# things we examine cannot masquerade as a clean run (the openshift-pipelines gap, in prose form).
echo "   examined (skippable, so droppable on adoption): ${EXAMINED:-none}"
echo "   not examined (not skippable, so never dropped): ${NOT_SKIPPABLE:-none}"

if [[ "$DECLARED" -gt 0 ]]; then
  echo
  echo "▶ declared known strands — ACCEPTED DEBT, still broken, deliberately not failing this gate"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r d_comp d_kind d_ns d_sib d_why <<< "$line"
    echo "  ⚠ ${d_comp}: ${d_kind} strand on namespace ${d_ns}, sibling ${d_sib} left non-viable if it is skipped"
    echo "     ${d_why}"
  done <<< "$DECLARED_LINES"
  echo "  These are NOT safe to skip. They are declared in KNOWN_STRANDS (top of this file) so a"
  echo "  standing, owner-accepted defect cannot hide a NEW one behind a permanently red gate."
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  if [[ "$DECLARED" -gt 0 ]]; then
    # Deliberately NOT "adoption is safe across the portfolio": ${DECLARED} component/namespace pairs
    # above are known-broken, and a green line claiming blanket safety over them is the exact false
    # reassurance property 3 was added to kill.
    echo "✅ no NEW adoption break — every property holds except the ${DECLARED} strand(s) declared above,"
    echo "   which remain BROKEN by owner decision and are re-checked on every run."
  else
    echo "✅ automatic component adoption is safe across the portfolio"
  fi
  exit 0
fi
echo "❌ ${FAILURES} violation(s) — see platform-portfolio/README.md § Adoption"
exit 1
