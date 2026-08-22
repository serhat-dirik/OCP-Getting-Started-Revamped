#!/usr/bin/env python3
"""diagram-size-guard.py — mermaid diagrams may not regress to the shapes that render unreadable.

WHY THIS EXISTS (measured 2026-08-22). `content/supplemental-ui/partials/head-styles.hbs:41` sets,
on every rendered diagram:

    width: 100% !important; max-width: 900px !important; height: auto !important;

So a diagram's intrinsic size is IRRELEVANT to what an attendee sees: every SVG is stretched or
squashed to a 900px column, and only two derived numbers matter —

    displayed height = 900 x h/w        text scale = 900 / w

A narrow, tall diagram is therefore UPSCALED, not shrunk. One shipped example measured 286x969
intrinsic and rendered 900x3049 with its text at 3.15x — three metres of column for a wrap-up
picture, in cartoon-sized type. Measured in a browser via `mermaid.render()`: of 107 diagrams, 30
rendered over 500px tall, 14 had their text blown up past 1.6x, and 7 were shrunk below 0.6x — one
to a 66px sliver at 0.44x. The project owner noticed it by eye, in two separate modules, before any
of this was measured. That is the failure mode this guard exists to make mechanical: the defect is
obvious to a reader and invisible to every check we had.

WHAT THIS GUARD CANNOT DO, stated plainly so a green tick is never read as "the diagrams are the
right size". It CANNOT MEASURE PIXELS. Mermaid's layout is dagre running in a browser — node
dimensions come from real text metrics in a real font — and CI has no cheap way to run one. Nothing
below computes a width, a height, or a text scale. A diagram can clear every rule here and still
render as a 3000px column; only opening the built page, or the browser harness that produced the
figures above, can tell you the actual size. What this guard enforces is narrower and honest: three
AUTHORING PATTERNS whose link to those measurements was established in a browser, one edge at a time.

  ignored-direction  A `subgraph` that declares `direction` AND has an edge crossing its boundary.
                     `direction` is SILENTLY DISCARDED the moment any edge joins a node inside the
                     subgraph to anything outside it; mermaid falls back to the parent direction and
                     warns about nothing. Measured on two synthetic graphs identical but for one
                     edge: joined container-to-container (`A --> B`), `direction LR` honoured, 397x284.
                     Joined node-to-node across the boundary (`a4 --> b1`), `direction LR` ignored,
                     142x689. Confirmed end-to-end on a real file — moving ONE edge in
                     packaging-distributing/03-what-you-built.mmd from `oci --> sub` to `helm --> olm`
                     took it from 341x857 (displayed 900x2262, text 2.64x) to 969x356 (displayed
                     900x331, text 0.93x). One edge, a sevenfold change in displayed height.

                     This is the highest-signal finding of the three precisely because it names a
                     diagram whose AUTHOR ALREADY BELIEVES they fixed the layout. The `direction`
                     line is right there in the source, doing nothing. 21 of the 26 diagrams still
                     out of band on 2026-08-22 were in exactly that state.

  tall-label         A node label with 3 or more `<br/>` (four or more lines). Every extra line is a
                     height multiplier applied to a box that is already the tallest thing in its
                     rank, and it compounds with the rule above.

  wide-chain         More than 6 nodes in the longest link chain of an `LR`/`RL` diagram. Displayed
                     width is dagre RANKS, and the longest path is what sets the rank count. The
                     900px cap then scales that down: the diagrams measured at 0.44x text, including
                     the 66px sliver, are this shape.

WHY RULE 1 IS NOT "a TB subgraph with no `direction` line", which is where this guard started. That
version was both noisy and blind, and the browser measurement above is why. Blind, because the 21
worst offenders all HAVE a `direction` line — it is being discarded, so its presence proved nothing.
Noisy, because a subgraph with no `direction` in a diagram whose edges do not cross is frequently
fine: storage-stateful/02-sts-vs-deployment.mmd declares no `direction` anywhere and measures
perfectly well. A rule that misses the real defect while reddening correct work is the exact shape
that gets a guard switched off, and this directory's other docstrings say so at length.

WHY RULE 3 COUNTS EVERY LINK, not only the ones written outside a `subgraph`. Wrapping a run of
nodes in subgraphs does not remove a dagre rank — it draws a box around some of them — and, by rule
1's mechanism, a `direction TB` meant to stack that run into a column is discarded as soon as one
edge leaves the box. So "the chain is wrapped" is not evidence that the diagram is narrow, and an
earlier draft that filtered wrapped chains out scored app-security-testing/01-five-pillars.mmd clean
at eight ranks. Chain length is measured over every link the file declares, wherever it is declared.

WHAT IT DELIBERATELY DOES NOT FLAG, and why (the pushback is part of the design):

  * A subgraph with no `direction` line at all. Nothing is being discarded, because nothing was
    declared — see above. `r1-control-no-direction-declared.mmd` is the fixture holding that line.
  * A tall `graph TB` with no subgraph. It is genuinely tall, but its height comes from the
    top-level arrangement, which no subgraph `direction` can repair, and flagging it would prescribe
    a fix that does not exist.
  * An EDGE label (`-->|"a<br/>b<br/>c<br/>d"|`) with four lines. Edge labels sit BETWEEN ranks
    rather than inside a box, so they cost rank separation rather than a node's height, and there
    are zero of them in the corpus today. `EDGE_LABEL_RE` masks them before rule 2 looks. If
    four-line edge labels ever appear, that is a NEW rule with its own measurement, not a quiet
    widening of this one.

USAGE
    tools/lint/diagram-size-guard.py [path ...]   # default: content/modules/ROOT/examples/diagrams
    tools/lint/diagram-size-guard.py --self-test  # per-fixture canary assertions; MUST exit 1

`tools/lint/_parse-guard-args.sh` does NOT apply here and needs no exemption entry: its meta-scan
sweeps `tools/lint/*.sh`, and this is a Python guard. The contract it exists to enforce is met the
way the other twenty Python guards here meet it — argparse, which exits 2 on an unknown argument, so
a mistyped `--selftest` can never be mistaken for a proven self-test.

THE SELF-TEST IS PER-RULE AND PER-PATTERN, and it never exits 0. Each of the three detectors has its
own synthetic fixture that MUST fire, and each has near-miss controls that MUST stay silent — a
subgraph joined container-to-container, a subgraph that declares no `direction`, a subgraph whose
edges are all internal, a three-line label, a six-node chain, a seven-node chain in a TB diagram.
Those controls are what a naive implementation fails: "any subgraph with a crossing edge", "any file
containing `<br/>`", "any LR file with seven node ids" each pass all the canaries and fail the
controls. And because a detector can be silent for the wrong reason, every fixture also names ONE
module-level pattern and a mutation (`blind` / `flood`); the fixture's outcome must FLIP when that
pattern is mutated, or the fixture is reported as not testing what it claims. A blind rule, a false
positive on a control, a mutation that changes nothing, an uncovered rule, an uncovered pattern, a
breached scope floor and a missing fixture are ALL rc 2 — "the harness is broken" — never rc 0.
rc 1 is the pass.

The real-file control is `content/modules/ROOT/examples/diagrams/multi-tenancy-workload-security/
04-what-you-built.mmd`, reshaped on 2026-08-22 into two `direction LR` rows joined
container-to-container and measured at 1110x374. A synthetic fixture proves a detector FIRES; only a
real file that a human looked at, measured, and called good proves it stays quiet on real work.

AND A CRASH IS NOT A DETECTION. CI's contract is "--self-test must exit EXACTLY 1". Python exits 1
on an uncaught exception, so a broken guard would score as a proven one. Module-level failures, a
bad regex, an unimportable `_scope` and anything raised out of main() all exit 2 instead — the same
three-part shape every Python guard in this directory carries, for the same measured reason.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import itertools
import pathlib
import re
import sys


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    The `__main__` try/except below cannot help here: module-level code runs before `__main__`
    exists, so a bad constant or a failing import would crash with Python's default rc 1 — which is
    exactly what CI's `--self-test must exit EXACTLY 1` reads as "the canary fired". Installed as the
    first statement after the imports so it is in place before anything below it can fail. `os._exit`
    is what makes the code stick: an excepthook cannot change the exit status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::diagram-size-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad, not `except ImportError`
    # A `_scope.py` that fails to PARSE raises SyntaxError and sails past an ImportError-only
    # handler, exiting 1 — CI's "the canary fired". Anything at all going wrong while loading the
    # scope ledger means this guard cannot start, and that is rc 2 whichever exception said so.
    print(f"::error::diagram-size-guard: cannot import _scope ({exc}) — the guard could not start, "
          f"which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    Every pattern below is compiled at MODULE level, so a typo raises `re.error` before main() — and
    before any try/except inside it — can run. Python exits 1 on an uncaught exception, and 1 is
    exactly what CI's `--self-test must exit EXACTLY 1` assertion accepts as "the canary was
    detected". A regex is the likeliest thing to break in this file, so the compile step is where the
    exit code has to be fixed.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::diagram-size-guard: {name} is not a valid regex ({exc}) — the guard could "
              f"not load. Exiting 2: that is 'the guard is broken', not 'the canary fired'.",
              file=sys.stderr)
        sys.exit(2)


ROOT = pathlib.Path(__file__).resolve().parents[2]

# One directory per module slug, one .mmd per diagram. 107 files across 26 slugs on 2026-08-22.
DIAGRAM_ROOT = ROOT / "content/modules/ROOT/examples/diagrams"
DIAGRAM_GLOB = "*/*.mmd"

# ---------------------------------------------------------------------------------------------
# Structural patterns. Every one of these is read by the real run, and every one is named by a
# fixture below that proves mutating it flips an outcome — see MUTABLE_PATTERNS.
# ---------------------------------------------------------------------------------------------

# `%%` starts a mermaid comment and runs to end of line (including a `%%{init: …}%%` directive).
# Stripping it FIRST is load-bearing, not tidiness: this corpus carries long `%%` headers that
# explain the sizing fix, and one of them quotes an offending four-line label verbatim. Reading a
# comment as a diagram would flag the very note telling the next author how to keep it short.
COMMENT_RE = _compile("COMMENT_RE", r"%%.*$")

# `graph TB` / `flowchart LR` / … — the declared direction. Rule 3 needs it, and its absence means
# the file is not a flowchart at all, which is when every rule here stops applying.
HEADER_RE = _compile("HEADER_RE",
                     r"^\s*(?:graph|flowchart)\s+(?P<dir>TB|TD|BT|LR|RL)\b")

# `subgraph id["title"]`, `subgraph id`, or a bare `subgraph`.
SUBGRAPH_RE = _compile("SUBGRAPH_RE", r"^\s*subgraph\b\s*(?P<id>[A-Za-z_][A-Za-z0-9_-]*)?")

# The `end` that closes a subgraph. Bare on its own line in every diagram in this tree.
END_RE = _compile("END_RE", r"^\s*end\s*$")

# `direction LR` inside a subgraph — the line rule 1 is about. Its PRESENCE is what makes a
# boundary-crossing edge a finding: without it, nothing is being discarded.
DIRECTION_RE = _compile("DIRECTION_RE", r"^\s*direction\s+(?P<dir>TB|TD|BT|LR|RL)\b")

# A line break inside a label. Mermaid accepts `<br>`, `<br/>` and `<br />`; this corpus uses
# `<br/>` exclusively today, and matching all three keeps a future author's variant in scope.
LABEL_BREAK_RE = _compile("LABEL_BREAK_RE", r"<br\s*/?>", re.IGNORECASE)

# An edge label, `-->|"…"|`. Masked before anything else reads the line: rule 2 is about NODE
# labels, and the chain walk must not find link syntax inside prose — this corpus really does write
# `-->|"oc set volume --overwrite"|`, and `--o` is a link operator.
EDGE_LABEL_RE = _compile("EDGE_LABEL_RE", r"\|[^|\n]*\|")

# Every link operator this corpus uses: `-->` `---` `-.->` `-.-` `-.text.->` `==>` `~~~` `<-->`,
# plus the `o`/`x` endings mermaid allows. Node labels are masked before this runs, so an ellipsis
# or a `==` inside a label ("prod == 1.0", "scales 0..N") can never be mistaken for a link.
EDGE_SPLIT_RE = _compile("EDGE_SPLIT_RE", r"""(?x)
      <?-\.[^.\n|]*\.-[->ox]?      # -.owns.->            (dotted link carrying an inline label)
    | <?-\.-*[->ox]?               # -.->  -.-
    | <?-{2,}[->ox]?               # -->   ---   --o   --x   <-->
    | <?={2,}[=>ox]?               # ==>   ===
    | ~{3,}                        # ~~~                  (invisible layout link)
