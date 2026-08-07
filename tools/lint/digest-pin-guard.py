#!/usr/bin/env python3
"""digest-pin-guard.py — the curated Parasol task library ships NO floating image tags.

WHY THIS EXISTS. `pipelines/tasks/image-size-report.yaml` shipped `ose-cli:latest` for the whole
life of the module that TEACHES digest pinning. Nothing noticed, because nothing was looking: the
repo had guards for pull policy, CDN assets, API-key shapes and eight kinds of copy drift, and none
of them asserted that an image reference is immutable. A floating tag means the thing that runs is
whatever the registry served that minute, and a supply-chain workshop demonstrating that with its
own tooling is the contradiction a reviewer notices first.

The fix was worse than it looked, which is the other reason this guard exists. `ose-cli:latest` on
the el8 `openshift4/ose-cli` repository is not "the newest oc" — it is the ONLY short tag that repo
publishes (v4.16…v4.22 are all absent) and it has been frozen on v4.15.0 since 2025-09-25, carrying
freshness grade D and "unapplied Critical or Important security errata". A floating tag had drifted
to something OLDER than the workshop's own OCP floor and nobody could see it from the manifest.

SCOPE, AND WHY IT IS THIS AND NOT THE WHOLE REPO. Measured 2026-08-08 over the tracked tree:

    git grep -nE '^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*[^[:space:]]+:latest'

returned 55 occurrences outside this directory's own fixtures. FORTY-FOUR of them are `kind: Job` —
one-shot install/seed/entry-state hooks that run once, on a cluster being built, and are deleted
afterwards. Those are a real but different risk, and a gate that failed on 44 pre-existing findings
would be switched off within a day, taking the 11 findings that matter with it. So this guard
polices the artifact where immutability is the actual product:

    pipelines/tasks/*.yaml                              the 8 canonical curated Tasks
    gitops/workshop-config/templates/parasol-tasks.yaml the same 8, republished by the workshop layer

That library is a platform team's published contract — `taskRef`'d by cluster resolver from every
app pipeline, read by attendees as the exemplar, and the thing the supply-chain module points at.
Its blast radius is every pipeline on the cluster, not one namespace being bootstrapped.

The rule is one the tree passes today, which is the only kind of rule that survives. Measured on the
canonical copy at the commit before this guard landed: 12 `image:` fields, of which 1 is a `${IMAGE}`
parameter, leaving 11 real step images — and TEN of those 11 were already digest-pinned. The library
had one floating tag, `image-size-report`, and pinning it made the convention unanimous rather than
imposing a new one. Across both copies the guard now reads 9 files and 24 fields, judging 22.

DELIBERATELY OUT OF SCOPE, so nobody reads a green tick as more than it is:
  * the 44 one-shot hook Jobs above (`gitops/entry-states/**`, `gitops/workshop-config/**`,
    `platform-portfolio/components/**`). Worth fixing; needs its own sweep and a cluster smoke,
    because those images are pulled during install and a bad pin breaks the installer, not a lab.
  * the 3 remaining floating tags in Tekton PIPELINE step images
    (`pipelines/pipeline/parasol-claims-devsecops.yaml`, and the app-security-testing /
    trusted-supply-chain entry-state pipelines). Same rule, same argument, but each is a
    lockstep copy pair and re-pinning them is a change that has to be run on a cluster first.
  * `apps/parasol-legacy-claims/devfile.yaml`'s universal-developer-image, which is an IDE base
    image chosen by Dev Spaces, not a supply-chain artifact.

WHAT COUNTS AS PINNED. `repo@sha256:<64 lowercase hex>`, with or without a human-readable tag in
front (`repo:v4.22@sha256:…`). The composite form is preferred and is what three sibling Tasks
already use: the tag is what a reviewer reads, the digest is what the runtime resolves. A tag ALONE
is never a pin, including a specific-looking one — Red Hat rebuilds `v4.22` for CVEs, so today's
v4.22 is not next month's.

Parameter references (`${IMAGE}`, `$(params.IMAGE)`, `{{ .Values.x }}`) are not image references
and are skipped — `roxctl-deployment-check.yaml` embeds a sample Deployment whose image is the
thing under test.

A missing file, or a scope that collapses below its floor, is an ERROR (exit 2), never a silent
pass — a guard that inspects nothing must not report clean.

USAGE
    tools/lint/digest-pin-guard.py              # check the curated library
    tools/lint/digest-pin-guard.py --self-test  # prove it fires; must exit 1
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    Same reasoning as every guard beside this one: module-level code runs before `__main__` exists,
    so a bad constant or a failed import crashes with Python's default rc 1 — exactly what CI's
    "--self-test must exit EXACTLY 1" assertion reads as "the canary fired". `os._exit` is what
    makes the code stick; an excepthook cannot change the status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::digest-pin-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', "
          f"never 'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad
    # NOT `except ImportError`: a _scope.py that fails to PARSE raises SyntaxError, sails past an
    # ImportError-only handler and exits 1 — CI's "the canary fired". Anything going wrong while
    # loading the scope ledger means this guard cannot start, and that is rc 2 whichever exception
    # said so.
    print(f"::error::digest-pin-guard: cannot import _scope ({exc}) — the guard could not start, "
          f"which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    Every pattern compiled at MODULE level raises re.error before main() can run, and Python's rc 1
    for an uncaught exception is exactly what CI's `--self-test must exit EXACTLY 1` accepts as "the
    canary was detected". A regex is the likeliest thing to break in a guard, so the compile step is
    where the exit code has to be fixed.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::digest-pin-guard: {name} is not a valid regex ({exc}) — the guard could "
              f"not load. Exiting 2: that is 'the guard is broken', not 'the canary fired'.",
              file=sys.stderr)
        sys.exit(2)


# tools/lint/<this file> -> tools/lint -> tools -> repo root.
REPO = Path(__file__).resolve().parents[2]

# The curated library, both copies. `kustomization.yaml` is a kustomize index, not a Task.
CANONICAL_DIR = REPO / "pipelines/tasks"
LIBRARY_COPY = REPO / "gitops/workshop-config/templates/parasol-tasks.yaml"

# An `image:` field and its value, stopping at whitespace or an inline comment. Anchored to the
# start of a line (with optional list dash) so `# ose-cli ships oc …` prose in a comment, and the
# word "image" inside a script body, are not mistaken for a field.
IMAGE_FIELD = _compile("IMAGE_FIELD",
                       r"^[ \t]*(?:-[ \t]+)?image:[ \t]*[\"']?([^\s\"'#]+)", re.M)

# A well-formed OCI digest: exactly 64 LOWERCASE hex characters. The length and the case are the
# point — `@sha256:deadbeef` is a typo, not a pin, and a registry rejects it at pull time, which is
# the worst moment to find out.
DIGEST = _compile("DIGEST", r"@sha256:[0-9a-f]{64}$")

# Templating and Tekton parameter references. These are not image references at all: the value is
# substituted at render or run time, so there is nothing here to pin. `roxctl-deployment-check`
# embeds a sample Deployment whose `image: ${IMAGE}` is the artifact under test.
PARAM_REF = _compile("PARAM_REF", r"\$\{|\$\(|\{\{")


def is_parameter(ref: str) -> bool:
    """Is this a substitution placeholder rather than a real image reference?

    Blinding this True empties the judged set (and trips the scope floor); blinding it False makes
    the guard demand a digest on `${IMAGE}`. Both directions are wrong in a visible way, which is
    what makes it a detector rather than decoration.
    """
    return bool(PARAM_REF.search(ref))


def is_digest_pinned(ref: str) -> bool:
    """Does this reference resolve to immutable content?

    A tag — any tag, however specific-looking — is a mutable pointer. Only a digest is content
    addressed, so only a digest answers "what actually ran".
    """
    return bool(DIGEST.search(ref))


def scope_files() -> list[Path]:
    """The curated library's files, canonical copy first.

    A sorted glob rather than a hand-listed constant: a NINTH curated Task must be policed the day
    it lands, not the day someone remembers to add it here. The floor below is what notices when the
    glob stops matching instead.
    """
    tasks = sorted(p for p in CANONICAL_DIR.glob("*.yaml") if p.name != "kustomization.yaml")
    return tasks + [LIBRARY_COPY]


# Floors, measured 2026-08-08 on this tree: 9 files (8 curated Tasks + the republished copy) and 24
# `image:` fields, of which 22 are real references and 2 are `${IMAGE}` placeholders.
#
# LITERALS, deliberately not len(scope_files()): the point is that a glob which stops matching must
# not be able to shrink its own floor. A discovery bug that returns one file collapses the count
# below these and exits 2; editing the real set means bumping these numbers in the same change, and
# the self-test asserts the file floor still equals what discovery actually finds.
MIN_FILES = 9
MIN_IMAGES = 20


def check(files, min_files: int = 1, min_images: int = 1) -> int:
    """Judge every image field in `files`. Returns 0 clean, 1 findings, 2 could-not-inspect."""
    problems, judged, skipped = [], 0, 0
    for path in files:
        if not path.exists():
            print(f"ERROR: {path} is missing — refusing to report clean", file=sys.stderr)
            return 2
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in IMAGE_FIELD.finditer(text):
            ref = m.group(1)
            if is_parameter(ref):
                skipped += 1
                continue
            judged += 1
            line = text.count("\n", 0, m.start()) + 1
            rel = path.relative_to(REPO) if path.is_relative_to(REPO) else path
            if not is_digest_pinned(ref):
                if "@sha256:" in ref:
                    # Has the shape of a pin but is not one: wrong length, uppercase, or truncated.
                    # Kept a separate finding from "no digest at all" because the fix is different —
                    # this one is a corrupted value, not a missing policy — and because a guard that
                    # reported them identically could stop catching either without the other
                    # noticing.
                    problems.append(
                        f"  {rel}:{line}: {ref}\n"
                        f"      malformed digest — a pin is @sha256: followed by exactly 64 "
                        f"lowercase hex characters. This one is not, so it pins nothing and the "
                        f"registry will reject it at pull time.")
                else:
                    problems.append(
                        f"  {rel}:{line}: {ref}\n"
                        f"      floating tag — whatever the registry serves that minute. Pin it: "
                        f"repo:tag@sha256:<64 hex>. Re-resolve the index digest without a pull "
                        f"secret via the public catalog API (see image-size-report.yaml's comment) "
                        f"or, on a cluster, `oc image info --show-multiarch <ref>`.")

    scope = Scope("digest-pin-guard")
    scope.require("library files", min_files,
                  "the 8 curated Tasks in pipelines/tasks plus the workshop layer's republished "
                  "copy. Reading fewer is not a clean result, it is an unread file.")
    scope.require("image fields judged", min_images,
                  "every step image in the curated library. A judged count that collapses means "
                  "the field regex stopped matching, not that the images went away.")
    scope.add("library files", len(files))
    scope.add("image fields judged", judged)
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if problems:
        print(f"digest-pin-guard: {len(problems)} unpinned image(s) in the curated task library "
              f"({judged} judged, {skipped} parameter reference(s) skipped).")
        print("\n".join(problems))
        return 1
    print(f"digest-pin-guard: clean ({len(files)} file(s), {judged} image(s) digest-pinned, "
          f"{skipped} parameter reference(s) skipped).")
    return 0


def self_test() -> int:
    """Prove each finding fires, and — just as important — that a correct pin does NOT."""
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as d:
        good = "a" * 64
        # A correctly pinned image, appended to every SKIP fixture below.
        #
        # WHY THE SKIP FIXTURES ARE NOT SKIP-ONLY. A file whose only image is `${IMAGE}` judges
        # nothing, and `_scope.py` rejects a floor of 0 outright ("asserts nothing") — correctly, so
        # the first draft of this self-test crashed. Dropping the floor for those cases would have
        # been the wrong repair anyway: it removes the assertion instead of satisfying it, and it
        # would have let a blinded is_parameter() that skips EVERYTHING pass the very cases meant to
        # police skipping. Pairing each skip with one real pin keeps the floor honest and catches
        # the blinding in both directions — blinded False judges the placeholder and reports a
        # finding (rc 1), blinded True skips the pin too and collapses the scope (rc 2). Either way
        # the expected rc 0 does not survive.
        pinned = f"    image: registry.example.com/anchor@sha256:{good}\n"
        # (filename, contents, expected rc, what a wrong result would mean)
        cases = [
            # ── The negative canaries. A guard that flags everything distinguishes nothing, so
            # these come first: every accepted form must stay accepted.
            ("pinned-bare.yaml", f"    image: registry.example.com/tool@sha256:{good}\n", 0,
             "a bare digest pin — the plainest correct form — was flagged"),
            ("pinned-composite.yaml",
             f"    image: registry.example.com/tool:v4.22@sha256:{good}\n", 0,
             "the tag@sha256 composite form was flagged. That is the form this library prefers "
             "and the form three sibling Tasks already use, so rejecting it would have made the "
             "guard unpassable by its own house style"),
            ("pinned-listitem.yaml", f"      - image: registry.example.com/t@sha256:{good}\n", 0,
             "a list-item image field (`- image:`) was flagged — the field regex would be missing "
             "every container in a plain pod spec"),
            ("param-brace.yaml", pinned + "    image: ${IMAGE}\n", 0,
             "a ${IMAGE} parameter placeholder was judged instead of skipped. "
             "roxctl-deployment-check embeds one as the artifact under test; demanding a digest "
             "there is unsatisfiable"),
            ("param-tekton.yaml", pinned + "    image: $(params.BUILT_IMAGE)\n", 0,
             "a Tekton $(params.…) reference was judged instead of skipped"),
            ("param-helm.yaml", pinned + "    image: {{ .Values.image }}\n", 0,
             "a Helm template reference was judged instead of skipped"),
            ("comment-only.yaml",
             pinned + "    # image: registry.example.com/tool:latest is fine in prose\n", 0,
             "prose in a comment was read as an image field — the guard would fail on its own "
             "explanatory comments"),

            # ── The positive canaries, one per emit site.
            ("floating-latest.yaml", "    image: registry.example.com/tool:latest\n", 1,
             "an explicit :latest did not trip the guard — the exact defect this file exists for"),
            ("floating-version.yaml", "    image: registry.example.com/tool:v4.22\n", 1,
             "a specific-LOOKING version tag did not trip the guard. Red Hat rebuilds a stream for "
             "CVEs, so v4.22 is a mutable pointer and treating it as a pin is the whole error"),
            ("floating-notag.yaml", "    image: registry.example.com/tool\n", 1,
             "an image with no tag at all did not trip the guard — it resolves to :latest "
             "implicitly, which is the same defect wearing no clothes"),
            ("malformed-short.yaml", "    image: registry.example.com/tool@sha256:deadbeef\n", 1,
             "a truncated digest did not trip the guard. It has the SHAPE of a pin, so it would "
             "pass any '@sha256: appears in the string' check while pinning nothing"),
            ("malformed-upper.yaml",
             f"    image: registry.example.com/tool@sha256:{'A' * 64}\n", 1,
             "an uppercase digest did not trip the guard — 64 characters of the right length but "
             "not a value any registry will resolve"),
        ]
        for name, text, expected, complaint in cases:
            probe = Path(d) / name
            probe.write_text(text)
            if check([probe]) != expected:
                print(f"SELF-TEST FAILED: {complaint}", file=sys.stderr)
                ok = False

        # A file that is GONE must be rc 2, not a clean zero-image pass. A renamed or moved Task is
        # how a curated artifact quietly stops being policed, and "I read nothing" must never be
        # spelled the same way as "I read everything and it was fine".
        if check([Path(d) / "no-such-file.yaml"]) != 2:
            print("SELF-TEST FAILED: a missing file did not exit 2. A renamed Task would then read "
                  "as a library with no unpinned images.", file=sys.stderr)
            ok = False

        # The scope floors, exercised the way they actually fail: a discovery bug that finds ONE
        # file, and a field regex that judges nothing. Both are rc 2. Until this existed, blinding
        # IMAGE_FIELD left the real tree at "clean (0 images)" and exit 0.
        one = Path(d) / "pinned-bare.yaml"
        if check([one], min_files=MIN_FILES) != 2:
            print("SELF-TEST FAILED: a collapsed FILE set did not exit 2 — a broken glob would "
                  "report clean over a library it never opened.", file=sys.stderr)
            ok = False
        empty = Path(d) / "no-images.yaml"
        empty.write_text("kind: Task\nmetadata:\n  name: nothing-here\n")
        if check([empty], min_images=MIN_IMAGES) != 2:
            print("SELF-TEST FAILED: judging ZERO image fields did not exit 2 — a field regex that "
                  "stopped matching would report clean.", file=sys.stderr)
            ok = False

    # The declared file floor must still equal what discovery actually finds. MIN_FILES is a literal
    # so a broken glob cannot shrink its own floor; this is what notices when the two diverge —
    # including the good case, a ninth curated Task landing without the floor being restated.
    found = len(scope_files())
    if MIN_FILES != found:
        print(f"SELF-TEST FAILED: MIN_FILES is {MIN_FILES} but discovery finds {found} file(s). "
              f"A curated Task was added or removed without re-stating the floor, so the floor has "
              f"stopped asserting the real set.", file=sys.stderr)
        ok = False
    for failure in Scope.self_check():
        print(f"SELF-TEST FAILED: {failure}", file=sys.stderr)
        ok = False

    if not ok:
        return 2
    print("self-test ok — floating tags (:latest, a version tag, and no tag at all) fail; "
          "malformed digests fail; bare and composite digest pins pass, as do parameter "
          "placeholders and prose in comments; a missing file and a collapsed file or image scope "
          "are refusals, not clean runs; the file floor matches discovery.")
    return 1


def main(argv=None) -> int:
    # argparse, not `"--self-test" in sys.argv`: the membership test ignores every other argument,
    # so `--selftest` (one hyphen short) would run the plain check and print a clean result, and a
    # maintainer proving a detector fires would have proved nothing. argparse names the offending
    # argument and exits 2.
    #
    # `argv` is POSITIONAL and defaults to None on purpose. tools/lint/_canary-coverage.py proves
    # each detector is falsifiable by importing this module and calling `mod.main(argv)` with a
    # list; a bare `def main()` raises TypeError there and the guard is reported COULD NOT INSPECT,
    # which ships it unproven. Every Python guard beside this one carries the same signature.
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="run the canaries instead of the real tree; exits 1 when every canary was "
                         "correctly caught, which is the PASS for this mode")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    return check(scope_files(), MIN_FILES, MIN_IMAGES)


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::digest-pin-guard: crashed ({type(exc).__name__}: {exc}). Exiting 2 — a "
              f"crash is 'the guard could not run', never 'clean' and never 'canary detected'.",
              file=sys.stderr)
        sys.exit(2)
