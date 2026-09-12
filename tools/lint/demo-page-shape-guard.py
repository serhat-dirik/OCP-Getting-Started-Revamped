#!/usr/bin/env python3
"""demo-page-shape-guard.py — every module's Demo page keeps the SA-Demos shape, and none of it
reaches the attendee guide.

WHY THIS EXISTS. An SA opens the demo guide in front of a customer who can read the screen. The
project owner set the page shape on 2026-09-11: a title and one-line summary, a Prep block, a Brief,
numbered steps that each carry a screenshot or diagram, and Frequently asked questions — written as
documentation, not as a script. The shape it replaced (Say/Show/Do beats under timing chips) had its
own guard, retired together with the chips, so without this file nothing checks the new one.

Two measured defects are why these are rules and not a style note:
  * platform-guardrails' presenter arc sat outside `ifdef::demo[]` and rendered in the ATTENDEE
    guide for weeks. Nothing reported it; it was found by reading a rendered page. (R2)
  * Presenter directives — "Say::", "the room", "beat 3" — are what the owner ruled must not be on a
    screen a customer reads, and the easiest thing to paste back from an old draft. (R1)

THE RULES, each proven by one small edit to a known-good fixture page (MUTATIONS, below):
  R1  no presenter-speak inside a demo region, code blocks included — `echo` output is on screen too
  R2  no Demo-page marker outside a demo region
  R3  the skeleton is present and in order: `== <Title> · N min`, an [IMPORTANT]
      `.Prep — run before the session` block, `=== Brief`, `*In this demo*`, the steps, and
      `== Frequently asked questions` as the last heading
  R4  steps read `=== N · <Title> — M min`, run 1..N, and add up to the title's minutes
  R5  the Brief and every step carry exactly one visual; every step has *Why it matters*
  R6  every visual's file exists, and no visual appears twice on a page — an SVG rendered from a
      Mermaid source and that source are the same diagram
  R7  a click-to-run block never passes `--user` (a demo runs as the signed-in workshop account) and
      runs the workshop `adm` tool only as `adm solve <this module>`, and only while
      ADM_SOLVE_CLICK_TO_RUN is True. `oc adm …` is ordinary OpenShift and is not the tool.
  R8  at least three Frequently asked questions

SCOPE. content/modules/ROOT/pages/*/lab.adoc, the Demo page of every module. A demo region is the
lines between `ifdef::demo[]` and its `endif`. A page may have several — two modules keep shared
setup blocks, rendered in every flavor, between two regions — and the skeleton is read across all
of them in order.

EXIT CODES: 0 clean · 1 a page is out of shape · 2 could not inspect. --self-test exits 1 when every
mutation is caught, like every guard beside it.
"""
from __future__ import annotations

import contextlib
import io
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception -> rc 2. Python's own crash code is 1, which CI reads as "the canary
    fired"; a crash must read as "the guard could not run". os._exit is what makes the code stick."""
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::demo-page-shape-guard: crashed ({exc_type.__name__}: {exc}); exiting 2.",
          file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2

REPO = Path(__file__).resolve().parents[2]
CANARY_DIR = Path(__file__).resolve().parent / "demo-page-shape-guard.canary"
PAGES_REL = "content/modules/ROOT/pages"
IMAGES_REL = "content/modules/ROOT/assets/images"
DIAGRAMS_REL = "content/modules/ROOT/examples/diagrams"
MIN_PAGES = 20  # 28 modules today. Fewer means the glob broke, not that the catalogue shrank.

# Decision 9 (owner, 2026-09-11): demos that start from a finished lab state stage it with a
# click-to-run `adm solve <module>`, conditional on proving that a workshop account can run it.
ADM_SOLVE_CLICK_TO_RUN = True

RE_COND = re.compile(r"^(ifdef|ifndef|ifeval|endif)::([^\[]*)\[(.*)\]\s*$")
RE_VERBATIM = re.compile(r"^(-{4,}|\.{4,})\s*$")
RE_PRESENTER = re.compile(
    r"^(?:Say|Show|Do)::|\bthen say\b|^\[TIME \d|^\[demo-block\]|\bbeats?\b|\bthe room\b"
    r"|\bmoney moment\b|\btalk track\b|\bbefore you present\b|\bencore\b|\bpresenter\b",
    re.IGNORECASE)
RE_DEMO_ONLY = re.compile(
    r"^(?:\.Prep — run before the session|=== Brief|== Frequently asked questions"
    r"|== Demo arc\b.*|\[TIME \d.*|(?:Say|Show|Do)::.*)\s*$")
