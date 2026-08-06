#!/usr/bin/env python3
"""Fail CI when a module-number token (MNN) contradicts /modules.yaml.

WHY THIS EXISTS. The Gen-4 renumber moved AppSec M27 -> M08 and shifted every module that had
been M08-M25 up by one. Its sweeps covered `content/` pages and `platform-portfolio/` and stopped
there. Nobody noticed that `apps/`, `bootstrap/`, `helm/`, `tools/` and `content/antora.yml` were
never swept, so 189 lines kept pointing at the pre-renumber catalogue for three weeks — including
strings `bootstrap/install.sh` PRINTS TO AN OPERATOR while an install is failing, and all five
module references in `content/antora.yml`. The drift is invisible: nothing builds differently, no
test fails, and a reader who follows a wrong number simply lands on the wrong module and believes
it.

WHAT THIS ASSERTS — deliberately only two things, both exact.

  P1  RANGE.  Every MNN token names a module that exists: 1 <= NN <= len(modules.yaml).
      Catches the whole class of numbers left over from a catalogue that was longer or
      differently-shaped. Real instances this would have caught on the day it was written:
      `M27` (AppSec's pre-renumber number) in content/antora.yml and a parasol-claims deployment;
      `M29` in parasol-fraud's devfile and pom; `M28` in a FraudResourceTest span.

  P2  WITNESS AGREEMENT.  When a line carries BOTH an MNN and a module SLUG, the number must be
      that slug's position. A slug is an exact, unambiguous witness.

WHAT THIS DELIBERATELY DOES NOT ASSERT, and why. It does not try to decide whether a bare MNN
with no slug on the line is right. That needs to know whether the line is a LIVE REFERENCE or
DATED PROVENANCE — `(found at M12 G1, 2026-07-11)` records a real finding under the numbering
that existed on that date, and "correcting" it would falsify the record. No regex can tell those
apart, and a guard that guessed would either rewrite history or drown in false positives. That
judgment stays human; this guard covers the part that is mechanical.

P2 uses SLUGS ONLY, never title words. An earlier draft matched single distinctive title tokens
and mapped the word "service" to Service Mesh, which turned every pom comment saying "a
long-running service" into a false mismatch — 100 reported, ~3 real. A witness is worth exactly
what it distinguishes.

Run:  tools/lint/module-number-drift-guard.py
Self-test: tools/lint/module-number-drift-guard.py --self-test   (must exit exactly 1)
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

# Zero-padded, two-digit, capital M. NOT `M1`/`M0` — SVG path data is full of `M12 4` moveto
# commands, and the padded form is the project's actual convention for a module reference.
TOKEN = re.compile(r"\bM([0-9]{2})\b")

# Trees excluded from the scan, each for a reason that is about the FILE not about convenience:
#   vendor JS  - third-party bundles; their `M12` are minified identifiers and path data
#   *.svg      - rendered diagrams; `M` is the SVG moveto command, thousands of false hits
#   docs/      - gitignored maintainer-local; never shipped, never read by an attendee
PATHSPEC = [
    ".",
    ":(exclude)docs",
    ":(exclude)content/supplemental-ui/js/vendor",
    ":(exclude)*.svg",
]

# INLINE SVG is the exclusion the *.svg pathspec cannot make. parasol-web's index.html embeds a
# logo as a literal <path d="M32 6C46 6 …"/>, and `M32` there is a moveto command, not a module.
# Excluding by FILE would blind the guard to the rest of that HTML; excluding by LINE is exact.
# Found by this guard's own first real run reporting M30/M32 that do not exist — a guard that
# cries wolf gets switched off, so this is load-bearing, not cosmetic.
SVG_PATH_LINE = re.compile(r"<path\b|\bd=[\"']\s*[Mm][\d.\-]")


def modules(root: Path) -> dict[str, int]:
    """slug -> 1-based position. Position IS the module number (CLAUDE.md, repo map)."""
    doc = yaml.safe_load((root / "modules.yaml").read_text())
    items = doc["modules"] if isinstance(doc, dict) and "modules" in doc else doc
    out = {}
    for i, m in enumerate(items, 1):
        out[m["slug"] if isinstance(m, dict) else m] = i
    return out


def scan(root: Path, slugs: dict[str, int], pathspec: list[str]) -> tuple[list, list]:
    """Return (range_violations, witness_violations)."""
    # -I skips binary. -P because `git grep -E` silently ignores \b and matches NOTHING —
    # that cost a full fabricated "zero findings" result before this was understood.
    proc = subprocess.run(
        ["git", "grep", "-nIP", r"\bM[0-9]{2}\b", "--", *pathspec],
        cwd=root, capture_output=True, text=True,
    )
    count = len(slugs)
    bad_range, bad_witness = [], []

    for line in proc.stdout.splitlines():
        try:
            path, lineno, body = line.split(":", 2)
        except ValueError:
            continue
        # modules.yaml is the source of truth, not a consumer of it.
        if path == "modules.yaml":
            continue
        if SVG_PATH_LINE.search(body):
            continue

        nums = [int(n) for n in TOKEN.findall(body)]
        if not nums:
            continue

        # Report a LINE once per distinct bad value, not once per occurrence: a line reading
        # "M27 gate ... the M27 capstone" is one defect to fix, and printing it twice makes the
        # count overstate the work.
        for n in sorted({n for n in nums if n < 1 or n > count}):
            bad_range.append((path, lineno, n, count, body.strip()[:120]))

        # A slug is an exact witness; two slugs on one line witness nothing in particular.
        present = [s for s in slugs if s in body]
        if len(present) == 1:
            slug = present[0]
            want = slugs[slug]
            if want not in nums:
                bad_witness.append(
                    (path, lineno, sorted(set(nums)), slug, want, body.strip()[:120])
                )

    return bad_range, bad_witness


def report(bad_range: list, bad_witness: list) -> int:
    if not bad_range and not bad_witness:
        print(f"✅ module-number drift: no out-of-range tokens, no slug/number disagreements")
        return 0

    # Each message names its measurement. A message like "wrong state, or it was not reached"
    # is a disjunction the reader cannot act on; it has cost this project four debugging runs.
    for path, lineno, n, count, body in bad_range:
        print(f"❌ {path}:{lineno}: M{n:02d} is out of range — modules.yaml defines {count} "
              f"modules, so the highest valid token is M{count:02d}")
        print(f"     | {body}")
    for path, lineno, got, slug, want, body in bad_witness:
        got_s = "/".join(f"M{g:02d}" for g in got)
        # Do NOT say "the number is wrong" — it may not be. A line can legitimately reference TWO
        # modules, e.g. "(curriculum: M04, observability-health-scale)", where M04 is config-multienv
        # and both halves are correct. What is actually wrong is the MIXED notation: half named,
        # half numbered, so a reader cannot tell whether the number is a second module or a stale
        # copy of the first. Naming both resolves it and cannot rot at the next reorder.
        print(f"❌ {path}:{lineno}: mixed notation — this line names '{slug}' (= M{want:02d}) by "
              f"slug and separately refers to {got_s} by number.")
        print(f"     If {got_s} is a DIFFERENT module, name it too. If it was meant to be "
              f"'{slug}', it is stale — drop it.")
        print(f"     | {body}")

    total = len(bad_range) + len(bad_witness)
    print(f"\n{total} module-number defect(s): "
          f"{len(bad_range)} out-of-range, {len(bad_witness)} slug/number disagreement.")
    print("Fix by naming the module rather than numbering it where the number carries nothing —")
    print("see commit 2a94d79, which decoupled the credits table from numbering for this reason.")
    return 1


def self_test(root: Path) -> int:
    """Build a mutant that violates each property SEPARATELY and assert each is caught.

    Two mutants, not one, and each is checked for ITS OWN message rather than for a non-zero
    exit. A single mutant that trips both properties would let either check rot undetected, and
    asserting only "something failed" is satisfied by a mutant that is merely broken.
    """
    slugs = modules(root)
    count = len(slugs)
    first_slug = next(iter(slugs))
    ok = True

    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / "repo"
        subprocess.run(["git", "init", "-q", str(work)], check=True)
        (work / "modules.yaml").write_text((root / "modules.yaml").read_text())

        # --- canary A: an out-of-range token, and NOTHING else wrong ---
        probe = work / "canary.txt"
        probe.write_text(f"# a comment referring to M{count + 1:02d}\n")
        subprocess.run(["git", "add", "-A"], cwd=work, check=True,
                       capture_output=True)
        rng, wit = scan(work, slugs, ["."])
        if len(rng) != 1:
            print(f"SELF-TEST FAIL [A]: an M{count + 1:02d} token in a tracked file must raise "
                  f"exactly 1 range violation; raised {len(rng)}")
            ok = False
        if wit:
            print(f"SELF-TEST FAIL [A]: the range canary must not also trip the witness "
                  f"property; it raised {len(wit)} — the two properties are not separable")
            ok = False

        # --- canary B: a slug paired with the WRONG number, in range ---
        wrong = (slugs[first_slug] % count) + 1        # in range, and never the right answer
        probe.write_text(f"# {first_slug} is documented here as M{wrong:02d}\n")
        subprocess.run(["git", "add", "-A"], cwd=work, check=True, capture_output=True)
        rng, wit = scan(work, slugs, ["."])
        if rng:
            print(f"SELF-TEST FAIL [B]: the witness canary must not also trip the range "
                  f"property; it raised {len(rng)} — M{wrong:02d} is inside 1..{count}")
            ok = False
        if len(wit) != 1:
            print(f"SELF-TEST FAIL [B]: '{first_slug}' (M{slugs[first_slug]:02d}) written as "
                  f"M{wrong:02d} must raise exactly 1 witness violation; raised {len(wit)}")
            ok = False

        # --- canary C: the NEGATIVE arm. A correct file must raise nothing. ---
        # Without this, a guard that flagged everything would pass A and B and be useless.
        probe.write_text(f"# {first_slug} is documented here as M{slugs[first_slug]:02d}\n")
        subprocess.run(["git", "add", "-A"], cwd=work, check=True, capture_output=True)
        rng, wit = scan(work, slugs, ["."])
        if rng or wit:
            print(f"SELF-TEST FAIL [C]: a CORRECT slug/number pair must raise nothing; "
                  f"raised {len(rng)} range + {len(wit)} witness — the guard cries wolf")
            ok = False

        # --- canary D: the inline-SVG exclusion, BOTH WAYS ---
        # An exclusion is the easiest thing in a guard to widen by accident until it swallows the
        # findings the guard exists for. So prove it is narrow: the SAME out-of-range value must
        # be IGNORED on an SVG path line and CAUGHT on an ordinary line. Testing only the first
        # half would pass just as well if the exclusion swallowed the entire file.
        oor = count + 1
        probe.write_text(f'<path d="M{oor:02d} 6C46 6 58 16 58 30Z" fill="#f2a900"/>\n')
        subprocess.run(["git", "add", "-A"], cwd=work, check=True, capture_output=True)
        rng, _ = scan(work, slugs, ["."])
        if rng:
            print(f"SELF-TEST FAIL [D1]: an SVG path line must be ignored; M{oor:02d} inside "
                  f'd="…" raised {len(rng)} range violation(s)')
            ok = False

        probe.write_text(f"# an ordinary comment mentioning M{oor:02d}\n")
        subprocess.run(["git", "add", "-A"], cwd=work, check=True, capture_output=True)
        rng, _ = scan(work, slugs, ["."])
        if len(rng) != 1:
            print(f"SELF-TEST FAIL [D2]: the SVG exclusion is too wide — the same M{oor:02d} on "
                  f"an ordinary line must still raise exactly 1 violation; raised {len(rng)}")
            ok = False

    if ok:
        print("✅ self-test: range canary, witness canary and the correct-file negative arm "
              "all behaved. Exiting 1 by contract.")
        return 1
    print("❌ self-test: the guard does NOT distinguish what it claims to. See failures above.")
    return 2


def main() -> int:
    root = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"],
                               capture_output=True, text=True, check=True).stdout.strip())
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test(root)
    if args:
        print(f"usage: {sys.argv[0]} [--self-test]", file=sys.stderr)
        return 2
    return report(*scan(root, modules(root), PATHSPEC))


if __name__ == "__main__":
    sys.exit(main())
