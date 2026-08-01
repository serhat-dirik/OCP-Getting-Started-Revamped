#!/usr/bin/env python3
"""click-to-run-guard.py — an interactive `read` must be the LAST line of a click-to-run block.

WHY THIS EXISTS (fixed in 76ae9d3, 2026-07-29; shipped TWICE before anyone noticed). Read
content/supplemental-ui/js/click-to-run.js yourself: commandText() takes a
`.listingblock.execute`'s WHOLE textContent, and sendToTerminal() posts it to the terminal as ONE
`execute` message. ttyd's listener strips only the trailing newline and writes `cmd + "\\r"` in a
single call — every INTERNAL newline in the block lands in the tty's input queue right along with
it. A `read` mid-stream drains that queue for its own answer, so whatever line follows it in the
same block is swallowed as the read's input, not typed by the attendee.

Measured on bash 3.2 and bash 5.1 (the cockpit's family) with a PTY harness: on both, `read`
captured the next line verbatim; on 5.1 the ENTIRE remainder of the block was discarded outright,
so the failure surfaces later as something that looks unrelated. Two real victims, both in
`content/modules/ROOT/pages/`:

  - gitops-at-scale/lab.adoc: `read -rsp "Your workshop password: " PW; echo` was followed in the
    same block by the ARGOCD_AUTH_TOKEN exchange. PW ate that export line, the exchange never ran,
    and the attendee met a bare 401 two blocks later at the ApplicationSet create — nothing at the
    read step itself looked wrong.
  - pipelines-fundamentals/lab.adoc: `read -rsp "paste your Gitea token, then press Enter: "
    GITEA_TOKEN; echo` was followed by `WEBHOOK_SECRET="parasol-$(openssl rand -hex 6)"` and the
    `oc create secret` call. GITEA_TOKEN ate the WEBHOOK_SECRET line and the Secret was never
    created at all.

Both are fixed today — each split into two blocks, the first ending at the `read` — and both carry
a `// DO NOT merge this block with the one below it` comment. Nothing but this guard stops a future
edit (a "tidy up the lab" pass, a copy-paste from an older draft) from re-merging them, because
nothing else in CI exercises this mechanism.

DETECTION RULE. Inside every AsciiDoc `[source,<lang>,role=execute...]` delimited block, find every
shell `read` invocation that reads interactively from the terminal — i.e. is not fed by a pipe and
carries no explicit input redirection — and flag it if it is not the block's last non-blank line
(comments count as content: the swallowed line does not have to be code to break the read).

WHAT COUNTS AS INTERACTIVE, precisely (false positives get a guard disabled, which is worse than no
guard — see the curl-format-guard docstring for the same lesson learned earlier):

  - `read -rsp "..." VAR` with nothing feeding it — interactive; must be the block's last line.
  - `cmd | while IFS=, read -r a b c; do …; done` — `read`'s stdin is the pipe from `cmd`, not the
    terminal. Harmless anywhere in the block. Detected by walking command separators (`;` `&` `|`
    `&&` `||` `(` `{` and the keywords `do`/`then`/`while`/`until`) and checking whether the token
    immediately before `read` is a single `|`.
  - `read -t 3 -n1 reply <&3` — an explicit fd (or file) redirect on the read itself. Whatever it
    reads, it is not the attendee's next keystroke. Detected by a literal `<` anywhere in the
    command chunk that starts with `read`.
  - `read` inside a heredoc body (`oc apply -f - <<'EOF' … EOF`) — that text is DATA the shell
    writes into a file/manifest, not a command the terminal executes at click time. The scanner
    tracks heredoc open/close per block and never inspects lines inside one.
  - the word "read" in prose or a `#`-comment — never a command at all; comment-only lines are
    skipped for detection (though they still count as "content" for the last-line check above).

QUOTES ARE MASKED before any of the above runs (see mask_quoted): a `;`, `|`, or the word `read`
sitting inside a quoted string is not shell syntax and must never be mistaken for it. The first real
run of this guard against content/ proved why — it flagged
`echo "... failed; read its logs: oc logs job/..."` in packaging-distributing/lab.adoc as an
offender, because the semicolon INSIDE that echo string reads as a command separator and "read its
logs" then looks like a `read` invocation. Masking fixed it, and as a side effect also closes what
would otherwise be a blind spot: a `<` inside a read's own prompt string (`read -rsp "value
<required>: " X`) no longer suppresses a real flag either, because that `<` is masked away too.

Verified against the real tree, 2026-07-30: `grep -rn "read " content/modules/ROOT/pages/` surfaces
~9 lines; of those, exactly two are genuinely interactive terminal reads (the two fixed victims
above), and both are correctly the last line of their block today. The rest are prose, a `read`
fed by a pipe inside a heredoc-embedded Job script (jobs-batch-kueue, twice), and an explicit-fd
read outside any role=execute block (devspaces-inner-loop). This guard must report ZERO offenders
on that tree — a guard that fires on the already-fixed state is useless.

USAGE
    tools/lint/click-to-run-guard.py [path ...]     # default: content
    tools/lint/click-to-run-guard.py --self-test     # scans the canary fixture; must exit non-zero

A guard that silently inspects zero files, or zero role=execute blocks, always "passes" — this repo
relearned that lesson on tools/lint/route-tls-guard.sh. This script refuses to report clean over an
empty file scope AND over a zero-block scan. --self-test exists so CI (and a human) can prove the
detector fires on a deliberately broken canary case, does NOT fire on every safe form beside it, and
exits 2 (not 1) if either check fails — only a clean self-test earns trust in a clean real-tree run.

THE DETECTOR IS EIGHT PATTERNS AND THE CANARY MUST COVER ALL EIGHT (2026-08-01). An audit blinded
each compiled pattern in turn — swapping it for one that can never match — and re-ran BOTH modes.
Five of the eight could be switched off with `--self-test` still exiting 1 and the real run still
exiting 0: _NORMALIZE_RE, _SPLIT_RE, _LEADING_LOOP_RE, _LEADING_ASSIGN_RE and HEREDOC_START_RE. The
reason each was invisible is the same shape every time: the fixture's only broken case
(`read …; echo` at the start of its line) is detected by `^read\b` alone, and every case that
exercised one of the other five was a SAFE case that stays silent whether the pattern works or not.
A safe case proves a pattern only when blinding the pattern makes it FIRE; proving a pattern that
enables detection needs a broken case that stops firing. The fixture now carries five broken cases,
one per enabling pattern, and EXPECTED_OFFENDERS below asserts them by name rather than by count, so
a blinded pattern reports which case it silenced. Three patterns are proven by other means and say
so there: OPENER_RE and DELIMITER_RE collapse the block scope (the ledger floors catch them), and
`<<-`'s indent group is proven through the examined-lines floor, not the offender list.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    WHY THE `__main__` TRY/EXCEPT IS NOT ENOUGH (measured 2026-08-01). Module-level code runs before
    `__main__` exists, so a bad constant, a failed import, or a _scope.py that does not PARSE crashed
    with Python's default rc 1 — which is exactly what CI's `--self-test must exit EXACTLY 1` reads as
    "the canary fired". Measured on a scratch copy of this file: replacing _scope.py with a syntax
    error gave rc 1 in BOTH modes, and the CI step would have printed "self-test ok".

    Installed as the FIRST statement after the imports, so it is already in place before anything
    below it can fail. `os._exit` is what makes the code stick: an excepthook cannot change the exit
    status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::click-to-run-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). "
          f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
          f"'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad; see the note below
    # NOT `except ImportError`. Measured 2026-08-01: a _scope.py that fails to PARSE raises
    # SyntaxError, sails past an ImportError-only handler, and exits 1 — CI's 'the canary
    # fired'. Anything at all going wrong while loading the scope ledger means this guard
    # cannot start, and that is rc 2 regardless of which exception said so.
    # An uncaught ImportError exits 1, and CI's contract for this guard is "--self-test must exit
    # EXACTLY 1 = the canary was detected". A crash would therefore be READ AS PROOF OF DETECTION and
    # the real run would never even happen. Measured 2026-08-01 by running a copy of this file with
    # _scope.py absent: traceback, rc=1, and the CI step would have printed "self-test ok".
    print(f"::error::click-to-run-guard: cannot import _scope ({exc}) — "
          f"the guard could not start, which is NOT the same as a clean tree.",
          file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    WHY (measured 2026-08-01). Every pattern compiled at MODULE level raises re.error before main()
    — and before any try/except inside it — can run. Python exits 1 on an uncaught exception, and 1
    is exactly what CI's `--self-test must exit EXACTLY 1` assertion accepts as "the canary was
    detected". A one-character regex typo therefore reported the guard's detection as PROVEN while
    the guard could not even load. A regex is the likeliest thing to break in a guard, so the
    compile step is where the exit code has to be fixed.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::click-to-run-guard: {name} is not a valid regex ({exc}) — "
              f"the guard could not load. Exiting 2: that is 'the guard is broken', not "
              f"'the canary fired'.", file=sys.stderr)
        sys.exit(2)


# The block-opener line. Accepts both forms seen in this repo (`role=execute` bare, and quoted
# multi-word roles like `role="execute send-to-tty-bottom"` that click-to-run.js also understands
# for the second/bottom terminal) without hard-coding either shape.
OPENER_RE = _compile("OPENER_RE", 
    r'^\[source\b[^\]]*\brole\s*=\s*(?:"(?P<qval>[^"]*)"|(?P<uval>[^,"\]]+))'
)

# A delimiter line opens/closes an AsciiDoc listing block: 2+ repeats of `-` (the only delimiter
# character this repo's [source] blocks use).
DELIMITER_RE = _compile("DELIMITER_RE", r"^-{2,}\s*$")

# A heredoc opener anywhere on a line: `<<EOF`, `<<'EOF'`, `<<"EOF"`, or the tab-stripping `<<-EOF`.
# Group 1 is the `-` (or empty) that permits an indented terminator; group 3 is the delimiter word.
HEREDOC_START_RE = _compile("HEREDOC_START_RE", r"<<(-?)\s*(['\"]?)(\w+)\2")

# Command separators/keywords that can precede a `read` invocation. `do`/`then` are normalized to
# `;` before splitting so `while … read …; do` and `if …; then read …` both split cleanly.
_NORMALIZE_RE = _compile("_NORMALIZE_RE", r"\b(?:do|then)\b")
_SPLIT_RE = _compile("_SPLIT_RE", r"(\|\||&&|[;&|(){}])")
_LEADING_LOOP_RE = _compile("_LEADING_LOOP_RE", r"^(?:while|until)\s+")
_LEADING_ASSIGN_RE = _compile("_LEADING_ASSIGN_RE", r"^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+")
_READ_RE = _compile("_READ_RE", r"^read\b")

# The canary's broken cases, keyed by the unique variable name each one's `read` assigns to, with
# the pattern that case exists to prove. --self-test asserts the guard flagged EXACTLY these — by
# NAME, not by count, so a blinded pattern names the case it silenced instead of just moving a
# number. Adding a broken case to the fixture means adding its marker here; the two are one edit.
#
# The three patterns absent from this table are not unproven, they are proven elsewhere, and each is
# listed with where — an entry that quietly went missing would otherwise look like coverage:
#   OPENER_RE      — blinding it yields zero execute blocks, which trips the "execute blocks" floor
#                    in scope_for_self_test() (rc 2). No offender-level canary can reach it: with no
#                    opener there is no block to put a canary in.
#   DELIMITER_RE   — same, for the same reason: iter_execute_blocks() requires a delimiter line
#                    immediately after the opener, so blinding it also yields zero blocks.
#   HEREDOC_START_RE group 1 (the `-` of `<<-`) — canary case 12. Losing the indent strip does not
#                    change any offender; it leaves that block's heredoc open to the end of the
#                    block, so the two commands after the tab-indented terminator are never
#                    examined. That is why the self-test's "block command lines examined" floor is
#                    the fixture's exact measurement rather than a margin below it.
EXPECTED_OFFENDERS = {
    "PW_MERGED": "case 1 (the shipped gitops-at-scale defect) — proves _READ_RE",
    "PW_LOOP": "case 7 (`while …; do read …`) — proves _NORMALIZE_RE rewrites `do` to a separator",
    "PW_ANDAND": "case 8 (`cmd && read …`) — proves _SPLIT_RE splits on command separators",
    "PW_UNTIL": "case 9 (`until read …; do`) — proves _LEADING_LOOP_RE strips the loop keyword",
    "PW_IFS": "case 10 (`IFS= read …`) — proves _LEADING_ASSIGN_RE strips inline assignments",
}


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def mask_quoted(text: str) -> str:
    """Blank out everything strictly inside single/double quotes, same length, same offsets.

    Without this, `echo "... failed; read its logs: ..."` reads as a `;`-separated command whose
    second chunk starts with the word `read` — a real false positive this guard hit on the first
    real-tree run (packaging-distributing/lab.adoc:664, an `echo` string that just SAYS "read its
    logs"). Masking removes the semicolon and the word from consideration without touching command
    text outside the quotes, so separator-splitting and the `read`/redirect checks below only ever
    see real shell syntax.
    """
    out = list(text)
    quote = None
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if quote is None:
            if c in ("'", '"'):
                quote = c
        else:
            if c == "\\" and quote == '"' and i + 1 < n:
                out[i] = out[i + 1] = "x"
                i += 2
                continue
            if c == quote:
                quote = None
            else:
                out[i] = "x"
        i += 1
    return "".join(out)


def is_execute_block_opener(line: str) -> bool:
    m = OPENER_RE.match(line.strip())
    if not m:
        return False
    val = m.group("qval") if m.group("qval") is not None else m.group("uval")
    return "execute" in val.split()


def line_has_interactive_read(text: str) -> bool:
    """True if `text` invokes `read` in a way that blocks on the terminal's next keystrokes."""
    normalized = _NORMALIZE_RE.sub(";", mask_quoted(text))
    last_sep = None
    for tok in _SPLIT_RE.split(normalized):
        if tok in ("||", "&&", ";", "&", "|", "(", ")", "{", "}"):
            last_sep = tok
            continue
        chunk = tok.strip()
        if not chunk:
            continue
        chunk = _LEADING_LOOP_RE.sub("", chunk)
        chunk = _LEADING_ASSIGN_RE.sub("", chunk)
        if _READ_RE.match(chunk):
            piped = last_sep == "|"
            redirected = "<" in chunk
            if not piped and not redirected:
                return True
        last_sep = None
    return False


def iter_execute_blocks(lines: list[str]):
    """Yield each [source,...,role=execute...] block's body as a list of (line_no, text)."""
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if is_execute_block_opener(line):
            j = i + 1
            if j < n and DELIMITER_RE.match(lines[j]):
                delim = lines[j].rstrip()
                k = j + 1
                body = []
                while k < n and lines[k].rstrip() != delim:
                    body.append((k + 1, lines[k]))
                    k += 1
                yield body
                i = k  # resume after the closing delimiter (or EOF if unterminated)
        i += 1


def find_offenders_in_block(body: list[tuple[int, str]]):
    """Return (offenders, command lines examined) for one block.

    An offender is (line_no, stripped_text) for every interactive `read` not at the block's last
    non-blank line. `body` is the block's content lines, excluding the [source] and delimiter lines
    themselves. The second value counts only lines that actually reached the `read` test — past
    blanks, past heredoc bodies, past comments — so it is evidence the walk went INSIDE the block.
    """
    last_nonblank = None
    for line_no, text in body:
        if text.strip():
            last_nonblank = line_no

    offenders = []
    examined = 0
    in_heredoc = False
    heredoc_delim = None
    heredoc_strip_leading = False
    for line_no, text in body:
        if in_heredoc:
            terminator = text.rstrip("\n")
            candidate = terminator.lstrip() if heredoc_strip_leading else terminator
            if candidate == heredoc_delim:
                in_heredoc = False
            continue  # heredoc body is DATA — never scanned for `read`

        stripped = text.strip()
        if not stripped:
            continue
        if not stripped.startswith("#"):
            examined += 1
            if line_has_interactive_read(text) and line_no != last_nonblank:
                offenders.append((line_no, stripped))
            m = HEREDOC_START_RE.search(text)
            if m:
                in_heredoc = True
                heredoc_delim = m.group(3)
                heredoc_strip_leading = bool(m.group(1))
    return offenders, examined


def scan_file(path: pathlib.Path):
    """Return (offenders, scope counters) for one file."""
    counts = {"execute blocks": 0, "block command lines examined": 0}
    offenders: list[tuple[int, str]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return offenders, counts
    for body in iter_execute_blocks(lines):
        counts["execute blocks"] += 1
        block_offenders, examined = find_offenders_in_block(body)
        counts["block command lines examined"] += examined
        offenders += block_offenders
    return offenders, counts


def scope_for_tree() -> Scope:
    """Floors for a real-tree run over content/. Measured 2026-08-01: 139 .adoc files carrying 978
    execute blocks and 2641 command lines inside them."""
    scope = Scope("click-to-run-guard")
    scope.require("files scanned", 90,
                  "content/ holds ~139 .adoc pages. A handful means the walk stopped recursing — "
                  "the shape that lets a one-file scan report the whole tree clean.")
    scope.require("execute blocks", 600,
                  "blocks that actually opened a role=execute body. Zero, or a fraction of 978, "
                  "means the opener or the delimiter match broke and every page looks defect-free.")
    scope.require("block command lines examined", 1500,
                  "lines fed to the detector INSIDE those blocks. Deliberately set ABOVE the block "
                  "count (978): if the scanner ever reads only each block's FIRST line this "
                  "collapses to at most one per block and trips the floor. That regression changes "
                  "no finding on today's tree, so nothing else here would notice it.")
    return scope


def scope_for_self_test() -> Scope:
    """The canary is one small fixture, and unlike the real tree its size is DECLARED, not observed —
    so these floors are its exact current measurement rather than a margin below it. _scope.py's own
    guidance says to pin a floor exactly where the set is declared in-repo, and pinning buys a proof
    nothing else here can give: canary case 12's tab-indented `<<-` terminator changes no offender,
    only how many lines get examined, so the only way to notice its indent group breaking is for the
    examined count to fall. Both numbers can only grow as cases are added; a fixture edit that
    lowers either is an editorial act and should re-state its own floor."""
    scope = Scope("click-to-run-guard --self-test")
    scope.require("files scanned", 1, "the canary fixture.")
    scope.require("execute blocks", 12,
                  "the fixture declares twelve blocks. Zero means OPENER_RE or DELIMITER_RE stopped "
                  "matching — neither can be proven by an offender canary, because with no opener "
                  "or no delimiter there is no block for a canary to live in.")
    scope.require("block command lines examined", 27,
                  "the fixture's exact count of lines reaching the detector. Above the twelve "
                  "blocks on purpose, so a first-line-only scan is visible here and not only on the "
                  "real tree — and pinned exactly, so case 12's `<<-` heredoc silently swallowing "
                  "the two commands after its tab-indented terminator (2 lines) trips it.")
    return scope


def collect_files(roots):
    files = []
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            files.extend(sorted(p.rglob("*.adoc")))
    return files


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=["content"],
                     help="file(s) or director(ies) to scan (default: content)")
    ap.add_argument("--self-test", action="store_true",
                     help="scan only the canary fixture next to this script; anything but a "
                          "precise match (one offender, every safe form silent) means the "
                          "detector itself is broken")
    args = ap.parse_args(argv)

    if args.self_test:
        fixture = pathlib.Path(__file__).resolve().parent / "click-to-run-guard.canary.adoc"
        roots = [fixture]
    else:
        roots = args.paths

    files = collect_files(roots)
    if not files:
        print(f"click-to-run-guard: no .adoc files found under {roots!r} — refusing to report "
              "clean over an empty scope.", file=sys.stderr)
        return 2

    scope = scope_for_self_test() if args.self_test else scope_for_tree()
    scope.add("files scanned", len(files))

    all_offenders = []
    for f in files:
        offenders, counts = scan_file(f)
        scope.merge(counts)
        for line_no, snippet in offenders:
            all_offenders.append((f, line_no, snippet))

    total_blocks = scope.get("execute blocks")

    # The old check here fired only on TOTAL emptiness, which let a scope that had merely SHRUNK
    # report clean. The ledger asserts a floor per dimension instead, so a truncated walk or a
    # first-line-only read fails rather than passing quietly over a smaller tree.
    if scope.enforce() != 0:
        return 2

    if args.self_test:
        # The canary carries one broken case per enabling pattern, each assigning to a unique
        # variable name. Matching offenders BY NAME rather than counting them is what makes a
        # blinded pattern say which case it silenced: a bare count reports "expected 5, got 4" and
        # leaves the reader to bisect the fixture. Anything unexpected in the list is the other
        # failure mode — the detector firing on one of the seven safe forms beside them.
        failures = []
        seen = set()
        for path, line_no, snippet in all_offenders:
            marks = [marker for marker in EXPECTED_OFFENDERS if marker in snippet]
            if marks:
                seen.update(marks)
            else:
                failures.append(f"{path}:{line_no} was flagged and no broken canary case lives "
                                f"there — a SAFE form is being reported as an offender, which is "
                                f"the false positive that gets a guard switched off ({snippet!r}).")
        for marker, why in EXPECTED_OFFENDERS.items():
            if marker not in seen:
                failures.append(f"{marker} went UNDETECTED — {why}. That pattern is now unproven, "
                                f"so a clean run over content/ proves nothing about it.")
        if len(all_offenders) != len(EXPECTED_OFFENDERS):
            failures.append(f"expected exactly {len(EXPECTED_OFFENDERS)} offenders, got "
                            f"{len(all_offenders)}: {[(str(f), n) for f, n, _ in all_offenders]}.")
        # The scope ledger is a library no CI step runs on its own; exercising it here is what
        # stops it from being an unrun gate.
        failures += Scope.self_check()
        if failures:
            for failure in failures:
                print(f"::error::click-to-run-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
            return 2

    for f, line_no, snippet in all_offenders:
        print(f'{f}:{line_no}: interactive `read` is not the last line of its click-to-run '
              f'block — content/supplemental-ui/js/click-to-run.js sends the whole block to the '
              f'terminal in one write, so the next line is swallowed as this read\'s input. '
              f'Split the block so the read ends it. ({snippet!r})')

    if all_offenders:
        print(f"\nclick-to-run-guard: {len(all_offenders)} offender(s) across {total_blocks} "
              f"execute block(s) in {len(files)} file(s) scanned.", file=sys.stderr)
        return 1

    print(f"click-to-run-guard: clean ({total_blocks} execute block(s) across {len(files)} "
          f"file(s) scanned).")
    return 0


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either, so it is remapped to 2 — "the
    # guard could not run". Without this, a typo in a regex or a missing fixture would make
    # --self-test exit 1 and CI would report the guard's detection as PROVEN.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::click-to-run-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