RE_TITLE = re.compile(r"^== (?P<name>.+) · (?P<min>\d+) min$")
RE_PREP = re.compile(r"^\.Prep — run before the session$")
RE_BRIEF = re.compile(r"^=== Brief$")
RE_AGENDA = re.compile(r"^\*In this demo\*$")
RE_STEP = re.compile(r"^=== (?P<n>\d+) · (?P<name>.+) — (?P<min>\d+) min$")
RE_FAQ = re.compile(r"^== Frequently asked questions$")
RE_HEADING = re.compile(r"^={2,3} \S")
RE_IMAGE = re.compile(r"^image::(?P<target>[^\[\s]+)\[")
RE_MERMAID = re.compile(r"^\[mermaid\]\s*$")
RE_MMD_INCLUDE = re.compile(r"^include::example\$diagrams/(?P<target>[^\[\s]+)\[\]")
RE_SVG_RENDER = re.compile(r"^(?P<slug>[^/]+)/(?P=slug)-(?P<stem>[^/]+)\.svg$")
RE_MMD_SOURCE = re.compile(r"^(?P<slug>[^/]+)/(?P<stem>[^/]+)\.mmd$")
RE_WHY = re.compile(r"^\*Why it matters\*$")
RE_RUN_ATTR = re.compile(r"^\[source,[^\]]*\brole=execute\b[^\]]*\]$")
RE_USER_FLAG = re.compile(r"(?:^\s*|[;&|]\s*)(?:ws|adm)\b.*\s--user\b")
# The workshop tool is the COMMAND word. `oc adm policy …` is ordinary OpenShift and must not
# be flagged: M16 demonstrates four tested `oc adm policy` commands.
RE_ADM = re.compile(r"(?:^\s*|[;&|]\s*)adm\b")
RE_FAQ_ENTRY = re.compile(r"^\*.+\?\*::$")


def split_regions(text: str) -> tuple[list, list]:
    """(lines inside a demo region, every other line), each as (line number, text). `endif::[]`
    closes whatever opened last, so every conditional is tracked, not only demo's."""
    inside, outside, stack = [], [], []
    for n, line in enumerate(text.splitlines(), 1):
        m = RE_COND.match(line)
        if m:
            kind, name, body = m.groups()
            if kind == "endif":
                if stack:
                    stack.pop()
            elif kind == "ifeval" or body == "":
                stack.append((kind, name))
            continue
        if ("ifdef", "demo") in stack:
            inside.append((n, line))
        else:
            outside.append((n, line))
    return inside, outside


def annotate(lines: list) -> list:
    """(line number, text, block) per line: block is None for prose, "run" or "text" for the body of
    a ----/.... block, whose delimiter lines are dropped. A block is "run" when the line right above
    its opening delimiter is a `[source,…,role=execute]` attribute line."""
    out, delim, kind, prev = [], None, None, ""
    for n, line in lines:
        if delim is None:
            m = RE_VERBATIM.match(line)
            if m:
                delim = m.group(1)
                kind = "run" if RE_RUN_ATTR.match(prev.strip()) else "text"
            else:
                out.append((n, line, None))
            prev = line
            continue
        if line.rstrip() == delim:
            delim = None
            prev = line
            continue
        out.append((n, line, kind))
    return out


def first(prose: list, rx: re.Pattern) -> int | None:
    return next((i for i, (_, line) in enumerate(prose) if rx.match(line)), None)


def visual_key(target: str) -> str:
    """An SVG rendered from a Mermaid source and the source itself are one diagram: both map to
    <slug>/<stem>. Any other target is its own key."""
    m = RE_SVG_RENDER.match(target) or RE_MMD_SOURCE.match(target)
    return f"{m.group('slug')}/{m.group('stem')}" if m else target


