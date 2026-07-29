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
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

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


def check_chart(chart: pathlib.Path, label: str) -> tuple[list[str], int]:
    findings, seen = [], 0
    for solve in ("false", "true"):
        try:
            rendered = render(chart, solve)
        except RuntimeError as exc:
            findings.append(f"{label} (solve={solve}) FAILED TO RENDER: {exc}")
            continue
        for document in yaml.safe_load_all(rendered):
            if not isinstance(document, dict):
                continue
            for obj_label, script, container in scripts_in(document):
                seen += 1
                if container.get("envFrom"):
                    print(f"  note: {label} {obj_label} uses envFrom — its env names are not "
                          f"knowable from the manifest, so its references are not checked.")
                    continue
                defined = env_names(container) | assigned_names(script) | SHELL_BUILTINS
                missing = sorted({n for n in REF.findall(script)} - defined)
                for name in missing:
                    findings.append(
                        f"{label} (solve={solve}) {obj_label}: ${{{name}}} is referenced but is "
                        f"neither a declared env var nor assigned in the script. Under `set -u` "
                        f"this KILLS the script at that line.")
    return findings, seen


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    findings, total = [], 0
    charts = sorted(p for p in ENTRY_STATES.iterdir() if (p / "Chart.yaml").is_file())
    if not charts:
        print("::error::hook-env-guard: no entry-state charts found — scanning nothing is not a pass.",
              file=sys.stderr)
        return 2
    for chart in charts:
        chart_findings, seen = check_chart(chart, chart.name)
        findings += chart_findings
        total += seen
    if findings:
        print("::error::an embedded hook script references a variable nothing defines. Under "
              "`set -euo pipefail` that is fatal at the referencing line — typically on the error "
              "path, which is why it ships looking fine.", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print(f"hook-env-guard: clean — {len(charts)} charts rendered at solve={{false,true}}, "
          f"{total} embedded script(s) checked.")
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

    for document, expect, why in ((good, 0, "inline/loop/read/local assignments and shell builtins"),
                                  (bad, 1, "the DST_USER shape that shipped"),
                                  (nested, 1, "a script nested in Template.objects[]")):
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

    if failures:
        for failure in failures:
            print(f"::error::hook-env-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2
    print("self-test ok — the DST_USER shape and a Template-nested script are both detected, and "
          "inline/loop/read assignments plus shell builtins are correctly NOT reported.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
