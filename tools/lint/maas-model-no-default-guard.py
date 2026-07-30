#!/usr/bin/env python3
"""maas-model-no-default-guard.py — the repo must ship NO concrete MaaS model.

WHY THIS EXISTS, AND WHY IT REPLACED A GUARD WRITTEN THE SAME DAY. The first version of this file
asserted that `versions.yaml`'s `maas.model` and `content/antora.yml`'s `maas_model` AGREED with each
other. They did agree — on `llama-scout-17b` — and both were wrong. `ws maas show` reported every AI
namespace correctly converged on `qwen3-14b` from the workshop credential, while the built docs
rendered `llama-scout-17b`, a model this cluster's key answers with HTTP 401. Two files can be
perfectly consistent and jointly false; a guard that checks them against each other cannot see that.

The project owner then settled the question (2026-07-30): "this may change in every setup, whatever
available the workshop should work with it. there is no default, only expected parameters." That
turns the invariant inside out. The thing worth enforcing is not that the copies match — it is that
NO plausible-looking model name is baked into the repo at all, because a wrong-but-plausible value
is worse than a visibly-empty one. Nobody questions `llama-scout-17b`; everybody questions
`<set-from-ogsr-maas-credentials>`.

WHAT IT CHECKS. Every place the repo can carry a MaaS model or endpoint default:
  * `content/antora.yml`               — `asciidoc.attributes.maas_model` / `maas_endpoint`
  * `gitops/workshop-config/values.yaml` — `showroom.maasModel` / `showroom.maasEndpoint`
Each value must be a PLACEHOLDER: angle-bracketed (`<set-from-...>`), or an obvious example host
(`example.com`). A bare model-shaped identifier — `qwen3-14b`, `llama-scout-17b`, anything matching
a vendor-model pattern — fails, INCLUDING the model this cluster happens to serve today. Pinning
today's entitlement is the same mistake as pinning yesterday's; the value belongs to the install,
not the repo.

`versions.yaml`'s `maas.model` is deliberately NOT policed. That entry is a dated record of what was
verified against a real endpoint on a real date — provenance, not configuration. Nothing renders it
into the site (it generates no attribute; `{maas_model}` comes only from antora.yml), so it cannot
mislead an attendee, and rewriting history to match today's cluster is the thing this project calls
doctoring captured output.

A missing file or an unparseable key is an ERROR (exit 2), never a silent pass — a guard that
inspects nothing must not report clean.

USAGE
    tools/lint/maas-model-no-default-guard.py     # check the real repo files
    tools/lint/maas-model-no-default-guard.py --self-test   # prove it fires; must exit non-zero
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# tools/lint/<this file> -> tools/lint -> tools -> repo root. Getting this wrong made the first
# run look for content/ under tools/; the guard refused to report clean rather than passing on a
# scope it could not find, which is the behaviour that made the bug visible in one run.
REPO = Path(__file__).resolve().parents[2]

# Where a MaaS default can hide. Each entry: file, regex capturing the value, human label.
SITES = [
    (REPO / "content/antora.yml",
     re.compile(r'^\s*maas_model\s*:\s*"?([^"\n#]+?)"?\s*$', re.M), "antora.yml maas_model"),
    (REPO / "content/antora.yml",
     re.compile(r'^\s*maas_endpoint\s*:\s*"?([^"\n#]+?)"?\s*$', re.M), "antora.yml maas_endpoint"),
    (REPO / "gitops/workshop-config/values.yaml",
     re.compile(r'^\s*maasModel\s*:\s*"?([^"\n#]+?)"?\s*$', re.M), "values.yaml maasModel"),
    (REPO / "gitops/workshop-config/values.yaml",
     re.compile(r'^\s*maasEndpoint\s*:\s*"?([^"\n#]+?)"?\s*$', re.M), "values.yaml maasEndpoint"),
]

# A value is acceptable ONLY if it is visibly not a real setting. Angle brackets are the repo's
# chosen marker; example.com is the long-standing placeholder host. The trailing "@" is Antora's
# soft-set marker and is stripped before judging.
PLACEHOLDER = re.compile(r"^<[^>]+>$|(^|\.)example\.com(/|$)")


def judge(value: str) -> str | None:
    """Return a failure reason, or None if the value is an acceptable placeholder."""
    v = value.strip().rstrip("@").strip()
    if not v:
        return "empty — cannot tell an unset parameter from a deleted line"
    if PLACEHOLDER.search(v):
        return None
    return (f"{v!r} is a concrete value. There is no default MaaS model or endpoint: it is an "
            f"install parameter, and a plausible-looking one ships a lie to every attendee whose "
            f"cluster serves something else. Use <set-from-ogsr-maas-credentials>.")


def check(sites) -> int:
    problems, checked = [], 0
    for path, rx, label in sites:
        if not path.exists():
            print(f"ERROR: {path} is missing — refusing to report clean", file=sys.stderr)
            return 2
        hits = rx.findall(path.read_text())
        if len(hits) != 1:
            print(f"ERROR: {label}: expected exactly one value, found {len(hits)}", file=sys.stderr)
            return 2
        checked += 1
        why = judge(hits[0])
        if why:
            problems.append(f"  {label}: {why}")
    if not checked:
        print("ERROR: inspected nothing", file=sys.stderr)
        return 2
    if problems:
        print(f"maas-model-no-default-guard: {len(problems)} offender(s) across {checked} site(s).")
        print("\n".join(problems))
        return 1
    print(f"maas-model-no-default-guard: clean ({checked} site(s) checked, all placeholders).")
    return 0


def self_test() -> int:
    """Prove the guard fires on a concrete value AND stays quiet on a placeholder."""
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as d:
        bad = Path(d) / "bad.yml"; bad.write_text('    maas_model: "llama-scout-17b@"\n')
        good = Path(d) / "good.yml"; good.write_text('    maas_model: "<set-from-ogsr-maas-credentials>@"\n')
        rx = re.compile(r'^\s*maas_model\s*:\s*"?([^"\n#]+?)"?\s*$', re.M)
        if check([(bad, rx, "canary-concrete")]) != 1:
            print("SELF-TEST FAILED: a concrete model did not trip the guard", file=sys.stderr); ok = False
        if check([(good, rx, "canary-placeholder")]) != 0:
            print("SELF-TEST FAILED: a placeholder was wrongly flagged", file=sys.stderr); ok = False
    if not ok:
        return 2
    print("self-test ok — a concrete value fails and a placeholder passes (both proven).")
    return 1


if __name__ == "__main__":
    raise SystemExit(self_test() if "--self-test" in sys.argv else check(SITES))
