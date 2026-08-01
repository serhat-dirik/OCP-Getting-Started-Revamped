#!/usr/bin/env python3
"""credential-redaction-guard.py — safety must be a redaction, never a character count.

WHY THIS EXISTS (near-miss, 2026-07-29). agentic-ai/troubleshooting.adoc documented a diagnostic
that showed a model-gateway error line to the attendee through `cut -c1-200`. Measured on the real
log line, the echoed credential (`Received=eyJ…`) started at character **201** — the truncation
cleared it by TEN characters. Nobody chose that margin; it was arithmetic. One reword upstream and
an attendee's terminal prints a bearer token.

The same sweep then found the identical shape had already gone live one module over, in
app-modernization/lab.adoc: a gateway 401 body printed through `b[:400]`, with the credential
sitting at character **75**. Not a near-miss — a leak. That is why this guard is mechanical rather
than a review habit: the class is invisible at review time precisely because the truncated output
*looks* redacted right up until the message changes.

THE RULE THIS ENFORCES. Where output that can carry credential material is displayed or logged, the
safety must come from an explicit redaction OF THE THING — by field name (`s/Received=[^,]*/…/`), by
credential shape (`s/(sk-|eyJ)[A-Za-z0-9._~+/=-]{8,}/\\1<redacted>/`), or by not printing it — never
from a fixed-width truncation that happens to fall short of it.

WHAT IT FLAGS
  1. Fixed-width truncation (`cut -c`, `cut -b`, `head -c`, `${VAR:0:N}`, `awk substr`, python
     `[:N]`) appearing in a block that also mentions credential material. A redaction in the same
     block clears the finding: the truncation is then a readability trim, not the control.
  2. Literal credential-shaped material (`sk-…`, a JWT) sitting in a command line — a hardcoded
     token, as opposed to a `$VARIABLE` reference.

WHAT IT DELIBERATELY DOES NOT FLAG — and why (the pushback is part of the design).
  `curl -H "Authorization: Bearer $TOKEN"` puts the token in argv, where `ps` can see it. This repo
  does that ~25 times and every one is defensible: the reader is the only process owner in their own
  cockpit pod, and in securing-apps-keycloak the Authorization header IS the lesson. Flagging the
  shape would redden main on legitimate teaching material and train people to silence the guard,
  which costs more than it saves. A *literal* token in argv is a different thing entirely and is
  rule 2. If argv hygiene is ever wanted, it needs a `--config` convention first, not a linter.

USAGE
    tools/lint/credential-redaction-guard.py [path ...]   # default: the repo's code+content roots
    tools/lint/credential-redaction-guard.py --self-test  # per-rule canary assertions; MUST exit 1

Like curl-format-guard.py, this refuses to report clean over an empty scope, and ships a canary so
CI (and a human) can prove the detector fires before trusting a clean result on the real tree.

THE SELF-TEST IS PER-RULE, AND PER-EXEMPTION (2026-08-01). It used to be "scan the canary, exit 1 if
anything was found", which is no evidence about anything: an audit measured that blinding rule 1
still exited 1 because rule 2 fired, and vice versa, and that breaking REDACTION_RE,
SYNTHETIC_MARKERS or GENERATION_RE changed nothing either — the canary's three "NOT an offender"
sections were decorative, since nothing asserted they stayed SILENT. This is one of only two things
between a pasted API key and main, so "something fired" is not good enough.

Now every canary section declares what it must produce and which ONE regex it exists to exercise
(see the header of credential-redaction-guard.canary.adoc), and the self-test asserts each section
independently, then MUTATES that regex and requires the section's outcome to flip. A rule that dies
takes its own section down with it; an exemption that dies shows up as a false positive in its own
section. The self-test also fails if any rule or any mutable pattern has no section naming it, so a
new rule cannot ship without a canary for it.

AND THE SCOPE IS MEASURED, NOT JUST NON-EMPTY (2026-08-01). The per-rule self-test above proves the
detectors work; it says nothing about whether anything was FED to them. This guard's only scope check
was `if not files: return 2` — the weak form, which catches `collect_files() → []` and misses
`collect_files() → files[:1]`. Measured: with that one-character truncation the guard printed
"clean (1 file(s) scanned)" and exited 0 while 901 of 902 files went uninspected, and --self-test
still exited 1, so BOTH CI signals stayed green. Scope now goes through the shared _scope.py ledger
with a floor per dimension, each recorded by the code path it proves — "files collected" by the walk,
"files scanned" by the loop that hands each file to the detectors. Counting only in the walk was not
enough: `files[:1]` truncates at the RETURN, after every increment, so the ledger read 899 while one
file was inspected. A counter upstream of the defect measures the intent, not the work.

AND A CRASH IS NOT A DETECTION (2026-08-01). CI's contract here is "--self-test must exit EXACTLY 1".
Python exits 1 on an uncaught exception, so a broken guard scored as a proven one: measured, a
missing _scope.py and a one-character regex typo each produced a traceback, rc=1, and a CI step that
printed "self-test ok". Both crash classes now exit 2, as does any unhandled exception from main().
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except ImportError as exc:  # pragma: no cover — see the exit-code note below
    # An uncaught ImportError exits 1, and CI's contract for this guard is "--self-test must exit
    # EXACTLY 1 = the canary was detected". A crash would therefore be READ AS PROOF OF DETECTION and
    # the real run would never even happen. Measured 2026-08-01 by running a copy of this file with
    # _scope.py absent: traceback, rc=1, and the CI step would have printed "self-test ok".
    print(f"::error::credential-redaction-guard: cannot import _scope ({exc}) — the guard could not "
          f"start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)

DEFAULT_ROOTS = ("content", "tools", "bootstrap", "gitops", "platform-portfolio", "helm", ".github", "apps")

SCANNED_SUFFIXES = {".adoc", ".sh", ".bash", ".yaml", ".yml", ".py", ".java", ".md"}

# Directories that are not ours to police: vendored charts, build output, dependency trees.
SKIP_DIR_PARTS = {
    ".git", "node_modules", "target", "build", "__pycache__", "vendor",
    ".venv", "venv", "dist", "charts",
}


def _compile(name, pattern):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    WHY (measured 2026-08-01). Every pattern below is compiled at MODULE level, so a typo raises
    re.error before main() — and before any try/except inside it — can run. Python exits 1 on an
    uncaught exception, and 1 is exactly what CI's `--self-test must exit EXACTLY 1` assertion
    accepts as "the canary was detected". A one-character regex typo therefore reported the guard's
    detection as PROVEN while the guard could not even load. A regex is the likeliest thing to break
    in this file, so the compile step is where the exit code has to be fixed.
    """
    try:
        return re.compile(pattern)
    except re.error as exc:
        print(f"::error::credential-redaction-guard: {name} is not a valid regex ({exc}) — the guard "
              f"could not load. Exiting 2: that is 'the guard is broken', not 'the canary fired'.",
              file=sys.stderr)
        sys.exit(2)


