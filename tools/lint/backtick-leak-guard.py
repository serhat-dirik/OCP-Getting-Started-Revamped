#!/usr/bin/env python3
"""backtick-leak-guard.py — an AsciiDoc code span that cannot close leaves a literal backtick, and
swallows the rest of the sentence into <code>. The source looks right and the build is rc=0.

ORIGIN (2026-08-05). AsciiDoc single-backtick spans are CONSTRAINED. Asciidoctor's rule, MEASURED
against @asciidoctor/core 2.2.9 (the engine this repo builds with) rather than recalled:

    opening `  is refused when the character BEFORE it is  \\w (unicode), ; : " ' }
    closing `  is refused when the character AFTER  it is  \\w (unicode), " ' `

So `Site`s does not render a code span at all: the whole construct stays literal, or — worse — the
span silently extends to the next backtick that IS allowed to close, dragging half a sentence into
monospace with a stray backtick sitting inside it. 101 of these were shipping across 21 modules
before the sweep of 2026-08-05, and nothing caught them for months: the source reads fine, Antora
exits 0, and only the rendered HTML shows the damage.

TWO CORRECTIONS THE MEASUREMENT FORCED, both of which a from-memory implementation gets wrong:
  * A CURLY apostrophe does NOT block the close — `Site`’s renders correctly. The STRAIGHT one
    does, and Asciidoctor's later replacements pass then turns the surviving `' into a curly
    apostrophe, which is why the rendered page looks like it merely lost its formatting.
  * `' also means the visible symptom is NOT reliably a stray backtick. In `user6`'s the opening
    backtick is consumed by the over-long span and the `' pair becomes ’, so the only trace in the
    HTML is prose wrongly wearing <code>. A "grep the built HTML for a backtick" check cannot see
    that. See "WHY SOURCE, NOT BUILT HTML" below.

WHAT IT CHECKS, over every tracked .adoc, line by line, outside verbatim blocks:
  [1] BLOCKED CLOSE — a legally-opened span whose closing backtick is followed by \\w, " or '.
      This is the shipped defect: `Site`s, `user6`'s, `claims-live`'s.
  [2] BLOCKED OPEN  — a span whose opening backtick is preceded by \\w ; : " ' or }. The form that
      survived the sweep in this repo is a demo Say/Do line that opens on a quote character:
      "`registry.access.redhat.com` hands out UBI anonymously." — the reader sees both backticks.
      `{attr}`code`` is the same trap with a } in front of it.

WHY SOURCE, NOT BUILT HTML — decided on evidence, not on convenience. Built HTML is the tempting
choice ("it cannot false-positive"), and measuring it is what ruled it out:
  * ONE SOURCE, THREE RENDERINGS, AND EACH HIDES PART OF THE DEFECT. Every page was rendered with
    real Asciidoctor twice, once plain and once with `demo` set. The workshop rendering exposes 4
    of the 9 surviving sites; the demo rendering exposes the other 5; the two sets are DISJOINT,
    because half the leaks live in [demo-block] Say/Do lines that ifdef::demo removes from the
    workshop pages entirely. An HTML gate would have to build all three sites and union them, and
    a rendering added later drops out of coverage silently. The source IS the union.
  * THE HTML SYMPTOM IS NOT A RELIABLE SIGNAL. Counting backticks in rendered prose finds a
    SUBSET, and which subset depends on the apostrophe: `' collapses to ’ and the swallowed
    sentence sits inside <code> — the very element an HTML scanner has to strip so that code
    blocks do not trip it. "Ground truth" here needs the author's intent, which only the source
    carries.
  * A GATE THAT NEEDS A BUILD IS A GATE THAT GETS SKIPPED. Every job in lint.yml is checkout plus
    an interpreter and finishes in seconds; the one job that needed more was throttled to a nightly
    for setting the wall clock. Requiring npm ci and three Antora builds before this check could
    run would put it on the same path, and an unrun gate is worse than none.
  * SUBSTITUTION ORDER IS ON THE SOURCE'S SIDE. Asciidoctor applies quotes BEFORE attributes, so
    what an attribute expands to cannot change whether a span closes. The source line carries the
    whole answer, and it also carries the file:line the author has to edit — an HTML hit does not.

WHAT THE RE-IMPLEMENTED RULE COST, AND HOW IT WAS CHECKED. Re-implementing a constrained-span rule
is the risk the source choice takes on, so it was measured rather than argued: all 4,943 prose
lines carrying a backtick were rendered individually through @asciidoctor/core 2.2.9 and compared
against this guard's verdict. Agreement is exact — 0 false positives and 0 false negatives, on 9
findings. Re-run that comparison after any change to the character classes or the walk.

WHAT THIS CHOICE CANNOT CATCH, stated plainly:
  * A span whose body crosses a newline. Asciidoctor allows it; this scanner is line-scoped, so
    `foo\\nbar`s is a false negative. Measured exposure on this tree: ZERO prose lines end with an
    unclosed would-be span, so nothing is missed today — and a fix would have to model paragraph
    boundaries, which risks inventing spans across unrelated lines. Line-scoping is also what makes
    every finding a file:line:column the author can open.
  * A leak that only exists after an include. Partials are scanned as their own files, so the text
    is covered — but a construct split across an include:: boundary is not.
  * Content inside an inline passthrough (+...+, pass:[...]) is deliberately skipped: a literal
    backtick there is the author asking for one.
  * A literal paragraph created by INDENTATION rather than by a delimiter. Those take no
    substitutions, so a backtick in one is safe and this scanner would call it prose. It reports a
    finding there only if the indented text also contains a blocked span, which has not happened
    on this tree; the cost of modelling it is mistaking list continuations for literal blocks.
  * An orphan backtick with no partner at all (`foo alone). It renders literally and is a real
    defect, but it is also what an author writes on purpose to talk about the character, so it is
    left to review rather than to a gate.

Exit codes:
  0  contract holds
  1  contract broken — or, under --self-test, every canary was correctly detected
  2  the guard could not inspect what it claims to inspect (no files found, unreadable tree)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


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


def _compile(name: str, pattern: str, flags: int = 0):
    """re.compile, but a bad pattern exits 2 instead of crashing with Python's rc 1.

    Same reason as every guard beside this one: a module-level re.error raises before main() can
    run, Python exits 1, and 1 is precisely what CI's "--self-test must exit EXACTLY 1" assertion
    reads as "the canary was detected". A regex typo must never report detection as proven.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::backtick-leak-guard: {name} is not a valid regex ({exc}) — the guard "
              f"could not load. Exiting 2: that is 'broken', not 'clean'.", file=sys.stderr)
        sys.exit(2)


