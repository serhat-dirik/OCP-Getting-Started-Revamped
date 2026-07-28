#!/usr/bin/env python3
"""curl-format-guard.py — catches curl -w format fields eaten as AsciiDoc attributes.

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

WHAT IT DOES NOT FLAG. jsonpath expressions such as `{.spec.template...}` inside the same kind of
block are safe and are deliberately not flagged: Asciidoctor's attribute-reference syntax requires
the name to start with a letter/underscore, so a leading `.` (or `[`) never matches. This guard
mirrors that shape (`[a-z_][a-z0-9_]*`) rather than "anything between braces", so it does not cry
wolf on jsonpath. And the correct escape `%\\{name}` is never flagged either — by construction: the
detector requires a percent immediately followed by a brace, and the backslash in the escaped form
sits exactly between them, breaking the match.

USAGE
    tools/lint/curl-format-guard.py [path ...]     # default: content
    tools/lint/curl-format-guard.py --self-test     # scans the canary fixture; must exit non-zero

A guard that silently inspects zero files always "passes" — this repo relearned that lesson on
tools/lint/route-tls-guard.sh. This script refuses to report clean over an empty scope, and
--self-test exists so CI (and a human) can prove the detector actually fires before trusting a
clean result on the real tree.
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

# The block-attribute line that turns attribute substitution on for the block it precedes.
OPENER_MARKER = 'subs="attributes"'

# A delimiter line opens/closes an AsciiDoc delimited block: 2+ repeats of one of - . = * _, or the
# table delimiter |===. (An "open block" delimiter is exactly "--", also matched here.)
DELIMITER_RE = re.compile(r"^(-{2,}|\.{2,}|={2,}|\*{2,}|_{2,}|\|={2,})\s*$")

# The defect: a literal percent immediately followed by a brace and an Asciidoctor-attribute-name-
# shaped identifier. The correctly escaped form is %\{name} — the backslash sits exactly where this
# pattern requires an immediate "{", so escaped occurrences never match this regex.
OFFENDER_RE = re.compile(r"%\{([a-z_][a-z0-9_]*)\}")


def find_offenders(path: pathlib.Path):
    """Yield (line_no, name) for every unescaped %{name} inside a subs="attributes" block body."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if OPENER_MARKER in line and line.lstrip().startswith("["):
            # The delimiter must be the very next line for the attribute list to apply to it.
            j = i + 1
            if j < n and DELIMITER_RE.match(lines[j]):
                delim = lines[j].rstrip()
                k = j + 1
                while k < n and lines[k].rstrip() != delim:
                    for m in OFFENDER_RE.finditer(lines[k]):
                        yield (k + 1, m.group(1))
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

    offenders = 0
    for f in files:
        for line_no, name in find_offenders(f):
            offenders += 1
            print(f'{f}:{line_no}: %{{{name}}} is inside a subs="attributes" block — '
                  f'escape as %\\{{{name}}}')

    if offenders:
        print(f"\ncurl-format-guard: {offenders} offender(s) across {len(files)} file(s) scanned.",
              file=sys.stderr)
        return 1

    print(f"curl-format-guard: clean ({len(files)} file(s) scanned).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
