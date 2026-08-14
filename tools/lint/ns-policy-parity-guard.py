#!/usr/bin/env python3
"""ns-policy-parity-guard.py — the per-user namespace resource policy is defined TWICE. Prove the
two definitions still say the same thing.

WHY THIS EXISTS (found 2026-08-14, one day after the defect landed).

The ResourceQuota/LimitRange policy for every {user}-<suffix> namespace is authored in two places:

  gitops/workshop-config/templates/per-user-*.yaml   ← LIVE today. Renders the objects that are
                                                       actually on the cluster.
  gitops/user-namespace/templates/_helpers.tpl       ← the quotaSpec helper, canonical source for
                                                       tools/gen-entry-namespaces.sh, which byte-
                                                       copies it into all 26 entry-state charts.

Helm cannot share templates across chart roots, so the duplication is structural and is not going
away (same rationale as ADR-0001 / copy-drift-guard.py). What was missing was any gate between them.

Commit 13ed4ef raised, in workshop-config, the dev/stage/prod/cicd LimitRange `default.cpu`
500m -> 1500m and the ResourceQuota `limits.cpu` 6 -> 8. That one change took the app-security-testing
capstone from 1414s to 821s: every Maven/Quarkus/ZAP step declares no CPU limit of its own, so all of
them had been running pegged at half a core. The quotaSpec helper was not updated and kept 500m/6.

NOTHING COULD HAVE CAUGHT IT. Not a test, not `ws doctor`, not the cluster:
  * the helper's render is gated behind `manageNamespaces`, false in all 26 entry-state charts, so
    it emits ZERO objects today — there is no live symptom to observe;
  * tools/gen-entry-namespaces.sh --check only proves the 26 COPIES match the helper, and they did
    — all 26 were faithfully carrying the stale numbers;
  * copy-drift-guard.py gates the helper against its own copies for the same reason, not against
    workshop-config. These two are not a registered pair and structurally cannot be one: its
    `_render_chart` cannot pass the `--set user=…/suffixes=…` this chart REQUIRES (assertInputs
    fails without them), and its `select` keys on kind+name — both sides name every object
    `workshop-quota`/`workshop-limits` and differ only by NAMESPACE, so a selector would match 13
    documents and error out.
So the drift was invisible until the manageNamespaces migration flipped, at which point it would
have silently reverted a measured 42% pipeline speedup on a live workshop.

WHAT IT COMPARES, AND WHAT IT DELIBERATELY IGNORES.

Both charts are RENDERED (a Helm template is not YAML until Helm has run) and reduced to the policy
that reaches the cluster:

    ResourceQuota  -> .spec.hard
    LimitRange     -> .spec.limits, re-keyed by each item's `type` so list ORDER cannot matter

keyed by (namespace, kind). Everything else about these objects legitimately differs and is none of
this guard's business: the user-namespace copy carries `argocd.argoproj.io/sync-wave` and
`sync-options: Prune=false` annotations that workshop-config has no use for, the two charts stamp
different owner-label helpers, and the comments differ on purpose (each file explains its own
numbers). A guard that compared whole documents would fail on all of that and would have to be
switched off — the "reddened main on work that is right" failure mode copy-drift-guard.py's own
docstring warns about.

QUANTITIES ARE COMPARED AS QUANTITIES, NOT AS TEXT. `pods: 30` and `pods: "30"` build the same
object, and so do `cpu: 1` and `cpu: 1000m`; flagging either would be crying wolf, and a gate that
cries wolf gets deleted. So scalars are parsed as Kubernetes quantities (plain number, `m` milli
suffix, Ki/Mi/Gi/Ti/Pi binary and k/M/G/T/P decimal suffixes) and compared numerically. A scalar
this parser does NOT understand is compared as an exact string instead — never silently called equal
to something else, which is the one thing a normalizer must not do.

SCOPE DISCOVERY IS AUTOMATIC ON THE SOURCE SIDE. Every `gitops/workshop-config/templates/per-user-*.yaml`
is rendered and whatever ResourceQuota/LimitRange it produces joins the comparison, so a new
per-user-<module>.yaml is covered the day it lands rather than the day someone remembers this file.
Templates that render no policy objects (per-user-rbac, per-user-sso-realm, …) simply contribute
nothing. The copy side must be asked for its suffixes explicitly (the chart requires them), so a
suffix the source renders and SUFFIXES does not list shows up as an `absent-copy` finding rather
than as silent under-coverage.

USAGE
    tools/lint/ns-policy-parity-guard.py              # check the tree
    tools/lint/ns-policy-parity-guard.py --show       # print the compared policy, both sides
    tools/lint/ns-policy-parity-guard.py --self-test  # scan the canary charts; MUST exit 1

EXIT CODES (the house convention — same as copy-drift-guard.py, so the CI steps read alike):
    0  the two definitions agree
    1  drift found — or, under --self-test, every canary was correctly detected
    2  the guard could not do its job (helm/PyYAML absent, a chart that will not render, an empty
       or shrunken scope, or a canary that went UNDETECTED). Never confuse this with a clean result.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception -> rc 2, INCLUDING one raised at MODULE level.

    Same reasoning as copy-drift-guard.py's copy of this hook, and it is installed for the same
    measured reason: module-level code runs before `__main__` exists, so a bad constant or a failed
    import would crash with Python's default rc 1 — which is exactly what CI's "--self-test must
    exit EXACTLY 1" reads as "the canary fired". `os._exit` is what makes the code stick; an
    excepthook cannot change the exit status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::ns-policy-parity-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad, see copy-drift-guard.py's note
    # NOT `except ImportError`: a _scope.py that fails to PARSE raises SyntaxError, sails past an
    # ImportError-only handler, and exits 1 — CI's "the canary fired".
    print(f"::error::ns-policy-parity-guard: cannot import _scope ({exc}) — the guard could not "
          f"start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a machine without PyYAML
    print("ns-policy-parity-guard: PyYAML is not installed. This guard parses rendered manifests "
          "rather than pattern-matching them, so it cannot run without a parser — refusing to "
          "report clean. Install it (python3 -m pip install PyYAML) and re-run.", file=sys.stderr)
    sys.exit(2)


# The 13 suffixes gitops/workshop-config renders per user today. The COPY side must be told which
# namespaces to render (its assertInputs refuses an empty `suffixes`), so unlike the source side
# this list cannot be discovered. It is not a coverage ceiling: a suffix the source renders and this
# list omits becomes an `absent-copy` FINDING, so under-coverage fails loudly instead of passing.
SUFFIXES = ("dev", "stage", "prod", "cicd", "ai", "batch", "mesh", "modernize", "partner",
            "gitops", "client", "site-a", "site-b")

# The one user both sides are rendered for. Policy is per-suffix, never per-user — on both sides the
# user only ever appears in the namespace NAME — so one user proves the whole matrix and keeps the
# render cheap.
USER = "user1"

SOURCE_CHART = "gitops/workshop-config"
SOURCE_GLOB = "per-user-*.yaml"
SOURCE_SET = {"userCount": "1", "userPrefix": "user"}

COPY_CHART = "gitops/user-namespace"

# Floors, all measured on this tree 2026-08-14 (26 objects / 13 namespaces / 8 policy-bearing
# templates / 130 fields). Each is set below today's value so ordinary growth does not redden main,
# and far above anything a truncation produces. See tools/lint/_scope.py for why a guard that can
# report clean over a shrunken scope is worse than no guard.
MIN_OBJECTS = 20
MIN_NAMESPACES = 10
MIN_TEMPLATES = 6
MIN_FIELDS = 90


class GuardError(Exception):
    """The guard cannot do its job. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


