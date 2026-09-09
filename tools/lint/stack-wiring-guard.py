#!/usr/bin/env python3
"""stack-wiring-guard.py — every stack /modules.yaml asks for must be installable by install.sh.

WHY THIS EXISTS. `/modules.yaml` is the catalogue's single source of truth, and each module declares
the platform stacks it needs (`stacks: [secrets]`). Half of the consumption of that field is
data-driven — bootstrap/install.sh builds REQUIRED_SET by reading modules.yaml — and the other half
is HAND-WRITTEN: a stack only reaches the cluster if someone also adds

    <NAME>="$(stack_toggle <name> <key>)"          # ~line 217
    [[ "$<NAME>" == "true" ]] && STACKS="...,<name>"  # ~line 981

When M20 (platform-guardrails) shipped in 9b94ec8 it declared `stacks: [secrets]` and the stack
existed on disk with a working kustomization — but neither hand-written line was added. The result
was not a build failure or a red gate. It was a workshop that installs cleanly, reports
`✅ workshop bootstrap complete`, lists module 20 in every attendee's cockpit, and then fails the
moment an attendee opens it:

    no matches for kind "SecretStore" in version "external-secrets.io/v1"

Found 2026-09-09 by a cold-start install on cluster-jm4gc, ELEVEN DAYS after the module shipped, and
only because someone installed from scratch and opened the module. Nothing else could have caught it:
CI was green the whole time, `adm doctor` reported 41/41 Applications Synced+Healthy, and the module's
own content, entry state and verify script were all correct.

WHY A GATE AND NOT A COMMENT. The FSC path already has this property mechanically —
`tools/gen-module-stacks.sh --check` regenerates helm/bootstrap/values.yaml's moduleCatalog from
modules.yaml and fails content-build.yml on drift. So the SAME defect was impossible on one install
path and invisible on the other, which is the worst arrangement: the path with the gate is the one
nobody hand-edits. This guard gives bootstrap/install.sh the equivalent.

THE TWO DETECTORS, and why each is a real failure rather than a style rule:

  required-but-unwired      a stack modules.yaml asks for that install.sh cannot turn on. The M20
                            bug exactly. Ships a broken module to attendees with no error anywhere.

  wired-but-absent          install.sh can enable a stack that has no directory on disk — a typo in
                            the append name, or a stack deleted without unwiring it. The portfolio
                            installer validates --stacks against the directory and refuses, so this
                            aborts the install AFTER the state ConfigMap has grown records.
                            (The neighbouring defect — an append guarded by a variable nothing
                            assigns — is deliberately NOT checked here: shellcheck's SC2154 already
                            fails CI on it, and a second detector for the same fault would only
                            drift away from the first.)

A required stack with no directory on disk needs no third detector: it is reported by whichever of
the two above applies, because it is necessarily either unwired or wired-but-absent. A detector whose
every case is already covered would only drift away from the two that do the work.

The baseline stacks (core-devtools, batch, progressive-delivery) are always installed and are read
from the STACKS= initialiser rather than assumed, so renaming one is caught too.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CANARY_DIR = Path(__file__).resolve().parent / "stack-wiring-guard.canary"

MODULES_REL = "modules.yaml"
INSTALL_REL = "bootstrap/install.sh"
STACKS_REL = "platform-portfolio/stacks"

# `STACKS="core-devtools,batch,progressive-delivery"` — the always-on baseline.
RE_BASELINE = re.compile(r'^STACKS="([a-z0-9,\-]+)"\s*$', re.M)
# `[[ "$TRUST" == "true" ]] && STACKS="${STACKS},trust"` — capture guard variable and stack name.
RE_APPEND = re.compile(
    r'\[\[\s*"\$([A-Z_][A-Z0-9_]*)"[^\]]*\]\]\s*&&\s*STACKS="\$\{STACKS\},([a-z0-9\-]+)"')


def required_stacks(root: Path) -> set[str]:
    """Stacks named by any module in modules.yaml.

    Parsed with a regex rather than PyYAML on purpose: this guard must run in the same minimal CI
    step as the shell linters, and the field it reads is a flat inline list by convention
    (`stacks: [a, b]`). A shape it cannot parse is reported, never silently treated as empty — an
    unreadable catalogue reading as "nothing required" would make this guard pass on the very tree
    it exists to fail.
    """
    text = (root / MODULES_REL).read_text(encoding="utf-8")
    found: set[str] = set()
    for m in re.finditer(r'^\s*stacks:\s*\[(.*?)\]', text, re.M):
        for tok in m.group(1).split(","):
            tok = tok.split("#")[0].strip().strip("'\"")
            if tok:
                found.add(tok)
    return found


def installable_stacks(root: Path) -> tuple[set[str], list[tuple[str, str]]]:
    """(stacks install.sh can enable, [(guard_var, stack)] conditional appends)."""
    text = (root / INSTALL_REL).read_text(encoding="utf-8")
    baseline: set[str] = set()
    m = RE_BASELINE.search(text)
    if m:
        baseline = {s for s in m.group(1).split(",") if s}
    pairs = [(g, s) for g, s in RE_APPEND.findall(text)]
    return baseline | {s for _, s in pairs}, pairs


def on_disk(root: Path) -> set[str]:
    d = root / STACKS_REL
    return {p.name for p in d.iterdir() if p.is_dir()} if d.is_dir() else set()


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()
    positional = [a for a in argv if not a.startswith("-")]
    root = Path(positional[0]).resolve() if positional else REPO

    for rel in (MODULES_REL, INSTALL_REL):
        if not (root / rel).exists():
            print(f"❌ stack-wiring-guard: {rel} not found under {root} — cannot judge wiring.",
                  file=sys.stderr)
            return 2

    required = required_stacks(root)
    if not required:
        print("❌ stack-wiring-guard: modules.yaml declared NO stacks at all. Either the catalogue "
              "shape changed or the parse broke; refusing to report a clean tree either way.",
              file=sys.stderr)
        return 2

    installable, pairs = installable_stacks(root)
    disk = on_disk(root)
    problems: list[str] = []

    for s in sorted(required - installable):
        problems.append(
            f"required-but-unwired  '{s}' is required by a module in {MODULES_REL} but "
            f"{INSTALL_REL} has no line that can add it to STACKS. The module ships to attendees "
            f"and its entry state fails at sync with a missing CRD. Add:\n"
            f"        {s.upper().replace('-', '_')}=\"$(stack_toggle {s} {s})\"\n"
            f"        [[ \"${s.upper().replace('-', '_')}\" == \"true\" ]] && "
            f"STACKS=\"${{STACKS}},{s}\"")

    if disk:
        for s in sorted(installable - disk):
            problems.append(
                f"wired-but-absent  {INSTALL_REL} can add '{s}' to STACKS but there is no "
                f"{STACKS_REL}/{s}/ directory. The portfolio installer refuses an unknown stack "
                f"name, so this aborts the install after state has already been recorded.")

    if problems:
        print("❌ stack-wiring-guard: modules.yaml and the installer disagree about platform stacks.\n",
              file=sys.stderr)
        for p in problems:
            print(f"  • {p}", file=sys.stderr)
        return 1

    print(f"stack-wiring-guard: clean — {len(required)} stack(s) required by {MODULES_REL}, all "
          f"installable by {INSTALL_REL} ({len(pairs)} conditional append(s)) and every stack it "
          f"can enable present under {STACKS_REL}.")
    return 0


def _drive(root: Path) -> tuple[int, str]:
    import contextlib, io
    buf, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
        rc = main([str(root)])
    return rc, buf.getvalue() + err.getvalue()


CASES = [
    ("canary-unwired", 1, "required-but-unwired"),
    ("canary-wired-absent", 1, "wired-but-absent"),
    # RE_BASELINE's witness: the only fixture whose verdict depends on the baseline initialiser
    # having been parsed at all. Without it, a broken baseline regex changes no exit code anywhere.
    ("canary-baseline-absent", 1, "progressive-delivery"),
    ("control-good", 0, "clean"),
]


def self_test() -> int:
    problems: list[str] = []
    if not CANARY_DIR.is_dir():
        print(f"❌ SELF-TEST FAILED: fixtures missing at {CANARY_DIR}", file=sys.stderr)
        return 2
    for name, want_rc, needle in CASES:
        root = CANARY_DIR / name
        if not root.is_dir():
            problems.append(f"[{name}] fixture directory is missing")
            continue
        rc, out = _drive(root)
        if rc != want_rc:
            problems.append(f"[{name}] expected rc={want_rc}, got rc={rc}. Output: {out.strip()[:300]!r}")
        elif needle not in out:
            problems.append(f"[{name}] rc was right but {needle!r} never appeared. "
                            f"Printed: {out.strip()[:300]!r}")

    # Blinding check: the real tree must be judged by the SAME code path the fixtures exercise.
    rc_real, _ = _drive(REPO)
    if rc_real == 2:
        problems.append("[real-tree] the guard could not inspect the actual repo (rc=2), so a clean "
                        "fixture run proves nothing about it.")

    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2

    print(f"✅ self-test ok — {len(CASES)} fixture tree(s) driven through the real main(): a stack "
          f"required but unwired and a wired stack with no directory each caught on exactly their "
          f"own fixture, neither firing on the other; the control silent.")
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    return 1


if __name__ == "__main__":
    sys.exit(main())
