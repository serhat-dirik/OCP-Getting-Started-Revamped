#!/usr/bin/env python3
"""api-key-shape-guard.py — catch a committed API key by its SHAPE, not by a 20-character alnum run.

WHY THIS EXISTS (task #97). The privacy guard's key pattern was `sk-[A-Za-z0-9]{20}`. That requires
twenty *consecutive* alphanumerics immediately after `sk-`, and a single `_` or `-` anywhere in the
first twenty characters breaks the run. Measured 2026-07-29 against a real key of the shape this
project actually uses — 22 characters after `sk-`, one `_` separator, two chunks — `sk-[A-Za-z0-9]{20}`
does NOT match it. A live credential could have been committed and the guard would have printed
"Privacy guard clean." (The measurement recorded only derived properties: length, separator set,
chunk lengths. The key itself was never written down, here or anywhere else.)

WHY NOT JUST WIDEN THE CHARACTER CLASS. `sk-[A-Za-z0-9_-]{16,}` false-positives five times on the
current tree, and a guard that cries wolf gets deleted:

    apps/mcp-agent-cli/…/AgentCommandTest.java     sk-SYNTHETIC-not-a-real-key-0123456789
    apps/parasol-agent/…/AgentResourceTest.java    sk-SYNTHETIC-not-a-real-key-0123456789
    pipelines/tasks/image-size-report.yaml         parasol-ta|sk-image-size-report
    pipelines/tasks/roxctl-deployment-check.yaml   parasol-ta|sk-roxctl-deployment-check
    tools/lint/credential-redaction-guard.canary.adoc  <sk- + three hex groups; see that file>

(The last three are not keys at all: two are the substring `task-` inside a Tekton Task name, and one
is a lint fixture whose entire job is to contain a scary-looking string.)

That last row is DESCRIBED rather than reproduced, and the reason is worth the line: writing the
literal here made this file itself key-shaped, and this guard does not exempt its own source (see
EXCLUDED_PATHS). While the file was untracked that was invisible — the scope is `git ls-files`, so
the guard could not see itself and every local run passed. Committing it turned main red. Documenting
a detector must not mean shipping a specimen of what it detects.

THE DISCRIMINATOR: OPACITY. A credential is opaque — it carries a long unbroken run of random
alphanumerics. A slug is words — short chunks separated by hyphens, and the words are either all
letters or all digits. That is a property of what the two things ARE, not a tuning constant fitted to
today's tree, and it is why this guard checks structure instead of length. Three layers, each
independently defensible:

  1. TOKEN START. `sk-` must not be preceded by an alphanumeric. A key's prefix begins its token;
     `parasol-task-image-size-report` only contains `sk-` because `task-` does. Kills FP 3 and 4.
  2. LENGTH. At least 20 characters of `[A-Za-z0-9_-]` after `sk-`. No real key is shorter; the
     original guard's instinct was right, only its character class was wrong.
  3. OPACITY. Somewhere in that run there must be an unbroken alphanumeric chunk of >= 12 characters
     containing BOTH a letter and a digit. `SYNTHETIC-not-a-real-key-0123456789` has no such chunk —
     its longest are `SYNTHETIC` (9, no digit) and `0123456789` (10, no letter). Kills FP 1 and 2.
     Verified against the real key's shape: its opaque chunk is 20 characters with both. Also catches
     shapes the old pattern would have missed entirely — 32-character lowercase hex, and base64url
     keys whose `-`/`_` characters break the run early.

FIXTURE FILES ARE EXCLUDED BY PATH, not by contorting the pattern around them: a lint fixture exists
to hold strings that look exactly like the thing being detected — the same self-referential exclusion
`.github/workflows/lint.yml` already gets in the privacy grep. Exclusions are EXACT paths, listed in
EXCLUDED_PATHS with a reason each, because every one of them is a file nobody is guarding.

THE SCOPE IS `git ls-files`, NOT A FILESYSTEM WALK. A walk lints whatever happens to be sitting in the
working tree; on a maintainer laptop that once meant 448 untracked artifacts and a reported CI miss
that was not real. The tracked set is the honest definition of "what we would have committed" and is
identical in every checkout.

MATCHES ARE PRINTED REDACTED. If this guard ever fires for real, the thing it found is a live
credential; echoing it into a CI log that anyone with repo read access can fetch would turn the guard
into the leak. The report gives file:line, the prefix, and the shape — enough to find it, not enough
to use it. (Sibling guard credential-redaction-guard.py exists for the mirror-image defect: a secret
DISPLAYED at runtime behind a character count.)

USAGE
    tools/lint/api-key-shape-guard.py               # scan every tracked file
    tools/lint/api-key-shape-guard.py --explain S   # why the rule does/does not fire on a string
    tools/lint/api-key-shape-guard.py --self-test   # scan the canary fixture; MUST exit 1

EXIT CODES (the same contract as the other tools/lint guards, so the workflow steps read alike):
    0  no key-shaped string in any tracked file
    1  found one — or, under --self-test, every canary was correctly detected
    2  the guard could not do its job (empty scope, missing fixture, or a canary that went
       UNdetected). Never confuse this with a clean result.
"""
from __future__ import annotations