# ── Character classes, transcribed from measured behaviour ─────────────────────────────────────
#
# Asciidoctor's constrained-monospace rule. `\w` is unicode-aware in both engines — a preceding or
# following `é` blocks, which was measured, not assumed.
OPEN_BLOCKERS = r"""\w;:"'}"""
CLOSE_BLOCKERS = r"""\w"'`"""

# ── Block structure ────────────────────────────────────────────────────────────────────────────
#
# VERBATIM blocks take no quote substitutions at all, so their backticks are content: `----` is
# full of them and every one is legitimate. Only the IDENTICAL delimiter closes such a block —
# nothing inside is parsed, so a `====` inside a `----` opens nothing.
VERBATIM_DELIM = _compile("VERBATIM_DELIM", r"^(-{4,}|\.{4,}|\+{4,}|/{4,})\s*$")
# A line comment is not rendered. `////` is the comment BLOCK delimiter and is handled above.
LINE_COMMENT = _compile("LINE_COMMENT", r"^\s*//(?!/)")

# ── Constructs that legitimately carry backticks in prose, blanked before the detectors run ────
#
# Order matters and mirrors Asciidoctor's own: passthroughs are extracted first, then the curved
# quote pairs, then unconstrained monospace, and only what is left can be a constrained span.
PASS_MACRO = _compile("PASS_MACRO", r"pass:[a-z]*\[[^\]\n]*\]")
# +text+ / ++text++ / +++text+++ — the constrained single-plus form needs a non-word neighbour on
# each side, which is what keeps a bare `+` list continuation from swallowing a line. All three
# forms require a non-space at each end of the body, exactly as Asciidoctor does: without that,
# "C++ and C++" reads as one passthrough and would blank a leak sitting between them.
PASSTHROUGH = _compile("PASSTHROUGH",
                       r"\+{3}(?:\S|\S[^\n]*?\S)\+{3}"
                       r"|\+{2}(?:\S|\S[^\n]*?\S)\+{2}"
                       r"|(?<![\w;:+])\+(?:\S|\S[^\n]*?\S)\+(?!\w)")
