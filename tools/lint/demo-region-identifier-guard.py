#!/usr/bin/env python3
"""demo-region-identifier-guard.py — an `ifdef::demo[]` region that USES an identifier whose only
DEFINITION lives inside `ifndef::demo[]`. Both regions read fine; the demo rendering ships neither.

WHY THIS EXISTS. Three instances of one class in a single night, none of them found by review, none
of them visible to any build:

  1. 2026-08-12, securing-apps-keycloak (SEV1, found by an SA demo dry-run). The arc told the
     presenter to take `NS`/`CLAIMS`/`WEB`/`FRAUD`/`REALM` "from the top of the lab". Those
     assignments sat inside `ifndef::demo[]`. Measured in the built artefact: the demo page carried
     0 occurrences of `CLAIMS=https` against 3 uses of `$CLAIMS`, while the workshop page carried 1.
  2. The same page, the same commit, a different identifier KIND: the `get_token()` and `decode()`
     shell FUNCTIONS. 0 definitions in demo against 3 uses of `get_token`. Worth naming separately
     because a guard that only understood `VAR=` would have called that page fixed.
  3. 2026-08-12, ai-assisted-development. The arc told the presenter to "paste in the `ask-agent`
     helper (exercise 1)", and exercise 1 is inside `ifndef::demo[]`. `cat > ask-agent` appeared 0
     times in www/demo against 3 invocations, 1 time in www/workshop and www/instructor. All three
     beats call it, so the ENTIRE arc was dead: the presenter's first click printed
     `ask-agent: command not found` (reproduced in a live user7 cockpit terminal, rc 127).

WHAT MAKES IT DANGEROUS, and why it is worth a gate of its own. Instance 1 did not merely fail — it
failed into a WRONG CURE. `curl` handed an empty URL reports `000`, which is also what a dead
service reports, and the arc's decision tree read `000` as "not the entry state, re-run ws prep".
The printed advice to an SA minutes before a customer demo was to WIPE a healthy namespace
(`user6-dev` was passing 9/9 checks at the time). An unset variable does not announce itself.

WHY NOTHING ELSE SEES IT. Asciidoctor drops the excluded branch during PREPROCESSING; the remaining
document is valid, so `antora --log-failure-level=warn` returns rc 0 with a ZERO-LINE log on all
three renderings (measured on the unfixed tree, this build, three playbooks). It is invisible in
source because BOTH regions read correctly — the defect exists only in the projection. And it is
trivially visible in the artefact, which is where two of the three were actually caught.

WHICH LEVEL THIS WORKS AT, AND WHAT EACH LEVEL CANNOT SEE. Both, because neither alone is honest:

  SOURCE (default, detectors [1] [2] [5]). Projects each page twice — once with `demo` set, once
  with `workshop` set — resolving `include::partial$…[]` and `include::example$…[]` the way Antora
  does, then harvests shell identifiers from each projection and compares. This is a checkout-plus-
  a-script check, so it can be a CI job. It CANNOT see what Antora actually emitted: an extension
  that rewrites content, a partial resolved from a different component version, or a conditional on
  an attribute this guard does not model (anything other than `demo`/`workshop`/`instructor` is
  treated as TAKEN in every projection, which can only hide a finding, never invent one).

  ARTEFACT (opt-in `--built-demo DIR`, detectors [3] [4]). Reads the rendered `<code class=
  "language-sh…">` bodies of a built site and applies the same harvest. This is the level that
  actually caught two of the three instances, and it is the only level that proves what a presenter
  will see. It CANNOT run in CI as things stand — every job in .github/workflows/lint.yml is
  checkout-plus-a-script and a gate that needs a site build is a gate that gets skipped (the same
  reasoning demo-beat-chip-guard records for its own built mode) — and it CANNOT name the source
  line to edit, because by then the conditional is gone.

WHAT IT ASSERTS.

  [1] FLAVOR-INVISIBLE DEFINITION. An identifier USED in the demo projection that has at least one
      definition in the non-demo projection and NONE in the demo projection. This is the class. It
      is reported on the USE, because the use is what runs and fails.
  [2] USE BEFORE DEFINITION, within one projection. The identifier is defined in that flavor, but
      the first use comes first. This is the ordering half, and it is why the ai-assisted-development
      fix moves the demo arc's BEATS below the shared definition instead of only unguarding it:
      unguarding alone would have put three uses above the one definition on the demo page.
  [3] BUILT USE WITHOUT DEFINITION. The same comparison on the rendered HTML, which is why it
      needs BOTH `--built-demo` and `--built-non-demo`: a built page has no conditional left in it,
      so "defined in the other flavor" has to come from the other flavor's copy of THAT page,
      matched on `<module-slug>/<page-stem>`. Without the pair it is inactive by design — the
      first version compared a demo page against nothing and reported 46 sites on a site with one
      defect, which is the signal-to-noise that gets a gate switched off.
  [4] BUILT USE BEFORE DEFINITION. Per page, so it runs on either side of the pair.
  [5] MALFORMED EXEMPTION. A `// lint-allow: demo-region-identifier NAME — reason` comment with no
      name or no reason. An exemption nobody has to justify is a silent hole.

THREE IDENTIFIER KINDS, because the three instances used three of them:
  var   `NAME=`, `export NAME=`, `local`/`readonly`/`declare`, `for NAME in`, `read NAME`
        used as `$NAME` / `${NAME}`
  func  `name() {` / `function name` — used as a bare command
  file  `cat > name <<EOF`, `cat >name`, `tee name` — used as a bare command

DELIBERATELY NARROW, and each narrowing is a false-positive the guard refuses to produce. A gate
that cries wolf gets switched off, taking the one detector that matters with it.

  * ONLY SHELL SOURCE BLOCKS COUNT, for definitions and for uses. Prose is not scanned at all — no
    identifier is ever inferred from a sentence. A demo NOTE that says "set `NS` first" in backticks
    is NOT a definition, and that is the correct verdict: a presenter cannot click prose. (It is
    also why the pre-fix ai-assisted-development page reports `NS` as well as `ask-agent`.)
  * A BARE COMMAND IS A USE ONLY IF THE PAGE CREATES SOMETHING BY THAT NAME. `oc`, `jq`, `curl` and
    every other real command are invisible to this guard by construction, so it needs no allowlist
    of commands and cannot be broken by a new one.
  * `${VAR:-default}`, `${VAR:=…}`, `${VAR:+…}` and their unset-colon forms are NOT uses. Those
    spellings exist precisely to tolerate an unset variable; flagging them would flag the correct
    fix. `NS="${NS:-$(oc project -q)}"` — a real line in ai-assisted-development's helper — is the
    witness.
  * A QUOTED heredoc body (`<<'EOF'`) is not scanned for uses, because the shell does not expand it.
    An UNQUOTED body (`<<EOF`) IS scanned for uses and NOT for definitions: `name: foo` inside a
    YAML heredoc is data, and `$NS` inside one really does expand.
  * Environment names the cockpit or the shell provides are exempt by table, each with the reason
    on its own line. The list was read off the LIVE terminal container of showroom-user7 on
    2026-08-12, not recalled.
  * Cross-PAGE definitions do not count. Module independence is a project rule: a helper defined on
    another page is not defined here.
  * `====`, `****`, `____` and `--` are CONTAINERS, not verbatim blocks, so a `[source,sh]` inside a
    `[tabs]` block is read normally. Getting this wrong is not a small miss: `[tabs]` is the house
    standard for the dual-path Console::/CLI:: steps, and treating `====` as verbatim hid 194 of
    this tree's 1162 shell blocks and produced three false positives in one run.

WHAT IT DOES NOT COVER, stated so nobody reads the green tick as more than it is.
  * It does not model `ifeval::[]`, and there are none in content/ today. If one appears its body is
    kept in every projection — conservative, and counted in the summary so the silence is not
    mistaken for a measurement.
  * It says nothing about whether a definition is CORRECT. `NS={user}-dev` renders `your-user-dev`
    on the demos cockpit — a real defect, a different class, and the neighbouring
    attribute-interpolation-guard's territory, not this one's.
  * It does not check the instructor projection against demo. Instructor renders the non-demo body,
    so instructor is covered by the workshop comparison; a demo-vs-instructor split would be a new
    shape, not a missing case.
  * Detector [2] is per-flavor and per-page. It cannot know that the reader is expected to have run
    a block from a DIFFERENT page — which is exactly what module independence forbids anyway.

Exit codes:
  0  contract holds
  1  contract broken — or, under --self-test, every canary was correctly detected
  2  the guard could not inspect what it claims to inspect (no files, collapsed scope, bad fixture,
     unreadable built directory)

USAGE
    tools/lint/demo-region-identifier-guard.py
    tools/lint/demo-region-identifier-guard.py --self-test            # must exit exactly 1
    tools/lint/demo-region-identifier-guard.py --root /tmp/old-tree   # a git-archive reconstruction
    tools/lint/demo-region-identifier-guard.py --built-demo www/demo --built-non-demo www/workshop
"""

