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
OPENER_RE = re.compile(r'^\[[^\]]*\bsubs\s*=\s*["\']?[^\]]*attributes')

# A delimiter line opens/closes an AsciiDoc delimited block: 2+ repeats of one of - . = * _, or the
# table delimiter |===. (An "open block" delimiter is exactly "--", also matched here.)
DELIMITER_RE = re.compile(r"^(-{2,}|\.{2,}|={2,}|\*{2,}|_{2,}|\|={2,})\s*$")

# The defect, both shapes at once. Group 1 is the optional percent sign; group 2 is an
# Asciidoctor-attribute-name-shaped identifier (its AttributeReferenceRx is `\{(\w+[\w-]*)\}`).
# The lookbehind is what spares the correct escapes: in `%\{http_code}` and `\{end}` a backslash
# sits immediately before the brace, so neither can match.
REFERENCE_RE = re.compile(r"(?<!\\)(%?)\{([A-Za-z0-9_][A-Za-z0-9_\-]*)\}")

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
ATTR_DEF_RE = re.compile(r"^:!?([A-Za-z0-9_][A-Za-z0-9_\-]*)!?:")

# A key inside a playbook's `asciidoc: attributes:` mapping.
YAML_KEY_RE = re.compile(r"^(\s+)([A-Za-z0-9_][A-Za-z0-9_\-]*)\s*:")


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
    """Yield (line_no, kind, name) for every brace reference at risk inside a subs="attributes" body.

    kind is "curl" for `%{name}` (the SEV's shape) or "attr" for a bare `{name}` that no attribute
    defines (the `{end}`-of-jsonpath shape).
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if OPENER_RE.match(line.lstrip()):
            # The delimiter must be the very next line for the attribute list to apply to it.
            j = i + 1
            if j < n and DELIMITER_RE.match(lines[j]):
                delim = lines[j].rstrip()
                k = j + 1
                while k < n and lines[k].rstrip() != delim:
                    for m in REFERENCE_RE.finditer(lines[k]):
                        name = m.group(2)
                        if m.group(1) == "%":
                            yield (k + 1, "curl", name)
                        elif name not in defined and not name.startswith(ALLOWED_PREFIXES):
                            yield (k + 1, "attr", name)
                    k += 1
                i = k  # resume scanning after the closing delimiter (or at EOF if unterminated)
        i += 1


def collect_files(roots):
    files = []
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            files.extend(sorted(p.rglob("*.adoc")))
    return files


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

    defined = collect_defined_attributes(repo_root())
    offenders = 0
    kinds_seen = set()
    for f in files:
        for line_no, kind, name in find_offenders(f, defined):
            offenders += 1
            kinds_seen.add(kind)
            if kind == "curl":
                print(f'{f}:{line_no}: %{{{name}}} is inside a subs="attributes" block — '
                      f'escape as %\\{{{name}}}')
            else:
                print(f'{f}:{line_no}: {{{name}}} is inside a subs="attributes" block and no such '
                      f'attribute is defined — antora warns "skipping reference to missing '
                      f'attribute: {name}" and the build fails at --log-failure-level=warn. Escape '
                      f'as \\{{{name}}}, or drop subs="attributes" from the block '
                      f'(jsonpath {{range …}}…{{end}} is the usual source).')

    if args.self_test:
        missing = {"curl", "attr"} - kinds_seen
        if missing:
            print(f"curl-format-guard: SELF-TEST FAILED — the canary fixture did not trigger the "
                  f"{sorted(missing)} detector(s). The guard, not the fixture, is broken.",
                  file=sys.stderr)
            return 2

    if offenders:
        print(f"\ncurl-format-guard: {offenders} offender(s) across {len(files)} file(s) scanned.",
              file=sys.stderr)
        return 1

    print(f"curl-format-guard: clean ({len(files)} file(s) scanned, "
          f"{len(defined)} attribute names known).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
