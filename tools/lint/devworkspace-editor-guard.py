#!/usr/bin/env python3
"""A DevWorkspace must contribute its editor by DevWorkspaceTemplate name, never by `uri`.

WHY THIS EXISTS. On 2026-08-17 both charts that ship a DevWorkspace contributed their editor as
`contributions: [{name: editor, uri: <dashboard editors API>}]`. That form produces a workspace
that passes every check anyone thought to run: it reaches phase=Running with Ready=True, its
`.status.mainUrl` populates, the dashboard opens the IDE, files load, extensions activate, and the
Argo Application reads Synced + Healthy. Its built-in "New Terminal" then does nothing at all —
no shell, and NO error is logged in the browser, the extension host, the remote agent, or the
workspace pod. `ai-assisted-development` shipped that way from 2026-07-18 to 2026-08-17 with 13
terminal steps in its lab, and `devspaces-inner-loop` inherited it by being "fixed" to match.

The mechanism the Dev Spaces dashboard itself uses is a DevWorkspaceTemplate referenced by name.
The `uri` form silently drops the CHE_* env, the `controller.devfile.io/container-contribution`
merge marker, and the `type: main` endpoint attribute that mints mainUrl.

WHAT THIS GUARD CANNOT DO, stated so its green tick is not read as more than it is: it does not
prove a terminal works. It proves only that no chart has gone back to the shape that is known to
break one. A workspace can still be broken in ways this never sees — that is what a live smoke in
the real IDE is for.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHART_GLOB = "gitops/entry-states/*/templates/*.yaml"

# Rendering is deliberate rather than pattern-matching the template text: `uri:` can arrive through
# a helper (it did — `include "<chart>.cheEditorUri"`), and a grep for the literal would have
# reported both charts clean on the day they were broken.
RENDER_VALUES = {"user": "user1", "clusterDomain": "apps.example.com", "suffixes": "dev"}


def charts() -> list[pathlib.Path]:
    seen = set()
    for p in ROOT.glob(CHART_GLOB):
        chart = p.parent.parent
        if (chart / "Chart.yaml").exists():
            seen.add(chart)
    return sorted(seen)


def render(chart: pathlib.Path) -> tuple[list[dict], str]:
    cmd = ["helm", "template", "t", str(chart)]
    for k, v in RENDER_VALUES.items():
        cmd += ["--set", f"{k}={v}"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return [], proc.stderr.strip().splitlines()[0] if proc.stderr else "helm template failed"
    try:
        return [d for d in yaml.safe_load_all(proc.stdout) if isinstance(d, dict)], ""
    except yaml.YAMLError as exc:  # a chart that renders invalid YAML is its own finding
        return [], f"rendered invalid YAML ({exc})"


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    self_test = "--self-test" in argv

    if self_test:
        # The canary: a synthetic uri-contributed workspace must be caught, and a template-
        # contributed one must not. Asserted on the checker itself rather than on a fixture chart,
        # because the finding is about the SHAPE, not about any file on disk.
        def check(contrib, templates):
            found = []
            if "uri" in contrib:
                found.append("uri")
            elif not (contrib.get("kubernetes") or {}).get("name"):
                found.append("neither")
            elif contrib["kubernetes"]["name"] not in templates:
                found.append("dangling")
            return found
        cases = [
            ({"name": "editor", "uri": "http://x/api/editors/devfile"}, set(), ["uri"]),
            ({"name": "editor", "kubernetes": {"name": "che-code-x"}}, {"che-code-x"}, []),
            ({"name": "editor", "kubernetes": {"name": "che-code-x"}}, set(), ["dangling"]),
            ({"name": "editor"}, {"che-code-x"}, ["neither"]),
        ]
        bad = [f"case {i}: got {check(c, t)}, want {w}"
               for i, (c, t, w) in enumerate(cases) if check(c, t) != w]
        if bad:
            print("❌ SELF-TEST FAILED:", "; ".join(bad), file=sys.stderr)
            return 2
        print(f"✅ self-test: 4 contribution shapes classified correctly (uri caught, "
              f"template accepted, dangling reference caught, missing editor caught). "
              f"Exiting 1 — the guard's detection is proven.")
        return 1


    problems: list[str] = []
    workspaces = 0
    for chart in charts():
        docs, err = render(chart)
        if err:
            problems.append(f"{chart.relative_to(ROOT)}: could not render — {err}")
            continue
        templates = {d["metadata"]["name"] for d in docs
                     if d.get("kind") == "DevWorkspaceTemplate" and d.get("metadata", {}).get("name")}
        for d in docs:
            if d.get("kind") != "DevWorkspace":
                continue
            workspaces += 1
            name = d.get("metadata", {}).get("name", "?")
            where = f"{chart.relative_to(ROOT)} DevWorkspace/{name}"
            contribs = (d.get("spec") or {}).get("contributions") or []
            contribs = [c for c in contribs if isinstance(c, dict)]
            editors = [c for c in contribs if c.get("name") == "editor"]
            if not editors:
                problems.append(
                    f"{where}: no `editor` contribution. A DevWorkspace authored through the "
                    f"Kubernetes API carries NO editor unless one is contributed — it will reach "
                    f"Running with an empty mainUrl and the dashboard will time out with 'has not "
                    f"received an IDE URL'.")
                continue
            for e in editors:
                if "uri" in e:
                    problems.append(
                        f"{where}: contributes its editor by `uri`. That form yields an IDE that "
                        f"opens and a built-in terminal that silently does nothing. Ship a "
                        f"DevWorkspaceTemplate and reference it by name instead.")
                elif not (e.get("kubernetes") or {}).get("name"):
                    problems.append(
                        f"{where}: editor contribution has neither `kubernetes.name` nor `uri`.")
                else:
                    ref = e["kubernetes"]["name"]
                    if ref not in templates:
                        problems.append(
                            f"{where}: references DevWorkspaceTemplate {ref!r}, which this chart "
                            f"does not render. The workspace would start with no editor at all.")

    if problems:
        print(f"::error::devworkspace-editor-guard: {len(problems)} problem(s).", file=sys.stderr)
        for p in problems:
            print(f"  ❌ {p}", file=sys.stderr)
        return 1

    print(f"✅ devworkspace-editor-guard: {workspaces} DevWorkspace(s) contribute an editor by "
          f"DevWorkspaceTemplate name, and every referenced template is rendered by its own chart. "
          f"This does NOT prove a terminal works — only that no chart is back in the shape known "
          f"to break one.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