# ---------------------------------------------------------------------------------------------
# Rule 1 — fixed-width truncation in a credential-bearing context.
# ---------------------------------------------------------------------------------------------

# Every way this repo has actually written "keep the first N characters".
TRUNCATION_RE = _compile(
    "TRUNCATION_RE",
    r"""(?x)
      \bcut\s+(?:-[a-zA-Z]+\s+)*-[cb]\s*\d       # cut -c1-200 / cut -b1-64
    | \bhead\s+(?:-[a-zA-Z]+\s+)*-c\s*\d         # head -c 200
    | \$\{[A-Za-z_][A-Za-z0-9_]*:\d+:\d+\}       # ${VAR:0:16}
    | \bsubstr\s*\(                              # awk substr(...)
    | \[\s*:\s*\d+\s*\]                          # python b[:400]
    """
)

# Tight on purpose. Words like "secret" are omitted: `oc get secret` appears all over this repo in
# entirely benign shapes, and a guard that cries wolf gets disabled. These are the tokens that
# actually co-occur with credential VALUES rather than credential object names.
CREDENTIAL_CONTEXT_RE = _compile(
    "CREDENTIAL_CONTEXT_RE",
    r"(?i)\b(?:authorization|bearer|api[_-]?key|apikey|genai_api_key|access[_-]?token"
    r"|id[_-]?token|maas-credentials|received=|passwd|htpasswd|password|credential)\b"
    r"|\bsk-[A-Za-z0-9]|\beyJ[A-Za-z0-9]"
)

