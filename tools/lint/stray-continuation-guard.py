#!/usr/bin/env python3
"""stray-continuation-guard.py — a lone AsciiDoc list-continuation `+` with nothing left to attach to
renders as LITERAL visible text — `<p>+</p>` — in the page an attendee, or an SA presenting to a
customer, actually reads.

ORIGIN (2026-08-14). Inside a delimited block (`--` open block, `====` example block) — or a
description-list item whose continuation chain already broke earlier on the same run — AsciiDoc
paragraphs separate with a BLANK LINE. A bare `+` alone on its own line there is the LIST-CONTINUATION
marker, and it has no list left to continue, so Asciidoctor renders it verbatim: either as a paragraph
whose entire text is `+` (nothing followed it before the next block), or — when more of the intended
sentence sits on the very next source line with no blank line between — as a paragraph that starts
`+`, a hard line break, and then the real sentence. TEN instances of exactly this shipped in the DEMO
rendering: ai-assisted-development/lab.adoc (4), developer-hub-golden-paths/lab.adoc (2),
jobs-batch-kueue/lab.adoc (4). Two sibling instances were fixed earlier the same day in
pipelines-fundamentals/lab.adoc (5cc8db5) and config-multienv/lab.adoc (258fc9e).

WHY A GUARD AND NOT A CONVENTION. `antora --log-failure-level=warn` returns rc 0 with a ZERO-LINE log
on every one of these ten — Asciidoctor considers a lone `+` perfectly valid input; it simply has
nowhere to attach, so it prints itself. Nothing about the SOURCE is malformed by any check this repo
already runs (vale, yamllint, the Antora build itself). The defect exists only in the rendered
artefact, and only in a build nobody re-reads paragraph by paragraph before a room full of customers.

WHY THIS CANNOT BE A SOURCE-SIDE CHECK — measured over three real attempts at exactly this class, not
assumed. A heuristic that flags every "lone `+` inside a delimited block" over-fires badly: one
attempt on this tree flagged 24 candidate sites, of which 18 were LEGITIMATE — a `+` inside a NESTED
LIST within the block, where it correctly attaches a block to a list item and renders fine (see
pipelines-fundamentals/lab.adoc lines 363/369/373 for the shape, deliberately left alone by 5cc8db5).
A refined heuristic that tried to exclude the nested-list shape still MISSED
developer-hub-golden-paths/lab.adoc's two real leaks entirely. The source cannot cheaply tell you
which bare `+` is doing real work: that depends on the full continuation-chain state at that exact
point, including whether an EARLIER `+` a few lines up already silently detached the list item it was
meant to extend (see WHAT THIS GUARD CANNOT SEE, below — that shape produces no visible leak at all,
so a source read of "was this `+` intended as a continuation" answers a different question than "did
it render broken"). The rendered artefact answers the actual question with certainty, in one regex,
because Asciidoctor already resolved every one of those continuation-chain questions by the time it
wrote the HTML.

WHAT IT CHECKS. Every `*.html` file under each `--built DIR` supplied on the command line, for a `<p>`
element whose text begins with a bare `+` immediately followed by either the closing `</p>` (the
marker was the paragraph's ENTIRE content) or a line break (more of the intended sentence follows on
the next rendered line — Asciidoctor preserves the source line break as a literal newline inside the
paragraph text, it does not collapse it to a space). Both shapes were observed in the same beat of the
same page three lines apart (ai-assisted-development/lab.adoc, Beat 2: a bare `<p>+</p>` before a
`[NOTE]` block, and a `<p>+\n"It could only touch…"` glued onto the following sentence). The boundary
check — immediately `</p>` or a newline, nothing else — is what keeps this from flagging genuine prose
that happens to start with a plus sign: real content like "+5% growth is expected this quarter." stays
on ONE physical source line, so Asciidoctor renders it as `<p>+5% growth…`, with `5` (not `</p>` and
not a newline) the very next character. See NEGATIVE CONTROL in the self-test for the witness.

DELIBERATELY SYMMETRIC ACROSS ALL THREE RENDERINGS, ON PURPOSE. Every one of the ten historical
instances happened to leak inside an `ifdef::demo[]` region — the demo arcs are where this project's
`--`/`====` blocks with hand-placed continuations concentrate — but the underlying AsciiDoc mechanic
is not demo-specific: a stray `+` inside any delimited block, in any of the three flavours, renders
the same broken way. This guard does not special-case demo the way this project's chip/identifier
guards correctly do (those invariants — a presenter's timing chip, a shared shell identifier — really
are asymmetric between demo and non-demo). Here the invariant is uniform: it requires ZERO occurrences
in EVERY directory handed to it via `--built`, tags each finding with the rendering it came from, and
refuses to run at all on fewer than three distinct `--built` directories — "checked in the demo
rendering only" would have caught nine of these ten and then declared victory over a class that is not
demo-specific.

WIRING. `.github/workflows/content-build.yml`, not `lint.yml`. Every job in `lint.yml` is
checkout-plus-a-script; this guard needs a built site, and content-build.yml is the one job that
already produces all three (`antora --log-failure-level=warn site-<flavor>.yml` for
workshop/demo/instructor). Building a second time just for this gate would cost minutes of every run
for output the earlier step already put on disk.

WHAT THIS GUARD CANNOT SEE, stated so a green run is not read as more than it is. A `+` whose
immediately-following block is separated from it by an interposed `//` comment can silently DETACH
from its list item without ever printing a stray `+` — the block still renders, correctly formed, just
as a document-level sibling instead of nested list content (documented at length above Beat 2 in
ai-assisted-development/lab.adoc: "Do NOT put a // comment between a `+` continuation and its block …
it ends the list item and the block silently detaches from the Do:: entry"; the same shape recurs
above Beat 3's neighbour probe on the same page). There is nothing anomalous in the finished HTML for
this — or any other HTML-reading — guard to see: a block that rendered fine, just somewhere other than
its author intended, leaves no trace once Asciidoctor is done. That is a structural authoring concern,
not a rendering leak, and is out of this guard's scope by construction. It is reported separately,
by hand, wherever this guard's fix is reported.

Exit codes:
  0  contract holds — zero stray-continuation paragraphs across every supplied rendering. ALSO
     returned, with a clearly-labelled note and NOT the "0 findings" message, when ZERO --built
     arguments were given at all — see NO ARGUMENTS AT ALL, below, for why that is not the same
     claim as "verified clean" and is not a loophole in the missing-build guarantee.
  1  contract broken — or, under --self-test, every canary was correctly detected
  2  an EXPLICITLY supplied --built directory could not be inspected: fewer than three distinct
     directories, one of them missing or not a directory, a duplicate directory, or a collapsed
     html-file scope (a supplied rendering exists but is empty or far smaller than a real build).
     This is the "a build is missing, say so, do not pass" guarantee, and it is what actually
     protects the real invocation — content-build.yml always supplies exactly three --built flags.

NO ARGUMENTS AT ALL — deliberately DIFFERENT from a --built argument that fails to resolve, and
worth stating precisely because the two look similar and must not be conflated. `tools/lint/
_canary-coverage.py` — the meta-guard that blinds every OTHER Python guard's detectors and requires
an exit code to change — calls every guard's `main([])` unconditionally as its "plain" baseline and
requires 0 (see that file's "THE CONTRACT" comment; there is no per-guard exemption from this, only
from individual DETECTOR unprovenness). Every other Python guard in this tree satisfies that by
having a real source-side default scan; this one has none, on purpose — the entire point is reading
built HTML, never .adoc source (see WHY THIS CANNOT BE A SOURCE-SIDE CHECK, above). So a bare
`main([])` answers the only honest thing it can: "you asked me to check nothing," not "2 — go build
first." That is categorically different from "you named three directories and one is not there,"
which is a real, EXPLICIT expectation this guard failed to meet — and stays rc 2. In the real CI
wiring only a broken EDIT to the workflow step could ever produce a bare, argument-less invocation;
the shipped step always names all three renderings explicitly.

USAGE
    tools/lint/stray-continuation-guard.py --self-test              # must exit exactly 1
    tools/lint/stray-continuation-guard.py \\
        --built www/workshop --built www/demo --built www/instructor
"""

