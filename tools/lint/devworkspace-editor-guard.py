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

import contextlib
import io
import os
import pathlib
import shutil
import subprocess
import sys

import yaml


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception -> rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import crashes
    with Python's default rc 1 — which is exactly what this guard's CI step reads as "the canary
    fired". `os._exit` is what makes the code stick: an excepthook cannot change the exit status by
    returning. Copied into each guard rather than imported, so it is in place before an import can
    fail.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::devworkspace-editor-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHART_GLOB = "gitops/entry-states/*/templates/*.yaml"
CANARY_DIR = pathlib.Path(__file__).resolve().parent / "devworkspace-editor-guard.canary"

# The floor a DEFAULT (whole-tree) run may not fall below. If CHART_GLOB ever stops matching, the
# scan loop runs zero times and the guard prints "0 DevWorkspace(s) ... ✅" — a guard that
# inspected nothing is indistinguishable from one that inspected everything. Two charts have
# shipped a DevWorkspace since 2026-07-18, and both must RENDER one, not merely be visited: a
# template gated behind a value we do not set would otherwise pass as "scanned, nothing found".
MIN_WORKSPACES = 2
GITOPS = ROOT / "gitops"

# Rendering is deliberate rather than pattern-matching the template text: `uri:` can arrive through
# a helper (it did — `include "<chart>.cheEditorUri"`), and a grep for the literal would have
# reported both charts clean on the day they were broken.
RENDER_VALUES = {"user": "user1", "clusterDomain": "apps.example.com", "suffixes": "dev"}


def charts(roots: list[pathlib.Path] | None = None) -> list[pathlib.Path]:
    """Chart directories to inspect.

    `roots` names them explicitly, which is how `--self-test` drives this same scan over the
    fixtures in `devworkspace-editor-guard.canary/`. Default: every entry-state chart that ships a
    template.
    """
    if roots is not None:
        return [r for r in roots if (r / "Chart.yaml").is_file()]
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


def charts_declaring_a_devworkspace() -> list[pathlib.Path]:
    """Charts under gitops/ that MENTION a DevWorkspace, found by walking and reading text.

    Deliberately not CHART_GLOB. A glob compared against itself proves nothing; this answers the
    same question by a different route — os.walk plus a substring — so the two answers can be
    compared. It is the only thing here that can notice the glob silently matching less than the
    tree holds, which is the failure that turns this guard's green tick into a lie. `kind:
    DevWorkspaceTemplate` contains the substring too, and that is correct: a chart shipping only
    the editor template is still a chart this guard must see.
    """
    found = set()
    for dirpath, _dirnames, filenames in os.walk(GITOPS):
        for fn in filenames:
            if not fn.endswith((".yaml", ".yml")):
                continue
            f = pathlib.Path(dirpath) / fn
            try:
                if "kind: DevWorkspace" not in f.read_text(encoding="utf-8", errors="replace"):
                    continue
            except OSError:
                continue
            for d in f.parents:
                if (d / "Chart.yaml").is_file():
                    found.add(d)
                    break
    return sorted(found)


def rel(p: pathlib.Path) -> str:
    """Repo-relative where possible; a fixture driven by absolute path is not an error."""
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()

    if shutil.which("helm") is None:
        print("::error::devworkspace-editor-guard: `helm` is not on PATH. Exiting 2 — this guard "
              "renders every chart, so without helm it cannot inspect anything, and a linter that "
              "cannot run is a FAILED gate, never a passed one.", file=sys.stderr)
        return 2

    roots = [pathlib.Path(a) for a in argv if not a.startswith("-")]
    explicit = bool(roots)
    scanned = charts(roots if explicit else None)

    problems: list[str] = []
    workspaces = 0
    for chart in scanned:
        docs, err = render(chart)
        if err:
            problems.append(f"{rel(chart)}: could not render — {err}")
            continue
        templates = {d["metadata"]["name"] for d in docs
                     if d.get("kind") == "DevWorkspaceTemplate" and d.get("metadata", {}).get("name")}
        for d in docs:
            if d.get("kind") != "DevWorkspace":
                continue
            workspaces += 1
            name = d.get("metadata", {}).get("name", "?")
            where = f"{rel(chart)} DevWorkspace/{name}"
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

    # SCOPE. Everything above can be perfect and still inspect an empty set — a broken glob, a
    # renamed directory, a mistyped path. Both halves land on ONE emission site on purpose: they
    # are the same defect ("this run checked less than it claims to") reached two ways.
    if explicit:
        missing = [rel(r) for r in roots if r not in scanned]
        shortfall = (f"{len(missing)} named root(s) resolved to no chart: {', '.join(missing)}"
                     if missing else "")
    else:
        unseen = [rel(c) for c in charts_declaring_a_devworkspace() if c not in scanned]
        if unseen:
            shortfall = (f"{len(unseen)} chart(s) under gitops/ declare a DevWorkspace but were "
                         f"never scanned: {', '.join(unseen)} — `{CHART_GLOB}` is matching less "
                         f"than the tree holds")
        elif workspaces < MIN_WORKSPACES:
            shortfall = (f"rendered {workspaces} DevWorkspace(s) from {len(scanned)} chart(s), "
                         f"below the floor of {MIN_WORKSPACES} — a DevWorkspace gated behind a "
                         f"value this guard does not set is a DevWorkspace nobody checks")
        else:
            shortfall = ""
    if shortfall:
        problems.append(f"[scope] {shortfall}. A guard that inspects nothing reports clean, which "
                        f"is indistinguishable from a guard that inspected everything.")

    if problems:
        print(f"::error::devworkspace-editor-guard: {len(problems)} problem(s).", file=sys.stderr)
        for p in problems:
            print(f"  ❌ {p}", file=sys.stderr)
        return 1

    print(f"✅ devworkspace-editor-guard: {workspaces} DevWorkspace(s) across {len(scanned)} chart(s) "
          f"contribute an editor by DevWorkspaceTemplate name, and every referenced template is "
          f"rendered by its own chart. This does NOT prove a terminal works — only that no chart is "
          f"back in the shape known to break one.")
    return 0