""")

# The identifier at the head of a node reference: `payments-ci` out of `payments-ci["…"]`.
NODE_ID_RE = _compile("NODE_ID_RE", r"^[A-Za-z_][A-Za-z0-9_-]*")

# ---------------------------------------------------------------------------------------------
# Thresholds. Each is a BOUNDARY a control fixture sits exactly on, so an off-by-one is a failing
# self-test rather than a silent widening: three lines is fine and four is not; six nodes is fine
# and seven is not.
# ---------------------------------------------------------------------------------------------

MAX_LABEL_BREAKS = 2          # 2 `<br/>` = 3 lines = fine. 3 = 4 lines = the height multiplier.
MAX_CHAIN_NODES = 6           # 6 ranks across a 900px column is legible. 7 is the ~2000px shape.

RULE_IGNORED_DIRECTION = "ignored-direction"
RULE_TALL_LABEL = "tall-label"
RULE_WIDE_CHAIN = "wide-chain"
RULES = (RULE_IGNORED_DIRECTION, RULE_TALL_LABEL, RULE_WIDE_CHAIN)

# Every pattern a fixture is allowed to mutate. This is a COVERAGE requirement, not a list of
# conveniences: --self-test fails if any entry here is named by no fixture, which is what stops a
# new pattern shipping with nothing to notice when it stops working.
MUTABLE_PATTERNS = (
    "COMMENT_RE", "HEADER_RE", "SUBGRAPH_RE", "END_RE", "DIRECTION_RE",
    "LABEL_BREAK_RE", "EDGE_LABEL_RE", "EDGE_SPLIT_RE", "NODE_ID_RE",
)


def _is_horizontal(direction: str) -> bool:
    """Does this direction lay ranks out left-to-right, so that rank COUNT is the displayed width?

    A module-level predicate rather than an inline comparison so `_canary-coverage.py` can force it
    to a constant and prove it decides something: forced True, the TB seven-chain control fires;
    forced False, every rule-3 canary goes silent. Either way an exit code moves.
    """
    return direction in ("LR", "RL")


# ---------------------------------------------------------------------------------------------
# Lexing. Mermaid is not YAML and has no parser we can import, so this is a small hand scanner —
# deliberately conservative: anything it cannot make sense of yields nothing rather than guessing.
# ---------------------------------------------------------------------------------------------

def _label_spans(text: str):
    """Yield (open_index, close_index) for each node-label region on one line.

    A node label is a balanced bracket run — `[…]`, `(…)`, `{…}` and every compound mermaid builds
    from them (`([…])`, `[(…)]`, `{{…}}`, `[/…/]`) — introduced by an identifier character. Depth is
    counted across all three bracket kinds at once, which is what makes `DB[(PostgreSQL 15)]` one
    span instead of two, and quoted text suspends counting so a label may legally contain a bracket.

    An unbalanced line stops the scan: a diagram mermaid itself cannot parse is not this guard's
    finding to report, and guessing at its structure is how a linter invents offenders.
    """
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch in "[({" and i > 0 and (text[i - 1].isalnum() or text[i - 1] in "_-"):
            depth, j, in_quote = 0, i, False
            while j < n:
                c = text[j]
                if in_quote:
                    if c == '"':
                        in_quote = False
                elif c == '"':
                    in_quote = True
                elif c in "[({":
                    depth += 1
                elif c in "])}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= n or depth != 0:
                return                       # unterminated: stop, do not guess
            yield (i, j)
            i = j + 1
            continue
        i += 1


def _node_decls(text: str):
    """Yield (node_id | None, label_text) for every NODE declaration on one comment-stripped line.

    Edge labels are masked first — see EDGE_LABEL_RE. The surviving shape punctuation (`(`, `/`,
    `"`, …) is stripped off both ends so `([You])`, `[[You]]` and `{{"You"}}` all reduce to `You`.
    The id is the identifier run immediately before the opening delimiter, validated through
    NODE_ID_RE so `4x["…"]` yields no id rather than a wrong one; rule 1 uses those ids to work out
    which nodes are inside which subgraph.
    """
    masked = EDGE_LABEL_RE.sub(lambda m: " " * len(m.group(0)), text)
    for start, stop in _label_spans(masked):
        head = start
        while head > 0 and (masked[head - 1].isalnum() or masked[head - 1] in "_-"):
            head -= 1
        candidate = masked[head:start]
        m = NODE_ID_RE.match(candidate)
        node_id = m.group(0) if m and m.group(0) == candidate else None
        yield (node_id, masked[start + 1:stop].strip('[](){}/\\" '))


def _mask_labels(text: str) -> str:
    """The line with every edge and node label blanked, leaving node ids and link operators.

    Without this, EDGE_SPLIT_RE would find links inside prose: this corpus really does contain
    `proof["prod == 1.0"]` and `kpa{{"scale 0..3"}}`, and `==` and `..` are link syntax.
    """
    masked = EDGE_LABEL_RE.sub(lambda m: " " * len(m.group(0)), text)
    out = list(masked)
    for start, stop in _label_spans(masked):
        for k in range(start, stop + 1):
            out[k] = " "
    return "".join(out)


def _segment_ids(segment: str):
    """The node ids in one segment between two link operators.

    `&` is mermaid's multi-target separator — `DEP --> POD1 & POD2 & POD3` is three links, not one —
    so a segment can name several nodes. Splitting on it is what keeps POD2 and POD3 in their
    subgraph's membership set, which rule 1 needs to decide whether an edge crosses a boundary.
    """
    ids = []
    for part in segment.split("&"):
        m = NODE_ID_RE.match(part.strip())
        if m:
            ids.append(m.group(0))
    return ids


def _edges(text: str):
    """Yield (source_id, target_id) for every link on one line, including `A --> B --> C` chains."""
    masked = _mask_labels(text)
    if not EDGE_SPLIT_RE.search(masked):
        return
    groups = [_segment_ids(part) for part in EDGE_SPLIT_RE.split(masked)]
    for left, right in zip(groups, groups[1:]):
        yield from itertools.product(left, right)


class Diagram:
    """One parsed .mmd: its declared direction, its subgraphs, its labels and every link it draws.

    Everything the three rules need is collected in ONE pass, so a rule can never disagree with
    another about which nodes were inside which subgraph.
    """

    def __init__(self):
        self.direction = ""
        self.header_line = 0
        self.subgraphs = []      # (line_no, name, has_direction, frozenset(member ids))
        self.labels = []         # (line_no, label_text)  — top level and inside subgraphs alike
        self.edges = []          # (line_no, src, dst)    — EVERY link, wherever it was declared


def parse(text: str) -> Diagram:
    """Walk one diagram's source, tracking subgraph depth with a stack.

    A frame is `[line_no, name, has_direction, {member ids}]`. Membership is TRANSITIVE: when a
    subgraph closes, its members and its own name are folded into its parent, because a node two
    levels down is still inside the outer box and an edge reaching it still crosses that boundary.

    FIRST MENTION PLACES THE NODE, and nothing moves it afterwards — this is mermaid's own rule, and
    getting it wrong makes rule 1 blind rather than merely imprecise. `a2 --> b1` written at the top
    level must NOT drag `a2` out of its subgraph, or the edge would have both endpoints outside and
    no boundary would ever look crossed. `placed` is what enforces that.
    """
    doc = Diagram()
    stack = []
    placed: set[str] = set()

    def place(node_id):
        """Assign a node to the box it is first mentioned in. A later mention changes nothing."""
        if node_id in placed:
            return
        placed.add(node_id)
        if stack:
            stack[-1][3].add(node_id)

    for n, raw in enumerate(text.splitlines(), 1):
        line = COMMENT_RE.sub("", raw)
        if not line.strip():
            continue

        if not doc.direction:
            head = HEADER_RE.match(line)
            if head:
                doc.direction = head.group("dir")
                doc.header_line = n
                continue

        sub = SUBGRAPH_RE.match(line)
        if sub:
            name = sub.group("id") or f"(unnamed, line {n})"
            # The container belongs to its PARENT, not to itself — that is what makes a
            # container-to-container link (`A --> B`) touch neither membership set. It is recorded
            # as placed here so a later `A --> B` cannot re-file it into whatever box is open then.
            placed.add(name)
            stack.append([n, name, False, set()])
            # The title is still a label, and a four-line subgraph title inflates the box the same
            # way a four-line node label inflates a node.
            for _, label in _node_decls(line):
                doc.labels.append((n, label))
            continue

        if END_RE.match(line):
            if stack:
                line_no, name, has_direction, members = stack.pop()
                doc.subgraphs.append((line_no, name, has_direction, frozenset(members)))
                if stack:
                    stack[-1][3].update(members)
                    stack[-1][3].add(name)
            continue

        direction = DIRECTION_RE.match(line)
        if direction:
            if stack:
                stack[-1][2] = True
            continue

        for node_id, label in _node_decls(line):
            doc.labels.append((n, label))
            if node_id:
                place(node_id)

        for a, b in _edges(line):
            doc.edges.append((n, a, b))
            place(a)
            place(b)

    # An unterminated subgraph still describes a box; report it rather than drop it.
    while stack:
        line_no, name, has_direction, members = stack.pop()
        doc.subgraphs.append((line_no, name, has_direction, frozenset(members)))
        if stack:
            stack[-1][3].update(members)
            stack[-1][3].add(name)
    return doc


def _crossing_edge(members, edges):
    """The first link with exactly ONE endpoint inside `members`, or None.

    This is rule 1's whole mechanism. A link between two CONTAINERS (`A --> B`) touches neither
    membership set, so it is not a crossing and `direction` survives — measured at 397x284. A link
    that joins a node inside the box to anything outside it (`a4 --> b1`) is a crossing, and mermaid
    silently discards the box's `direction` — the same graph, measured at 142x689.
    """
    for line_no, src, dst in edges:
        if (src in members) != (dst in members):
            return (line_no, src, dst)
    return None


def _longest_chain(edges):
    """The longest run of distinct nodes reachable through `edges`, as a list of ids.

    Memoised depth-first longest path — the rank count dagre will produce, which in an LR diagram is
    the displayed width. A `visiting` set breaks cycles by treating a back-edge as a dead end: on a
    cyclic diagram the answer is a LOWER bound, which is the conservative direction, since this
    guard would rather miss a finding than invent one.
    """
    adjacency: dict[str, list[str]] = {}
    nodes: list[str] = []
    for _, a, b in edges:
        for node in (a, b):
            if node not in adjacency:
                adjacency[node] = []
                nodes.append(node)
        adjacency[a].append(b)

    memo: dict[str, list[str]] = {}
    visiting: set[str] = set()

    def best_from(node):
        if node in memo:
            return memo[node]
        if node in visiting:
            return [node]
        visiting.add(node)
        best = [node]
        for nxt in adjacency[node]:
            candidate = [node] + best_from(nxt)
            if len(candidate) > len(best):
                best = candidate
        visiting.discard(node)
        memo[node] = best
        return best

    longest: list[str] = []
    for node in nodes:
        candidate = best_from(node)
        if len(candidate) > len(longest):
            longest = candidate
    return longest


# ---------------------------------------------------------------------------------------------
# The three detectors. One `yield` per rule, so `_canary-coverage.py` can no-op each emission site
# independently and watch exactly one fixture go quiet.
# ---------------------------------------------------------------------------------------------

def find_offenders(path: pathlib.Path):
    """Yield (line_no, rule, message) for each finding in one .mmd file."""
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return
    doc = parse(text)
    if not doc.direction:
        return                       # not a flowchart (or not a diagram at all): nothing to say

    # Rule 1 — a `direction` mermaid is throwing away.
    for line_no, name, has_direction, members in sorted(doc.subgraphs):
        if not has_direction:
            continue                 # nothing declared, so nothing is being discarded
        crossing = _crossing_edge(members, doc.edges)
        if crossing:
            edge_line, src, dst = crossing
            yield (line_no, RULE_IGNORED_DIRECTION,
                   f"subgraph {name} declares `direction`, and the edge `{src} --> {dst}` on line "
                   f"{edge_line} crosses its boundary — so mermaid DISCARDS that direction and "
                   f"falls back to the parent's, with no warning. Measured: the same graph joined "
                   f"container-to-container renders 397x284, joined node-to-node 142x689. Join the "
                   f"containers instead (`{name} --> <other subgraph>`), or drop the `direction` "
                   f"line so the source stops claiming a layout it does not get.")

    # Rule 2 — a node label with four or more lines.
    for line_no, label in doc.labels:
        breaks = len(LABEL_BREAK_RE.findall(label))
        if breaks > MAX_LABEL_BREAKS:
            shown = label if len(label) <= 70 else label[:67] + "..."
            yield (line_no, RULE_TALL_LABEL,
                   f"node label has {breaks} `<br/>` ({breaks + 1} lines, max "
                   f"{MAX_LABEL_BREAKS + 1}): {shown!r}. Every line multiplies the height of the "
                   f"tallest box in its rank. Cut it to two or three lines, or split the node.")

    # Rule 3 — too many dagre ranks in a diagram whose ranks run left to right.
    if _is_horizontal(doc.direction):
        chain = _longest_chain(doc.edges)
        if len(chain) > MAX_CHAIN_NODES:
            head = chain[0]
            line_no = next((n for n, a, _ in doc.edges if a == head), doc.header_line)
            yield (line_no, RULE_WIDE_CHAIN,
                   f"{len(chain)} nodes in the longest `{doc.direction}` chain (max "
                   f"{MAX_CHAIN_NODES}): {' -> '.join(chain)}. Displayed width is dagre ranks, and "
                   f"a subgraph does not remove one — that renders around 2000px wide and the 900px "
                   f"cap scales it DOWN, which is the shape measured at 0.44x text. Break the run, "
                   f"or stack it as rows under a `TB` parent joined container-to-container.")


# ---------------------------------------------------------------------------------------------
# Scope. A guard that silently inspects nothing reports "clean" forever.
# ---------------------------------------------------------------------------------------------

def require_tree_floors(scope: Scope, include_parsed: bool = True) -> None:
    """The floors a WHOLE-CORPUS run must clear, declared once so the real run and --self-test can
    never disagree about what "enough" means.

    THREE DIMENSIONS, BECAUSE THEY FAIL AT DIFFERENT PLACES. "module directories" is recorded by the
    glob's grouping, "files collected" inside the walk, and "diagrams parsed" downstream of
    collect_diagrams' RETURN — a truncation applied at the return increments every counter in the
    walk and still hands back one file, so only a counter past it can tell the two apart.
    """
    scope.require("module directories", 20,
                  "the diagram corpus is one directory per module slug and modules.yaml lists ~26. "
                  "A floor of 20 survives a module being split or retired; it cannot be met by a "
                  "walk that collapsed to one slug's directory.")
    scope.require("files collected", 80,
                  "107 .mmd files on 2026-08-22, and the largest single module directory holds 5. "
                  "A floor of 80 therefore survives ordinary editing but cannot be met by any "
                  "single directory — so a walk truncated to one module, or to one file, fails "
                  "instead of reporting a confident 'clean'.")
    if include_parsed:
        scope.require("diagrams parsed", 80,
                      "recorded by the loop that hands each file to the detectors, NOT by the walk. "
                      "Collecting 107 files and parsing 1 is a clean-looking run over nothing.")


def collect_diagrams(roots, scope=None):
    """Resolve `roots` (files and/or directories) to the .mmd files to scan.

    Counts are incremented HERE, inside the loop that does the work, rather than from a `len(...)`
    at the call site: a length taken beside the walk is satisfied by a walk that never ran.
    """
    files = []
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            files.append(p)
            if scope is not None:
                scope.add("files collected")
        elif p.is_dir():
            seen_dirs = set()
            for f in sorted(p.glob(DIAGRAM_GLOB)):
                files.append(f)
                if scope is not None:
                    scope.add("files collected")
                    if f.parent not in seen_dirs:
                        seen_dirs.add(f.parent)
                        scope.add("module directories")
    return files


# ---------------------------------------------------------------------------------------------
# Self-test. Per rule, per control, per pattern. "Something fired" is not evidence about anything.
# ---------------------------------------------------------------------------------------------

CANARY_DIR = pathlib.Path(__file__).resolve().parent / "diagram-size-guard.canary"

# The real file a human looked at, measured at 1110x374, and called good. A synthetic fixture proves
# a detector FIRES; only real work proves it stays quiet on real work.
REAL_CONTROL = DIAGRAM_ROOT / "multi-tenancy-workload-security/04-what-you-built.mmd"

# A mutation is how a fixture proves it is testing what it names: blind the pattern (match nothing)
# or flood it (match everything), and the fixture's outcome must FLIP.
NEVER_MATCH = _compile("NEVER_MATCH", r"(?!)")
ALWAYS_MATCH = _compile("ALWAYS_MATCH", r"")

# %% EXPECT: <rule|none> | <blind|flood|-> <PATTERN_NAME> — prose
EXPECT_RE = _compile("EXPECT_RE",
                     r"^%%\s*EXPECT:\s*(?P<rule>[a-z-]+)\s*\|\s*(?P<mode>blind|flood|-)"
                     r"\s*(?P<pattern>[A-Z_]*)")

# %% MUST-FIRE — declares that the next non-comment line is the offender. Deferred to the NEXT line
# because mermaid comments must own their line: a trailing `%%` inside a node label is diagram text,
# not a comment, so a marker cannot sit on the line it describes.
MUST_FIRE_RE = _compile("MUST_FIRE_RE", r"^%%\s*MUST-FIRE\s*$")


def _fixture_contract(path: pathlib.Path):
    """Read one fixture's declared contract: (rule|None, mode, pattern, must_fire_lines)."""
    lines = path.read_text(encoding="utf-8").splitlines()
    rule = mode = pattern = None
    for line in lines:
        m = EXPECT_RE.match(line.strip())
        if m:
            rule = None if m.group("rule") == "none" else m.group("rule")
            mode = m.group("mode")
            pattern = m.group("pattern") or None
            break
    must_fire = set()
    pending = False
    for n, line in enumerate(lines, 1):
        if MUST_FIRE_RE.match(line.strip()):
            pending = True
            continue
        if pending and line.strip() and not line.strip().startswith("%%"):
            must_fire.add(n)
            pending = False
    return rule, mode, pattern, must_fire


