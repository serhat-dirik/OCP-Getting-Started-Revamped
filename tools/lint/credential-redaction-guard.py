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
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

DEFAULT_ROOTS = ("content", "tools", "bootstrap", "gitops", "platform-portfolio", "helm", ".github", "apps")

SCANNED_SUFFIXES = {".adoc", ".sh", ".bash", ".yaml", ".yml", ".py", ".java", ".md"}

# Directories that are not ours to police: vendored charts, build output, dependency trees.
SKIP_DIR_PARTS = {
    ".git", "node_modules", "target", "build", "__pycache__", "vendor",
    ".venv", "venv", "dist", "charts",
}

# ---------------------------------------------------------------------------------------------
# Rule 1 — fixed-width truncation in a credential-bearing context.
# ---------------------------------------------------------------------------------------------

# Every way this repo has actually written "keep the first N characters".
TRUNCATION_RE = re.compile(
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
CREDENTIAL_CONTEXT_RE = re.compile(
    r"(?i)\b(?:authorization|bearer|api[_-]?key|apikey|genai_api_key|access[_-]?token"
    r"|id[_-]?token|maas-credentials|received=|passwd|htpasswd|password|credential)\b"
    r"|\bsk-[A-Za-z0-9]|\beyJ[A-Za-z0-9]"
)

# A pod log is a stream whose contents this repo does not control: whatever the application decided
# to print, including anything an upstream service echoed back at it. That is precisely how the
# motivating near-miss arose — the block said only `oc logs … | cut -c1-200`, with no credential
# vocabulary anywhere in it, because the credential was in the DATA, not in the command. Without
# this signal the guard would miss the very defect it was written for.
UNAUDITABLE_STREAM_RE = re.compile(r"\b(?:oc|kubectl)\s+logs\b")

# An explicit redaction anywhere in the block clears rule 1 — that is the whole point of the rule:
# we are not banning truncation, we are banning truncation used AS the safety.
REDACTION_RE = re.compile(
    r"(?i)redact|<hidden>|\*\*\*\*|/dev/null|\bwc\s+-c\b|-o\s+name\b|(?:^|[^A-Za-z])xxxx"
)

# Truncating the output of a random-byte source is how you MINT a password, not how you hide one:
# `openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-16` is a generator, and the character
# count is the point rather than a fig leaf. Measured false positive on bootstrap/install.sh and
# tools/ws/ws before this exemption existed.
GENERATION_RE = re.compile(r"\bopenssl\s+rand\b|/dev/urandom|\buuidgen\b|\bpwgen\b")

# ---------------------------------------------------------------------------------------------
# Rule 2 — a literal credential in a command line (not a $VARIABLE reference).
# ---------------------------------------------------------------------------------------------

LITERAL_KEY_RE = re.compile(r"\bsk-[A-Za-z0-9_-]{16,}")
LITERAL_JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}")

# Synthetic stand-ins are how you TEST a redaction, so they must not be findings themselves. Every
# fixture in this repo is deliberately built from these markers.
SYNTHETIC_MARKERS = re.compile(
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


def collect_files(roots, skip_self=True):
    files = []
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            for f in sorted(p.rglob("*")):
                if not f.is_file():
                    continue
                if SKIP_DIR_PARTS & set(f.parts):
                    continue
                if skip_self and f.name in SELF_EXCLUDED:
                    continue
                if f.suffix in SCANNED_SUFFIXES or (f.suffix == "" and _has_shebang(f)):
                    files.append(f)
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

    roots = args.paths or [r for r in DEFAULT_ROOTS if pathlib.Path(r).exists()]

    files = collect_files(roots, skip_self=True)
    if not files:
        print(f"credential-redaction-guard: no scannable files under {[str(r) for r in roots]!r} — "
              "refusing to report clean over an empty scope.", file=sys.stderr)
        return 2

    offenders = 0
    for f in files:
        for line_no, rule, message in find_offenders(f):
            offenders += 1
            print(f"{f}:{line_no}: [{rule}] {message}")

    if offenders:
        print(f"\ncredential-redaction-guard: {offenders} finding(s) across {len(files)} file(s) "
              "scanned.", file=sys.stderr)
        return 1

    print(f"credential-redaction-guard: clean ({len(files)} file(s) scanned).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