# "`curved double quotes`" and '`curved single quotes`' — a `" or `' pair here is the construct,
# not a leak. Without these two the detectors would report every smart quote in the workshop.
SMART_DOUBLE = _compile("SMART_DOUBLE", r'"`(?:\S|\S[^\n]*?\S)`"')
SMART_SINGLE = _compile("SMART_SINGLE", r"'`(?:\S|\S[^\n]*?\S)`'")
# ``text`` is UNCONSTRAINED — it closes against anything, and is the correct fix for `text`s.
MONO_UNCONSTRAINED = _compile("MONO_UNCONSTRAINED", r"``(?:\S|\S[^\n]*?\S)``")

# ── The two detectors ──────────────────────────────────────────────────────────────────────────
#
# Both are decided by a PAIRING WALK (see leaks_in), not by a standalone regex over the raw line.
# The regex version of this guard was written first and produced 363 findings on this tree, of
# which essentially all were false: in `toolCalls`/`tokenUsage` the CLOSING backtick of a perfectly
# good span is also a backtick preceded by a word character, so a pattern that only looks at one
# delimiter's neighbours cannot tell a closer from a refused opener. Which role a backtick plays is
# positional, so the guard has to walk the line and keep track.
#
# [1] CLOSE_BLOCKER — the character class that refuses a closing backtick.
CLOSE_BLOCKER = _compile("CLOSE_BLOCKER", rf"[{CLOSE_BLOCKERS}]")
# [2] OPEN_BLOCKER — the character class that refuses an opening backtick.
OPEN_BLOCKER = _compile("OPEN_BLOCKER", rf"[{OPEN_BLOCKERS}]")

# Blanking filler. Not a space: a space would change the neighbouring character that decides
# whether the NEXT span may open, and turn a real leak into a silent pass.
FILL = "\x01"


def _blank(text: str, rx) -> str:
    """Replace every match of `rx` with same-length filler, so offsets stay honest."""
    return rx.sub(lambda m: FILL * len(m.group(0)), text)


def inert(line: str) -> str:
    """One prose line with every LEGITIMATE backtick construct blanked out.

    What survives is the material the two detectors judge. Applying the blanking in Asciidoctor's
    own order matters: `+`Site`s+` is a passthrough first and never reaches the monospace rules.
    """
    for rx in (PASS_MACRO, PASSTHROUGH, SMART_DOUBLE, SMART_SINGLE, MONO_UNCONSTRAINED):
        line = _blank(line, rx)
    return line


def prose_lines(text: str):
    """Yield (line_number, line) for lines that actually take inline substitutions.

    Verbatim blocks are skipped wholesale, and while inside one ONLY its own delimiter is looked
    for — the same rule Asciidoctor applies, and the reason a `----` block full of shell backticks
    cannot trip this guard.
    """
    verbatim = None
    for number, line in enumerate(text.splitlines(), 1):
        token = line.strip()
        if verbatim is not None:
            if token == verbatim:
                verbatim = None
            continue
        if VERBATIM_DELIM.match(token):
            verbatim = token
            continue
        if LINE_COMMENT.match(line) or "`" not in line:
            continue
        yield number, line