# A pod log is a stream whose contents this repo does not control: whatever the application decided
# to print, including anything an upstream service echoed back at it. That is precisely how the
# motivating near-miss arose — the block said only `oc logs … | cut -c1-200`, with no credential
# vocabulary anywhere in it, because the credential was in the DATA, not in the command. Without
# this signal the guard would miss the very defect it was written for.
UNAUDITABLE_STREAM_RE = _compile("UNAUDITABLE_STREAM_RE", r"\b(?:oc|kubectl)\s+logs\b")

# An explicit redaction anywhere in the block clears rule 1 — that is the whole point of the rule:
# we are not banning truncation, we are banning truncation used AS the safety.
REDACTION_RE = _compile(
    "REDACTION_RE",
    r"(?i)redact|<hidden>|\*\*\*\*|/dev/null|\bwc\s+-c\b|-o\s+name\b|(?:^|[^A-Za-z])xxxx"
)

# Truncating the output of a random-byte source is how you MINT a password, not how you hide one:
# `openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-16` is a generator, and the character
# count is the point rather than a fig leaf. Measured false positive on bootstrap/install.sh and
# tools/ws/ws before this exemption existed.
GENERATION_RE = _compile("GENERATION_RE",
                         r"\bopenssl\s+rand\b|/dev/urandom|\buuidgen\b|\bpwgen\b")

# ---------------------------------------------------------------------------------------------
# Rule 2 — a literal credential in a command line (not a $VARIABLE reference).
# ---------------------------------------------------------------------------------------------

LITERAL_KEY_RE = _compile("LITERAL_KEY_RE", r"\bsk-[A-Za-z0-9_-]{16,}")
LITERAL_JWT_RE = _compile("LITERAL_JWT_RE",
                          r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}")

# Synthetic stand-ins are how you TEST a redaction, so they must not be findings themselves. Every
# fixture in this repo is deliberately built from these markers.
SYNTHETIC_MARKERS = _compile(
    "SYNTHETIC_MARKERS",
    r"(?i)synthetic|placeholder|redacted|example|fixture|canary|fake|dummy|"
    r"abcdef0123456789|xxxx|<the-?key>|your-?key|test"
)

# The rules this guard can emit, and every regex a canary section is allowed to mutate. Both are
# coverage requirements: --self-test fails if any entry here has no canary section naming it, which
# is what stops a new rule (or a new exemption) from shipping with no evidence behind it.
RULE_TRUNCATION = "truncation-as-redaction"
RULE_LITERAL = "literal-credential"
RULES = (RULE_TRUNCATION, RULE_LITERAL)

MUTABLE_PATTERNS = (
    "TRUNCATION_RE", "CREDENTIAL_CONTEXT_RE", "UNAUDITABLE_STREAM_RE",
    "REDACTION_RE", "GENERATION_RE", "LITERAL_KEY_RE", "LITERAL_JWT_RE",
    "SYNTHETIC_MARKERS",
)


def _adoc_blocks(lines):
    """Yield (start_index, end_index_exclusive) for each ---- delimited source block."""
    open_at = None
    for i, line in enumerate(lines):
        if line.rstrip() == "----":
            if open_at is None:
                open_at = i
            else:
                yield (open_at, i + 1)
                open_at = None
    if open_at is not None:                      # unterminated block: treat the tail as one block
        yield (open_at, len(lines))


