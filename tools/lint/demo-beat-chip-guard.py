#!/usr/bin/env python3
"""demo-beat-chip-guard.py — a demo beat's ⏱ timing chip can vanish and NO BUILD SAYS SO.

WHY THIS EXISTS. Every beat in every demo arc is authored as block-attribute lines above a
description list:

    === Beat 2 — Default-deny breaks the API

    [demo-block]
    [TIME 3m]
    Say:: …
    Show:: …
    Do:: …

Asciidoctor's block STYLE is positional attribute 1, so of two consecutive attribute lines the
second REPLACES the first: `demo-block` never reaches the HTML, and `TIME 3m` is emitted verbatim
into the description list's wrapper class attribute, landing as three classes. The presenter's
timing chip in `content/supplemental-ui/partials/head-styles.hbs` is painted from exactly those
classes — read that file's own comment (around lines 65-139), which states the fragility, and warns
that grepping the RENDERED CLASS ATTRIBUTE self-matches the inlined stylesheet on every page, so the
honest grep is for the opening `<div` tag. This guard follows that rule.

The consequence is that `[TIME Nm]` is a load-bearing hook whose failure is INVISIBLE. Measured
2026-08-08 with a real transposition: `npx antora --log-failure-level=warn` returns rc 0 with a
zero-line log while the chip is gone from the page. Nothing else in this repo can see it — a build
cannot fail on HTML it considers perfectly valid.

WHAT WAS MEASURED, AND WHY THE RULES ARE NARROWER THAN THEY LOOK. Every shape below was rendered
through `node_modules/@asciidoctor/core` 2.2.9 — the engine Antora builds this site with — and the
wrapper div's class attribute was read directly. Reasoning about the parser was NOT enough: four of
the shapes a stricter guard would have flagged turn out to render the chip perfectly.

    CHIP SURVIVES                                      CHIP LOST
    heading / blank / demo-block / TIME / Say  (ref)   a section heading between TIME and the list
    a blank line between TIME and the list             a style attribute line AFTER TIME
    a `//` comment line between them                   the run attaching to a source block
    a block title (`.Title`) between them              the run attaching to a paragraph
    a conditional (`endif::demo[]`) between them       the run attaching to an admonition
    a ROLE line (`[.lead]`) after TIME                  (a heading with no list after it at all)
    no `[demo-block]` line at all
    two `[TIME]` lines — the last one wins
    a value with no rule (`90s`) — bare glyph, no number

So this guard does NOT require adjacency, does NOT require `[demo-block]` (the stylesheet's comment
says plainly that the line is inert and may be deleted), and does not treat a role line as a style
line. A guard that fired on those would be flagging correct pages, and a guard that cries wolf gets
switched off, taking the one detector that matters with it.

WHAT IT ASSERTS.

  [1] HEADING INTERPOSED. A section heading between a `[TIME Nm]` line and the description list it
      is meant to style. This is the defect a sweep introduces by inserting `=== Beat N — label`
      headings in the wrong place, and it is reported ON THE HEADING because the heading is the line
      to move.
  [2] STYLE AFTER TIME. Another positional-style attribute line — `[demo-block]`, `[NOTE]`,
      `[source,sh]` — between `[TIME Nm]` and its block. It takes positional 1 and the chip dies.
      The stylesheet's comment warns about exactly this reordering.
  [3] CHIP ON A NON-LIST. The attribute run attaches to something that is not a description list.
      The classes land on a wrapper no rule selects.
  [4] BEAT WITHOUT A CHIP. A `=== Beat …` heading with no working chip site under it. This is
      chip conservation from the beat's side.
  [5] CHIP WITHOUT A BEAT. A chip site inside the arc that sits under no beat heading, on a page
      that uses beat headings. Conservation from the chip's side. [4] and [5] together are the
      per-module equality "beats == chips", split so each has a witness of its own.
  [6] CHIP OUTSIDE THE ARC. A `[TIME Nm]` outside `ifdef::demo[]` would paint a presenter's chip
      into the workshop and instructor renderings. Ground truth 2026-08-08, read from the opening
      div tags of a built site: demo 104, workshop 0, instructor 0.
  [7] UNPAINTED VALUE. A value the stylesheet enumerates no rule for. The chip still renders — as a
      bare glyph with no number — which is the failure mode that file deliberately prefers, but the
      pacing is still lost and the fix is one line there.

  [8] BUILT-OUTPUT CONSERVATION, OPT-IN (`--built-demo DIR`, `--built-non-demo DIR`). Counts the
      rendered chip elements per page by their opening `<div` tag and requires the count to equal
      the working chip sites this guard found in the source, and requires ZERO in a non-demo build.
      Not wired into CI: every job in lint.yml is checkout-plus-a-script, and a gate that needs a
      site build is a gate that gets skipped.

WHAT IT DOES NOT COVER — stated plainly, because a source-only check must not read as complete.

  * It cannot see the RENDERED page unless you hand it a build. Detectors [1]-[7] reason about
    authored source against measured Asciidoctor behaviour; they cannot catch a chip lost to
    something outside that model — a stylesheet edit that drops a rule, an Antora extension that
    rewrites classes, a theme whose CSS wins the cascade. `--built-demo` closes exactly that gap and
    is the only mode that proves what a presenter will actually see.
  * It does not model a multi-line `////` comment block between the attribute and its list. That
    shape does not occur in this tree; if it appears, the guard reports it as [3].
  * It does not judge whether a beat's timing VALUE is honest — whether `3m` is what the beat takes
    is a rehearsal question, not a lint one — nor whether the arc's beats sum to the stated arc
    length in the section title.
  * It does not require beat headings to exist. A demo arc with no `=== Beat …` headings is not a
    finding: detectors [4] and [5] switch off for that page. That is deliberate — a sweep adding
    headings across the catalogue must not redden every module it has not reached yet.
  * It says nothing about `Say::`/`Show::`/`Do::` content, ordering or completeness.

Exit codes:
  0  contract holds
  1  contract broken — or, under --self-test, every canary was correctly detected
  2  the guard could not inspect what it claims to inspect (no files, collapsed scope, bad fixture)

USAGE
    tools/lint/demo-beat-chip-guard.py
    tools/lint/demo-beat-chip-guard.py --self-test          # must exit exactly 1
    tools/lint/demo-beat-chip-guard.py --built-demo www/demo \
        --built-non-demo www/workshop --built-non-demo www/instructor
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import crashes
    with Python's default rc 1 — which is exactly what CI's `--self-test must exit EXACTLY 1`
    assertion reads as "the canary fired". `os._exit` is what makes the remap stick: an excepthook
    cannot change the exit status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::demo-beat-chip-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from _scope import Scope, fixture_line_expectations  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad
    # NOT `except ImportError`. A _scope.py that fails to PARSE raises SyntaxError, sails past an
    # ImportError-only handler and exits 1 — CI's "the canary fired". Anything going wrong while
    # loading the scope ledger means this guard cannot start, and that is rc 2 whichever exception
    # said so.
    print(f"::error::demo-beat-chip-guard: cannot import _scope ({exc}) — the guard could not "
          f"start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    Every pattern here compiles at MODULE level, before main() — and before any try/except inside
    it — can run. Python exits 1 on an uncaught exception, and 1 is what CI accepts as "the canary
    was detected", so a one-character regex typo would report this guard's detection as PROVEN while
    it could not even load.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::demo-beat-chip-guard: {name} is not a valid regex ({exc}) — the guard "
              f"could not load. Exiting 2: that is 'the guard is broken', not 'the canary fired'.",
              file=sys.stderr)
        sys.exit(2)


REPO = Path(__file__).resolve().parents[2]

# ── The line grammar ───────────────────────────────────────────────────────────────────────────
# Every one of these is read by the real run, and blinding any of them changes what the canary
# fixture reports — which is the point: a grammar rule that can stop matching with no CI signal is
# the same hole as a detector that can stop firing.

# A section heading. Level is the number of `=`; the title is what follows.
HEADING = _compile("HEADING", r"^(=+)\s+(\S.*?)\s*$")
# The beat headings a demo sweep inserts. Matched on the TITLE, not the whole line, so the heading
# level is free — `=== Beat 2 — …` today, and a re-levelled arc tomorrow.
BEAT_TITLE = _compile("BEAT_TITLE", r"^Beat\b")
# Any block-attribute line. Deliberately broad: anchors (`[[id]]`), roles (`[.lead]`) and options
# all live here, and all of them are transparent to the chip. Which of them STEALS positional 1 is
# STYLE_ATTR's job, below.
ATTR_LINE = _compile("ATTR_LINE", r"^\[.*\]\s*$")
# The chip's hook. The value is captured raw so [7] can judge it.
TIME_ATTR = _compile("TIME_ATTR", r"^\[TIME\s+([^\]]*?)\s*\]\s*$")
# An attribute line that SETS positional attribute 1 — i.e. the block style. The first segment must
# be a bare token starting with a letter: `[demo-block]`, `[NOTE]`, `[source,sh]` qualify;
# `[.lead]` (role), `[#id]`, `[%collapsible]`, `[[anchor]]` and `[cols="1,1"]` (a named attribute,
# so the `=` stops the match) do not. That distinction is not cosmetic — a role line after TIME was
# measured to leave the chip intact, so flagging it would be a false positive.
STYLE_ATTR = _compile("STYLE_ATTR", r"^\[([A-Za-z][^\],=]*?)\s*(?:,|\])")
# A description-list term. The trailing whitespace-or-end is what separates `Say:: …` from
# `include::x[]`, `image::y[]` and `ifdef::demo[]`, none of which are lists.
DLIST_TERM = _compile("DLIST_TERM", r"^\s*\S.*?::(\s|$)")
# A conditional region opener. EMPTY brackets only: `ifndef::demo-body[…]` is a one-line default and
# opens no region.
COND_OPEN = _compile("COND_OPEN", r"^if(n?)def::([^\[\]]+)\[\]\s*$")
COND_CLOSE = _compile("COND_CLOSE", r"^endif::([^\[\]]*)\[\]\s*$")
# Transparent to the attribute/block association — all three measured, not assumed.
COMMENT = _compile("COMMENT", r"^//")
BLOCK_TITLE = _compile("BLOCK_TITLE", r"^\.\S")
# The values head-styles.hbs enumerates a `content:` rule for. Outside this set the chip renders a
# bare glyph and the number is lost; the fix is one line in that file.
PAINTED_VALUE = _compile("PAINTED_VALUE", r"^([1-9]|1[0-5])m$")

# The rendered chip element, matched on its OPENING DIV TAG. head-styles.hbs is inlined into every
# page of every flavour, so a pattern written against the class attribute alone self-matches that
# stylesheet and reports phantom hits — its own comment records two drafts that did, 131 per page.
BUILT_CHIP_DIV = _compile("BUILT_CHIP_DIV",
                          r'<div[^>]*\bclass="[^"]*\bdlist\b[^"]*\bTIME\b[^"]*"')

# ── Scope floors ───────────────────────────────────────────────────────────────────────────────
# Literals, not derived from the scan: the point of a floor is that the code being proven cannot
# shrink it. Each sits below today's measurement (2026-08-08: 141 pages, 60 demo regions, 104 chip
# sites) and far above what any plausible truncation produces.
MIN_PAGES = 60
MIN_DEMO_REGIONS = 20
MIN_CHIP_SITES = 60

# Finding kinds, in report order. The text after the code is the fix, not a restatement of the
# complaint: a guard that names a defect without naming its repair gets read once and ignored.
KINDS = {
    "heading-interposed":
        "Move the heading ABOVE the attribute lines. A heading between `[TIME Nm]` and its list "
        "consumes the attributes into the section, and the chip is gone with no build warning — "
        "the reference shape is in content/modules/ROOT/pages/networking-dev-devops/lab.adoc "
        "(commit 17d74b2).",
    "style-after-time":
        "`[TIME Nm]` must be the LAST style attribute before the list. Whatever sets positional 1 "
        "last wins, and only `TIME` is a hook the stylesheet paints.",
    "chip-on-non-list":
        "Attach the run to the `Say::`/`Show::`/`Do::` list. The chip is painted by a rule on the "
        "description-list wrapper; on any other block the classes land where nothing selects them.",
    "beat-without-chip":
        "Give the beat a `[TIME Nm]` line directly above its `Say::` list, or drop the beat "
        "heading. A beat with no chip leaves the presenter with no pacing for that segment.",
    "chip-without-beat":
        "Add the `=== Beat N — …` heading this chip belongs under, or fold the segment into the "
        "beat above it. On a page that uses beat headings, an unheaded chip is a beat the sweep "
        "missed.",
    "chip-outside-arc":
        "Move it inside the page's `ifdef::demo[]` region. Outside it, the chip paints in the "
        "workshop and instructor renderings, where the arc does not exist.",
    "unpainted-value":
        "Use a value the stylesheet paints, or add the one rule for it in "
        "content/supplemental-ui/partials/head-styles.hbs — it enumerates the painted values "
        "explicitly, and outside that set the chip shows a bare glyph with no number.",
    "built-count-mismatch":
        "The built page does not carry the chip elements the source calls for. Rebuild and re-run; "
        "if it persists, the loss is downstream of the source and this guard's source-only "
        "detectors cannot see it.",
    "built-chip-in-non-demo":
        "A chip element reached a non-demo rendering. Every `[TIME Nm]` must live inside "
        "`ifdef::demo[]`.",
}


def tracked_adocs():
    """Every tracked .adoc, minus other guards' fixtures — and this guard's own.

    `.canary.` files are deliberately broken content; scanning them would report a fixture's
    planted defect as a real finding. This is the same exclusion attribute-interpolation-guard,
    backtick-leak-guard, module-prep-pairing-guard and no-cdn-assets-guard already apply.
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", "--", "*.adoc"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
    except Exception:  # noqa: BLE001 — no git, no scope; main() turns the empty list into rc 2
        return []
    return [REPO / f for f in out if ".canary." not in f]


