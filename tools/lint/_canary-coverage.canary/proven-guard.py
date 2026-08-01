#!/usr/bin/env python3
"""FIXTURE for _canary-coverage.py — a guard whose every detector IS witnessed.

Not a real guard: nothing imports it, no CI job runs it, and it inspects a temporary directory it
writes itself. It exists so `_canary-coverage.py --self-test` has a case with a known answer on
the PROVEN side — a gate that only ever sees holes cannot show that it can tell the difference.

Three detectors, one witness each, deliberately one of each kind the gate knows how to blind:
  pattern:FLAW_RE        blind it and the canary's defect line stops being found.
  predicate:is_exempt    force it either way and the canary's exempt line changes behaviour.
  emit:find_offenders:*  no-op the yield and nothing is reported at all.

Keep the shape (real-run pipeline shared by BOTH modes) if you edit it. The moment `self_test()`
stops routing through `find_offenders()`, this fixture stops being the proven case and
`_canary-coverage.py --self-test` fails — which is the correct outcome, not a nuisance.
"""

import argparse
import pathlib
import re
import sys
import tempfile

DEFECT = "SHOUTY-DEFECT"
EXEMPT_MARK = "# fixture-ok"


def _compile(name, pattern, flags=0):
    """Same crash-to-2 contract the real guards use; a bad regex must not exit 1."""
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"proven-guard fixture: {name} is not a valid regex ({exc})", file=sys.stderr)
        sys.exit(2)


# The defect this fixture guard pretends to care about.
FLAW_RE = _compile("FLAW_RE", rf"\b{DEFECT}\b")


def is_exempt(line: str) -> bool:
    """A line carrying the opt-out marker is allowed to contain the defect."""
    return EXEMPT_MARK in line


def find_offenders(path: pathlib.Path):
    """Yield (line_no, text) for every non-exempt defect. The ONLY detection path, both modes."""
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if is_exempt(line):
            continue
        if FLAW_RE.search(line):
            yield (number, line.strip())


def scan(directory: pathlib.Path) -> list:
    return [(path.name, *hit) for path in sorted(directory.glob("*.txt"))
            for hit in find_offenders(path)]


CLEAN = "nothing to see here\nan ordinary line\nallowed here SHOUTY-DEFECT  # fixture-ok\n"
CANARY = "an ordinary line\nthis line carries SHOUTY-DEFECT\nallowed here SHOUTY-DEFECT  # fixture-ok\n"


def _materialise(directory: pathlib.Path, text: str) -> None:
    (directory / "sample.txt").write_text(text, encoding="utf-8")


def check() -> int:
    """Real run: a clean tree must produce nothing and exit 0."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        _materialise(root, CLEAN)
        offenders = scan(root)
    if offenders:
        print(f"proven-guard fixture: {len(offenders)} offender(s): {offenders}")
        return 1
    print("proven-guard fixture: clean.")
    return 0


def self_test() -> int:
    """Exit 1 when the canary's one defect is found AND its exempt twin stays silent."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        _materialise(root, CANARY)
        offenders = scan(root)
    lines = sorted(hit[1] for hit in offenders)
    if lines != [2]:
        print(f"proven-guard fixture SELF-TEST FAILED: expected the defect on line 2 and silence "
              f"on the exempt line 3; got lines {lines}.", file=sys.stderr)
        return 2
    print("proven-guard fixture: canary detected on line 2, exempt line silent (rc=1).")
    return 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    return self_test() if args.self_test else check()


if __name__ == "__main__":
    sys.exit(main())