import argparse
import fnmatch
import pathlib
import re
import subprocess
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
    print(f"::error::api-key-shape-guard: crashed before it could report "
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
    print(f"::error::api-key-shape-guard: cannot import _scope ({exc}) — "
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
        print(f"::error::api-key-shape-guard: {name} is not a valid regex ({exc}) — "
              f"the guard could not load. Exiting 2: that is 'the guard is broken', not "
              f"'the canary fired'.", file=sys.stderr)
        sys.exit(2)


# Layers 1 and 2. Layer 3 (opacity) is not expressible in a POSIX ERE without lookahead, which is
# precisely why this moved out of the inline `git grep` in .github/workflows/lint.yml and into a
# guard that can be self-tested.
CANDIDATE = _compile("CANDIDATE", r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}")

# Layer 3.
MIN_OPAQUE_CHUNK = 12

# Files whose job is to CONTAIN a key-shaped string. EXACT paths, never globs: every entry here is a
# hole in the guard, so each one is named individually and states why it is not a real one. (A glob
# was the first cut and it was wrong — `tools/lint/*.canary*` under fnmatch also swallowed two whole
# fixture DIRECTORIES, 13 files that nobody had decided to stop guarding.)
EXCLUDED_PATHS = [
    (".github/workflows/lint.yml",
     "the workflow that runs the guards quotes their patterns; already excluded from the privacy "
     "grep for the same reason."),
    ("tools/lint/credential-redaction-guard.canary.adoc",
     "the sibling guard's fixture. Its whole job is to carry a key-shaped string past a truncating "
     "redaction, so it is key-shaped on purpose."),
    ("tools/lint/api-key-shape-guard.canary.txt",
     "this guard's own fixture — eight constructed key shapes that MUST be detectable by "
     "--self-test and must not redden the tree scan."),
]
# NOT excluded, deliberately: THIS FILE. The self-test asserts it stays that way. Excluding the
# guard's own source would make the one place a maintainer edits while holding a real key the one
# place the guard cannot see — the worst possible hole. The docstring above therefore DESCRIBES the
# shapes it detects instead of reproducing one; the literal that used to sit there reddened main the
# moment this file became tracked (the scope is `git ls-files`, so while untracked it could not see
# itself, and every local run passed). Two lessons, both cheap to forget: a guard that scopes to the
# tracked set must be tested FROM the tracked set, and documentation of a detector must not be a
# specimen of what it detects.

# Skip anything that is not plausibly source. A binary is not something a key gets pasted into by
# accident, and decoding one wastes the scan.
MAX_BYTES = 2 * 1024 * 1024


class GuardError(Exception):
    """The guard cannot do its job. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def chunks_of(run: str) -> list[str]:
    """The unbroken alphanumeric chunks of a candidate run, i.e. the run split on `-` and `_`."""
    return [c for c in re.split(r"[^A-Za-z0-9]+", run) if c]


def is_opaque(run: str) -> bool:
    """Layer 3: does this run carry a chunk that looks random rather than like a word?"""
    return any(len(c) >= MIN_OPAQUE_CHUNK
               and any(ch.isalpha() for ch in c)
               and any(ch.isdigit() for ch in c)
               for c in chunks_of(run))


def looks_like_key(token: str) -> bool:
    """All three layers, applied to a token that already starts with `sk-`."""
    match = CANDIDATE.fullmatch(token)
    return bool(match) and is_opaque(token[3:])


def redact(token: str) -> str:
    """Enough to locate it, not enough to use it. See the module docstring."""
    body = token[3:]
    sizes = sorted((len(c) for c in chunks_of(body)), reverse=True)
    return (f"sk-{body[:3]}… ({len(token)} chars total, alnum chunks {sizes}, "
            f"longest opaque chunk {sizes[0] if sizes else 0})")


# --------------------------------------------------------------------------------- scanning


def excluded(path: str) -> bool:
    # fnmatch on the WHOLE repo-relative path, not PurePath.match: the latter matches a multi-segment
    # pattern from the RIGHT, so `tools/lint/*.canary*` would also excuse a hypothetical
    # vendor/tools/lint/x.canary. An exclusion should cover exactly what it says.
    return any(fnmatch.fnmatchcase(path, pattern) for pattern, _ in EXCLUDED_PATHS)


def tracked_files(root: pathlib.Path) -> list[str]:
    proc = subprocess.run(["git", "ls-files", "-z"], cwd=root,
                          capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise GuardError(f"`git ls-files` failed (rc={proc.returncode}): {proc.stderr.strip()}")
    return [f for f in proc.stdout.split("\0") if f]


def scan_text(text: str, origin: str) -> list[tuple[str, int, str]]:
    findings = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in CANDIDATE.finditer(line):
            if is_opaque(match.group(0)[3:]):
                findings.append((origin, lineno, redact(match.group(0))))
    return findings


def scan_files(root: pathlib.Path, files: list[str]) -> tuple[list[tuple[str, int, str]], dict]:
    """(findings, scope counters).

    The counters are raised INSIDE this loop, past every `continue`, because the audit blinded this
    function to return [] and the guard printed "clean (1253 tracked files scanned)" and exited 0 —
    that message was counting the SELECTION, not what was read. A number that can be printed without
    the reading happening is not evidence that it happened.
    """
    findings = []
    counts = {"files read": 0, "lines scanned": 0}
    for name in files:
        path = root / name
        if not path.is_file() or path.is_symlink():
            continue
        try:
            if path.stat().st_size > MAX_BYTES:
                continue
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue  # binary or unreadable: not somewhere a key is pasted by accident
        counts["files read"] += 1
        counts["lines scanned"] += len(text.splitlines())
        findings += scan_text(text, name)
    return findings, counts


# --------------------------------------------------------------------------------- self-test


CANARY = "tools/lint/api-key-shape-guard.canary.txt"

# Every fixture line is annotated in the .canary.txt itself; this is the machine-readable half.
# MUST_CATCH strings are SHAPE-EQUIVALENT constructions, never a real key — the shapes were derived
# from published key formats and from the measured properties (length, separator set, chunk lengths)
# of the project's own key, which was never transcribed.
MUST_CATCH = 8
MUST_NOT_CATCH_MARKER = "# BENIGN"


def self_test(root: pathlib.Path) -> int:
    fixture = root / CANARY
    if not fixture.is_file():
        print(f"::error::api-key-shape-guard: the canary fixture {CANARY} is missing — detection is "
              "unproven, so a clean result on the real tree means nothing.", file=sys.stderr)
        return 2

    failures: list[str] = []
    lines = fixture.read_text(encoding="utf-8").splitlines()
    if not lines:
        print("::error::api-key-shape-guard: the canary fixture is empty — refusing to call a "
              "self-test over an empty scope a pass.", file=sys.stderr)
        return 2

    caught = benign_caught = 0
    for lineno, line in enumerate(lines, 1):
        if line.startswith("#") and MUST_NOT_CATCH_MARKER not in line:
            continue
        hit = bool(scan_text(line, CANARY))
        if MUST_NOT_CATCH_MARKER in line:
            if hit:
                benign_caught += 1
                failures.append(f"line {lineno} is declared BENIGN and the guard fired on it. A "
                                "guard that cries wolf on the repo's own test constants gets "
                                "switched off, which is how the real key would get through.")
        elif line.strip():
            if hit:
                caught += 1
            else:
                failures.append(f"line {lineno} is a key SHAPE the guard must catch and it did not. "
                                "Detection is unproven for that shape.")

    if caught != MUST_CATCH:
        failures.append(f"expected {MUST_CATCH} key shapes to be caught, caught {caught}. The "
                        "fixture and MUST_CATCH have diverged — one of them is lying.")

    # The layer-3 discriminator, asserted directly rather than only through the fixture: the rule is
    # "opaque chunk", and these two cases are what that phrase has to mean.
    if is_opaque("SYNTHETIC-not-a-real-key-0123456789"):
        failures.append("the opacity rule accepted a hyphenated word list as opaque — layer 3 is "
                        "not doing the work the docstring claims.")
    if not is_opaque("a_A1b2C3d4E5f6G7h8i9"):
        failures.append("the opacity rule rejected a 19-character mixed alnum chunk — layer 3 is "
                        "too strict and would miss real keys.")
    # Layer 1, asserted directly: `sk-` mid-token is a slug, never a key prefix.
    if scan_text("name: parasol-task-image-size-report-abc123def456", "unit"):
        failures.append("layer 1 (token start) did not fire: `sk-` inside `task-` was treated as a "
                        "key prefix, which is exactly the false positive that made the naive "
                        "widening unusable.")

    # The path exclusions, asserted directly. The sibling guard's fixture IS key-shaped on purpose;
    # it is meant to be excluded by path, and nothing else in tools/lint/ or the tree should be.
    for path, should_exclude in (
            ("tools/lint/credential-redaction-guard.canary.adoc", True),
            (CANARY, True),
            (".github/workflows/lint.yml", True),
            ("tools/lint/api-key-shape-guard.py", False),
            ("apps/parasol-agent/src/test/java/com/parasol/agent/AgentResourceTest.java", False)):
        if excluded(path) != should_exclude:
            failures.append(f"the path exclusion list gave the wrong answer for {path} — it should "
                            f"{'' if should_exclude else 'NOT '}be excluded. Every exclusion is a "
                            "hole; a wrong one is an unguarded file.")

    # The scope ledger is a library no CI step runs on its own; exercising it here is what stops it
    # from being an unrun gate. And scan_files must actually count what it read: the audit blinded
    # it to return [] and the run stayed clean, because the printed number counted the SELECTION.
    failures += Scope.self_check()
    probe_findings, probe_counts = scan_files(root, [CANARY])
    if not probe_findings or probe_counts["files read"] != 1 or probe_counts["lines scanned"] < 10:
        failures.append(f"scan_files() over the canary reported {probe_counts} and "
                        f"{len(probe_findings)} finding(s). It is the only function that measures "
                        "how much of the tree was actually read, and the real run's floors depend "
                        "on those counts being raised by the reading itself.")

    if failures:
        for failure in failures:
            print(f"::error::api-key-shape-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2

    print(f"self-test ok — {caught} key shapes detected, "
          f"{sum(1 for line in lines if MUST_NOT_CATCH_MARKER in line) - benign_caught} benign "
          "look-alikes correctly ignored, all three layers asserted directly.")
    return 1


# --------------------------------------------------------------------------------- main


def scope_for_tree() -> Scope:
    """Floors for a real-tree run. Measured 2026-08-01: 1253 tracked files selected, 1210 actually
    read (the rest are binary, oversized or symlinks), 122,356 lines scanned."""
    scope = Scope("api-key-shape-guard")
    scope.require("files read", 800,
                  "the repo tracks ~1250 files and ~1210 of them are readable text. A smaller "
                  "number means the reader is skipping, not that the repo shrank.")
    scope.require("lines scanned", 50_000,
                  "a key is pasted on ONE line; the number of lines actually fed to the detector is "
                  "the only measure of how much of the repo it saw.")
    return scope


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="scan the canary fixture instead of the tree; a result other than 1 "
                             "means detection is unproven, not that the tree is fine")
    parser.add_argument("--explain", metavar="STRING",
                        help="report which layers a string passes (local debugging; prints the "
                             "verdict and the shape, never the string)")
    args = parser.parse_args(argv)

    root = repo_root()

    if args.self_test:
        return self_test(root)

    if args.explain:
        token = args.explain
        match = CANDIDATE.search(token)
        run = match.group(0)[3:] if match else ""
        print(f"token start + length (layers 1-2): {'pass' if match else 'FAIL'}")
        print(f"alnum chunks                     : {[len(c) for c in chunks_of(run)]}")
        print(f"opacity (layer 3, chunk >= {MIN_OPAQUE_CHUNK})   : "
              f"{'pass' if run and is_opaque(run) else 'FAIL'}")
        print(f"verdict                          : "
              f"{'KEY-SHAPED' if match and is_opaque(run) else 'not key-shaped'}")
        return 0

    try:
        files = tracked_files(root)
    except GuardError as exc:
        print(f"::error::api-key-shape-guard: {exc}", file=sys.stderr)
        return 2

    scanned = [f for f in files if not excluded(f)]
    if not scanned:
        print("::error::api-key-shape-guard selected zero files. The repo tracks thousands, so an "
              "empty selection means this guard is broken — refusing to pass on an empty scope.",
              file=sys.stderr)
        return 2

    scope = scope_for_tree()
    findings, counts = scan_files(root, scanned)
    scope.merge(counts)
    # Before reporting anything: did the run actually read what it claims to have scanned?
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if findings:
        print("Key-shaped strings in tracked files (redacted — see the guard's docstring):")
        for origin, lineno, shape in findings:
            print(f"  {origin}:{lineno}  {shape}")
        print("\n::error::a string with the shape of an API key is committed. Secrets belong in the "
              "gitignored vars.yaml (template: vars.example.yaml) or in ../Project-Shared, outside "
              "the repo. If this is a synthetic test constant, give it a shape a key cannot have — "
              "hyphenated words, no opaque chunk — rather than adding an exclusion.", file=sys.stderr)
        return 1

    print(f"api-key-shape-guard: clean ({scope.summary()}; {len(scanned)} tracked files selected, "
          f"{len(files) - len(scanned)} declared fixture path(s) excluded).")
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
        print(f"::error::api-key-shape-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
