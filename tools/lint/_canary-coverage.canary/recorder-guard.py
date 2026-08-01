#!/usr/bin/env python3
"""FIXTURE for _canary-coverage.py — a guard that records findings through a class, not a local.

Not a real guard; see proven-guard.py beside it for the same disclaimer.

This is the `copy-drift-guard.py` shape, and it is here because the gate's first enumerator could
not see it. copy-drift reaches NONE of its eight finding kinds through a `[]` local: every one is a
`self._record(kind, …)` call on a one-line method that appends to `self.findings`. A local-list
sweep enumerated four incidental detectors in that file and missed all eight of the kinds the
2026-08-01 audit had just spent a night proving — a green tick about nothing.

The gate must classify both of this fixture's recorder call sites as PROVEN, and — the assertion
that actually witnesses the class walk — must ENUMERATE them at all. Blind `_class_recorders()`,
or drop class methods from `_module_functions()`, and this fixture's detector set collapses to
empty, which `_canary-coverage.py --self-test` fails on by name.
"""

import argparse
import pathlib
import sys
import tempfile

DEFECT = "SHOUTY-DEFECT"
SHOUTED = "SHOUTY-SHOUTY"


class Review:
    """Walks lines and records every way one is wrong. Findings live on the instance."""

    def __init__(self):
        self.findings: list[tuple[str, int]] = []

    def _record(self, kind, line_no):
        """A one-line recorder: the whole body is one append onto a `[]` self attribute."""
        self.findings.append((kind, line_no))

    def read(self, text):
        for number, line in enumerate(text.splitlines(), 1):
            if SHOUTED in line:
                self._record("doubled", number)
            elif DEFECT in line:
                self._record("plain", number)


def scan(directory: pathlib.Path) -> list:
    review = Review()
    for path in sorted(directory.glob("*.txt")):
        review.read(path.read_text(encoding="utf-8"))
    return review.findings


CLEAN = "nothing to see here\nan ordinary line\n"
CANARY = "an ordinary line\nthis line carries SHOUTY-DEFECT\nand this one SHOUTY-SHOUTY\n"


def _materialise(directory: pathlib.Path, text: str) -> None:
    (directory / "sample.txt").write_text(text, encoding="utf-8")


def check() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        _materialise(root, CLEAN)
        findings = scan(root)
    if findings:
        print(f"recorder-guard fixture: {len(findings)} finding(s): {findings}")
        return 1
    print("recorder-guard fixture: clean.")
    return 0


def self_test() -> int:
    """Exit 1 when BOTH kinds fired, each on its own line. Per-kind, never a total: a count is
    satisfied by one detector firing twice, which is how a masked kind survives."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        _materialise(root, CANARY)
        findings = scan(root)
    if sorted(findings) != [("doubled", 3), ("plain", 2)]:
        print(f"recorder-guard fixture SELF-TEST FAILED: expected plain on line 2 and doubled on "
              f"line 3; got {sorted(findings)}.", file=sys.stderr)
        return 2
    print("recorder-guard fixture: both kinds recorded on their own lines (rc=1).")
    return 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    return self_test() if args.self_test else check()


if __name__ == "__main__":
    sys.exit(main())
