#!/usr/bin/env python3
"""curl-format-guard.py — catches brace expressions eaten as AsciiDoc attributes.

WHY THIS EXISTS (SEV, 2026-07-28, fixed in commit 2e6fc1c). content-build runs antora with
--log-failure-level=warn, so ANY "skipping reference to missing attribute" warning fails the
build. subs="attributes" turns attribute substitution ON for the block that follows it — and once
it is on, `%{http_code}` is no longer a literal curl format field to Asciidoctor, it is a percent
sign followed by the attribute reference `{http_code}`. No such attribute is defined, so the build
goes red. main stayed red for five hours before this specific class was found by hand
(eventing-deep-dive/lab.adoc, serverless-zero-to-hero/lab.adoc — six occurrences, two files).

Escape as `%\\{name}` — backslash immediately after the percent sign, before the brace — the same
escape form this repo already uses for `\\{claimNumber}`. Attribute refs like `{user}` in the same
block still resolve; only the curl field is protected.

TWO DETECTORS, ONE DEFECT CLASS. The trigger is never "a percent sign": it is *any* brace expression
whose inside happens to match Asciidoctor's attribute-name shape (`\\w[\\w-]*`) sitting in a block
where substitution is on. So this guard flags both:

  1. `%{name}` — the curl `-w` format field the SEV was made of.
  2. a BARE `{name}` that is not a defined attribute — most often the `{end}` of a kubectl/oc
     jsonpath `'{range .items[*]}{.metadata.name}{"\\n"}{end}'`. `{range …}` and `{.metadata.name}`
     are genuinely safe (a space, a leading dot — neither can start an attribute name), but `{end}`
     is indistinguishable from an attribute reference and produces exactly the same
     "skipping reference to missing attribute: end" warning. An earlier version of this docstring
     claimed jsonpath was safe as a category; that was true only of the leading-dot form, and the
     `{end}` hole was wide enough to reproduce the original SEV.

Real attribute references are NOT flagged: every attribute this project defines is collected first
(see collect_defined_attributes) — the generated version attributes, every `:name:` set anywhere in
content/, the `asciidoc.attributes` of antora.yml and the three site playbooks, plus Asciidoctor's
and Antora's own intrinsics — and a name in that set is left alone. The correct escapes `%\\{name}`
and `\\{name}` are never flagged either: the detector refuses a brace preceded by a backslash.

FIXING A HIT. Escape it (`%\\{http_code}`, `\\{end}`), or — usually better for a jsonpath-heavy
block — drop `subs="attributes"` from that block and use a shell variable instead of `{user}`.

USAGE
    tools/lint/curl-format-guard.py [path ...]     # default: content
    tools/lint/curl-format-guard.py --self-test     # scans the canary fixture; must exit non-zero

A guard that silently inspects zero files always "passes" — this repo relearned that lesson on
tools/lint/route-tls-guard.sh. This script refuses to report clean over an empty scope, and
--self-test exists so CI (and a human) can prove BOTH detectors actually fire before trusting a
clean result on the real tree (the fixture carries a case for each; a run that misses either one
exits 2, not 1).
"""
from __future__ import annotations