def _walk_to_target(lines, start):
    """From the line AFTER a `[TIME Nm]` line, find the block its attributes will attach to.

    Returns `(kind, index, style_lines)` where kind is one of:
      "heading"     a section heading got there first — the attributes go to the SECTION
      "dlist"       a description-list term — the chip renders
      "superseded"  another `[TIME]` line takes over; this site emits nothing and the later one is
                    judged on its own (measured: two TIME lines in a run, the last one wins)
      "other"       anything else — a delimiter, prose, an include; the classes land nowhere useful
      "eof"         the file ended
    `style_lines` are 1-based line numbers of style attributes seen after the TIME line, each of
    which steals positional 1.

    Blank lines, `//` comments, block titles and conditional lines are TRANSPARENT here because
    they were measured to be — every one of them still renders the chip.
    """
    style_lines = []
    i = start
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or COMMENT.match(line) or BLOCK_TITLE.match(line) \
                or COND_OPEN.match(line) or COND_CLOSE.match(line):
            i += 1
            continue
        if ATTR_LINE.match(line):
            if TIME_ATTR.match(line):
                return "superseded", i, style_lines
            if STYLE_ATTR.match(line):
                style_lines.append(i + 1)
            i += 1
            continue
        if HEADING.match(line):
            return "heading", i, style_lines
        if DLIST_TERM.match(line):
            return "dlist", i, style_lines
        return "other", i, style_lines
    return "eof", len(lines), style_lines


