#!/usr/bin/env python3
"""Nothing may decide what a NAMED stack ships by globbing its apps/ directory.

WHY THIS EXISTS (the defect it was written for, verified end-to-end 2026-08-23).

`platform-portfolio/stacks/<stack>/kustomization.yaml` is the authority on which `apps/*.yaml` a
stack actually ships. A stack may carry an app file that is deliberately COMMENTED OUT of that
`resources:` list — today `stacks/observability/apps/loki-logging.yaml`, capacity-gated behind ODF
object storage. Such a file is never rendered, its child Application never exists, and its operators
are never installed. `platform-portfolio/argocd-bootstrap/lib-components.sh` provides
`active_app_files()` for exactly this and states the rule in its own header: *"Any new consumer must
use active_app_files(), never a glob."*

Two consumers never got converted, and the difference was a safety property, not tidiness:

    bootstrap/install.sh          snapshot_operators()    — globbed apps/*.yaml
    bootstrap/ogsr-uninstall.sh   enumerate_operators()   — globbed apps/*.yaml

The glob credited loki-logging's Subscriptions to the workshop, so a workshop install recorded

    op_loki-operator=created:openshift-operators-redhat
    op_cluster-logging=created:openshift-logging

for two operators nobody installed. `created:<ns>` is the SOLE authorization
`csv_delete_authorized_by_state()` consults, and `del_created_csv()` — "the ONE place that deletes a
CSV" — deletes on it. So: install the workshop with the observability stack, let the org install
OpenShift Logging later under those same standard names, run `ogsr-uninstall.sh`, and the teardown
deletes the ORG'S CSV. That is verbatim the outcome `del_created_csv`'s own refusal message exists to
prevent — *"An adopted operator's CSV belongs to the org — deleting it would uninstall their
operator."* — reached not by defeating the guard but by feeding it a false record upstream.

Measured, running the real functions against the real tree with `oc` stubbed to find nothing:
BEFORE, both functions enumerated 10 operators including the two above; AFTER, both enumerate the
same 8 and neither loki-logging operator appears. `csv_delete_authorized_by_state loki-operator
openshift-operators-redhat` returns TRUE on `created:…` and FALSE on no record at all.

The bug's mechanism is duplication: one derivation existed in a library, and three consumers had
hand-rolled their own. So this guard is aimed at the duplication, not at the two symptoms.

THE HONEST DISCRIMINATOR, which is the whole design problem here. Globbing `apps/*.yaml` is NOT
always wrong, and a guard that reddens on correct work gets switched off. The line is *which
question is being asked*:

  * `stacks/<one named or parameterised stack>/apps/*.yaml`  → asks "what does stack X SHIP?" The
    kustomization is the authority; the directory is not. ALWAYS a defect.
  * `stacks/*/apps/*.yaml` (every stack)                     → asks "is every AUTHORED app file
    well-formed?" or "which file declares Application Y?" On-disk is the right domain, precisely
    because a disabled file must still be correct on the day someone enables it. LEGITIMATE.

Three sites in this repo depend on the second reading and must stay green:
`platform-portfolio/hack/check-teardown-invariants.sh` (its sync-wave PAIRS table names
`pp-loki-logging`, which only resolves because it sweeps all stacks) and `bootstrap/install.sh`'s
`owning_stack_of_app()` (a reverse lookup for a fix hint, over an app already live on the cluster,
whose behaviour `tools/lint/owning-stack-guard.sh` separately locks).

WHAT IT CHECKS

  PER-STACK-GLOB           no tracked file globs a named stack's apps/ directory       (rc 1)
  SECOND-IMPLEMENTATION    only lib-components.sh may define active_app_files()        (rc 1)
  CALLER-NOT-SOURCED       a caller of active_app_files() must source the library      (rc 1)
  PEER-DIVERGENCE          install.sh and ogsr-uninstall.sh both use it, or neither    (rc 1)
  LIBRARY-DISAGREES        the library's answer == the kustomization's, every stack    (rc 1)
  UNREADABLE-KUSTOMIZATION a stack whose `resources:` is present but not a list        (rc 1)
  STALE / VANISHED         a declared-debt entry that no longer describes a defect     (rc 1)

PEER-DIVERGENCE is not implied by the others and is the reason this file names two scripts at all.
`bootstrap/install.sh:436` states the contract in the tree's own words — the install and the
teardown "can never hold two different opinions about who owns an operator" — and the failure mode
it guards is asymmetric conversion: fix one, leave the other, and the install stops recording an
operator the teardown still enumerates (or worse, the reverse). Both halves now derive stack
membership from the same function in the same file, which is what makes agreement structural rather
than reviewed.

LIBRARY-DISAGREES is the only behavioural check here, and it is what stops this guard from being
purely textual. Both scripts now REST on `active_app_files()`; if that function ever starts agreeing
with the directory instead of the kustomization — a rewritten awk, a flow-style `resources: [a, b]`
list its parser cannot see — every consumer silently inherits the original defect while every
textual check above stays green. So the shipped Bash function is EXECUTED and its answer compared
against an independent YAML parse of the same kustomization.

EXIT CODES (the house convention, inverted on purpose)
    plain        0 = clean, 1 = a finding above, 2 = could not inspect
    --self-test  MUST exit EXACTLY 1 (real tree clean AND every canary case detected).
                 0 = a detector is blind. 2 = the harness is broken. A crash maps to 2, never 1.

SCOPE. The real run inspects `git ls-files`, not a filesystem walk. That is deliberate and was
learned the hard way in this repo's shellcheck job: a walk on a maintainer laptop selected 449 files,
395 of them agent worktrees under `.claude/`, which here would mean stale COPIES of install.sh
reporting as live defects. Canary fixtures are walked instead, because they are not tracked.

KNOWN BLIND SPOTS, stated rather than left implicit:
  * FULL-LINE `#` comments are stripped before scanning, for the same reason `guard-wiring-guard.py`
    strips them: several guard headers legitimately QUOTE the anti-pattern
    (`owning-stack-guard.sh:6,15`, `operatorgroup-uniqueness-guard.sh:30` all write
    `stacks/**/apps/*.yaml` in prose), and a naive text match reports prose as code. A glob hidden
    behind a TRAILING comment on a code line is therefore invisible — and, symmetrically, a trailing
    comment that quotes the shape would be a false positive. Put such prose on its own line.
  * Variable indirection evades the text match: assign a per-stack apps directory to a variable on
    one line and glob the variable on the next. PEER-DIVERGENCE covers the specific pair that
    matters; the realistic reintroduction — copy-pasting the old `for app in …/${stack}/apps"/*.yaml`
    line — is caught exactly.
  * This file and its canary fixtures are excluded from the real-tree scan: both contain the shape
    on purpose. Self-coverage is what `--self-test` is for.

USAGE
    tools/lint/active-app-files-guard.py              # check the real tree
    tools/lint/active-app-files-guard.py --self-test  # prove it fires; must exit EXACTLY 1
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception -> rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import would exit
    1 — exactly what this guard's CI step reads as "the canary fired". `os._exit` is what makes the
    code stick: an excepthook cannot change the exit status by returning.
    """
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print("::error::active-app-files-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          "'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem, not a finding
    print("ERROR: PyYAML is not installed — LIBRARY-DISAGREES cannot compare the library's answer "
          "against an independent parse without it.", file=sys.stderr)
    sys.exit(2)


def _compile(name: str, pattern: str, flags: int = 0) -> re.Pattern:
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    A module-level `re.error` raises before main() can run and Python exits 1, which is exactly what
    CI's "--self-test must exit EXACTLY 1" assertion reads as proven detection. A regex typo must
    never report detection as proven.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:  # pragma: no cover - a typo in this file, caught before it can lie
        print(f"::error::active-app-files-guard: {name} is not a valid regex ({exc}). Exiting 2.",
              file=sys.stderr)
        sys.exit(2)


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
GUARD_NAME = "active-app-files-guard"
CANARY_DIR = pathlib.Path(__file__).resolve().parent / f"{GUARD_NAME}.canary"

LIB_REL = "platform-portfolio/argocd-bootstrap/lib-components.sh"
STACKS_REL = "platform-portfolio/stacks"
READER = "active_app_files"

# The two scripts the ownership contract binds together. bootstrap/install.sh writes the
# `op_<sub>=created|adopted:<ns>` records; bootstrap/ogsr-uninstall.sh acts on them, up to and
# including deleting a CSV. They must derive stack membership the same way or the record means one
# thing on the way in and another on the way out.
PEERS = ("bootstrap/install.sh", "bootstrap/ogsr-uninstall.sh")

# A per-stack glob, after quotes are stripped from the line: `stacks/<seg>/apps/*.yaml` where <seg>
# is whatever sits between them. Quote-stripping is what makes the shell's own splicing readable —
# the shipped defect was written `".../stacks/${stack}/apps"/*.yaml`, with the quote INSIDE the path.
PER_STACK_GLOB_RE = _compile("PER_STACK_GLOB_RE", r"stacks/([^/\s]+)/apps/\*\.ya?ml")

# `active_app_files() {` / `active_app_files(){` at the start of a line — a Bash definition. The
# Python spelling is included so a future port cannot quietly become the second implementation.
READER_DEF_RE = _compile("READER_DEF_RE", rf"^\s*(?:def\s+{READER}\s*\(|{READER}\s*\(\)\s*\{{)",
                         re.MULTILINE)

# A CALL. Deliberately not the same pattern as the definition: `active_app_files "$stack"` in
# command position, never `active_app_files()` with parens, which is the definition shape.
READER_CALL_RE = _compile("READER_CALL_RE", rf"(?<![\w-]){READER}\s+(?!\()\S")

FULL_LINE_COMMENT_RE = _compile("FULL_LINE_COMMENT_RE", r"^\s*#")

# A stack's kustomization, by repo-relative path. Used to derive WHICH stacks the behavioural half
# inspects from the same file list the text half scans, so both halves share one scope.
STACK_KUSTOMIZATION_RE = _compile("STACK_KUSTOMIZATION_RE",
                                  rf"{re.escape(STACKS_REL)}/([^/]+)/kustomization\.yaml")

# Only text a shell or a template could execute. `.md` is absent on purpose: documentation that
# describes the anti-pattern is not the anti-pattern, and this repo's docs quote it often.
SCANNED_SUFFIXES = (".sh", ".bash", ".yaml", ".yml", ".py")

# ── declared-debt ledger ──────────────────────────────────────────────────────
# Convention and format: tools/lint/LEDGERS.md, following check-adoption-skip.sh's KNOWN_STRANDS —
# the one that page rates ✅ on every property, notably "a declared item is REPORTED and the green
# line never claims blanket safety".
#
#   key   = repo-relative path that still carries a per-stack glob
#   value = "<YYYY-MM-DD> | <why it is not fixed here> | decision: <who defers it>"
#
# BOTH rot directions fail (see check_ledger): an entry whose file no longer globs is STALE, and an
# entry whose file is gone is VANISHED. So the list can only ever shrink, and it cannot outlive the
# defect it describes — which is the exact failure LEDGERS.md was written to prevent.
#
# EMPTY, and it stays empty until someone declares new debt. The one entry it ever carried —
# helm/bootstrap/templates/job-state-capture.yaml, the FSC/RHDP twin that was still globbing after
# both bootstrap/ scripts were converted — was paid off on 2026-08-23: that Job now sources
# lib-components.sh off the init container's existing platform-portfolio/ sparse checkout and calls
# active_app_files(), so all three consumers of the ownership record share one derivation. The guard
# went STALE-DECLARATION the moment the glob left, which is the mechanism that forced this deletion.
DECLARED_GLOBS: dict[str, str] = {}


def is_all_stacks_sweep(segment: str) -> bool:
    """True when the path segment between `stacks/` and `/apps` selects EVERY stack.

    A bare `*` is the sweep. Anything else — a literal stack name, `${stack}`, `$1` — names one
    stack, and for one stack the kustomization is the authority. This predicate IS the honest
    discriminator described in the module docstring; getting it wrong in either direction is how
    this guard would either miss the defect or redden on correct work.
    """
    return segment == "*"


def strip_full_line_comments(text: str) -> str:
    """Drop whole-line `#` comments. See KNOWN BLIND SPOTS in the module docstring."""
    return "\n".join("" if FULL_LINE_COMMENT_RE.match(line) else line
                     for line in text.split("\n"))


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return ""


def tracked_files(root: pathlib.Path) -> list[pathlib.Path] | None:
    """Every tracked file with a scanned suffix. None when git cannot answer — never a silent walk."""
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    rels = [r for r in out.stdout.split("\0") if r]
    return [root / r for r in rels if r.endswith(SCANNED_SUFFIXES)]


def walked_files(root: pathlib.Path) -> list[pathlib.Path]:
    """Fixture-tree equivalent of tracked_files. Canary trees are not in git."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            if name.endswith(SCANNED_SUFFIXES):
                found.append(pathlib.Path(dirpath) / name)
    return sorted(found)


def excluded(path: pathlib.Path, root: pathlib.Path) -> bool:
    """This guard and its fixtures carry the shape on purpose; everything else is in scope."""
    rel = path.relative_to(root).as_posix()
    return rel == f"tools/lint/{GUARD_NAME}.py" or rel.startswith(f"tools/lint/{GUARD_NAME}.canary/")


# ── the checks ────────────────────────────────────────────────────────────────

def check_per_stack_globs(files: list[pathlib.Path], root: pathlib.Path,
                          ledger: dict[str, str]) -> tuple[list[str], set[str]]:
    """PER-STACK-GLOB. Returns (problems, the set of ledgered paths observed still globbing)."""
    problems: list[str] = []
    observed: set[str] = set()
    for path in files:
        if excluded(path, root):
            continue
        rel = path.relative_to(root).as_posix()
        body = strip_full_line_comments(read_text(path))
        hits = []
        for lineno, line in enumerate(body.split("\n"), start=1):
            for match in PER_STACK_GLOB_RE.finditer(line.replace('"', "").replace("'", "")):
                if not is_all_stacks_sweep(match.group(1)):
                    hits.append((lineno, match.group(0)))
        if not hits:
            continue
        if rel in ledger:
            observed.add(rel)
            continue
        for lineno, text in hits:
            problems.append(
                f"PER-STACK-GLOB  {rel}:{lineno}  `{text}` enumerates one stack's apps/ directory. "
                f"The kustomization `resources:` list is the authority on what a stack ships — the "
                f"directory also holds deliberately disabled app files. Source {LIB_REL} and call "
                f"{READER} <stack>.")
    return problems, observed


def check_single_implementation(files: list[pathlib.Path], root: pathlib.Path) -> list[str]:
    """SECOND-IMPLEMENTATION. A copied derivation that drifts is how this defect happened."""
    problems: list[str] = []
    for path in files:
        if excluded(path, root):
            continue
        rel = path.relative_to(root).as_posix()
        if rel == LIB_REL:
            continue
        if READER_DEF_RE.search(strip_full_line_comments(read_text(path))):
            problems.append(
                f"SECOND-IMPLEMENTATION  {rel} defines {READER}() itself. Exactly one definition may "
                f"exist, in {LIB_REL}: two implementations drift, and the way they drift is one of "
                f"them quietly disagreeing about a disabled app — which is this defect, again.")
    return problems


def check_callers_source_the_library(files: list[pathlib.Path], root: pathlib.Path) -> list[str]:
    """CALLER-NOT-SOURCED. Calling it without sourcing it is a 127 that `|| true` can swallow."""
    problems: list[str] = []
    for path in files:
        if excluded(path, root):
            continue
        rel = path.relative_to(root).as_posix()
        if rel == LIB_REL:
            continue
        body = strip_full_line_comments(read_text(path))
        if not READER_CALL_RE.search(body):
            continue
        if "lib-components.sh" in body:
            continue
        problems.append(
            f"CALLER-NOT-SOURCED  {rel} calls {READER} but never sources lib-components.sh. An "
            f"undefined function is a 127 exit, and every call site here is inside a `|| true` or a "
            f"process substitution — so the failure reads as 'this stack ships no apps', which is "
            f"the silent-empty-answer shape.")
    return problems


def check_peer_agreement(root: pathlib.Path) -> list[str]:
    """PEER-DIVERGENCE. Asymmetric conversion of the install/teardown pair."""
    problems: list[str] = []
    using = {}
    for rel in PEERS:
        body = strip_full_line_comments(read_text(root / rel))
        using[rel] = bool(READER_CALL_RE.search(body)) and "lib-components.sh" in body
    if len(set(using.values())) > 1:
        yes = sorted(r for r, v in using.items() if v)
        no = sorted(r for r, v in using.items() if not v)
        problems.append(
            f"PEER-DIVERGENCE  {', '.join(yes)} derives stack membership through {READER} and "
            f"{', '.join(no)} does not. These two must agree by construction: one records "
            f"op_<sub>=created|adopted:<ns>, the other DELETES on that record. bootstrap/install.sh "
            f"states the contract — they 'can never hold two different opinions about who owns an "
            f"operator'. Convert both or neither.")
    return problems


def kustomization_apps(path: pathlib.Path) -> list[str] | None:
    """The `apps/*.yaml` entries a kustomization lists, parsed independently of the shipped awk."""
    try:
        doc = yaml.safe_load(read_text(path))
    except yaml.YAMLError:
        return None
    if not isinstance(doc, dict):
        return None
    resources = doc.get("resources") or []
    if not isinstance(resources, list):
        return None
    return sorted(r for r in resources
                  if isinstance(r, str) and r.startswith("apps/") and r.endswith((".yaml", ".yml")))


def check_library_behaviour(root: pathlib.Path, lib: pathlib.Path, stacks_dir: pathlib.Path,
                            stacks: list[str]) -> tuple[list[str], list[str], int]:
    """LIBRARY-DISAGREES. Executes the shipped Bash reader and compares it to an independent parse.

    `stacks` is passed IN rather than discovered by walking stacks_dir, so this half inspects exactly
    the same scope the text half does. Walking would reintroduce the machine-dependence the SCOPE
    paragraph rejects from the other direction: a stack another lane is mid-way through creating —
    on disk, not yet committed — would be judged here and not there, so the guard's verdict would
    depend on whose working tree it ran in.

    Returns (problems, notes, rc2) — rc2 is set when the comparison could not be made at all, which
    is could-not-inspect, never a pass.
    """
    problems: list[str] = []
    notes: list[str] = []
    if shutil.which("bash") is None:
        return problems, notes, 2
    if not lib.is_file():
        return problems, notes, 2
    if not stacks_dir.is_dir():
        return problems, notes, 2
    if not stacks:
        return problems, notes, 2

    disabled: dict[str, tuple[int, list[str]]] = {}
    for stack in stacks:
        kust = stacks_dir / stack / "kustomization.yaml"
        expected = kustomization_apps(kust)
        if expected is None:
            problems.append(
                f"UNREADABLE-KUSTOMIZATION  {STACKS_REL}/{stack}/kustomization.yaml has no readable "
                f"`resources:` list (absent is fine; a non-list is not), so nothing in this repo can "
                f"say what that stack ships — including the reader every consumer now depends on.")
            continue
        try:
            out = subprocess.run(
                ["bash", "-c", f'. "$1"; {READER} "$2"', "_", str(lib), stack],
                capture_output=True, text=True, timeout=60,
                env={**os.environ, "STACKS_DIR": str(stacks_dir)})
        except (OSError, subprocess.SubprocessError):
            return problems, notes, 2
        actual = sorted(l for l in out.stdout.split("\n") if l.strip())
        if actual != expected:
            problems.append(
                f"LIBRARY-DISAGREES  {READER} {stack} returned {actual or '[]'} but the "
                f"kustomization lists {expected or '[]'}. Every consumer now RESTS on that function; "
                f"if it starts answering from the directory instead of `resources:`, all of them "
                f"silently inherit the original defect while every textual check here stays green.")
        on_disk = sorted(f"apps/{p.name}" for p in (stacks_dir / stack / "apps").glob("*.y*ml")) \
            if (stacks_dir / stack / "apps").is_dir() else []
        extra = sorted(set(on_disk) - set(expected))
        if extra:
            disabled[stack] = (len(expected), extra)
    # NOTES, NOT FINDINGS — built by comprehension rather than by appending, so nothing here looks
    # like a detector to tools/lint/_canary-coverage.py. An informational line cannot be witnessed by
    # blinding it (no exit code moves), and a detector that cannot be witnessed is exactly what that
    # sweep exists to flag; shaping the code so the two are distinguishable is cheaper than declaring
    # an exemption for something that was never a detector.
    #
    # The empty case is said OUT LOUD: a tree where every app file is enabled is legitimate, but it
    # means the comparison above had no disabled file to disagree about, and a reader should know
    # that before reading the green tick as proof.
    notes = ([f"{s}: {n} active, disabled on disk: {x}" for s, (n, x) in sorted(disabled.items())]
             or ["no stack currently disables an app file — the behavioural comparison ran, but on "
                 "this tree it had no disabled app to distinguish."])
    return problems, notes, 0


def check_ledger(ledger: dict[str, str], observed: set[str], root: pathlib.Path) -> list[str]:
    """Both rot directions. A declaration must never outlive the defect it describes."""
    problems: list[str] = []
    for rel, reason in sorted(ledger.items()):
        if not (root / rel).exists():
            problems.append(
                f"VANISHED-DECLARATION  {rel} is declared in DECLARED_GLOBS but is not in the tree. "
                f"The entry suppresses nothing, and the next file to take that path inherits a "
                f"suppression nobody chose. Delete it. ({reason})")
            continue
        if rel not in observed:
            problems.append(
                f"STALE-DECLARATION  {rel} is declared in DECLARED_GLOBS but no longer globs a named "
                f"stack's apps/ directory — the debt is paid. Delete the entry so the guard goes back "
                f"to making its unqualified claim. ({reason})")
    return problems


# ── driver ────────────────────────────────────────────────────────────────────

class CouldNotInspect(Exception):
    """rc 2. Raised where the guard cannot read what it claims to — never dressed up as a finding."""


def collect(root: pathlib.Path, *, tracked: bool = True,
            ledger: dict[str, str] | None = None) -> tuple[list[str], list[str], set[str], int]:
    """Every finding for a tree -> (problems, notes, ledgered-paths-still-globbing, files-scanned).

    THE ONE PIPELINE. `run()` reports what this returns and `self_test()` drives its canary fixtures
    through this same function — deliberately, and it is not a stylistic choice. A self-test that
    calls the check functions directly leaves every `problems.extend(...)` line below unwitnessed:
    delete one and the check goes dead in the real run while the self-test keeps passing. That is
    verbatim the `hook-env-guard.py` defect tools/lint/_canary-coverage.py was built to find, and it
    found it here too, on the first sweep of this file.

    Raises CouldNotInspect for rc 2.
    """
    active_ledger = DECLARED_GLOBS if ledger is None else ledger

    files = tracked_files(root) if tracked else walked_files(root)
    if files is None:
        raise CouldNotInspect(
            f"`git ls-files` could not answer in {root}. Refusing to fall back to a filesystem walk "
            f"— a walk picks up agent worktrees under .claude/ and reports stale copies of "
            f"install.sh as live defects.")
    if not files:
        raise CouldNotInspect(f"inspected zero files under {root}. Scanning nothing is never a pass.")

    problems: list[str] = []
    glob_problems, observed = check_per_stack_globs(files, root, active_ledger)
    problems.extend(glob_problems)
    problems.extend(check_single_implementation(files, root))
    problems.extend(check_callers_source_the_library(files, root))
    problems.extend(check_peer_agreement(root))

    stacks = sorted({m.group(1) for m in
                     (STACK_KUSTOMIZATION_RE.fullmatch(f.relative_to(root).as_posix())
                      for f in files) if m})
    behaviour, notes, rc2 = check_library_behaviour(root, root / LIB_REL, root / STACKS_REL, stacks)
    if rc2:
        raise CouldNotInspect(
            f"could not execute {READER} from {LIB_REL} against {STACKS_REL} — bash, the library or "
            f"the stacks tree is missing. The behavioural half is the only thing standing between a "
            f"textual pass and a real one, so this is could-not-inspect, not clean.")
    problems.extend(behaviour)
    problems.extend(check_ledger(active_ledger, observed, root))

    return problems, notes, observed, sum(1 for f in files if not excluded(f, root))


def run(root: pathlib.Path, *, tracked: bool = True,
        ledger: dict[str, str] | None = None, quiet: bool = False) -> int:
    """0 clean · 1 a finding · 2 could not inspect."""
    active_ledger = DECLARED_GLOBS if ledger is None else ledger
    try:
        problems, notes, observed, scanned = collect(root, tracked=tracked, ledger=ledger)
    except CouldNotInspect as exc:
        if not quiet:
            print(f"❌ {GUARD_NAME}: {exc} Exiting 2.", file=sys.stderr)
        return 2

    if quiet:
        return 1 if problems else 0

    for note in notes:
        print(f"   · {note}")

    # The debt block prints BEFORE the verdict, so it survives a failing run — LEDGERS.md §3.
    if active_ledger:
        print(f"\n{GUARD_NAME}: {len(active_ledger)} declared ledger entry(ies) — accepted debt, "
              f"NOT proof:")
        for rel, reason in sorted(active_ledger.items()):
            seen = "observed STILL GLOBBING on this run" if rel in observed else "not observed"
            print(f"  ⚠ DECLARED  {rel}  ({seen})")
            print(f"      {reason}")

    if problems:
        print(f"\n❌ {GUARD_NAME}: {len(problems)} problem(s)\n", file=sys.stderr)
        for p in problems:
            print(f"  ❌ {p}", file=sys.stderr)
        return 1

    if active_ledger:
        print(f"\n✅ {GUARD_NAME}: no NEW per-stack apps/ glob across {scanned} tracked file(s), one "
              f"definition of {READER}, both halves of the install/teardown pair on it, and its "
              f"answer matches every kustomization — EXCEPT the {len(active_ledger)} entry(ies) "
              f"above, which remain DEFECTIVE by declaration.")
    else:
        print(f"\n✅ {GUARD_NAME}: no per-stack apps/ glob across {scanned} tracked file(s), one "
              f"definition of {READER}, both halves of the install/teardown pair on it, and its "
              f"answer matches every kustomization. The ledger is empty, so that claim carries no "
              f"exceptions.")
    return 0


# ── self-test ─────────────────────────────────────────────────────────────────

def _fixture_root(case: str, tmp: pathlib.Path) -> pathlib.Path:
    """Materialize one canary case: shared skeleton, then the REAL library, then the case on top.

    The real lib-components.sh is copied in rather than stubbed, so no fixture can quietly hold a
    stale second implementation of the very function this guard exists to keep singular. The one
    case that needs a broken reader (c5) ships its own and lands last, overwriting it.
    """
    root = tmp / case
    shutil.copytree(CANARY_DIR / "_skeleton", root)
    lib_dst = root / LIB_REL
    lib_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(REPO_ROOT / LIB_REL, lib_dst)
    case_dir = CANARY_DIR / case
    for src in sorted(case_dir.rglob("*")):
        if src.is_dir():
            continue
        dst = root / src.relative_to(case_dir)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    return root


# case -> (expected finding code, ledger to run it under). None ledger means DECLARED_GLOBS-empty.
CANARY_CASES: dict[str, tuple[str | None, dict[str, str]]] = {
    "c1-per-stack-glob": ("PER-STACK-GLOB", {}),
    "c1-control-all-stacks-sweep": (None, {}),
    "c2-second-implementation": ("SECOND-IMPLEMENTATION", {}),
    "c3-caller-not-sourced": ("CALLER-NOT-SOURCED", {}),
    "c4-peer-divergence": ("PEER-DIVERGENCE", {}),
    "c5-library-disagrees": ("LIBRARY-DISAGREES", {}),
    "c6-stale-declaration": ("STALE-DECLARATION",
                             {"bootstrap/install.sh": "2026-08-23 | fixture | decision: fixture"}),
    "c7-vanished-declaration": ("VANISHED-DECLARATION",
                                {"bootstrap/gone.sh": "2026-08-23 | fixture | decision: fixture"}),
    "c8-unreadable-kustomization": ("UNREADABLE-KUSTOMIZATION", {}),
}


def self_test() -> int:
    """1 = real tree clean AND every case detected. 0 = a detector is blind. 2 = harness broken."""
    if not CANARY_DIR.is_dir():
        print(f"::error::{GUARD_NAME}: canary fixtures missing at {CANARY_DIR}. Detection is "
              f"unproven.", file=sys.stderr)
        return 2
    missing = [c for c in CANARY_CASES if not (CANARY_DIR / c).is_dir()]
    if missing or not (CANARY_DIR / "_skeleton").is_dir():
        print(f"::error::{GUARD_NAME}: canary case(s) missing: {missing or ['_skeleton']}",
              file=sys.stderr)
        return 2

    blind: list[str] = []
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = pathlib.Path(tmpdir)
        for case, (expected, ledger) in sorted(CANARY_CASES.items()):
            try:
                # THROUGH collect(), not around it — see collect()'s docstring. Every
                # `problems.extend(...)` in the real pipeline is witnessed by a case below only
                # because this line does not re-implement that pipeline.
                found, _notes, _obs, _n = collect(_fixture_root(case, tmp), tracked=False,
                                                  ledger=ledger)
            except (CouldNotInspect, OSError) as exc:
                print(f"::error::{GUARD_NAME}: fixture {case} could not be evaluated ({exc}).",
                      file=sys.stderr)
                return 2
            codes = {f.split()[0] for f in found}
            if expected is None:
                # The false-positive control. A legitimate all-stacks sweep must produce NOTHING —
                # this is the case that keeps the guard from reddening on correct work.
                if found:
                    print(f"  ❌ CONTROL {case}: expected no finding, got {sorted(codes)}",
                          file=sys.stderr)
                    for f in found:
                        print(f"       {f}", file=sys.stderr)
                    blind.append(case)
                else:
                    print(f"  ✅ control  {case}: correctly produced no finding")
                continue
            if expected in codes:
                print(f"  ✅ canary   {case}: {expected} detected")
            else:
                print(f"  ❌ CANARY {case}: {expected} NOT detected (got {sorted(codes) or 'nothing'})"
                      f" — this detector is blind.", file=sys.stderr)
                blind.append(case)

    # NOT quiet. The reporting half — the notes, the declared-debt block, the verdict sentence — is
    # code too, and `quiet=True` skips all of it. It was skipping a NameError in the debt block on
    # 2026-08-23: the self-test printed nine green ticks while the plain run crashed to rc 2. A
    # self-test that cannot see the guard's own output is asserting less than it appears to.
    print(f"\n  — the real tree, through the full reporting path —")
    real = run(REPO_ROOT, tracked=True)
    if real == 2:
        print(f"::error::{GUARD_NAME}: the real-tree run could not inspect (rc 2). The self-test "
              f"cannot claim a clean tree it never read.", file=sys.stderr)
        return 2
    if real != 0:
        print(f"  ❌ the real tree is NOT clean (rc {real}) — run the guard plainly to see why.",
              file=sys.stderr)
        blind.append("real-tree")

    if blind:
        print(f"\n❌ {GUARD_NAME} self-test: {len(blind)} failure(s): {blind}. Exiting 0 — a guard "
              f"whose detection is unproven must not be read as working.", file=sys.stderr)
        return 0
    print(f"\n✅ {GUARD_NAME} self-test: {len(CANARY_CASES)} case(s) — every canary detected, the "
          f"all-stacks-sweep control stayed silent, and the real tree is clean.")
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--self-test", action="store_true",
                        help="run the canary fixtures; exits EXACTLY 1 on success")
    parser.add_argument("root", nargs="?", default=str(REPO_ROOT))
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    return run(pathlib.Path(args.root).resolve())


if __name__ == "__main__":
    sys.exit(main())
