#!/usr/bin/env python3
"""version-anchor-guard.py — keeps OpenShift version numbers out of attendee-facing prose.

WHY THIS EXISTS (owner directive, Foundations review 2026-07-13/14; re-raised 2026-07-29).
Attendee pages must not anchor themselves to an OpenShift version. The workshop is delivered on
whatever cluster the SA has, and a page that names a release is wrong for every other one.

The 2026-07-29 re-raise found something worse than staleness. Five sentences read

    "It is GA on OpenShift {ocp_version}."

`{ocp_version}` resolves to the version of the cluster the docs were BUILT for. But GA is a fact
about the product timeline, not about the cluster in front of the reader, so that sentence asserts
"this feature became GA in <whatever versions.yaml says today>" — false for all three features
written that way (Gateway API, UserDefinedNetwork, native sidecars all landed earlier). And because
the binding is dynamic, the false claim CHANGED on every version bump: the same source line asserted
4.21.22 the day before. A sentence that silently re-asserts something new whenever a config file
moves is a defect generator, which is what makes this a lint gate and not a style note.

WHAT IS AND IS NOT IN SCOPE

  IN — concept.adoc, lab.adoc, wrapup.adoc. Owner ruling 2026-07-29: "only showroom pages".
  That is precisely this set — showroom/site.yml sets `workshop: true`, which makes
  modules/ROOT/nav.adoc select nav-workshop.adoc, whose sidebar is exactly concept + lab + wrapup.
  If the cockpit's flavor or nav ever changes, this list must be re-derived from it, not guessed.

  OUT — instructor.adoc and troubleshooting.adoc. Note this is a DELIBERATE owner call, not an
  oversight, and specifically not an argument that attendees cannot reach these pages — they can.
  Nine lab pages xref troubleshooting directly, and the built workshop site publishes all 26
  troubleshooting AND all 26 instructor pages with live hrefs. The exclusion stands anyway because
  the version text there is PROVENANCE ("Last verified on OpenShift X, 2026-07-13"): a dated
  freshness signal, not a claim about the product, so it cannot go wrong the way "GA on 4.22.5" did.

  This paragraph used to end "80 such lines exist and all are correct. Do not close the gap — it was
  measured and kept." That was FALSE, and saying so with confidence made it durable: 48 of those
  lines interpolated LIVE attributes ({ocp_version}, {istio_version}, …) rather than literals, so
  every versions.yaml bump silently re-dated them and made each page assert a verification that
  never happened. versions.yaml moved twice on 2026-07-31 alone. Worse, commit 9f0ff1e9 had
  deliberately re-templated a CORRECT literal (Istio v1.28.6) into {istio_version} in six places,
  believing templating was always the fix — this very sentence is what would have blessed that.

  All 48 were frozen to literals on 2026-07-31, sourced from a versions.yaml timeline reconstructed
  with `git log -p` — never from the current file, which is the one whose movement caused the bug.

  So the exclusion still stands, but for the honest reason: provenance must be a FROZEN record of
  what was observed. A provenance line containing `{...}` is a defect, not a convention. What stays
  dynamic is guidance about the reader's own cluster ("Expect `istio {istio_version} Healthy`") —
  that describes their present, not our past.

  OUT — `//` authoring comments, on every page. Recording "grounded on OCP 4.22.5 as user1" next to
  a click-path is exactly how a capture should be attributed. Comments do not render.

  OUT — verbatim blocks (`----` listing, `....` literal). Captured output must show what the cluster
  actually printed, version strings and all; doctoring it would be a worse lie than the anchor.

TWO DETECTORS, ONE DEFECT CLASS. The trigger is "an OpenShift release identifies itself in prose an
attendee reads", and it arrives in two shapes that must both be caught — a guard that only knew the
attribute form would quietly teach authors to hardcode instead, which is strictly worse:

  1. "attr"    — {ocp_version} and its siblings ({ocp_image_policy_version}, …).
  2. "literal" — a bare 4.NN / 4.NN.N / v4.NN written into the sentence.

THE DELIBERATE EXCEPTION. Sometimes the version IS the lesson — packaging-distributing teaches that
the operator catalog index tag tracks the cluster's OpenShift minor, and that paragraph cannot be
written without naming one. Mark those:

    // version-anchor-ok: <why this paragraph must name a release>

The marker exempts the rest of the paragraph (through the next blank line), so it covers a wrapped
sentence without blanket-exempting the file. It requires a reason so the next reader can judge it.

USAGE
    tools/lint/version-anchor-guard.py [path ...]   # default: content/modules/ROOT/pages
    tools/lint/version-anchor-guard.py --self-test  # scans the canary; MUST exit non-zero

A guard that inspects zero files always "passes" — this repo learned that on route-tls-guard.sh, and
again when a whole CI job turned out to run no tests at all. So this refuses to report clean over an
empty scope, and --self-test proves BOTH detectors fire AND that the opt-out actually suppresses (a
canary run that misses either detector, or that flags the exempted paragraph, exits 2 rather than 1 —
"the guard is broken", not "the fixture is dirty").
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
    print(f"::error::version-anchor-guard: crashed before it could report "
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
    print(f"::error::version-anchor-guard: cannot import _scope ({exc}) — "
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
        print(f"::error::version-anchor-guard: {name} is not a valid regex ({exc}) — "
              f"the guard could not load. Exiting 2: that is 'the guard is broken', not "
              f"'the canary fired'.", file=sys.stderr)
        sys.exit(2)


# The attendee-facing renderings. Numbers may not appear here; instructor/troubleshooting are
# provenance surfaces and are deliberately absent.
ATTENDEE_PAGES = ("concept.adoc", "lab.adoc", "wrapup.adoc")

# Any version attribute that carries an OpenShift release. Product versions ({pipelines_version},
# {gitops_version}, …) are NOT matched: naming the product release in "the OpenShift Pipelines guide
# (Pipelines 1.20)" is useful and does not date the page to a cluster.
ATTR_RE = _compile("ATTR_RE", r"\{(ocp[A-Za-z0-9_]*_version|ocp_version)\}")

# A hardcoded OpenShift release. Two digits after the dot is what separates a release (4.19 … 4.99)
# from an ordinary number ("4.5 GB"). The lookbehind rejects a digit or dot before the match, so an
# IP address like 10.14.221.9 cannot produce a false "4.22", and an optional leading `v` catches the
# `v4.22` catalog-tag form.
LITERAL_RE = _compile("LITERAL_RE", r"(?<![\w.])v?4\.\d{2}(?:\.\d+)?(?!\d)")

# Verbatim block delimiters — listing and literal. Their contents are captured output.
VERBATIM_DELIM_RE = _compile("VERBATIM_DELIM_RE", r"^(-{4,}|\.{4,})\s*$")

# The deliberate-exception marker. A reason is mandatory.
OPT_OUT_RE = _compile("OPT_OUT_RE", r"^\s*//\s*version-anchor-ok\s*:\s*\S")
# Same marker with the reason missing — reported, so it can't be used as a silent blanket.
OPT_OUT_BARE_RE = _compile("OPT_OUT_BARE_RE", r"^\s*//\s*version-anchor-ok\s*:?\s*$")

COMMENT_RE = _compile("COMMENT_RE", r"^\s*//")


def find_offenders(path: pathlib.Path):
    """Return (offenders, scope counters) for one page.

    Each offender is (line_no, kind, text); kind is "attr" ({ocp_version}), "literal" (4.22), or
    "marker" (an opt-out with no reason).

    "prose lines inspected" counts only lines that reached the two detectors — past the verbatim
    blocks, the `//` comments and any active opt-out. It is what collapses if the page walk breaks,
    and it is measured HERE rather than as len(lines) in main() so it cannot be satisfied by a walk
    that never happened.
    """
    offenders: list[tuple[int, str, str]] = []
    counts = {"attendee pages read": 0, "prose lines inspected": 0}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return offenders, counts
    counts["attendee pages read"] += 1

    in_verbatim = False
    verbatim_delim = ""
    exempt = False          # inside a paragraph covered by an opt-out marker

    for i, line in enumerate(lines, start=1):
        stripped = line.rstrip()

        # Verbatim blocks: enter on a delimiter, leave on the matching one. Captured output inside
        # is never scanned.
        if in_verbatim:
            if stripped == verbatim_delim:
                in_verbatim = False
            continue
        if VERBATIM_DELIM_RE.match(stripped):
            in_verbatim, verbatim_delim = True, stripped
            continue

        # A blank line ends an opt-out's reach — the exemption is per-paragraph, not per-file.
        if not stripped.strip():
            exempt = False
            continue

        if OPT_OUT_BARE_RE.match(line):
            offenders.append((i, "marker", "// version-anchor-ok with no reason given"))
            exempt = True
            continue
        if OPT_OUT_RE.match(line):
            exempt = True
            continue

        # Authoring comments never render; attributing a capture to a release is correct there.
        if COMMENT_RE.match(line):
            continue

        if exempt:
            continue

        counts["prose lines inspected"] += 1
        for m in ATTR_RE.finditer(line):
            offenders.append((i, "attr", m.group(0)))
        for m in LITERAL_RE.finditer(line):
            offenders.append((i, "literal", m.group(0)))
    return offenders, counts


def collect_files(roots):
    files = []
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            files.extend(sorted(
                f for f in p.rglob("*.adoc") if f.name in ATTENDEE_PAGES
            ))
    return files


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=["content/modules/ROOT/pages"],
                    help="file(s) or director(ies) to scan (default: content/modules/ROOT/pages)")
    ap.add_argument("--self-test", action="store_true",
                    help="scan only the canary fixture; a clean (0) result there means the "
                         "detector is broken, not that the tree is fine")
    args = ap.parse_args(argv)

    if args.self_test:
        fixture = pathlib.Path(__file__).resolve().parent / "version-anchor-guard.canary.adoc"
        files = [fixture]
    else:
        files = collect_files(args.paths)

    if not files:
        print(f"version-anchor-guard: no attendee pages ({', '.join(ATTENDEE_PAGES)}) found under "
              f"{args.paths!r} — refusing to report clean over an empty scope.", file=sys.stderr)
        return 2

    scope = scope_for_self_test() if args.self_test else scope_for_tree()
    offenders = 0
    kinds_seen = set()
    fired_lines: set[int] = set()
    for f in files:
        file_offenders, counts = find_offenders(f)
        scope.merge(counts)
        for line_no, kind, text in file_offenders:
            offenders += 1
            kinds_seen.add(kind)
            fired_lines.add(line_no)
            if kind == "attr":
                print(f"{f}:{line_no}: {text} anchors attendee prose to the build cluster's "
                      f"release. It also makes any 'GA in'/'shipped with' claim re-assert a new "
                      f"version on every versions.yaml bump. Drop the version, or move the "
                      f"sentence to instructor.adoc/troubleshooting.adoc where it is provenance.")
            elif kind == "literal":
                print(f"{f}:{line_no}: hardcoded OpenShift release '{text}' in attendee prose. "
                      f"The workshop runs on whatever cluster the SA has. Drop it — or, if the "
                      f"release genuinely IS the lesson, precede the paragraph with "
                      f"'// version-anchor-ok: <reason>'.")
            else:
                print(f"{f}:{line_no}: {text} — the opt-out requires a reason so the next reader "
                      f"can judge whether it still applies.")

    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if args.self_test:
        failures = []
        missing = {"attr", "literal", "marker"} - kinds_seen
        if missing:
            failures.append(f"the canary did not trigger the {sorted(missing)} detector(s).")
        # Proof for collect_files' file-vs-directory branch. The plain run above (and every other
        # call to collect_files in this file) always hands it a DIRECTORY
        # (content/modules/ROOT/pages); the explicitly-named-single-file shape — `guard.py <file>`
        # — is real-run reachable (it lives in main()'s non-self-test branch) but exercised by no
        # canary, so assert it directly against the fixture itself.
        named = collect_files([fixture])
        if named != [fixture]:
            failures.append(f"collect_files([{fixture}]) returned {named!r}, not [{fixture}] — "
                            f"the explicitly-named-file branch is broken.")
        # Per-LINE expectations, not a total. The old check looked for "EXEMPT-MUST-NOT-FIRE" in the
        # offender's TEXT — but text is the matched token ("4.22"), never the line — so it could
        # never fire, and blinding the opt-out left the self-test at 1. The markers in the fixture
        # now pin which lines must be flagged and which must not, including the first line AFTER the
        # exempted paragraph's blank line, which is what proves the exemption ENDS.
        failures += fixture_line_expectations(files[0], fired_lines)
        failures += Scope.self_check()
        if failures:
            for failure in failures:
                print(f"version-anchor-guard: SELF-TEST FAILED — {failure} The guard, not the "
                      f"fixture, is broken.", file=sys.stderr)
            return 2

    if offenders:
        print(f"\nversion-anchor-guard: {offenders} offender(s) across {len(files)} attendee "
              f"page(s) scanned.", file=sys.stderr)
        return 1

    print(f"version-anchor-guard: clean ({scope.summary()}).")
    return 0


def scope_for_tree() -> Scope:
    """Floors for a real-tree run. Measured 2026-08-01: 78 attendee pages, ~9,900 prose lines
    reaching the detectors."""
    scope = Scope("version-anchor-guard")
    scope.require("attendee pages read", 60,
                  f"the catalog ships 26 modules x {len(ATTENDEE_PAGES)} attendee renderings = 78 "
                  "pages. A handful means collect_files stopped matching, not that modules were "
                  "removed — and a one-file scan reporting the whole tree clean is the shape this "
                  "floor exists for.")
    scope.require("prose lines inspected", 4000,
                  "lines that actually reached the two detectors, past verbatim blocks, `//` "
                  "comments and active opt-outs. If this collapses, the pages were opened and not "
                  "read.")
    return scope


def scope_for_self_test() -> Scope:
    scope = Scope("version-anchor-guard --self-test")
    scope.require("attendee pages read", 1, "the canary fixture.")
    scope.require("prose lines inspected", 10,
                  "the fixture's prose must actually reach the detectors; a walk that skips it "
                  "would otherwise look like a canary with nothing in it.")
    return scope


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
        print(f"::error::version-anchor-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