def _drive(argv: list[str]) -> tuple[int, str]:
    """Run the REAL main() and capture everything it printed."""
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        rc = main(argv)
    return rc, sink.getvalue()


# (fixture directory, expected rc, a phrase only THIS detector can print).
# One fixture per detector, and each fixture trips exactly ONE of them — that is what makes the
# detectors individually provable. A fixture that tripped two would leave both readable as
# "proven" while either could silently stop working.
CASES = [
    ("control-good", 0, None),
    ("canary-uri", 1, "contributes its editor by `uri`"),
    ("canary-no-editor", 1, "no `editor` contribution"),
    ("canary-neither", 1, "neither `kubernetes.name` nor `uri`"),
    ("canary-dangling", 1, "does not render"),
    ("canary-unrenderable", 1, "could not render"),
]


def self_test() -> int:
    """Drive the real entry point over the fixtures. Exit 1 = every detector fired on exactly its
    own fixture and the control stayed silent. Exit 2 = any of that is false. Never 0.

    WHY THIS EXISTS. Until 2026-08-23 this function asserted a LOCAL REIMPLEMENTATION of the
    detection logic — a nested `check()` that duplicated the classification and returned before
    main()'s real `problems.append(...)` sites were ever reached. It therefore exited 1 no matter
    what the guard actually did. `_canary-coverage.py` scored it 0/5: no-op'ing any of the five
    emission sites moved neither mode off baseline, so every one of them could stop working with no
    CI signal. A duplicated implementation is worse than no test — it drifts silently, and keeps
    asserting the old behaviour after the real code is changed.
    """
    problems: list[str] = []

    if not CANARY_DIR.is_dir():
        print(f"❌ SELF-TEST FAILED: fixture directory {CANARY_DIR} is missing — there is nothing "
              f"to detect, so nothing this function prints would mean anything.", file=sys.stderr)
        return 2
    if shutil.which("helm") is None:
        print("❌ SELF-TEST FAILED: `helm` is not on PATH, so every fixture would fail to render "
              "and the uri/no-editor/dangling detectors would go unexercised.", file=sys.stderr)
        return 2

    for name, want_rc, want in CASES:
        d = CANARY_DIR / name
        if not (d / "Chart.yaml").is_file():
            problems.append(f"[fixture] {name}: no Chart.yaml — a case that does not exist cannot "
                            f"witness anything, and its detector silently reads as proven.")
            continue
        rc, out = _drive([str(d)])
        if rc != want_rc:
            problems.append(f"[{name}] the real main() exited {rc}, want {want_rc}. "
                            f"Printed: {out.strip()[:300]!r}")
        if want is not None and want not in out:
            problems.append(f"[{name}] the finding text {want!r} never reached the report — this "
                            f"detector's emission site is no longer reachable. "
                            f"Printed: {out.strip()[:300]!r}")
        if want is None and "❌" in out:
            problems.append(f"[{name}] the CONTROL produced a finding. A guard that reddens on "
                            f"correct work is a guard that gets switched off. "
                            f"Printed: {out.strip()[:300]!r}")

    # The scope floor's own emission site, reached the only way a fixture can reach it.
    rc, out = _drive([str(CANARY_DIR / "there-is-no-chart-here")])
    if rc != 1 or "resolved to no chart" not in out:
        problems.append(f"[scope] naming a root that is not a chart exited {rc} and printed "
                        f"{out.strip()[:300]!r} — a scan that silently resolves to nothing must be "
                        f"a finding, or every other assertion here can pass over an empty set.")

    # All fixtures in ONE run: proves the scan loop continues past a chart it could not render
    # rather than stopping at the first, which `continue` is doing by hand.
    every = [str(CANARY_DIR / n) for n, _, _ in CASES]
    want_findings = sum(1 for _, want_rc, _ in CASES if want_rc == 1)
    rc, out = _drive(every)
    if rc != 1 or f"{want_findings} problem(s)" not in out:
        problems.append(f"[aggregate] scanning all {len(CASES)} fixtures at once exited {rc} and "
                        f"did not report {want_findings} problem(s) — the loop stops early, or a "
                        f"render failure aborts the charts after it. Printed: "
                        f"{out.strip()[:300]!r}")

    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2

    print(f"✅ self-test ok — {len(CASES)} fixture(s) driven through the real main(): the `uri` "
          f"shape, a missing editor, an editor with neither key, a dangling template reference and "
          f"an unrenderable chart each caught on exactly their own fixture; the control silent; a "
          f"root that resolves to no chart reported rather than passed; and all fixtures in one "
          f"run still yielding {want_findings} findings.")
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    return 1


if __name__ == "__main__":
    sys.exit(main())