from __future__ import annotations

import argparse
import html as html_mod
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import crashes
    with Python's default rc 1 — which is exactly what CI's "--self-test must exit EXACTLY 1"
    assertion reads as "the canary fired". `os._exit` is what makes the remap stick: an excepthook
    cannot change the exit status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::demo-region-identifier-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from _scope import Scope, fixture_line_expectations  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad
    # NOT `except ImportError`. A _scope.py that fails to PARSE raises SyntaxError, sails past an
    # ImportError-only handler and exits 1 — CI's "the canary fired".
    print(f"::error::demo-region-identifier-guard: cannot import _scope ({exc}) — the guard could "
          f"not start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    Every pattern here compiles at MODULE level, before main() can run. Python exits 1 on an
    uncaught exception, and 1 is what CI accepts as "the canary was detected", so a one-character
    regex typo would report this guard's detection as PROVEN while it could not even load.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::demo-region-identifier-guard: {name} is not a valid regex ({exc}) — the "
              f"guard could not load. Exiting 2: that is 'the guard is broken', not 'the canary "
              f"fired'.", file=sys.stderr)
        sys.exit(2)


REPO = Path(__file__).resolve().parents[2]
PAGES = REPO / "content/modules/ROOT/pages"


def _is_canary(path: str) -> bool:
    """A fixture belonging to some guard's canary — never this guard's finding.

    Matches BOTH shapes. `foo-guard.canary.adoc` is a single-file canary; `foo-guard.canary/` is a
    directory canary holding a whole fake tree. The original test five guards shared was
    `".canary." not in path`, which silently covered only the first (4699bc4).
    """
    return ".canary." in path or ".canary/" in path


# ── The line grammar ───────────────────────────────────────────────────────────────────────────
# Every pattern below is read by the real run. Blinding any of them changes what the canary fixture
# reports, which is the point: a grammar rule that can stop matching with no CI signal is the same
# hole as a detector that can stop firing.

# A conditional region opener, BLOCK form only (empty brackets). `ifdef::demo[some text]` is the
# INLINE form and opens no region — INLINE_COND handles it.
COND_OPEN = _compile("COND_OPEN", r"^if(n?)def::([^\[\]]+)\[\]\s*$")
COND_CLOSE = _compile("COND_CLOSE", r"^endif::([^\[\]]*)\[\]\s*$")
INLINE_COND = _compile("INLINE_COND", r"^if(n?)def::([^\[\]]+)\[(.+)\]\s*$")
# ifeval is not modelled — counted so its absence is a measurement, not an assumption.
IFEVAL = _compile("IFEVAL", r"^ifeval::")
# An Antora resource include. Only partial$ and example$ occur in this tree (220 + 107).
INCLUDE = _compile("INCLUDE", r"^include::(partial|example)\$([^\[\]]+)\[[^\]]*\]\s*$")

# A source-block attribute line and the delimiter that opens the block.
SOURCE_ATTR = _compile("SOURCE_ATTR", r"^\[source(?:%[A-Za-z]+)?\s*,\s*([A-Za-z0-9_-]+)")
# ONLY the two VERBATIM delimiters. `====` (example/admonition), `****` (sidebar), `____` (quote)
# and `--` (open block) are CONTAINERS: their contents are still AsciiDoc and still hold source
# blocks. Treating them as verbatim swallowed every shell block inside a `[tabs]` block — and
# `[tabs]` is this project's house standard for the dual-path Console::/CLI:: steps, so the guard
# was blind to a large fraction of the tree. Measured 2026-08-12: 968 shell blocks before this fix,
# and app-security-testing's demo `$NS` (a real instance of the class) went unreported because its
# use sits inside a tabs block.
LISTING_DELIM = _compile("LISTING_DELIM", r"^(-{4,}|\.{4,})\s*$")
# The languages whose bodies are SHELL the reader runs. `texinfo` is this project's captured-output
# convention and must never be harvested: it is what the terminal PRINTED, not what it was given.
SHELL_LANGS = frozenset({"sh", "bash", "shell", "zsh", "console", "terminal"})

# ── Identifier grammar ─────────────────────────────────────────────────────────────────────────
# Definitions are matched GENEROUSLY on purpose. A missed definition becomes a false POSITIVE, and
# this guard would rather miss a defect than flag a correct page.
VAR_DEF = _compile(
    "VAR_DEF",
    r"(?:^|[\s;&|(])(?:export\s+|local\s+|readonly\s+|declare\s+(?:-[A-Za-z]+\s+)?)?"
    r"([A-Za-z_][A-Za-z0-9_]*)=")
FOR_DEF = _compile("FOR_DEF", r"(?:^|[\s;&|(])for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b")
READ_DEF = _compile("READ_DEF", r"(?:^|[\s;&|(])read\s+(?:-[A-Za-z]+\s+)*([A-Za-z_][A-Za-z0-9_]*)")
FUNC_DEF = _compile("FUNC_DEF",
                    r"(?:^\s*|[;&|]\s*)(?:function\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)\s*\{")
# A file the page CREATES. The name becomes a command later — `ask-agent "…"` — which is exactly
# how instance 3 failed.
# The target must be a BARE name (optionally `./name`), never a path: `echo x 2>/dev/null` must not
# be read as creating a file called `dev`, and a page that redirects into a directory is not
# creating a command.
FILE_DEF = _compile("FILE_DEF",
                    r"(?:^\s*|[;&|]\s*)(?:cat|tee|printf|echo)\b[^|;&]*?>{1,2}\s*"
                    r"(?:\./)?([A-Za-z_][A-Za-z0-9_.-]*)")
# A variable USE. The `(?![:\-+=?])` is the whole false-positive story for detector [1]: it drops
# `${VAR:-default}` and friends, which exist to tolerate an unset variable.
VAR_USE_BRACED = _compile("VAR_USE_BRACED", r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])")
VAR_USE_BARE = _compile("VAR_USE_BARE", r"\$([A-Za-z_][A-Za-z0-9_]*)")
BRACED_DEFAULTED = _compile("BRACED_DEFAULTED",
                            r"\$\{([A-Za-z_][A-Za-z0-9_]*)\s*[:\-+=?]")
