#!/usr/bin/env python3
"""attribute-interpolation-guard.py — an attribute written into a block that cannot interpolate it
renders as literal text to the attendee.

ORIGIN (2026-08-05, during the F-01 sweep). Two testers reported hardcoded usernames in
attendee-facing expected output: a reader whose namespace is `user6-dev` was shown output naming
`user2-dev`. The obvious fix is to template it — write `{user}-dev` and let Antora substitute.

That fix is a TRAP, and measuring it is what produced this guard. An AsciiDoc delimited block does
NOT substitute attributes unless its header opts in:

    [source,texinfo]                      <- `{user}-dev` renders as the LITERAL TEXT "{user}-dev"
    [source,texinfo,subs="attributes"]    <- `{user}-dev` renders as "user6-dev"

Measured on the shipped tree before this guard existed: of the blocks containing a rendered `userN`,
only 4 already carried `subs=`. So a well-meant sweep across the remaining ~124 candidates would have
replaced a wrong-but-plausible namespace name with visible template syntax — strictly worse, because
`user2-dev` at least looks like a namespace while `{user}-dev` looks like the workshop is broken.

WHAT IT CHECKS:
  [1] LITERAL LEAK, over every tracked .adoc page. A block WITHOUT `subs=` whose body contains a
      DECLARED attribute reference. The attendee would see the braces. This is the failure a naive
      F-01 sweep introduces.
  [2] DIAGRAM LEAK, over every tracked .mmd file. Mermaid diagrams are pulled in through
      `[mermaid]` + a `....` LITERAL block, which applies no substitution and accepts no `subs=`
      option — so an attribute reference in a .mmd can NEVER resolve, on any page, by construction.
      Found on the shipped tree 2026-08-05: five diagrams had been rendering the literal text
      "{user}-dev" to attendees since 2026-07-18, in 30 built files across the three renderings.
      Detector [1] could not see them because the .adoc block body is an `include::` line, not the
      diagram text. Fix by wording the label as an obvious placeholder ("your -dev namespace"),
      never by adding subs= — there is no header on that path to add it to.

A SECOND DETECTOR WAS BUILT AND DELIBERATELY REMOVED — do not re-add it without new evidence.
The idea was to flag the reverse mistake: `subs="attributes"` on a block containing braces that are
not attributes (JSON, jsonpath, awk), on the theory Asciidoctor would resolve and damage them. The
shipped tree falsifies it. 67 blocks already pair subs= with jsonpath such as
`{.data.aiPathAvailable}` and every Antora build is rc=0, because Asciidoctor only substitutes
references matching attribute-name syntax and leaves the rest alone. Narrowing it to "valid-looking
but undeclared" still produced 24 findings that are all fine: `{http_code}` and `{time_total}` are
curl -w formats that survive because the default attribute-missing is *skip*, and `{module-id}` reads
as undeclared only because this scanner does not resolve `include::` directives — the partial sets it.
Distinguishing real damage from those needs include resolution plus the attribute-missing setting,
which is Antora's job, not a grep's. A gate that cries wolf 24 times gets switched off, taking
detector [1] with it.

WHAT IT DELIBERATELY DOES NOT CHECK. Attribute references in ordinary prose (outside delimited
blocks) are substituted by default and need no opt-in — flagging those would fire on every page and
be trained away within a day.

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

# A delimited block opens and closes with a line of 4+ of the same delimiter char. `----` is the
# listing/source form these pages use; `....` is literal. Both interpolate only when told to.
BLOCK_DELIM = re.compile(r"^(-{4,}|\.{4,})\s*$")
# The attribute-list line immediately above a block, e.g. [source,texinfo] or [source,sh,role=execute]
ATTR_LINE = re.compile(r"^\[(source|listing|literal)[,\]]")
SUBS_OPT = re.compile(r"subs\s*=")

# An attribute reference: {name} or {name-with-dashes}. Deliberately narrow — no quotes, colons,
# spaces or braces inside — which is exactly what separates `{user}` from `{"namespace": "x"}`.
ATTR_REF = re.compile(r"\{([a-z][a-z0-9_-]*)\}")
# Any brace expression at all, used to find the JSON-ish ones.
ANY_BRACE = re.compile(r"\{[^}\n]{0,200}\}")

# KNOWN ATTRIBUTES ONLY. The first version of this guard flagged any `{lowercase-word}` and produced
# 136 findings, essentially all false: `{http_code}` is curl's -w format, `{end}`/`{print}`/`{next}`
# are awk program syntax, and those blocks are CORRECT precisely because they do not opt into
# substitution. "Any brace" cannot distinguish an attribute the author meant to interpolate from
# shell/awk/curl syntax that must stay literal — only the declared attribute set can.
#
# Derived at runtime from the two places attributes are actually declared, plus the page's own
# header, so the list cannot rot as attributes are added:
#   content/antora.yml                                   (asciidoc.attributes:)
#   content/modules/ROOT/partials/version-attributes.adoc (:name: value, generated from versions.yaml)
#   the scanned page's own `:name:` lines                (e.g. :module-id:)
_ANTORA_ATTR = re.compile(r"^\s{2,}([a-z][a-z0-9_-]*):\s")
# re.MULTILINE is load-bearing: scan() calls _PAGE_ATTR.finditer(raw) over a whole page to promote
# the page's own `:name:` declarations into its known set. Without it `^` matches only at offset 0,
# so a `:name:` line BELOW the `= Title` — i.e. on every real page — is never seen and the promotion
# is dead. It does not change the `.match(line)` use in declared_attributes(), which is already
# anchored at the start of each single line.
_PAGE_ATTR = re.compile(r"^:([a-z][a-z0-9_-]*):", re.MULTILINE)


def declared_attributes() -> set[str]:
    names: set[str] = set()
    antora = REPO / "content" / "antora.yml"
    if antora.exists():
        in_attrs = False
        for line in antora.read_text(errors="replace").splitlines():
            if re.match(r"^\s*attributes:\s*$", line):
                in_attrs = True
                continue
            if in_attrs:
                if line.strip() and not line.startswith(" "):
                    in_attrs = False
                    continue
                m = _ANTORA_ATTR.match(line)
                if m:
                    names.add(m.group(1))
    partial = REPO / "content" / "modules" / "ROOT" / "partials" / "version-attributes.adoc"
    if partial.exists():
        for line in partial.read_text(errors="replace").splitlines():
            m = _PAGE_ATTR.match(line)
            if m:
                names.add(m.group(1))
    return names


def attr_refs(text: str, known: set[str]) -> set[str]:
    """Attribute references the author plausibly MEANT to interpolate."""
    return {m.group(1) for m in ATTR_REF.finditer(text) if m.group(1) in known}




def blocks_of(lines: list[str]):
    """Yield (header, start_line, end_line, body_lines) for each delimited block."""
    header = ""
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if ATTR_LINE.match(line):
            header = line.rstrip("\n")
            i += 1
            continue
        m = BLOCK_DELIM.match(line.rstrip("\n"))
        if m:
            delim = m.group(1)[0]
            start = i
            body = []
            i += 1
            while i < n:
                m2 = BLOCK_DELIM.match(lines[i].rstrip("\n"))
                if m2 and m2.group(1)[0] == delim:
                    break
                body.append(lines[i])
                i += 1
            yield header, start + 1, i + 1, body
            header = ""
            i += 1
            continue
        if line.strip():
            header = ""  # a non-blank, non-delimiter line breaks the header/block adjacency
        i += 1


def scan(paths, known=None):
    if known is None:
        known = declared_attributes()
    leaks = []
    for p in paths:
        try:
            raw = p.read_text(errors="replace")
        except OSError:
            continue
        lines = raw.splitlines(keepends=True)
        # Page-local attributes (:module-id: …) count as declared for THIS page only.
        page_known = known | {m.group(1) for m in _PAGE_ATTR.finditer(raw)}
        rel = p.relative_to(REPO) if str(p).startswith(str(REPO)) else p
        for header, start, _end, body in blocks_of(lines):
            text = "".join(body)
            has_subs = bool(SUBS_OPT.search(header))
            refs = attr_refs(text, page_known)
            if refs and not has_subs:
                leaks.append((str(rel), start, header or "(no header)", sorted(refs)[:4]))
    return leaks


def tracked_mmds():
    """Diagram SOURCES and their exported renderings.

    Both are checked because they must agree: the project rule is that an exported SVG/PNG sits next
    to its editable .mmd, so a fix applied to only one of them is silently reverted by the next
    re-export. The 2026-08-05 incident needed both — five .mmd sources AND their five committed SVGs
    carried the same unresolvable {user}.
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", "--", "*.mmd", "*.svg"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
    except Exception:
        return []
    return [REPO / f for f in out if ".canary." not in f]


