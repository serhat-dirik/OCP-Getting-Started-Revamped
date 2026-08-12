#!/usr/bin/env python3
r"""module-prep-pairing-guard.py — the prep OFFER and the prep CONFIRMATION must ship as a pair.

ORIGIN (2026-08-05, F-13). `ws prep` takes minutes. It used to be asked for at the top of the LAB
page, which is the worst possible moment: the attendee has finished reading and now sits watching a
progress line. The fix that shipped today splits it in two —

    concept.adoc   include::partial$prep-while-you-read.adoc[]   OFFER: start it, it builds while
                                                                 you read
    lab.adoc       include::partial$prereq-ws-start.adoc[]       CONFIRM: is it ready? if not, here

— and landed on all 26 concept pages and all 26 lab pages. Nothing structural holds the halves
together. Drop either one and the FAILURE IS SILENT: Antora still builds, the page still renders,
the attendee is simply never told to prepare, and then the lab does not work. There is no build
error to notice, no broken link, no missing image — only an attendee whose first lab command fails
for a reason the page never mentioned. A new module written from an old template, or a careless
edit to the header of an existing page, reintroduces it at any time.

WHAT IT CHECKS. The module list comes from /modules.yaml, which is the single source of truth for
the catalog and is ELASTIC — modules get split and combined when it serves the end-user, so a
hardcoded 26 would rot the first time the catalog moves.

  [1] PREP NOT OFFERED. A catalogued module whose concept.adoc does not include
      partial$prep-while-you-read. The attendee reads the concept with an empty cluster and
      discovers the wait at the lab, which is exactly the situation F-13 removed.
  [2] PREP NOT CONFIRMED. A catalogued module whose lab.adoc does not include
      partial$prereq-ws-start. Module independence is sacred: anyone can deep-link straight to a
      lab, so the lab page must stand alone and hand a cold-start reader a working environment.
  [3] MODULE-ID NOT IN EFFECT. A page that includes either partial without `:module-id:` set
      ABOVE the include. Both partials open with `ifndef::module-id[:module-id: unset-module-id]`,
      a deliberate belt-and-braces so a missing attribute cannot render as raw braces — which means
      the page still builds and still looks right, and cheerfully instructs the attendee to run
      `ws prep unset-module-id`. Ordering is part of the contract, not pedantry: the ifndef is
      evaluated where the include sits, so `:module-id:` written BELOW it is already too late.
  [4] MODULE-ID NAMES THE WRONG MODULE. A page under pages/<slug>/ whose `:module-id:` is some
      other catalogued slug. This is the copy-paste failure — a new module started from a
      neighbour's page — and it is worse than [3], because `ws prep <a-real-other-module>` succeeds
      and can EVICT this module's world from the shared namespace (`ws start/solve` evicts
      conflicting modules) instead of building it.

COMMENTED-OUT INCLUDES DO NOT COUNT. An author who comments an include out while debugging and then
pushes has removed it as far as the attendee is concerned, and a plain substring search would call
that page compliant — as it would for the usage example both partials carry in their own header
(`//   include::partial$prereq-ws-start.adoc[]`). Two mechanisms cover the two comment forms, and
only one of them is code: the include patterns anchor at `^\s*include::`, which already excludes the
`//` line form, so `////` blocks are the only case that needs stripping. That split was measured by
blinding, not assumed — see the note above BLOCK_COMMENT.

WHAT IT DELIBERATELY DOES NOT CHECK. Placement beyond the ordering rule in [3]. The prep offer is
supposed to sit near the TOP of the concept page (a TIP at the bottom buys nothing — the attendee
reaches it just before the lab anyway, which is the situation this replaces), but "near the top" is
not mechanically decidable: concept pages open with a varying number of admonitions, a [.lead]
paragraph, and sometimes a diagram. Encoding a line-number threshold would either miss real
bottom-placement or fire on legitimate pages, and a gate that cries wolf gets switched off, taking
the four detectors above with it. Placement stays a review item.

Exit codes:
  0  contract holds
  1  contract broken — or, under --self-test, every canary was correctly detected
  2  the guard could not inspect what it claims to inspect (no catalog, no parser, no pages)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "modules.yaml"
PAGES_ROOT = REPO / "content" / "modules" / "ROOT" / "pages"

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a machine without PyYAML
    print("module-prep-pairing-guard: PyYAML is not installed. The module catalog is the single "
          "source of truth for this check, and this guard parses it properly rather than "
          "pattern-matching it — refusing to report clean without a parser. "
          "Install it (python3 -m pip install PyYAML) and re-run.", file=sys.stderr)
    sys.exit(2)

# The two halves of the pairing, matched as INCLUDE DIRECTIVES rather than as bare names, so a
# mention of a partial in prose or in a cross-reference is not mistaken for wiring it in.
INCLUDE_PREP = re.compile(r"^\s*include::partial\$prep-while-you-read\.adoc\[")
INCLUDE_PREREQ = re.compile(r"^\s*include::partial\$prereq-ws-start\.adoc\[")

# A page-level attribute definition, e.g. `:module-id: pipelines-fundamentals`.
PAGE_MODULE_ID = re.compile(r"^:module-id:[ \t]*(\S+)")

# A `////` comment-block delimiter. ONLY the block form needs stripping, and that asymmetry is
# measured rather than assumed: the include patterns above anchor at `^\s*include::`, so a line
# commented out the ordinary way (`// include::partial$…`) can never match them in the first place —
# a LINE_COMMENT pattern was written, blinded, and found to change no outcome, i.e. it was dead code
# pretending to be a safety net. A `////` block is different: the lines INSIDE it are unindented and
# match perfectly, so without this the shape below grades as compliant while rendering nothing.
#     ////
#     include::partial$prereq-ws-start.adoc[]
#     ////
BLOCK_COMMENT = re.compile(r"^/{4,}$")


def _is_canary(path: str) -> bool:
    """A fixture belonging to some guard's canary — never this guard's finding.

    Matches BOTH shapes. `foo-guard.canary.adoc` is a single-file canary; `foo-guard.canary/` is a
    directory canary holding a whole fake tree. The original test was `".canary." not in path`,
    which silently covered only the first: a directory canary's path contains `.canary/`, with a
    SLASH, so every .adoc inside it was scanned as real content. Latent in five guards until
    2026-08-12, when cockpit-attribute-emission-guard became the first directory canary to hold
    .adoc files and reddened attribute-interpolation-guard on a deliberately-malformed fixture.
    """
    return ".canary." in path or ".canary/" in path


def catalog_slugs(catalog: Path) -> list[str]:
    """Ordered module slugs from modules.yaml — position is the module number, slug is its identity."""
    try:
        data = yaml.safe_load(catalog.read_text(encoding="utf-8", errors="replace"))
    except (OSError, yaml.YAMLError):
        return []
    if not isinstance(data, dict):
        return []
    entries = data.get("modules")
    if not isinstance(entries, list):
        return []
    return [e["slug"] for e in entries
            if isinstance(e, dict) and isinstance(e.get("slug"), str) and e["slug"]]


def visible_lines(text: str) -> list[tuple[int, str]]:
    """(1-based lineno, text) for every line an attendee's render can actually be affected by.

    Commented-out content is dropped. A commented include is not an include: the attendee gets
    nothing from it, so grading it as present would let a debugging edit ship as compliant.
    """
    out: list[tuple[int, str]] = []
    in_block = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        if BLOCK_COMMENT.match(raw.strip()):
            in_block = not in_block
            continue
        if in_block:
            continue
        out.append((lineno, raw))
    return out


def include_line(lines: list[tuple[int, str]], pattern: re.Pattern) -> int | None:
    for lineno, text in lines:
        if pattern.match(text):
            return lineno
    return None


def module_id_of(lines: list[tuple[int, str]]) -> tuple[int, str] | None:
    for lineno, text in lines:
        m = PAGE_MODULE_ID.match(text)
        if m:
            return lineno, m.group(1)
    return None


def read_page(path: Path) -> str | None:
    """Page text, or None when the page does not exist.

    Unreadable-but-present is DELIBERATELY not caught here and propagates to main(), which turns it
    into exit 2. "This module has no lab page" is a finding about the content; "I could not read the
    file" is a finding about the guard, and collapsing the two lets a broken checkout read as a
    content defect (or, worse, get 'fixed' as one).
    """
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8", errors="replace")


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def scan(slugs: list[str], pages_root: Path, page_paths: list[Path]) -> list[tuple[int, str, str]]:
    """Return (detector, path, message) for every broken half of the pairing."""
    findings: list[tuple[int, str, str]] = []
    known = set(slugs)

    # ── [1] and [2]: every catalogued module offers prep on its concept page and confirms it on
    #     its lab page. Driven from the catalog, never from what happens to be on disk, so a module
    #     added to modules.yaml without its pairing is a finding rather than an absence nobody sees.
    for slug in slugs:
        for filename, pattern, detector, what in (
            ("concept.adoc", INCLUDE_PREP, 1, "partial$prep-while-you-read"),
            ("lab.adoc", INCLUDE_PREREQ, 2, "partial$prereq-ws-start"),
        ):
            page = pages_root / slug / filename
            text = read_page(page)
            if text is None:
                findings.append((detector, rel(page),
                                 f"module '{slug}' is in modules.yaml but has no {filename} — "
                                 f"the {what} include has nowhere to live"))
                continue
            if include_line(visible_lines(text), pattern) is None:
                findings.append((detector, rel(page),
                                 f"does not include {what} — the attendee is never told to "
                                 f"`ws prep {slug}`, and nothing about the built page shows it"))

    # ── [3] and [4]: wherever either partial IS included, the attribute it interpolates has to be
    #     in effect and has to name this module. Scanned over every page, not just concept/lab, so
    #     a wrapup or troubleshooting page that adopts the partial is held to the same contract.
    for page in page_paths:
        text = read_page(page)
        if text is None:
            continue
        lines = visible_lines(text)
        first = [ln for ln in (include_line(lines, INCLUDE_PREP),
                               include_line(lines, INCLUDE_PREREQ)) if ln is not None]
        if not first:
            continue
        at = min(first)
        found = module_id_of(lines)
        if found is None:
            findings.append((3, rel(page),
                             f"includes a prep partial at line {at} but never sets :module-id: — "
                             f"the partial's ifndef fallback fires and the attendee is told to run "
                             f"`ws prep unset-module-id`"))
            continue
        id_line, module_id = found
        if id_line > at:
            findings.append((3, rel(page),
                             f":module-id: is set at line {id_line}, BELOW the include at line "
                             f"{at} — the ifndef is evaluated at the include, so the fallback has "
                             f"already won and the attendee is told to run `ws prep unset-module-id`"))
            continue
        owner = page.parent.name
        if owner in known and module_id in known and module_id != owner:
            findings.append((4, rel(page),
                             f":module-id: is '{module_id}' on a page belonging to '{owner}' — "
                             f"the attendee is sent to prepare a DIFFERENT module, which succeeds "
                             f"and can evict this module's world from the shared namespace"))
    return findings


def tracked_pages(pages_root: Path) -> list[Path]:
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", "--", f"{rel(pages_root)}/*.adoc"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
    except Exception:
        return []
    # Fixtures belonging to other guards are deliberately broken content — scanning them would
    # report another guard's canary as this guard's finding.
    return [REPO / f for f in out if not _is_canary(f)]


HEADLINE = {
    1: "concept page does not OFFER prep (partial$prep-while-you-read)",
    2: "lab page does not CONFIRM prep (partial$prereq-ws-start)",
    3: ":module-id: not in effect where a prep partial is included",
    4: ":module-id: names a different module than the page it sits in",
}


def report(findings) -> int:
    if not findings:
        print("✅ prep pairing: every catalogued module offers prep on its concept page and")
        print("   confirms it on its lab page, with :module-id: in effect at every include")
        return 0
    for detector in sorted(HEADLINE):
        hits = [f for f in findings if f[0] == detector]
        if not hits:
            continue
        print(f"❌ [{detector}] {len(hits)} × {HEADLINE[detector]}")
        for _, path, message in hits[:25]:
            print(f"   {path}: {message}")
        if len(hits) > 25:
            print(f"   … and {len(hits) - 25} more")
    return 1


# ── fixtures ──────────────────────────────────────────────────────────────────────────────────────
# A page that satisfies the contract, parameterised so each canary can break exactly one thing.
def _concept(slug: str, *, module_id: str | None = None, include: bool = True,
             id_below: bool = False) -> str:
    mid = slug if module_id is None else module_id
    text = f"= {slug} concept\n"
    if not id_below:
        text += f":module-id: {mid}\n"
    text += "\n[.lead]\nWhy this matters.\n\n"
    if include:
        text += "include::partial$prep-while-you-read.adoc[]\n"
    if id_below:
        text += f"\n:module-id: {mid}\n"
    return text


def _lab(slug: str, *, include: bool = True) -> str:
    return (f"= {slug} lab\n:module-id: {slug}\n\n"
            + ("include::partial$prereq-ws-start.adoc[]\n" if include else "")
            + "\n== Exercise 1\n")


def _tree(tmpdir: Path, name: str, pages: dict[str, str]) -> tuple[Path, list[Path]]:
    root = tmpdir / name
    written = []
    for relpath, text in pages.items():
        p = root / relpath
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        written.append(p)
    return root, written


def self_test(tmpdir: Path) -> int:
    slugs = ["alpha-module", "beta-module"]

    # Proof 0: a detector that fires on everything proves nothing. The clean fixture exercises the
    # shapes most likely to be false-positived: a page with no partial and no :module-id: at all, a
    # `////` block, and a `//` comment that MENTIONS an include (both partials carry exactly that in
    # their own headers).
    clean = {
        "alpha-module/concept.adoc": _concept("alpha-module"),
        "alpha-module/lab.adoc": _lab("alpha-module"),
        "beta-module/concept.adoc":
            "= beta concept\n:module-id: beta-module\n\n"
            "////\nA block comment discussing include::partial$prereq-ws-start.adoc[] at length.\n////\n"
            "// Usage: include::partial$prep-while-you-read.adoc[]\n"
            "include::partial$prep-while-you-read.adoc[]\n",
        "beta-module/lab.adoc": _lab("beta-module"),
        "beta-module/wrapup.adoc": "= beta wrapup\n\nNo partial here, and no module-id either.\n",
    }
    root, pages = _tree(tmpdir, "clean", clean)
    found = scan(slugs, root, pages)
    if found:
        print(f"❌ SELF-TEST FAILED: the CLEAN fixture was flagged ({found}).")
        print("   A guard that fires on correct content will be disabled by the first person it annoys.")
        return 2

    # Each canary breaks exactly one thing and must be caught by exactly the detector that owns it.
    canaries = [
        (1, "no-offer", "the prep offer dropped from a concept page", {
            "alpha-module/concept.adoc": _concept("alpha-module", include=False),
            "alpha-module/lab.adoc": _lab("alpha-module"),
            "beta-module/concept.adoc": _concept("beta-module"),
            "beta-module/lab.adoc": _lab("beta-module"),
        }),
        (1, "no-concept-page", "a module catalogued in modules.yaml with no concept.adoc at all", {
            "alpha-module/lab.adoc": _lab("alpha-module"),
            "beta-module/concept.adoc": _concept("beta-module"),
            "beta-module/lab.adoc": _lab("beta-module"),
        }),
        (2, "no-confirm", "the prep confirmation dropped from a lab page", {
            "alpha-module/concept.adoc": _concept("alpha-module"),
            "alpha-module/lab.adoc": _lab("alpha-module", include=False),
            "beta-module/concept.adoc": _concept("beta-module"),
            "beta-module/lab.adoc": _lab("beta-module"),
        }),
        (2, "confirm-in-block-comment", "a lab page whose include sits inside a //// block", {
            "alpha-module/concept.adoc": _concept("alpha-module"),
            "alpha-module/lab.adoc":
                "= alpha lab\n:module-id: alpha-module\n\n"
                "////\ninclude::partial$prereq-ws-start.adoc[]\n////\n\n== Exercise 1\n",
            "beta-module/concept.adoc": _concept("beta-module"),
            "beta-module/lab.adoc": _lab("beta-module"),
        }),
        (3, "no-module-id", "a page including a partial with :module-id: never set", {
            "alpha-module/concept.adoc":
                "= alpha concept\n\n[.lead]\nWhy.\n\ninclude::partial$prep-while-you-read.adoc[]\n",
            "alpha-module/lab.adoc": _lab("alpha-module"),
            "beta-module/concept.adoc": _concept("beta-module"),
            "beta-module/lab.adoc": _lab("beta-module"),
        }),
        (3, "module-id-below-include", "an ordering break — :module-id: set under the include", {
            "alpha-module/concept.adoc": _concept("alpha-module", module_id="alpha-module",
                                                  id_below=True),
            "alpha-module/lab.adoc": _lab("alpha-module"),
            "beta-module/concept.adoc": _concept("beta-module"),
            "beta-module/lab.adoc": _lab("beta-module"),
        }),
        (4, "wrong-module-id", "a copy-pasted page prepping its neighbour's module", {
            "alpha-module/concept.adoc": _concept("alpha-module", module_id="beta-module"),
            "alpha-module/lab.adoc": _lab("alpha-module"),
            "beta-module/concept.adoc": _concept("beta-module"),
            "beta-module/lab.adoc": _lab("beta-module"),
        }),
    ]

    for detector, name, description, tree in canaries:
        root, pages = _tree(tmpdir, name, tree)
        found = scan(slugs, root, pages)
        hit = [f for f in found if f[0] == detector]
        if not hit:
            print(f"❌ SELF-TEST FAILED: detector [{detector}] did not catch '{name}' —")
            print(f"   {description}. Findings from that fixture: {found or 'none'}.")
            print("   The detector is blind, so a clean scan of the real tree proves nothing.")
            return 2
        other = [f for f in found if f[0] != detector]
        if other:
            print(f"❌ SELF-TEST FAILED: canary '{name}' also tripped other detectors: {other}.")
            print("   Each canary must isolate one detector, or a blinded detector can hide behind"
                  " a neighbour's finding.")
            return 2

    # Proof 1: the guard must be able to SEE the real catalog and the real pages, or its clean
    # verdict is a clean scan of nothing.
    real_slugs = catalog_slugs(CATALOG)
    if not real_slugs:
        print(f"❌ SELF-TEST FAILED: no module slugs parsed from {rel(CATALOG)} — the guard would")
        print("   report a clean pairing after checking zero modules.")
        return 2
    real_pages = tracked_pages(PAGES_ROOT)
    if not real_pages:
        print("❌ SELF-TEST FAILED: no tracked .adoc pages found — detectors [3]/[4] would pass by")
        print("   scanning nothing.")
        return 2

    print("✅ self-test ok — clean fixture silent (a comment that MENTIONS an include, and a page")
    print(f"   with no partial at all, stay quiet); all {len(canaries)} canaries caught by their own")
    print(f"   detector; {len(real_slugs)} catalogued module(s) and {len(real_pages)} tracked page(s)")
    print("   visible to the real scan.")
    return 1  # house convention: every canary caught == exit exactly 1


def main(argv=None) -> int:
    # argv is a PARAMETER, not sys.argv, because tools/lint/_canary-coverage.py drives every guard
    # by importing it and calling `mod.main(["--self-test"])`. A zero-argument main() raises
    # TypeError there, the sweep's BaseException handler turns that into rc=2, and the guard reports
    # `unmutated control ran 2/2` — i.e. it is silently EXEMPT from the gate that proves its
    # detectors can be blinded. Measured 2026-08-05 against this very file.
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the detectors fire against planted canaries (exit 1 = PASS)")
    args = ap.parse_args(argv)

    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return self_test(Path(td))

    slugs = catalog_slugs(CATALOG)
    if not slugs:
        print(f"❌ no module slugs parsed from {rel(CATALOG)} — refusing to report a clean pairing "
              f"after checking zero modules.")
        return 2
    if not PAGES_ROOT.is_dir():
        print(f"❌ {rel(PAGES_ROOT)} is not a directory — the guard cannot see the pages it grades.")
        return 2
    pages = tracked_pages(PAGES_ROOT)
    if not pages:
        print(f"❌ no tracked .adoc pages found under {rel(PAGES_ROOT)} — refusing to report a "
              f"clean scan of nothing.")
        return 2
    try:
        findings = scan(slugs, PAGES_ROOT, pages)
    except OSError as exc:
        print(f"❌ a tracked page exists but could not be read ({exc}) — that is a broken checkout, "
              f"not a clean tree. Refusing to report on a scan that did not finish.")
        return 2
    print(f"   checked {len(slugs)} catalogued module(s) across {len(pages)} tracked page(s)")
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