from __future__ import annotations

import argparse
import html as html_mod
import re
import sys
from pathlib import Path


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import crashes
    with Python's default rc 1 — which is exactly what CI's `--self-test must exit EXACTLY 1`
    assertion reads as "the canary fired". `os._exit` is what makes the remap stick: an excepthook
    cannot change the exit status by returning. Copied verbatim from the sibling built-artefact
    guards (demo-beat-chip-guard.py, demo-region-identifier-guard.py) — same failure mode, same fix.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::stray-continuation-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad
    # NOT `except ImportError`. A _scope.py that fails to PARSE raises SyntaxError, sails past an
    # ImportError-only handler and exits 1 — CI's "the canary fired". Anything going wrong while
    # loading the scope ledger means this guard cannot start, and that is rc 2 whichever exception
    # said so.
    print(f"::error::stray-continuation-guard: cannot import _scope ({exc}) — the guard could not "
          f"start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    Both patterns below compile at MODULE level, before main() — and before any try/except inside
    it — can run. Python exits 1 on an uncaught exception, and 1 is what CI accepts as "the canary
    was detected", so a one-character regex typo would report this guard's detection as PROVEN while
    it could not even load.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::stray-continuation-guard: {name} is not a valid regex ({exc}) — the guard "
              f"could not load. Exiting 2: that is 'the guard is broken', not 'the canary fired'.",
              file=sys.stderr)
        sys.exit(2)


