#!/usr/bin/env python3
"""The A/B/C/D block structure must agree across modules.yaml, the navs and the catalogue table.

WHY THIS EXISTS. The four blocks — A Foundations, B Delivery & Trust, C Platform & Tenancy,
D Advanced Electives — were rendered in three navs, in `index.adoc` and in the README, and declared
in none of them. They lived in a README sentence and in people's heads, so nothing could check
them. Three real defects came out of that in two days, all found by hand:

  * 2026-08-22 — `application-logging` was inserted at position 14 and its `index.adoc` row was
    nested inside `securing-apps-keycloak`'s `ifndef` wrapper. A deployer disabling Keycloak would
    have silently lost Application Logging from the catalogue table. Nothing rendered differently
    for anyone who had both enabled, which is why it survived review.
  * 2026-08-22 — the same insertion left the README saying "26 modules" in four places and giving
    Day 3 as `M18–M26` over a 27-module catalogue.
  * 2026-08-23 — a reordering script dropped three section headers (`.B`, `.C`, `.D`) out of
    nav-workshop.adoc. `check-module-order.sh` passed: it asserts module ORDER, and a missing
    section header is not a module. A green tick over a real regression.

Each detector below is one of those, generalised. `check-module-order.sh` owns "the navs list the
modules in the right order"; this owns "the blocks agree with the SSOT". The two are deliberately
separate — the 2026-08-23 defect passed the first while failing the second.

WHAT THIS CANNOT DO: it does not judge whether a module is in the RIGHT block. That is a teaching
decision, and no guard should have an opinion about it.
"""
from __future__ import annotations

import contextlib
import io
import itertools
import pathlib
import re
import sys

import yaml


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception -> rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import exits 1 —
    exactly what this guard's CI step reads as "the canary fired". `os._exit` is what makes the code
    stick: an excepthook cannot change the exit status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::module-block-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2

ROOT = pathlib.Path(__file__).resolve().parents[2]
CANARY_DIR = pathlib.Path(__file__).resolve().parent / "module-block-guard.canary"
NAVS = ("nav-workshop.adoc", "nav-demo.adoc", "nav-instructor.adoc")
COUNT_PROSE = re.compile(r'\b(\d+)\s+(?:self-contained\s+)?modules\b')
MIN_MODULES = 2   # two modules in one block is the smallest tree where "contiguous" means anything


def load(root: pathlib.Path):
    mods = (yaml.safe_load((root / "modules.yaml").read_text()) or {}).get("modules") or []
    return mods