def scan_diagrams(paths, known=None):
    """Any declared-attribute reference in a .mmd is unresolvable — no header exists to opt in."""
    if known is None:
        known = declared_attributes()
    hits = []
    for p in paths:
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        rel = p.relative_to(REPO) if str(p).startswith(str(REPO)) else p
        for i, line in enumerate(text.splitlines(), 1):
            refs = attr_refs(line, known)
            if refs:
                hits.append((str(rel), i, sorted(refs), line.strip()[:70]))
    return hits


def tracked_adocs():
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", "--", "*.adoc"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
    except Exception:
        return []
    # Fixtures belonging to other guards are deliberately broken content — scanning them would
    # report another guard's canary as this guard's finding.
    return [REPO / f for f in out if ".canary." not in f]


def report(leaks, diagrams=()) -> int:
    rc = 0
    if diagrams:
        rc = 1
        print(f"❌ [2] {len(diagrams)} diagram line(s) reference an attribute that can NEVER resolve.")
        print("       Mermaid arrives through a `....` literal block, which applies no substitution")
        print("       and has no header to add subs= to. Reword the label as a plain placeholder.")
        for f, ln, refs, txt in diagrams[:20]:
            print(f"   {f}:{ln}  refs={refs}  {txt}")
    if leaks:
        rc = 1
        print(f"❌ [1] {len(leaks)} block(s) reference an attribute but cannot interpolate it —")
        print("       the attendee sees the literal braces. Add subs=\"attributes\" to the header,")
        print("       UNLESS the body contains JSON/brace output, in which case revert the")
        print("       templating and annotate the block instead.")
        for f, ln, hdr, refs in leaks[:25]:
            print(f"   {f}:{ln}  {hdr}  refs={refs}")
        if len(leaks) > 25:
            print(f"   … and {len(leaks) - 25} more")
    if rc == 0:
        print("✅ attribute interpolation: every block referencing a declared attribute opts into")
        print("   substitution — no attendee sees literal {braces}")
    return rc