REPO = Path(__file__).resolve().parents[2]

# The rendered defect. `<p` (not `<p>`) so an emitted attribute — unseen on this theme today, but
# free to allow — does not defeat the match; `[^>]*` before the closing `>` covers it. The boundary
# after the literal `+` is the whole false-positive story: real prose beginning with a plus sign
# ("+5% growth is expected.") stays on ONE physical source line, so Asciidoctor emits `<p>+5% …` with
# a non-whitespace, non-`<` character immediately after the `+` — neither `</p>` nor a line break.
# Only a `+` that was alone on its OWN source line produces one of these two endings, because
# Asciidoctor preserves the source line break as a literal newline inside the paragraph text rather
# than collapsing it to a space.
LEAK_RE = _compile(
    "LEAK_RE",
    r"<p[^>]*>\+[ \t]*(?:</p>|\r?\n)")

# Strips nested markup (`<strong>`, `<code>`, …) from the text that follows a match, so the reported
# snippet reads as prose a maintainer can grep the .adoc source for — mirroring the exact reconnaissance
# method that found the ten historical instances: map the rendered FOLLOWING TEXT back to its source
# line, because the rendered text strips `*bold*`/`` `code` `` and a needle taken from HTML may not
# match the .adoc verbatim.
TAG_RE = _compile("TAG_RE", r"<[^>]+>")

CONTEXT_CHARS = 200
SNIPPET_CHARS = 120

# Declared exactly, not derived: the whole point of this guard is checking THREE renderings, so a
# floor of anything less than 3 would let "checked demo and workshop, forgot instructor" report clean.
MIN_RENDERINGS = 3
# 396 `*.html` files measured across www/{workshop,demo,instructor} on this tree (132 each,
# 2026-08-14). The floor sits comfortably below ordinary catalogue growth and far above what a single
# missing or empty rendering would leave behind (~264, two renderings' worth) — that shape is exactly
# the truncation this floor exists to catch, not a coincidence of round numbers.
MIN_HTML_FILES = 300


def _snippet_after(text: str, match: re.Match) -> str:
    """Human-readable prose following a match — tags stripped, entities unescaped, collapsed to one
    line — or "" when the marker WAS the entire paragraph.

    Which alternative LEAK_RE matched decides this, not a fixed character window. The BARE shape
    (`<p>+</p>`) consumes the closing tag itself as part of the match — there is nothing left inside
    that paragraph, and text starting right after `match.end()` belongs to the NEXT, unrelated
    element (a sibling admonition, the next paragraph…), so reporting it as if it were the leaked
    paragraph's own content would be actively misleading. The GLUED shape consumes a line break with
    the intended sentence still open, so the snippet reads up to THAT paragraph's own closing `</p>`
    — never a fixed character count, which could as easily stop mid-word or bleed past the paragraph
    into markup that has nothing to do with the leak.
    """
    if match.group(0).endswith("</p>"):
        return ""
    end = match.end()
    close = text.find("</p>", end)
    window = text[end:close] if close != -1 else text[end:end + CONTEXT_CHARS]
    return " ".join(html_mod.unescape(TAG_RE.sub(" ", window)).split())[:SNIPPET_CHARS]