def read(root: pathlib.Path, rel: str) -> str:
    p = root / rel
    return p.read_text(encoding="utf-8", errors="replace") if p.is_file() else ""


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()

    positional = [a for a in argv if not a.startswith("-")]
    root = pathlib.Path(positional[0]) if positional else ROOT

    mods = load(root)
    problems: list[str] = []

    # D1 — every module declares a block. Without this the other three have nothing to compare to.
    undeclared = [m.get("slug", "?") for m in mods if not m.get("block")]
    if undeclared:
        problems.append(
            f"{len(undeclared)} module(s) declare no `block:` in modules.yaml: "
            f"{', '.join(undeclared)}. The block structure is rendered in three navs and the "
            f"catalogue table; a module outside it appears in the nav under whichever heading "
            f"happens to precede it.")

    # D2 — a block is a contiguous run. An interleaved block renders one heading twice, and the
    # second copy silently reparents every module under it.
    runs = [b for b, _ in itertools.groupby(m.get("block") for m in mods if m.get("block"))]
    dupes = [b for b in set(runs) if runs.count(b) > 1]
    if dupes:
        problems.append(
            f"block(s) {', '.join(sorted(dupes))} appear in more than one run through modules.yaml "
            f"(order seen: {' -> '.join(runs)}). A block must be one unbroken span of positions, or "
            f"its heading is emitted twice and every module after the second copy is reparented.")

    # D3 — every module owns exactly one catalogue row, under ITS OWN ifndef. This is the
    # 2026-08-22 defect: a row nested in a neighbour's wrapper disappears when the NEIGHBOUR is
    # disabled, and renders perfectly whenever both are enabled.
    index = read(root, "content/modules/ROOT/pages/index.adoc")
    if index:
        wrapped = re.findall(
            r'^ifndef::module-([a-z0-9-]+)-hidden\[\]\n(.*?)^endif::module-\1-hidden\[\]$',
            index, re.M | re.S)
        owner = {slug: body for slug, body in wrapped}
        for m in mods:
            slug = m.get("slug")
            if slug not in owner:
                problems.append(
                    f"{slug} has no ifndef::module-{slug}-hidden[] block of its own in "
                    f"index.adoc. Either it is missing from the catalogue table, or its row sits "
                    f"inside a NEIGHBOUR's wrapper — in which case disabling that neighbour "
                    f"silently removes this module from the table, and nothing renders differently "
                    f"while both are enabled.")
            else:
                n_rows = len(re.findall(r'^\| ', owner[slug], re.M))
                if n_rows != 1:
                    problems.append(
                        f"{slug}'s ifndef block in index.adoc holds {n_rows} table row(s), not "
                        f"exactly 1. A second row inside this wrapper belongs to another module and "
                        f"disappears whenever THIS one is disabled.")

    # D4 — the nav section headings must be exactly the blocks, in order. A dropped heading passes
    # check-module-order.sh, which asserts module order and knows nothing about sections.
    expected = runs
    for nav in NAVS:
        text = read(root, f"content/modules/ROOT/partials/{nav}")
        if not text:
            continue
        seen = re.findall(r'^\.([A-D] — .+)$', text, re.M)
        if seen != expected:
            problems.append(
                f"{nav} section headings are {seen or '[none]'} but modules.yaml declares "
                f"{expected}. A heading dropped here still passes check-module-order.sh — that "
                f"guard asserts module ORDER, and a missing heading is not a module.")

    # D6 — README's own module table is a FIFTH rendering of the catalogue, alongside the three
    # navs and index.adoc. On 2026-08-23 a rotation swept four of the five and left this one
    # naming `B | M07 | Pipelines Fundamentals` after pipelines had become M09 — 20 of its 26 rows
    # wrong, and every other guard green. Asserted on the (block letter, number) SEQUENCE rather
    # than on titles: README deliberately carries richer titles than the SSOT ("… (Vibe Coding,
    # Safely)"), and policing those would force good copy to be flattened for a machine.
    readme = read(root, "README.md")
    if readme:
        seen_rows = [(m.group(1), int(m.group(2)))
                     for m in re.finditer(r'^\| ([A-D]) \| M(\d\d) \| ', readme, re.M)]
        if seen_rows:
            want_rows = [(m["block"][0], i + 1) for i, m in enumerate(mods) if m.get("block")]
            if seen_rows != want_rows:
                first = next((k for k, (a, b) in enumerate(zip(seen_rows, want_rows)) if a != b),
                             min(len(seen_rows), len(want_rows)))
                shown = seen_rows[first] if first < len(seen_rows) else "<no row>"
                expect = want_rows[first] if first < len(want_rows) else "<no module>"
                problems.append(
                    f"README.md's module table has {len(seen_rows)} row(s) against {len(want_rows)} "
                    f"module(s), and first diverges at row {first + 1}: the table says "
                    f"{shown}, the catalogue says {expect}. That table is a fifth rendering of "
                    f"modules.yaml — a renumber that sweeps the navs and index.adoc and forgets it "
                    f"leaves every other guard green.")

    # D5 — prose that counts the catalogue must count it correctly.
    for rel in ("README.md",):
        text = read(root, rel)
        for stated in {int(x) for x in COUNT_PROSE.findall(text)}:
            if stated != len(mods):
                problems.append(
                    f"{rel} says '{stated} modules' but modules.yaml holds {len(mods)}. This is the "
                    f"2026-08-22 defect verbatim: a module was added and the prose was not.")

    # SCOPE. Every check above is a comparison; if modules.yaml resolves empty the comparisons are
    # vacuous and this guard reports clean over a tree it never read.
    if len(mods) < MIN_MODULES:
        problems.append(
            f"[scope] modules.yaml under {root} yielded {len(mods)} module(s), below the floor of "
            f"{MIN_MODULES}. A guard that inspects nothing reports clean, which is "
            f"indistinguishable from a guard that inspected everything.")

    if problems:
        print(f"::error::module-block-guard: {len(problems)} problem(s).", file=sys.stderr)
        for p in problems:
            print(f"  ❌ {p}", file=sys.stderr)
        return 1

    print(f"✅ module-block-guard: {len(mods)} module(s) in {len(runs)} contiguous block(s) "
          f"({', '.join(runs)}); every module owns exactly one catalogue row under its own ifndef; "
          f"every nav's section headings match the SSOT; prose counts agree. This does NOT judge "
          f"whether a module is in the RIGHT block — that is a teaching decision.")
    return 0


def _drive(argv: list[str]) -> tuple[int, str]:
    """Run the REAL main() and capture everything it printed."""
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        rc = main(argv)
    return rc, sink.getvalue()


# (fixture, expected rc, a phrase only THIS detector prints). One fixture per detector, each
# tripping exactly ONE — a fixture tripping two would leave both readable as proven while either
# could silently stop working.
CASES = [
    ("control-good", 0, None),
    ("canary-no-block", 1, "declare no `block:`"),
    ("canary-interleaved", 1, "more than one run"),
    ("canary-missing-row", 1, "has no ifndef::module-"),
    ("canary-double-row", 1, "table row(s), not"),
    ("canary-dropped-heading", 1, "section headings are"),
    ("canary-stale-count", 1, "but modules.yaml holds"),
    ("canary-table-drift", 1, "first diverges at row"),
    ("canary-empty", 1, "[scope]"),
]


def self_test() -> int:
    """Drive the real entry point over the fixtures. Exit 1 = every detector fired on exactly its
    own fixture and the control stayed silent. Exit 2 = any of that is false. Never 0.
    """
    problems: list[str] = []
    if not CANARY_DIR.is_dir():
        print(f"❌ SELF-TEST FAILED: fixture directory {CANARY_DIR} is missing — there is nothing "
              f"to detect, so nothing this function prints would mean anything.", file=sys.stderr)
        return 2

    for name, want_rc, want in CASES:
        d = CANARY_DIR / name
        if not d.is_dir():
            problems.append(f"[fixture] {name}: missing — a case that does not exist cannot witness "
                            f"anything, and its detector silently reads as proven.")
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

    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2

    print(f"✅ self-test ok — {len(CASES)} fixture(s) driven through the real main(): an undeclared "
          f"block, an interleaved block, a catalogue row nested in a neighbour's wrapper, a dropped "
          f"nav heading, a stale prose count and an empty tree each caught on exactly their own "
          f"fixture; the control silent.")
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    return 1


if __name__ == "__main__":
    sys.exit(main())