# ---------------------------------------------------------------- Kubernetes quantities


_QUANTITY = re.compile(r"^(-?\d+(?:\.\d+)?)([a-zA-Z]*)$")
_SUFFIXES = {
    "": 1, "m": 1e-3,
    "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15,
    "Ki": 2 ** 10, "Mi": 2 ** 20, "Gi": 2 ** 30, "Ti": 2 ** 40, "Pi": 2 ** 50,
}


def quantity(value):
    """A Kubernetes quantity as a number, or the exact original if it is not one.

    `pods: 30` / `pods: "30"` and `cpu: 1` / `cpu: 1000m` are the SAME object once applied, and a
    gate that reddened main on the spelling would be deleted within a week. So parseable scalars are
    compared numerically.

    What this must never do is call two DIFFERENT things equal, so anything the regex does not
    recognize (an empty string, a unit nobody here uses, a mapping) is returned untouched and then
    compared exactly. Returning a (kind, value) tuple keeps a parsed number from ever comparing
    equal to a raw string that happens to render the same way.
    """
    if isinstance(value, bool):          # bool is an int subclass; never a quantity
        return ("raw", value)
    if isinstance(value, (int, float)):
        return ("num", float(value))
    if not isinstance(value, str):
        return ("raw", value)
    match = _QUANTITY.match(value.strip())
    if not match:
        return ("raw", value)
    number, suffix = match.groups()
    if suffix not in _SUFFIXES:
        return ("raw", value)
    return ("num", float(number) * _SUFFIXES[suffix])


