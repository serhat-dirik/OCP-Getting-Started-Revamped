#!/usr/bin/env python3
"""crd-unknown-field-guard.py — a rendered CR must not carry a field its CRD does not define.

WHY THIS EXISTS (the defect it would have caught, fixed 2026-08-06 in 9c97d80). The
ai-assisted-development entry state shipped a DevWorkspace carrying `spec.template.schemaVersion`
and `spec.template.metadata`. Neither field is in the DevWorkspace CRD's structural schema —
`spec.template` is a DevWorkspaceTemplateSpec, not a devfile document — and that CRD sets no
`x-kubernetes-preserve-unknown-fields`. The API server therefore PRUNED both at admission: they
appear in `kubectl.kubernetes.io/last-applied-configuration`, they never appear in the persisted
object, and Argo CD's three-way diff compared a manifest that declares them against a live object
that cannot ever hold them. `entry-ai-assisted-development-*` read **OutOfSync forever** on an
otherwise-healthy world, nobody could explain the red, and the accepted story became "operator
defaulting" — which was wrong. Permanent red is not free: it trains attendees and SAs to ignore red.

That whole class is mechanically detectable without a cluster, which is what this file does:

    render every chart AND every portfolio overlay that ships custom resources
      → for each rendered CR, look up its CRD's openAPIV3Schema in a CHECKED-IN SNAPSHOT
      → walk the object against the schema
      → report any field the schema does not define

TWO RENDER PATHS, because the repo has two. `gitops/**` and `helm/**` are Helm charts and render with
`helm template`; `platform-portfolio/**` is kustomize and renders with `kustomize build --enable-helm`
(the same pin and the same flag as the `kustomize` job in .github/workflows/lint.yml — one component,
sonarqube, inflates an upstream chart). Neither path is a grep: a CR assembled from a named template,
or one that only exists after a patch is applied, is invisible to a pattern match.

THE THREE OUTCOMES ARE DELIBERATELY DISTINCT, and the third is the point. This project's recurring
defect is a gate that goes green over something it never inspected, so "I had no schema for this
kind" must not be spelled the same way as "I checked it and it was clean":

    rc 0   every custom resource was CHECKED against a real schema and every field is defined
    rc 1   a rendered CR carries a field its CRD does not define — it will be pruned at admission
    rc 2   the guard COULD NOT INSPECT what it claims to: a CR whose CRD has no snapshot, a chart
           helm refuses to render, a collapsed scope, or a crash

A new custom-resource kind therefore REDDENS CI until someone captures its schema. That is the
intended cost. The alternative — skipping what we have no schema for — is the exact shape of every
false-pass in this repo's history.

WHY A SNAPSHOT AND NOT A LIVE CLUSTER. CI has no cluster, and a guard that only runs on a laptop is
a guard that does not run. `--capture` re-takes the snapshots from a live cluster (see below); the
plain run reads only files.

WHAT "UNKNOWN FIELD" MEANS, PRECISELY. The walker implements the API server's PRUNING rule, not
JSON-Schema validation — it judges field NAMES against the structural schema and says nothing about
types, formats, required-ness or enums. Three things make a field legal, and getting any of them
wrong would produce a false positive, which here is worse than the bug because it blocks authoring:

  * the field is named in `properties` at that level;
  * the level sets `x-kubernetes-preserve-unknown-fields: true` — then ANY field is legal there
    (knative's Trigger `spec`, DevWorkspace's `spec.template.attributes`, Tekton's param defaults);
  * the level sets `additionalProperties` — it is a MAP, so any KEY is legal, and the values are
    walked against the additionalProperties schema (Tekton `spec.params[].properties.<name>` is a
    map whose values DO have a schema, and a typo inside one still prunes).

`x-kubernetes-preserve-unknown-fields` does NOT propagate into fields that ARE named in `properties`
— those resume ordinary pruning under their own schema — and the walker matches that.

WHICH PORTFOLIO OVERLAYS ARE RENDERED, and why it is not every directory that has a
kustomization.yaml. The portfolio is an Argo CD app-of-apps: a `stacks/<name>` overlay emits child
Applications, and a `components/<name>` overlay reaches a cluster ONLY when some stack's
kustomization actually lists the app file pointing at it. A stack may ship an app file that is
deliberately commented out (today: `stacks/observability/apps/loki-logging.yaml`, capacity-gated),
and such a component is not installed by any portfolio install.

So the render set is DERIVED from that wiring, exactly as the portfolio's own installer derives it:
every `stacks/*` overlay, plus `argocd-bootstrap/operator`, plus every component directory a rendered
stack Application actually points `spec.source.path` at. This is not a scope this file invented —
`platform-portfolio/argocd-bootstrap/lib-components.sh` (`kustomize_resources` / `active_app_files`,
shared by install.sh and hack/check-adoption-skip.sh) reads the resources list rather than globbing
`apps/*.yaml`, and its comment records the cost of globbing instead, verified on a live cluster on
2026-08-05: the glob attributes a commented-out component's operators to us and records
`created:` for operators that were never installed, which later licenses deleting an operator the
ORG installed. A guard that globbed would be asserting a different portfolio than the one that
ships.

The wiring is read from the RENDERED stacks, never from a second parse of the YAML, so there is no
discovery mechanism that can drift from the thing being checked. Every component the render set
leaves out is NAMED on every run, green or red — the count is not left to be inferred — and the day
someone uncomments an app file that component enters the render set automatically. If its CRDs have
no snapshot it will then read rc 2 UN-CHECKABLE, which is the correct and intended cost.

WHAT IS SKIPPED, and why that is not a hole. Built-in and aggregated kinds (core/v1, apps, batch,
rbac, route.openshift.io, build.openshift.io, image.openshift.io, template.openshift.io,
user.openshift.io, admissionregistration.k8s.io …) have no CRD, so there is no openAPIV3Schema to
walk and this mechanism does not apply to them. They are identified from a captured inventory of
every kind the cluster serves that is NOT backed by a CustomResourceDefinition — not from a
hardcoded list of group names, which would be recall rather than measurement. A kind that is in
neither the CRD snapshots nor that inventory is UN-CHECKABLE (rc 2), never skipped.

`objects[]` inside an `openshift.io/v1 Template` ARE walked: they are created as ordinary objects
once the template is processed, so a pruned field there prunes just the same.

WHAT THIS DOES NOT COVER, stated so nobody reads its green tick as more than it is:
  * Portfolio YAML that reaches a cluster WITHOUT passing through a kustomization. Measured
    2026-08-06: of 210 tracked YAML files under `platform-portfolio/`, four carry a custom resource
    that no `kustomize build` in this tree ever emits —
    `argocd-bootstrap/operator/argocd-controller-resources.yaml` (an ArgoCD CR, applied by
    install.sh with `oc apply -f`, not through `operator/kustomization.yaml`),
    `argocd-bootstrap/{appproject,stack-app}.template.yaml` (sed-substituted at bootstrap time and
    not parseable as YAML until then), and
    `components/sonarqube/node-tuning/sonarqube-vm-max-map-count.yaml` (a Tuned CR documented as a
    manual node prerequisite). Extending a RENDER guard to cover an imperative apply is a design
    question for the portfolio's owner, not something a lint file should decide on its own; it is
    reported as follow-up rather than silently covered or silently dropped.
  * Components no stack wires up — see the section above. Named on every run, never inferred.
  * VALUE correctness. A field with the right name and a nonsense value is this guard's blind spot;
    `helm lint` and the API server own that.
  * Aggregated API servers. Their decoding is not CRD pruning and is not modelled here.
  * ADMISSION WEBHOOKS, which are a separate mechanism and strictly stricter. Measured 2026-08-06:
    a knative Trigger carrying an unknown field under a `preserve-unknown-fields` spec is legal as
    far as CRD pruning is concerned — and `webhook.eventing.knative.dev` rejects the whole object
    anyway with "cannot decode incoming new object: json: unknown field". So a clean run here does
    NOT promise the cluster will accept a manifest; it promises the cluster will not silently drop
    part of it, which is the failure that produced permanent OutOfSync.

HOW THE RULES ABOVE WERE ESTABLISHED. Not from memory: every verdict in the canary was checked
against a live OpenShift 4.22.8 cluster on 2026-08-06 with `oc apply --dry-run=server` (which
persists nothing), by diffing the submitted object against the one the API server returned. All
eight planted fields came back pruned — including the closed-object and map-value cases, which are
the two rules most likely to be wrong — and every field the guard declines to flag survived.

USAGE
    tools/lint/crd-unknown-field-guard.py              # check the real tree
    tools/lint/crd-unknown-field-guard.py --self-test  # prove it fires; must exit EXACTLY 1
    tools/lint/crd-unknown-field-guard.py --capture    # re-take the snapshots (needs `oc`; not CI)
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    Same reason as every guard beside this one: module-level code runs before `__main__` exists, so
    a bad constant or a failed import crashes with Python's default rc 1 — which is exactly what
    CI's `--self-test must exit EXACTLY 1` reads as "the canary fired". Installed as the first
    statement after the imports so it is already in place before anything below can fail; `os._exit`
    is what makes the code stick, because an excepthook cannot change the exit status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::crd-unknown-field-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    import yaml
except Exception as exc:  # noqa: BLE001 — deliberately broad
    print(f"::error::crd-unknown-field-guard: cannot import PyYAML ({exc}) — the guard could not "
          f"start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — NOT `except ImportError`: a _scope.py that fails to PARSE
    # raises SyntaxError, sails past an ImportError-only handler, and exits 1 — CI's "the canary
    # fired". Anything at all going wrong while loading the ledger means this guard cannot start.
    print(f"::error::crd-unknown-field-guard: cannot import _scope ({exc}) — the guard could not "
          f"start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)


# tools/lint/<this file> -> tools/lint -> tools -> repo root.
REPO = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = REPO / "tools/lint/crd-unknown-field-guard.fixtures"
SCHEMA_DIR = FIXTURES / "schemas"
INDEX_FILE = FIXTURES / "index.json"
BUILTIN_FILE = FIXTURES / "builtin-kinds.json"
CANARY = REPO / "tools/lint/crd-unknown-field-guard.canary"

# Every chart in the repo, with the values it needs to render. DECLARED rather than globbed for the
# three non-entry-state charts because each needs different values; the 26 entry states ARE globbed,
# so a new module is covered the day it lands instead of the day someone remembers this list.
#
# `gitops/user-namespace` ships NO custom resources today (measured 2026-08-06: Namespace,
# ResourceQuota, LimitRange, RoleBinding — all built-in). It is rendered anyway, for one line of
# cost, so that the day it grows one the CR is checked rather than silently outside the scope.
ENTRY_STATES = REPO / "gitops/entry-states"
EXTRA_CHARTS = (
    ("gitops/workshop-config", {"user": "user1", "clusterDomain": "example.com"}),
    ("helm/bootstrap", {"user": "user1", "clusterDomain": "example.com"}),
    # helm's --set splits on commas, so a comma-joined scalar must arrive backslash-escaped. The
    # chart rejects an empty `suffixes` outright (it is a scalar string it splits itself, because
    # Argo's helm.parameters does not expand `{a,b,c}` list literals), so there is no rendering it
    # without one.
    ("gitops/user-namespace", {"user": "user1", "suffixes": r"dev\,stage\,prod"}),
)

# A LITERAL, deliberately not len(EXTRA_CHARTS): the point is that shrinking the declared list must
# not be able to shrink its own floor. self_test() asserts the two agree, so adding or removing a
# chart means re-stating the number in the same change.
MIN_EXTRA_CHARTS = 3

# The kustomize half. `platform-portfolio/` is the workshop-agnostic GitOps installer; the same
# functions run against the canary's miniature portfolio, so the wiring rule is proven by the code
# that implements it rather than by a re-implementation of it.
PORTFOLIO = REPO / "platform-portfolio"

# Overlays rendered whatever the wiring says, because nothing points a stack Application at them:
# `stacks/*` IS the wiring, and `argocd-bootstrap/operator` is the one imperative step the
# architecture allows (install.sh runs `oc apply -k operator/`), so it ships on every cluster.
# Missing means rc 2, never a quiet skip — see portfolio_jobs().
PORTFOLIO_ALWAYS = ("argocd-bootstrap/operator",)
MIN_PORTFOLIO_ALWAYS = 1

# The two worlds every entry state renders. An entry state materializes MORE workloads at solve=true
# (that is what `ws solve` means), and dropping that half is a blinding this repo has measured twice
# — so the two are counted separately and floored separately.
SOLVE_WORLDS = ("false", "true")

# Fields the API server always accepts at the ROOT of any custom resource, whatever the schema says.
# `metadata` is ObjectMeta, handled by the standard decoder rather than by CRD pruning — most CRD
# schemas declare it as a bare `type: object` with no properties, so walking into it would flag
# `name`, `labels` and `annotations` on EVERY object in the repo. That would be the false positive
# that gets a guard switched off. Note this applies to the ROOT only: a `metadata` nested deeper —
# `spec.template.metadata`, which is half of the defect this file exists for — is an ordinary field
# and is walked like any other.
ROOT_ALWAYS_ALLOWED = ("apiVersion", "kind", "metadata")

# The dimensions the working functions raise. Named once so the counters and their floors cannot
# drift apart; self_test asserts every one of them has a floor, because a measurement nobody judges
# is not a measurement.
WALK_DIMENSIONS = (
    "custom resources checked",
    "built-in resources skipped",
    "template objects walked",
    "fields walked",
    "preserve-unknown-fields nodes honoured",
    "free-form map nodes honoured",
)
RENDER_DIMENSIONS = (("helm renders", "kustomize renders", "portfolio custom resources")
                     + tuple(f"solve={w} custom resources" for w in SOLVE_WORLDS))


class GuardError(Exception):
    """The guard could not inspect something it claims to inspect. Always rc 2, never rc 1."""


# ────────────────────────────────────────────────────────────── the schema, as the API server reads it


def preserves_unknown(schema: dict) -> bool:
    """True when this level accepts ANY field, so nothing here can be pruned.

    The single most important predicate in the file: every false POSITIVE this guard could produce
    is a level where this wrongly returns False.
    """
    return schema.get("x-kubernetes-preserve-unknown-fields") is True


def is_free_form_map(schema: dict) -> bool:
    """True when this level is a MAP — arbitrary keys, values validated by additionalProperties.

    Kept separate from preserves_unknown because the two are not the same rule: a map's keys are
    unconstrained but its VALUES still have a schema, and a typo inside one of those values prunes
    exactly like any other unknown field (Tekton's `spec.params[].properties.<name>.type` is the
    live example in this tree).
    """
    return "additionalProperties" in schema


def is_embedded_resource(schema: dict) -> bool:
    """True when this level holds a whole Kubernetes object, so apiVersion/kind/metadata are legal
    here even though the schema does not name them (DevWorkspace's `custom.embeddedResource`)."""
    return schema.get("x-kubernetes-embedded-resource") is True


def is_closed_object(schema: dict) -> bool:
    """True when the schema says 'object' and names NOTHING — so the API server prunes every field.

    This is a real pruning outcome, not an oddity, but it is separated from the ordinary
    'not in properties' case because the two are worth telling apart in a report: one means you
    misspelt a field, the other means the whole subtree cannot be stored at all.

    A node with no `type` at all is NOT closed — it is a node whose structure this snapshot cannot
    describe, and the walker says nothing about those rather than guessing.
    """
    return (schema.get("type") == "object"
            and not schema.get("properties")
            and not is_free_form_map(schema)
            and not preserves_unknown(schema)
            and not is_embedded_resource(schema))


def is_builtin(group: str, kind: str, builtin_kinds: set) -> bool:
    """True when the cluster serves this kind WITHOUT a CustomResourceDefinition behind it.

    Measured, not recalled: the set comes from a captured inventory of every served kind minus every
    CRD-backed one. A hardcoded list of 'core-looking' group names is exactly the kind of memory
    this repo has been burnt by — `route.openshift.io` and `template.openshift.io` look like
    operator groups and are not, `kueue.openshift.io` looks built-in and is a CRD.
    """
    return f"{group}/{kind}" in builtin_kinds


# ────────────────────────────────────────────────────────────────────────────────── the report


class Report:
    """Every finding this guard can make, recorded through ONE method.

    Each public recorder is a single `self._record(…)` call, so blinding any one of them silences
    exactly one finding kind and nothing else — which is what makes each independently provable by
    the canary (tools/lint/_canary-coverage.py sweeps these three sites).
    """

    def __init__(self):
        self.rows: list[dict] = []

    def _record(self, severity: str, source: str, subject: str, detail: str) -> None:
        self.rows.append({"severity": severity, "source": source,
                          "subject": subject, "detail": detail})

    def unknown_field(self, source: str, subject: str, path: str, why: str) -> None:
        self._record("unknown-field", source, subject, f"{path} — {why}")

    def uncheckable(self, source: str, subject: str, why: str) -> None:
        self._record("uncheckable", source, subject, why)

    def render_failed(self, source: str, subject: str, why: str) -> None:
        self._record("render-failed", source, subject, why)

    def of(self, severity: str) -> list:
        return [r for r in self.rows if r["severity"] == severity]

    def paths(self) -> set:
        """(subject-kind, field-path) for every unknown-field row — the shape the canary asserts."""
        return {(r["subject"].split("/")[0], r["detail"].split(" — ")[0])
                for r in self.of("unknown-field")}


# ─────────────────────────────────────────────────────────────────────────────────── the walk


def walk(value, schema: dict, path: list, source: str, subject: str,
         report: Report, counts: dict) -> None:
    """Walk a rendered value against its schema node, recording every field that would be pruned.

    The counters are raised HERE, by the loops doing the work, so a blinded walk collapses a scope
    dimension instead of quietly shrinking the input set (tools/lint/_scope.py explains why that
    distinction is the whole point).
    """
    if not isinstance(schema, dict):
        return
    if isinstance(value, dict):
        if preserves_unknown(schema):
            counts["preserve-unknown-fields nodes honoured"] += 1
            # Anything unnamed is legal AND preserved verbatim, so there is nothing below it to
            # judge. Fields that ARE named resume ordinary pruning under their own schema —
            # preserve does not propagate into them.
            props = schema.get("properties") or {}
            for key, child in value.items():
                if key in props:
                    counts["fields walked"] += 1
                    walk(child, props[key], path + [key], source, subject, report, counts)
            return
        if is_free_form_map(schema):
            counts["free-form map nodes honoured"] += 1
            child_schema = schema["additionalProperties"]
            if isinstance(child_schema, dict):
                for key, child in value.items():
                    counts["fields walked"] += 1
                    walk(child, child_schema, path + [f"[{key}]"], source, subject, report, counts)
            return
        if is_closed_object(schema):
            for key in value:
                report.unknown_field(
                    source, subject, ".".join(path + [key]),
                    "the CRD schema declares this level as an object with NO fields at all and no "
                    "x-kubernetes-preserve-unknown-fields, so the whole subtree is pruned at "
                    "admission and can never be stored")
            return
        props = schema.get("properties") or {}
        if not props:
            # No type, no properties: a node whose structure the snapshot does not describe. Saying
            # nothing is deliberate — a guess here is a false positive, and a false positive blocks
            # authoring, which is worse than the defect this file catches.
            return
        embedded = is_embedded_resource(schema)
        for key, child in value.items():
            if embedded and key in ROOT_ALWAYS_ALLOWED:
                continue
            if key not in props:
                report.unknown_field(
                    source, subject, ".".join(path + [key]),
                    f"the CRD schema does not define it at this level (it defines "
                    f"{', '.join(sorted(props)[:8])}{'…' if len(props) > 8 else ''}). Kubernetes "
                    f"PRUNES unknown fields at admission: it will sit in last-applied, never in the "
                    f"stored object, and Argo CD will read OutOfSync forever")
                continue
            counts["fields walked"] += 1
            walk(child, props[key], path + [key], source, subject, report, counts)
    elif isinstance(value, list):
        item_schema = schema.get("items")
        if not isinstance(item_schema, dict):
            return
        for index, element in enumerate(value):
            walk(element, item_schema, path + [f"[{index}]"], source, subject, report, counts)


def check_document(doc: dict, source: str, store: dict, builtin_kinds: set,
                   report: Report, counts: dict) -> str:
    """Judge one rendered document. Returns its verdict: checked / builtin / uncheckable."""
    api_version = doc.get("apiVersion") or ""
    kind = doc.get("kind") or ""
    group, _, version = api_version.rpartition("/")
    subject = f"{kind}/{(doc.get('metadata') or {}).get('name', '?')}"

    if not group or is_builtin(group, kind, builtin_kinds):
        counts["built-in resources skipped"] += 1
        return "builtin"

    schema = store.get((group, version, kind))
    if schema is None:
        report.uncheckable(
            source, subject,
            f"no CRD schema snapshot for {api_version} {kind}. This is NOT a pass — the guard could "
            f"not inspect it. Capture it on a cluster where that CRD is installed:\n"
            f"      tools/lint/crd-unknown-field-guard.py --capture")
        return "uncheckable"

    counts["custom resources checked"] += 1
    body = {k: v for k, v in doc.items() if k not in ROOT_ALWAYS_ALLOWED}
    walk(body, schema, [], source, subject, report, counts)
    return "checked"


def documents_in(rendered: str, source: str):
    """Every document a render produced, INCLUDING the objects nested in an OpenShift Template.

    A Template's `objects[]` are created as ordinary objects once `oc process` has substituted its
    parameters, so a field the CRD does not define prunes there exactly as it would anywhere else.
    Parameter placeholders (`${NAME}`) are string VALUES and never field names, so they cannot
    confuse a field-name walk.
    """
    try:
        docs = list(yaml.safe_load_all(rendered))
    except yaml.YAMLError as exc:
        raise GuardError(f"{source} rendered output that is not parseable as YAML: {exc}") from exc
    for doc in docs:
        if not isinstance(doc, dict) or not doc.get("kind"):
            continue
        yield doc, False
        if doc.get("kind") == "Template":
            for nested in doc.get("objects") or []:
                if isinstance(nested, dict) and nested.get("kind"):
                    yield nested, True


def render(chart: pathlib.Path, values: dict) -> str:
    if shutil.which("helm") is None:
        raise GuardError(
            "helm is not on PATH. This guard RENDERS the charts rather than grepping them — a CR "
            "assembled from a named template in _helpers.tpl is invisible to a grep — so it cannot "
            "run without it. Refusing to report clean.")
    cmd = ["helm", "template", "t", str(chart)]
    for key, value in values.items():
        cmd += ["--set", f"{key}={value}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, cwd=REPO)
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip().splitlines()
        raise GuardError(f"`helm template` failed (rc={proc.returncode}): "
                         f"{tail[-1] if tail else 'no stderr'}")
    return proc.stdout


def render_overlay(overlay: pathlib.Path) -> str:
    """`kustomize build` one portfolio overlay.

    `--enable-helm` and the same kustomize pin as the `kustomize` job in lint.yml, because one
    component (sonarqube) inflates an upstream chart through `helmCharts:` and would otherwise
    render nothing at all.
    """
    if shutil.which("kustomize") is None:
        raise GuardError(
            "kustomize is not on PATH. The portfolio overlays are kustomize, not Helm, and this "
            "guard RENDERS them — a CR that only exists after a patch is applied is invisible to a "
            "grep — so it cannot run without it. Refusing to report clean.")
    proc = subprocess.run(["kustomize", "build", "--enable-helm", str(overlay)],
                          capture_output=True, text=True, check=False, cwd=REPO)
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip().splitlines()
        raise GuardError(f"`kustomize build --enable-helm` failed (rc={proc.returncode}): "
                         f"{tail[-1] if tail else 'no stderr'}")
    return proc.stdout


def judge(rendered: str, label: str, store: dict, builtin_kinds: set, report: Report,
          counts: dict, solve: str | None = None, portfolio: bool = False) -> None:
    """Judge every document one render produced. The shared half of both render paths.

    Helm and kustomize differ only in how the YAML is produced; what happens to it afterwards must
    be identical, so it is written once. The counters are raised HERE, by the loop doing the work.
    """
    for doc, nested in documents_in(rendered, label):
        if nested:
            counts["template objects walked"] += 1
        verdict = check_document(doc, label, store, builtin_kinds, report, counts)
        if verdict != "checked":
            continue
        if solve in SOLVE_WORLDS:
            counts[f"solve={solve} custom resources"] += 1
        if portfolio:
            counts["portfolio custom resources"] += 1


def check_chart(chart: pathlib.Path, values: dict, label: str, store: dict, builtin_kinds: set,
                report: Report) -> dict:
    """Render one chart under one value set and judge every document it produced.

    Returns the scope counters this call raised. They are produced by the loops that did the work —
    never re-derived by the caller — so a blinded check_chart collapses a floor rather than
    reporting a clean scan of nothing.
    """
    counts = {d: 0 for d in WALK_DIMENSIONS + RENDER_DIMENSIONS}
    try:
        rendered = render(chart, values)
    except GuardError as exc:
        report.render_failed(label, chart.name,
                             f"{exc} A chart that will not render is a chart this guard did not "
                             f"check; skipping it would turn a broken chart into a passing gate.")
        return counts
    counts["helm renders"] += 1
    judge(rendered, label, store, builtin_kinds, report, counts, solve=values.get("solve"))
    return counts


def check_overlay(overlay: pathlib.Path, label: str, store: dict, builtin_kinds: set,
                  report: Report) -> dict:
    """`kustomize build` one portfolio overlay and judge every document it produced.

    Counted on its own dimensions rather than folded into the Helm ones: the two halves must be able
    to collapse independently, or a kustomize path that stops rendering hides behind 55 healthy Helm
    renders and the total still clears its floor.
    """
    counts = {d: 0 for d in WALK_DIMENSIONS + RENDER_DIMENSIONS}
    try:
        rendered = render_overlay(overlay)
    except GuardError as exc:
        report.render_failed(label, overlay.name,
                             f"{exc} An overlay that will not render is an overlay this guard did "
                             f"not check; skipping it would turn a broken overlay into a passing "
                             f"gate.")
        return counts
    counts["kustomize renders"] += 1
    judge(rendered, label, store, builtin_kinds, report, counts, portfolio=True)
    return counts


# ────────────────────────────────────────────────────────────────────── the checked-in snapshots


def load_snapshots(fixtures: pathlib.Path) -> tuple[dict, set, dict]:
    """(schemas by (group, version, kind), built-in kind set, index).

    Every failure here is rc 2 by way of GuardError: a guard that cannot read its own reference data
    has not inspected anything, and must not be able to say so quietly.
    """
    index_file = fixtures / "index.json"
    builtin_file = fixtures / "builtin-kinds.json"
    if not index_file.is_file():
        raise GuardError(f"{index_file} is missing. The schema snapshots are this guard's entire "
                         f"reference data; without them it inspects nothing. Re-capture with "
                         f"`tools/lint/crd-unknown-field-guard.py --capture` on a cluster.")
    index = json.loads(index_file.read_text())
    if not builtin_file.is_file():
        raise GuardError(f"{builtin_file} is missing — without it every built-in kind reads as "
                         f"un-checkable and nothing can pass.")
    builtin_kinds = set(json.loads(builtin_file.read_text())["kinds"])
    if not builtin_kinds:
        raise GuardError(f"{builtin_file} lists no kinds at all.")

    store: dict = {}
    entries = index.get("crds") or []
    if not entries:
        raise GuardError(f"{index_file} declares no CRDs. An empty snapshot set cannot fail.")
    for entry in entries:
        path = fixtures / entry["file"]
        if not path.is_file():
            raise GuardError(f"{index_file.name} names {entry['file']}, which does not exist. A "
                             f"snapshot referenced but absent is a kind that silently stops being "
                             f"checked.")
        snapshot = json.loads(path.read_text())
        for version, schema in snapshot["versions"].items():
            store[(snapshot["group"], version, snapshot["kind"])] = schema
    return store, builtin_kinds, index


def chart_jobs() -> list:
    """("helm", chart path, values, label) for every Helm render the real run performs."""
    entry_charts = sorted(p.parent for p in ENTRY_STATES.glob("*/Chart.yaml"))
    jobs = [("helm", chart, {"user": "user1", "clusterDomain": "example.com", "solve": solve},
             f"gitops/entry-states/{chart.name} (solve={solve})")
            for chart in entry_charts for solve in SOLVE_WORLDS]
    jobs += [("helm", REPO / rel, dict(values), rel) for rel, values in EXTRA_CHARTS]
    return jobs


def portfolio_jobs(root: pathlib.Path = PORTFOLIO) -> tuple[list, list]:
    """(jobs, overlays deliberately NOT rendered) for one app-of-apps portfolio.

    Parameterised by root so the canary drives THIS function over a miniature portfolio of its own,
    rather than a re-implementation of the wiring rule that could pass while the real one is broken.

    The wiring is read from the RENDERED stacks — `spec.source.path` on each child Application — and
    never from a second parse of the stack YAML. One mechanism means there is nothing for the check
    to drift away from: whatever Argo CD would be told to sync is exactly what gets rendered here.
    """
    stacks = sorted(p.parent for p in (root / "stacks").glob("*/kustomization.yaml"))
    if not stacks:
        raise GuardError(f"{root}/stacks contains no kustomization.yaml at all. The stacks ARE the "
                         f"app-of-apps; an empty set means discovery broke, and every component "
                         f"would then look unwired and go unchecked.")
    always = []
    for rel in PORTFOLIO_ALWAYS:
        if not (root / rel / "kustomization.yaml").is_file():
            raise GuardError(f"{root / rel} has no kustomization.yaml. It is rendered "
                             f"unconditionally because it ships on every cluster; a missing one is "
                             f"a move nobody told this guard about, not a component to skip.")
        always.append(root / rel)

    prefix = f"{root.relative_to(REPO).as_posix()}/"
    wired: dict = {}
    for stack in stacks:
        for doc, _ in documents_in(render_overlay(stack), str(stack)):
            if doc.get("kind") != "Application":
                continue
            path = ((doc.get("spec") or {}).get("source") or {}).get("path") or ""
            if not path.startswith(prefix):
                continue
            target = REPO / path
            if not (target / "kustomization.yaml").is_file():
                raise GuardError(
                    f"{stack.name} points an Application at '{path}', which has no "
                    f"kustomization.yaml. Argo CD would fail to sync it — and this guard cannot "
                    f"render it, so it must say so rather than quietly drop it from the scope.")
            wired.setdefault(target, []).append(stack.name)

    jobs = [("kustomize", overlay, None, overlay.relative_to(REPO).as_posix())
            for overlay in stacks + always + sorted(wired)]
    unwired = [p.parent for p in sorted((root / "components").glob("*/kustomization.yaml"))
               if p.parent not in wired]
    return jobs, unwired


def unwired_note(unwired: list) -> str:
    """What the render set leaves out, printed on EVERY run — green or red.

    A scope that narrows itself must announce the narrowing at the point of detection, or the day
    someone comments out an app file to quieten something, the guard goes on printing the same ✅
    over a smaller world. Same reasoning as tools/lint/LEDGERS.md C2, applied to a render scope
    rather than to a declared-debt entry: this is not a waiver of a detected defect — nothing was
    detected and then forgiven — but it IS a decision about what gets looked at, so it is said out
    loud with its own reason every time.
    """
    if not unwired:
        return ("ℹ️  every component overlay in the portfolio is wired into a stack and was "
                "rendered, so this run's scope carries no exceptions.")
    lines = [f"ℹ️  {len(unwired)} component overlay(s) NOT rendered — no stack Application points "
             f"at them, so no portfolio install deploys them:"]
    for overlay in unwired:
        lines.append(f"     · {overlay.relative_to(REPO).as_posix()}")
    lines.append("   They enter this guard's scope automatically the moment a stack's "
                 "kustomization.yaml lists their app file. If their CRDs have no snapshot then, "
                 "the run turns rc 2 UN-CHECKABLE — capture first, on a cluster carrying those "
                 "operators: tools/lint/crd-unknown-field-guard.py --capture")
    return "\n".join(lines)


def scope_for_tree() -> Scope:
    """The floors for a real-tree run.

    Re-measured 2026-08-06 after the portfolio half landed: 29 charts and 46 portfolio overlays, 55
    helm renders and 46 kustomize renders, 51 CRD snapshots loaded, 191 custom resources checked
    (18 at solve=false, 30 at solve=true, 42 from the three extra charts which have no solve world,
    and 101 from the portfolio), 1148 built-in resources skipped, 5 Template objects walked, 3750
    fields walked, 31 preserve nodes and 78 free-form map nodes honoured.

    THE TWO HALVES ARE FLOORED SEPARATELY, which is the whole reason `kustomize renders` and
    `portfolio custom resources` exist as their own dimensions. Folded into the shared totals, the
    entire portfolio half could stop rendering and the run would still clear a floor set for the
    Helm half — 191 minus 101 is 90, which is what the tree measured yesterday. The shared floors
    below therefore stay generous (they exist to catch the shared machinery collapsing); each half
    is caught by its own.

    Every floor sits well under its measurement so ordinary churn does not redden main, and far
    above what any plausible truncation produces (1, or one directory's worth).
    """
    scope = Scope("crd-unknown-field-guard")
    scope.require("charts", 25,
                  "26 entry states plus 3 declared extras. A smaller number means discovery stopped "
                  "matching (a renamed Chart.yaml, a truncated glob), not that charts were deleted.")
    scope.require("portfolio overlays", 40,
                  "14 stacks + argocd-bootstrap/operator + the 31 components some stack wires up. A "
                  "collapse here is the wiring discovery failing, which would silently shrink the "
                  "portfolio half to the stacks alone while every other number looked healthy.")
    scope.require("CRD schemas loaded", 45,
                  "the checked-in snapshots. Zero or a handful means the fixtures moved and every "
                  "custom resource would read un-checkable.")
    scope.require("helm renders", 45,
                  "two `helm template` renders per entry state plus one each for the extras. Losing "
                  "half of these is how a whole world stops being checked while the run says clean.")
    scope.require("kustomize renders", 40,
                  "one `kustomize build` per rendered overlay. Zero means the portfolio half stopped "
                  "running entirely — the exact blinding this dimension was split out to catch.")
    scope.require("custom resources checked", 140,
                  "the resources this guard exists to judge. This is the dimension that collapses "
                  "if the built-in skip ever widens past genuinely CRD-less kinds.")
    scope.require("portfolio custom resources", 70,
                  "the operand CRs the portfolio ships — Central, SecuredCluster, Securesign, "
                  "Backstage, TempoMonolithic, CheCluster, OLSConfig, Tackle and the rest. They are "
                  "the largest hand-written CRs in the repo and the reason this half exists.")
    scope.require("solve=false custom resources", 12,
                  "the default world's custom resources. Fewer than the solve world by design — a "
                  "solve world materializes MORE — so the two floors are not the same number.")
    scope.require("solve=true custom resources", 20,
                  "the solve world's. Zero here means the solve=true render was dropped — a "
                  "blinding this repo has measured on two other guards.")
    scope.require("built-in resources skipped", 700,
                  "Deployments, Roles, Namespaces and the rest. Zero means the built-in inventory "
                  "stopped loading, and every one of them would then read un-checkable.")
    scope.require("template objects walked", 3,
                  "objects nested inside an OpenShift Template. Zero means the Template descent was "
                  "dropped and a CR could hide inside one.")
    scope.require("fields walked", 2200,
                  "fields actually compared against a schema. This is the ONE dimension a walk that "
                  "returns early everywhere cannot fake: no fields walked, no checking done.")
    scope.require("preserve-unknown-fields nodes honoured", 12,
                  "levels where the schema legalises any field. Zero means that rule stopped being "
                  "consulted, which would turn every legal wild field into a false positive.")
    scope.require("free-form map nodes honoured", 30,
                  "levels that are maps. Same reasoning as preserve: this rule going silent shows "
                  "up as false positives on every label and annotation map in the tree.")
    return scope


# ──────────────────────────────────────────────────────────────────────────────────── the run


def run(fixtures: pathlib.Path, jobs: list, scope: Scope | None) -> tuple[Report, dict]:
    """Render and judge everything. Returns (report, counters). Raises GuardError for rc 2."""
    store, builtin_kinds, index = load_snapshots(fixtures)
    report = Report()
    totals: dict = {d: 0 for d in WALK_DIMENSIONS + RENDER_DIMENSIONS}
    if scope is not None:
        scope.add("charts", len({job[1] for job in jobs if job[0] == "helm"}))
        scope.add("portfolio overlays", len({job[1] for job in jobs if job[0] == "kustomize"}))
        scope.add("CRD schemas loaded", len(index.get("crds") or []))
    for kind, target, values, label in jobs:
        if kind == "helm":
            counts = check_chart(target, values, label, store, builtin_kinds, report)
        elif kind == "kustomize":
            counts = check_overlay(target, label, store, builtin_kinds, report)
        else:
            # An unreachable branch that is written anyway: a job shape nobody handles would
            # otherwise be a job that silently contributes nothing while the totals still clear
            # their floors.
            raise GuardError(f"unknown job kind {kind!r} for {label} — the guard does not know how "
                             f"to render it, which is not the same as there being nothing to check.")
        for dimension, value in counts.items():
            totals[dimension] += value
    if scope is not None:
        scope.merge(totals)
    return report, totals


def report_and_exit(report: Report, scope: Scope | None, headline: str, quiet: bool = False) -> int:
    """0 clean / 1 a field will be pruned / 2 something could not be inspected.

    `quiet` is for self_test(), whose canary reports are SUPPOSED to be non-clean: printing their
    `::error::` lines on a passing run would put red annotations on a green CI log and teach readers
    to skim past that string — the same reason Scope.enforce() has the flag.
    """
    def shout(text):
        if not quiet:
            print(text, file=sys.stderr)

    blocked = report.of("render-failed") + report.of("uncheckable")
    if blocked:
        shout(f"::error::crd-unknown-field-guard: {len(blocked)} resource(s) or chart(s) COULD NOT "
              f"BE CHECKED. This is not a clean result — it is an uninspected one.")
        for row in blocked:
            shout(f"  ❌ {row['source']}: {row['subject']}\n     {row['detail']}")
        return 2
    if scope is not None:
        collapsed = scope.enforce(quiet=quiet)
        if collapsed:
            return collapsed
    findings = report.of("unknown-field")
    if findings:
        shout("::error::a rendered custom resource carries a field its CRD does not define. "
              "Kubernetes prunes unknown fields at admission, so the field lands in last-applied "
              "and never in the stored object — and Argo CD then reads OutOfSync forever on a "
              "healthy world. Delete the field; do not waive the diff.")
        for row in findings:
            shout(f"  ❌ {row['source']}: {row['subject']}\n     {row['detail']}")
        return 1
    if not quiet:
        print(f"✅ crd-unknown-field-guard: clean — {headline}.")
    return 0


# ───────────────────────────────────────────────────────────────────────────────── --capture


def prune_schema(node):
    """Reduce an openAPIV3Schema to the structure PRUNING depends on, and nothing else.

    Kept small for a reason: a checked-in fixture nobody can read is a fixture nobody reviews. The
    full schemas for these 51 CRDs are ~6.6MB; descriptions, defaults, enums, formats and validation
    keywords play no part in whether a field survives admission, so they are dropped and what is
    left (~2.1MB) is a readable field-name tree.

    Logical junctors are MERGED into the parent here rather than interpreted at check time. A
    structural schema may only add value validations inside allOf/anyOf/oneOf — the structure lives
    outside them — so folding their `properties` in can only ever WIDEN what this guard considers
    legal. That direction is deliberate: the failure it risks is a missed finding, never a false
    positive on a field that is in fact legal.
    """
    if not isinstance(node, dict):
        return {}
    out: dict = {}
    # `type` is kept ONLY for objects, and only because is_closed_object() needs to tell "the schema
    # says object and names nothing, so everything here prunes" from "this snapshot does not
    # describe this node's structure, so say nothing". Every other type is irrelevant to pruning, so
    # a string leaf snapshots as `{}` — which is what keeps these fixtures a readable field-name
    # tree instead of a 2.4MB dump nobody reviews.
    if node.get("type") == "object":
        out["type"] = "object"
    for key in ("x-kubernetes-preserve-unknown-fields", "x-kubernetes-embedded-resource"):
        if key in node:
            out[key] = node[key]
    merged = [node] + [sub for junctor in ("allOf", "anyOf", "oneOf")
                       for sub in (node.get(junctor) or []) if isinstance(sub, dict)]
    properties = {name: prune_schema(child)
                  for source in merged for name, child in (source.get("properties") or {}).items()}
    if properties:
        out["properties"] = properties
    for source in merged:
        if "additionalProperties" in source and "additionalProperties" not in out:
            value = source["additionalProperties"]
            out["additionalProperties"] = prune_schema(value) if isinstance(value, dict) else value
        if isinstance(source.get("items"), dict) and "items" not in out:
            out["items"] = prune_schema(source["items"])
        if source.get("x-kubernetes-preserve-unknown-fields") is True:
            out["x-kubernetes-preserve-unknown-fields"] = True
    return out


def capture_jobs() -> list:
    """Every render a CAPTURE walks — deliberately WIDER than the one the check walks.

    The check renders only what the app-of-apps wires up; capture renders every tracked overlay,
    including the ones no stack points at. The asymmetry is the point. If capture inherited the
    check's scope, an unwired component's CRDs could never be snapshotted — so the moment somebody
    uncommented its app file the guard would go rc 2, and the only way out would be to comment it
    straight back. Capturing wide means the snapshot is already waiting; running --capture on a
    cluster that lacks those operators prints the loud `‼️ NOT INSTALLED` line below, which is the
    honest record of a gap rather than a silent absence.
    """
    overlays = sorted({p.parent for p in PORTFOLIO.glob("*/*/kustomization.yaml")}
                      | {p.parent for p in PORTFOLIO.glob("*/kustomization.yaml")})
    return chart_jobs() + [("kustomize", overlay, None, overlay.relative_to(REPO).as_posix())
                           for overlay in overlays]


def _oc(*args) -> str:
    proc = subprocess.run(["oc", *args], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise GuardError(f"`oc {' '.join(args)}` failed: {(proc.stderr or '').strip()[:400]}")
    return proc.stdout


def capture(fixtures: pathlib.Path) -> int:
    """Re-take the schema snapshots from the cluster `oc` is pointed at. Never runs in CI.

    Captures every SERVED version of every CRD backing a kind the charts render — not only the
    versions in use today — so a chart moving from v1beta1 to v1beta2 stays checkable instead of
    reddening CI for a reason nobody without a cluster can fix.
    """
    if shutil.which("oc") is None:
        raise GuardError("oc is not on PATH; --capture needs a live cluster.")
    print("rendering the charts and overlays to find out which CRDs are actually needed…")
    wanted = set()
    for kind, target, values, label in capture_jobs():
        rendered = render(target, values) if kind == "helm" else render_overlay(target)
        for doc, _ in documents_in(rendered, label):
            group, _, _version = (doc.get("apiVersion") or "").rpartition("/")
            if group:
                wanted.add((group, doc.get("kind")))

    crds = json.loads(_oc("get", "crd", "-o", "json"))["items"]
    by_kind = {(c["spec"]["group"], c["spec"]["names"]["kind"]): c for c in crds}
    crd_kinds = set(by_kind)

    # `oc api-resources --no-headers` has an OPTIONAL shortnames column, so the fields are counted
    # from the RIGHT: KIND last, NAMESPACED before it, APIVERSION before that.
    served = set()
    for line in _oc("api-resources", "--no-headers").splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        api_version, kind = fields[-3], fields[-1]
        served.add(f"{api_version.rpartition('/')[0]}/{kind}")
    builtin = sorted(name for name in served if tuple(name.split("/", 1)) not in crd_kinds)

    import datetime
    version = json.loads(_oc("version", "-o", "json"))
    provenance = {
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "capturedFrom": "a live OpenShift cluster with the workshop platform portfolio installed "
                        "(hostname deliberately omitted: ephemeral RHDP domains do not belong in "
                        "tracked files)",
        "openshiftVersion": version.get("openshiftVersion", "?"),
        "kubernetesVersion": (version.get("serverVersion") or {}).get("gitVersion", "?"),
    }

    (fixtures / "schemas").mkdir(parents=True, exist_ok=True)
    entries = []
    for group, kind in sorted(wanted):
        crd = by_kind.get((group, kind))
        if crd is None:
            # Two very different situations, and printing them the same way is how a real gap gets
            # skimmed past: a kind the cluster serves WITHOUT a CRD is built-in (Route, BuildConfig,
            # Template …) and is meant to have no snapshot; a kind the cluster does not serve at all
            # is a genuine hole that will read UN-CHECKABLE on the next plain run.
            if f"{group}/{kind}" in builtin:
                print(f"  ·  {group}/{kind}: built-in (no CRD behind it) — nothing to snapshot.")
            else:
                print(f"  ‼️  {group}/{kind}: NOT INSTALLED on this cluster. It will read "
                      f"UN-CHECKABLE (rc 2) until you re-capture somewhere that operator is.")
            continue
        name = crd["metadata"]["name"]
        meta = crd["metadata"]
        versions = {v["name"]: prune_schema(v["schema"]["openAPIV3Schema"])
                    for v in crd["spec"]["versions"] if v.get("schema", {}).get("openAPIV3Schema")}
        # WHICH operator's schema this is, as far as the CRD itself will say. Re-measured 2026-08-06
        # across all 51: `olm.owner` is set on NONE of them, the `operators.coreos.com/<csv>.<ns>`
        # label on 28, and `controller-gen.kubebuilder.io/version` on 29 — so every signal is
        # recorded when present and OMITTED when absent. A uniform "not OLM-owned" on all 51 would
        # have been a provenance field that tells you nothing while looking like it tells you
        # something.
        source = {key: value for key, value in (
            ("operator", next((k.split("/", 1)[1] for k in (meta.get("labels") or {})
                               if k.startswith("operators.coreos.com/")), None)),
            ("controllerGen", (meta.get("annotations") or {}).get(
                "controller-gen.kubebuilder.io/version")),
            ("installedOnClusterAt", meta.get("creationTimestamp")),
        ) if value}
        snapshot = {
            "crd": name,
            "group": group,
            "kind": kind,
            "source": source,
            "capturedAt": provenance["capturedAt"],
            "capturedFrom": provenance["capturedFrom"],
            "note": "Pruned to the structure Kubernetes admission-pruning depends on: properties, "
                    "items, additionalProperties, x-kubernetes-preserve-unknown-fields and "
                    "x-kubernetes-embedded-resource. Re-take with "
                    "`tools/lint/crd-unknown-field-guard.py --capture`.",
            "versions": versions,
        }
        (fixtures / "schemas" / f"{name}.json").write_text(
            json.dumps(snapshot, indent=1, sort_keys=True) + "\n")
        entries.append({"file": f"schemas/{name}.json", "crd": name, "group": group, "kind": kind,
                        "versions": sorted(versions)})
        print(f"  ✅ {name}: {', '.join(sorted(versions))}")

    (fixtures / "builtin-kinds.json").write_text(json.dumps(
        {**provenance,
         "note": "Every group/Kind this cluster serves that is NOT backed by a "
                 "CustomResourceDefinition — built-in and aggregated APIs. CRD field pruning does "
                 "not apply to them, so the guard skips them by measurement rather than by a "
                 "hardcoded list of group names.",
         "kinds": builtin}, indent=1) + "\n")
    (fixtures / "index.json").write_text(json.dumps(
        {**provenance,
         "note": "Snapshots of the CRD structural schemas the repo's charts render against. "
                 "Re-take with `tools/lint/crd-unknown-field-guard.py --capture`.",
         "crds": entries}, indent=1) + "\n")
    print(f"captured {len(entries)} CRD snapshot(s) and {len(builtin)} built-in kinds into "
          f"{fixtures.relative_to(REPO)}")
    return 0


# ───────────────────────────────────────────────────────────────────────────────── the modes


def main(argv=None) -> int:
    # argparse, not `"--self-test" in sys.argv`: the membership test ignores every other argument,
    # so `--selftest` (one hyphen short) would run the plain check and print a clean result while a
    # maintainer believed they had proven a detector fires.
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="run the canaries instead of the real tree; exits 1 when every planted "
                             "defect was caught, which is the PASS for this mode")
    parser.add_argument("--capture", action="store_true",
                        help="re-take the CRD schema snapshots from the cluster `oc` points at "
                             "(needs a live cluster; never runs in CI)")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    try:
        if args.capture:
            return capture(FIXTURES)
        scope = scope_for_tree()
        overlay_jobs, unwired = portfolio_jobs()
        # Before the verdict, not after and not only when green: the narrowing has to be visible in
        # the log a reader is scanning because something FAILED, not just in the happy path.
        print(unwired_note(unwired))
        report, totals = run(FIXTURES, chart_jobs() + overlay_jobs, scope)
    except GuardError as exc:
        print(f"::error::crd-unknown-field-guard: {exc}", file=sys.stderr)
        return 2
    headline = scope.summary()
    headline += (f"; {len(unwired)} component overlay(s) outside the render set, named above"
                 if unwired else "; every component overlay was wired and rendered")
    return report_and_exit(report, scope, headline)


def self_test() -> int:
    """Prove both directions on a canary chart rendered through the REAL code path.

    The canary is a chart, not a fixture string, because check_chart() is the thing that needs
    proving and check_chart() renders with helm. Its planted defects are judged against the SAME
    checked-in snapshots the real run uses, so this also proves the snapshots themselves — the
    DevWorkspace case below is the 9c97d80 defect, field for field, against the real DevWorkspace
    CRD schema.
    """
    import tempfile
    failures: list[str] = []

    expectations = yaml.safe_load((CANARY / "expectations.yaml").read_text())
    chart_half = [("helm", CANARY / "chart",
                   {"user": "user1", "clusterDomain": "example.com", "solve": solve},
                   f"canary (solve={solve})") for solve in SOLVE_WORLDS]
    # The kustomize half runs through portfolio_jobs() itself, over the canary's miniature
    # portfolio, so the wiring rule is proven by the function the real run calls — not by a
    # re-implementation that could pass while the shipped one is broken.
    try:
        overlay_half, unwired = portfolio_jobs(CANARY / "portfolio")
        report, totals = run(FIXTURES, chart_half + overlay_half, None)
    except GuardError as exc:
        print(f"SELF-TEST FAILED: the canary could not be rendered or judged: {exc}",
              file=sys.stderr)
        return 2

    # ── 1. every planted defect caught, and NOTHING else. A total ("N findings") cannot tell which
    # case produced which, and a fixture whose comments claim coverage it does not have is worse
    # than one with no comments at all (tools/lint/_scope.py records what that cost elsewhere).
    expected = {(case["kind"], case["path"]) for case in expectations["mustFire"]}
    actual = report.paths()
    for kind, path in sorted(expected - actual):
        failures.append(f"the planted defect {kind} {path} was NOT flagged — "
                        f"{next(c['why'] for c in expectations['mustFire'] if c['path'] == path)}")
    for kind, path in sorted(actual - expected):
        failures.append(f"{kind} {path} was flagged but the canary declares no expectation for it. "
                        f"Every finding a canary produces must SAY it is meant to.")

    # ── 2. the false-positive controls. Listing a legal field is not enough: the field has to still
    # BE there. A control that quietly disappears from the fixture stops controlling anything while
    # the self-test goes on passing, which is this project's signature failure.
    # "\n---\n", not "\n": `helm template` opens its output with a `---`, `kustomize build` does not,
    # so a bare join silently FUSES the last Helm document into the first kustomize one. Measured
    # while writing this: the fused document swallowed the canary Application and its false-positive
    # control reported itself missing — a self-test failure that was really a harness bug.
    rendered = "\n---\n".join(
        [render(CANARY / "chart", values) for _, _, values, _ in chart_half]
        + [render_overlay(overlay) for _, overlay, _, _ in overlay_half])
    documents = [d for d in yaml.safe_load_all(rendered) if isinstance(d, dict)]
    for case in expectations["mustNotFire"]:
        present = any(_dig(doc, case["path"].split(".")) is not None
                      for doc in documents if doc.get("kind") == case["kind"])
        if not present:
            failures.append(f"the false-positive control {case['kind']} {case['path']} is NOT in "
                            f"the rendered canary any more, so it proves nothing: {case['why']}")
        if (case["kind"], case["path"]) in actual:
            failures.append(f"FALSE POSITIVE: {case['kind']} {case['path']} was flagged and it is "
                            f"legal — {case['why'].rstrip().rstrip('.')}. A guard that reports "
                            f"working manifests as broken is worse than the defect it hunts.")

    # ── 3. un-checkable must be its own outcome, never silence and never a field finding.
    uncheckable = {row["subject"].split("/")[0] for row in report.of("uncheckable")}
    if uncheckable != set(expectations["mustBeUncheckable"]):
        failures.append(f"the un-checkable set was {sorted(uncheckable)}, expected "
                        f"{sorted(expectations['mustBeUncheckable'])}. A custom resource whose CRD "
                        f"has no snapshot must be reported as uninspected, not skipped.")
    if report_and_exit(report, None, "canary", quiet=True) != 2:
        failures.append("a canary carrying an un-checkable custom resource did not exit 2. "
                        "'I had no schema for this' would then be indistinguishable from 'clean'.")

    # ── 4. THE WIRING RULE, in all three directions. The render set narrows itself, so what it
    # leaves out has to be asserted as carefully as what it catches — an exclusion nobody checks is
    # how a scope quietly shrinks while the ✅ line stays the same length.
    declared = {case["overlay"]: case for case in expectations["mustNotBeRendered"]}
    observed = {overlay.relative_to(CANARY / "portfolio").as_posix() for overlay in unwired}
    if observed != set(declared):
        failures.append(f"the canary's unwired set was {sorted(observed)}, expected "
                        f"{sorted(declared)}. An overlay that stops being REPORTED as outside the "
                        f"render set is an overlay nobody knows went unchecked — and one that "
                        f"appears here unexpectedly is coverage silently lost.")
    for overlay, case in declared.items():
        # (a) still not reported, and (b) the defect is still THERE. Without (b) the control decays
        # into a green tick over an empty file — the exact shape mustNotFire is asserted against.
        if (case["kind"], case["path"]) in actual:
            failures.append(f"{case['kind']} {case['path']} was reported, but it lives in "
                            f"{overlay}, which the wiring rule says is not rendered. Either the "
                            f"exclusion stopped working or the expectation is stale.")
        try:
            planted = [doc for doc in yaml.safe_load_all(
                render_overlay(CANARY / "portfolio" / overlay)) if isinstance(doc, dict)]
        except GuardError as exc:
            failures.append(f"the unwired overlay {overlay} no longer renders at all ({exc}), so "
                            f"nothing proves the guard is declining to check something real.")
            continue
        if not any(_dig(doc, case["path"].split(".")) is not None
                   for doc in planted if doc.get("kind") == case["kind"]):
            failures.append(f"the un-rendered control {case['kind']} {case['path']} is gone from "
                            f"{overlay}. A control with no defect in it proves nothing while the "
                            f"self-test goes on passing: {case['why']}")

    # ── 4b. THE DISCLOSURE MUST REACH THE LOG. Measured while writing this file: blinding
    # unwired_note() to return "" left the real tree at a perfectly green rc 0 with loki-logging
    # never mentioned — a narrowed scope and an unchanged ✅. Nothing else here would notice, because
    # a disclosure moves no exit code by design, which is exactly why it needs its own assertion.
    # Asserted against the output of a REAL main() run, so blinding the print SITE fails too.
    import contextlib
    import io
    _, real_unwired = portfolio_jobs()
    note = unwired_note(real_unwired)
    if not note.strip():
        failures.append("unwired_note() produced nothing. A render scope that narrows itself in "
                        "silence is how the ✅ line survives while the world behind it shrinks.")
    for overlay in real_unwired:
        if overlay.relative_to(REPO).as_posix() not in note:
            failures.append(f"{overlay.relative_to(REPO).as_posix()} is outside the render set and "
                            f"is NOT named in the note. A count without names cannot be acted on.")
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        main([])  # the plain path — never --self-test, so this cannot recurse
    if note.strip() and note not in buffer.getvalue():
        failures.append("the real run did not PRINT what is outside its render set. The note exists "
                        "and nobody reads it: a scope exception nobody sees is not disclosed.")

    # ── 5. the solve=true world must materialize MORE than the default one, or one of the two
    # renders has silently stopped happening.
    if totals["solve=true custom resources"] <= totals["solve=false custom resources"]:
        failures.append(f"the canary's solve world produced "
                        f"{totals['solve=true custom resources']} custom resources against "
                        f"{totals['solve=false custom resources']} at solve=false. It must produce "
                        f"more; equal counts mean one render's documents never reached the walker.")
    # Both render paths must have actually run. "kustomize renders" and "portfolio custom resources"
    # are here for the same reason the rest are: an unrun half of a gate is worse than no gate.
    for dimension in ("preserve-unknown-fields nodes honoured", "free-form map nodes honoured",
                      "template objects walked", "fields walked", "helm renders",
                      "kustomize renders", "portfolio custom resources"):
        if totals[dimension] < 1:
            failures.append(f"the canary exercised '{dimension}' zero times, so nothing proves that "
                            f"rule is still consulted.")

    # ── 6. a render either side refuses must be a REFUSAL, not a skip. Written to a temp dir rather
    # than committed, because a broken chart in the tree would trip `helm lint` and the kustomize
    # job.
    with tempfile.TemporaryDirectory() as tmp:
        broken = pathlib.Path(tmp) / "broken"
        (broken / "templates").mkdir(parents=True)
        (broken / "Chart.yaml").write_text("apiVersion: v2\nname: broken\nversion: 0.0.0\n")
        (broken / "templates" / "boom.yaml").write_text("{{ .Values.nope | required \"boom\" }}\n")
        broken_report = Report()
        check_chart(broken, {"solve": "false"}, "canary-broken", {}, set(), broken_report)
        if len(broken_report.of("render-failed")) != 1:
            failures.append("a chart helm refuses to render did not produce exactly one "
                            "render-failed row. Without it, a chart that stops rendering becomes a "
                            "chart that stops being checked, silently.")
        if report_and_exit(broken_report, None, "canary", quiet=True) != 2:
            failures.append("a chart that failed to render did not exit 2.")

        # The kustomize half of the same property. A directory with no kustomization.yaml is what
        # `kustomize build` refuses, and it must land as render-failed → rc 2, never as an overlay
        # that quietly contributed nothing.
        empty = pathlib.Path(tmp) / "not-an-overlay"
        empty.mkdir()
        overlay_report = Report()
        check_overlay(empty, "canary-broken-overlay", {}, set(), overlay_report)
        if len(overlay_report.of("render-failed")) != 1:
            failures.append("an overlay kustomize refuses to build did not produce exactly one "
                            "render-failed row. Without it, an overlay that stops rendering becomes "
                            "an overlay that stops being checked, silently.")
        if report_and_exit(overlay_report, None, "canary", quiet=True) != 2:
            failures.append("an overlay that failed to build did not exit 2.")

    # ── 7. the declared floors must still describe the declared work.
    if MIN_EXTRA_CHARTS != len(EXTRA_CHARTS):
        failures.append(f"MIN_EXTRA_CHARTS is {MIN_EXTRA_CHARTS} but EXTRA_CHARTS declares "
                        f"{len(EXTRA_CHARTS)}. A chart was added or removed without re-stating the "
                        f"floor, so the floor has stopped asserting the real set.")
    if MIN_PORTFOLIO_ALWAYS != len(PORTFOLIO_ALWAYS):
        failures.append(f"MIN_PORTFOLIO_ALWAYS is {MIN_PORTFOLIO_ALWAYS} but PORTFOLIO_ALWAYS "
                        f"declares {len(PORTFOLIO_ALWAYS)}. An always-rendered overlay was added or "
                        f"dropped without re-stating the floor — and dropping one silently removes "
                        f"a whole overlay from every run.")
    tree_scope = scope_for_tree()
    for dimension in WALK_DIMENSIONS + RENDER_DIMENSIONS:
        if tree_scope.floor_for(dimension) is None:
            failures.append(f"the counter '{dimension}' is raised but has no floor — a measurement "
                            f"nobody judges cannot notice a collapse.")
    failures += Scope.self_check()

    if failures:
        for failure in failures:
            print(f"SELF-TEST FAILED: {failure}", file=sys.stderr)
        return 2
    print(f"self-test ok — the two DevWorkspace fields of 9c97d80 are caught against the real CRD "
          f"snapshot, along with {len(expected) - 2} other planted defects across BOTH render "
          f"paths ({totals['helm renders']} helm renders, {totals['kustomize renders']} kustomize "
          f"renders); {len(expectations['mustNotFire'])} legal fields beside them (a "
          f"preserve-unknown-fields node, a free-form map, a map VALUE, a built-in kind and a child "
          f"Application) are present in the render and are NOT flagged; a component reached only by "
          f"following a stack Application IS rendered, and the "
          f"{len(expectations['mustNotBeRendered'])} overlay(s) no stack wires up are reported as "
          f"outside the scope with their planted defect still in place; a CR with no snapshot exits "
          f"2 rather than passing; a chart helm refuses and an overlay kustomize refuses both exit "
          f"2; the solve world renders more than the default; every counter has a floor and the "
          f"scope ledger fails an empty or truncated input set.")
    return 1


def _dig(node, path):
    """Follow one of walk()'s own paths back through a rendered document, or None.

    Reads the SAME notation walk() writes — `[0]` a list index, `[key]` a map key — so a
    false-positive control declares its field exactly as a finding would name it, and the two cannot
    drift apart into a control that points at nothing.
    """
    for step in path:
        if step.startswith("[") and step.endswith("]"):
            inner = step[1:-1]
            if isinstance(node, list):
                index = int(inner)
                if index >= len(node):
                    return None
                node = node[index]
                continue
            step = inner
        if not isinstance(node, dict) or step not in node:
            return None
        node = node[step]
    return node


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the tree has a finding" / "the canary
    # was detected" code. A crash must never be readable as either, so it is remapped to 2.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::crd-unknown-field-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
              f"'canary detected'.", file=sys.stderr)
        sys.exit(2)
