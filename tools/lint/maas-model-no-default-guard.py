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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _scope import Scope  # noqa: E402  (path must be set first; this file is run as a script)

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

# A LITERAL, deliberately not len(SITES): the point is that shrinking SITES must not be able to
# shrink its own floor. Truncating the list the driver iterates (`SITES[:1]`) collapses the count
# below this; editing SITES itself trips the self-test, which asserts the two agree. Adding a site
# means bumping this number in the same change.
MIN_SITES = 4

# A value is acceptable ONLY if it is visibly not a real setting. The trailing "@" is Antora's
# soft-set marker and is stripped before judging.
#
# ANGLE BRACKETS WERE THE MARKER UNTIL 2026-07-31, AND THEY WERE INVISIBLE TO ATTENDEES. This
# guard required `<set-from-ogsr-maas-credentials>`, Asciidoctor emitted those brackets unescaped
# inside <code>, and every browser then parsed `<set-from-ogsr-maas-credentials>` as an unknown
# HTML tag and dropped it. The built page read "On this workshop it is " and "serving " — the
# sentence lost its subject, in five places across two files, with no build warning at any log
# level. Verified in the built HTML, not inferred. So the guard was mandating a placeholder that
# could never be seen: it enforced the right RULE through a mechanism that defeated the rule's
# purpose, which is the same shape as every "check that inspects nothing" fixed here today.
#
# `set-from-…` (no brackets) is now the marker. It is still visibly not a model name, it still
# cannot be mistaken for a real setting, and it survives rendering. Bracketed forms stay accepted
# so an endpoint written `<set-from-…>` in a YAML comment or a non-rendered file is not a failure —
# what changed is that the bracket-free form is no longer rejected.
PLACEHOLDER = re.compile(r"^<[^>]+>$|^set-from-[\w.-]+$|(^|\.)example\.com(/|$)")


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


def check(sites, min_sites: int = 1) -> int:
    """`min_sites` is the floor for the number of sites actually judged.

    It defaults to 1 for the self-test's single-site canaries; main() passes MIN_SITES. The old
    "if not checked" was the weak form of this: it caught SITES = [] and missed SITES[:1], which is
    the likelier accident and left the guard reporting "clean (1 site checked)" while three places a
    concrete model can hide went unread (audit 2026-08-01).
    """
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
    scope = Scope("maas-model-no-default-guard")
    scope.require("sites judged", min_sites,
                  "every place the repo can carry a MaaS model or endpoint default. Reading fewer "
                  "than all of them is not a clean result, it is an unread file.")
    scope.add("sites judged", checked)
    collapsed = scope.enforce()
    if collapsed:
        return collapsed
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
        rx = re.compile(r'^\s*maas_model\s*:\s*"?([^"\n#]+?)"?\s*$', re.M)
        cases = [
            # (filename, contents, expected rc, what it proves)
            ("bad.yml", '    maas_model: "llama-scout-17b@"\n', 1,
             "a concrete model did not trip the guard"),
            ("good.yml", '    maas_model: "<set-from-ogsr-maas-credentials>@"\n', 0,
             "a bracketed placeholder was wrongly flagged"),
            ("bare.yml", '    maas_model: "set-from-ogsr-maas-credentials@"\n', 0,
             "the bracket-free placeholder — the form that actually survives HTML rendering, and "
             "the reason this rule was rewritten on 2026-07-31 — was wrongly flagged"),
            # The empty-value rule had no canary at all: judge() rejects an empty value with its own
            # message and nothing proved the branch was even reachable. An empty value is how a
            # half-deleted line looks and must not read as "no default is set, so this is fine".
            #
            # The shape below is the REACHABLE one, established by measurement rather than assumed:
            # the value is the Antora soft-set marker with nothing in front of it, which is what a
            # line looks like when someone clears the model and leaves the `@`. judge() strips the
            # marker, sees "", and rejects it.
            ("soft-set-only.yml", '    maas_model: "@"\n', 1,
             "a value that is nothing but the Antora soft-set marker did not trip the guard — a "
             "half-deleted line would read as a passing placeholder"),
            # …and a value that is only whitespace takes the same branch.
            ("blank.yml", '    maas_model:  \n', 1,
             "a whitespace-only value did not trip the guard"),
            # NOTE, measured 2026-08-01: `maas_model: ""` and a key with NOTHING after the colon do
            # not reach judge() at all — the value regex requires one character, so they produce
            # zero hits and exit 2 ("expected exactly one value"). That is also a refusal to report
            # clean, by a different route, and it is recorded here so the next reader does not
            # "fix" the fixture by adding a case that can only ever exit 2.
        ]
        for name, text, expected, complaint in cases:
            probe = Path(d) / name
            probe.write_text(text)
            if check([(probe, rx, f"canary-{name}")]) != expected:
                print(f"SELF-TEST FAILED: {complaint}", file=sys.stderr)
                ok = False

    # The declared floor must still equal the declared site list: MIN_SITES is a literal so that
    # shrinking SITES cannot shrink its own floor, and this is what notices when the two diverge.
    if MIN_SITES != len(SITES):
        print(f"SELF-TEST FAILED: MIN_SITES is {MIN_SITES} but SITES declares {len(SITES)} entr"
              f"(y|ies). A site was added or removed without re-stating the floor, so the floor has "
              f"stopped asserting the real set.", file=sys.stderr)
        ok = False
    for failure in Scope.self_check():
        print(f"SELF-TEST FAILED: {failure}", file=sys.stderr)
        ok = False

    if not ok:
        return 2
    print("self-test ok — a concrete value fails, an empty value fails, and both placeholder forms "
          "pass; the site-count floor matches the declared sites; the scope ledger fails an empty "
          "or truncated input set.")
    return 1


if __name__ == "__main__":
    raise SystemExit(self_test() if "--self-test" in sys.argv else check(SITES, MIN_SITES))
