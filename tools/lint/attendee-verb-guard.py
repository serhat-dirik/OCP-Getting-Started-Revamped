#!/usr/bin/env python3
"""attendee-verb-guard.py — a verify hint must not tell an attendee to run a verb `ws` refuses.

WHY THIS EXISTS. There are two entry points into one script: `adm` carries the full surface, `ws`
accepts only `list prep verify reset help` and exits 2 on anything else with
"'<verb>' is an instructor/operator command, not part of your workshop."

`tools/verify/*.sh` runs on BOTH sides. Its `hint` strings are the last thing an attendee reads when
a check goes red — the one moment they are already stuck — and 42 of them across 20 files told that
attendee to run `ws start <module> --user <them>`, which the attendee entry point refuses. The lab
then looks broken twice: the check failed, and the fix the tool printed does not work either.

Found 2026-09-10 by running `ws verify m01` rather than reading it, after the SAME defect had been
fixed twice elsewhere in three days — install.sh's closing `next: ws doctor` (6efb5b7) and nine
hint sites in tools/ws/ws (75c274c). Three independent instances of one rule nobody was enforcing
is the definition of a missing gate.

THE RULE. Inside a `hint "…"` in tools/verify/, `ws <verb>` is allowed only when <verb> is one an
attendee actually has. An operator verb may still be NAMED — the established pattern offers both, so
one string serves both readers:

    hint "run: ws prep agentic-ai (or ws start agentic-ai --user ${USER_NAME}); …"

so the check is not "never say start", it is "never say start WITHOUT the attendee's form in the same
hint". 13 hints already did this correctly; the fix was making the other 42 match them.

Scoped to `hint` strings on purpose. Prose and comments in these files legitimately discuss what
`ws start` materializes, and a guard that cannot tell an instruction from a description would be
turned off within a week.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CANARY_DIR = Path(__file__).resolve().parent / "attendee-verb-guard.canary"
VERIFY_REL = "tools/verify"

# The four the attendee tool accepts, plus help. Kept as data rather than parsed out of ws: this
# guard must keep working if ws is unreadable, and a silently-empty set would pass everything.
ATTENDEE_VERBS = {"list", "prep", "verify", "reset", "help"}

RE_HINT = re.compile(r'hint\s+"(?P<body>(?:[^"\\]|\\.)*)"')
RE_WS_VERB = re.compile(r'\bws (?P<verb>[a-z][a-z-]*)')


def offenders(root: Path) -> list[str]:
    out: list[str] = []
    d = root / VERIFY_REL
    if not d.is_dir():
        return out
    for f in sorted(d.glob("*.sh")):
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for h in RE_HINT.finditer(line):
                body = h.group("body")
                verbs = {m.group("verb") for m in RE_WS_VERB.finditer(body)}
                bad = verbs - ATTENDEE_VERBS
                if bad and not (verbs & ATTENDEE_VERBS):
                    v = sorted(bad)[0]
                    remedy = (
                        f"offer both forms, as the rest do:\n"
                        f"        hint \"run: ws prep <slug> (or ws start <slug> --user ${{USER_NAME}})\""
                        if v == "start" else
                        f"{v!r} has no attendee equivalent, so name the OPERATOR tool:\n"
                        f"        hint \"… adm {v} <slug> --user ${{USER_NAME}}\"")
                    out.append(
                        f"{f.relative_to(root)}:{n}  hint says `ws {v}`, which exits 2 for an "
                        f"attendee — {remedy}")
    return out


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()
    positional = [a for a in argv if not a.startswith("-")]
    root = Path(positional[0]).resolve() if positional else REPO

    d = root / VERIFY_REL
    if not d.is_dir():
        print(f"❌ attendee-verb-guard: {VERIFY_REL} not found under {root}.", file=sys.stderr)
        return 2
    scripts = sorted(d.glob("*.sh"))
    if not scripts:
        print(f"❌ attendee-verb-guard: no *.sh under {VERIFY_REL} — refusing to report a clean "
              f"scan of nothing.", file=sys.stderr)
        return 2

    bad = offenders(root)
    if bad:
        print("❌ attendee-verb-guard: verify hints tell attendees to run a command `ws` refuses.\n",
              file=sys.stderr)
        for b in bad:
            print(f"  • {b}", file=sys.stderr)
        return 1
    print(f"attendee-verb-guard: clean — {len(scripts)} verify script(s); no hint tells an "
          f"attendee to run a verb `ws` refuses (operator verbs either offer the attendee's form "
          f"alongside, or name `adm` outright).")
    return 0


def _drive(root: Path) -> tuple[int, str]:
    import contextlib, io
    buf, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
        rc = main([str(root)])
    return rc, buf.getvalue() + err.getvalue()


CASES = [
    # `start` HAS an attendee equivalent, so the remedy is "offer both".
    ("canary-operator-verb", 1, "offer both forms"),
    # `solve` does NOT, so the remedy is "name adm" — a different sentence, and the only fixture
    # that proves the guard distinguishes the two rather than printing one stock hint.
    ("canary-no-attendee-form", 1, "no attendee equivalent"),
    ("control-good", 0, "clean"),
]


def self_test() -> int:
    problems: list[str] = []
    if not CANARY_DIR.is_dir():
        print(f"❌ SELF-TEST FAILED: fixtures missing at {CANARY_DIR}", file=sys.stderr)
        return 2
    for name, want_rc, needle in CASES:
        rc, out = _drive(CANARY_DIR / name)
        if rc != want_rc:
            problems.append(f"[{name}] expected rc={want_rc}, got {rc}. Output: {out.strip()[:250]!r}")
        elif needle not in out:
            problems.append(f"[{name}] rc right but {needle!r} absent. Printed: {out.strip()[:250]!r}")
    if _drive(REPO)[0] == 2:
        problems.append("[real-tree] guard could not inspect the repo (rc=2); a clean fixture run "
                        "proves nothing about it.")
    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2
    print(f"✅ self-test ok — {len(CASES)} fixture tree(s) through the real main(): a verb WITH an "
          f"attendee equivalent and one WITHOUT each caught and given their own remedy, and a hint "
          f"offering both forms correctly left silent.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
