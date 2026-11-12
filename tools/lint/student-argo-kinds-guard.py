#!/usr/bin/env python3
"""Every kind a student-gitops app renders must be in the student Argo CD's resourceInclusions.

WHY THIS EXISTS (SEV1 2026-11-12). The attendees' shared Argo CD (student-argocd.yaml) watched every
API kind in every managed namespace — 536 kinds x 40 namespaces, 55k goroutines — and OOMKilled at
2Gi with 13 attendees, crash-looping through gitops-fundamentals and gitops-at-scale. The fix is
spec.resourceInclusions (values.yaml studentArgo.resourceInclusions): watch only what student apps
deploy. The catch is that Argo CD treats an unlisted kind as if it did not exist — not synced, not
diffed, no health — with no error anywhere. Add a PersistentVolumeClaim to the claims template and
the app reports Synced/Healthy while the PVC is never created. That is a silent module break, so it
is a gate, not a comment.

WHAT IT CHECKS. Renders the student ArgoCD CR (helm template, so the template wiring is proven too,
not just values.yaml), reads its resourceInclusions, then `kustomize build`s EVERY kustomization
under gitops/promotion/ — the source the gitops-fundamentals/gitops-at-scale fork jobs seed into
each attendee's claims-config, and every path their Applications/ApplicationSet point at — and
fails on any rendered (group, kind) no inclusion rule covers.

WHAT IT CANNOT DO: runtime children (ReplicaSet, Pod, AnalysisRun) are never rendered, so it cannot
tell you one is missing; those are listed by hand in values.yaml with the reason.

EXIT CODES (house convention, tools/lint/README.md): plain 0 clean / 1 finding / 2 could not
inspect; --self-test MUST exit exactly 1.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHART = "gitops/workshop-config"
TEMPLATE = "templates/student-argocd.yaml"
SOURCES = "gitops/promotion"
CANARY = pathlib.Path(__file__).resolve().parent / "student-argo-kinds-guard.canary"
MIN_DIRS = 5  # base + overlays/dev,stage,prod + rollouts today; fewer means discovery broke


class GuardError(Exception):
    pass


def run(cmd: list[str]) -> str:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False, cwd=ROOT)
    except FileNotFoundError as exc:
        raise GuardError(f"`{cmd[0]}` is not installed") from exc
    if proc.returncode != 0:
        raise GuardError(f"`{' '.join(cmd)}` failed (rc={proc.returncode}): {proc.stderr.strip()}")
    return proc.stdout


def inclusions() -> list[dict]:
    """The rules the CR actually ships, read from the rendered template."""
    out = run(["helm", "template", "t", CHART, "--set", "clusterDomain=apps.example.com", "-s", TEMPLATE])
    for doc in yaml.safe_load_all(out):
        if doc and doc.get("kind") == "ArgoCD":
            rules = yaml.safe_load(doc.get("spec", {}).get("resourceInclusions") or "") or []
            if not rules:
                raise GuardError(f"{CHART}/{TEMPLATE} renders no spec.resourceInclusions")
            return rules
    raise GuardError(f"{CHART}/{TEMPLATE} renders no ArgoCD CR")


def covered(group: str, kind: str, rules: list[dict]) -> bool:
    return any((group in r.get("apiGroups", []) or "*" in r.get("apiGroups", []))
               and (kind in r.get("kinds", []) or "*" in r.get("kinds", [])) for r in rules)


def rendered_kinds(directory: pathlib.Path) -> set[tuple[str, str]]:
    kinds = set()
    for doc in yaml.safe_load_all(run(["kustomize", "build", str(directory)])):
        if doc:
            api = doc.get("apiVersion", "")
            kinds.add((api.rpartition("/")[0], doc.get("kind", "")))
    return kinds


def find_offenders(dirs: list[pathlib.Path], rules: list[dict]) -> list[str]:
    problems = []
    for d in dirs:
        for group, kind in sorted(rendered_kinds(d)):
            if not covered(group, kind, rules):
                problems.append(f"{d.relative_to(ROOT)} renders {group or 'core'}/{kind}, which "
                                f"the student Argo CD does not watch — it would be silently never "
                                f"synced. Add it to studentArgo.resourceInclusions in "
                                f"{CHART}/values.yaml.")
    return problems


def kustomize_dirs(base: pathlib.Path) -> list[pathlib.Path]:
    return sorted(p.parent for p in base.rglob("kustomization.yaml"))


def self_test(rules: list[dict]) -> int:
    # Same functions as the real run, against the REAL rendered rules. Each canary dir declares
    # whether it must fire; a covered kind firing or an uncovered one staying silent is a failure.
    cases = {"control-covered": False, "uncovered-kind": True, "wrong-group": True}
    bad = []
    for name, must_fire in cases.items():
        fired = bool(find_offenders([CANARY / name], rules))
        if fired != must_fire:
            bad.append(f"{name}: fired={fired}, want {must_fire}")
    if bad:
        print("❌ SELF-TEST FAILED: " + "; ".join(bad), file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(cases)} canaries classified correctly — an unlisted kind and a listed "
          f"kind in the wrong API group both caught, the covered control silent. Exiting 1 — "
          f"detection is proven.")
    return 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    try:
        rules = inclusions()
        if args.self_test:
            return self_test(rules)
        dirs = kustomize_dirs(ROOT / SOURCES)
        if len(dirs) < MIN_DIRS:
            print(f"::error::found {len(dirs)} kustomizations under {SOURCES}, floor {MIN_DIRS} — "
                  f"discovery broke.", file=sys.stderr)
            return 2
        problems = find_offenders(dirs, rules)
    except (GuardError, yaml.YAMLError) as exc:
        print(f"::error::student-argo-kinds-guard could not inspect: {exc}", file=sys.stderr)
        return 2
    if problems:
        print(f"::error::student-argo-kinds-guard: {len(problems)} unwatched kind(s).", file=sys.stderr)
        for p in problems:
            print(f"  ❌ {p}", file=sys.stderr)
        return 1
    print(f"✅ student-argo-kinds-guard: {len(dirs)} kustomizations under {SOURCES}, every rendered "
          f"kind covered by the student Argo CD's {len(rules)} inclusion rules.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
