#!/usr/bin/env python3
"""digest-pin-guard.py — no floating image tags in the curated task library, and no floating
ENTITLED-registry tag anywhere in the GitOps install path.

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

SCOPE — THREE TIERS, EACH ONE THE TREE PASSES TODAY.

Tier 1, the curated Parasol task library, EVERY image whatever its registry:

    pipelines/tasks/*.yaml                              the 8 canonical curated Tasks
    gitops/workshop-config/templates/parasol-tasks.yaml the same 8, republished by the workshop layer

That library is a platform team's published contract — `taskRef`'d by cluster resolver from every
app pipeline, read by attendees as the exemplar, and the thing the supply-chain module points at.
Its blast radius is every pipeline on the cluster, not one namespace being bootstrapped. Measured on
the canonical copy at the commit before this guard landed: 12 `image:` fields, 1 of them a `${IMAGE}`
parameter, and TEN of the 11 real step images were already pinned. Pinning `image-size-report` made
the convention unanimous rather than imposing a new one. Across both copies: 9 files, 24 fields, 22
judged.

Tier 2, added 2026-08-08 once the sweep below made it passable: every ENTITLED-REGISTRY image
reference in the install path —

    gitops/**  platform-portfolio/**  helm/**  pipelines/**   (664 YAML files)

— must be digest-pinned. "Entitled registry" means `registry.redhat.io/**`, the one that needs a
pull secret and the one where this whole finding started. Measured after the sweep: 53 references
judged, 2 exempt, 0 unpinned.

Tier 3, added 2026-08-12: every ENTITLED-REGISTRY image reference that an attendee RUNS, inside
`content/**` —

    content/**/*.adoc, but ONLY inside a `[source,…,role=execute]` listing block   (141 files,
                                                                                    1108 blocks)

— must be digest-pinned. Measured today: 36 image references inside those blocks, of which 5 are
entitled and judged, 30 exempt (16 UBI, 13 in-cluster, 1 `image: auto`) and 1 a Helm placeholder.
0 unpinned. See "TIER 3 AND THE CARVE-OUT IT REPLACES" below for why this is a live-command tier and
not a `content/**` sweep.

WHY TIER 2 EXISTS NOW AND DID NOT THIS MORNING. The first version of this guard was deliberately
tier 1 only, because a `git grep` for floating `image:` tags returned 55 hits outside this
directory's fixtures and 44 of them were `registry.redhat.io/openshift4/ose-cli:latest` in one-shot
hook Jobs. A gate that opens on 44 pre-existing findings gets switched off inside a day and takes
the findings that matter with it. Those 44 have since been swept — surveyed by kind, checked for the
≥512Mi and no-runtime-dnf constraints, proved on a live cluster, and repinned onto
`ose-cli-rhel9:v4.22@sha256:…`. The scope note that said "worth fixing; needs its own sweep and a
cluster smoke" got its sweep, so the rule it was waiting on is now a rule the tree passes.

Tier 2 reads ANY YAML field whose value is an entitled reference, not just `image:`. Measured field
names carrying one: `image`, `cli` (helm/bootstrap/values.yaml's `images.cli`, the single value that
feeds ten bootstrap Jobs) and `udiImage`. A guard that only understood `image:` would have left the
most leveraged reference in the tree unpoliced.

DELIBERATELY OUT OF SCOPE, so nobody reads a green tick as more than it is:
  * `registry.access.redhat.com` UBI base images. SIX floating tags remain in the install path
    (`ubi9-minimal:latest` ×3, `ubi9/ubi-minimal:latest` ×3 in jobs-batch-kueue's solve endstate,
    `ubi9/openjdk-21:latest` ×1). Same rule, same argument, and the next sweep — but UBI `:latest`
    is ACTIVELY rebuilt, which is the opposite of the failure that motivated this file, so it is a
    lower-grade risk and not worth blocking tier 2 on.
  * in-cluster registry references (`image-registry.openshift-image-registry.svc:5000/...`, 3 of
    them). Those resolve through ImageStreamTags the cluster owns — two are OpenShift's own
    `openshift/tools` and `openshift/cli`, one is the workshop's own build output. A digest there
    would pin away the thing the imagestream exists to do.
  * Dev Spaces UDI images (`registry.redhat.io/devspaces/**`, 2 of them: an `udiImage` value and a
    devfile). Entitled, but the IDE base image is chosen by the Dev Spaces operator and version-
    tagged to the product release; the workshop pins the Dev Spaces VERSION via versions.yaml. Same
    reasoning the sibling `apps/parasol-legacy-claims/devfile.yaml` was carved out under.
  * everything in `content/**` that is NOT inside a `role=execute` block. That is the whole of
    tier 3's design and it has its own section, next.

TIER 3 AND THE CARVE-OUT IT REPLACES.

The old note here said `content/**` was out of scope entirely, and named observability-health-scale's
hand-typed `claims-burst` as "a real finding awaiting its module owner". It waited 32 days. The sweep
that repinned 44 sibling `ose-cli:latest` references walked straight past it, because the sweep read
manifests and this one was a command an attendee TYPES; the module's own troubleshooting page already
documented the symptom (ErrImagePull, and the HPA never moves). It was fixed in 78e71b0.

The obvious response — "police `content/**` too" — is wrong as stated, and the reason is the whole
design of this tier. Content legitimately contains image references a linter must not touch, and
78e71b0 ships one of each kind as a ready-made fixture:

  1. A live command block the attendee actually runs: `[source,sh,role=execute]` around
     `oc run … --image=…`. THIS is what tier 3 polices, and nothing else.
  2. Captured output from a real run. House rule: captured output stays exactly as captured.
     `packaging-distributing/lab.adoc` carries a floating `redhat-operator-index:v4.22` inside a
     `.Expected output` / `[source,texinfo]` block, under a grounding comment that says in as many
     words not to re-template it; `pipelines-fundamentals/lab.adoc` carries an ELIDED
     `ubi9/openjdk-17@sha256:...`, which a naive check reports as a MALFORMED digest — the worse of
     this file's two findings, raised against a line nobody may edit.
  3. A dated `//` provenance comment recording what a command looked like on the day it was
     measured (`observability-health-scale/lab.adoc`, the 2026-07-31 as-run record that still names
     `ose-cli:latest` on purpose), plus prose that names an old tag precisely in order to warn about
     it. "Fixing" either would make it claim a run that never happened.

A naive sweep fails 2 and 3 and pushes an author toward doctoring a captured record to appease a
linter, which is worse than the gap it closes. So tier 3 keys on ASCIIDOC STRUCTURE, never on the
image name: a reference is judged only when it sits inside a listing block whose opener carries
`role=execute` — the same block the cockpit's click-to-run button sends to the attendee's terminal.
Prose, `//` line comments, `////` comment blocks, `[source,yaml]` display manifests and
`[source,texinfo]` captured output all open no such block and are therefore never read at all.

WHY THIS IS WORTH A TIER, measured rather than asserted. Replaying this detector over the content
tree's own history (`git ls-tree` at each revision, no working-tree mutation):

    2026-07-11 → 2026-07-18   m08's instructor page, TWO sites: `--image=…/rhtas/client-server`
                              and the same ref inside an `--overrides='{…"image":"…"}'` JSON body.
                              No tag at all, so an implicit `:latest`. They left the tree when the
                              module was rebalanced for unrelated reasons — nobody ever noticed the
                              pin.
    2026-07-11 → 2026-08-12   m12's `claims-burst`, TWO sites, 32 days, through the 44-site sweep
                              and through two later commits that edited that very file.
    today                     0.

So the rule this tier enforces would have been RED for essentially the whole authoring life of the
content tree, on defects that were real, and GREEN today. That is the evidence that decided it; a
count of today's sites alone (5, all pinned) would have argued the other way.

WHAT TIER 3 DELIBERATELY DOES NOT DO:
  * It does not widen the registry rule. Only `registry.redhat.io/**` is judged, exactly as tier 2,
    so UBI (16 sites in execute blocks, deliberately floating teaching material — `jobs-batch-kueue`
    applies bare `ubi-minimal:latest` Jobs and that is the point), in-cluster ImageStreamTags (13)
    and `docker.io` (the registry-governance module's subject matter) stay exempt. Widening would
    open the gate on ~30 pre-existing findings, which is the failure tier 2 was sequenced to avoid.
  * It does not read arbitrary `field: registry.redhat.io/…` YAML the way tier 2 does. In content
    that over-fires: `registry-images-catalog-governance/instructor.adoc` puts an
    ImageDigestMirrorSet in a `role=execute` heredoc whose `- source: registry.redhat.io/ubi9` is a
    mirror-selector PREFIX, not a pullable image — digest-pinning it would break the mirror rule it
    teaches. Tier 3 therefore recognizes only the three constructs that actually name a pull target,
    and all three have real instances in this tree's history: `--image=`, a YAML `image:` field, and
    a JSON `"image":` field.
  * It does not exempt `#` shell comments inside an execute block. Click-to-run sends the whole
    block, and a commented-out `oc run --image=…` is an example an attendee may uncomment; there are
    zero such lines today, so no verdict rests on this either way.

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
    tools/lint/digest-pin-guard.py              # check both tiers; rc 2 outranks 1 outranks 0
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

# TIER 2's field regex. ANY YAML scalar field whose value is an entitled reference — not just
# `image:`. Measured on this tree, three field names carry one: `image`, `udiImage`, and `cli`
# (helm/bootstrap/values.yaml's `images.cli`, the single value ten bootstrap Jobs read). Anchored to
# the start of a line so a comment — including this file's own prose, and the `# Digest-pinned; el8
# ose-cli:latest was …` note the sweep left at 44 sites — is never read as a field.
ENTITLED_FIELD = _compile(
    "ENTITLED_FIELD",
    r"^[ \t]*(?:-[ \t]+)?[A-Za-z][A-Za-z0-9_.-]*:[ \t]*[\"']?(registry\.redhat\.io/[^\s\"'#]+)",
    re.M)

# Dev Spaces IDE base images. Entitled, but chosen by the Dev Spaces operator and version-tagged to
# the product release rather than pinned by this repo — the same carve-out the sibling
# apps/parasol-legacy-claims/devfile.yaml has. See the docstring's out-of-scope list.
DEVSPACES_UDI = _compile("DEVSPACES_UDI", r"^registry\.redhat\.io/devspaces/")

# ── TIER 3's structure patterns. These decide WHERE a reference is, which is the only thing that
# separates a command an attendee runs from a record of one. Deliberately the same shapes
# click-to-run-guard.py uses, so the two guards agree on what an execute block is: both count 1108
# blocks across 141 files on this tree, which is the cross-check that says this walk is right.

# The block-opener line. Accepts `role=execute` bare and the quoted multi-word form
# (`role="execute send-to-tty-bottom"`) that click-to-run.js also understands — zero of the latter
# in content today, but a tier that silently stopped reading them would be invisible.
EXEC_OPENER = _compile("EXEC_OPENER",
                       r'^\[source\b[^\]]*\brole\s*=\s*(?:"(?P<qval>[^"]*)"|(?P<uval>[^,"\]]+))')

# A listing delimiter: 2+ repeats of `-`, the only delimiter this repo's [source] blocks use.
LISTING_DELIM = _compile("LISTING_DELIM", r"^-{2,}\s*$")

# An AsciiDoc comment BLOCK fence. Everything between a matched pair is commented out of the
# rendered page, so an execute block inside one is not a command anyone can run. Zero in content
# today; handled anyway, because the alternative is a tier that fires on text no attendee can see.
COMMENT_FENCE = _compile("COMMENT_FENCE", r"^/{4,}\s*$")

# ── TIER 3's three image-bearing constructs. NOT "any field whose value is entitled" (tier 2's
# rule): in content that reads an ImageDigestMirrorSet's `- source:` prefix as an image. Each of
# these three has a real instance in this tree's history — see the docstring's replay.

# `--image=<ref>` / `--image <ref>`, the shape m12's claims-burst and m08's cosign client both used.
# `--image-pull-policy=…` does not match: `-` is not in the `[= ]` that must follow.
IMAGE_FLAG = _compile("IMAGE_FLAG", r"--image[= ]\s*([^\s\\\"']+)")

# `"image": "<ref>"`, the shape inside `oc run --overrides='{"spec":{"containers":[{…}]}}'`. m08
# carried its unpinned reference twice on consecutive lines — once as a flag, once in this JSON —
# and a guard that read only the flag would have called that line clean.
IMAGE_JSON_FIELD = _compile("IMAGE_JSON_FIELD", r'"image"[ \t]*:[ \t]*"([^"]+)"')


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


def is_entitled_scope(ref: str) -> bool:
    """Is this a reference TIER 2 is responsible for?

    True for `registry.redhat.io/**` — the entitled registry, the one that needs a pull secret and
    the one `ose-cli:latest` rotted on — except Dev Spaces UDI images, which the Dev Spaces operator
    version-tags for itself.

    Blinding this True drags the UBI base images and the Dev Spaces UDIs into scope and reports
    their floating tags (rc 1); blinding it False empties tier 2 and collapses its scope floor
    (rc 2). Both directions move an exit code, which is what makes it a detector and not a comment.
    """
    return bool(ref.startswith("registry.redhat.io/") and not DEVSPACES_UDI.search(ref))


def is_execute_block_opener(line: str) -> bool:
    """Does this line open a listing block the attendee's click-to-run button will SEND?

    This is the whole of tier 3's kind-1/kind-2/kind-3 distinction, and the reason it is a
    predicate rather than an inline regex test is that it has to be blindable in both directions:

      blinded False — no block ever opens, tier 3 judges nothing, and its execute-block floor
                      collapses to zero (rc 2). Silence would otherwise look exactly like a clean
                      content tree.
      blinded True  — EVERY line opens a block, so a `[source,texinfo]` opener followed by `----`
                      turns captured output into a live command and the guard reports the frozen
                      `redhat-operator-index:v4.22` in packaging-distributing's `.Expected output`
                      (rc 1). That is the over-fire this tier exists to avoid, and it is worth as
                      much of a canary as the under-fire.

    `role` is split on whitespace rather than substring-matched so `role=executed-elsewhere` — or
    any future role whose name merely contains the word — does not read as executable.
    """
    m = EXEC_OPENER.match(line.strip())
    if not m:
        return False
    val = m.group("qval") if m.group("qval") is not None else m.group("uval")
    return "execute" in val.split()


def iter_execute_blocks(lines: list[str]):
    """Yield (line_no, text) for every line inside a role=execute listing block.

    The opener must be followed IMMEDIATELY by the delimiter — measured on this tree, all 1108
    execute blocks are that shape and none is missed by requiring it, so the rule is the tree's
    own, not a simplification of it.

    Lines between a matched pair of `////` fences are skipped before any of this: they are
    commented out of the rendered page, so an execute block in there is not a command anyone can
    run, and firing on one would be firing on text no attendee can see.
    """
    # ONE append, not one per branch. A second `live.append(None)` for the fence line itself was
    # the obvious way to write this and it is unprovable: blinding it only shifts the reported line
    # numbers, so no exit code moves and `_canary-coverage` correctly reports a detector that can
    # stop working in silence. With a single append, blinding it empties `live`, which finds zero
    # execute blocks and collapses the block floor — a refusal, in both modes.
    live = []
    fenced = False
    for line in lines:
        fence = bool(COMMENT_FENCE.match(line))
        live.append(None if (fenced or fence) else line)   # None keeps line numbers aligned
        if fence:
            fenced = not fenced

    i, n = 0, len(live)
    while i < n:
        line = live[i]
        if line is not None and is_execute_block_opener(line):
            j = i + 1
            if j < n and live[j] is not None and LISTING_DELIM.match(live[j]):
                delim = live[j].rstrip()
                k = j + 1
                body = []
                while k < n and not (live[k] is not None and live[k].rstrip() == delim):
                    if live[k] is not None:
                        body.append((k + 1, live[k]))
                    k += 1
                yield body
                i = k          # resume after the closing delimiter (or EOF if unterminated)
        i += 1


def scope_files() -> list[Path]:
    """The curated library's files, canonical copy first.

    A sorted glob rather than a hand-listed constant: a NINTH curated Task must be policed the day
    it lands, not the day someone remembers to add it here. The floor below is what notices when the
    glob stops matching instead.
    """
    tasks = sorted(p for p in CANONICAL_DIR.glob("*.yaml") if p.name != "kustomization.yaml")
    return tasks + [LIBRARY_COPY]


# TIER 2's roots: the GitOps install path. Everything an `oc`-bearing hook Job, a portfolio
# component or a bootstrap chart can pull during a cluster build.
INSTALL_ROOTS = ("gitops", "platform-portfolio", "helm", "pipelines")


def install_path_files() -> list[Path]:
    """Every YAML file under the install path, sorted.

    A glob rather than a list for the same reason as scope_files(): a new entry-state chart is
    policed the day it lands. The floor below is what notices when the glob stops matching.
    """
    found = set()
    for root in INSTALL_ROOTS:
        for ext in ("yaml", "yml"):
            found.update((REPO / root).glob(f"**/*.{ext}"))
    return sorted(found)


# Floors, measured 2026-08-08 after the ose-cli sweep: 664 install-path YAML files carrying 53
# entitled references (plus 2 Dev Spaces UDIs, exempt). Set well below today's numbers so ordinary
# growth and small deletions do not redden main, and far above what any plausible truncation
# produces — one root's worth, or the `[:1]` that _scope.py exists to catch.
MIN_INSTALL_FILES = 400
MIN_INSTALL_IMAGES = 40

# Tier 2's label, used for its scope-ledger dimension names and its verdict line. A constant so
# the self-test's probes report under the SAME tier as the real run — a canary that prints "curated
# task library" while exercising the install path is a log that lies about what it proved.
T2 = "entitled references in the install path"

# TIER 3's root and label. `content` rglob'd for `*.adoc`, which is exactly what
# click-to-run-guard.py scans — the two guards must see the same 141 files, or one of them is
# reading a set the other is not.
CONTENT_ROOT = REPO / "content"
T3 = "entitled references in attendee-run command blocks"


def content_files() -> list[Path]:
    """Every AsciiDoc page under content/, sorted. A glob for the same reason as its two siblings:
    a module that lands tomorrow is policed tomorrow, and the floor below is what notices when the
    glob stops matching instead."""
    return sorted(CONTENT_ROOT.rglob("*.adoc"))


# Floors, measured 2026-08-12 on this tree: 141 `.adoc` files carrying 1108 role=execute blocks, in
# which 36 image references appear (5 entitled and judged, 30 exempt, 1 a `{{ .Values… }}`
# placeholder). Set well below today's numbers, and far above what any plausible truncation gives.
#
# The third floor counts references BEFORE the entitled filter on purpose. Judged-only would be a
# floor of 5 on a number that legitimately moves whenever a module is rewritten — it would redden
# main for an editorial act. The candidate count is the structural quantity: labs will always run
# containers, so a collapse there means IMAGE_FLAG / IMAGE_FIELD / IMAGE_JSON_FIELD stopped
# matching, not that the workshop stopped using images. The entitled predicate collapsing is caught
# by tier 2's `all_exempt` canary, which exercises the same shared `is_entitled_scope`.
MIN_CONTENT_FILES = 100
MIN_CONTENT_BLOCKS = 800
MIN_CONTENT_REFS = 20


# Floors, measured 2026-08-08 on this tree: 9 files (8 curated Tasks + the republished copy) and 24
# `image:` fields, of which 22 are real references and 2 are `${IMAGE}` placeholders.
#
# LITERALS, deliberately not len(scope_files()): the point is that a glob which stops matching must
# not be able to shrink its own floor. A discovery bug that returns one file collapses the count
# below these and exits 2; editing the real set means bumping these numbers in the same change, and
# the self-test asserts the file floor still equals what discovery actually finds.
MIN_FILES = 9
MIN_IMAGES = 20


def check(files, min_files: int = 1, min_images: int = 1,
          field=None, only=None, tier: str = "curated task library") -> int:
    """Judge the image fields in `files`. Returns 0 clean, 1 findings, 2 could-not-inspect.

    `field` is the field regex (tier 1's `image:`-only IMAGE_FIELD by default, tier 2's
    ENTITLED_FIELD for the install path) and `only` an optional responsibility predicate: a ref it
    rejects is EXEMPT — counted, reported, and never judged. Both are parameters rather than two
    copies of this loop because every emit site below, and the scope ledger under it, has to be the
    same code in both tiers; a second implementation is a second thing to blind.
    """
    field = IMAGE_FIELD if field is None else field
    problems, judged, skipped, exempt = [], 0, 0, 0
    for path in files:
        if not path.exists():
            print(f"ERROR: {path} is missing — refusing to report clean", file=sys.stderr)
            return 2
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in field.finditer(text):
            ref = m.group(1)
            if is_parameter(ref):
                skipped += 1
                continue
            if only is not None and not only(ref):
                exempt += 1
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
    scope.require(f"{tier} files", min_files,
                  "tier 1 is the 8 curated Tasks in pipelines/tasks plus the workshop layer's "
                  "republished copy; tier 2 is every YAML file under the install path. Reading "
                  "fewer is not a clean result, it is an unread file.")
    scope.require(f"{tier} image fields judged", min_images,
                  "every step image in the curated library (tier 1) / every entitled reference in "
                  "the install path (tier 2). A judged count that collapses means the field regex "
                  "or the responsibility predicate stopped matching, not that the images went "
                  "away.")
    scope.add(f"{tier} files", len(files))
    scope.add(f"{tier} image fields judged", judged)
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    tail = (f"{skipped} parameter reference(s) skipped"
            + (f", {exempt} out-of-scope reference(s) exempt" if only is not None else ""))
    if problems:
        print(f"digest-pin-guard: {len(problems)} unpinned image(s) in the {tier} "
              f"({judged} judged, {tail}).")
        print("\n".join(problems))
        return 1
    print(f"digest-pin-guard: clean — {tier}: {len(files)} file(s), {judged} image(s) "
          f"digest-pinned, {tail}.")
    return 0


def refs_in_command(text: str) -> list[str]:
    """Every pull target named on one line of a command block, in the three constructs tier 3
    recognizes. Order is stable so a line carrying two (m08's flag + `--overrides` JSON) reports
    both, in the order a reader's eye takes them.

    The YAML field reuses tier 1's IMAGE_FIELD rather than declaring a near-identical twin: it is
    the same construct, and a second copy is a second thing that can be blinded without the first
    noticing.
    """
    found = []
    m = IMAGE_FLAG.search(text)
    if m:
        found.append(m.group(1))
    m = IMAGE_FIELD.search(text)
    if m:
        found.append(m.group(1))
    found.extend(m.group(1) for m in IMAGE_JSON_FIELD.finditer(text))
    return found


def check_content(files, min_files: int = 1, min_blocks: int = 1, min_refs: int = 1) -> int:
    """TIER 3. Judge entitled image references inside role=execute blocks. 0/1/2 as everywhere.

    This is NOT a `check()` call with different parameters, and the difference is the point.
    `check()` runs a field regex over a whole FILE, which is the right shape for YAML and the wrong
    shape here: in content, WHERE a reference sits is what decides whether it is a command or a
    record of one, and a file-wide regex cannot see that. What the two share is the judgment —
    `is_parameter`, `is_entitled_scope`, `is_digest_pinned` — so blinding any of those still moves
    all three tiers, which is the property the anti-duplication rule in `check()` exists to protect.
    """
    problems, blocks, refs, judged, skipped, exempt = [], 0, 0, 0, 0, 0
    for path in files:
        if not path.exists():
            print(f"ERROR: {path} is missing — refusing to report clean", file=sys.stderr)
            return 2
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        rel = path.relative_to(REPO) if path.is_relative_to(REPO) else path
        for body in iter_execute_blocks(lines):
            blocks += 1
            for line_no, text in body:
                for ref in refs_in_command(text):
                    refs += 1
                    if is_parameter(ref):
                        skipped += 1
                        continue
                    if not is_entitled_scope(ref):
                        exempt += 1
                        continue
                    judged += 1
                    if is_digest_pinned(ref):
                        continue
                    if "@sha256:" in ref:
                        problems.append(
                            f"  {rel}:{line_no}: {ref}\n"
                            f"      malformed digest in a block the attendee RUNS — a pin is "
                            f"@sha256: followed by exactly 64 lowercase hex characters. This one "
                            f"is not, so the pull fails in front of the room. If you meant to "
                            f"ELIDE a digest for readability, that belongs in captured output or "
                            f"prose, never in a role=execute block.")
                    else:
                        problems.append(
                            f"  {rel}:{line_no}: {ref}\n"
                            f"      floating tag in a block the attendee RUNS — whatever the "
                            f"registry serves that minute. This is the m12 `claims-burst` defect: "
                            f"the el8 `ose-cli` repository froze `:latest` on v4.15.0 and the lab "
                            f"died with ErrImagePull. Pin it: repo:tag@sha256:<64 hex>, and prefer "
                            f"the reference the module's own entry state already runs so the two "
                            f"cannot drift.")

    scope = Scope("digest-pin-guard")
    scope.require(f"{T3} files", min_files,
                  "every .adoc page under content/. Reading fewer is not a clean result, it is an "
                  "unread page — and the count must match click-to-run-guard's, which walks the "
                  "same set.")
    scope.require(f"{T3} execute blocks", min_blocks,
                  "every [source,…,role=execute] block. A collapse here means the opener or the "
                  "delimiter stopped matching, so tier 3 read no commands at all — which prints "
                  "identically to a content tree with nothing wrong in it.")
    scope.require(f"{T3} image references", min_refs,
                  "every image reference inside those blocks, BEFORE the entitled filter. Labs run "
                  "containers; a collapse means a construct regex stopped matching, not that the "
                  "workshop stopped using images.")
    scope.add(f"{T3} files", len(files))
    scope.add(f"{T3} execute blocks", blocks)
    scope.add(f"{T3} image references", refs)
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    tail = (f"{blocks} execute block(s), {refs} image reference(s) in them, {skipped} parameter "
            f"reference(s) skipped, {exempt} out-of-scope reference(s) exempt")
    if problems:
        print(f"digest-pin-guard: {len(problems)} unpinned image(s) in the {T3} "
              f"({judged} judged, {tail}).")
        print("\n".join(problems))
        return 1
    print(f"digest-pin-guard: clean — {T3}: {len(files)} file(s), {judged} image(s) "
          f"digest-pinned, {tail}.")
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

        # ── TIER 2's own canaries, run through check() with the tier-2 field regex and
        # responsibility predicate, exactly as main() calls it. Each non-entitled case is paired
        # with a pinned ENTITLED anchor for the reason spelled out above: a probe that judges
        # nothing collapses the scope floor and would report rc 2 for the wrong reason, which is
        # indistinguishable from the exemption working.
        anchor = f"    image: registry.redhat.io/anchor/tool@sha256:{good}\n"
        tier2_cases = [
            # Negative canaries — the forms tier 2 must NOT fire on.
            ("t2-entitled-pinned.yaml", anchor, 0,
             "a correctly pinned entitled reference was flagged by tier 2"),
            ("t2-nonimage-field.yaml",
             f'  cli: "registry.redhat.io/openshift4/ose-cli-rhel9:v4.22@sha256:{good}"\n', 0,
             "helm/bootstrap/values.yaml's `images.cli` shape was not read as a field, or was "
             "flagged while pinned. That single value feeds ten bootstrap Jobs — an `image:`-only "
             "regex leaves the most leveraged reference in the tree unpoliced"),
            ("t2-unentitled-floating.yaml",
             anchor + "    image: registry.access.redhat.com/ubi9/ubi-minimal:latest\n", 0,
             "tier 2 fired on a registry.access.redhat.com UBI tag. Those SIX floating tags are "
             "documented out of scope; firing on them is the 'gate opens on pre-existing findings' "
             "failure this tier was sequenced to avoid"),
            ("t2-incluster-floating.yaml",
             anchor + "    image: image-registry.openshift-image-registry.svc:5000/openshift/"
                      "tools:latest\n", 0,
             "tier 2 fired on an in-cluster ImageStreamTag reference — a digest there pins away "
             "the thing the imagestream exists to do"),
            ("t2-devspaces-udi.yaml",
             anchor + "    image: registry.redhat.io/devspaces/udi-rhel9:3.29\n", 0,
             "the Dev Spaces UDI exemption did not hold. It is entitled and unpinned by design; "
             "the Dev Spaces operator version-tags it and versions.yaml pins the product"),

            # Positive canary — the defect this tier exists for.
            ("t2-entitled-floating.yaml",
             "    image: registry.redhat.io/openshift4/ose-cli:latest\n", 1,
             "the exact string this whole sweep removed — an entitled floating tag in the install "
             "path — did not trip tier 2. That is the regression this tier exists to prevent"),
        ]
        for name, text, expected, complaint in tier2_cases:
            probe = Path(d) / name
            probe.write_text(text)
            if check([probe], field=ENTITLED_FIELD, only=is_entitled_scope,
                     tier=T2) != expected:
                print(f"SELF-TEST FAILED: {complaint}", file=sys.stderr)
                ok = False

        # ── TIER 3's canaries. Every fixture below is copied in SHAPE from a real page, named in
        # its complaint, because this tier's whole claim is that it can tell a command from a
        # record of one — and the records it must leave alone are real lines someone would have to
        # doctor if it got this wrong.
        #
        # Each negative fixture carries a pinned entitled ANCHOR inside its own execute block, for
        # the same reason tier 2's do: a probe that judges nothing would collapse a floor and
        # report rc 2, which is indistinguishable from the exemption working.
        pinned_ref = f"registry.redhat.io/openshift4/ose-cli-rhel9:v4.22@sha256:{good}"
        floating_ref = "registry.redhat.io/openshift4/ose-cli:latest"
        anchor_block = ("[source,sh,role=execute]\n"
                        "----\n"
                        f"oc run anchor --image={pinned_ref} --restart=Never\n"
                        "----\n")
        adoc_cases = [
            # ── KIND 2, captured output. The house rule is that captured output stays exactly as
            # captured, so every one of these must be silent.
            ("kind2-expected-output.adoc",
             anchor_block +
             ".Expected output (the catalog index image)\n"
             "[source,texinfo]\n"
             "----\n"
             "catalog: Red Hat Operators  image: "
             "registry.redhat.io/redhat/redhat-operator-index:v4.22\n"
             "----\n", 0,
             "a FLOATING tag inside `.Expected output` / [source,texinfo] was flagged. That is "
             "packaging-distributing/lab.adoc's real captured line, sitting under a grounding "
             "comment that says in as many words not to re-template it — flagging it asks an "
             "author to doctor a record of a run that happened"),
            ("kind2-elided-digest.adoc",
             anchor_block +
             ".Expected output (parameter names vary by Pipelines version)\n"
             "[source,texinfo]\n"
             "----\n"
             "  registry.redhat.io/ubi9/openjdk-17@sha256:...\n"
             "----\n", 0,
             "an ELIDED digest in captured output was flagged. That is "
             "pipelines-fundamentals/lab.adoc:603, and the finding it would raise is the MALFORMED "
             "one — the worse of this file's two, against a line nobody may edit"),
            ("kind2-plain-listing.adoc",
             anchor_block +
             "----\n"
             f"    image: {floating_ref}\n"
             "----\n", 0,
             "a floating tag in an UNLABELLED `----` listing was flagged. A listing with no "
             "[source] attribute line at all is display material, and the click-to-run button "
             "never appears on it"),
            ("kind2-source-yaml-display.adoc",
             anchor_block +
             "[source,yaml]\n"
             "----\n"
             f"            - name: start-nightly-build\n"
             f"              image: {floating_ref}\n"
             "----\n", 0,
             "a floating tag in a [source,yaml] DISPLAY manifest was flagged. That is the exact "
             "shape m07's concept page carried for weeks — a CronJob printed to illustrate a "
             "point, not applied by anyone"),

            # ── KIND 3, records and warnings. Rewriting any of these would make it claim
            # something that never happened.
            ("kind3-line-comment.adoc",
             anchor_block +
             "// GROUNDING 2026-07-31: driven with the exact command AS IT THEN STOOD —\n"
             f"// `oc -n user3-dev run claims-burst --image={floating_ref} --restart=Never`.\n", 0,
             "a dated // provenance comment was flagged. That is "
             "observability-health-scale/lab.adoc:666, deliberately left as-run; 'fixing' it makes "
             "it claim a measurement that never took place"),
            ("kind3-prose.adoc",
             anchor_block +
             "A floating `" + floating_ref + "` would be whatever the registry served that "
             "minute — and on this repository `latest` has been frozen since 2025.\n", 0,
             "PROSE naming an old tag in order to WARN about it was flagged. The warning cannot be "
             "written without naming the thing it warns about"),
            ("kind3-comment-fence.adoc",
             anchor_block +
             "////\n"
             "[source,sh,role=execute]\n"
             "----\n"
             f"oc run old --image={floating_ref} --restart=Never\n"
             "----\n"
             "////\n", 0,
             "an execute block inside a //// comment fence was flagged. It is commented out of the "
             "rendered page, so no attendee can run it and no click-to-run button exists for it"),

            # ── Responsibility and shape, inside genuine execute blocks.
            ("t3-pinned-anchor.adoc", anchor_block, 0,
             "a correctly pinned entitled reference in a live command block was flagged"),
            ("t3-mirror-source.adoc",
             anchor_block +
             "[source,sh,role=execute]\n"
             "----\n"
             "cat <<'EOF'\n"
             "  imageDigestMirrors:\n"
             "    - source: registry.redhat.io/ubi9\n"
             "EOF\n"
             "----\n", 0,
             "an ImageDigestMirrorSet's `- source:` was read as an image. It is a mirror-selector "
             "PREFIX, not a pull target — registry-images-catalog-governance/instructor.adoc:186 "
             "ships one, and pinning it would break the very mirror rule that block teaches. This "
             "is why tier 3 does not reuse tier 2's any-field regex"),
            ("t3-ubi-exempt.adoc",
             anchor_block +
             "[source,sh,role=execute]\n"
             "----\n"
             "    image: registry.access.redhat.com/ubi9/ubi-minimal:latest\n"
             "----\n", 0,
             "tier 3 fired on a UBI tag in a live block. Sixteen of those run in jobs-batch-kueue's "
             "Jobs on purpose; firing here opens the gate on pre-existing findings, which is the "
             "failure tier 2 was sequenced to avoid"),
            ("t3-incluster-exempt.adoc",
             anchor_block +
             "[source,sh,role=execute]\n"
             "----\n"
             "    image: image-registry.openshift-image-registry.svc:5000/openshift/tools:latest\n"
             "----\n", 0,
             "tier 3 fired on an in-cluster ImageStreamTag in a live block — a digest there pins "
             "away the thing the imagestream exists to do"),
            ("t3-param-skipped.adoc",
             anchor_block +
             "[source,sh,role=execute]\n"
             "----\n"
             "    image: {{ .Values.image }}\n"
             "----\n", 0,
             "a Helm placeholder inside a live block was judged instead of skipped — "
             "packaging-distributing/lab.adoc:294 has one"),

            # ── KIND 1, the positives. One per construct and one per emit site.
            ("t3-flag-floating.adoc",
             "[source,sh,role=execute]\n"
             "----\n"
             f"oc -n $NS run claims-burst --image={floating_ref} --restart=Never\n"
             "----\n", 1,
             "the m12 `claims-burst` defect — a floating entitled tag on `--image=` in a live "
             "command block — did not trip tier 3. That is the regression this whole tier exists "
             "to prevent, and it survived 32 days and a 44-site sweep without it"),
            ("t3-yaml-field-floating.adoc",
             "[source,sh,role=execute]\n"
             "----\n"
             "oc apply -f - <<'EOF'\n"
             f"          image: {floating_ref}\n"
             "EOF\n"
             "----\n", 1,
             "a floating entitled tag in a YAML `image:` field inside a heredoc the attendee "
             "APPLIES did not trip tier 3"),
            ("t3-json-field-floating.adoc",
             "[source,sh,role=execute]\n"
             "----\n"
             "oc run c --overrides='{\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":"
             "\"registry.redhat.io/rhtas/client-server-rhel9\"}]}}'\n"
             "----\n", 1,
             "a floating entitled reference inside an `--overrides` JSON body did not trip tier 3. "
             "m08 carried its unpinned ref on two consecutive lines, once as a flag and once like "
             "this, and a guard reading only the flag would have called the second line clean. "
             "Note it has NO tag at all, which is an implicit :latest wearing no clothes"),
            ("t3-quoted-role.adoc",
             '[source,sh,role="execute send-to-tty-bottom"]\n'
             "----\n"
             f"oc run x --image={floating_ref}\n"
             "----\n", 1,
             "the quoted multi-word `role=\"execute …\"` opener was not recognized as a live "
             "block. click-to-run.js honours that form, so a block wearing it is one an attendee "
             "can still click"),
            ("t3-malformed.adoc",
             "[source,sh,role=execute]\n"
             "----\n"
             "oc run x --image=registry.redhat.io/openshift4/ose-cli@sha256:deadbeef\n"
             "----\n", 1,
             "a truncated digest in a live command block did not trip tier 3. It has the SHAPE of "
             "a pin, so it passes any '@sha256: appears in the string' check while failing the "
             "pull in front of the room"),
            ("t3-role-lookalike.adoc",
             anchor_block +
             "[source,sh,role=executed-elsewhere]\n"
             "----\n"
             f"oc run x --image={floating_ref}\n"
             "----\n", 0,
             "a role whose name merely CONTAINS the word execute was treated as executable. The "
             "role value is split on whitespace for exactly this reason"),
        ]
        for name, text, expected, complaint in adoc_cases:
            probe = Path(d) / name
            probe.write_text(text)
            if check_content([probe]) != expected:
                print(f"SELF-TEST FAILED: {complaint}", file=sys.stderr)
                ok = False

        # Tier 3's floors, each exercised the way it actually fails. A page that is GONE first —
        # same reasoning as the missing Task below.
        if check_content([Path(d) / "no-such-page.adoc"]) != 2:
            print("SELF-TEST FAILED: a missing content page did not exit 2 — a renamed module "
                  "would read as a page with no unpinned commands.", file=sys.stderr)
            ok = False
        anchor_page = Path(d) / "t3-pinned-anchor.adoc"
        if check_content([anchor_page], min_files=MIN_CONTENT_FILES) != 2:
            print("SELF-TEST FAILED: a collapsed content FILE set did not exit 2 — a broken glob "
                  "would report clean over pages it never opened.", file=sys.stderr)
            ok = False
        if check_content([anchor_page], min_blocks=MIN_CONTENT_BLOCKS) != 2:
            print("SELF-TEST FAILED: a collapsed EXECUTE-BLOCK count did not exit 2. This is the "
                  "one that matters most: a blinded opener or delimiter reads every page and finds "
                  "no commands, which prints identically to a content tree with nothing wrong.",
                  file=sys.stderr)
            ok = False
        if check_content([anchor_page], min_refs=MIN_CONTENT_REFS) != 2:
            print("SELF-TEST FAILED: a collapsed IMAGE-REFERENCE count did not exit 2 — a "
                  "construct regex that stopped matching would report clean over live commands.",
                  file=sys.stderr)
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
        # Tier 2's own floors, the same two failures. The second is the one that matters most here:
        # a responsibility predicate blinded to False exempts EVERYTHING, and without this the tier
        # would print "clean — 0 image(s) digest-pinned, 53 exempt" and exit 0.
        if check([one], min_files=MIN_INSTALL_FILES,
                 field=ENTITLED_FIELD, only=is_entitled_scope, tier=T2) != 2:
            print("SELF-TEST FAILED: a collapsed tier-2 FILE set did not exit 2 — a broken "
                  "install-path glob would report clean over a tree it never opened.",
                  file=sys.stderr)
            ok = False
        all_exempt = Path(d) / "t2-all-exempt.yaml"
        all_exempt.write_text("    image: registry.redhat.io/devspaces/udi-rhel9:3.29\n")
        if check([all_exempt], min_images=MIN_INSTALL_IMAGES,
                 field=ENTITLED_FIELD, only=is_entitled_scope, tier=T2) != 2:
            print("SELF-TEST FAILED: a tier-2 run that judged ZERO references did not exit 2 — an "
                  "exemption predicate that widened to everything would report clean.",
                  file=sys.stderr)
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

    # Tier 2's discovery is a FLOOR, not an equality (664 files today against a floor of 400), so
    # there is no MIN==found assertion to make. What must hold is that discovery still clears its
    # own floor on the real tree: a glob that stops matching would otherwise only be caught on
    # whatever push happened to follow it.
    install_found = len(install_path_files())
    if install_found < MIN_INSTALL_FILES:
        print(f"SELF-TEST FAILED: install-path discovery finds {install_found} file(s), below its "
              f"own floor of {MIN_INSTALL_FILES}. Either the glob broke or the roots "
              f"{list(INSTALL_ROOTS)} moved; re-state the floor deliberately, do not lower it to "
              f"whatever the bug returns.", file=sys.stderr)
        ok = False

    # Tier 3's discovery, the same floor check as tier 2's — plus the cross-check that gives this
    # tier its confidence: click-to-run-guard.py walks the same `content/**.adoc` set with an
    # independently written opener and delimiter, and both count 1108 blocks. If the two ever
    # disagree, one of them is reading a set of commands the other is not, and neither's clean
    # result means what it says.
    content_found = len(content_files())
    if content_found < MIN_CONTENT_FILES:
        print(f"SELF-TEST FAILED: content discovery finds {content_found} page(s), below its own "
              f"floor of {MIN_CONTENT_FILES}. Either the glob broke or {CONTENT_ROOT.name}/ moved; "
              f"re-state the floor deliberately, do not lower it to whatever the bug returns.",
              file=sys.stderr)
        ok = False
    blocks_found = sum(1 for p in content_files()
                       for _ in iter_execute_blocks(
                           p.read_text(encoding="utf-8", errors="replace").splitlines()))
    if blocks_found < MIN_CONTENT_BLOCKS:
        print(f"SELF-TEST FAILED: the content walk finds {blocks_found} execute block(s), below "
              f"its own floor of {MIN_CONTENT_BLOCKS}. Cross-check against "
              f"`tools/lint/click-to-run-guard.py`, which counts the same blocks a different way; "
              f"if it still reports ~1108, this walk is what broke.", file=sys.stderr)
        ok = False

    for failure in Scope.self_check():
        print(f"SELF-TEST FAILED: {failure}", file=sys.stderr)
        ok = False

    if not ok:
        return 2
    print("self-test ok — floating tags (:latest, a version tag, and no tag at all) fail; "
          "malformed digests fail; bare and composite digest pins pass, as do parameter "
          "placeholders and prose in comments; a missing file and a collapsed file or image scope "
          "are refusals, not clean runs; the file floor matches discovery. Tier 2: an entitled "
          "floating tag fails; a pinned `cli:` value, a UBI tag, an in-cluster ImageStreamTag and "
          "a Dev Spaces UDI are all correctly left alone; a collapsed file set and a run that "
          "exempts everything are refusals. Tier 3: a floating or malformed entitled reference "
          "fails in a role=execute block, whether it arrives on --image=, in a YAML image: field "
          "or in an --overrides JSON body, and whether the role is bare or quoted; captured output "
          "(.Expected output, [source,texinfo], a bare listing, a [source,yaml] display manifest), "
          "a dated // provenance comment, warning prose, a //// comment fence, an IDMS mirror "
          "`source:` prefix, a UBI or in-cluster reference, a Helm placeholder and a role that "
          "merely contains the word execute are ALL correctly left alone; a missing page and a "
          "collapsed file, block or reference scope are refusals.")
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

    # ALL THREE tiers run before any verdict is returned, deliberately: a tier-1 finding must not
    # hide a tier-2 or tier-3 one from whoever is reading the log. rc 2 dominates rc 1 dominates
    # rc 0, which `max` gives directly — "could not inspect" outranks "found something" outranks
    # "clean".
    tier1 = check(scope_files(), MIN_FILES, MIN_IMAGES)
    tier2 = check(install_path_files(), MIN_INSTALL_FILES, MIN_INSTALL_IMAGES,
                  field=ENTITLED_FIELD, only=is_entitled_scope, tier=T2)
    tier3 = check_content(content_files(), MIN_CONTENT_FILES, MIN_CONTENT_BLOCKS, MIN_CONTENT_REFS)
    return max(tier1, tier2, tier3)


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