def _logical_commands(lines):
    """Group lines into single shell pipelines: backslash continuations and leading-`|` chains.

    A naive +/- N line window is too crude — it married a benign `curl … | head -c 200` to an
    unrelated `oc logs` five lines away in a media manifest, which is how guards earn their
    reputation for crying wolf. One pipeline is the honest unit of "this truncation is applied to
    that stream".
    """
    i, n = 0, len(lines)
    while i < n:
        start = i
        while i < n:
            stripped = lines[i].strip()
            continues = stripped.endswith("\\")
            follows = (i + 1 < n) and lines[i + 1].strip().startswith("|")
            i += 1
            if not (continues or follows):
                break
        yield (start, i)


def _blocks_for(path: pathlib.Path, lines):
    """The context window a finding is judged in.

    For AsciiDoc that is the enclosing ---- source block, which is exactly the unit a reader sees as
    "one command". For everything else it is one shell pipeline.
    """
    if path.suffix == ".adoc":
        blocks = list(_adoc_blocks(lines))
        if blocks:
            return blocks
    return list(_logical_commands(lines))


def find_offenders(path: pathlib.Path):
    """Yield (line_no, rule, message) for each finding in one file, deduplicated."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return

    seen = set()

    # Rule 1: truncation whose surrounding block talks about credential material and does NOT redact.
    for start, end in _blocks_for(path, lines):
        window = "\n".join(lines[start:end])
        if not (CREDENTIAL_CONTEXT_RE.search(window) or UNAUDITABLE_STREAM_RE.search(window)):
            continue
        if REDACTION_RE.search(window) or GENERATION_RE.search(window):
            continue
        for offset, line in enumerate(lines[start:end]):
            if line.lstrip().startswith(("#", "//", "*")):
                continue                          # prose and comments describe the rule, not break it
            match = TRUNCATION_RE.search(line)
            if match:
                finding = (start + offset + 1, RULE_TRUNCATION,
                           f"fixed-width truncation ({match.group(0).strip()}) guards output that "
                           f"can carry credential material — redact the thing instead")
                if finding[:2] not in seen:
                    seen.add(finding[:2])
                    yield finding

    # Rule 2: a literal credential sitting in the file. The synthetic check reads a small window,
    # not just the line: a fixture's `private static final String FAKE_JWT =` sits on the line
    # ABOVE the literal it names, and flagging our own redaction tests would be absurd.
    for i, line in enumerate(lines):
        neighbourhood = "\n".join(lines[max(0, i - 3):i + 4])
        if SYNTHETIC_MARKERS.search(neighbourhood):
            continue
        for regex, what in ((LITERAL_KEY_RE, "API key"), (LITERAL_JWT_RE, "JWT")):
            if regex.search(line):
                finding = (i + 1, RULE_LITERAL,
                           f"a literal {what} appears here — use a $VARIABLE from a gitignored vars "
                           f"file, or a clearly synthetic stand-in")
                if finding[:2] not in seen:
                    seen.add(finding[:2])
                    yield finding


# This guard and its canary exist to CONTAIN the patterns it hunts — its docstring quotes `cut -c`
# and `b[:400]`, and the canary is nothing but offenders. Scanning them during a real run reports
# the detector to itself. lint.yml's privacy guard excludes its own file for exactly this reason.
SELF_EXCLUDED = {"credential-redaction-guard.py", "credential-redaction-guard.canary.adoc"}


def require_tree_floors(scope, include_scan: bool = True) -> None:
    """The floors a WHOLE-TREE run must clear. Declared once and used by both the real run and
    --self-test, so the two can never disagree about what "enough" means.

    THREE DIMENSIONS, BECAUSE THEY FAIL AT DIFFERENT PLACES. "collected" is recorded by the directory
    walk and "scanned" by the loop that actually calls the detectors, and the gap between them is
    load-bearing: a first attempt counted only in the walk, and `collect_files() → files[:1]` still
    passed, because the truncation happens at the RETURN — after every increment had been recorded.
    A counter upstream of the defect measures the intent, not the work.

    `include_scan=False` is for --self-test's Proof 0, which exercises the walk but does not scan.
    """
    scope.require("roots walked", len(DEFAULT_ROOTS),
                  f"DEFAULT_ROOTS names {len(DEFAULT_ROOTS)} trees and every one of them exists in "
                  f"this repo. Fewer means discovery broke, or the run happened somewhere other than "
                  f"the repo root — not that a tree was deleted.")
    scope.require("files collected", 400,
                  "the eight default roots hold ~900 scannable files, and the largest single root "
                  "holds ~264. A floor of 400 therefore survives ordinary growth and deletion, but "
                  "cannot be met by any single root — so a walk truncated to one tree, or to one "
                  "file, fails instead of reporting a confident 'clean'.")
    if include_scan:
        scope.require("files scanned", 400,
                      "recorded by the loop that hands each file to the detectors, NOT by the walk. "
                      "Collecting 900 files and scanning 1 is a clean-looking run over nothing; only "
                      "a counter downstream of the truncation can tell the two apart.")


def _ignored_untracked() -> set:
    """Absolute paths of files git BOTH ignores AND does not track.

    WHY (measured 2026-08-01). A plain run on a maintainer's machine reported a finding in
    `bootstrap/vars.yaml` — a real `sk-` key, sitting in the file the project's own rule 8 says is
    where credentials belong ("secrets only via gitignored vars files"). So the guard's one finding
    on a healthy tree was the sanctioned location doing exactly what it is for. That is the shape
    this guard's own docstring warns about: a guard that cries wolf gets disabled, and the next
    person to see red here learns to ignore it.

    A file that is ignored AND untracked cannot reach main, so it is not what this guard defends.
    That is also the line lint.yml's sibling privacy guard already draws — it uses `git grep`, which
    reads tracked files only.

    BOTH conditions are required, and the untracked half is the load-bearing one: a TRACKED file can
    still match an ignore rule, and skipping on ignore-status alone would let a key be hidden from
    this guard by appending a line to .gitignore. `--others` lists untracked files only, so a tracked
    file is never in this set no matter what .gitignore says.

    Degrades to "skip nothing" when git is absent or this is not a repo — in CI every file is
    tracked, so the set is empty there and behaviour is unchanged.
    """
    def _git(*args):
        return subprocess.run(["git", *args], capture_output=True, text=True, timeout=30,
                              check=False)

    try:
        top = _git("rev-parse", "--show-toplevel")
        if top.returncode != 0:
            return set()
        root = pathlib.Path(top.stdout.strip())
        out = _git("ls-files", "--others", "--ignored", "--exclude-standard", "-z")
        if out.returncode != 0:
            return set()
    except (OSError, subprocess.SubprocessError):
        return set()
    return {(root / p).resolve() for p in out.stdout.split("\0") if p}


def collect_files(roots, skip_self=True, scope=None):
    """Resolve `roots` (files and/or directories) to the concrete files to scan.

    A directory walk and an explicitly-named file are DELIBERATELY not filtered the same way:

    * SELF_EXCLUDED always applies, file or directory. Naming the guard's own source or its canary
      by hand is still the detector reporting itself to itself — the reason SELF_EXCLUDED exists in
      the first place — regardless of whether the path arrived via a walk or on the command line.

    * SCANNED_SUFFIXES / the shebang sniff do NOT apply to an explicitly-named file. That allowlist
      exists to bound an otherwise-unbounded directory walk (`.git`, `node_modules`, a stray binary);
      it is not a claim that unusual suffixes are safe to skip. A file named directly on the command
      line was asked for BY NAME — "scan tools/lint/credential-redaction-guard.py" — and silently
      no-op'ing because its extension isn't in the allowlist (or it has none, and no shebang) would
      make `guard.py <dir>` and `guard.py <dir>/<file>` disagree about what is scannable, which is
      the defect this rewrite fixes. This guard is security-relevant; when in doubt, scan more.

    * The gitignored-and-untracked skip is likewise WALK-ONLY, for the same reason: naming such a
      file by hand is asking for it to be scanned, and answering "no findings" without looking would
      be a lie. Only the automatic walk treats unreachable-by-git as out of scope.

    `scope` (a _scope.Scope) records what this walk actually did. The counts are incremented HERE,
    inside the loop that does the work, rather than from `len(...)` at the call site — a length taken
    beside the walk is satisfied by a walk that never ran, which is precisely the `→ []` / `[:1]`
    blinding the ledger exists to catch.
    """
    files = []
    # Resolved on first use, so a single-file (pre-commit) invocation never pays for a `git ls-files`
    # it would not consult anyway — the skip is walk-only.
    ignored = None
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            if skip_self and p.name in SELF_EXCLUDED:
                continue
            files.append(p)
            if scope is not None:
                scope.add("files collected")
        elif p.is_dir():
            if ignored is None:
                ignored = _ignored_untracked()
            if scope is not None:
                scope.add("roots walked")
            for f in sorted(p.rglob("*")):
                if not f.is_file():
                    continue
                if SKIP_DIR_PARTS & set(f.parts):
                    continue
                if skip_self and f.name in SELF_EXCLUDED:
                    continue
                if ignored and f.resolve() in ignored:
                    continue
                if f.suffix in SCANNED_SUFFIXES or (f.suffix == "" and _has_shebang(f)):
                    files.append(f)
                    if scope is not None:
                        scope.add("files collected")
    return files


def _has_shebang(path: pathlib.Path) -> bool:
    try:
        with path.open("rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


# ---------------------------------------------------------------------------------------------
# Self-test — per rule, per exemption. "Something fired" is not evidence about anything.
# ---------------------------------------------------------------------------------------------

CANARY_PATH = pathlib.Path(__file__).resolve().parent / "credential-redaction-guard.canary.adoc"

# A mutation is how a section proves it is testing what it claims: blind the pattern it names (make
# it match nothing) or flood it (make it match everything), and the section's outcome must FLIP.
NEVER_MATCH = re.compile(r"(?!)")
ALWAYS_MATCH = re.compile(r"")

# // EXPECT: <rule[,rule]|none> | <blind|flood|-> <PATTERN_NAME> — prose
EXPECT_RE = re.compile(
    r"^//\s*EXPECT:\s*(?P<rules>[^|]+?)\s*\|\s*(?P<mode>blind|flood|-)\s*(?P<pattern>[A-Z_]*)"
)


def _canary_sections(lines):
    """Parse the canary into `== ` sections, each carrying its own EXPECT contract."""
    heads = [i for i, line in enumerate(lines) if line.startswith("== ")]
    sections = []
    for n, start in enumerate(heads):
        end = heads[n + 1] if n + 1 < len(heads) else len(lines)
        sec = {"title": lines[start][3:].strip(), "start": start, "end": end,
               "rules": None, "mode": None, "pattern": None}
        for line in lines[start:end]:
            m = EXPECT_RE.match(line.strip())
            if m:
                raw = m.group("rules").strip()
                sec["rules"] = set() if raw == "none" else {r.strip() for r in raw.split(",")}
                sec["mode"] = m.group("mode")
                sec["pattern"] = m.group("pattern") or None
                break
        sections.append(sec)
    return heads[0] if heads else len(lines), sections


def _findings_between(path, start, end):
    """Findings whose line number falls inside [start, end) — 0-based indices, 1-based line nos."""
    return [f for f in find_offenders(path) if start < f[0] <= end]


def _mutate(name, mode):
    """Swap a module-level pattern for a never/always-matching one; returns the original."""
    original = globals()[name]
    globals()[name] = NEVER_MATCH if mode == "blind" else ALWAYS_MATCH
    return original


def self_test():
    """Assert every canary section INDIVIDUALLY, then prove each one's named pattern is load-bearing.

    Exit 1 = every rule fired where it must, every exemption stayed silent where it must, and
    mutating each named pattern flipped its section. Exit 2 = a rule or an exemption is blind, or
    the fixture no longer states what it is testing.
    """
    if not CANARY_PATH.is_file():
        print(f"❌ SELF-TEST FAILED: canary fixture {CANARY_PATH} is missing — there is nothing to "
              "prove the detectors with.", file=sys.stderr)
        return 2

    lines = CANARY_PATH.read_text(encoding="utf-8").splitlines()
    first_head, sections = _canary_sections(lines)
    problems = []
    if not sections:
        print("❌ SELF-TEST FAILED: the canary has no `== ` sections — the harness cannot attribute "
              "a finding to a rule.", file=sys.stderr)
        return 2

    # The preamble is prose ABOUT the rules; a finding there means the fixture drifted.
    stray = _findings_between(CANARY_PATH, 0, first_head)
    if stray:
        problems.append(f"the canary preamble produced {len(stray)} finding(s) — it is documentation, "
                        f"not a fixture: {stray[0][0]}:{stray[0][1]}")

    covered_rules, covered_patterns = set(), set()
    for sec in sections:
        title = sec["title"]
        if sec["rules"] is None:
            problems.append(f"section {title!r} carries no `// EXPECT:` line — an unasserted section "
                            f"is decorative, which is the defect this self-test exists to remove")
            continue
        if sec["pattern"] and sec["pattern"] not in MUTABLE_PATTERNS:
            problems.append(f"section {title!r} names {sec['pattern']}, which is not one of this "
                            f"guard's mutable patterns {MUTABLE_PATTERNS}")
            continue

        base = _findings_between(CANARY_PATH, sec["start"], sec["end"])
        base_rules = {rule for _, rule, _ in base}
        silent = not sec["rules"]

        if silent:
            if base:
                problems.append(f"[false positive] section {title!r} must stay SILENT but produced "
                                f"{len(base)} finding(s) — first at line {base[0][0]}: {base[0][2]}")
        else:
            missing = sec["rules"] - base_rules
            if missing:
                problems.append(f"[blind rule] section {title!r} produced no {sorted(missing)} "
                                f"finding — that rule is broken, and the other rules firing elsewhere "
                                f"would have masked it")
            covered_rules |= sec["rules"]

        if sec["mode"] and sec["mode"] != "-" and sec["pattern"]:
            original = _mutate(sec["pattern"], sec["mode"])
            try:
                mutated = _findings_between(CANARY_PATH, sec["start"], sec["end"])
            finally:
                globals()[sec["pattern"]] = original
            mutated_rules = {rule for _, rule, _ in mutated}
            if silent:
                if not mutated:
                    problems.append(f"[exemption not load-bearing] section {title!r} stayed silent "
                                    f"even with {sec['pattern']} {sec['mode']}ed — its silence is an "
                                    f"accident, so it proves nothing about {sec['pattern']}")
            elif sec["rules"] & mutated_rules:
                problems.append(f"[detector not load-bearing] section {title!r} still reported "
                                f"{sorted(sec['rules'] & mutated_rules)} with {sec['pattern']} "
                                f"{sec['mode']}ed — the section is not testing {sec['pattern']}")
            covered_patterns.add(sec["pattern"])

        state = "silent" if silent else "+".join(sorted(sec["rules"]))
        proof = f"{sec['mode']} {sec['pattern']}" if sec["pattern"] else "baseline only"
        print(f"   [{state:>24}] {title}  ({proof})")

    # Coverage: a rule or a pattern with no section naming it has no evidence behind it at all.
    for missing in sorted(set(RULES) - covered_rules):
        problems.append(f"[uncovered] rule {missing!r} is never asserted by any canary section")
    for missing in sorted(set(MUTABLE_PATTERNS) - covered_patterns):
        problems.append(f"[uncovered] pattern {missing} is never mutated by any canary section — "
                        f"nothing would notice if it stopped working")

    # The canary proves the DETECTORS. These two proofs cover the other half — whether anything is
    # ever handed to them. Measured 2026-08-01: `collect_files() → files[:1]` left --self-test at 1
    # AND the real run at 0, so every signal stayed green while one file of 902 was inspected.
    problems += Scope.self_check()          # the ledger mechanism itself, exercised by this CI job

    # Proof 0 — the real tree still clears this guard's own floors, AND collect_files still records
    # what it walked. A count recorded nowhere fails the floor exactly like a walk that never ran,
    # which is what makes a truncated or unwired walk visible from --self-test.
    tree = Scope("credential-redaction-guard/real-tree")
    require_tree_floors(tree, include_scan=False)
    returned = collect_files([r for r in DEFAULT_ROOTS if pathlib.Path(r).exists()],
                             skip_self=True, scope=tree)
    for shortfall in tree.shortfalls():
        problems.append(f"[scope] the real tree no longer clears this guard's own floor — {shortfall} "
                        f"(run from the repo root; cwd is {pathlib.Path.cwd()})")

    # RECORDED vs RETURNED. The floors above are raised inside the walk, so they cannot see a
    # truncation applied at the `return` — `return files[:1]` increments 899 times and hands back
    # one. Comparing the two numbers catches exactly that, and it is the one scope defect the real
    # run's floors would otherwise be alone in noticing.
    collected = tree.get("files collected")
    if len(returned) != collected:
        problems.append(f"[scope] collect_files RECORDED {collected} file(s) but RETURNED "
                        f"{len(returned)} — something truncates the list after the walk. Every file "
                        f"counted must actually be handed back, or the guard reports confidence it "
                        f"has not earned.")

    if problems:
        for p in problems:
            print(f"❌ SELF-TEST FAILED: {p}", file=sys.stderr)
        return 2

    print(f"✅ self-test ok — {len(sections)} canary section(s): every rule in {list(RULES)} fires in "
          f"its own section, every exemption stays silent in its own section, and mutating each of "
          f"the {len(MUTABLE_PATTERNS)} named patterns flips its section.")
    # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help=f"file(s)/dir(s) to scan (default: {' '.join(DEFAULT_ROOTS)})")
    ap.add_argument("--self-test", action="store_true",
                    help="assert the canary section by section: each rule fires in its own section, "
                         "each exemption stays silent in its own, and each named pattern is proven "
                         "load-bearing by mutating it. MUST exit 1")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    explicit = bool(args.paths)
    roots = args.paths or [r for r in DEFAULT_ROOTS if pathlib.Path(r).exists()]

    # Floors apply to the WHOLE-TREE run only. `guard.py one-file.adoc` — the pre-commit shape — is a
    # legitimately tiny scope, and a floor there would fail every single-file invocation. An explicit
    # scope is the caller's assertion about what to look at; the default scope is the guard's own,
    # and only the guard's own claim is something the guard can be held to.
    scope = Scope("credential-redaction-guard")
    if not explicit:
        require_tree_floors(scope)

    files = collect_files(roots, skip_self=True, scope=scope)
    if not files:
        print(f"credential-redaction-guard: no scannable files under {[str(r) for r in roots]!r} — "
              "refusing to report clean over an empty scope.", file=sys.stderr)
        return 2

    offenders = 0
    for f in files:
        scope.add("files scanned")          # recorded HERE: downstream of collect_files' return
        for line_no, rule, message in find_offenders(f):
            offenders += 1
            print(f"{f}:{line_no}: [{rule}] {message}")

    # Judged BEFORE the findings are reported: over a collapsed scope neither answer is trustworthy.
    # "No findings" is meaningless, and "findings" understates. rc=2 says the guard could not inspect
    # what it claims to — a different thing from rc=1, "the tree has a defect".
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if offenders:
        print(f"\ncredential-redaction-guard: {offenders} finding(s) across {len(files)} file(s) "
              "scanned.", file=sys.stderr)
        return 1

    summary = scope.summary() if not explicit else f"{len(files)} files scanned"
    print(f"credential-redaction-guard: clean ({summary}).")
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
        print(f"::error::credential-redaction-guard: crashed ({type(exc).__name__}: {exc}). Exiting 2 "
              f"— a crash is 'the guard could not run', never 'clean' and never 'canary detected'.",
              file=sys.stderr)
        sys.exit(2)