# ---------------------------------------------------------------- rendering a side


def _helm(root: pathlib.Path, chart: str, sets: dict, show_only: str | None) -> str:
    """`helm template`, because a Helm template is not YAML until Helm has rendered it.

    Commas in a --set VALUE are escaped, not left to chance: helm splits an unescaped comma into
    another assignment, and `suffixes` is deliberately a comma-joined scalar string (Argo CD's
    helm.parameters does not expand {a,b,c} list literals the way the CLI does — see the chart's
    own values.yaml). Verified through subprocess with no shell in the loop.
    """
    if shutil.which("helm") is None:
        raise GuardError("helm is not on PATH. Both sides of this comparison are Helm templates, "
                         "which are not valid YAML until rendered — refusing to guess at them.")
    cmd = ["helm", "template", str(root / chart)]
    if show_only:
        cmd += ["--show-only", show_only]
    for key, value in sets.items():
        cmd += ["--set", f"{key}={str(value).replace(',', chr(92) + ',')}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise GuardError(f"`helm template {chart}"
                         f"{' --show-only ' + show_only if show_only else ''}` failed "
                         f"(rc={proc.returncode}):\n{proc.stderr.strip()}")
    return proc.stdout


def policy_objects(rendered: str, origin: str) -> dict:
    """Reduce a rendered manifest stream to {(namespace, kind): policy}.

    Only the two policy fields survive — ResourceQuota's `.spec.hard` and LimitRange's
    `.spec.limits` re-keyed by item `type` so list order cannot matter. Everything else about these
    objects (annotations, owner labels, sync waves, comments) differs between the two charts ON
    PURPOSE and is not what this pair is about.
    """
    try:
        docs = [d for d in yaml.safe_load_all(rendered) if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        raise GuardError(f"{origin} is not parseable as YAML: {exc}") from exc

    out: dict = {}
    for doc in docs:
        kind = doc.get("kind")
        if kind not in ("ResourceQuota", "LimitRange"):
            continue
        namespace = (doc.get("metadata") or {}).get("namespace")
        if not namespace:
            raise GuardError(f"{origin}: a {kind} was rendered with no metadata.namespace. Both "
                             "sides key on the namespace, so an unnamespaced policy object cannot "
                             "be matched to anything — refusing to compare a partial set.")
        spec = doc.get("spec") or {}
        if kind == "ResourceQuota":
            policy = spec.get("hard")
            if not isinstance(policy, dict):
                raise GuardError(f"{origin}: ResourceQuota {namespace}/workshop-quota has no "
                                 "`.spec.hard` mapping. That is the entire policy this guard "
                                 "compares — an empty one is a broken render, not a clean result.")
        else:
            items = spec.get("limits")
            if not isinstance(items, list) or not items:
                raise GuardError(f"{origin}: LimitRange in {namespace} has no `.spec.limits` list. "
                                 "That is the entire policy this guard compares.")
            policy = {}
            for item in items:
                item_type = item.get("type")
                if item_type in policy:
                    raise GuardError(f"{origin}: LimitRange in {namespace} declares type "
                                     f"{item_type!r} twice. Re-keying by type would drop one — "
                                     "refusing to compare a set this guard cannot key.")
                policy[item_type] = {k: v for k, v in item.items() if k != "type"}

        key = (namespace, kind)
        if key in out:
            raise GuardError(f"{origin}: two {kind} objects for namespace {namespace}. The pair is "
                             "keyed by (namespace, kind); a duplicate means one would be silently "
                             "discarded.")
        out[key] = policy
    return out


def render_source(root: pathlib.Path, scope: Scope | None = None) -> dict:
    """The LIVE side: every gitops/workshop-config per-user-*.yaml that renders policy objects.

    Discovered by glob rather than listed, so a new per-user-<module>.yaml is covered the day it
    lands. Templates that render no ResourceQuota/LimitRange (per-user-rbac, per-user-sso-realm, …)
    contribute nothing and are not an error — the scope floors are what prove discovery still works.
    """
    templates_dir = root / SOURCE_CHART / "templates"
    if not templates_dir.is_dir():
        raise GuardError(f"{SOURCE_CHART}/templates does not exist — the chart moved. Update this "
                         "guard rather than leaving it pointing at nothing.")
    paths = sorted(templates_dir.glob(SOURCE_GLOB))
    if not paths:
        raise GuardError(f"no {SOURCE_GLOB} templates found under {SOURCE_CHART}/templates — "
                         "refusing to report clean over an empty source side.")

    merged: dict = {}
    for path in paths:
        rendered = _helm(root, SOURCE_CHART, SOURCE_SET, f"templates/{path.name}")
        found = policy_objects(rendered, f"source {SOURCE_CHART}/templates/{path.name}")
        overlap = set(found) & set(merged)
        if overlap:
            raise GuardError(f"source templates disagree about who owns {sorted(overlap)}: "
                             f"{path.name} renders a policy object another per-user-*.yaml already "
                             "rendered. Two templates writing one object is a defect in its own "
                             "right — this guard will not pick a winner.")
        merged.update(found)
        # Counted HERE, inside the loop that does the work, so a discovery that stops finding
        # templates lands under the floor instead of being re-derived in main() and passing.
        if scope is not None and found:
            scope.add("policy-bearing source templates rendered")
    return merged


def render_copy(root: pathlib.Path) -> dict:
    """The CANONICAL-SOURCE side: gitops/user-namespace, asked for all 13 suffixes at once."""
    rendered = _helm(root, COPY_CHART, {"user": USER, "suffixes": ",".join(SUFFIXES)}, None)
    return policy_objects(rendered, f"copy {COPY_CHART}")


# ---------------------------------------------------------------- comparing


class Result:
    """What one comparison produced: the human findings, the DETECTOR KINDS behind them, and how
    much was actually inspected.

    The kinds are carried out of the comparator for the reason copy-drift-guard.py's PairResult
    records: a self-test that reaches past the production comparator can be green while the
    comparator itself is blind. self_test() below drives THIS function, the one main() drives.
    """

    def __init__(self):
        self.findings: list[str] = []
        self.kinds: set[str] = set()
        self.objects = 0
        self.fields = 0

    def record(self, kind: str, message: str) -> None:
        self.kinds.add(kind)
        self.findings.append(f"  {kind}: {message}")

    def __bool__(self) -> bool:
        return bool(self.findings)


def _flatten(policy, prefix=()) -> dict:
    """{path tuple: scalar} for a policy mapping, so a nested LimitRange section compares field by
    field and the finding names the exact key a human has to go change."""
    out = {}
    if isinstance(policy, dict):
        for key, value in policy.items():
            out.update(_flatten(value, prefix + (str(key),)))
    else:
        out[prefix] = policy
    return out


def compare_policies(source: dict, copy: dict) -> Result:
    """THE production comparator. main() and self_test() both go through here — see Result."""
    result = Result()
    for key in sorted(set(source) | set(copy), key=lambda k: (k[0], k[1])):
        namespace, kind = key
        left, right = source.get(key), copy.get(key)
        if left is None:
            result.record("absent-source",
                          f"{namespace} {kind} is rendered by {COPY_CHART} but NOT by "
                          f"{SOURCE_CHART}. Either the live chart stopped creating it, or the copy "
                          "grew a namespace the workshop does not actually provision.")
            continue
        if right is None:
            result.record("absent-copy",
                          f"{namespace} {kind} is rendered by {SOURCE_CHART} but NOT by "
                          f"{COPY_CHART}. If this is a new suffix, add it to SUFFIXES in this guard "
                          "AND to user-namespace.quotaSpec — an unlisted suffix is uncovered, not "
                          "absent.")
            continue

        result.objects += 1
        left_fields, right_fields = _flatten(left), _flatten(right)
        for path in sorted(set(left_fields) | set(right_fields)):
            where = f"{namespace} {kind} {'.'.join(path)}"
            in_left, in_right = path in left_fields, path in right_fields
            if in_left and not in_right:
                result.record("field-absent-copy",
                              f"{where} is set by {SOURCE_CHART} (= {left_fields[path]!r}) and not "
                              f"set at all by {COPY_CHART}.")
                continue
            if in_right and not in_left:
                result.record("field-absent-source",
                              f"{where} is set by {COPY_CHART} (= {right_fields[path]!r}) and not "
                              f"set at all by {SOURCE_CHART}.")
                continue
            result.fields += 1
            if quantity(left_fields[path]) != quantity(right_fields[path]):
                result.record("value",
                              f"{where}: {SOURCE_CHART} = {left_fields[path]!r} / "
                              f"{COPY_CHART} = {right_fields[path]!r}")
    return result


# ---------------------------------------------------------------- self-test


CANARY = "tools/lint/ns-policy-parity-guard.canary"

# One canary per detector, plus the one that must stay SILENT. Static fixture charts rather than a
# mutation of the real tree: what has to be proven here is the DETECTOR, and a canary derived from
# live files quietly turns into an exit 2 the day those files change shape.
CANARIES = (
    # The clean control. Its two charts differ in exactly the ways the real pair differs — sync-wave
    # and sync-options annotations, owner labels, comments, key order, AND `pods: 30` against
    # `pods: "30"` plus `cpu: 1` against `cpu: 1000m`. If the guard ever starts flagging any of
    # that, this canary fails and the self-test exits 2 rather than 1.
    ("clean", "source", "copy-clean", set()),
    # The 13ed4ef defect shape, reproduced exactly: the copy kept 500m/6 after the source moved to
    # 1500m/8. This is the case that was live in the tree on 2026-08-14.
    ("value-drift", "source", "copy-drifted", {"value"}),
    # A whole namespace's policy missing from one side, both directions in one fixture.
    ("absent", "source", "copy-absent", {"absent-copy", "absent-source"}),
    # A single field added on one side and dropped on the other — invisible to the value detector,
    # which only ever looks at fields BOTH sides set.
    ("field", "source", "copy-field", {"field-absent-copy", "field-absent-source"}),
)


def _render_canary(root: pathlib.Path, chart: str) -> dict:
    return policy_objects(_helm(root, f"{CANARY}/{chart}", {}, None), f"canary {chart}")


def self_test(root: pathlib.Path) -> int:
    """Drive the REAL comparator over the canary charts. MUST return 1.

    Goes through compare_policies() — the function main() uses — rather than re-implementing the
    comparison, because a self-test that re-implements the pipeline proves nothing about the
    pipeline (measured across this repo's guards, 2026-08-01: hook-env-guard's self_test never
    called check_chart at all).
    """
    problems = []
    for name, source_chart, copy_chart, expected in CANARIES:
        try:
            source = _render_canary(root, source_chart)
            copy = _render_canary(root, copy_chart)
        except GuardError as exc:
            print(f"::error::ns-policy-parity-guard SELF-TEST: canary {name!r} could not be "
                  f"rendered: {exc}", file=sys.stderr)
            return 2
        result = compare_policies(source, copy)

        # BOTH of Result.record's emissions are asserted, deliberately. It writes the machine-
        # readable KIND and the human-readable FINDING TEXT as two separate statements, and a
        # self-test that checked only the kinds would let the text emission be deleted in silence:
        # `kinds` would stay right (self-test green at 1) while the real run — whose verdict is
        # `bool(result.findings)` — went quietly blind and reported every tree clean at 0. That is
        # not hypothetical. It is the shape `_canary-coverage.py` found in copy-drift-guard.py
        # (headline and diff body masking each other), it is what this guard's own coverage sweep
        # reported on its first run, and asserting the two halves separately is what closes it.
        emitted = {line.strip().split(":", 1)[0] for line in result.findings}
        trouble = []
        if result.kinds != expected:
            trouble.append(f"expected finding KINDS {sorted(expected) or 'NONE'}, got "
                           f"{sorted(result.kinds) or 'NONE'}")
        if emitted != expected:
            trouble.append(f"expected finding TEXT for {sorted(expected) or 'NONE'}, got text for "
                           f"{sorted(emitted) or 'NONE'} — the kind and the message are emitted by "
                           "two different statements and each must be proven on its own")
        if trouble:
            problems.append(f"  canary {name!r}:\n" +
                            "\n".join(f"    {t}" for t in trouble) +
                            ("\n" + "\n".join(f"    {f}" for f in result.findings)
                             if result.findings else ""))
        else:
            verdict = "correctly stayed clean" if not expected else \
                f"correctly detected {sorted(result.kinds)}"
            print(f"  canary {name!r}: {verdict}")

    # The quantity normalizer is the one piece that can make two DIFFERENT things look equal, so it
    # is asserted directly rather than only through a fixture.
    for a, b, same, why in (
        (30, "30", True, "int and quoted int are the same object once applied"),
        ("1", "1000m", True, "1 core and 1000 milli-cores are the same quantity"),
        ("12Gi", "12Gi", True, "identical spellings"),
        ("500m", "1500m", False, "THE defect: a changed CPU default must never normalize away"),
        ("6", "8", False, "THE defect: a changed quota ceiling must never normalize away"),
        ("12Gi", "12G", False, "binary and decimal Gi differ by 7% and must not be conflated"),
        ("", "0", False, "an empty value is not a zero"),
        ("abc", "abd", False, "unparseable scalars fall back to exact comparison"),
    ):
        if (quantity(a) == quantity(b)) != same:
            problems.append(f"  quantity({a!r}) == quantity({b!r}) should be {same} — {why}")

    if problems:
        print("::error::ns-policy-parity-guard SELF-TEST FAILED — a detector is blind or a canary "
              "no longer reproduces its defect. This is exit 2: the guard is unproven, which is "
              "NOT the same as the tree being clean.", file=sys.stderr)
        for problem in problems:
            print(problem, file=sys.stderr)
        return 2

    print("self-test ok — every canary behaved as declared (the clean pair stayed clean despite "
          "differing annotations/labels/quantity spellings; the 500m/6 drift, the absent objects "
          "and the absent fields were each caught by their own detector).")
    return 1


# ---------------------------------------------------------------- driver


def scope_for_tree() -> Scope:
    scope = Scope("ns-policy-parity-guard")
    scope.require("policy-bearing source templates rendered", MIN_TEMPLATES,
                  f"{SOURCE_CHART} ships 8 per-user-*.yaml that render a ResourceQuota or "
                  "LimitRange; a smaller number means the glob stopped matching, not that the "
                  "workshop shrank.")
    scope.require("namespaces compared", MIN_NAMESPACES,
                  f"{len(SUFFIXES)} suffixes are rendered per user; a smaller number means one "
                  "side stopped rendering, not that namespaces were retired.")
    scope.require("policy objects compared", MIN_OBJECTS,
                  "26 (one ResourceQuota + one LimitRange per suffix) today. A collapse here is a "
                  "render that silently produced fewer objects.")
    scope.require("policy fields compared", MIN_FIELDS,
                  "130 today. This is the dimension that proves the comparison actually descended "
                  "into each object rather than matching two empty mappings.")
    return scope


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="drive the comparator over the canary charts instead of the tree; a "
                             "result other than 1 means detection is unproven, not that the tree "
                             "is fine")
    parser.add_argument("--show", action="store_true",
                        help="print the compared policy for both sides and exit (debugging)")
    args = parser.parse_args(argv)

    root = repo_root()

    if args.self_test:
        return self_test(root)

    scope = scope_for_tree()
    try:
        source = render_source(root, scope)
        copy = render_copy(root)
    except GuardError as exc:
        print(f"::error::ns-policy-parity-guard cannot run: {exc}", file=sys.stderr)
        return 2

    if args.show:
        for label, side in (("SOURCE " + SOURCE_CHART, source), ("COPY " + COPY_CHART, copy)):
            print(f"\n===== {label} =====")
            for (namespace, kind) in sorted(side):
                print(f"{namespace:18s} {kind:14s} {side[(namespace, kind)]}")
        return 0

    result = compare_policies(source, copy)
    # Counted off the two RENDER outputs and off the comparator's own tallies, never re-derived
    # from SUFFIXES — a floor a constant can satisfy proves nothing about whether the work happened
    # (tools/lint/_scope.py, "THE ONE RULE THAT MAKES THIS WORK").
    scope.add("namespaces compared", len({ns for ns, _ in set(source) | set(copy)}))
    scope.add("policy objects compared", result.objects)
    scope.add("policy fields compared", result.fields)

    # Before reporting anything: did the run actually inspect what it claims to?
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if result:
        print(f"\nDRIFT — the per-user namespace policy is defined twice and the two no longer "
              f"agree ({len(result.findings)} finding(s)):\n")
        for finding in result.findings:
            print(finding)
        print(f"\n::error::ns-policy-parity-guard: {SOURCE_CHART}/templates/per-user-*.yaml and "
              f"{COPY_CHART}/templates/_helpers.tpl (user-namespace.quotaSpec) disagree. Decide "
              "which number is right and change BOTH — then run tools/gen-entry-namespaces.sh so "
              "all 26 entry-state charts pick the fix up, and bump each touched chart's version so "
              "Argo's manifest cache does too. This gate exists because 13ed4ef raised the "
              "dev/stage/prod/cicd CPU ceiling in one file and not the other, and nothing else in "
              "the repo could see it.", file=sys.stderr)
        return 1

    print(f"ns-policy-parity-guard: clean ({scope.summary()}).")
    return 0


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "canary detected" / "tree has a
    # finding" code. A crash must never be readable as either.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::ns-policy-parity-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
              f"'canary detected'.", file=sys.stderr)
        sys.exit(2)