import argparse
import pathlib
import re
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
    print(f"::error::curl-format-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). "
          f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
          f"'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope, fixture_line_expectations  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad; see the note below
    # NOT `except ImportError`. Measured 2026-08-01: a _scope.py that fails to PARSE raises
    # SyntaxError, sails past an ImportError-only handler, and exits 1 — CI's 'the canary
    # fired'. Anything at all going wrong while loading the scope ledger means this guard
    # cannot start, and that is rc 2 regardless of which exception said so.
    # An uncaught ImportError exits 1, and CI's contract for this guard is "--self-test must exit
    # EXACTLY 1 = the canary was detected". A crash would therefore be READ AS PROOF OF DETECTION and
    # the real run would never even happen. Measured 2026-08-01 by running a copy of this file with
    # _scope.py absent: traceback, rc=1, and the CI step would have printed "self-test ok".
    print(f"::error::curl-format-guard: cannot import _scope ({exc}) — "
          f"the guard could not start, which is NOT the same as a clean tree.",
          file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    WHY (measured 2026-08-01). Every pattern compiled at MODULE level raises re.error before main()
    — and before any try/except inside it — can run. Python exits 1 on an uncaught exception, and 1
    is exactly what CI's `--self-test must exit EXACTLY 1` assertion accepts as "the canary was
    detected". A one-character regex typo therefore reported the guard's detection as PROVEN while
    the guard could not even load. A regex is the likeliest thing to break in a guard, so the
    compile step is where the exit code has to be fixed.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::curl-format-guard: {name} is not a valid regex ({exc}) — "
              f"the guard could not load. Exiting 2: that is 'the guard is broken', not "
              f"'the canary fired'.", file=sys.stderr)
        sys.exit(2)


# Curl -w format fields most likely to show up in this repo's labs. Informational only — the
# scanner below flags ANY %{lowercase_identifier} shape inside a subs="attributes" block, because
# that is exactly the shape Asciidoctor's own attribute-reference syntax matches, and a field we
# did not think to list here is exactly as dangerous as one we did.
KNOWN_CURL_FIELDS = (
    "http_code", "time_total", "size_download", "size_upload",
    "url_effective", "content_type", "speed_download", "speed_upload",
)

# The block-attribute line that turns attribute substitution on for the block it precedes. Must be a
# real attribute list (starts with `[`) — the phrase also appears in `//` authoring comments.
OPENER_RE = _compile("OPENER_RE", r'^\[[^\]]*\bsubs\s*=\s*["\']?[^\]]*attributes')

# A delimiter line opens/closes an AsciiDoc delimited block: 2+ repeats of one of - . = * _, or the
# table delimiter |===. (An "open block" delimiter is exactly "--", also matched here.)
DELIMITER_RE = _compile("DELIMITER_RE", r"^(-{2,}|\.{2,}|={2,}|\*{2,}|_{2,}|\|={2,})\s*$")

# The defect, both shapes at once. Group 1 is the optional percent sign; group 2 is an
# Asciidoctor-attribute-name-shaped identifier (its AttributeReferenceRx is `\{(\w+[\w-]*)\}`).
# The lookbehind is what spares the correct escapes: in `%\{http_code}` and `\{end}` a backslash
# sits immediately before the brace, so neither can match.
REFERENCE_RE = _compile("REFERENCE_RE", r"(?<!\\)(%?)\{([A-Za-z0-9_][A-Za-z0-9_\-]*)\}")

# Asciidoctor/Antora built-ins. Referencing one of these is always legitimate, and none of them is
# ever a curl field or a jsonpath keyword. (Antora's page-* family is allowed by prefix below.)
INTRINSIC_ATTRIBUTES = frozenset("""
amp apos asterisk backslash backtick blank brvbar caret cpp deg empty endsb gt ldquo lsquo lt
nbsp none plus pp quot rdquo rsquo sp startsb tilde two-colons two-semicolons vbar wj zwsp
backend backend-html5 basebackend doctitle docname docfile docdir docdate doctime docdatetime
localdate localtime localdatetime outfilesuffix safe-mode-name embedded env env-site
idprefix idseparator imagesdir sectnums toc experimental
""".split())

ALLOWED_PREFIXES = ("page-",)

# `:name: value` / `:name!:` — an attribute DEFINITION in AsciiDoc source.
ATTR_DEF_RE = _compile("ATTR_DEF_RE", r"^:!?([A-Za-z0-9_][A-Za-z0-9_\-]*)!?:")

# A key inside a playbook's `asciidoc: attributes:` mapping.
YAML_KEY_RE = _compile("YAML_KEY_RE", r"^(\s+)([A-Za-z0-9_][A-Za-z0-9_\-]*)\s*:")


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def _yaml_asciidoc_attributes(path: pathlib.Path):
    """Keys under `asciidoc:` → `attributes:` in an Antora playbook / component descriptor.

    Deliberately a 20-line indentation scan rather than a PyYAML import: this guard runs in CI on a
    bare python3 and must never fail because a parser is missing.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    in_asciidoc = in_attrs = False
    attrs_indent = None
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"^asciidoc\s*:", line):
            in_asciidoc, in_attrs, attrs_indent = True, False, None
            continue
        if in_asciidoc and not line[:1].isspace():   # a new top-level key ends the section
            in_asciidoc = in_attrs = False
            continue
        if in_asciidoc and re.match(r"^\s+attributes\s*:", line):
            in_attrs = True
            attrs_indent = len(line) - len(line.lstrip())
            continue
        if in_attrs:
            m = YAML_KEY_RE.match(line)
            if not m or len(m.group(1)) <= attrs_indent:
                in_attrs = False
                continue
            yield m.group(2)


def collect_defined_attributes(root: pathlib.Path) -> frozenset:
    """Every attribute name this project can legitimately reference.

    Sources, in the order they matter: the generated version attributes and every other `:name:`
    definition anywhere in content/ (pages define their own, e.g. `:demo-title:`), the
    `asciidoc.attributes` of content/antora.yml and the three site-*.yml playbooks (that is where
    {user}, {gitea_url}, {ocp_console_url}, the flavor flags … come from), and the built-ins above.
    """
    names = set(INTRINSIC_ATTRIBUTES)
    content = root / "content"
    for adoc in content.rglob("*.adoc"):
        try:
            for line in adoc.read_text(encoding="utf-8").splitlines():
                if line.startswith(":"):
                    m = ATTR_DEF_RE.match(line)
                    if m:
                        names.add(m.group(1))
        except (UnicodeDecodeError, OSError):
            continue
    for cfg in sorted(content.glob("site-*.yml")) + [content / "antora.yml"]:
        if cfg.is_file():
            names.update(_yaml_asciidoc_attributes(cfg))
    return frozenset(names)


def find_offenders(path: pathlib.Path, defined: frozenset):
    """Return (offenders, scope counters) for one file.

    Each offender is (line_no, kind, name); kind is "curl" for `%{name}` (the SEV's shape) or "attr"
    for a bare `{name}` that no attribute defines (the `{end}`-of-jsonpath shape).

    The counters are raised by the walk itself — one per subs="attributes" block ENTERED and one per
    body line actually fed to the detector. That second one is the only thing that would notice the
    scanner quietly inspecting just the first line of each block: the offender list looks identical
    on this tree either way, because every defect it currently knows about happens to sit on line 1.
    """
    offenders: list[tuple[int, str, str]] = []
    counts = {"attribute-substitution blocks": 0, "block body lines inspected": 0}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return offenders, counts
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if OPENER_RE.match(line.lstrip()):
            # The delimiter must be the very next line for the attribute list to apply to it.
            j = i + 1
            if j < n and DELIMITER_RE.match(lines[j]):
                delim = lines[j].rstrip()
                k = j + 1
                counts["attribute-substitution blocks"] += 1
                while k < n and lines[k].rstrip() != delim:
                    counts["block body lines inspected"] += 1
                    for m in REFERENCE_RE.finditer(lines[k]):
                        name = m.group(2)
                        if m.group(1) == "%":
                            offenders.append((k + 1, "curl", name))
                        elif name not in defined and not name.startswith(ALLOWED_PREFIXES):
                            offenders.append((k + 1, "attr", name))
                    k += 1
                i = k  # resume scanning after the closing delimiter (or at EOF if unterminated)
        i += 1
    return offenders, counts


def collect_files(roots):
    files = []
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            files.extend(sorted(p.rglob("*.adoc")))
    return files


def scope_for_tree() -> Scope:
    """Floors for a real-tree run over content/. Measured 2026-08-01: 139 .adoc files, 198
    subs="attributes" blocks carrying 919 body lines, 118 attribute names collected."""
    scope = Scope("curl-format-guard")
    scope.require("files scanned", 90,
                  "content/ holds ~139 .adoc pages. A handful means the walk stopped recursing — "
                  "the shape that let a one-file scan report the whole tree clean.")
    scope.require("attribute-substitution blocks", 120,
                  'blocks that actually opened a subs="attributes" body. Zero means the opener or '
                  "delimiter match broke and every page now looks defect-free.")
    scope.require("block body lines inspected", 500,
                  "lines fed to the detector INSIDE those blocks. This is what collapses (to ~198, "
                  "one per block) if the scanner ever reads only a block's first line — a shrink "
                  "that changes no finding on today's tree and would therefore be invisible.")
    scope.require("attribute names collected", 60,
                  "the defined-attribute set. If it collapses, every legitimate {user}/{gitea_url} "
                  "reference in the tree becomes an 'undefined attribute' finding instead.")
    return scope


def scope_for_self_test() -> Scope:
    """The canary is one small file; only the floors it can meet are asserted, and they still prove
    the walk reached inside the blocks."""
    scope = Scope("curl-format-guard --self-test")
    scope.require("files scanned", 1, "the canary fixture.")
    scope.require("attribute-substitution blocks", 4, "the fixture declares four blocks.")
    scope.require("block body lines inspected", 6,
                  "the fixture's blocks are deliberately multi-line so a first-line-only scan is "
                  "visible here too, not just on the real tree.")
    scope.require("attribute names collected", 60, "same collection as the real run.")
    return scope


def fixture_expectation_failures(fixture: pathlib.Path, fired_lines) -> list[str]:
    return fixture_line_expectations(fixture, fired_lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=["content"],
                     help="file(s) or director(ies) to scan (default: content)")
    ap.add_argument("--self-test", action="store_true",
                     help="scan only the canary fixture next to this script; a clean (0) result "
                          "here means the detector is broken, not that the fixture is fine")
    args = ap.parse_args(argv)

    if args.self_test:
        fixture = pathlib.Path(__file__).resolve().parent / "curl-format-guard.canary.adoc"
        roots = [fixture]
    else:
        roots = args.paths

    files = collect_files(roots)
    if not files:
        print(f"curl-format-guard: no .adoc files found under {roots!r} — refusing to report "
              "clean over an empty scope.", file=sys.stderr)
        return 2

    scope = scope_for_self_test() if args.self_test else scope_for_tree()
    defined = collect_defined_attributes(repo_root())
    scope.add("files scanned", len(files))
    scope.add("attribute names collected", len(defined))
    offenders = 0
    kinds_seen = set()
    fired_lines: set[int] = set()
    for f in files:
        file_offenders, counts = find_offenders(f, defined)
        scope.merge(counts)
        for line_no, kind, name in file_offenders:
            offenders += 1
            kinds_seen.add(kind)
            fired_lines.add(line_no)
            if kind == "curl":
                print(f'{f}:{line_no}: %{{{name}}} is inside a subs="attributes" block — '
                      f'escape as %\\{{{name}}}')
            else:
                print(f'{f}:{line_no}: {{{name}}} is inside a subs="attributes" block and no such '
                      f'attribute is defined — antora warns "skipping reference to missing '
                      f'attribute: {name}" and the build fails at --log-failure-level=warn. Escape '
                      f'as \\{{{name}}}, or drop subs="attributes" from the block '
                      f'(jsonpath {{range …}}…{{end}} is the usual source).')

    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if args.self_test:
        failures = []
        missing = {"curl", "attr"} - kinds_seen
        if missing:
            failures.append(f"the canary fixture did not trigger the {sorted(missing)} detector(s).")
        failures += fixture_expectation_failures(files[0], fired_lines)
        failures += Scope.self_check()
        if failures:
            for failure in failures:
                print(f"curl-format-guard: SELF-TEST FAILED — {failure} The guard, not the "
                      f"fixture, is broken.", file=sys.stderr)
            return 2

    if offenders:
        print(f"\ncurl-format-guard: {offenders} offender(s) across {len(files)} file(s) scanned.",
              file=sys.stderr)
        return 1

    print(f"curl-format-guard: clean ({scope.summary()}).")
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
        print(f"::error::curl-format-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