def scan_page(rel, lines):
    """Every finding on one page, plus what was measured, plus its working chip sites.

    Returns `(findings, counters, working_sites)`. `findings` are `(rel, lineno, kind, detail)`.
    `working_sites` is the number of chip sites that will actually render, which is what the
    built-output comparison in check_built() is measured against.
    """
    findings = []
    counters = {"pages": 1, "demo regions": 0, "chip sites": 0}

    # Pass 1 — where the demo arc is. A stack, because `ifdef::demo[]` and `ifndef::demo[]` both
    # close with `endif::demo[]` and this tree uses the pair to split demo from non-demo content on
    # the same page.
    in_demo = [False] * len(lines)
    stack: list[tuple[str, bool]] = []
    for i, line in enumerate(lines):
        opened = COND_OPEN.match(line)
        if opened:
            names = [n.strip() for n in re.split(r"[,+]", opened.group(2))]
            stack.append((opened.group(2).strip(), bool(opened.group(1))))
            if "demo" in names and not opened.group(1):
                counters["demo regions"] += 1
        closed = COND_CLOSE.match(line)
        if closed and stack:
            want = closed.group(1).strip()
            while stack:
                name, _neg = stack.pop()
                if not want or name == want:
                    break
        positive = any("demo" in re.split(r"[,+]", n) and not neg for n, neg in stack)
        negative = any("demo" in re.split(r"[,+]", n) and neg for n, neg in stack)
        in_demo[i] = positive and not negative

    # Pass 2 — the beat headings, and the line range each one owns. A beat body runs to the next
    # heading of the same or higher level, or to the end of the page.
    beats = []  # (lineno, title, start_index, end_index)
    heads = [(i, len(m.group(1)), m.group(2))
             for i, line in enumerate(lines) if (m := HEADING.match(line))]
    for pos, (idx, level, title) in enumerate(heads):
        if not BEAT_TITLE.match(title) or not in_demo[idx]:
            continue
        end = len(lines)
        for nidx, nlevel, _ in heads[pos + 1:]:
            if nlevel <= level:
                end = nidx
                break
        beats.append((idx + 1, title, idx + 1, end))
    page_uses_beats = bool(beats)

    # Pass 3 — every chip site.
    working: set[int] = set()
    for i, line in enumerate(lines):
        timed = TIME_ATTR.match(line)
        if not timed:
            continue
        counters["chip sites"] += 1
        lineno = i + 1
        value = timed.group(1)

        if not in_demo[i]:
            findings.append((rel, lineno, "chip-outside-arc",
                             f"[TIME {value}] sits outside ifdef::demo[]"))
            continue

        if not PAINTED_VALUE.match(value):
            findings.append((rel, lineno, "unpainted-value",
                             f"the stylesheet paints no rule for {value!r}"))

        kind, at, style_lines = _walk_to_target(lines, i + 1)
        for sline in style_lines:
            findings.append((rel, lineno, "style-after-time",
                             f"{lines[sline - 1].strip()} on line {sline} takes positional 1 "
                             f"after [TIME {value}]"))
        if kind == "heading":
            findings.append((rel, at + 1, "heading-interposed",
                             f"this heading sits between [TIME {value}] on line {lineno} and the "
                             f"list it must style"))
        elif kind == "other":
            findings.append((rel, lineno, "chip-on-non-list",
                             f"[TIME {value}] attaches to {lines[at].strip()[:48]!r} on line "
                             f"{at + 1}, which is not a description list"))
        elif kind == "eof":
            findings.append((rel, lineno, "chip-on-non-list",
                             f"[TIME {value}] has no block after it at all"))
        elif kind == "dlist" and not style_lines:
            working.add(lineno)

        if kind != "superseded" and page_uses_beats \
                and not any(start < i < end for _ln, _t, start, end in beats):
            findings.append((rel, lineno, "chip-without-beat",
                             f"[TIME {value}] is under no === Beat heading, on a page that uses "
                             f"them"))

    # Pass 4 — conservation from the beat's side.
    for lineno, title, start, end in beats:
        if not any(start < ln - 1 < end for ln in working):
            findings.append((rel, lineno, "beat-without-chip",
                             f"{title!r} has no working [TIME Nm] site under it"))

    return findings, counters, len(working)