def scan(dirs: list[Path], floors=(MIN_RENDERINGS, MIN_HTML_FILES), quiet: bool = False):
    """(findings, scope-collapse rc, measurement summary).

    findings: [(rendering, html_path, line_no, snippet)], one per leaked paragraph, in the order the
    directories were supplied and files were walked.

    `floors` is a parameter, not a module constant read directly, so --self-test can prove detection
    against tiny synthetic fixtures (low floors) and prove the REAL floors would collapse a truncated
    scan (the production floors, asserted separately) — the same split demo-beat-chip-guard.py and
    demo-region-identifier-guard.py use their own `floors=` parameter for, and for the same reason:
    a floor sized for a 396-file real build would reject its own three-file canary as "collapsed"
    before the detector had a chance to prove anything.
    """
    scope = Scope("stray-continuation-guard")
    scope.require("renderings", floors[0],
                  "this guard's whole purpose is comparing across the workshop, demo and instructor "
                  "renderings; fewer means a rendering was never handed to it, not that renderings "
                  "were retired")
    scope.require("html files", floors[1],
                  "every *.html file under each --built directory is read; a smaller number means a "
                  "supplied rendering is empty, half-built, or the wrong path — not that pages were "
                  "deleted")
    findings = []
    for d in dirs:
        scope.add("renderings", 1)
        html_files = sorted(d.rglob("*.html"))
        scope.add("html files", len(html_files))          # fed by the walk itself, not recomputed
        for f in html_files:
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for m in LEAK_RE.finditer(text):
                line_no = text.count("\n", 0, m.start()) + 1
                findings.append((d.name, str(f), line_no, _snippet_after(text, m)))
    return findings, scope.enforce(quiet=quiet), scope.summary()


def report(findings, summary: str) -> int:
    if not findings:
        print(f"✅ stray-continuation: 0 leaked list-continuation marker(s) across {summary}. Every "
              f"`<p>` in every supplied rendering that starts with a bare `+` either does not exist, "
              f"or is genuine prose that keeps flowing on the same line.")
        return 0

    print(f"❌ stray-continuation-marker: {len(findings)} leaked paragraph(s) — a lone AsciiDoc list "
          f"continuation with nothing to attach to, rendered as literal text:")
    for rendering, path, line_no, snippet in findings[:40]:
        tail = f"followed by: {snippet!r}" if snippet else "(the entire paragraph is just '+')"
        print(f"   [{rendering}] {path}:{line_no}  {tail}")
    if len(findings) > 40:
        print(f"   … and {len(findings) - 40} more")
    print(f"\n{len(findings)} stray continuation marker(s). None of these fails a build — "
          f"`antora --log-failure-level=warn` returns rc 0 with a zero-line log while the marker ships "
          f"as visible text (measured 2026-08-14 across ai-assisted-development, "
          f"developer-hub-golden-paths and jobs-batch-kueue before they were fixed).\n"
          f"FIX: map each finding's snippet back to its .adoc source line — watch for markup, the "
          f"rendered text strips *bold*/`code` so a needle taken from HTML may not match the source "
          f"verbatim — confirm the source line really is a lone `+`, then either delete that line "
          f"(when a plain paragraph follows; the two paragraphs merge cleanly — see "
          f"pipelines-fundamentals/lab.adoc, commit 5cc8db5) or replace it with a blank line (when a "
          f"block — [source,…], [NOTE], an image, a table — follows; see config-multienv/lab.adoc, "
          f"commit 258fc9e). Rebuild all three renderings and re-run this guard; it must return to 0 "
          f"everywhere, not just on the page you touched.")
    return 1


# ── Self-test fixtures ─────────────────────────────────────────────────────────────────────────────
# Built HTML, not .adoc — this guard reads finished artefacts only, so its canaries are pages the way
# Asciidoctor actually writes them, exactly as demo-beat-chip-guard.py's BUILT_PAGE/BUILT_GOOD/
# BUILT_BAD constants do for their own opt-in built-mode check. There is no on-disk `.canary.adoc` or
# `.canary/` fixture here because there is no source-side detector for one to exercise.

# The bare-paragraph shape: the marker WAS the entire paragraph (ai-assisted-development Beat 2, the
# `+` immediately before its `[NOTE]` block).
LEAK_BARE = """<div class="paragraph">
<p>"The write is granted."</p>
</div>
<div class="paragraph">
<p>+</p>
</div>
<div class="admonitionblock note">
<table><tr><td class="content"><p>Have the recovery ready.</p></td></tr></table>
</div>
"""