def _mutate(name, mode):
    """Swap a module-level pattern for a never/always-matching one; returns the original."""
    original = globals()[name]
    globals()[name] = NEVER_MATCH if mode == "blind" else ALWAYS_MATCH
    return original


def self_test():  # noqa: C901 — one linear proof per fixture reads better than five helpers
    """Assert every fixture INDIVIDUALLY, then prove each one's named pattern is load-bearing.

    Exit 1 = every canary fired on exactly its declared line with exactly its declared rule, every
    control stayed silent, mutating each named pattern flipped its fixture, every rule and every
    pattern is covered, the real-file control is clean, and the real corpus still clears the scope
    floors. Exit 2 = any of those is false. Never 0: "the guard found nothing in self-test mode" is
    a blind guard, not a pass.
    """
    problems: list[str] = []

    if not CANARY_DIR.is_dir():
        print(f"❌ SELF-TEST FAILED: the fixture directory {CANARY_DIR} is missing — there is "
              f"nothing to prove the detectors with.", file=sys.stderr)
        return 2

    fixtures = sorted(CANARY_DIR.glob("*.mmd"))
    if not fixtures:
        print(f"❌ SELF-TEST FAILED: {CANARY_DIR} holds no .mmd fixtures.", file=sys.stderr)
        return 2

    covered_rules, covered_patterns = set(), set()
    offending, quiet = [], []
    for fixture in fixtures:
        rule, mode, pattern, must_fire = _fixture_contract(fixture)
        (offending if rule else quiet).append(fixture)
        name = fixture.name
        if mode is None:
            problems.append(f"fixture {name!r} carries no `%% EXPECT:` line — an unasserted fixture "
                            f"is decorative, which is the defect this self-test exists to remove")
            continue
        if pattern and pattern not in MUTABLE_PATTERNS:
            problems.append(f"fixture {name!r} names {pattern}, which is not one of this guard's "
                            f"mutable patterns {MUTABLE_PATTERNS}")
            continue
        if rule and rule not in RULES:
            problems.append(f"fixture {name!r} expects rule {rule!r}, which this guard cannot emit "
                            f"(it emits {list(RULES)})")
            continue
        if rule and not must_fire:
            problems.append(f"fixture {name!r} expects {rule!r} but marks no line `%% MUST-FIRE` — "
                            f"'a finding somewhere in the file' does not say which line is the "
                            f"defect, and that is how a fixture stops testing what it claims to")
            continue
        if not rule and must_fire:
            problems.append(f"control fixture {name!r} says `EXPECT: none` yet marks a "
                            f"`%% MUST-FIRE` line — the contract contradicts itself")
            continue

        base = list(find_offenders(fixture))
        base_lines = {line_no for line_no, _, _ in base}
        base_rules = {found for _, found, _ in base}

        if rule:
            if rule not in base_rules:
                problems.append(f"[blind rule] fixture {name!r} produced no {rule!r} finding — that "
                                f"detector is broken, and another rule firing in another fixture "
                                f"would have masked it")
            if base_rules - {rule}:
                problems.append(f"[cross-talk] fixture {name!r} also produced "
                                f"{sorted(base_rules - {rule})}, so a pass here would not be "
                                f"evidence about {rule!r}")
            for line_no in sorted(must_fire - base_lines):
                problems.append(f"[wrong line] {name}:{line_no} is marked `%% MUST-FIRE` and the "
                                f"guard did not flag it")
            for line_no in sorted(base_lines - must_fire):
                problems.append(f"[stray] {name}:{line_no} was flagged but carries no "
                                f"`%% MUST-FIRE` marker")
            covered_rules.add(rule)
        elif base:
            problems.append(f"[false positive] control fixture {name!r} must stay SILENT but "
                            f"produced {len(base)} finding(s) — first at line {base[0][0]}: "
                            f"{base[0][2]}")

        if mode != "-" and pattern:
            original = _mutate(pattern, mode)
            try:
                mutated_rules = {found for _, found, _ in find_offenders(fixture)}
            finally:
                globals()[pattern] = original
            if rule:
                if rule in mutated_rules:
                    problems.append(f"[detector not load-bearing] fixture {name!r} still reported "
                                    f"{rule!r} with {pattern} {mode}ed — the fixture is not testing "
                                    f"{pattern}")
            elif not mutated_rules:
                problems.append(f"[control not load-bearing] fixture {name!r} stayed silent even "
                                f"with {pattern} {mode}ed — its silence is an accident, so it "
                                f"proves nothing about {pattern}")
            covered_patterns.add(pattern)

        state = rule if rule else "silent"
        proof = f"{mode} {pattern}" if pattern and mode != "-" else "baseline only"
        print(f"   [{state:>18}] {name}  ({proof})")

    # Coverage: a rule or a pattern with no fixture naming it has no evidence behind it at all.
    for missing in sorted(set(RULES) - covered_rules):
        problems.append(f"[uncovered] rule {missing!r} is never asserted by any fixture")
    for missing in sorted(set(MUTABLE_PATTERNS) - covered_patterns):
        problems.append(f"[uncovered] pattern {missing} is never mutated by any fixture — nothing "
                        f"would notice if it stopped working")

    # The real-file control. The synthetic fixtures prove the detectors fire; this proves they do
    # not fire on a diagram a human reshaped and measured at 1110x374 on 2026-08-22.
    if not REAL_CONTROL.is_file():
        problems.append(f"[control missing] {REAL_CONTROL} is gone — the one real file proving "
                        f"these rules pass real work is no longer there to prove it")
    else:
        real = list(find_offenders(REAL_CONTROL))
        if real:
            problems.append(f"[false positive] the real-file control {REAL_CONTROL.name} produced "
                            f"{len(real)} finding(s) — first at line {real[0][0]}: {real[0][2]}. "
                            f"Either the file regressed or a rule got too broad; a guard that "
                            f"reddens on correct work is a guard that gets switched off.")

    # Proof for main()'s OWN scan loop and report path, driven end to end rather than around.
    #
    # WHY THIS EXISTS (measured 2026-08-22 with `_canary-coverage.py --guard diagram-size-guard.py`):
    # every assertion above calls `find_offenders` directly, so no-op'ing the `findings.append` in
    # main() left the plain run at 0 on a clean corpus and this self-test at 1 — 19 of 20 detectors
    # proven and the twentieth able to stop working with no CI signal at all. The guard would have
    # reported "clean" over a tree full of offenders and both CI lights would have stayed green.
    # Driving the real entry point with the fixtures is the only thing that can witness it.
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        rc_offending = main([str(p) for p in offending]) if offending else None
        rc_quiet = main([str(p) for p in quiet]) if quiet else None
    if rc_offending != 1:
        problems.append(f"[cli] `diagram-size-guard.py <{len(offending)} canary fixture(s)>` exited "
                        f"{rc_offending}, not 1. find_offenders can be perfect and still report "
                        f"nothing if main()'s own scan loop or its report path is broken.")
    if rc_quiet != 0:
        problems.append(f"[cli] `diagram-size-guard.py <{len(quiet)} control fixture(s)>` exited "
                        f"{rc_quiet}, not 0 — the clean branch of the real entry point is broken.")

    # The ledger mechanism itself, exercised by this CI job rather than trusted.
    problems += Scope.self_check()

    # Proof for collect_diagrams' explicitly-named-file branch. Every other call here and in main()
    # hands it a DIRECTORY, so `guard.py one.mmd` — the pre-commit shape — is reachable and proven
    # by nothing else.
    named = collect_diagrams([REAL_CONTROL])
    if named != [REAL_CONTROL]:
        problems.append(f"[scope] collect_diagrams([{REAL_CONTROL}]) returned {named!r} — the "
                        f"explicitly-named-file branch is broken")

    # Proof 0 — the real corpus still clears this guard's own floors, AND collect_diagrams still
    # records what it walked. A count recorded nowhere fails the floor exactly like a walk that
    # never ran, which is what makes a truncated or unwired walk visible from --self-test.
    tree = Scope("diagram-size-guard/real-tree")
    require_tree_floors(tree, include_parsed=False)
    returned = collect_diagrams([DIAGRAM_ROOT], scope=tree)
    for shortfall in tree.shortfalls():
        problems.append(f"[scope] the diagram corpus no longer clears this guard's own floor — "
                        f"{shortfall}")
    collected = tree.get("files collected")
    if len(returned) != collected:
        problems.append(f"[scope] collect_diagrams RECORDED {collected} file(s) but RETURNED "
                        f"{len(returned)} — something truncates the list after the walk.")

    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2

    print(f"✅ self-test ok — {len(fixtures)} fixture(s): every rule in {list(RULES)} fires on its "
          f"own marked line, every near-miss control stays silent, mutating each of the "
          f"{len(MUTABLE_PATTERNS)} named patterns flips its fixture, and the real-file control "
          f"{REAL_CONTROL.name} scans clean.")
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*",
                    help=f"file(s)/dir(s) to scan (default: {DIAGRAM_ROOT.relative_to(ROOT)})")
    ap.add_argument("--self-test", action="store_true",
                    help="assert each fixture: each rule fires on its own marked line, each control "
                         "stays silent, and each named pattern is proven load-bearing by mutating "
                         "it. MUST exit 1")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    explicit = bool(args.paths)
    roots = args.paths or [DIAGRAM_ROOT]

    # Floors apply to the WHOLE-CORPUS run only. `guard.py one.mmd` — the pre-commit shape — is a
    # legitimately tiny scope, and a floor there would fail every single-file invocation.
    scope = Scope("diagram-size-guard")
    if not explicit:
        require_tree_floors(scope)

    files = collect_diagrams(roots, scope=scope)
    if not files:
        print(f"diagram-size-guard: no .mmd files under {[str(r) for r in roots]!r} — refusing to "
              f"report clean over an empty scope.", file=sys.stderr)
        return 2

    findings = []
    for f in files:
        scope.add("diagrams parsed")        # recorded HERE: downstream of collect_diagrams' return
        for line_no, rule, message in find_offenders(f):
            findings.append((f, line_no, rule, message))

    # Judged BEFORE the findings are reported: over a collapsed scope neither answer is trustworthy.
    # rc 2 says the guard could not inspect what it claims to — a different thing from rc 1.
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if findings:
        for f, line_no, rule, message in findings:
            rel = f.relative_to(ROOT) if f.is_relative_to(ROOT) else f
            print(f"{rel}:{line_no}: [{rule}] {message}")
        by_rule = {rule: sum(1 for _, _, r, _ in findings if r == rule) for rule in RULES}
        tally = ", ".join(f"{n} {rule}" for rule, n in by_rule.items() if n)
        print(f"\ndiagram-size-guard: {len(findings)} finding(s) across "
              f"{len({f for f, _, _, _ in findings})} of {len(files)} diagram(s) — {tally}.",
              file=sys.stderr)
        return 1

    summary = scope.summary() if not explicit else f"{len(files)} diagram(s) scanned"
    print(f"diagram-size-guard: clean ({summary}). This does NOT mean the diagrams are the right "
          f"size — nothing here measures pixels. It means none of them is back in one of the three "
          f"authoring shapes that produced every measured offender.")
    return 0


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either, so it is remapped to 2.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::diagram-size-guard: crashed ({type(exc).__name__}: {exc}). Exiting 2 — a "
              f"crash is 'the guard could not run', never 'clean' and never 'canary detected'.",
              file=sys.stderr)
        sys.exit(2)
