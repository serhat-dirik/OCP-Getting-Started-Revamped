#!/usr/bin/env python3
"""`conflictsWith` must be symmetric: if A conflicts with B, B must conflict with A.

WHY THIS EXISTS. `gc_conflicts()` in tools/ws/ws reads only the STARTING module's list. So a
mutual conflict has to be written into both files by hand, and nothing checked that it was. The
18 charts that share a `{user}-dev` namespace form a clique — every one lists the other 17 —
which is 306 hand-maintained entries that must all agree.

It failed the first time it was tested. `application-logging` landed on 2026-08-22 declaring all
18 of its conflicts, and NONE of the 18 declared it back. The consequence is silent and delayed:
`adm start <any of the 18>` over a materialized `application-logging` does not garbage-collect it,
so a dormant `entry-application-logging-<user>` Application is left behind owning a Deployment in
the namespace the new module is about to use. That is the same shape as the G4 SEV2 that
`observability-health-scale` hit on 2026-07-12 — found then by an attendee, not by CI.

Adding a module to the catalogue is exactly when this breaks, and exactly when nobody is looking
at the other 18 files.

WHAT THIS GUARD CANNOT DO: it does not decide WHICH modules should conflict. A pair that genuinely
does not conflict is invisible to it — it only enforces that whatever the charts claim, they claim
in both directions.
"""
from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
META = "gitops/entry-states/*/ws-meta.yaml"


def load() -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for f in sorted(ROOT.glob(META)):
        slug = f.parent.name
        try:
            doc = yaml.safe_load(f.read_text()) or {}
        except yaml.YAMLError as exc:
            print(f"::error::{f.relative_to(ROOT)} is not valid YAML ({exc})", file=sys.stderr)
            sys.exit(2)
        out[slug] = list(doc.get("conflictsWith") or [])
    return out


def asymmetric(graph: dict[str, list[str]]) -> list[str]:
    problems = []
    for a, peers in sorted(graph.items()):
        for b in peers:
            if b not in graph:
                problems.append(f"{a} conflicts with {b!r}, which has no entry state — a typo or a "
                                f"deleted module. `adm start` would never garbage-collect it.")
            elif a not in graph[b]:
                problems.append(f"{a} conflicts with {b}, but {b} does NOT conflict with {a}. "
                                f"Starting {b} over a materialized {a} leaves an orphan "
                                f"entry-{a}-<user> Application owning workloads in that namespace. "
                                f"Add `- {a}` to gitops/entry-states/{b}/ws-meta.yaml.")
    return problems


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    for a in argv:
        if a not in ("--self-test", "-h", "--help"):
            print(f"::error::unknown argument {a!r}", file=sys.stderr)
            return 2
    if "-h" in argv or "--help" in argv:
        print(__doc__)
        return 0

    if "--self-test" in argv:
        # The canary is asserted on the checker, not on a fixture tree: the defect is about the
        # SHAPE of the relation, and a fixture would only prove that one directory is consistent.
        cases = [
            ({"a": ["b"], "b": ["a"]}, 0, "symmetric pair is silent"),
            ({"a": ["b"], "b": []}, 1, "one-way edge is caught"),
            ({"a": ["b"], "b": ["a"], "c": ["a"]}, 1, "third module's one-way edge is caught"),
            ({"a": ["ghost"]}, 1, "edge to a non-existent entry state is caught"),
            ({"a": [], "b": []}, 0, "no conflicts declared is silent"),
            ({"a": ["b", "c"], "b": ["a"], "c": ["a"]}, 0, "a full clique is silent"),
            ({"a": ["b", "c"], "b": ["a", "c"], "c": ["a"]}, 1, "clique missing ONE back-edge is caught"),
        ]
        bad = [f"{why}: got {len(asymmetric(g))} problem(s), want {want}"
               for g, want, why in cases if (len(asymmetric(g)) > 0) != (want > 0)]
        if bad:
            print("❌ SELF-TEST FAILED: " + "; ".join(bad), file=sys.stderr)
            return 2
        print(f"✅ self-test: {len(cases)} relation shapes classified correctly — one-way edges, "
              f"dangling targets and a clique with a single missing back-edge all caught, and "
              f"symmetric graphs stayed silent. Exiting 1 — detection is proven.")
        return 1

    graph = load()
    if not graph:
        print(f"::error::no ws-meta.yaml found under {META} — nothing to check.", file=sys.stderr)
        return 2
    problems = asymmetric(graph)
    if problems:
        print(f"::error::conflicts-symmetry-guard: {len(problems)} asymmetric relation(s).",
              file=sys.stderr)
        for p in problems:
            print(f"  ❌ {p}", file=sys.stderr)
        return 1
    edges = sum(len(v) for v in graph.values())
    print(f"✅ conflicts-symmetry-guard: {len(graph)} entry states, {edges} conflict edges, every "
          f"one declared in both directions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