# The glued shape: the marker fused onto the front of the sentence that was meant to be its own
# paragraph (ai-assisted-development Beat 2, three lines from the bare shape above — both forms
# measured on the same page, which is why both need their own witness). Carries a real `<strong>`
# span in the trailing sentence, echoing the historical instance's own "<strong>I do not take its
# word for it</strong>" — a fixture without embedded markup here cannot witness TAG_RE at all:
# _canary-coverage.py's sweep found precisely that gap the first time this guard was written (a
# snippet with no tags in it "passes" whether or not the stripping pattern still matches anything).
# Kept SHORT on purpose — comfortably inside SNIPPET_CHARS — because the sweep found a SECOND,
# subtler gap the first time this fixture carried a long sentence: the 120-char truncation cut the
# check phrase off mid-word, so the assertion failed for a reason that had nothing to do with
# TAG_RE. A witness fixture has to fit inside the window the thing it is proving actually uses.
LEAK_GLUED = """<div class="listingblock execute"><div class="content"><pre><code>oc get pods</code></pre></div></div>
<div class="paragraph">
<p>+
"I granted the write. <strong>Read the cluster</strong> first."</p>
</div>
"""

# A CLEAN page: a correctly-working [tabs] Console::/CLI:: continuation (the house-standard
# dual-path pattern — hundreds of real instances, none of them a defect), a NOTE that attached
# correctly, and — the deliberate negative control for the boundary check — a paragraph that
# genuinely starts with a literal plus sign ON ONE PHYSICAL LINE. If the boundary check ever
# regressed to "any <p> starting with +", this is the fixture that would catch it: `+5%` is real
# prose, not a leaked marker, because Asciidoctor never inserted a line break between the `+` and
# the `5` — they were one line in the source and stay one line in the output.
CLEAN_PAGE = """<div class="dlist"><dl>
<dt class="hdlist1">Console</dt>
<dd><div class="openblock"><div class="content">
<div class="paragraph"><p>Open the web console and click Workloads.</p></div>
</div></div></dd>
<dt class="hdlist1">CLI</dt>
<dd><div class="openblock"><div class="content">
<div class="listingblock execute"><div class="content"><pre><code>oc get pods -n $NS</code></pre></div></div>
</div></div></dd>
</dl></div>
<div class="admonitionblock note">
<table><tr><td class="content"><p>A green checkpoint means the fix landed.</p></td></tr></table>
</div>
<div class="paragraph">
<p>+5% growth is expected this quarter — real prose, not a continuation marker.</p>
</div>
"""


def _write_rendering(root: Path, name: str, pages: dict) -> Path:
    """One synthetic rendering root: root/name/modules/<slug>/lab.html per (slug, body) in pages."""
    rendering = root / name
    for slug, body in pages.items():
        page_dir = rendering / "modules" / slug
        page_dir.mkdir(parents=True, exist_ok=True)
        (page_dir / "lab.html").write_text(f"<html><body>{body}</body></html>", encoding="utf-8")
    return rendering


def _pad_rendering(root: Path, name: str, count: int) -> None:
    """Add `count` inert, leak-free filler pages under one rendering.

    Exists ONLY so --self-test's end-to-end `main()` calls — which run through the REAL production
    floors, deliberately with no CLI back door to lower them — can clear MIN_HTML_FILES without a
    real 396-file build on disk. If a filler page ever matched LEAK_RE that would be a bug in the
    filler text, not evidence of anything; it carries no `+` at all.
    """
    rendering = root / name
    for i in range(count):
        page_dir = rendering / "modules" / f"filler-{i}"
        page_dir.mkdir(parents=True, exist_ok=True)
        (page_dir / "lab.html").write_text(
            "<html><body><div class=\"paragraph\"><p>filler page — nothing to see here.</p></div>"
            "</body></html>", encoding="utf-8")