def leaks_in(judged: str):
    """Yield (column, kind) for every backtick on one blanked line that cannot play its role.

    THE WALK. A backtick's role is positional, so the line is read left to right with one bit of
    state: are we inside a would-be span or not. Asciidoctor's own two structural rules decide
    whether a backtick is even eligible for a role — a span's body may not start or end on
    whitespace, so a backtick followed by a space can never open and one preceded by a space can
    never close. Those ineligible backticks are skipped WITHOUT touching the state, which is what
    keeps a lone ` used as prose ("the ` character and `code` here") from shifting the parity of
    everything after it and inventing a leak in the next honest span.

    Only then is the blocking character class consulted:
      * a backtick taking the CLOSING role, followed by \\w " or '  → the span cannot close  → [1]
      * a backtick taking the OPENING role, preceded by \\w ; : " ' } → the span cannot open → [2]
    """
    pending = False
    for i, char in enumerate(judged):
        if char != "`":
            continue
        prev = judged[i - 1] if i else ""
        nxt = judged[i + 1] if i + 1 < len(judged) else ""
        if pending and prev and not prev.isspace():
            if CLOSE_BLOCKER.match(nxt):
                yield i + 1, "blocked-close"
            pending = False
        elif not pending and nxt and not nxt.isspace():
            if OPEN_BLOCKER.match(prev):
                yield i + 1, "blocked-open"
            pending = True


def scan(paths):
    """[(relative path, line number, column, kind, excerpt)] for every leak found."""
    findings = []
    for path in paths:
        try:
            raw = path.read_text(errors="replace")
        except OSError:
            continue
        rel = path.relative_to(REPO) if str(path).startswith(str(REPO)) else path
        for number, line in prose_lines(raw):
            for col, kind in leaks_in(inert(line)):
                findings.append((str(rel), number, col, kind, _excerpt(line, col - 1, col)))
    findings.sort()
    return findings


def _excerpt(line: str, start: int, end: int, pad: int = 24) -> str:
    lo, hi = max(0, start - pad), min(len(line), end + pad)
    return ("…" if lo else "") + line[lo:hi].strip() + ("…" if hi < len(line) else "")


def tracked_adocs():
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", "--", "*.adoc"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
    except Exception:
        return []
    # Fixtures belonging to other guards are deliberately broken content — scanning them would
    # report another guard's canary as this guard's finding. (credential-redaction-guard's canary
    # genuinely contains a leaked backtick, on purpose.)
    return [REPO / f for f in out if not _is_canary(f)]


def report(findings) -> int:
    if not findings:
        print("✅ backtick leaks: every constrained code span in prose can open and close —")
        print("   no attendee sees a stray ` or a sentence wearing <code>")
        return 0
    close = [f for f in findings if f[3] == "blocked-close"]
    opened = [f for f in findings if f[3] == "blocked-open"]
    if close:
        print(f"❌ [1] {len(close)} code span(s) cannot CLOSE: the ` is followed by a word "
              f"character, \" or '.")
        print("       The reader sees a literal backtick, or the span runs on to the next backtick")
        print("       that is allowed to close and drags the sentence into monospace with it.")
        print("       Fix: use the UNCONSTRAINED form — ``Site``s — or reword so the span ends on")
        print("       whitespace or punctuation. A curly ’ closes fine; a straight ' does not.")
        for f, ln, col, _kind, txt in close[:25]:
            print(f"   {f}:{ln}:{col}  {txt}")
        if len(close) > 25:
            print(f"   … and {len(close) - 25} more")
    if opened:
        print(f"❌ [2] {len(opened)} code span(s) cannot OPEN: the ` is preceded by a word "
              f"character, ; : \" ' or }}.")
        print("       Most often a demo Say/Do line that opens on a quote — \"`oc get pods` …\".")
        print("       Fix: put a space after the quote, use ``oc get pods``, or reword.")
        for f, ln, col, _kind, txt in opened[:25]:
            print(f"   {f}:{ln}:{col}  {txt}")
        if len(opened) > 25:
            print(f"   … and {len(opened) - 25} more")
    return 1


# ── Fixtures ───────────────────────────────────────────────────────────────────────────────────
#
# Every line of FIXTURE_CLEAN was rendered through @asciidoctor/core 2.2.9 while this guard was
# written. Each one either renders with no literal backtick at all, or asks for literal backticks
# on purpose (the passthrough line, measured: exactly the 4 the author wrote) or is verbatim block
# content. It is the half of the self-test that stops the guard from being tuned until it goes
# green: a detector that fires here is wrong, and blinding ANY of the eight blanking/skipping
# patterns makes one fire here.
FIXTURE_CLEAN = """= Page

Run `oc get pods` and read the `NAME` column; `it's fine` if nothing shows yet.

The ``Site``s name uses the unconstrained form, which is the fix for this defect.

A curly apostrophe closes a span correctly: `Site`’s name.

Smart quotes are a construct, not a leak: "`quoted`" and '`single`'.

A passthrough asks for literal backticks on purpose: +`Site`s+ and pass:[`Other`s].

// A comment is never rendered, so `Site`s here reaches no reader.

.A listing block is full of legitimate backticks
[source,sh]
----
echo "`date`" && VAR=`hostname` && echo "${VAR}`s"
----

....
literal block: `Site`s
....
"""

