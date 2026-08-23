#!/usr/bin/env python3
"""Every guard in tools/lint must be RUN by CI, and run through its --self-test first.

WHY THIS EXISTS. On 2026-08-23 a `_canary-coverage.py --all` sweep found that
`devworkspace-editor-guard.py` — written 2026-08-17 to stop a DevWorkspace contributing its editor
by `uri`, which ships an IDE whose built-in terminal silently does nothing — had never been wired
into a CI step. It was the only one of 47 guards with no job. Its plain run therefore never
executed anywhere, and the regression it existed to prevent was ungated for six days in the two
charts that had already shipped it once.

Nothing noticed because nothing was looking: adding a guard means writing the guard AND remembering
a workflow step, and only the first half leaves a file behind to review. A guard that no job runs
is indistinguishable, in every report anyone reads, from a guard that runs and finds nothing.

The three things asserted here, and why each is separate:
  * ON DISK BUT NEVER RUN — the defect above.
  * RUN BUT NOT ON DISK — a renamed or deleted guard leaves a step that fails at the shell, which
    reads as "the guard found something" rather than "the guard is gone".
  * RUN WITHOUT --self-test — the house contract is that every step proves detection before
    trusting a clean scan. All 47 guards satisfied it when this was written; a 48th that skipped it
    would be a gate whose green tick means nothing, which is the failure `_canary-coverage.py` was
    built for and this file keeps reachable.

WHAT THIS CANNOT DO: it proves a guard is INVOKED, never that its job runs (a job gated behind
`if:` or absent from a required-checks list still satisfies this), and never that its detection
works — that is `_canary-coverage.py`'s job, and the two are deliberately separate.
"""
from __future__ import annotations

import contextlib
import io
import pathlib
import re
import sys

import yaml


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception -> rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import would
    exit 1 — exactly what this guard's CI step reads as "the canary fired". `os._exit` is what makes
    the code stick: an excepthook cannot change the exit status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::guard-wiring-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2

ROOT = pathlib.Path(__file__).resolve().parents[2]
CANARY_DIR = pathlib.Path(__file__).resolve().parent / "guard-wiring-guard.canary"
GUARD_NAME = re.compile(r"[a-z0-9-]+-guard\.(?:py|sh)")
GUARD_REF = re.compile(r"tools/lint/([a-z0-9-]+-guard\.(?:py|sh))")

# This guard reads two directories; if either resolves empty the report is "0 problem(s) ✅" over
# nothing at all. The floor is not a catalogue size — guards are added and retired — it is simply
# that both halves must be non-empty for any comparison between them to mean anything.
MIN_GUARDS = 1
MIN_WORKFLOWS = 1


def guards_on_disk(root: pathlib.Path) -> set[str]:
    d = root / "tools" / "lint"
    if not d.is_dir():
        return set()
    return {p.name for p in d.iterdir() if p.is_file() and GUARD_NAME.fullmatch(p.name)}