FIXTURE_LEAK = """= Page
:module-id: demo

.Expected output
[source,texinfo]
----
Namespace:  {user}-dev
----
"""


# A PAGE-LOCAL attribute: declared with `:name:` BELOW the `= Title` (as on every real page) and
# absent from the global set. It reaches page_known ONLY through _PAGE_ATTR promotion in scan(),
# which needs re.MULTILINE to see a `:name:` line that is not at offset 0. Referenced in a block
# with no subs=, it is a real leak. The self-test scans it with known=set() so the ONLY thing that
# can catch it is that promotion — which is exactly what makes it a witness for _PAGE_ATTR.
FIXTURE_PAGE_LOCAL_LEAK = """= Getting Started
:region: emea-1

.Expected output
[source,texinfo]
----
Region:  {region}
----
"""


FIXTURE_CLEAN = """= Page

.Expected output
[source,texinfo,subs="attributes"]
----
Namespace:  {user}-dev
----

.Trace kept faithful
[source,texinfo]
----
args: {"namespace": "user3-dev"}
----

.jsonpath alongside subs= is FINE — Asciidoctor leaves invalid references alone
[source,sh,subs="attributes"]
----
oc get cm -n {user}-dev -o jsonpath='{.data.endpoint}'
----
"""


def self_test(tmpdir: Path) -> int:
    # Proof 0: a detector that fires on everything proves nothing — the clean fixture must pass.
    f = tmpdir / "clean.adoc"
    f.write_text(FIXTURE_CLEAN)
    leaks = scan([f])
    if leaks:
        print(f"❌ SELF-TEST FAILED: the CLEAN fixture was flagged (leaks={leaks}).")
        print("   A guard that fires on correct content will be disabled by the first person it annoys.")
        return 2

    # Canary A — the trap a naive F-01 sweep introduces: {user} in a block with no subs=.
    f = tmpdir / "leak.adoc"
    f.write_text(FIXTURE_LEAK)
    leaks = scan([f])
    if not leaks:
        print("❌ SELF-TEST FAILED: an attribute in a non-interpolating block was NOT detected —")
        print("   detector [1] is blind, and a sweep would ship visible {user} to attendees.")
        return 2

    # Canary C — witnesses _PAGE_ATTR. A page-local attribute declared with `:name:` BELOW the title
    # (so only re.MULTILINE promotion in scan() can see it), referenced in a block with no subs=.
    # Scanned with known=set() so the ONLY path to a hit is that promotion: blind _PAGE_ATTR and the
    # detection drops to zero, which is what proves the detector. It is deliberately a LEAK fixture,
    # not a clean one — the promotion is purely additive to the known set, so blinding it can only
    # make a leak DISAPPEAR, never appear; a clean fixture could not witness it. Before re.MULTILINE
    # this canary failed in the baseline, which is the point: it fixes and proves the page-local
    # promotion in one move.
    f = tmpdir / "page-local-leak.adoc"
    f.write_text(FIXTURE_PAGE_LOCAL_LEAK)
    if not scan([f], known=set()):
        print("❌ SELF-TEST FAILED: a page-local attribute ({region}, declared via :region: below the")
        print("   title) referenced in a non-subs block was NOT detected — _PAGE_ATTR promotion is")
        print("   blind, and a page interpolating its own attribute would ship literal {braces}.")
        return 2


    # Canary B — an attribute in a mermaid source, which no header can ever rescue.
    d = tmpdir / "diagram.mmd"
    d.write_text('flowchart LR\n  subgraph ns["{user}-dev — after the lab"]\n  end\n')
    if not scan_diagrams([d]):
        print("❌ SELF-TEST FAILED: an attribute reference in a .mmd was NOT detected — detector [2]")
        print("   is blind, and diagrams would keep rendering literal braces to attendees.")
        return 2
    d.write_text('flowchart LR\n  subgraph ns["your -dev namespace"]\n  end\n')
    if scan_diagrams([d]):
        print("❌ SELF-TEST FAILED: a correctly-worded .mmd was flagged — detector [2] cries wolf.")
        return 2

    # Proof 1: the guard must be able to SEE the real tree, or its clean verdict means nothing.
    real = tracked_adocs()
    if not real:
        print("❌ SELF-TEST FAILED: no tracked .adoc files found — the guard would pass by scanning nothing.")
        return 2

    print("✅ self-test ok — clean fixture silent (including jsonpath beside subs=); literal-leak,")
    print("   page-local-leak and diagram-leak canaries caught;")
    print(f"   {len(real)} tracked .adoc file(s) visible to the real scan.")
    return 1  # house convention: every canary caught == exit exactly 1


def main(argv=None) -> int:
    # argv is a PARAMETER, not read from sys.argv, because tools/lint/_canary-coverage.py drives
    # every guard by calling `mod.main(argv)` in-process to blind one detector at a time. A
    # zero-argument main() raises TypeError there, the sweep records "unmutated control ran 2/2",
    # and this guard's detectors go UNPROVEN while every job still looks green.
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
    leaks = scan(paths)
    mmds = tracked_mmds()
    diagrams = scan_diagrams(mmds)
    print(f"   scanned {len(paths)} tracked .adoc and {len(mmds)} diagram file(s)")
    return report(leaks, diagrams)


if __name__ == "__main__":
    sys.exit(main())
