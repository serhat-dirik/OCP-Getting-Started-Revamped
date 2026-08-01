#!/usr/bin/env python3
"""_scope.py — the ledger every Python guard reports its measured input volume through.

WHY THIS EXISTS (audit, 2026-08-01). The house rule is "every guard ships a canary and CI asserts
--self-test exits EXACTLY 1". An audit blinded each guard's detectors and its SCOPE code in turn and
found the rule has a hole that is worse than a broken detector: a guard whose detectors all work can
still have the code that decides WHAT TO SCAN broken, and it then prints "clean" and exits 0 over a
shrunken — or empty — input set. Measured instances, every one of them exit 0 on the real tree AND
exit 1 on --self-test after the blinding:

  * hook-env-guard        check_chart() → []            (also: envFrom skip widened to every
                                                         container; initContainers dropped; the
                                                         solve=true render dropped)
  * image-pull-policy     the kustomize half dropped; the solve=true half dropped; chart discovery
                          truncated; the Knative-premise re-derivation broken
  * copy-drift            check_structural_pair() → []  (4 of 5 detectors are ONLY reachable through
                                                         it, and the self-test called load_side +
                                                         Comparison directly, never the wrapper)
  * api-key-shape         scan_files() → []
  * curl-format           scope truncated to one file
  * version-anchor        scope truncated to one file
  * maas-model-no-default SITES[:1]
  * rebuild-scan          main() dropping either half

Several guards already refused to report clean over a TOTALLY empty scope. That is the weak form of
this assertion: it catches `→ []` and misses `[:1]`, and truncation is the likelier accident (a
debugging edit left behind, a filter that stops matching after a rename).

THE MECHANISM. A guard declares, per dimension, the floor its input set may not fall below, and
records the measurement. Below the floor is rc=2 — "the guard could not inspect what it claims to
inspect" — never a clean 0. CI's exit-exactly-1 assertion on --self-test and its exit-0 assertion on
the real run both catch it.

    scope = Scope("hook-env-guard")
    scope.require("charts", 20, "gitops/entry-states ships 26; a smaller number means discovery is "
                                "broken, not that charts were deleted")
    ...
    scope.add("charts", len(charts))
    rc = scope.enforce()
    if rc:
        return rc

THE ONE RULE THAT MAKES THIS WORK. **The number handed to add() must be produced BY the code path
being proven, not recomputed beside it.** A count taken from `len(charts)` proves discovery ran; a
count taken from inside check_chart() proves check_chart ran. If a dimension can be satisfied
without the work happening, it proves nothing — that is exactly how the old "empty scope" checks
passed while check_structural_pair returned []. Where the working function did not previously return
a count, give it one and thread it up; do not re-derive it in main().

CHOOSING A FLOOR. It is a floor, not an assertion of the current value: set it below today's
measurement (so ordinary growth and small deletions do not redden main) and far above the value any
plausible truncation produces (1, or one directory's worth). Where the set is DECLARED in the guard
itself — copy-drift's PAIRS, maas's SITES — the floor is the declared count exactly, because
shrinking a declared list is an editorial act that should re-state its own floor.

WHAT THIS DOES NOT DO. It does not check WHAT was found; that is the detectors' and the canary's job.
A guard can pass its scope floors and still detect nothing useful. Scope and detection are separate
proofs and both are required.

SELF-CHECK. This file is a library — no CI step runs it directly, and an unrun gate is worse than
none. So every guard that uses it calls Scope.self_check() from its own --self-test, which means all
nine already-running CI jobs exercise this code. `python3 tools/lint/_scope.py --self-test` runs the
same checks standalone (exit 1 = the mechanism works, matching the house exit convention).
"""
from __future__ import annotations

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
    print(f"::error::_scope: crashed before it could report "
          f"({exc_type.__name__}: {exc}). "
          f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
          f"'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


class Scope:
    """Per-dimension measurements of what a guard actually inspected, plus the floors they may not
    fall below."""

    def __init__(self, guard: str):
        self.guard = guard
        self._counts: dict[str, int] = {}
        self._floors: list[tuple[str, int, str]] = []

    # ---------------------------------------------------------------- declaring and measuring

    def require(self, dimension: str, minimum: int, why: str) -> None:
        """Declare a floor. Declaring the same dimension twice is a programming error, not a merge
        of the two — a second, laxer floor silently replacing a strict one is the failure this whole
        file exists to prevent."""
        if any(name == dimension for name, _, _ in self._floors):
            raise ValueError(f"{self.guard}: scope dimension {dimension!r} already has a floor")
        if minimum < 1:
            raise ValueError(f"{self.guard}: a floor of {minimum} for {dimension!r} asserts nothing")
        self._floors.append((dimension, minimum, why))
        self._counts.setdefault(dimension, 0)

    def add(self, dimension: str, n: int = 1) -> None:
        """Record work that HAPPENED. Call this from the function doing the work."""
        self._counts[dimension] = self._counts.get(dimension, 0) + n

    def get(self, dimension: str) -> int:
        return self._counts.get(dimension, 0)

    def floor_for(self, dimension: str) -> int | None:
        """The declared floor, or None if this dimension is measured but not judged. Guards use it
        to assert that every counter they raise actually has a floor."""
        for name, minimum, _ in self._floors:
            if name == dimension:
                return minimum
        return None

    def merge(self, counts: dict) -> None:
        """Fold in a counter dict returned by a worker function."""
        for dimension, n in counts.items():
            self.add(dimension, n)

    # ---------------------------------------------------------------- judging

    def shortfalls(self) -> list[str]:
        out = []
        for dimension, minimum, why in self._floors:
            actual = self._counts.get(dimension, 0)
            if actual < minimum:
                out.append(
                    f"{dimension}: inspected {actual}, floor is {minimum}. {why}\n"
                    f"      A guard that reports clean over a collapsed input set is worse than a "
                    f"broken detector: it reports success over work it did not do. If the shrink is "
                    f"deliberate, lower the floor in the same change and say why.")
        return out

    def enforce(self, quiet: bool = False) -> int:
        """0 if every floor is met, else 2 (printed as a CI error). Never 1 — a collapsed scope is
        'the guard could not run', not 'the tree has a defect'.

        `quiet` is for self_check() below, whose collapsed ledgers are EXPECTED to fail: printing
        their ::error:: lines would teach readers of a green CI log to skim past that string.
        """
        shortfalls = self.shortfalls()
        if not shortfalls:
            return 0
        if quiet:
            return 2
        print(f"::error::{self.guard}: SCOPE COLLAPSE — the guard inspected less than it claims to.",
              file=sys.stderr)
        for shortfall in shortfalls:
            print(f"  {shortfall}", file=sys.stderr)
        return 2

    def summary(self) -> str:
        """One line naming every measured dimension, for the clean-run message. A clean result that
        does not say how much it looked at is the thing this file was written about."""
        return ", ".join(f"{self._counts[d]} {d}" for d, _, _ in self._floors)

    # ---------------------------------------------------------------- proving the mechanism

    @staticmethod
    def self_check() -> list[str]:
        """Canary for the ledger itself. Returns failure strings; empty means the mechanism works.

        Called from every consuming guard's --self-test so this library is exercised by nine CI jobs
        rather than by nothing.
        """
        failures: list[str] = []

        met = Scope("canary")
        met.require("units", 3, "canary")
        met.add("units", 3)
        if met.enforce() != 0:
            failures.append("Scope.enforce() failed a dimension that exactly meets its floor.")

        collapsed = Scope("canary")
        collapsed.require("units", 3, "canary")
        collapsed.add("units", 1)          # the [:1] truncation shape
        if collapsed.enforce(quiet=True) != 2:
            failures.append("Scope.enforce() did not fail a TRUNCATED dimension (1 of a floor of "
                            "3) — the mechanism would miss every [:1] blinding.")

        empty = Scope("canary")
        empty.require("units", 3, "canary")
        if empty.enforce(quiet=True) != 2:  # the `→ []` shape: nothing recorded at all
            failures.append("Scope.enforce() did not fail a dimension that recorded NOTHING.")

        unmeasured = Scope("canary")
        unmeasured.add("units", 99)          # recorded but never required
        if unmeasured.enforce() != 0 or unmeasured.shortfalls():
            failures.append("Scope treated an undeclared dimension as a shortfall.")

        try:
            twice = Scope("canary")
            twice.require("units", 3, "canary")
            twice.require("units", 1, "canary")
        except ValueError:
            pass
        else:
            failures.append("Scope.require() silently accepted a second, laxer floor for the same "
                            "dimension — a strict floor could be replaced without anyone noticing.")

        return failures


def fixture_line_expectations(path, fired_lines, fire_marker="MUST-FIRE",
                              quiet_marker="MUST-NOT-FIRE") -> list[str]:
    """Compare a line-oriented canary's DECLARED per-line expectations with what actually fired.

    WHY THIS AND NOT A TOTAL. A self-test that only asserts "the fixture produced N offenders" — or,
    worse, "each detector KIND fired at least once" — cannot tell which case produced which. The
    audit measured the consequence on click-to-run-guard: two fixture cases carried comments
    claiming to prove a rule, and blinding that rule left the total unchanged, because a DIFFERENT
    rule was quietly keeping those lines quiet. A fixture whose comments claim coverage it does not
    have is worse than one with no comments, because it stops anyone from looking.

    So a fixture line that must be flagged says so ON THE LINE (`MUST-FIRE`), and a line that must
    stay quiet says `MUST-NOT-FIRE`. Every rule then has at least one line whose verdict flips when
    that rule is blinded, and the failure names the line.

    A line carrying neither marker is unconstrained — fixtures need scaffolding (openers, closing
    delimiters, prose) that no expectation applies to.

    `<fire_marker>-NEXT-LINE` on a line declares the expectation for the line BELOW it. Exactly one
    kind of fixture line needs it: one whose defect is that it carries nothing else. version-anchor's
    bare `// version-anchor-ok:` is the case — appending a marker to it would make it a marker WITH
    text, which is the legal form, so the line would stop being the defect it is there to prove.
    """
    failures = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [f"the canary fixture {path} could not be read ({exc}), so nothing below was proven."]

    deferred = f"{fire_marker}-NEXT-LINE"
    must_fire: set[int] = set()
    must_be_quiet: set[int] = set()
    for i, line in enumerate(lines, 1):
        if deferred in line:
            must_fire.add(i + 1)
        elif quiet_marker in line:
            must_be_quiet.add(i)
        elif fire_marker in line:
            must_fire.add(i)
    if not must_fire:
        failures.append(f"the canary fixture {path.name} declares no {fire_marker} line at all — "
                        "an expectation set that expects nothing cannot fail.")
    if not must_be_quiet:
        failures.append(f"the canary fixture {path.name} declares no {quiet_marker} line — nothing "
                        "proves the guard stays silent on the safe forms beside the broken one.")

    for lineno in sorted(must_fire - set(fired_lines)):
        failures.append(f"{path.name}:{lineno} is marked {fire_marker} and the guard did NOT flag "
                        f"it: {lines[lineno - 1].strip()!r}")
    for lineno in sorted(must_be_quiet & set(fired_lines)):
        failures.append(f"{path.name}:{lineno} is marked {quiet_marker} and the guard flagged it: "
                        f"{lines[lineno - 1].strip()!r}")
    stray = set(fired_lines) - must_fire - must_be_quiet
    for lineno in sorted(stray):
        failures.append(f"{path.name}:{lineno} was flagged but carries no expectation marker. Every "
                        f"line a canary fires on must SAY it is meant to: "
                        f"{lines[lineno - 1].strip()!r}")
    return failures


def _main() -> int:
    failures = Scope.self_check()
    if failures:
        for failure in failures:
            print(f"::error::_scope.py SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2
    print("self-test ok — the scope ledger fails an empty dimension, fails a truncated one, passes "
          "one that meets its floor, ignores undeclared dimensions, and refuses a duplicate floor.")
    return 1


if __name__ == "__main__":
    # THE TERNARY THAT WAS HERE WAS DEAD (removed 2026-08-01). It read
    #     sys.exit(_main() if "--self-test" in sys.argv else _main())
    # — both branches identical, so it was shaped like a mode switch that did not exist. Removed
    # rather than implemented: this file is a library, and proving its own mechanism is the only
    # thing it can be RUN to do, so there is no second mode to switch to. What the ternary's shape
    # promised is now real in the only way that means anything here — an argv this file does not
    # understand exits 2 instead of silently running the self-test and returning its 1, which is
    # every other guard's "the canary fired".
    if sys.argv[1:] != ["--self-test"]:
        print(f"usage: {sys.argv[0]} --self-test   (this file is a library; its only runnable mode "
              f"is proving the scope ledger works)", file=sys.stderr)
        sys.exit(2)
    # Any unhandled exception exits 1, and 1 is this file's "the mechanism works" code — the same
    # collision the consuming guards were hardened against. A crash must never be readable as proof.
    try:
        sys.exit(_main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::_scope.py: crashed ({type(exc).__name__}: {exc}). Exiting 2 — a crash is "
              f"'the harness could not run', never 'the mechanism is proven'.", file=sys.stderr)
        sys.exit(2)