# A heredoc opener: `<<EOF`, `<<-EOF`, `<<'EOF'`, `<<"EOF"`. The quote decides whether the body
# expands, which decides whether the body is scanned.
HEREDOC = _compile("HEREDOC", r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
# An exemption comment. Both the NAME and the reason are required — see detector [5].
EXEMPTION = _compile("EXEMPTION", r"^//\s*lint-allow:\s*demo-region-identifier\s*(.*)$")
EXEMPTION_BODY = _compile("EXEMPTION_BODY",
                          r"^([A-Za-z_][A-Za-z0-9_.-]*)\s*[—:-]\s*(\S.*)$")
# The rendered shell blocks of a built page, in document order.
# `[^>]*` before `class=`, not a literal space: Asciidoctor emits attributes in an order this
# guard does not control, and a built page may carry a newline inside the tag.
BUILT_SH = _compile(
    "BUILT_SH",
    r'<code[^>]*class="language-(?:sh|bash|shell|console)[^"]*"[^>]*>(.*?)</code>', re.S)
BUILT_TAG = _compile("BUILT_TAG", r"<[^>]+>")

# Names the RUNTIME provides, so a page that uses one without defining it is correct. Read off the
# live `terminal` container of pod showroom-user7 in ogsr-showroom on 2026-08-12 (`env | cut -d= -f1`),
# plus the POSIX/bash specials, plus the two Kubernetes service families the kubelet injects.
# Each group carries WHY it is here, per the house rule that an exemption without a reason is a hole.
ENV_PROVIDED = frozenset({
    # bash/POSIX specials — set by the shell itself before any page runs.
    "HOME", "PATH", "PWD", "OLDPWD", "SHELL", "SHLVL", "TERM", "USER", "LOGNAME", "HOSTNAME",
    "LANG", "LC_ALL", "IFS", "PS1", "PS2", "RANDOM", "SECONDS", "LINENO", "UID", "EUID",
    "BASH_SOURCE", "FUNCNAME", "REPLY", "TMPDIR", "EDITOR", "MAIL", "HISTSIZE", "HISTCONTROL",
    "GPG_TTY", "LESSOPEN", "NSS_SDB_USE_CACHE",
    # Injected into every pod by the kubelet; the cockpit terminal is a pod.
    "NAMESPACE", "KUBERNETES_SERVICE_HOST", "KUBERNETES_SERVICE_PORT", "KUBECONFIG",
})
# Prefixes of the kubelet's per-Service env families (KUBERNETES_PORT_443_TCP_ADDR,
# SHOWROOM_USER3_SERVICE_HOST, ETHERPAD_PORT_9001_TCP…). Enumerating them is impossible — the set
# depends on which Services exist — so the shape is exempted instead.
ENV_PROVIDED_PREFIXES = ("KUBERNETES_", "SHOWROOM_", "ETHERPAD_")

# The flavor projections. Keys are the attribute sets the three playbooks set (content/site-*.yml).
FLAVORS = {"demo": frozenset({"demo"}), "nondemo": frozenset({"workshop"})}
# Attributes whose value this guard KNOWS per flavor. Anything else is UNKNOWN and its body is kept
# in every projection: keeping content can only add a definition, which can only hide a finding.
# Inventing a finding is the failure mode that gets a gate switched off.
MODELLED = frozenset({"demo", "workshop", "instructor"})

MIN_PAGES = 100          # 141 tracked .adoc pages today
MIN_DEMO_REGIONS = 30    # 56 ifdef::demo[] openers today
MIN_SHELL_BLOCKS = 800   # 1162 measured on this tree; a smaller number is a broken block parser,
                         # and 968 was the number BEFORE `[tabs]` blocks became visible — a floor
                         # set from a broken measurement would have blessed that blindness
MIN_IDENTIFIERS = 600    # 858 distinct (kind, name) definitions harvested


def is_exempt(name: str) -> bool:
    """True when the RUNTIME provides this identifier, so the page owes no definition for it."""
    return name in ENV_PROVIDED or name.startswith(ENV_PROVIDED_PREFIXES)


# ── Flavor projection ──────────────────────────────────────────────────────────────────────────

def _condition_holds(negated: str, attrs: str, flavor_attrs) -> bool | None:
    """Evaluate one `ifdef::`/`ifndef::` condition. None means UNKNOWN (keep the body).

    `attrs` may carry `,` (OR) or `+` (AND); this tree uses neither, so both are handled by
    treating a multi-attribute condition as unknown rather than guessing at the precedence.
    """
    if "," in attrs or "+" in attrs:
        return None
    name = attrs.strip()
    if name not in MODELLED:
        return None
    present = name in flavor_attrs
    return (not present) if negated else present


def project(lines, flavor_attrs, resolve_include=None, depth=0):
    """Render one flavor of a page: [(source_lineno_or_None, text)] with conditionals resolved.

    Included partials carry lineno None — a finding inside a partial names the partial's own text,
    not a line number in the page that included it, and a wrong line number is worse than none.
    """
    out = []
    stack = []          # each entry: True = keep, False = drop, None = unknown (kept)
    unknown = 0
    ifevals = 0
    for i, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        m = COND_OPEN.match(line)
        if m:
            verdict = _condition_holds(m.group(1), m.group(2), flavor_attrs)
            if verdict is None:
                unknown += 1
            stack.append(verdict)
            continue
        if COND_CLOSE.match(line):
            if stack:
                stack.pop()
            continue
        if IFEVAL.match(line):
            ifevals += 1
            continue
        live = all(v is not False for v in stack)
        if not live:
            continue
        m = INLINE_COND.match(line)
        if m:
            verdict = _condition_holds(m.group(1), m.group(2), flavor_attrs)
            if verdict is None:
                unknown += 1
            if verdict is not False:
                out.append((i, m.group(3)))
            continue
        m = INCLUDE.match(line)
        if m and resolve_include is not None and depth < 5:
            body = resolve_include(m.group(1), m.group(2))
            if body is not None:
                sub, sub_unknown, sub_ifevals = project(
                    body.splitlines(), flavor_attrs, resolve_include, depth + 1)
                out.extend([(None, t) for _ln, t in sub])
                unknown += sub_unknown
                ifevals += sub_ifevals
                continue
        out.append((i, line))
    return out, unknown, ifevals


def repo_include_resolver(root: Path):
    """Resolve `partial$x.adoc` / `example$x` against a tree's modules/ROOT/<family>/ directory.

    The directory list and every resolved body are computed ONCE. The obvious version re-globbed
    the tree per include line, per projection, per page: 327 include lines x 2 projections meant
    hundreds of full recursive walks of a checkout that contains node_modules, www/ and .git, and
    the guard took 41s wall of which 34s was system time. At that cost `_canary-coverage` — which
    runs both modes twice per detector — could not finish inside ten minutes, so the gate that
    proves this gate could not run at all. Search is also narrowed to `content/` when it exists,
    for the same reason.
    """
    search_root = root / "content" if (root / "content").is_dir() else root
    bases = {}
    for family in ("partial", "example"):
        bases[family] = sorted(search_root.rglob(f"modules/*/{family}s"))
    cache = {}

    def resolve(family, target):
        hit = cache.get((family, target), False)
        if hit is not False:
            return hit
        body = None
        for base in bases.get(family, ()):
            candidate = base / target
            if candidate.is_file():
                try:
                    body = candidate.read_text(errors="replace")
                except OSError:
                    body = None
                break
        cache[(family, target)] = body
        return body
    return resolve


# ── Identifier harvest ─────────────────────────────────────────────────────────────────────────

def _uses_in(text):
    """Variable uses on one line, minus the `${VAR:-default}` family."""
    defaulted = set(BRACED_DEFAULTED.findall(text))
    names = set(VAR_USE_BRACED.findall(text)) | set(VAR_USE_BARE.findall(text))
    return names - defaulted


def harvest(seq, known_created=None):
    """(defs, uses, created, exemptions, malformed) over a projected page.

    defs: {(kind, name): [position, …]}   uses: [(kind, name, position, lineno, text)]
    Position is the index in the projected sequence, which is document order — the only order that
    matters for "did the definition come first".

    `known_created` is {name: kind} for functions and files created ANYWHERE on the page, in either
    flavor. It has to be passed in, and that is the whole point of instance 3: in the demo
    projection the `cat > ask-agent` line does not exist, so this pass alone cannot know that
    `ask-agent` is a page-created command rather than some binary on PATH. Without it the guard is
    blind to exactly the kind of identifier that caused the outage. Callers run harvest twice — once
    to learn the names, once to resolve the uses.
    """
    known_created = known_created or {}
    defs = {}
    uses = []
    created = set()          # names the page creates: functions and heredoc files
    in_block = False
    block_is_shell = False
    delim = None
    pending_lang = None
    heredoc = None           # (terminator, expands)
    exemptions = set()
    malformed = []

    for pos, (lineno, text) in enumerate(seq):
        if heredoc is not None:
            terminator, expands = heredoc
            if text.strip() == terminator:
                heredoc = None
                continue
            if expands:
                for name in _uses_in(text):
                    uses.append(("var", name, pos, lineno, text))
            continue

        m = EXEMPTION.match(text)
        if m:
            body = EXEMPTION_BODY.match(m.group(1).strip())
            if body:
                exemptions.add(body.group(1))
            else:
                malformed.append((lineno, text))
            continue

        if not in_block:
            sm = SOURCE_ATTR.match(text)
            if sm:
                pending_lang = sm.group(1).lower()
                continue
            dm = LISTING_DELIM.match(text)
            if dm:
                in_block = True
                delim = dm.group(1)
                block_is_shell = pending_lang in SHELL_LANGS
                pending_lang = None
                continue
            if text.strip() and not text.startswith("//"):
                pending_lang = None          # any other content ends the attribute run
            continue

        if text.rstrip() == delim:
            in_block = False
            block_is_shell = False
            delim = None
            continue
        if not block_is_shell:
            continue

        # ── inside a shell block ──
        hm = HEREDOC.search(text)
        fm = FILE_DEF.search(text)
        if fm:
            name = fm.group(1)
            defs.setdefault(("file", name), []).append(pos)
            created.add(name)
        for name in FUNC_DEF.findall(text):
            defs.setdefault(("func", name), []).append(pos)
            created.add(name)
        for pattern, kind in ((VAR_DEF, "var"), (FOR_DEF, "var"), (READ_DEF, "var")):
            for name in pattern.findall(text):
                defs.setdefault(("var", name), []).append(pos)
        for name in _uses_in(text):
            uses.append(("var", name, pos, lineno, text))
        # A bare command is a use ONLY if the page creates something by that name — recorded now,
        # resolved after the whole page is read, because a definition may come later in the file.
        uses.append(("command-line", text, pos, lineno, text))

        if hm:
            heredoc = (hm.group(2), hm.group(1) == "")

    candidates = dict(known_created)
    for name in created:
        candidates.setdefault(name, "func" if ("func", name) in defs else "file")
    resolved = []
    for kind, name, pos, lineno, text in uses:
        if kind != "command-line":
            resolved.append((kind, name, pos, lineno, text))
            continue
        for cand, ckind in sorted(candidates.items()):
            if _bare_command(text, cand):
                resolved.append((ckind, cand, pos, lineno, text))
    return defs, resolved, candidates, exemptions, malformed


def _bare_command(text: str, name: str) -> bool:
    """`name` appears in COMMAND position on this line — not as an argument, not in a path.

    Restricted to names the page itself creates, so this never has to know what a real command is.
    """
    pattern = re.compile(r"(?:^\s*|[;&|]\s*|\$\(\s*|&&\s*|\|\|\s*)(?:\./)?" + re.escape(name)
                         + r"(?=\s|$)")
    if re.search(r">{1,2}\s*(?:\./)?" + re.escape(name) + r"(?=\s|$)", text):
        return False        # the creation line itself
    return bool(pattern.search(text))


# ── Detectors ──────────────────────────────────────────────────────────────────────────────────

KINDS = {
    "flavor-invisible-definition":
        "move the DEFINITION out of `ifndef::demo[]` into a shared region OUTSIDE every guard, and "
        "put the demo arc's heading above it — one definition, rendered by all three flavors. See "
        "the SHARED SETUP A/B banners in "
        "content/modules/ROOT/pages/ai-assisted-development/lab.adoc for the shape that works. Do "
        "NOT fix it by telling the presenter to read the other rendering, and do NOT copy the "
        "block into the demo region: a second copy is the same bug with a delay.",
    "use-before-definition":
        "the definition renders in this flavor but AFTER the use. Move the block that defines it "
        "above the first use — for a split demo arc that means the beats belong BELOW the shared "
        "setup region, not above it.",
    "built-use-without-definition":
        "the RENDERED demo page uses an identifier it never defines. Fix the source (see "
        "flavor-invisible-definition) and rebuild; this detector reads the artefact, so it cannot "
        "name the line.",
    "built-use-before-definition":
        "the RENDERED demo page defines the identifier only after its first use. Reorder the "
        "source regions, then rebuild.",
    "malformed-exemption":
        "write the exemption as `// lint-allow: demo-region-identifier NAME — why the runtime "
        "provides it`. A name and a reason are both required; an exemption nobody has to justify "
        "is a hole with a comment on it.",
    "stale-ledger-entry":
        "the defect this LEDGER entry suppresses is gone. Delete the entry — a suppression that no "
        "longer applies is a licence nobody notices being used, and the next instance on that page "
        "would be swallowed by it.",
}

# ── The LEDGER ─────────────────────────────────────────────────────────────────────────────────
# Known instances this guard FINDS and does not fail on, because fixing them was out of the scope
# of the change that introduced the guard. Every entry is PRINTED on every run with its reason and
# is never counted as clean — the same contract tools/lint/_canary-coverage.py uses for a detector
# it cannot prove. Two properties make this a backlog rather than a blindfold:
#
#   * an entry is keyed on (page, detector, IDENTIFIER), never a line number: a line number rots
#     the moment anything above it moves, and a suppression keyed on a rotted id silently stops
#     applying to the thing it was written for;
#   * an entry that matches NOTHING is a finding of its own (stale-ledger-entry, rc 1). A ledger
#     that can outlive its defect is how a gate quietly stops guarding a page.
#
# DO NOT add an entry to make a red run green. The only legitimate reason is the one below: the
# page belongs to a change already in flight elsewhere.
LEDGER = [
    ("app-security-testing/lab.adoc", "flavor-invisible-definition", "var:NS",
     "FOURTH instance of this class, found by this guard on the run that introduced it "
     "(2026-08-12), and NOT a repeat of the three in the docstring. The demo arc's pre-flight runs "
     "`oc get pipelinerun -n $NS …` while the only `NS={user}-cicd` assignment sits inside "
     "`ifndef::demo[]` at line 27; the arc's own prose says 'Set NS={user}-cicd in your terminal', "
     "which is the securing-apps-keycloak shape exactly — a presenter who clicks rather than "
     "retypes gets `-n ''`. NOT FIXED HERE: app-security-testing belongs to another change in "
     "flight and this one must not touch it. FILED — delete this entry with the fix, and note the "
     "guard will fail on a stale entry if you forget."),
    ("agentic-ai/lab.adoc", "flavor-invisible-definition", "var:NS",
     "FIFTH instance, same class, same night. Verified by reading the file rather than trusting "
     "the finding: `NS={user}-ai` is at line 100, inside `ifndef::demo[]` (93-117); the demo arc "
     "is 136-327 and patches `cm parasol-agent-grounding -n $NS` at line 244; line 144 is the "
     "prose 'Set `NS={user}-ai` … in the terminal'. Prose is not clickable, so the arc's own "
     "`oc patch` runs with `-n ''`. NOT FIXED HERE — outside this change's write territory. "
     "FILED — delete this entry with the fix."),
]
# A THIRD entry — agentic-ai use-before-definition var:AGENT — was written here and then REMOVED,
# because it was this guard's own false positive rather than a defect: `====` was being treated as
# a verbatim delimiter, so every shell block inside a `[tabs]` block was invisible, and the demo
# arc's own `AGENT="$AGENT" bash /tmp/eval-run.sh` (line 216, before the use at 241) could not be
# seen. Two more went the same way, on resilience-multicluster-dr and on the agentic-ai definition
# above, before the grammar was corrected. A ledger is for defects that exist; an entry written
# around a guard bug hides the bug and the page at the same time, so every entry here was checked
# against the file it names before it was written.


def apply_ledger(findings):
    """(kept, suppressed, stale) — split findings against the LEDGER.

    Matching is by (page suffix, detector, identifier key). The page is matched on a SUFFIX so the
    same entry works against this repo and against a `git archive` reconstruction, whose paths are
    rooted somewhere else entirely.
    """
    def slug(path):
        """`<module-slug>/<page-stem>` — extension-free, so ONE entry covers both levels.

        A source finding names `…/pages/app-security-testing/lab.adoc` and the artefact finding for
        the same defect names `…/modules/app-security-testing/lab.html`. Matching on the literal
        path would leave the built mode unledgered, and a filed defect would redden it while the
        CI mode stayed green — a split verdict on one defect is worse than either answer.
        """
        parts = Path(path.replace("\\", "/")).parts
        return f"{parts[-2]}/{Path(parts[-1]).stem}" if len(parts) >= 2 else path

    kept, suppressed = [], []
    used = set()
    for finding in findings:
        rel, _lineno, kind, _detail, key = finding
        for idx, (page, lkind, lkey, reason) in enumerate(LEDGER):
            built_kind = kind.replace("built-use-without-definition",
                                      "flavor-invisible-definition").replace(
                                          "built-use-before-definition", "use-before-definition")
            if slug(rel) == slug(page) and built_kind == lkind and key == lkey:
                used.add(idx)
                suppressed.append((finding, reason))
                break
        else:
            kept.append(finding)
    stale = [(page, kind, key, reason) for idx, (page, kind, key, reason) in enumerate(LEDGER)
             if idx not in used]
    return kept, suppressed, stale


def scan_page(rel, lines, resolve_include=None):
    """(findings, counters) for one page, over both flavor projections."""
    findings = []
    counters = {"pages": 1}

    # TWO PASSES. The first learns which names the page CREATES (functions, heredoc files) across
    # BOTH flavors; the second resolves bare-command uses against that union. One pass cannot do it:
    # in the demo projection the `cat > ask-agent` line has already been conditioned away, so a
    # single-pass guard would read `ask-agent "…"` as an ordinary command and miss the class
    # entirely for the identifier kind that caused instance 3.
    sequences = {}
    for flavor, attrs in FLAVORS.items():
        seq, unknown, ifevals = project(lines, attrs, resolve_include)
        sequences[flavor] = seq
        counters["unknown conditionals"] = counters.get("unknown conditionals", 0) + unknown
        counters["ifeval"] = counters.get("ifeval", 0) + ifevals
    known = {}
    for seq in sequences.values():
        known.update(harvest(seq)[2])
    projections = {flavor: harvest(seq, known) for flavor, seq in sequences.items()}

    counters["demo regions"] = sum(
        1 for line in lines if COND_OPEN.match(line.rstrip("\n"))
        and COND_OPEN.match(line.rstrip("\n")).group(2).strip() == "demo"
        and not COND_OPEN.match(line.rstrip("\n")).group(1))
    demo_defs, demo_uses, _demo_created, demo_exempt, demo_malformed = projections["demo"]
    nd_defs, _nd_uses, _nd_created, nd_exempt, nd_malformed = projections["nondemo"]
    counters["shell blocks"] = 0
    counters["identifiers"] = len(demo_defs) + len(nd_defs)

    # From BOTH projections, deduped by line: an exemption written inside `ifndef::demo[]` is just
    # as unjustified as one in the arc, and reporting only the demo half would leave half the file
    # able to carry a reasonless suppression.
    for lineno, text in sorted(set(demo_malformed) | set(nd_malformed)):
        findings.append((rel, lineno, "malformed-exemption", text.strip(), ""))

    exempt = demo_exempt | nd_exempt

    # [1] used in demo, defined in non-demo, defined NOWHERE in demo.
    seen = set()
    for kind, name, _pos, lineno, text in demo_uses:
        if is_exempt(name) or name in exempt or (kind, name) in seen:
            continue
        if (kind, name) in demo_defs:
            continue
        if (kind, name) not in nd_defs:
            continue
        seen.add((kind, name))
        findings.append((rel, lineno, "flavor-invisible-definition",
                         f"the demo rendering uses {_show(kind, name)} and never defines it; its "
                         f"only definition is inside `ifndef::demo[]`  ({text.strip()[:90]})",
                         f"{kind}:{name}"))

    # [2] defined in this flavor, but the first use comes first.
    for flavor, (fdefs, fuses, _fcreated, _fex, _fm) in projections.items():
        first_use = {}
        for kind, name, pos, lineno, text in fuses:
            first_use.setdefault((kind, name), (pos, lineno, text))
        for key, positions in fdefs.items():
            if key not in first_use or is_exempt(key[1]) or key[1] in exempt:
                continue
            pos, lineno, text = first_use[key]
            if pos < min(positions):
                findings.append((rel, lineno, "use-before-definition",
                                 f"the {flavor} rendering uses {_show(*key)} at document position "
                                 f"{pos} and defines it at {min(positions)}  "
                                 f"({text.strip()[:90]})",
                                 f"{key[0]}:{key[1]}"))
    return findings, counters


def _show(kind, name):
    return {"var": f"${name}", "func": f"{name}()", "file": f"`{name}`"}.get(kind, name)


# ── Drivers ────────────────────────────────────────────────────────────────────────────────────

def pages_under(root: Path, include_canaries=False):
    """Every .adoc page in a tree, minus other guards' fixtures.

    Two discovery paths on purpose. Inside this repo, `git ls-files` is authoritative — an untracked
    scratch file is not content. A RECONSTRUCTION (`git archive … | tar -x`) is not a git repo at
    all, so it is walked. Without the second path this guard could not be pointed at a known-bad
    tree, and a gate nobody can test against known-bad input is a gate nobody has watched work.
    """
    if root == REPO:
        try:
            out = subprocess.run(["git", "-C", str(REPO), "ls-files", "--", "*.adoc"],
                                 capture_output=True, text=True, check=True).stdout.split()
            found = [REPO / f for f in out]
        except Exception:  # noqa: BLE001 — no git, no scope; the caller turns [] into rc 2
            found = []
    else:
        found = sorted(p for p in root.rglob("*.adoc") if p.is_file())
    if include_canaries:
        return found
    return [p for p in found if not _is_canary(str(p))]


def scan(paths, root=REPO, floors=(MIN_PAGES, MIN_DEMO_REGIONS, MIN_SHELL_BLOCKS, MIN_IDENTIFIERS),
         quiet=False):
    """(findings, scope-collapse rc, measurement summary)."""
    findings = []
    scope = Scope("demo-region-identifier-guard")
    scope.require("pages", floors[0],
                  "every .adoc page is read; a smaller number means file discovery broke, not that "
                  "pages were deleted")
    scope.require("demo regions", floors[1],
                  "the arcs live inside ifdef::demo[]; finding few of them means the conditional "
                  "tracker stopped matching, and every identifier would then look flavor-neutral")
    scope.require("shell blocks", floors[2],
                  "definitions and uses are read ONLY from shell source blocks; reading few of "
                  "them is an unread tree, not a clean one")
    scope.require("identifiers", floors[3],
                  "the harvested definitions are what the comparison is made of; a small number "
                  "means the identifier grammar stopped matching")
    resolver = repo_include_resolver(root)
    for path in paths:
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        try:
            rel = str(path.relative_to(root))
        except ValueError:
            rel = str(path)
        page_findings, counters = scan_page(rel, text.splitlines(), resolver)
        findings.extend(page_findings)
        counters["shell blocks"] = _count_shell_blocks(text.splitlines())
        scope.merge(counters)
    return findings, scope.enforce(quiet=quiet), scope.summary()


def _count_shell_blocks(lines):
    """Shell source blocks in the RAW page — the scope measurement, independent of any projection.

    Counted on the raw text rather than a projection because a projection that collapsed to nothing
    is exactly the failure this measurement has to be able to see.
    """
    n = 0
    pending = None
    in_block = False
    delim = None
    for raw in lines:
        line = raw.rstrip("\n")
        if in_block:
            if line.rstrip() == delim:
                in_block = False
            continue
        m = SOURCE_ATTR.match(line)
        if m:
            pending = m.group(1).lower()
            continue
        d = LISTING_DELIM.match(line)
        if d:
            in_block = True
            delim = d.group(1)
            if pending in SHELL_LANGS:
                n += 1
            pending = None
            continue
        if line.strip() and not line.startswith("//"):
            pending = None
    return n


def check_built(demo_dirs, non_demo_dirs):
    """Detectors [3] and [4], on a BUILT site. Returns (findings, pages_compared).

    This is the level that caught two of the three historical instances, and it is the only one
    that proves what a presenter will actually see. It cannot name a source line — by the time the
    HTML exists the conditional is gone — so its FIX line sends you back to the source.
    """
    findings = []
    compared = 0

    def page_scan(page, seed=None):
        """seed is {name: kind} from the OTHER flavor's copy of this page.

        Without it the artefact arm cannot see the file/function half of the class at all: the demo
        page never contains `cat > ask-agent`, so a scan of that page alone reads `ask-agent "…"`
        as an ordinary command. Same reason scan_page() runs two passes, one page apart.
        """
        bodies = [html_mod.unescape(BUILT_TAG.sub("", b)) for b in BUILT_SH.findall(
            page.read_text(errors="replace"))]
        if not bodies:
            return None
        seq = [(None, line) for body in bodies
               for line in ["[source,sh]", "----"] + body.splitlines() + ["----"]]
        known = dict(seed or {})
        known.update(harvest(seq)[2])
        defs, uses, _created, exempt, _mal = harvest(seq, known)
        first_use = {}
        for kind, name, pos, _ln, text in uses:
            first_use.setdefault((kind, name), (pos, text))
        return defs, first_use, exempt

    for root in list(demo_dirs) + list(non_demo_dirs):
        if not Path(root).is_dir():
            return [("", 0, "unreadable-built-dir", str(root), "")], compared

    # The NON-DEMO side first, keyed on <module-slug>/<page-stem>. Detector [3] is the artefact
    # analogue of [1] and needs exactly the same comparison: "used here, defined on the OTHER
    # flavor's copy of THIS page". Without that pairing the built check has nothing to compare
    # against and fires on every identifier a presenter legitimately sets by hand — measured on
    # this site: 46 findings, of which 1 was the defect. A gate at that signal-to-noise gets
    # switched off within a week, so [3] simply does not run unless --built-non-demo is supplied.
    nd_defs = {}
    nd_created = {}
    for root in non_demo_dirs:
        for page in sorted(Path(root).rglob("*.html")):
            scanned = page_scan(page)
            if scanned is None:
                continue
            compared += 1
            defs, first_use, exempt = scanned
            key = f"{page.parent.name}/{page.stem}"
            nd_defs.setdefault(key, set()).update(defs)
            nd_created.setdefault(key, {}).update(
                {name: kind for kind, name in defs if kind in ("func", "file")})
            for ident, (pos, text) in first_use.items():
                if ident in defs and pos < min(defs[ident]) and not is_exempt(ident[1]) \
                        and ident[1] not in exempt:
                    findings.append((str(page), 0, "built-use-before-definition",
                                     f"{_show(*ident)} is used at {pos} and defined at "
                                     f"{min(defs[ident])}  ({text.strip()[:80]})",
                                     f"{ident[0]}:{ident[1]}"))

    for root in demo_dirs:
        for page in sorted(Path(root).rglob("*.html")):
            key = f"{page.parent.name}/{page.stem}"
            scanned = page_scan(page, nd_created.get(key))
            if scanned is None:
                continue
            compared += 1
            defs, first_use, exempt = scanned
            twin = nd_defs.get(key, set())
            for ident, (pos, text) in sorted(first_use.items(), key=lambda kv: kv[1][0]):
                if is_exempt(ident[1]) or ident[1] in exempt:
                    continue
                if ident not in defs:
                    if ident in twin:
                        findings.append((str(page), 0, "built-use-without-definition",
                                         f"{_show(*ident)} is used and never defined — the "
                                         f"non-demo rendering of the same page defines it  "
                                         f"({text.strip()[:80]})", f"{ident[0]}:{ident[1]}"))
                elif pos < min(defs[ident]):
                    findings.append((str(page), 0, "built-use-before-definition",
                                     f"{_show(*ident)} is used at {pos} and defined at "
                                     f"{min(defs[ident])}  ({text.strip()[:80]})",
                                     f"{ident[0]}:{ident[1]}"))
    return findings, compared


def report(findings, summary, built_note="", suppressed=()) -> int:
    for finding, reason in suppressed:
        print(f"➖ LEDGERED (known, filed, NOT counted as clean): {finding[0]}:{finding[1]} "
              f"{finding[2]} {finding[4]}\n   {reason}")
    if suppressed:
        print()
    if not findings:
        print(f"✅ demo-region-identifier: {summary}. Every identifier an `ifdef::demo[]` region "
              f"uses is defined where the demo rendering can see it, before it is used."
              f"{built_note}")
        return 0
    for kind, fix in KINDS.items():
        hits = [f for f in findings if f[2] == kind]
        if not hits:
            continue
        print(f"❌ {kind}: {len(hits)} site(s)")
        for rel, lineno, _kind, detail, _key in hits[:20]:
            print(f"   {rel}:{lineno}  {detail}" if lineno else f"   {rel}  {detail}")
        if len(hits) > 20:
            print(f"   … and {len(hits) - 20} more")
        print(f"   FIX: {fix}")
    stray = [f for f in findings if f[2] not in KINDS]
    for rel, _ln, kind, detail, _key in stray:
        print(f"❌ {kind}: {rel} {detail}")
    if stray:
        return 2
    print(f"\n{len(findings)} flavor-scope defect(s). None of these fails a build: all three "
          f"Antora renderings return rc 0 with a zero-line log while the demo page ships uses of "
          f"an identifier it never defines (measured 2026-08-12 on the unfixed tree).")
    return 1


# ── Self-test ──────────────────────────────────────────────────────────────────────────────────

CANARY = Path(__file__).resolve().parent / "demo-region-identifier-guard.canary.adoc"

# A built demo page carrying the exact shape instance 3 shipped: three `ask-agent` invocations and
# no `cat > ask-agent`. Written the way Asciidoctor writes a highlighted block, because that markup
# is what BUILT_SH has to survive.
BUILT_BAD = """<html><body>
<div class="listingblock"><div class="content"><pre class="highlightjs highlight"><code
class="language-sh hljs" data-lang="sh">ask-agent "diagnose it"</code></pre></div></div>
<div class="listingblock"><div class="content"><pre class="highlightjs highlight"><code
class="language-sh hljs" data-lang="sh">echo $SET_BY_THE_PRESENTER_BY_HAND</code></pre></div></div>
</body></html>
"""
# The non-demo twin of the page above: it DEFINES `ask-agent`, which is what makes the demo page's
# use a finding rather than an unknown. It deliberately does NOT define
# $SET_BY_THE_PRESENTER_BY_HAND — the negative control for the over-fire that made the first
# version of this detector report 46 sites on a site with one defect.
BUILT_TWIN = """<html><body>
<div class="listingblock"><div class="content"><pre class="highlightjs highlight"><code
class="language-sh hljs" data-lang="sh"><span class="hljs-built_in">cat</span> &gt; ask-agent &lt;&lt;\'EOF\'
echo hi
EOF</code></pre></div></div>
</body></html>
"""
# A NON-demo built page whose own first use precedes its own definition — the witness for the
# non-demo arm of the built ordering detector, which no demo fixture can reach.
BUILT_NON_DEMO_UBD = """<html><body>
<div class="listingblock"><div class="content"><pre class="highlightjs highlight"><code
class="language-sh hljs" data-lang="sh">oc get pods -n $LATE_NS
LATE_NS=user1-dev</code></pre></div></div>
</body></html>
"""
# A DEMO built page with the same shape, for the demo arm.
BUILT_DEMO_UBD = """<html><body>
<div class="listingblock"><div class="content"><pre class="highlightjs highlight"><code
class="language-sh hljs" data-lang="sh">oc get pods -n $LATE_NS
LATE_NS=user1-dev</code></pre></div></div>
</body></html>
"""
BUILT_GOOD = """<html><body>
<div class="listingblock"><div class="content"><pre class="highlightjs highlight"><code
class="language-sh hljs" data-lang="sh">cat &gt; ask-agent &lt;&lt;'EOF'
echo hi
EOF
chmod +x ask-agent</code></pre></div></div>
<div class="listingblock"><div class="content"><pre class="highlightjs highlight"><code
class="language-sh hljs" data-lang="sh">ask-agent "diagnose it"</code></pre></div></div>
</body></html>
"""


def self_test(tmpdir: Path) -> int:
    """Prove every detector fires on a line only IT fires on, and stays silent on the correct forms.

    Expectations are declared PER LINE in the fixture, not as a total: a total is satisfied by the
    wrong detector firing the right number of times, which is how a canary comes to certify
    coverage it does not have.
    """
    ok = True

    if not CANARY.is_file():
        print(f"❌ SELF-TEST FAILED: the canary fixture {CANARY} is missing — there is nothing to "
              f"prove the detectors with.", file=sys.stderr)
        return 2

    lines = CANARY.read_text(encoding="utf-8").splitlines()
    findings, _counters = scan_page(CANARY.name, lines)

    for failure in fixture_line_expectations(CANARY, [f[1] for f in findings]):
        print(f"❌ SELF-TEST FAILED: {failure}", file=sys.stderr)
        ok = False

    # Per-line expectations prove WHICH lines fire, not which detector fired on them. Assert the
    # kinds too, so one detector cannot be quietly replaced by another that fires on the same line.
    kinds = {f[2] for f in findings}
    expected = {"flavor-invisible-definition", "use-before-definition", "malformed-exemption"}
    for missing in sorted(expected - kinds):
        print(f"❌ SELF-TEST FAILED: no {missing} finding on the canary — that detector is blind, "
              f"and the fixture case written for it proves nothing.", file=sys.stderr)
        ok = False
    for extra in sorted(kinds - expected):
        print(f"❌ SELF-TEST FAILED: unexpected {extra} finding on the canary — a detector is "
              f"firing on a shape the fixture declares correct.", file=sys.stderr)
        ok = False

    # THE OVER-FIRE ARM, standalone and as hard as the under-fire arm. Without it a guard that
    # flagged everything would satisfy every assertion above. Each line here is a shape measured to
    # be CORRECT: a shared (unguarded) definition, a `${VAR:-default}`, a quoted heredoc whose body
    # names variables nothing defines, a texinfo captured-output block, a real command, and an
    # identifier defined and then used in the same flavor.
    clean = [
        "= Page",
        "",
        "ifdef::demo[]",
        "== Demo arc",
        "endif::demo[]",
        "",
        "[source,sh]",
        "----",
        "export NS=\"$(oc whoami)-dev\"",
        "cat > helper <<'EOF'",
        "echo \"$NEVER_DEFINED_ANYWHERE and $ALSO_NOT\"",
        "EOF",
        "chmod +x helper",
        "----",
        "",
        "ifndef::demo[]",
        "[source,sh]",
        "----",
        "oc get pods -n $NS",
        "----",
        "endif::demo[]",
        "",
        "ifdef::demo[]",
        "[source,sh]",
        "----",
        "helper \"go\"",
        "echo \"${MAYBE_UNSET:-fallback}\" $NS",
        "----",
        "",
        "[source,texinfo]",
        "----",
        "$THIS_IS_CAPTURED_OUTPUT never runs",
        "----",
        "endif::demo[]",
    ]
    clean_findings, _c = scan_page("clean.adoc", clean)
    if clean_findings:
        print(f"❌ SELF-TEST FAILED: the CORRECT fixture was flagged ({clean_findings}). A guard "
              f"that fires on a shared definition, a `${{VAR:-default}}`, a quoted heredoc or a "
              f"captured-output block will be switched off by the first person it annoys, taking "
              f"the one detector that matters with it.", file=sys.stderr)
        ok = False

    # THE DRIVER, not just the page scanner. scan() is what the real run calls, and every assertion
    # above reaches scan_page() directly — so nothing yet proved the driver still collects what the
    # page scanner finds, or that pages_under() still finds pages.
    tree = tmpdir / "recon" / "content/modules/ROOT/pages/mod"
    tree.mkdir(parents=True)
    partials = tmpdir / "recon" / "content/modules/ROOT/partials"
    partials.mkdir(parents=True)
    # The definition lives in a PARTIAL, included from the lab flavor only. Antora inlines it; a
    # guard that does not is reading a different document from the one it is judging.
    (partials / "setup.adoc").write_text(
        "[source,sh]\n----\nINCLUDED_NS=lab-only\n----\n", encoding="utf-8")
    (tree / "lab.adoc").write_text("\n".join([
        "ifdef::demo[]", "[source,sh]", "----", "ask-agent \"go\"", "oc get pods -n $INCLUDED_NS",
        "----", "endif::demo[]",
        "ifndef::demo[]", "include::partial$setup.adoc[]", "[source,sh]", "----",
        "cat > ask-agent <<'EOF'", "x", "EOF", "----",
        "endif::demo[]",
    ]), encoding="utf-8")
    # Two: the lab page and the partial it includes. Partials are enumerated as pages here for the
    # same reason `git ls-files -- *.adoc` enumerates them in the repo mode — a partial holding a
    # demo region would otherwise be unreachable — and a partial with no region of its own costs
    # nothing.
    driven = pages_under(tmpdir / "recon")
    if len(driven) != 2:
        print(f"❌ SELF-TEST FAILED: pages_under() found {len(driven)} page(s) in a two-file "
              f"reconstruction — the discovery path a known-bad tree is checked through is broken.",
              file=sys.stderr)
        ok = False
    driven_findings, driven_rc, _s = scan(driven, root=tmpdir / "recon", floors=(1, 1, 1, 1),
                                          quiet=True)
    if driven_rc != 0:
        print(f"❌ SELF-TEST FAILED: the driver reported a collapsed scope (rc {driven_rc}) on a "
              f"tree it was handed.", file=sys.stderr)
        ok = False
    driven_keys = {f[4] for f in driven_findings if f[2] == "flavor-invisible-definition"}
    if "file:ask-agent" not in driven_keys:
        print("❌ SELF-TEST FAILED: scan() did not surface the finding scan_page() produces — the "
              "driver drops findings on the floor and the real run would report clean.",
              file=sys.stderr)
        ok = False
    if "var:INCLUDED_NS" not in driven_keys:
        print("❌ SELF-TEST FAILED: a definition that lives in an INCLUDED partial was not seen. "
              "Antora inlines includes; a guard that does not is judging a different document from "
              "the one that ships, and 220 include lines in this tree ride on it.", file=sys.stderr)
        ok = False

    # `ifeval::[]` is NOT modelled, and the docstring says its bodies are kept and COUNTED so the
    # silence reads as a measurement rather than an assumption. The counter is the only thing that
    # makes that claim checkable, so it gets an assertion.
    _f, ifeval_counters = scan_page("ifeval.adoc", [
        "ifeval::[\"{user}\" == \"user1\"]", "[source,sh]", "----", "X=1", "----", "endif::[]"])
    if ifeval_counters.get("ifeval", 0) < 1:
        print("❌ SELF-TEST FAILED: an ifeval:: line was not counted. The docstring promises the "
              "unmodelled construct is measured, not assumed absent.", file=sys.stderr)
        ok = False

    # The SCOPE ledger, deliberately collapsed. A guard whose detectors all work can still be
    # scanning nothing; rc 2 is what says so.
    if scan(driven, root=tmpdir / "recon", floors=(MIN_PAGES, MIN_DEMO_REGIONS, MIN_SHELL_BLOCKS,
                                                   MIN_IDENTIFIERS), quiet=True)[1] != 2:
        print("❌ SELF-TEST FAILED: a one-page scope did not trip the floors. The ledger that turns "
              "'I inspected almost nothing' into rc 2 is not wired up.", file=sys.stderr)
        ok = False

    # Detectors [3] and [4] — the artefact arm, with its own negative control. Without the GOOD
    # page a blinded built check would look identical to a working one.
    bad = tmpdir / "built-bad"
    (bad / "modules/mod").mkdir(parents=True)
    (bad / "modules/mod/lab.html").write_text(BUILT_BAD, encoding="utf-8")
    twin = tmpdir / "built-twin"
    (twin / "modules/mod").mkdir(parents=True)
    (twin / "modules/mod/lab.html").write_text(BUILT_TWIN, encoding="utf-8")
    good = tmpdir / "built-good"
    (good / "modules/mod").mkdir(parents=True)
    (good / "modules/mod/lab.html").write_text(BUILT_GOOD, encoding="utf-8")
    bad_findings, bad_pages = check_built([bad], [twin])
    good_findings, good_pages = check_built([good], [twin])
    if bad_pages != 2 or good_pages != 2:
        print(f"❌ SELF-TEST FAILED: the built scanner compared {bad_pages}/{good_pages} page(s) — "
              f"it is not reading the rendered blocks at all.", file=sys.stderr)
        ok = False
    hits = [f for f in bad_findings if f[2] == "built-use-without-definition"]
    if not [f for f in hits if f[4] == "file:ask-agent"]:
        print("❌ SELF-TEST FAILED: a built demo page with 1 `ask-agent` use and 0 definitions, "
              "whose non-demo twin defines it, was not flagged — the artefact detector is blind to "
              "the exact shape instance 3 shipped.", file=sys.stderr)
        ok = False
    # The OVER-FIRE control for the artefact arm. $SET_BY_THE_PRESENTER_BY_HAND is undefined on the
    # demo page AND on its twin, so it is not this class and must stay quiet. Without this line the
    # detector's first version reported 46 sites on a site with one defect.
    if [f for f in hits if f[4] == "var:SET_BY_THE_PRESENTER_BY_HAND"]:
        print("❌ SELF-TEST FAILED: the artefact detector flagged an identifier that is undefined "
              "in BOTH flavors. That is not this class, and firing on it drowns the one finding "
              "that matters.", file=sys.stderr)
        ok = False
    if not check_built([bad], [])[0] == []:
        print("❌ SELF-TEST FAILED: detector [3] produced findings with NO --built-non-demo to "
              "compare against. Without the twin there is nothing to compare and it must stay "
              "silent.", file=sys.stderr)
        ok = False
    if good_findings:
        print(f"❌ SELF-TEST FAILED: a built page that DEFINES `ask-agent` before using it was "
              f"flagged ({good_findings}).", file=sys.stderr)
        ok = False

    # The built ORDERING detector, on BOTH sides of the pair. It has two emission sites — one per
    # side — and a fixture that only exercises the demo side leaves the other able to stop working
    # silently.
    ubd_nd = tmpdir / "built-ubd-nondemo"
    (ubd_nd / "modules/ubd").mkdir(parents=True)
    (ubd_nd / "modules/ubd/lab.html").write_text(BUILT_NON_DEMO_UBD, encoding="utf-8")
    ubd_demo = tmpdir / "built-ubd-demo"
    (ubd_demo / "modules/ubd").mkdir(parents=True)
    (ubd_demo / "modules/ubd/lab.html").write_text(BUILT_DEMO_UBD, encoding="utf-8")
    ubd_findings, _n = check_built([ubd_demo], [ubd_nd])
    # -4, not -3: the path is <root>/modules/<slug>/<page>.html, so the ROOT name — the thing that
    # says which side of the pair produced the finding — is four components from the end.
    sides = {Path(f[0]).parts[-4] for f in ubd_findings if f[2] == "built-use-before-definition"}
    for side, label in ((ubd_demo.name, "demo"), (ubd_nd.name, "non-demo")):
        if side not in sides:
            print(f"❌ SELF-TEST FAILED: a built {label} page using $LATE_NS before defining it "
                  f"was not flagged. That arm of the built ordering detector is blind.",
                  file=sys.stderr)
            ok = False
    if not [f for f in check_built([tmpdir / "does-not-exist"], [])[0]
            if f[2] == "unreadable-built-dir"]:
        print("❌ SELF-TEST FAILED: a missing --built-demo directory was accepted. A gate handed "
              "nothing must say so, never report clean.", file=sys.stderr)
        ok = False

    # The LEDGER, both directions. A suppression list is a detector in reverse: if it stops
    # matching, a filed defect silently becomes a red build; if it outlives its defect, a page
    # quietly stops being guarded. Both arms are asserted, on the REAL ledger, so an entry whose
    # key rots is caught here rather than by whoever hits the next instance on that page.
    if not LEDGER:
        print("❌ SELF-TEST FAILED: the LEDGER is empty, so neither ledger arm below proves "
              "anything. Assert against a fixture entry if the backlog ever empties.",
              file=sys.stderr)
        ok = False
    else:
        page, kind, key, _reason = LEDGER[0]
        matching = [(f"content/modules/ROOT/pages/{page}", 9, kind, "synthetic", key)]
        kept, suppressed, stale = apply_ledger(matching)
        if kept or len(suppressed) != 1:
            print(f"❌ SELF-TEST FAILED: a finding the LEDGER names was not suppressed "
                  f"(kept={kept}). A filed, ledgered defect would redden CI.", file=sys.stderr)
            ok = False
        if len(stale) != len(LEDGER) - 1:
            print(f"❌ SELF-TEST FAILED: {len(stale)} stale entries reported when exactly "
                  f"{len(LEDGER) - 1} should be.", file=sys.stderr)
            ok = False
        _kept, _sup, all_stale = apply_ledger([])
        if len(all_stale) != len(LEDGER):
            print("❌ SELF-TEST FAILED: a LEDGER entry matching NOTHING was not reported stale. A "
                  "suppression that outlives its defect swallows the next instance on that page.",
                  file=sys.stderr)
            ok = False
        wrong_key = [(f"content/modules/ROOT/pages/{page}", 9, kind, "synthetic",
                      "var:NOT_THE_LEDGERED_NAME")]
        wrong_kept, wrong_sup, _st = apply_ledger(wrong_key)
        if wrong_sup:
            print("❌ SELF-TEST FAILED: the LEDGER suppressed a DIFFERENT identifier on a ledgered "
                  "page. An entry must license one defect, not a whole file.", file=sys.stderr)
            ok = False
        if len(wrong_kept) != 1:
            print(f"❌ SELF-TEST FAILED: an UNLEDGERED finding was not carried through "
                  f"(kept={wrong_kept}). If the keep path stops working every real finding is "
                  f"swallowed and the guard reports clean forever.", file=sys.stderr)
            ok = False

    if not ok:
        return 2
    print("✅ SELF-TEST: every detector fired on its own fixture line, the correct forms stayed "
          "quiet, the driver and the reconstruction discovery path both carry findings through, a "
          "collapsed scope exits 2, and the artefact arm caught the shape instance 3 shipped. "
          "Exiting 1 BY DESIGN — the canaries were detected.")
    return 1


def main(argv=None) -> int:
    # argv is a PARAMETER, not read from sys.argv, because tools/lint/_canary-coverage.py drives
    # every guard by calling `mod.main(argv)` POSITIONALLY, in-process, to blind one detector at a
    # time. A zero-argument `def main()` raises TypeError there, the harness's broad handler turns
    # it into "the guard could not run", and every detector in this file would be reported unproven.
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="run the canary fixtures; exits EXACTLY 1 when they are all detected")
    ap.add_argument("--root", default=None,
                    help="scan an arbitrary tree (a `git archive` reconstruction) instead of this "
                         "repo. Relaxes the scope floors, so it is NOT the CI mode.")
    ap.add_argument("--built-demo", action="append", default=[], metavar="DIR",
                    help="a built DEMO site to check the rendered blocks of (detectors [3] [4])")
    ap.add_argument("--built-non-demo", action="append", default=[], metavar="DIR",
                    help="a built non-demo site; checked for use-before-definition only")
    args = ap.parse_args(argv)

    if args.self_test:
        with tempfile.TemporaryDirectory() as tmp:
            return self_test(Path(tmp))

    root = Path(args.root).resolve() if args.root else REPO
    if not root.is_dir():
        print(f"::error::demo-region-identifier-guard: --root {root} is not a directory. Exiting "
              f"2 — a gate handed nothing to inspect has not passed.", file=sys.stderr)
        return 2
    pages = pages_under(root)
    floors = (1, 1, 1, 1) if args.root else (MIN_PAGES, MIN_DEMO_REGIONS, MIN_SHELL_BLOCKS,
                                             MIN_IDENTIFIERS)
    findings, collapse_rc, summary = scan(pages, root=root, floors=floors)
    if collapse_rc:
        return collapse_rc

    built_note = ""
    if args.built_demo or args.built_non_demo:
        built_findings, compared = check_built(args.built_demo, args.built_non_demo)
        findings.extend(built_findings)
        built_note = f" Built comparison: {compared} page(s) with shell blocks."
        if compared == 0:
            print("::error::demo-region-identifier-guard: the built directories held no page with "
                  "a shell block. Exiting 2 — that is an unread build, not a clean one.",
                  file=sys.stderr)
            return 2

    findings, suppressed, stale = apply_ledger(findings)
    for page, kind, key, _reason in stale:
        findings.append((page, 0, "stale-ledger-entry",
                         f"the LEDGER suppresses {kind} for {key} on {page}, and this run found "
                         f"no such defect", key))
    return report(findings, summary, built_note, suppressed)


if __name__ == "__main__":
    sys.exit(main())