def scan(paths, floors=(MIN_PAGES, MIN_DEMO_REGIONS, MIN_CHIP_SITES)):
    """(findings, per-page working-site counts, scope-collapse rc)."""
    findings = []
    per_page = {}
    scope = Scope("demo-beat-chip-guard")
    scope.require("pages", floors[0],
                  "every tracked .adoc is read; a smaller number means file discovery broke, not "
                  "that pages were deleted")
    scope.require("demo regions", floors[1],
                  "the arcs live inside ifdef::demo[]; finding few of them means the conditional "
                  "tracker stopped matching, and every chip would then read as outside the arc")
    scope.require("chip sites", floors[2],
                  "the [TIME Nm] lines are what this guard exists to check; reading few of them is "
                  "an unread tree, not a clean one")
    for path in paths:
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        rel = str(path.relative_to(REPO)) if str(path).startswith(str(REPO)) else str(path)
        page_findings, counters, working = scan_page(rel, text.splitlines())
        findings.extend(page_findings)
        per_page[rel] = working
        scope.merge(counters)
    return findings, per_page, scope.enforce(), scope.summary()


def check_built(demo_dirs, non_demo_dirs, per_page):
    """Compare the RENDERED chip elements against the source. Opt-in; needs a built site.

    Returns `(findings, pages_compared)`. The mapping from a built page back to its source is the
    last two path components — Antora writes `<out>/modules/<slug>/lab.html` from
    `content/modules/ROOT/pages/<slug>/lab.adoc` — which is exact and survives a changed output
    root. Built pages with no source counterpart, and source pages with no built counterpart, are
    skipped rather than guessed at: a disabled module is not a defect.
    """
    findings = []
    compared = 0
    by_key = {}
    for rel, working in per_page.items():
        parts = Path(rel).parts
        if len(parts) >= 2:
            by_key[f"{parts[-2]}/{Path(parts[-1]).stem}"] = (rel, working)

    for root in demo_dirs:
        for html in sorted(Path(root).rglob("*.html")):
            key = f"{html.parent.name}/{html.stem}"
            if key not in by_key:
                continue
            rel, working = by_key[key]
            rendered = len(BUILT_CHIP_DIV.findall(html.read_text(errors="replace")))
            compared += 1
            if rendered != working:
                findings.append((rel, 0, "built-count-mismatch",
                                 f"{html} renders {rendered} chip element(s); the source has "
                                 f"{working} working chip site(s)"))

    for root in non_demo_dirs:
        for html in sorted(Path(root).rglob("*.html")):
            rendered = len(BUILT_CHIP_DIV.findall(html.read_text(errors="replace")))
            compared += 1
            if rendered:
                findings.append((str(html), 0, "built-chip-in-non-demo",
                                 f"{rendered} chip element(s) in a non-demo rendering"))

    return findings, compared