def self_test(tmpdir: Path) -> int:
    """Prove both directions on synthetic built HTML: a leaked page fails, in EACH rendering
    position (not just "demo"); a clean tree — including a page with a genuinely plus-prefixed
    sentence — passes. Then prove the driver (scan(), and main() end to end) carries both verdicts,
    and that the CLI layer refuses fewer than three renderings, a missing directory, and a duplicate.
    """
    ok = True

    # ── Direction 1: a leaked page FAILS, and the guard does not special-case "demo". The bare
    # shape is planted in the position CI calls "demo"; the glued shape in the position CI calls
    # "workshop" — proving detection is symmetric across renderings, not hard-coded to one of them.
    leaky = tmpdir / "leaky"
    _write_rendering(leaky, "demo", {"ai-assisted-development": LEAK_BARE})
    _write_rendering(leaky, "workshop", {"ai-assisted-development": LEAK_GLUED})
    _write_rendering(leaky, "instructor", {"ai-assisted-development": CLEAN_PAGE})
    dirs = [leaky / "demo", leaky / "workshop", leaky / "instructor"]
    findings, collapsed, _summary = scan(dirs, floors=(3, 1))
    if collapsed:
        print(f"❌ SELF-TEST FAILED: scanning the LEAKED fixture collapsed scope (rc {collapsed}) "
              f"before the detector had a chance to fire.", file=sys.stderr)
        ok = False
    by_rendering = {r for r, *_ in findings}
    if by_rendering != {"demo", "workshop"}:
        print(f"❌ SELF-TEST FAILED: expected findings tagged exactly {{'demo', 'workshop'}}, got "
              f"{by_rendering}. Either a detector is blind in one rendering position, or the "
              f"'instructor' clean fixture is wrongly firing — this guard must treat every rendering "
              f"the same way.", file=sys.stderr)
        ok = False
    if len(findings) != 2:
        print(f"❌ SELF-TEST FAILED: expected exactly 2 findings (one bare, one glued), got "
              f"{len(findings)}: {findings}", file=sys.stderr)
        ok = False
    bare = [f for f in findings if f[0] == "demo"]
    if bare and bare[0][3] != "":
        print(f"❌ SELF-TEST FAILED: the bare `<p>+</p>` shape must report an EMPTY snippet (nothing "
              f"followed the marker before the paragraph closed); got {bare[0][3]!r}.",
              file=sys.stderr)
        ok = False
    glued = [f for f in findings if f[0] == "workshop"]
    if glued and "granted the write" not in glued[0][3]:
        print(f"❌ SELF-TEST FAILED: the glued shape must report the sentence that follows the "
              f"marker (mirroring the reconnaissance method that found the real instances); got "
              f"{glued[0][3]!r}.", file=sys.stderr)
        ok = False
    # TAG_RE's own witness: the fixture's trailing sentence carries a real <strong> span, so the
    # reported snippet must both LOSE the tag (proving TAG_RE still matches — without this, a
    # snippet with no embedded markup at all would "pass" whether or not the pattern still fires,
    # which is exactly the gap _canary-coverage.py's sweep found the first time this was written)
    # and KEEP the words that were inside it (proving the strip is a strip, not a truncation).
    if glued and ("<strong>" in glued[0][3] or "Read the cluster" not in glued[0][3]):
        print(f"❌ SELF-TEST FAILED: TAG_RE did not cleanly strip the embedded <strong> span from "
              f"the glued shape's snippet — either the tag survived or it took the words inside it "
              f"with it; got {glued[0][3]!r}.", file=sys.stderr)
        ok = False

    # ── Direction 2: a CLEAN tree passes — across all three renderings, including the deliberate
    # plus-prefixed-prose negative control and a correctly-attached [tabs] continuation.
    clean = tmpdir / "clean"
    for name in ("workshop", "demo", "instructor"):
        _write_rendering(clean, name, {"some-module": CLEAN_PAGE, "other-module": LEAK_BARE.replace(
            "<p>+</p>", "<p>a real paragraph, not a leak</p>")})
    clean_dirs = [clean / "workshop", clean / "demo", clean / "instructor"]
    clean_findings, clean_collapsed, clean_summary = scan(clean_dirs, floors=(3, 1))
    if clean_collapsed:
        print(f"❌ SELF-TEST FAILED: scanning the CLEAN fixture collapsed scope (rc {clean_collapsed}) "
              f"— a clean tree must be inspectable, not just a leaked one.", file=sys.stderr)
        ok = False
    if clean_findings:
        print(f"❌ SELF-TEST FAILED: the CLEAN fixture was flagged ({clean_findings}). A guard that "
              f"fires on a genuinely plus-prefixed sentence or a correctly-attached [tabs] "
              f"continuation is a guard that cries wolf and gets switched off, taking the real "
              f"detector with it.", file=sys.stderr)
        ok = False
    if "renderings" not in clean_summary or "html files" not in clean_summary:
        print(f"❌ SELF-TEST FAILED: scan()'s summary does not name what it measured "
              f"({clean_summary!r}) — a clean verdict that does not say how much it looked at is the "
              f"thing _scope.py was written to stop.", file=sys.stderr)
        ok = False

    # ── The REAL production floors must collapse a scan this small. Without this, MIN_HTML_FILES
    # could silently rot to "1" and no CI signal would ever say so — the exact hole _scope.py's own
    # README section warns a Scope-less floor check leaves open.
    _f, real_floor_rc, _s = scan(clean_dirs, floors=(MIN_RENDERINGS, MIN_HTML_FILES), quiet=True)
    if real_floor_rc != 2:
        print(f"❌ SELF-TEST FAILED: scanning a {sum(1 for _ in Path(clean_dirs[0]).rglob('*.html'))}"
              f"-file-per-rendering fixture against the REAL floors "
              f"({MIN_RENDERINGS} renderings / {MIN_HTML_FILES} html files) did not collapse (rc "
              f"{real_floor_rc}) — the production floor is too low to catch a truncated build.",
              file=sys.stderr)
        ok = False

    # ── THE DRIVER, not just scan(). main() is what CI actually calls; every assertion above went
    # through scan() directly with a lowered floor, so nothing yet proved argv parsing, the
    # directory-existence check, the distinct-directories check, report()'s exit code, OR that the
    # REAL production floors (no CLI override exists, on purpose) let a legitimately-sized scan
    # through. Pad both fixture trees to clear MIN_HTML_FILES honestly — through the same *.html
    # walk the real run uses, not by lowering the bar to fit the fixture.
    pad = MIN_HTML_FILES // 3 + 5           # 3 renderings * pad > MIN_HTML_FILES, comfortably
    for rendering in ("demo", "workshop", "instructor"):
        _pad_rendering(leaky, rendering, pad)
        _pad_rendering(clean, rendering, pad)

    leaked_rc = main(["--built", str(dirs[0]), "--built", str(dirs[1]), "--built", str(dirs[2])])
    if leaked_rc != 1:
        print(f"❌ SELF-TEST FAILED: main() over the leaked fixture directories returned {leaked_rc}, "
              f"not 1 — the CLI driver is not carrying scan()'s findings through to report()'s exit "
              f"code.", file=sys.stderr)
        ok = False
    clean_rc = main(["--built", str(clean_dirs[0]), "--built", str(clean_dirs[1]),
                     "--built", str(clean_dirs[2])])
    if clean_rc != 0:
        print(f"❌ SELF-TEST FAILED: main() over the clean fixture directories returned {clean_rc}, "
              f"not 0.", file=sys.stderr)
        ok = False

    # ── "If a build is missing when it runs, it must exit 2 and say so, NOT pass." A directory that
    # does not exist at all.
    missing_rc = main(["--built", str(clean_dirs[0]), "--built", str(clean_dirs[1]),
                       "--built", str(tmpdir / "does-not-exist")])
    if missing_rc != 2:
        print(f"❌ SELF-TEST FAILED: main() with one nonexistent --built directory returned "
              f"{missing_rc}, not 2 — a missing build must never read as a clean scan of nothing.",
              file=sys.stderr)
        ok = False

    # ── Fewer than three renderings — the entire point of this guard is a three-way comparison, so
    # two is not a smaller clean scan, it is an unproven one.
    two_rc = main(["--built", str(clean_dirs[0]), "--built", str(clean_dirs[1])])
    if two_rc != 2:
        print(f"❌ SELF-TEST FAILED: main() with only TWO --built directories returned {two_rc}, not "
              f"2 — 'checked two of three renderings' must never report as clean.", file=sys.stderr)
        ok = False

    # ── Zero renderings is a DIFFERENT failure mode from "one or two supplied and missing", and
    # deliberately returns 0, not 2 — see the long comment in main() for why: this exact call shape
    # (`main([])`) is what tools/lint/_canary-coverage.py's baseline probe makes of every Python
    # guard here, unconditionally, and requires it to return 0. A guard that answered 2 to "you asked
    # me to check nothing" would fail that shared contract outright, not just its own self-test.
    # ONE or TWO explicit --built directories (tested above and below) are a different call shape —
    # canary-coverage never produces them — and correctly stay at rc 2.
    zero_rc = main([])
    if zero_rc != 0:
        print(f"❌ SELF-TEST FAILED: main() with NO --built directories at all returned {zero_rc}, "
              f"not 0 — this exact call is what _canary-coverage.py's baseline probe makes, and it "
              f"requires 0.", file=sys.stderr)
        ok = False

    # ── A duplicate directory (the same rendering handed twice, e.g. a copy-paste in the workflow
    # step) must not silently count as satisfying the three-distinct-renderings requirement.
    dup_rc = main(["--built", str(clean_dirs[0]), "--built", str(clean_dirs[0]),
                   "--built", str(clean_dirs[1])])
    if dup_rc != 2:
        print(f"❌ SELF-TEST FAILED: main() with a DUPLICATE --built directory (only two distinct "
              f"paths among three arguments) returned {dup_rc}, not 2.", file=sys.stderr)
        ok = False

    for failure in Scope.self_check():
        print(f"❌ SELF-TEST FAILED: {failure}", file=sys.stderr)
        ok = False

    if not ok:
        return 2
    print("self-test ok — the bare and glued leak shapes are both caught, tagged to the correct "
          "rendering (demo AND workshop, not just demo); a clean tree — including a correctly-"
          "attached [tabs] continuation and a genuinely plus-prefixed sentence — passes across all "
          "three renderings; the production floors would collapse a build this small; main() carries "
          "both verdicts end to end and refuses a missing directory, a duplicate directory, and "
          "fewer than three renderings, all with rc 2 — and answers a bare, argument-less call (the "
          "shape _canary-coverage.py's baseline probe makes) with a clearly-labelled no-op at rc 0, "
          "never as a false 'verified clean'.")
    return 1


