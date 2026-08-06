#!/usr/bin/env python3
# Raw docstring: the prose below quotes bash and regex fragments (`\s`, `${VAR}`), and a plain
# docstring makes Python emit `SyntaxWarning: invalid escape sequence` on EVERY run — noise in every
# CI log, and noise is how a real warning gets skimmed past.
r"""Every ${VAR} an embedded hook script references must be defined, or the hook dies at runtime.

WHY THIS EXISTS. Entry-state Jobs embed bash scripts that run under `set -euo pipefail`. Under `-u`,
referencing a variable that is neither a declared container env var nor assigned in-script is FATAL —
and it is fatal at the exact moment the line executes, not at parse time. So the failure hides on
whichever branch is least exercised, which is almost always the error branch.

That is not hypothetical. Measured on a live cluster, 2026-07-29:

    ❌ the MaaS credential in adopted-lightspeed(Bearer) CANNOT work against …
       why: it is a 3-segment JSON Web Token …
       fix: put a working OpenAI-compatible key in bootstrap/vars.yaml …
    /bin/bash: line 90: DST_USER: unbound variable

jobs-batch-kueue's hook referenced ${DST_USER} in its rejected-credential guidance and never declared
it (the other three AI charts did). The hook died PART-WAY THROUGH PRINTING ITS OWN ERROR — after the
❌, before the fix instructions — which took the deliberate exit-0 degrade path with it. The Job
failed all 5 attempts, maas-config was never patched, and the entry state's sync failed on precisely
the clusters that were meant to degrade quietly (no workshop MaaS key). Fixed in d53dccb; this guard
is why it cannot come back.

The defect class is broader than that one variable: an error path that throws before it can deliver
its error. The same shape shipped in Java the same day (Set.of(...).contains(null) throwing NPE
inside a validation guard, 22db7ef). Both were introduced by code written to IMPROVE error reporting.

WHAT COUNTS AS DEFINED. Three things, and the third is where a naive implementation goes wrong:
  1. a declared container env name (`env: - name: FOO`)
  2. a shell assignment `FOO=...` at the start of a line
  3. an assignment that is NOT at the start of a line — `if …; then FROM_NS="$WS_NS"; else …`, a
     `local x=` inside a function, a `for x in …` loop variable, a `read -r a b c`. A `^\s*VAR=`
     regex misses every one of these. The first cut of this check reported CAND_SRC, FROM_NS and
     FROM_SECRET as undefined on all four AI charts; all three are assigned inline after `then`.
     False positives here are expensive: they train people to add junk env vars to silence a guard.

SCOPE IS THE RENDERED MANIFEST, not the template. A ${VAR} can be produced by Helm interpolation, and
what runs in the pod is the render. Rendering is also what reaches PodSpecs nested inside OpenShift
Template.objects[], which a template-text scan cannot see.

WHAT THIS DOES NOT CHECK. Whether the value is CORRECT — only that referencing it cannot kill the
script. A variable defined as the empty string passes here and should; `set -u` does not object to an
empty value, only to an unset name.

SCOPE IS ASSERTED, NOT ASSUMED (2026-08-01). An audit blinded check_chart() to return no findings and
this guard printed "clean" and exited 0 — as it also did with the envFrom skip widened to every
container, with initContainers dropped from the walk, and with the solve=true render dropped. Each of
those is a guard reporting success over work it did not do, which is worse than a broken detector.
Every count below is now produced INSIDE check_chart and measured against a floor (see
tools/lint/_scope.py); the initContainers walk, which has no instance in the tree today and so cannot
be floored, is pinned by a fixture in self_test() instead.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    WHY THE `__main__` TRY/EXCEPT IS NOT ENOUGH (measured 2026-08-01). Module-level code runs before
    `__main__` exists, so a bad constant, a failed import, or a _scope.py that does not PARSE crashed
    with Python's default rc 1 — which is exactly what CI's `--self-test must exit EXACTLY 1` reads as
    "the canary fired". Measured on a scratch copy of this file: replacing _scope.py with a syntax
    error gave rc 1 in BOTH modes, and the CI step would have printed "self-test ok".

    Installed as the FIRST statement after the imports, so it is already in place before anything
    below it can fail. `os._exit` is what makes the code stick: an excepthook cannot change the exit
    status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::hook-env-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). "
          f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
          f"'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad; see the note below
    # NOT `except ImportError`. Measured 2026-08-01: a _scope.py that fails to PARSE raises
    # SyntaxError, sails past an ImportError-only handler, and exits 1 — CI's 'the canary
    # fired'. Anything at all going wrong while loading the scope ledger means this guard
    # cannot start, and that is rc 2 regardless of which exception said so.
    # An uncaught ImportError exits 1, and CI's contract for this guard is "--self-test must exit
    # EXACTLY 1 = the canary was detected". A crash would therefore be READ AS PROOF OF DETECTION and
    # the real run would never even happen. Measured 2026-08-01 by running a copy of this file with
    # _scope.py absent: traceback, rc=1, and the CI step would have printed "self-test ok".
    print(f"::error::hook-env-guard: cannot import _scope ({exc}) — "
          f"the guard could not start, which is NOT the same as a clean tree.",
          file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    WHY (measured 2026-08-01). Every pattern compiled at MODULE level raises re.error before main()
    — and before any try/except inside it — can run. Python exits 1 on an uncaught exception, and 1
    is exactly what CI's `--self-test must exit EXACTLY 1` assertion accepts as "the canary was
    detected". A one-character regex typo therefore reported the guard's detection as PROVEN while
    the guard could not even load. A regex is the likeliest thing to break in a guard, so the
    compile step is where the exit code has to be fixed.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::hook-env-guard: {name} is not a valid regex ({exc}) — "
              f"the guard could not load. Exiting 2: that is 'the guard is broken', not "
              f"'the canary fired'.", file=sys.stderr)
        sys.exit(2)


try:
    import yaml
except ModuleNotFoundError:
    print("::error::hook-env-guard: PyYAML is not installed. This guard PARSES rendered manifests; "
          "without a parser it cannot run, and a guard that cannot run must not report success.",
          file=sys.stderr)
    raise SystemExit(2)

REPO = pathlib.Path(__file__).resolve().parents[2]
ENTRY_STATES = REPO / "gitops/entry-states"
# The fixture CHART the self-test renders through check_chart(). It is a chart, not a text file,
# because check_chart() is the thing that needed proving and check_chart() renders with helm — and
# until 2026-08-01 this constant was read by one `if … : pass` and nothing else, which is to say it
# was not read at all.
CANARY = REPO / "tools/lint/hook-env-guard.canary"

# Names the shell itself provides. Referencing these under `set -u` is safe.
SHELL_BUILTINS = {
    "PATH", "HOME", "PWD", "OLDPWD", "SHELL", "USER", "HOSTNAME", "IFS", "PS1", "PS2",
    "BASH", "BASH_VERSION", "BASH_SOURCE", "FUNCNAME", "LINENO", "RANDOM", "SECONDS",
    "OPTIND", "OPTARG", "REPLY", "PPID", "UID", "EUID", "TMPDIR", "LANG", "LC_ALL", "TERM",
}

REF = _compile("REF", r"\$\{([A-Za-z_][A-Za-z0-9_]*)[}:#%/\[]")

# The scope dimensions check_chart() raises, named once so the counters and their floors cannot
# drift apart. self_test asserts every one of these has a floor: an unfloored dimension is a
# measurement nobody is judging.
CHART_DIMENSIONS = ("renders", "solve=false scripts", "solve=true scripts",
                    "scripts actually evaluated")


def assigned_names(script: str) -> set[str]:
    """Every name the script itself binds, wherever the binding sits on the line.

    Deliberately generous. A false NEGATIVE here costs nothing — the variable is defined either way
    and the guard simply does not flag it. A false POSITIVE reports a working script as broken, which
    is the failure mode that gets guards disabled.
    """
    names: set[str] = set()
    # plain assignment anywhere a command could start: line start, after ; & | ( { && || then do else
    names |= set(re.findall(r"(?:^|[;&|(){}]|\bthen\b|\bdo\b|\belse\b|\bfi\b)\s*"
                            r"([A-Za-z_][A-Za-z0-9_]*)=", script, re.M))
    # `local a b=1 c="$2" d` binds FOUR names. Matching only the first is how the initial cut of this
    # guard reported ${ep} and ${model} as undefined across three charts: both are the 2nd and 3rd
    # names on `local tok="$1" ep="${2%/}" model="$3" code cfg=…` inside probe_endpoint(). Take the
    # whole statement and pull every bare name out of it.
    for statement in re.findall(r"\b(?:local|declare|typeset|readonly|export)\s+([^\n;&|]*)", script):
        names |= set(re.findall(r"(?:^|\s)(?!-)([A-Za-z_][A-Za-z0-9_]*)(?==|\s|$)", statement))
    names |= set(re.findall(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b", script))
    names |= set(re.findall(r"\bread\b([^\n;|&]*)", script) and
                 [n for chunk in re.findall(r"\bread\b([^\n;|&]*)", script)
                  for n in re.findall(r"(?<![-\w])([A-Za-z_][A-Za-z0-9_]*)", chunk)
                  if n not in {"r", "n", "d", "a", "p", "s", "t", "u", "N", "read"}])
    # positional params ($1, ${2}) inside functions, and $@/$* — not names we can or should track
    return names


def env_names(container: dict) -> set[str]:
    names = set()
    for entry in container.get("env") or []:
        if isinstance(entry, dict) and entry.get("name"):
            names.add(entry["name"])
    # envFrom pulls in an unknown key set; treat it as "we cannot know" and say so rather than
    # pretend. Handled by the caller, which skips such containers with a printed note.
    return names


def scripts_in(document: dict) -> list[tuple[str, str, dict]]:
    """(object-label, script-text, container) for every container whose command/args carry a script."""
    out = []
    docs = [document]
    if document.get("kind") == "Template":
        docs += [o for o in (document.get("objects") or []) if isinstance(o, dict)]
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        spec = ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
        if not isinstance(spec, dict):
            continue
        name = (doc.get("metadata") or {}).get("name", "?")
        for key in ("initContainers", "containers"):
            for container in spec.get(key) or []:
                if not isinstance(container, dict):
                    continue
                text = " ".join(str(a) for a in (container.get("args") or []))
                text += " " + " ".join(str(c) for c in (container.get("command") or []))
                if "$" not in text:
                    continue
                out.append((f"{doc.get('kind')}/{name} [{container.get('name')}]", text, container))
    return out


def render(chart: pathlib.Path, solve: str) -> str:
    proc = subprocess.run(
        ["helm", "template", "t", str(chart), "--set", "user=user1",
         "--set", "clusterDomain=example.com", "--set", f"solve={solve}"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr else "helm failed")
    return proc.stdout


def check_chart(chart: pathlib.Path, label: str) -> tuple[list[str], dict]:
    """(findings, scope counters). The counters are raised HERE, by the loops that do the work, so a
    blinded check_chart cannot satisfy them — see tools/lint/_scope.py for why that matters."""
    findings: list[str] = []
    counts = {dimension: 0 for dimension in CHART_DIMENSIONS}
    for solve in ("false", "true"):
        try:
            rendered = render(chart, solve)
        except RuntimeError as exc:
            findings.append(f"{label} (solve={solve}) FAILED TO RENDER: {exc}")
            continue
        counts["renders"] += 1
        for document in yaml.safe_load_all(rendered):
            if not isinstance(document, dict):
                continue
            for obj_label, script, container in scripts_in(document):
                counts[f"solve={solve} scripts"] += 1
                if container.get("envFrom"):
                    print(f"  note: {label} {obj_label} uses envFrom — its env names are not "
                          f"knowable from the manifest, so its references are not checked.")
                    continue
                # Counted only past the skip: a skip that widens to every container collapses this
                # dimension, which is exactly what the audit's blinding did without being noticed.
                counts["scripts actually evaluated"] += 1
                defined = env_names(container) | assigned_names(script) | SHELL_BUILTINS
                missing = sorted({n for n in REF.findall(script)} - defined)
                for name in missing:
                    findings.append(
                        f"{label} (solve={solve}) {obj_label}: ${{{name}}} is referenced but is "
                        f"neither a declared env var nor assigned in the script. Under `set -u` "
                        f"this KILLS the script at that line.")
    return findings, counts


def scope_for_tree() -> Scope:
    """The floors for a real-tree run. Measured 2026-08-01: 26 charts, 52 renders, 25 solve=false
    and 32 solve=true scripts, all 57 evaluated (nothing uses envFrom today). Each floor sits well
    under the measurement so ordinary churn does not redden main, and far over what any truncation
    produces."""
    scope = Scope("hook-env-guard")
    scope.require("charts", 20,
                  "gitops/entry-states ships 26 charts. A smaller number means discovery stopped "
                  "matching (a renamed Chart.yaml, a truncated glob), not that 6 were deleted.")
    scope.require("renders", 40,
                  "two `helm template` renders per chart. Losing half of these is how the solve=true "
                  "world — where a real Route and a real pull-policy defect once hid — stops being "
                  "checked while the run still says clean.")
    scope.require("solve=false scripts", 15, "the default world's embedded hook scripts.")
    scope.require("solve=true scripts", 20,
                  "solve worlds materialize MORE workloads than the default render, so this must be "
                  "the larger of the two. Zero here means the solve=true render was dropped.")
    scope.require("scripts actually evaluated", 40,
                  "scripts that reached the ${VAR} check. Counted PAST the envFrom skip: if that "
                  "skip ever widens beyond genuine envFrom containers, this collapses and the run "
                  "fails instead of reporting a clean scan of nothing.")
    return scope


def main(argv=None) -> int:
    # argparse, not `"--self-test" in sys.argv`. The membership test IGNORED every other argument:
    # `--selftest`, one hyphen short, ran the plain check and printed a clean result, so a maintainer
    # proving a detector fires proved nothing. argparse names the offending argument and exits 2 —
    # the same behaviour the six argparse-based guards beside this one already had, and the same
    # exit code tools/lint/_parse-guard-args.sh gives the shell guards.
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="run the canaries instead of the real tree; exits 1 when every canary was "
                         "correctly caught, which is the PASS for this mode")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    findings = []
    scope = scope_for_tree()
    charts = sorted(p for p in ENTRY_STATES.iterdir() if (p / "Chart.yaml").is_file())
    if not charts:
        print("::error::hook-env-guard: no entry-state charts found — scanning nothing is not a pass.",
              file=sys.stderr)
        return 2
    scope.add("charts", len(charts))
    for chart in charts:
        chart_findings, counts = check_chart(chart, chart.name)
        findings += chart_findings
        scope.merge(counts)
    # Before reporting anything: did the run actually inspect what it claims to?
    collapsed = scope.enforce()
    if collapsed:
        return collapsed
    if findings:
        print("::error::an embedded hook script references a variable nothing defines. Under "
              "`set -euo pipefail` that is fatal at the referencing line — typically on the error "
              "path, which is why it ships looking fine.", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print(f"hook-env-guard: clean — {scope.summary()}.")
    return 0


def self_test() -> int:
    """Prove both directions on static fixtures. Anything but 1 means detection is unproven."""
    failures = []

    good = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "canary-good"},
            "spec": {"template": {"spec": {"containers": [{
                "name": "c",
                "env": [{"name": "DST_NS", "value": "x"}],
                "args": ['set -euo pipefail\nCAND=none\n'
                         'if [ -n "$CAND" ]; then FROM="a"; else FROM="b"; fi\n'
                         'for u in 1 2; do echo "${u} ${FROM} ${CAND} ${DST_NS} ${HOME}"; done\n'
                         'read -r line rest <<< "x y"\necho "${line}${rest}"']}]}}}}
    bad = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "canary-bad"},
           "spec": {"template": {"spec": {"containers": [{
               "name": "c",
               "env": [{"name": "DST_NS", "value": "x"}],
               "args": ['set -euo pipefail\necho "fix: ws reset --user ${DST_USER}"']}]}}}}
    # the exact shape that shipped: nested inside an OpenShift Template
    nested = {"apiVersion": "template.openshift.io/v1", "kind": "Template",
              "metadata": {"name": "canary-tmpl"},
              "objects": [{"kind": "Job", "metadata": {"name": "canary-nested"},
                           "spec": {"template": {"spec": {"containers": [{
                               "name": "c", "args": ['echo "${NEVER_SET_ANYWHERE}"']}]}}}}]}
    # initContainers, pinned here because the real tree has no init container carrying a script
    # today — so no scope floor can prove the walk still visits them, and dropping "initContainers"
    # from scripts_in()'s key tuple was one of the blindings that left a silent clean. A credential
    # handoff between an init and a main container is a shape this repo uses, so the walk must not
    # quietly stop covering it the day one of those grows a ${VAR}.
    init_only = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "canary-init"},
                 "spec": {"template": {"spec": {
                     "initContainers": [{"name": "prep",
                                         "args": ['echo "${ONLY_IN_INIT_CONTAINER}"']}],
                     "containers": [{"name": "c", "args": ['echo "$HOME"']}]}}}}

    for document, expect, why in ((good, 0, "inline/loop/read/local assignments and shell builtins"),
                                  (bad, 1, "the DST_USER shape that shipped"),
                                  (nested, 1, "a script nested in Template.objects[]"),
                                  (init_only, 1, "a script that exists ONLY in an initContainer")):
        found = []
        for obj_label, script, container in scripts_in(document):
            if container.get("envFrom"):
                continue
            defined = env_names(container) | assigned_names(script) | SHELL_BUILTINS
            found += sorted({n for n in REF.findall(script)} - defined)
        if len(found) != expect:
            failures.append(f"fixture ({why}): expected {expect} undefined reference(s), got "
                            f"{len(found)}: {found}")

    # THE PRODUCTION PATH, driven end to end. Everything above re-implements check_chart()'s body
    # inline — it calls scripts_in/env_names/assigned_names/REF itself — so check_chart(), the only
    # function main() actually runs, was executed by no CI signal at all. Measured 2026-08-01:
    # neutering its `findings.append` while leaving its counters intact left --self-test at 1 AND
    # the real run at 0. That is the api-key-shape defect in a different costume: a docstring's
    # worth of logic that nothing exercises.
    #
    # The two `pass`-branch lines that used to sit here claimed the fixtures were "inline by
    # design" and referenced a CANARY constant that no code read. They are replaced by a real
    # fixture chart, rendered by helm under both solve worlds exactly as the real charts are.
    if not (CANARY / "Chart.yaml").is_file():
        failures.append(f"the canary fixture chart {CANARY.relative_to(REPO)} is missing, so "
                        "check_chart() — the function the real run is made of — is exercised by "
                        "nothing.")
    else:
        canary_findings, canary_counts = check_chart(CANARY, "canary")
        by_world = {(m.group(1), m.group(2))
                    for m in (re.search(r"\(solve=(\w+)\).*?\$\{(\w+)\}", finding)
                              for finding in canary_findings) if m}
        expected_world = {
            ("false", "DST_USER"), ("true", "DST_USER"),
            ("false", "ONLY_IN_INIT_CONTAINER"), ("true", "ONLY_IN_INIT_CONTAINER"),
            ("false", "NEVER_SET_IN_TEMPLATE"), ("true", "NEVER_SET_IN_TEMPLATE"),
            # solve=false only: the Job that carries it is gated on solve=true.
            ("true", "ONLY_IN_THE_SOLVE_WORLD"),
        }
        if by_world != expected_world:
            failures.append(
                f"check_chart() over the canary chart found {sorted(by_world)}; expected "
                f"{sorted(expected_world)}. Missing entries mean a shape stopped being walked or a "
                f"finding stopped being raised; extra ones mean a defined reference is now being "
                f"reported. Raw findings: {canary_findings}")
        if canary_counts["renders"] != 2:
            failures.append(f"check_chart() reported {canary_counts['renders']} render(s) of the "
                            "canary chart; both the solve=false and the solve=true world must be "
                            "rendered, and dropping one is invisible in the finding list of a "
                            "chart whose worlds are identical.")
        if canary_counts["solve=true scripts"] <= canary_counts["solve=false scripts"]:
            failures.append("the canary's solve world did not materialize MORE scripts than its "
                            "default world, so nothing here distinguishes two renders from one.")
        # The envFrom skip, pinned from both sides. Exactly one container per render carries
        # envFrom, so evaluated must be exactly two short of the scripts seen: a skip that widens
        # makes this larger than the gap, and a skip that disappears makes it equal.
        seen = canary_counts["solve=false scripts"] + canary_counts["solve=true scripts"]
        if canary_counts["scripts actually evaluated"] != seen - 2:
            failures.append(
                f"check_chart() evaluated {canary_counts['scripts actually evaluated']} of {seen} "
                f"scripts; the fixture carries exactly one envFrom container per render, so it must "
                f"evaluate {seen - 2}. More means the envFrom skip stopped working (and its "
                f"unknowable reference is now a false finding); fewer means the skip widened past "
                f"envFrom and containers are being ignored.")

    # A chart that will not render must SAY SO by name. The scope floors already fail the run (a
    # skipped render never raises `renders`), but a scope collapse names a number, not the chart —
    # and this finding was the only thing that did. Blinding it changed neither exit code, because
    # nothing here ever handed check_chart() a chart helm refuses. Written to a temp dir rather than
    # committed: a chart that exists only during the run cannot be installed by accident, and a
    # deliberately-broken chart in gitops/ would be a trap for the next reader.
    with tempfile.TemporaryDirectory() as tmp:
        broken = pathlib.Path(tmp) / "broken-chart"
        (broken / "templates").mkdir(parents=True)
        (broken / "Chart.yaml").write_text(
            "apiVersion: v2\nname: broken\nversion: 0.1.0\n", encoding="utf-8")
        # `required` with no value set is how a real chart fails: rendered, not a syntax error.
        (broken / "templates" / "boom.yaml").write_text(
            '{{ required "canary: this chart is meant to fail rendering" .Values.doesNotExist }}\n',
            encoding="utf-8")
        broken_findings, broken_counts = check_chart(broken, "broken-canary")
        if broken_counts["renders"] != 0:
            failures.append(f"a chart helm refuses to render still counted "
                            f"{broken_counts['renders']} render(s) — the counter is raised on a "
                            "render that did not happen, so the scope floor stops meaning anything.")
        if len(broken_findings) != 2 or not all("FAILED TO RENDER" in f for f in broken_findings):
            failures.append(f"a chart helm refuses to render produced {broken_findings!r} instead "
                            "of one FAILED TO RENDER finding per solve world. Without it the run "
                            "fails on a scope shortfall that names a number and not the chart.")

    # The scope ledger is a library no CI step runs on its own; exercising it from here is what
    # stops it from being an unrun gate.
    failures += Scope.self_check()
    # …and the floors this guard declares must be REAL floors. A dimension nothing ever raises is a
    # floor that can only fail, which gets lowered to 1 by the next person and stops asserting.
    unfloored = [d for d in CHART_DIMENSIONS if scope_for_tree().floor_for(d) is None]
    if unfloored or scope_for_tree().floor_for("charts") is None:
        failures.append(f"scope_for_tree() declares no floor for {unfloored or ['charts']} — a "
                        "dimension that is measured but not judged proves nothing.")

    if failures:
        for failure in failures:
            print(f"::error::hook-env-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2
    print("self-test ok — the DST_USER shape, a Template-nested script and an initContainer-only "
          "script are all detected THROUGH check_chart() as main() runs it, in both solve worlds; "
          "inline/loop/read assignments plus shell builtins are correctly NOT reported; the envFrom "
          "skip covers exactly the envFrom containers; and the scope ledger fails an empty or "
          "truncated input set.")
    return 1


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either, so it is remapped to 2 — "the
    # guard could not run". Without this, a typo in a regex or a missing fixture would make
    # --self-test exit 1 and CI would report the guard's detection as PROVEN.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::hook-env-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