def check_page(root: Path, page: Path) -> list[str]:
    rel = page.relative_to(root)
    slug = page.parent.name
    inside, outside = split_regions(page.read_text(encoding="utf-8"))
    out: list[str] = []

    for n, line in outside:  # R2
        if RE_DEMO_ONLY.match(line):
            out.append(f"{rel}:{n}  renders outside ifdef::demo[] — attendees would see it: "
                       f"{line.strip()[:70]}")

    lines = annotate(inside)
    for n, line, _ in lines:  # R1
        m = None if line.startswith("//") else RE_PRESENTER.search(line)
        if m:
            out.append(f"{rel}:{n}  presenter-speak {m.group(0)!r} — write it as documentation: "
                       f"{line.strip()[:70]}")

    prose = [(n, line) for n, line, block in lines if block is None]
    title, brief, agenda, faq = (first(prose, rx) for rx in (RE_TITLE, RE_BRIEF, RE_AGENDA, RE_FAQ))
    prep = next((i for i, (_, line) in enumerate(prose)
                 if RE_PREP.match(line) and i and prose[i - 1][1].strip() == "[IMPORTANT]"), None)
    steps = [(i, RE_STEP.match(line)) for i, (_, line) in enumerate(prose) if RE_STEP.match(line)]
    headings = [i for i, (_, line) in enumerate(prose) if RE_HEADING.match(line)]

    required = [("title heading `== <Title> · N min`", title),  # R3
                ("[IMPORTANT] `.Prep — run before the session` block", prep),
                ("`=== Brief`", brief),
                ("`*In this demo*` agenda", agenda),
                ("numbered steps `=== N · <Title> — M min`", steps[0][0] if steps else None),
                ("`== Frequently asked questions`", faq)]
    for label, index in required:
        if index is None:
            out.append(f"{rel}  no {label}")
    if all(index is not None for _, index in required):
        order = [title, prep, brief, agenda, steps[0][0], steps[-1][0], faq]
        if order != sorted(order) or (headings and headings[-1] != faq):
            out.append(f"{rel}  out of order — the page must read title, Prep, Brief, "
                       f"*In this demo*, the steps, then Frequently asked questions last")

    if steps:  # R4
        numbers = [int(m.group("n")) for _, m in steps]
        if numbers != list(range(1, len(numbers) + 1)):
            out.append(f"{rel}  step numbers must run 1..{len(numbers)}, found {numbers}")
        if title is not None:
            said = int(RE_TITLE.match(prose[title][1]).group("min"))
            total = sum(int(m.group("min")) for _, m in steps)
            if said != total:
                out.append(f"{rel}  the title says {said} min but the steps add up to {total} min")

    bounds = headings + [len(prose)]  # R5
    sections = ([("the Brief", brief)] if brief is not None else []) + \
        [(f"step {m.group('n')}", i) for i, m in steps]
    for label, start in sections:
        end = next(b for b in bounds if b > start)
        body = prose[start + 1:end]
        visuals = sum(1 for _, line in body if RE_IMAGE.match(line) or RE_MERMAID.match(line))
        if visuals != 1:
            out.append(f"{rel}:{prose[start][0]}  {label} must carry exactly one visual "
                       f"(a screenshot or a diagram), found {visuals}")
        if label != "the Brief" and not any(RE_WHY.match(line) for _, line in body):
            out.append(f"{rel}:{prose[start][0]}  {label} has no *Why it matters*")

    seen: dict[str, int] = {}  # R6
    for n, line, block in lines:
        image = RE_IMAGE.match(line) if block is None else None
        diagram = RE_MMD_INCLUDE.match(line)
        if not (image or diagram):
            continue
        target = (image or diagram).group("target")
        base = root / (IMAGES_REL if image else DIAGRAMS_REL)
        if not (base / target).is_file():
            out.append(f"{rel}:{n}  {target} does not exist under {base.relative_to(root)}")
        key = visual_key(target)
        if key in seen:
            out.append(f"{rel}:{n}  {target} is the same visual as line {seen[key]} — used twice "
                       f"on one page")
        else:
            seen[key] = n

    for n, line, block in lines:  # R7
        if block != "run":
            continue
        if RE_USER_FLAG.search(line):
            out.append(f"{rel}:{n}  --user in a click-to-run block — a demo runs as the signed-in "
                       f"account: {line.strip()}")
        if RE_ADM.search(line) and not (ADM_SOLVE_CLICK_TO_RUN and line.strip() == f"adm solve {slug}"):
            out.append(f"{rel}:{n}  adm in a click-to-run block — Demo pages use ws: {line.strip()}")

    if faq is not None:  # R8
        count = sum(1 for _, line in prose[faq + 1:] if RE_FAQ_ENTRY.match(line))
        if count < 3:
            out.append(f"{rel}  Frequently asked questions lists {count} — fewer than 3 questions")
    return out


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()
    positional = [a for a in argv if not a.startswith("-")]
    root = Path(positional[0]).resolve() if positional else REPO
    pages = sorted((root / PAGES_REL).glob("*/lab.adoc"))
    if not pages or (root == REPO and len(pages) < MIN_PAGES):
        print(f"❌ demo-page-shape-guard: {len(pages)} Demo page(s) under {PAGES_REL} — refusing to "
              f"report a clean scan of (almost) nothing.", file=sys.stderr)
        return 2
    bad = [finding for page in pages for finding in check_page(root, page)]
    if bad:
        print("❌ demo-page-shape-guard: Demo pages out of the SA-Demos shape.\n", file=sys.stderr)
        for finding in bad:
            print(f"  • {finding}", file=sys.stderr)
        return 1
    print(f"demo-page-shape-guard: clean — {len(pages)} Demo page(s) in the SA-Demos shape, and no "
          f"Demo-page marker outside ifdef::demo[].")
    return 0


PAGE = f"{PAGES_REL}/demo-canary/lab.adoc"
TITLE = "== Canary demo · 7 min\n\nOne sentence on what the customer will see.\n"
PREP = ("[IMPORTANT]\n.Prep — run before the session\n====\n[source,sh,role=execute]\n----\n"
        "ws prep demo-canary\n----\n====\n")