def main(argv=None) -> int:
    # argv is a PARAMETER, not read from sys.argv, because tools/lint/_canary-coverage.py drives
    # every guard by calling `mod.main(argv)` POSITIONALLY, in-process, to blind one detector at a
    # time. A zero-argument `def main()` raises TypeError there, the harness's broad handler turns
    # it into rc 2, and this guard's own real-run mode would ship unproven while its CI job stayed
    # green — measured against module-number-drift-guard on 2026-08-07; match the sibling guards.
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="run the canaries instead of a real build; exits 1 when every canary was "
                         "correctly caught, which is the PASS for this mode")
    ap.add_argument("--built", action="append", default=[], metavar="DIR",
                    help="a built site root (repeatable) — supply ALL THREE renderings "
                         "(workshop, demo, instructor); fewer than three distinct directories is "
                         "refused, because this guard's whole point is comparing across all of them")
    args = ap.parse_args(argv)

    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return self_test(Path(td))

    if not args.built:
        # A CLEARLY-LABELLED no-op, not a silent one, and deliberately DISTINCT from an explicit
        # `--built` argument that fails to resolve (which stays rc 2 below). Two different failure
        # modes get two different exit codes on purpose:
        #   - "you told me to check DIR and DIR is not there" is this guard failing to do the job it
        #     was asked to do — that is the "missing build must exit 2, never pass" case, and it is
        #     what actually protects the real CI wiring (content-build.yml always supplies exactly
        #     three --built flags; only a broken EDIT to that step could ever hit this).
        #   - "you asked me to check nothing at all" is not a build going missing; it is an empty
        #     request, and tools/lint/_canary-coverage.py's baseline probe calls every guard's
        #     `main([])` and requires it to return 0 (this is one contract shared by every Python
        #     guard in this tree, not a --self-test detail — see that file's "THE CONTRACT" comment).
        #     Every OTHER guard here satisfies it by having a real source-side default scan; this one
        #     has none, by design (the whole point is reading built HTML, never .adoc source), so the
        #     honest zero-argument answer is "nothing was asked of me," not "2 — go build first."
        # The label is what keeps this from being the vacuous-pass anti-pattern this whole guard
        # exists to prevent: it says plainly that no build was checked, never "clean."
        print("ℹ️  stray-continuation-guard: no --built directories supplied — nothing to check. "
              "This is NOT a verification that any build is clean; it is a no-op. Real usage always "
              "supplies --built once per rendering (see the 'Stray continuation markers' step in "
              ".github/workflows/content-build.yml).")
        return 0

    dirs = [Path(d) for d in args.built]
    missing = [str(d) for d in dirs if not d.is_dir()]
    if missing:
        print(f"::error::stray-continuation-guard: built director(y/ies) not found: {missing}. "
              f"Refusing to report a clean scan of a build that is not there — an unrun build must "
              f"exit 2, never pass.", file=sys.stderr)
        return 2

    resolved = [d.resolve() for d in dirs]
    if len(set(resolved)) != len(resolved):
        print(f"::error::stray-continuation-guard: the same directory was supplied more than once "
              f"({[str(d) for d in dirs]}). That can satisfy an argument COUNT without actually "
              f"comparing three distinct renderings — refusing to treat it as a clean three-way "
              f"scan.", file=sys.stderr)
        return 2

    findings, collapsed, summary = scan(dirs)
    if collapsed:
        return collapsed
    return report(findings, summary)


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
        print(f"::error::stray-continuation-guard: crashed ({type(exc).__name__}: {exc}). Exiting "
              f"2 — a crash is 'the guard could not run', never 'clean' and never 'canary detected'.",
              file=sys.stderr)
        sys.exit(2)