def report(findings, per_page, summary, built_note="") -> int:
    if not findings:
        chips = sum(per_page.values())
        print(f"✅ demo-beat-chip: {chips} working chip site(s) across {summary}. Every beat "
              f"heading has a chip, every chip has a beat, and no attribute line takes positional "
              f"1 after [TIME Nm].{built_note}")
        return 0

    order = list(KINDS)
    for kind in order:
        hits = [f for f in findings if f[2] == kind]
        if not hits:
            continue
        print(f"❌ {kind}: {len(hits)} site(s)")
        for rel, lineno, _kind, detail in hits[:20]:
            where = f"{rel}:{lineno}" if lineno else rel
            print(f"   {where}  {detail}")
        if len(hits) > 20:
            print(f"   … and {len(hits) - 20} more")
        print(f"   FIX: {KINDS[kind]}")
    print(f"\n{len(findings)} demo-beat chip defect(s). None of these fails a build: "
          f"`npx antora --log-failure-level=warn` returns rc 0 with a zero-line log while the chip "
          f"is missing from the page (measured 2026-08-08).")
    return 1


CANARY = Path(__file__).resolve().parent / "demo-beat-chip-guard.canary.adoc"

# A built page carrying two chip elements, written the way Asciidoctor writes them. The stylesheet
# text is included on purpose: head-styles.hbs is inlined into every built page, so a fixture
# without it would not exercise the one thing BUILT_CHIP_DIV is shaped to avoid — matching the
# stylesheet instead of the content.
BUILT_PAGE = """<html><head><style>
.doc .dlist.TIME { border-top: 2px solid #c9190b; }
.doc .dlist.TIME.\\33 m::before { content: "3m"; }
</style></head><body>
<div class="sect2"><h3>Beat 1</h3>
<div class="dlist TIME 2m"><dl><dt>Say</dt><dd>one</dd></dl></div>
<div class="dlist TIME 3m"><dl><dt>Say</dt><dd>two</dd></dl></div>
<div class="dlist"><dl><dt>Plain</dt><dd>no chip</dd></dl></div>
</div></body></html>
"""