def workflow_run_blocks(root: pathlib.Path) -> tuple[list[str], int]:
    """Every `run:` script in every workflow, with shell comments stripped.

    Comments are dropped on purpose. lint.yml carries a note reading `(tools/lint/seed-drift-
    guard.sh, deleted)`, and a grep over the raw text reports that long-gone guard as wired — the
    naive check finds a defect that is not there and misses the one that is. YAML comments the
    parser removes for us; shell comments inside a `run:` block it does not.
    """
    blocks, seen = [], 0
    wf_dir = root / ".github" / "workflows"
    if not wf_dir.is_dir():
        return blocks, seen
    for wf in sorted(wf_dir.glob("*.y*ml")):
        seen += 1
        doc = yaml.safe_load(wf.read_text(encoding="utf-8"))
        if not isinstance(doc, dict):
            continue
        for job in (doc.get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            for step in (job.get("steps") or []):
                if isinstance(step, dict) and isinstance(step.get("run"), str):
                    blocks.append("\n".join(l for l in step["run"].split("\n")
                                            if not l.lstrip().startswith("#")))
    return blocks, seen


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()

    positional = [a for a in argv if not a.startswith("-")]
    root = pathlib.Path(positional[0]) if positional else ROOT

    disk = guards_on_disk(root)
    blocks, workflows = workflow_run_blocks(root)
    live = "\n".join(blocks)
    invoked = set(GUARD_REF.findall(live))

    problems: list[str] = []

    for name in sorted(disk - invoked):
        problems.append(
            f"tools/lint/{name} exists but NO workflow step runs it. A guard no job runs is "
            f"indistinguishable, in every report anyone reads, from a guard that runs and finds "
            f"nothing — which is how the DevWorkspace `uri` regression stayed ungated for six days "
            f"after it was fixed.")

    for name in sorted(invoked - disk):
        problems.append(
            f"a workflow step runs tools/lint/{name}, which does not exist. The step fails at the "
            f"shell, and a shell failure reads as 'the guard found something' rather than 'the "
            f"guard is gone'.")

    for name in sorted(disk & invoked):
        if f"tools/lint/{name} --self-test" not in live:
            problems.append(
                f"tools/lint/{name} is run without `--self-test`. The house contract is that every "
                f"step proves its detection still fires before trusting a clean scan; without it "
                f"the step's green tick asserts nothing about whether the guard still works.")

    # SCOPE. Everything above compares two sets; if either resolves empty the comparison is vacuous
    # and this guard reports clean over a tree it never read.
    if len(disk) < MIN_GUARDS or workflows < MIN_WORKFLOWS:
        problems.append(
            f"[scope] found {len(disk)} guard(s) under {root}/tools/lint and {workflows} "
            f"workflow(s) under {root}/.github/workflows, below the floor of {MIN_GUARDS}/"
            f"{MIN_WORKFLOWS}. Both halves must be non-empty for the comparison between them to "
            f"mean anything.")

    if problems:
        print(f"::error::guard-wiring-guard: {len(problems)} problem(s).", file=sys.stderr)
        for p in problems:
            print(f"  ❌ {p}", file=sys.stderr)
        return 1

    print(f"✅ guard-wiring-guard: all {len(disk)} guard(s) in tools/lint are run by a workflow "
          f"step, every step runs `--self-test` first, and no step names a guard that is gone. "
          f"This does NOT prove any guard's detection works — that is _canary-coverage.py's job.")
    return 0


def _drive(argv: list[str]) -> tuple[int, str]:
    """Run the REAL main() and capture everything it printed."""
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        rc = main(argv)
    return rc, sink.getvalue()


# (fixture tree, expected rc, a phrase only THIS detector prints).
# One fixture per detector, each tripping exactly one — a fixture that tripped two would leave both
# readable as proven while either could silently stop working.
CASES = [
    ("control-good", 0, None),
    ("canary-unwired", 1, "exists but NO workflow step runs it"),
    ("canary-dead-ref", 1, "which does not exist"),
    ("canary-no-selftest", 1, "is run without `--self-test`"),
    ("canary-empty", 1, "[scope]"),
]


def self_test() -> int:
    """Drive the real entry point over the fixture trees. Exit 1 = every detector fired on exactly
    its own fixture and the control stayed silent. Exit 2 = any of that is false. Never 0.
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

    # The comment-stripping branch, which has no fixture of its own because it is not a detector:
    # a note mentioning a deleted guard must NOT be read as wiring. Without this, the naive check
    # reports a defect that is not there — measured on lint.yml's own seed-drift-guard.sh note.
    blocks, _ = workflow_run_blocks(CANARY_DIR / "control-good")
    if any("commented-out-guard.py" in b for b in blocks):
        problems.append("[comments] a shell-commented guard reference survived stripping, so a "
                        "'deleted, see X' note would be read as a live CI invocation.")

    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2

    print(f"✅ self-test ok — {len(CASES)} fixture tree(s) driven through the real main(): an "
          f"unwired guard, a step naming a guard that is gone, a step skipping `--self-test` and an "
          f"empty tree each caught on exactly their own fixture; the control silent; and a "
          f"shell-commented reference correctly not counted as wiring.")
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    return 1


if __name__ == "__main__":
    sys.exit(main())
