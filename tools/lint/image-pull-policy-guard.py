#!/usr/bin/env python3
"""image-pull-policy-guard.py — every workshop-built image must be pulled with `Always`.

WHY THIS EXISTS. Every image this workshop builds is tagged `1.0`/`1.1` and rebuilt IN PLACE, so the
tag is MUTABLE. Kubernetes defaults any tag other than `:latest` to `imagePullPolicy: IfNotPresent`,
and a node that already has that tag cached serves the OLD layers forever. Measured on a live cluster
(2026-07-29): all three `parasol-claims` tags had moved to a new digest, and `oc rollout restart`
brought the old digest back up. Commit 4efc931 fixed all 29 sites; this guard is what stops the 30th.

THIS GUARD RENDERS, IT DOES NOT GREP — that is the entire point.
`config-multienv` emits two of its three claims Deployments from a NAMED TEMPLATE in
`templates/_helpers.tpl` (`claims.stack`, called twice). Those Deployments do not exist as text in any
`templates/*.yaml`, so `grep 'image:' templates/*.yaml` cannot see them. That blind spot swallowed
that chart TWICE — this sweep, and the Route-TLS sweep of 2026-07-27 (see route-tls-guard.sh's
header). Every other author-facing check in this repo is line-oriented, so the defect class recurs by
construction until one gate renders. This is that gate.

Charts are rendered at BOTH `solve=false` and `solve=true`, because solve worlds emit Deployments the
default render never produces, and the promotion template is built through kustomize for all three
overlays plus the rollouts directory.

WHAT COUNTS AS "OURS" (the load-bearing question, and the reason this file is not a list of names).
The signal is the REGISTRY, not the repository name:

    an image is workshop-built  <=>  it is served by the OpenShift internal registry
                                     AND its namespace is not `openshift`

Everything this workshop builds is built ON the cluster — binary builds and Tekton pipelines pushing
into `ogsr-parasol-images` (shared, built once) or into a per-user `{user}-dev` (the
packaging-distributing BuildConfig) — and reached over the internal registry Service, whose DNS name
is identical on every OpenShift cluster. Verified 2026-07-29 that nothing we build is pushed anywhere
else: `git grep -nE 'quay\\.io/(ogsr|parasol)|IMAGE_REGISTRY|imageRepo' -- gitops/ pipelines/ apps/
bootstrap/` returns nothing. So "in the internal registry" and "we built it, in place, under a
mutable tag" are the same set.

The one carve-out is the cluster's own `openshift` namespace — the Samples Operator's shared
imagestreams (`postgresql:15-el9`, `tools:latest`, `nodejs:20-ubi9`). Those are populated by the
cluster, not by us; we never rebuild them, so a cached layer is not our defect and they correctly stay
`IfNotPresent`. That is ONE documented exception to a derived rule, not a hand-maintained inventory
that goes stale the day someone adds a service.

Everything outside the internal registry is upstream and deliberately untouched: `:latest` already
defaults to `Always`, and digest- or version-pinned references (`registry.redhat.io/devspaces/
udi-rhel9:3.29`, `rhel9/postgresql-16@sha256:…`) are immutable by construction.

FINDING IMAGES. The walk is generic: any dict anywhere in any rendered document that carries a string
`image` key is an image site, wherever it sits. That is deliberately broader than "parse the PodSpec":
it picks up PodSpecs nested inside an OpenShift `Template.objects[]`
(registry-images-catalog-governance ships one), Tekton `taskSpec.steps[]`, CronJob
`jobTemplate.spec.template.spec`, Argo `Rollout`, and the devfile `components[].container` of a
DevWorkspace — none of which a PodSpec-shaped walk reaches. A workshop image found at a container key
this guard does not recognize is an EXIT 2, never a pass: better to stop and make a person look than
to quietly not check something.

EXEMPTIONS are declared in EXEMPTIONS below, keyed by (API group, kind), each with its reason. There
is exactly one today (Knative Services) and its premise is machine-checked — see
`check_knative_premise`.

USAGE
    tools/lint/image-pull-policy-guard.py                # check the tree
    tools/lint/image-pull-policy-guard.py --list-images  # every image found, and how it is classified
    tools/lint/image-pull-policy-guard.py --self-test    # scan the canary fixtures; MUST exit 1

EXIT CODES (same contract as copy-drift-guard.py / credential-redaction-guard.py, so the workflow
steps read alike):
    0  every workshop container pulls with Always
    1  at least one does not — or, under --self-test, every canary was correctly detected
    2  the guard could not do its job (helm/kustomize/PyYAML missing, a render failed, a COLLAPSED
       scope, a workshop image at an unrecognized container key, or an undetected canary). Never
       confuse this with a clean result.

SCOPE IS ASSERTED, NOT ASSUMED (2026-08-01). An audit dropped the kustomize half, dropped the
solve=true half, truncated chart discovery to one chart, and broke the Knative-premise call — each
one on its own, each leaving this guard printing "clean" and exiting 0. The old check ("zero image
references is an error") only ever caught total emptiness. Every render loop now raises a counter
that is measured against a floor (scope_for_tree() below, mechanism in tools/lint/_scope.py), and
the warn-only premise check reports how many derivations it actually made, because nothing else in
the run notices when a warning stops being emitted.

LOCAL YAMLLINT: the canary chart's templates carry Helm actions and are not plain YAML, exactly like
the real chart template dirs and like copy-drift-guard's fixture. The maintainer yamllint config is
gitignored (2026-07-19 owner review) so it cannot ship that exclusion with this commit — add

    tools/lint/image-pull-policy-guard.canary/chart/templates/

to the `ignore:` block of your own .yamllint.yaml, next to the copy-drift-guard.canary line.
"""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile


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
    print(f"::error::image-pull-policy-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). "
          f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
          f"'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad; see the note below
    # NOT `except ImportError`. Measured 2026-08-01: a _scope.py that fails to PARSE raises
    # SyntaxError, sails past an ImportError-only handler, and exits 1 — CI's 'the canary
    # fired'. Anything at all going wrong while loading the scope ledger means this guard
    # cannot start, and that is rc 2 regardless of which exception said so.
    # An uncaught ImportError exits 1, and CI's contract for this guard is "--self-test must exit
    # EXACTLY 1 = the canary was detected". A crash would therefore be READ AS PROOF OF DETECTION and
    # the real run would never even happen. Measured 2026-08-01 by running a copy of this file with
    # _scope.py absent: traceback, rc=1, and the CI step would have printed "self-test ok".
    print(f"::error::image-pull-policy-guard: cannot import _scope ({exc}) — "
          f"the guard could not start, which is NOT the same as a clean tree.",
          file=sys.stderr)
    sys.exit(2)

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a machine without PyYAML
    print("image-pull-policy-guard: PyYAML is not installed. This guard parses rendered manifests "
          "properly rather than pattern-matching them, so it cannot run without a parser — refusing "
          "to report clean. Install it (python3 -m pip install PyYAML) and re-run.", file=sys.stderr)
    sys.exit(2)


# The OpenShift internal registry Service. Identical on every OpenShift cluster, which is why the
# rule below is portable and not a property of any one cluster.
INTERNAL_REGISTRY = "image-registry.openshift-image-registry.svc:5000/"

# The cluster's own shared imagestream namespace (Samples Operator). Populated by OpenShift, never
# rebuilt by us — the single documented carve-out from "internal registry means ours".
CLUSTER_OWNED_NAMESPACE = "openshift"

REQUIRED_POLICY = "Always"

# Keys under which a container object legitimately appears. A workshop image found anywhere else is
# an exit 2 rather than a silent skip: an unknown shape means the guard does not know whether it is
# even looking at something that can carry imagePullPolicy.
CONTAINER_KEYS = {
    "containers",          # PodSpec / Knative RevisionSpec / Rollout
    "initContainers",      # PodSpec
    "ephemeralContainers",  # PodSpec
    "steps",               # Tekton TaskSpec
    "sidecars",            # Tekton TaskSpec
    "stepTemplate",        # Tekton TaskSpec (single object, not a list)
    "container",           # devfile v2 / DevWorkspace components[].container
}

# --------------------------------------------------------------------------------- what to render

# Helm charts, rendered under every values permutation that changes WHAT IS EMITTED. `solve` is not
# cosmetic: solve worlds materialize Deployments the default render never produces. Any future flag
# that gates extra workloads belongs here too.
HELM_VALUE_SETS = (
    {"user": "user1", "clusterDomain": "example.com", "solve": "false"},
    {"user": "user1", "clusterDomain": "example.com", "solve": "true"},
)

# The promotion template is kustomize, not Helm: three environment overlays plus the progressive-
# delivery directory, which carries an Argo Rollout and a migration Job that the overlays do not.
KUSTOMIZE_DIRS = (
    "gitops/promotion/claims-config-template/overlays/dev",
    "gitops/promotion/claims-config-template/overlays/stage",
    "gitops/promotion/claims-config-template/overlays/prod",
    "gitops/promotion/claims-config-template/rollouts",
)

# --------------------------------------------------------------------------------- exemptions

# DELIBERATELY EMPTY. There was one entry — serving.knative.dev/v1 Service — resting on the premise
# that Knative resolves an image tag to an immutable digest at Revision creation, so a ksvc could not
# suffer the mutable-tag defect. The premise is false HERE, and this guard is what caught it: the
# portfolio sets registries-skipping-tag-resolving for the internal registry
# (platform-portfolio/components/serverless/knative-serving.yaml), which is exactly the switch that
# turns that resolution off for our images. Confirmed against the live cluster's config-deployment
# 2026-07-29. Both ksvcs now carry Always like everything else, and the exemption is retired.
#
# check_knative_premise() below is KEPT, not deleted: it re-derives the setting from the CR on every
# run, so if anyone ever removes the internal registry from that skip list, the guard says so and the
# exemption can be reconsidered on evidence rather than on memory. That re-derivation is the reason
# this was caught at all — an exemption whose premise is a comment is an exemption nobody rechecks.
EXEMPTIONS: list[dict] = []

# The portfolio CR whose config decides whether the Knative exemption's premise holds.
KNATIVE_SERVING_CR = "platform-portfolio/components/serverless/knative-serving.yaml"

# The scope dimensions collect_sites() raises, named once so the counters and their floors cannot
# drift apart. self_test asserts each one has a floor.
COLLECT_DIMENSIONS = ("helm renders", "solve=false image sites", "solve=true image sites",
                      "kustomize builds", "kustomize image sites")


class GuardError(Exception):
    """The guard cannot do its job. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


# --------------------------------------------------------------------------------- classification


def image_namespace(image: str) -> str | None:
    """The internal-registry namespace an image lives in, or None if it is not internal."""
    if not image.startswith(INTERNAL_REGISTRY):
        return None
    remainder = image[len(INTERNAL_REGISTRY):]
    return remainder.split("/", 1)[0] if "/" in remainder else None


def is_workshop_image(image: str) -> bool:
    """True when WE build this image, in place, under a mutable tag. See the module docstring."""
    namespace = image_namespace(image)
    return namespace is not None and namespace != CLUSTER_OWNED_NAMESPACE


def api_group(api_version: str) -> str:
    return api_version.split("/", 1)[0] if "/" in api_version else ""


def exemption_for(api_version: str, kind: str) -> dict | None:
    group = api_group(api_version)
    for exemption in EXEMPTIONS:
        if exemption["group"] == group and exemption["kind"] == kind:
            return exemption
    return None


# --------------------------------------------------------------------------------- walking


def _enclosing_key(path: list) -> str | None:
    """The key the container object hangs off — `containers` for …/containers/0, `container` for
    …/components/0/container. Anything else is a shape this guard has not been taught."""
    if not path:
        return None
    if isinstance(path[-1], int):
        return str(path[-2]) if len(path) >= 2 else None
    return str(path[-1])


def find_image_sites(document, source: str) -> list[dict]:
    """Every dict carrying a string `image`, anywhere in the document, with where it was found.

    Generic on purpose — see the module docstring. Template.objects[], CronJob jobTemplate, Tekton
    taskSpec.steps[] and DevWorkspace components[].container all fall out of this for free, and none
    of them are reachable by a walk that only knows the PodSpec shape.
    """
    kind = document.get("kind", "<no kind>") if isinstance(document, dict) else "<not a mapping>"
    name = "<unnamed>"
    if isinstance(document, dict) and isinstance(document.get("metadata"), dict):
        name = document["metadata"].get("name", "<unnamed>")
    api_version = document.get("apiVersion", "") if isinstance(document, dict) else ""

    sites: list[dict] = []

    def walk(node, path: list) -> None:
        if isinstance(node, dict):
            if isinstance(node.get("image"), str):
                sites.append({
                    "image": node["image"],
                    "policy": node.get("imagePullPolicy"),
                    "container_name": node.get("name"),
                    "path": list(path),
                    "enclosing_key": _enclosing_key(path),
                    "kind": kind,
                    "name": name,
                    "apiVersion": api_version,
                    "source": source,
                })
            for key, value in node.items():
                walk(value, path + [key])
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, path + [index])

    walk(document, [])
    return sites


def fmt_path(path: list) -> str:
    return "/".join(str(step) for step in path)


# --------------------------------------------------------------------------------- rendering


def _require(tool: str) -> None:
    if shutil.which(tool) is None:
        raise GuardError(
            f"{tool} is not on PATH. This guard RENDERS the charts rather than grepping them — that "
            "is the whole reason it exists (a named template in _helpers.tpl is invisible to a grep) "
            "— so it cannot run without it. Refusing to report clean.")


def render_helm(root: pathlib.Path, chart: pathlib.Path, values: dict) -> str:
    _require("helm")
    cmd = ["helm", "template", "t", str(chart)]
    for key, value in values.items():
        cmd += ["--set", f"{key}={value}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, cwd=root)
    if proc.returncode != 0:
        label = " ".join(f"{k}={v}" for k, v in values.items())
        raise GuardError(
            f"`helm template` failed for {chart.relative_to(root)} ({label}), rc={proc.returncode}:\n"
            f"{proc.stderr.strip()}\n"
            "A chart that will not render is a chart this guard did not check. Skipping it would "
            "turn a broken chart into a passing gate.")
    return proc.stdout


def render_kustomize(root: pathlib.Path, directory: str) -> str:
    _require("kustomize")
    proc = subprocess.run(["kustomize", "build", directory],
                          capture_output=True, text=True, check=False, cwd=root)
    if proc.returncode != 0:
        raise GuardError(f"`kustomize build {directory}` failed (rc={proc.returncode}):\n"
                         f"{proc.stderr.strip()}")
    return proc.stdout


def parse_documents(text: str, source: str) -> list:
    try:
        return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        raise GuardError(f"{source} rendered output that is not parseable as YAML: {exc}") from exc


def collect_sites(root: pathlib.Path, charts: list[pathlib.Path],
                  kustomize_dirs: tuple) -> tuple[list[dict], dict]:
    """(sites, scope counters). The counters are raised by the loops that render, so dropping the
    kustomize half or the solve=true half collapses a dimension instead of quietly shrinking the
    input set — both were blindings that left this guard reporting clean (audit 2026-08-01)."""
    sites: list[dict] = []
    counts = {dimension: 0 for dimension in COLLECT_DIMENSIONS}
    for chart in charts:
        for values in HELM_VALUE_SETS:
            label = f"{chart.relative_to(root)} (solve={values['solve']})"
            counts["helm renders"] += 1
            for document in parse_documents(render_helm(root, chart, values), label):
                found = find_image_sites(document, label)
                counts[f"solve={values['solve']} image sites"] += len(found)
                sites += found
    for directory in kustomize_dirs:
        if not (root / directory).is_dir():
            raise GuardError(f"{directory} does not exist. It was moved or renamed; update "
                             "KUSTOMIZE_DIRS rather than leaving the gate pointing at nothing.")
        counts["kustomize builds"] += 1
        for document in parse_documents(render_kustomize(root, directory), directory):
            found = find_image_sites(document, directory)
            counts["kustomize image sites"] += len(found)
            sites += found
    return sites, counts


# --------------------------------------------------------------------------------- the check


def evaluate(sites: list[dict]) -> tuple[list[str], list[str], dict]:
    """Return (violations, blockers, stats). A blocker is an exit-2 condition, not a violation."""
    violations: list[str] = []
    blockers: list[str] = []
    stats = {"images": 0, "workshop": 0, "always": 0, "exempt": 0}

    for site in sites:
        stats["images"] += 1
        if not is_workshop_image(site["image"]):
            continue
        stats["workshop"] += 1

        if site["enclosing_key"] not in CONTAINER_KEYS:
            blockers.append(
                f"{site['source']} {site['kind']}/{site['name']} at {fmt_path(site['path'])}\n"
                f"      carries the workshop image {site['image']} under the key "
                f"{site['enclosing_key']!r}, which this guard does not recognize as a container "
                "position.\n"
                "      Refusing to guess whether that shape can even carry imagePullPolicy. Add the "
                "key to CONTAINER_KEYS if it is a container, or declare an EXEMPTIONS entry with the "
                "reason if the shape genuinely cannot express a pull policy.")
            continue

        exemption = exemption_for(site["apiVersion"], site["kind"])
        if exemption is not None:
            stats["exempt"] += 1
            continue

        if site["policy"] == REQUIRED_POLICY:
            stats["always"] += 1
            continue

        policy_text = site["policy"] or (
            "<unset — Kubernetes defaults any tag other than :latest to IfNotPresent>")
        violations.append(
            f"{site['source']} {site['kind']}/{site['name']} "
            f"container {site['container_name'] or '<unnamed>'} at {fmt_path(site['path'])}\n"
            f"      image  : {site['image']}\n"
            f"      policy : {policy_text}\n"
            f"      fix    : add `imagePullPolicy: {REQUIRED_POLICY}` to this container, and bump "
            "the chart version so Argo's manifest cache picks the change up.")

    return violations, blockers, stats


# ------------------------------------------------------------------- the Knative premise, re-derived


def knative_premise_findings(path: pathlib.Path, label: str) -> tuple[list[str], int]:
    """Re-derive the Knative exemption's premise from a KnativeServing CR file.

    The exemption holds only while Knative actually resolves our tags to digests. That behaviour is
    switchable PER REGISTRY via `KnativeServing.spec.config.deployment.registries-skipping-tag-
    resolving`, so the premise is a property of the portfolio, not a fact about Knative — and it is
    re-derived on every run rather than trusted to a comment.

    Warns rather than fails: whether to drop the exemption is an architecture decision for the PM,
    not something a lint gate should take unilaterally. But it is re-checked and re-printed on every
    CI run, so it cannot rot the way a comment does.

    Returns (findings, derivations) — the second element counts the KnativeServing CRs from which a
    conclusion was actually reached. It exists because this check is WARN-ONLY, so breaking it
    produced no failure of any kind: the audit blinded it and the run stayed clean and silent. It is
    also the only thing that notices a KNATIVE_SERVING_CR file that parses but carries no
    KnativeServing document at all, which used to return [] and read as "premise holds".
    """
    if not path.is_file():
        return ([f"{label} is missing, so the Knative exemption's premise cannot be re-derived. "
                 "Update KNATIVE_SERVING_CR if the portfolio moved it."], 0)
    try:
        documents = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8"))
                     if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        return ([f"{label} is not parseable as YAML ({exc}), so the Knative exemption's premise "
                 "cannot be re-derived."], 0)

    for document in documents:
        if document.get("kind") != "KnativeServing":
            continue
        skipping = (((document.get("spec") or {}).get("config") or {})
                    .get("deployment") or {}).get("registries-skipping-tag-resolving")
        if isinstance(skipping, str) and INTERNAL_REGISTRY.rstrip("/") in skipping:
            # EXPECTED STATE, so: silence. The skip list includes our registry, Knative therefore
            # keeps the mutable tag in the Revision, and both ksvcs carry imagePullPolicy: Always to
            # compensate. That is handled, and a warning repeated on every green run is how a project
            # teaches itself to stop reading warnings.
            return ([], 1)
        return ([
            f"{label} no longer lists the internal registry in registries-skipping-tag-resolving.",
            "That restores Knative's default tag->digest resolution for workshop-built images, so a "
            "ksvc would pull by digest and the mutable-tag defect could not reach it.",
            "Consequence worth acting on: the imagePullPolicy: Always on the two ksvcs "
            "(serverless-zero-to-hero, eventing-deep-dive) becomes an avoidable registry round-trip "
            "on every scale-from-zero — and it is paid in the one module whose cold-start timings "
            "are a measured teaching artifact. Re-examine the exemption, do not just delete this "
            "check. The guard reports the change; the call is a human's.",
        ], 1)
    # The file parses but carries no KnativeServing document at all. Nothing was derived, and
    # returning "no findings" here reads as "the premise holds" — the scope floor is what stops it.
    return ([], 0)


def check_knative_premise(root: pathlib.Path) -> tuple[list[str], int]:
    return knative_premise_findings(root / KNATIVE_SERVING_CR, KNATIVE_SERVING_CR)


# --------------------------------------------------------------------------------- self-test


def _canary_root(root: pathlib.Path) -> pathlib.Path:
    return root / "tools/lint/image-pull-policy-guard.canary"


def self_test(root: pathlib.Path) -> int:
    """Prove each detector on static fixtures. A result other than 1 means detection is unproven.

    Static fixtures, not a mutated copy of a real chart: what has to be tested here is the DETECTOR,
    and a canary derived from live content quietly becomes an exit 2 the day that content changes
    shape.
    """
    fixture = _canary_root(root)
    if not fixture.is_dir():
        print("::error::image-pull-policy-guard: the canary fixture directory is missing — "
              "detection is unproven, so a clean result on the real tree means nothing.",
              file=sys.stderr)
        return 2

    failures: list[str] = []

    # (1) The classifier: the rule that decides what is ours, exercised on the real shapes.
    classifier_cases = [
        (f"{INTERNAL_REGISTRY}ogsr-parasol-images/parasol-claims:1.1", True, "shared built image"),
        (f"{INTERNAL_REGISTRY}user1-dev/parasol-notifications:1.0", True, "per-user built image"),
        (f"{INTERNAL_REGISTRY}openshift/postgresql:15-el9", False, "Samples Operator imagestream"),
        (f"{INTERNAL_REGISTRY}openshift/tools:latest", False, "Samples Operator imagestream"),
        ("registry.redhat.io/devspaces/udi-rhel9:3.29", False, "upstream, version-pinned"),
        ("quay.io/openshift-knative/showcase:latest", False, "upstream, :latest"),
        ("registry.redhat.io/rhel9/postgresql-16@sha256:" + "0" * 64, False, "upstream, digest"),
        ("auto", False, "Istio gateway injection placeholder"),
    ]
    for image, expected, why in classifier_cases:
        if is_workshop_image(image) != expected:
            failures.append(f"classifier: {image} ({why}) should be "
                            f"{'workshop-built' if expected else 'upstream'} and is not.")

    # (2) The renderer + walker + policy check, against a fixture chart that reproduces every shape
    #     the real tree has: a plain Deployment, a Deployment emitted only from a NAMED TEMPLATE (the
    #     config-multienv blind spot), a PodSpec nested in a Template.objects[], two Knative Services,
    #     and upstream images that must NOT be demanded.
    #
    #     The two ksvcs deliberately carry NO pull policy and are now expected to be DETECTED. They
    #     used to assert the opposite — that they were exempt — and that assertion is what would have
    #     locked in a false premise: EXEMPTIONS held a Knative entry on the belief that Knative
    #     resolves the tag to a digest, which this portfolio switches off for our own registry. A
    #     canary that asserts an exemption is a canary that defends a mistake. Keeping the ksvcs
    #     policy-less and demanding they be flagged tests the thing that actually protects attendees.
    canary_chart = fixture / "chart"
    expectations = [
        # (solve, expected violating object names, expected workshop-container count)
        #   solve=false — canary-plain-bad(1) + canary-plain-good(1) + canary-init-good(2) = 4
        #   solve=true  — the above + canary-helper-{good,bad}(2) + canary-template-bad(1)
        #                 + the two ksvcs(2)                                               = 9
        ("false", {"canary-plain-bad"}, 4),
        ("true", {"canary-plain-bad", "canary-helper-bad", "canary-template-bad",
                  "canary-ksvc-a", "canary-ksvc-b"}, 9),
    ]
    for solve, expected_bad, expected_workshop in expectations:
        values = {"user": "user1", "clusterDomain": "example.com", "solve": solve}
        try:
            documents = parse_documents(render_helm(root, canary_chart, values),
                                        f"canary (solve={solve})")
        except GuardError as exc:
            failures.append(f"canary chart (solve={solve}) could not be rendered: {exc}")
            continue
        sites: list[dict] = []
        for document in documents:
            sites += find_image_sites(document, f"canary (solve={solve})")
        violations, blockers, stats = evaluate(sites)
        if blockers:
            failures.append(f"canary (solve={solve}) produced unexpected blockers: {blockers}")
        got_bad = {line.split(" container ")[0].split("/")[-1] for line in violations}
        if got_bad != expected_bad:
            failures.append(f"canary (solve={solve}): expected violations on {sorted(expected_bad)}, "
                            f"got {sorted(got_bad)}.")
        if stats["workshop"] != expected_workshop:
            failures.append(f"canary (solve={solve}): expected {expected_workshop} workshop "
                            f"containers, saw {stats['workshop']}. The walker is not reaching every "
                            "shape the fixture plants.")
        # Nothing is exempt any more, and that must stay true by assertion rather than by nobody
        # noticing: a re-introduced exemption silently turns real violations into ignored ones, which
        # is exactly how the Knative case survived. If a future exemption is genuinely warranted, this
        # line is where the evidence for it has to be re-stated.
        if stats["exempt"] != 0:
            failures.append(f"canary (solve={solve}): expected 0 exempt containers, saw "
                            f"{stats['exempt']}. An exemption was re-introduced — justify it here.")

    # (2b) collect_sites() ITSELF — the production glue main() runs and every assertion above walks
    #      around. The loop above calls render_helm and find_image_sites directly, so anything
    #      collect_sites does with their output was unproven: blinded to return no sites while still
    #      raising its counters, both CI signals stayed green (measured 2026-08-01). A filter or a
    #      slice appended at the end of that function is the realistic shape.
    #
    #      Driven over the canary chart with NO kustomize dirs — what is being proven here is the
    #      helm half's wiring; the kustomize half is pinned by its own scope floor on the real run,
    #      which fails closed because KUSTOMIZE_DIRS is a declared list.
    try:
        collected, collected_counts = collect_sites(root, [canary_chart], ())
    except GuardError as exc:
        collected, collected_counts = [], {}
        failures.append(f"collect_sites() could not run over the canary chart: {exc}")
    if collected_counts:
        if collected_counts["helm renders"] != len(HELM_VALUE_SETS):
            failures.append(f"collect_sites() reported {collected_counts['helm renders']} helm "
                            f"render(s) for one chart; HELM_VALUE_SETS declares "
                            f"{len(HELM_VALUE_SETS)}. A dropped value set is a whole world of "
                            "workloads that stops being rendered.")
        if collected_counts["solve=true image sites"] <= collected_counts["solve=false image sites"]:
            failures.append("collect_sites() did not see MORE image sites at solve=true than at "
                            "solve=false. The canary chart, like every entry state, materializes "
                            "extra workloads in its solve world; equal counts mean one render's "
                            "documents never reached the walker.")
        # The invariant a blinded collect_sites breaks and nothing else notices: the sites it
        # RETURNS must be exactly the sites it COUNTED. Counters that outlive their own list are
        # how a scope floor gets satisfied by work whose result was thrown away.
        counted = sum(collected_counts[d] for d in COLLECT_DIMENSIONS if d.endswith("image sites"))
        if len(collected) != counted:
            failures.append(f"collect_sites() returned {len(collected)} site(s) but counted "
                            f"{counted}. The scope floors are raised from the counters, so a "
                            "filter that drops sites after they are counted passes every floor "
                            "while judging nothing.")

    # (3a) Every declared container key must actually be honoured by the walker. Asserted in Python
    #      rather than as a chart fixture: the devfile `container` key has no workshop-image instance
    #      in the tree today, and shipping a rendered fixture that carries one would imply a devfile
    #      schema claim this guard has no business making. What is being proven here is only that the
    #      walker REACHES the shape and does not treat it as unknown.
    devworkspace = {
        "apiVersion": "workspace.devfile.io/v1alpha2", "kind": "DevWorkspace",
        "metadata": {"name": "canary-devworkspace"},
        "spec": {"template": {"components": [
            {"name": "tools",
             "container": {"image": f"{INTERNAL_REGISTRY}ogsr-parasol-images/mcp-agent-cli:1.0",
                           "imagePullPolicy": REQUIRED_POLICY}}]}},
    }
    dw_sites = find_image_sites(devworkspace, "canary-devworkspace")
    if [s["enclosing_key"] for s in dw_sites] != ["container"]:
        failures.append("the walker did not reach a devfile components[].container image, or "
                        "classified its position wrongly — a PodSpec-shaped walk's blind spot.")
    _, dw_blockers, dw_stats = evaluate(dw_sites)
    if dw_blockers or dw_stats["always"] != 1:
        failures.append("the `container` key is declared in CONTAINER_KEYS but is not honoured: a "
                        "workshop image there was blocked or not counted.")

    # (3) The unknown-shape blocker: a workshop image somewhere this guard has not been taught must
    #     stop the run, not be silently skipped.
    odd = {"apiVersion": "example.com/v1", "kind": "Widget", "metadata": {"name": "canary-odd"},
           "spec": {"somethingElse": {"image": f"{INTERNAL_REGISTRY}ogsr-parasol-images/x:1.0"}}}
    _, odd_blockers, _ = evaluate(find_image_sites(odd, "canary-unknown-shape"))
    if len(odd_blockers) != 1:
        failures.append("the unknown-container-key blocker did not fire on a workshop image planted "
                        "at an unrecognized path — the guard would silently skip that shape.")

    # (4) The Knative premise re-derivation, both ways. Written to a temp dir, never into the tree:
    #     a fixture that only exists during the run cannot be committed by accident.
    #
    #     The polarity is the inverse of what it was, and the inversion is the point. It used to warn
    #     when the skip list INCLUDED our registry, because an exemption depended on it not doing so.
    #     That exemption is gone — both ksvcs now carry Always — so skip-present is the handled state
    #     and silence is correct. What is worth reporting is the OPPOSITE change: if our registry ever
    #     leaves that list, digest resolution returns and the Always becomes a cost to re-examine.
    premise_off = {"kind": "KnativeServing", "spec": {"config": {"deployment": {}}}}
    premise_on = {"kind": "KnativeServing", "spec": {"config": {"deployment": {
        "registries-skipping-tag-resolving": INTERNAL_REGISTRY.rstrip("/")}}}}
    with tempfile.TemporaryDirectory() as tmp:
        for document, should_warn, label in ((premise_off, True, "no skip list"),
                                             (premise_on, False, "internal registry in skip list")):
            probe = pathlib.Path(tmp) / "knative-serving.yaml"
            probe.write_text(yaml.safe_dump(document), encoding="utf-8")
            probe_findings, derivations = knative_premise_findings(probe, label)
            if bool(probe_findings) != should_warn:
                failures.append(f"the Knative premise check gave the wrong answer for the {label} "
                                "case — the exemption's premise is not actually being re-derived.")
            if derivations != 1:
                failures.append(f"the Knative premise check reported {derivations} derivation(s) "
                                f"for the {label} case. That count is the only evidence the real "
                                "run has that this warn-only check ran at all.")
        # …and a missing CR must be reported, not read as "premise holds".
        absent_findings, absent_derivations = knative_premise_findings(
            pathlib.Path(tmp) / "absent.yaml", "absent")
        if not absent_findings or absent_derivations:
            failures.append("the Knative premise check reported nothing for a MISSING CR, which "
                            "would read as 'premise holds' the day the portfolio file moves.")
        # A file that parses but carries no KnativeServing derives nothing and must say so.
        empty_cr = pathlib.Path(tmp) / "empty.yaml"
        empty_cr.write_text(yaml.safe_dump({"kind": "ConfigMap"}), encoding="utf-8")
        if knative_premise_findings(empty_cr, "no KnativeServing")[1] != 0:
            failures.append("a CR file with no KnativeServing document claimed to have derived the "
                            "premise from it.")

    # The scope ledger is a library no CI step runs on its own; exercising it here is what stops it
    # from being an unrun gate. Then: every dimension collect_sites() raises must have a floor.
    failures += Scope.self_check()
    tree_scope = scope_for_tree()
    unfloored = [d for d in (*COLLECT_DIMENSIONS, "charts", "knative premise derivations")
                 if tree_scope.floor_for(d) is None]
    if unfloored:
        failures.append(f"scope_for_tree() declares no floor for {unfloored} — a dimension that is "
                        "measured but not judged proves nothing.")

    if failures:
        for failure in failures:
            print(f"::error::image-pull-policy-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2

    print("self-test ok — classifier, renderer, named-template walk, Template.objects[] walk, "
          "Knative exemption, unknown-shape blocker and the Knative premise check all behaved as "
          "declared, and the scope ledger fails an empty or truncated input set.")
    return 1


# --------------------------------------------------------------------------------- main


def discover_charts(root: pathlib.Path) -> list[pathlib.Path]:
    charts = sorted(p.parent for p in (root / "gitops/entry-states").glob("*/Chart.yaml"))
    if not charts:
        raise GuardError("no entry-state charts found under gitops/entry-states/*/Chart.yaml. The "
                         "repo ships two dozen, so an empty selection means this guard is broken — "
                         "refusing to pass on an empty scope.")
    return charts


def scope_for_tree() -> Scope:
    """The floors for a real-tree run. Measured 2026-08-01: 26 charts, 52 helm renders, 72 image
    sites at solve=false and 96 at solve=true, 4 kustomize builds carrying 10 sites, 1 Knative
    premise derivation. Each floor sits under the measurement and far over any truncation."""
    scope = Scope("image-pull-policy-guard")
    scope.require("charts", 20,
                  "gitops/entry-states ships 26 charts; a smaller number means discover_charts() "
                  "stopped matching, not that six were deleted.")
    scope.require("helm renders", 40, "two renders per chart, both value sets.")
    scope.require("solve=false image sites", 40, "image references in the default world.")
    scope.require("solve=true image sites", 55,
                  "solve worlds materialize workloads the default render never emits, so this is "
                  "the LARGER half. Zero means the solve=true render was dropped — the exact half "
                  "where a real Route and a real pull-policy defect have hidden before.")
    scope.require("kustomize builds", len(KUSTOMIZE_DIRS),
                  "every declared overlay in KUSTOMIZE_DIRS must be built. This half renders with a "
                  "different tool and is the easiest to drop without the run looking any different.")
    scope.require("kustomize image sites", 8,
                  "the promotion overlays and the rollouts dir carry 10 image references; a build "
                  "that emits none is a kustomization that stopped selecting resources.")
    scope.require("knative premise derivations", 1,
                  "the exemption's premise is re-derived from the portfolio CR on every run. This "
                  "check is WARN-ONLY, so nothing else notices when it stops answering.")
    return scope


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="scan the canary fixtures instead of the tree; a result other than 1 "
                             "means detection is unproven, not that the tree is fine")
    parser.add_argument("--list-images", action="store_true",
                        help="print every image found and how it is classified, then exit")
    args = parser.parse_args(argv)

    root = repo_root()

    if args.self_test:
        try:
            return self_test(root)
        except GuardError as exc:
            print(f"::error::image-pull-policy-guard self-test could not run: {exc}", file=sys.stderr)
            return 2

    scope = scope_for_tree()
    try:
        charts = discover_charts(root)
        scope.add("charts", len(charts))
        sites, counts = collect_sites(root, charts, KUSTOMIZE_DIRS)
        scope.merge(counts)
    except GuardError as exc:
        print(f"::error::image-pull-policy-guard: {exc}", file=sys.stderr)
        return 2

    if args.list_images:
        for image in sorted({s["image"] for s in sites}):
            marker = "WORKSHOP" if is_workshop_image(image) else "upstream"
            print(f"{marker:9s} {image}")
        return 0

    violations, blockers, stats = evaluate(sites)

    premise_findings, derivations = check_knative_premise(root)
    scope.add("knative premise derivations", derivations)
    for line in premise_findings:
        print(f"::warning::image-pull-policy-guard: {line}")

    # Before reporting anything: did the run actually inspect what it claims to?
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if blockers:
        print("\n::error::image-pull-policy-guard cannot judge every workshop image:", file=sys.stderr)
        for blocker in blockers:
            print(f"  {blocker}", file=sys.stderr)
        return 2

    if violations:
        print(f"\nWorkshop-built images pulled with something other than {REQUIRED_POLICY}:")
        for violation in violations:
            print(f"  {violation}")
        print(f"\n::error::{len(violations)} workshop container(s) would keep serving a STALE image "
              "after a rebuild. Every image we build is rebuilt in place under a mutable tag, so "
              f"`imagePullPolicy: {REQUIRED_POLICY}` is what makes a restart actually land the new "
              "layers.", file=sys.stderr)
        return 1

    print(f"image-pull-policy-guard: clean — {scope.summary()}; "
          f"{stats['images']} image references seen, {stats['workshop']} workshop-built, "
          f"{stats['always']} with {REQUIRED_POLICY}, {stats['exempt']} declared-exempt.")
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
        print(f"::error::image-pull-policy-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