def self_test(tmpdir: Path) -> int:
    """Prove every detector fires on a line only IT fires on, and stays silent on the correct forms.

    The fixture declares its expectations PER LINE rather than as a total. A total is satisfied by
    the wrong detector firing the right number of times, which is how a canary comes to certify
    coverage it does not have.
    """
    ok = True

    if not CANARY.is_file():
        print(f"❌ SELF-TEST FAILED: the canary fixture {CANARY} is missing — there is nothing to "
              f"prove the detectors with.", file=sys.stderr)
        return 2

    lines = CANARY.read_text(encoding="utf-8").splitlines()
    findings, counters, working = scan_page(CANARY.name, lines)

    for failure in fixture_line_expectations(CANARY, [f[1] for f in findings]):
        print(f"❌ SELF-TEST FAILED: {failure}", file=sys.stderr)
        ok = False

    # Per-line expectations prove WHICH lines fire, not which detector fired on them. Assert the
    # kinds too, so a detector cannot be quietly replaced by another that happens to fire on the
    # same line — the substitution the shared helper alone cannot see.
    kinds = {f[2] for f in findings}
    expected_kinds = {"heading-interposed", "style-after-time", "chip-on-non-list",
                      "beat-without-chip", "chip-without-beat", "chip-outside-arc",
                      "unpainted-value"}
    for missing in sorted(expected_kinds - kinds):
        print(f"❌ SELF-TEST FAILED: no {missing} finding on the canary — that detector is blind, "
              f"and the fixture case written for it proves nothing.", file=sys.stderr)
        ok = False
    for extra in sorted(kinds - expected_kinds):
        print(f"❌ SELF-TEST FAILED: unexpected {extra} finding on the canary — a detector is "
              f"firing on a shape the fixture declares correct.", file=sys.stderr)
        ok = False

    # The NEGATIVE arm, standalone. Without it, a guard that flagged everything would satisfy every
    # assertion above and distinguish nothing. This is the committed reference shape from
    # networking-dev-devops/lab.adoc, plus the four variations measured to still paint the chip.
    clean = [
        "ifdef::demo[]",
        "== Demo arc",
        "",
        "=== Beat 1 — reference",
        "",
        "[demo-block]",
        "[TIME 2m]",
        "Say:: one",
        "Show:: two",
        "",
        "=== Beat 2 — tolerated variations",
        "",
        "[TIME 3m]",
        "",
        "// a comment",
        "[.lead]",
        ".A title",
        "Say:: one",
        "",
        "endif::demo[]",
    ]
    clean_findings, _c, clean_working = scan_page("clean.adoc", clean)
    if clean_findings:
        print(f"❌ SELF-TEST FAILED: the CORRECT fixture was flagged ({clean_findings}). A guard "
              f"that fires on the reference shape will be switched off by the first person it "
              f"annoys, taking the one detector that matters with it.", file=sys.stderr)
        ok = False
    if clean_working != 2:
        print(f"❌ SELF-TEST FAILED: the correct fixture has 2 chip sites and the guard counted "
              f"{clean_working} — the working-site count feeds the built-output comparison, so a "
              f"wrong count there is a wrong verdict here.", file=sys.stderr)
        ok = False

    # A chip site with NOTHING after it — the end-of-file arm of the non-list detector. It needs
    # its own fixture because the canary cannot host it: whatever follows a `[TIME]` line in that
    # file, transparent or not, stops the site being at the end. Left unwitnessed, this arm was one
    # of two detectors _canary-coverage reported blindable when the guard was first swept.
    eof_case = ["ifdef::demo[]", "== Demo arc", "", "[TIME 3m]"]
    eof_findings, _c, _w = scan_page("eof.adoc", eof_case)
    if [f for f in eof_findings if f[2] == "chip-on-non-list"] == []:
        print("❌ SELF-TEST FAILED: a [TIME Nm] line with no block after it at all was not flagged "
              "— a truncated demo arc would ship a chip attached to nothing.", file=sys.stderr)
        ok = False

    # THE DRIVER, not just the detectors. scan() is what the real run calls; every assertion above
    # reaches scan_page() directly, so nothing here proved the driver still collects what the page
    # scanner finds. Deleting that one line left both modes on their baseline — the guard would
    # report a clean tree while every page's findings were dropped on the floor.
    driven, driven_pages, driven_rc, _summary = scan([CANARY], floors=(1, 1, 1))
    if not driven or driven_rc != 0:
        print(f"❌ SELF-TEST FAILED: scan() over the canary returned {len(driven)} finding(s) at "
              f"rc {driven_rc} — the driver is not carrying page findings up, so the real run "
              f"would report clean over a broken tree.", file=sys.stderr)
        ok = False
    if driven_pages.get(str(CANARY.relative_to(REPO))) != 8:
        print(f"❌ SELF-TEST FAILED: scan() reported {driven_pages} working sites for the canary; "
              f"the per-page counts are what the built-output comparison is measured against.",
              file=sys.stderr)
        ok = False
    if scan([CANARY], floors=(MIN_PAGES, MIN_DEMO_REGIONS, MIN_CHIP_SITES))[2] != 2:
        print(f"❌ SELF-TEST FAILED: scanning ONE page did not collapse the scope floors "
              f"({MIN_PAGES}/{MIN_DEMO_REGIONS}/{MIN_CHIP_SITES}) — file discovery could shrink to "
              f"a single page and still report clean.", file=sys.stderr)
        ok = False

    # Scope: a floor of zero asserts nothing, so the canary's own counts are checked against real
    # positives rather than against an empty page.
    # Measured, not guessed: 12 `[TIME]` lines in the fixture, of which three are broken by design
    # (heading interposed, style after, non-list target) and one sits outside the arc. The
    # remaining eight include the unpainted `90s` site, which DOES render — a value with no rule
    # loses its number, not its element, and the built comparison counts it.
    if counters["chip sites"] != 12 or counters["demo regions"] != 1:
        print(f"❌ SELF-TEST FAILED: the canary measured {counters} — the fixture carries one demo "
              f"region and 12 chip sites, so the parse of it has drifted.", file=sys.stderr)
        ok = False
    if working != 8:
        print(f"❌ SELF-TEST FAILED: the canary has 8 working chip sites and the guard counted "
              f"{working}. The count feeds the built-output comparison, so a wrong count here is a "
              f"wrong verdict there.", file=sys.stderr)
        ok = False

    # The built-output half. Fixtures rather than a real build, so the assertion runs everywhere:
    # a gate that needs a site build is a gate that gets skipped.
    demo_root = tmpdir / "demo" / "modules" / "canary-slug"
    demo_root.mkdir(parents=True)
    (demo_root / "lab.html").write_text(BUILT_PAGE)
    matching = {"content/modules/ROOT/pages/canary-slug/lab.adoc": 2}
    built, compared = check_built([tmpdir / "demo"], [], matching)
    if built or compared != 1:
        print(f"❌ SELF-TEST FAILED: a built page whose chip count MATCHES the source was flagged "
              f"({built}, compared={compared}) — the built comparison cries wolf, and it also "
              f"proves the opening-div pattern is not matching the inlined stylesheet.",
              file=sys.stderr)
        ok = False
    mismatched = {"content/modules/ROOT/pages/canary-slug/lab.adoc": 3}
    built, _ = check_built([tmpdir / "demo"], [], mismatched)
    if [f for f in built if f[2] == "built-count-mismatch"] == []:
        print("❌ SELF-TEST FAILED: a built page rendering FEWER chips than the source declares was "
              "not flagged — the only detector that can see a chip lost downstream of the source "
              "is blind.", file=sys.stderr)
        ok = False
    non_demo = tmpdir / "workshop" / "modules" / "canary-slug"
    non_demo.mkdir(parents=True)
    (non_demo / "lab.html").write_text(BUILT_PAGE)
    built, _ = check_built([], [tmpdir / "workshop"], matching)
    if [f for f in built if f[2] == "built-chip-in-non-demo"] == []:
        print("❌ SELF-TEST FAILED: chip elements in a NON-demo rendering were not flagged — a "
              "presenter's pacing would ship to every attendee's page.", file=sys.stderr)
        ok = False
    (non_demo / "lab.html").write_text("<html><body><div class=\"dlist\"></div></body></html>")
    built, _ = check_built([], [tmpdir / "workshop"], matching)
    if built:
        print(f"❌ SELF-TEST FAILED: a clean non-demo page was flagged ({built}) — the non-demo "
              f"check fires on any description list, not on chips.", file=sys.stderr)
        ok = False

    # The guard must be able to SEE the real tree, or its clean verdict means nothing.
    real = tracked_adocs()
    if not real:
        print("❌ SELF-TEST FAILED: no tracked .adoc files found — the guard would pass by scanning "
              "nothing.", file=sys.stderr)
        ok = False
    if any(".canary." in str(p) for p in real):
        print("❌ SELF-TEST FAILED: a .canary. fixture is inside the real scan set — this guard "
              "would report its own planted defects, and another guard's, as findings in the tree.",
              file=sys.stderr)
        ok = False

    for failure in Scope.self_check():
        print(f"❌ SELF-TEST FAILED: {failure}", file=sys.stderr)
        ok = False

    if not ok:
        return 2
    print(f"self-test ok — {len(findings)} finding(s) on the canary, each on a line only its own "
          f"detector fires on, and all seven source kinds present; the reference shape and the "
          f"four measured variations stay silent; the built comparison catches a short page and a "
          f"chip in a non-demo rendering while passing a matching one; {len(real)} tracked .adoc "
          f"file(s) visible to the real scan, none of them a fixture.")
    return 1


