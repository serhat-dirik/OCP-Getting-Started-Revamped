#!/usr/bin/env python3
"""Every ${VAR} an embedded hook script references must be defined, or the hook dies at runtime.

WHY THIS EXISTS. Entry-state Jobs embed bash scripts that run under `set -euo pipefail`. Under `-u`,
referencing a variable that is neither a declared container env var nor assigned in-script is FATAL —
and it is fatal at the exact moment the line executes, not at parse time. So the failure hides on
whichever branch is least exercised, which is almost always the error branch.

That is not hypothetical. Measured on cluster ksls5, 2026-07-29:

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

import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _scope import Scope  # noqa: E402  (path must be set first; this file is run as a script)

try:
    import yaml
except ModuleNotFoundError:
    print("::error::hook-env-guard: PyYAML is not installed. This guard PARSES rendered manifests; "
          "without a parser it cannot run, and a guard that cannot run must not report success.",
          file=sys.stderr)
    raise SystemExit(2)

REPO = pathlib.Path(__file__).resolve().parents[2]
ENTRY_STATES = REPO / "gitops/entry-states"
CANARY = REPO / "tools/lint/hook-env-guard.canary"

# Names the shell itself provides. Referencing these under `set -u` is safe.
SHELL_BUILTINS = {
    "PATH", "HOME", "PWD", "OLDPWD", "SHELL", "USER", "HOSTNAME", "IFS", "PS1", "PS2",
    "BASH", "BASH_VERSION", "BASH_SOURCE", "FUNCNAME", "LINENO", "RANDOM", "SECONDS",
    "OPTIND", "OPTARG", "REPLY", "PPID", "UID", "EUID", "TMPDIR", "LANG", "LC_ALL", "TERM",
}

REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)[}:#%/\[]")

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


def main() -> int:
    if "--self-test" in sys.argv:
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

    if not CANARY.is_dir() and not CANARY.with_suffix(".txt").is_file():
        pass  # fixtures are inline above by design — see the note below

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
          "script are all detected; inline/loop/read assignments plus shell builtins are correctly "
          "NOT reported; and the scope ledger fails an empty or truncated input set.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