# (case, [(old, new), ...], the one finding it must produce — None means "must stay clean").
MUTATIONS = [
    ("presenter-speak", [("What the first step shows.", "Say:: What the first step shows.")],
     "presenter-speak"),
    ("leak", [("Attendee exercise text.", "Attendee exercise text.\n\n=== Brief")],
     "renders outside ifdef::demo[]"),
    ("no-title", [("== Canary demo · 7 min", "== Canary demo")], "no title heading"),
    ("no-prep", [(".Prep — run before the session", ".Before the session")], "no [IMPORTANT]"),
    ("no-brief", [("=== Brief", "=== Overview")], "no `=== Brief`"),
    ("no-agenda", [("*In this demo*", "*What you will see*")], "no `*In this demo*`"),
    ("no-steps", [("=== 1 · First step — 3 min", "=== First step"),
                  ("=== 2 · Second step — 4 min", "=== Second step")], "no numbered steps"),
    ("no-faq", [("== Frequently asked questions", "== Questions")],
     "no `== Frequently asked questions`"),
    ("order", [(TITLE + "\n" + PREP, PREP + "\n" + TITLE)], "out of order"),
    ("numbering", [("=== 2 · Second step — 4 min", "=== 3 · Second step — 4 min")],
     "step numbers must run"),
    ("minutes", [("== Canary demo · 7 min", "== Canary demo · 9 min")], "add up to"),
    ("step-without-visual", [('image::demo-canary/demo-canary-02-first.svg["The first screenshot."]\n\n', "")],
     "must carry exactly one visual"),
    ("step-without-why", [("*Why it matters*\n\nWhy the second step matters.\n\n", "")],
     "has no *Why it matters*"),
    ("repeat", [("image::demo-canary/demo-canary-02-first.svg", "image::demo-canary/demo-canary-01-overview.svg")],
     "used twice"),
    ("render-and-source", [("diagrams/demo-canary/03-second.mmd", "diagrams/demo-canary/01-overview.mmd")],
     "used twice"),
    ("missing-file", [("image::demo-canary/demo-canary-02-first.svg", "image::demo-canary/demo-canary-09-gone.svg")],
     "does not exist"),
    ("user-flag", [("ws prep demo-canary\n", "ws prep demo-canary --user {user}\n")], "--user in a click-to-run"),
    ("adm", [("oc get pods -n {user}-dev\n", "oc get pods -n {user}-dev\nadm verify demo-canary\n")],
     "adm in a click-to-run"),
    ("adm-solve", [("ws prep demo-canary\n", "adm solve demo-canary\n")],
     None if ADM_SOLVE_CLICK_TO_RUN else "adm in a click-to-run"),
    # `oc adm` must stay silent — the rule is about the workshop tool, not the oc subcommand.
    ("oc-adm-allowed", [("oc get pods -n {user}-dev\n", "oc adm policy who-can create pods -n {user}-dev\n")], None),
    ("thin-faq", [("*The third question?*::\nThe third answer.\n", "")], "fewer than 3 questions"),
]


def _drive(root: Path) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = main([str(root)])
    return rc, buf.getvalue()


def self_test() -> int:
    control = CANARY_DIR / "control"
    if not (control / PAGE).is_file():
        print(f"❌ SELF-TEST FAILED: fixture missing at {control / PAGE}", file=sys.stderr)
        return 2
    problems = []
    rc, out = _drive(control)
    if rc != 0 or "clean" not in out:
        problems.append(f"[control] expected rc=0 and clean, got rc={rc}: {out.strip()[:300]!r}")
    original = (control / PAGE).read_text(encoding="utf-8")
    for case, edits, needle in MUTATIONS:
        text = original
        for old, new in edits:
            if old not in text:
                problems.append(f"[{case}] the edit did not land: {old[:50]!r} is not in the fixture")
            text = text.replace(old, new, 1)
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "tree"
            shutil.copytree(control, tree)
            (tree / PAGE).write_text(text, encoding="utf-8")
            rc, out = _drive(tree)
        findings = [line for line in out.splitlines() if line.startswith("  • ")]
        if needle is None:
            if rc != 0:
                problems.append(f"[{case}] expected clean, got rc={rc}: {findings!r}")
        elif rc != 1 or len(findings) != 1 or needle not in findings[0]:
            problems.append(f"[{case}] expected exactly one finding naming {needle!r}, got rc={rc}: "
                            f"{findings!r}")
    if _drive(REPO)[0] == 2:
        problems.append("[real-tree] the guard could not inspect the repository (rc=2); a clean "
                        "fixture run proves nothing about it.")
    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2
    print(f"✅ self-test ok — the known-good page is clean, and each of {len(MUTATIONS)} small edits "
          f"produces exactly its own finding and no other.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