def main(argv=None) -> int:
    # argv is a PARAMETER, not read from sys.argv, because tools/lint/_canary-coverage.py drives
    # every guard by calling `mod.main(argv)` POSITIONALLY, in-process, to blind one detector at a
    # time. A zero-argument `def main()` raises TypeError there, the harness's broad handler turns
    # it into rc 2, the sweep records "unmutated control ran 2/2, not 0/1" and reports COULD NOT
    # INSPECT — and every detector in this file would ship unproven while its own CI job stayed
    # green. That happened to module-number-drift-guard on 2026-08-07; match the sibling guards.
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="run the canaries instead of the real tree; exits 1 when every canary was "
                         "correctly caught, which is the PASS for this mode")
    ap.add_argument("--built-demo", action="append", default=[], metavar="DIR",
                    help="a built DEMO site root; compares rendered chip elements against the "
                         "source (repeatable, opt-in — needs a build, so not wired into CI)")
    ap.add_argument("--built-non-demo", action="append", default=[], metavar="DIR",
                    help="a built WORKSHOP or INSTRUCTOR site root; must contain zero chip "
                         "elements (repeatable)")
    args = ap.parse_args(argv)

    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return self_test(Path(td))

    paths = tracked_adocs()
    if not paths:
        print("::error::demo-beat-chip-guard: no tracked .adoc files found — refusing to report a "
              "clean scan of nothing.", file=sys.stderr)
        return 2

    findings, per_page, collapsed, summary = scan(paths)
    if collapsed:
        return collapsed

    built_note = ""
    if args.built_demo or args.built_non_demo:
        missing = [d for d in args.built_demo + args.built_non_demo if not Path(d).is_dir()]
        if missing:
            print(f"::error::demo-beat-chip-guard: built directory(ies) not found: {missing}. "
                  f"Refusing to report a clean comparison against a build that is not there.",
                  file=sys.stderr)
            return 2
        built, compared = check_built([Path(d) for d in args.built_demo],
                                      [Path(d) for d in args.built_non_demo], per_page)
        if not compared:
            print("::error::demo-beat-chip-guard: the built directories matched ZERO pages. A "
                  "comparison of nothing is not a clean comparison — check the build root.",
                  file=sys.stderr)
            return 2
        findings.extend(built)
        built_note = f" Built comparison: {compared} page(s) matched."

    return report(findings, per_page, summary, built_note)


if __name__ == "__main__":
    # An unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::demo-beat-chip-guard: crashed ({type(exc).__name__}: {exc}). Exiting 2 — "
              f"a crash is 'the guard could not run', never 'clean' and never 'canary detected'.",
              file=sys.stderr)
        sys.exit(2)