FIXTURE_BLOCKED_CLOSE = """= Page

The `Site`s name is wrong, and so is `user6`'s namespace.
"""

FIXTURE_BLOCKED_OPEN = """= Page

Do:: "`registry.access.redhat.com` hands out UBI anonymously."
"""


def _scan_text(tmpdir: Path, name: str, text: str):
    path = tmpdir / name
    path.write_text(text)
    return scan([path])


def self_test(tmpdir: Path) -> int:
    # Proof 0: a detector that fires on everything proves nothing. The clean fixture carries one
    # instance of every construct the blanking pass exists for, so blinding ANY of them lands here.
    noise = _scan_text(tmpdir, "clean.adoc", FIXTURE_CLEAN)
    if noise:
        print(f"❌ SELF-TEST FAILED: the CLEAN fixture was flagged ({noise}).")
        print("   Every line of it renders without a stray backtick in real Asciidoctor. A guard")
        print("   that fires on correct content will be disabled by the first person it annoys.")
        return 2

    # Canary A — the shipped defect. Must be caught by detector [1], BY NAME: a canary that any
    # detector may claim lets one of them go blind while the exit code stays at 1.
    hits = _scan_text(tmpdir, "close.adoc", FIXTURE_BLOCKED_CLOSE)
    kinds = {h[3] for h in hits}
    if kinds != {"blocked-close"} or len(hits) != 2:
        print(f"❌ SELF-TEST FAILED: `Site`s and `user6`'s should be exactly two blocked-close "
              f"findings; got {hits}.")
        print("   Detector [1] is blind, and the defect this guard exists for would ship again.")
        return 2

    # Canary B — the form that survived the sweep here: a code span opening on a quote character.
    hits = _scan_text(tmpdir, "open.adoc", FIXTURE_BLOCKED_OPEN)
    if {h[3] for h in hits} != {"blocked-open"} or len(hits) != 1:
        print(f"❌ SELF-TEST FAILED: a span opening on a \" should be exactly one blocked-open "
              f"finding; got {hits}.")
        print("   Detector [2] is blind — demo Say/Do lines would keep shipping visible backticks.")
        return 2

    # Proof 1: the guard must be able to SEE the real tree, or its clean verdict means nothing.
    real = tracked_adocs()
    if not real:
        print("❌ SELF-TEST FAILED: no tracked .adoc files found — the guard would pass by "
              "scanning nothing.")
        return 2

    print("✅ self-test ok — clean fixture silent across all eight legitimate backtick constructs;")
    print(f"   blocked-close and blocked-open canaries each caught by their own detector; "
          f"{len(real)} tracked .adoc file(s) visible to the real scan.")
    return 1  # house convention: every canary caught == exit exactly 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the detectors fire against planted canaries (exit 1 = PASS)")
    args = ap.parse_args(argv)

    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return self_test(Path(td))

    paths = tracked_adocs()
    if not paths:
        print("❌ no tracked .adoc files found — refusing to report a clean scan of nothing.")
        return 2
    findings = scan(paths)
    print(f"   scanned {len(paths)} tracked .adoc file(s)")
    return report(findings)


def _crash_exit_2(exc_type, exc, tb):
    """Any unhandled exception exits 2, never 1 — 1 is CI's "the canaries were caught"."""
    sys.__excepthook__(exc_type, exc, tb)
    print("::error::backtick-leak-guard: crashed. Exiting 2 — the guard could not inspect what it "
          "claims to inspect, which is NOT 'the tree is clean'.", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    sys.excepthook = _crash_exit_2
    sys.exit(main())
