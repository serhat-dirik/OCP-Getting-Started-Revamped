#!/usr/bin/env python3
"""sync-wave-pvc-guard.py — an Argo-created PVC must share its consumer's sync wave.

WHY THIS EXISTS. `gitops/workshop-config/templates/showroom-shared.yaml` put a PersistentVolumeClaim
at `argocd.argoproj.io/sync-wave: "2"` and the Deployment that mounts it at `"3"`. The default
StorageClass on these clusters is `WaitForFirstConsumer`, so the PVC stays Pending until its
consuming pod is SCHEDULED; Argo will not begin wave 3 until wave 2 is Healthy, and a Pending PVC is
Progressing, never Healthy. It waited for a PVC that could not bind until it created the very
Deployment it was refusing to create. Measured on cluster-m24jn 2026-08-15: 52 minutes, zero pods
created, the Application stuck Progressing/Running on

    waiting for healthy state of /PersistentVolumeClaim/showroom-shared-demos-homes

Fixed in c7b3324. THE REASON THIS NEEDS A GATE RATHER THAN A COMMENT: nothing in that state is an
error. A Pending PVC reports `Normal`/`WaitForFirstConsumer`; the operation is `Running`, not
`Failed`. It reads as a slow sync, forever — no `oc get events` line, no Degraded health, nothing for
`ws doctor` to go red on. And the rule was ALREADY WRITTEN DOWN, correctly, in the file next door:
`showroom.yaml` states it for `showroom-home-{user}` and says "proven on-cluster". Prose in a sibling
template did not survive being re-applied in a new one. That is precisely the gap a gate closes.

THIS GUARD RENDERS, IT DOES NOT GREP. Same reason as image-pull-policy-guard.py: a PVC or a workload
emitted from a named template in `_helpers.tpl` is invisible to `grep`, and the `showroom-shared`
Deployment/PVC pair is emitted twice from ONE `range` in a single template — a text scan sees one
wave annotation and one claimName and cannot pair them per instance. Rendering is also the only way
to see the `showroom.shared.enabled=true` world at all: the flag is false by default, so the render
that carried this bug is not the render anybody looks at.

THE RULE, and why BOTH inequalities are derived rather than just "the PVC must not be earlier":

    consumer ordered BEFORE the PVC  ->  the pod is Pending on a claim that does not exist; its
                                         wave never goes Healthy; Argo never reaches the PVC's wave.
                                         Deadlocks for EVERY storage class. Unconditional.

    consumer ordered AFTER the PVC   ->  the PVC is Pending until a consumer pod is scheduled; its
                                         wave never goes Healthy; Argo never reaches the consumer's
                                         wave. Deadlocks whenever the PVC BINDS LAZILY (below).

Both directions are the same deadlock seen from opposite ends, so the safe state is EQUAL ordering.

BINDING MODE IS THE PRECONDITION OF THE SECOND DIRECTION, AND IT IS DERIVED, NOT ASSUMED.
"Pending until a consumer is scheduled" is `volumeBindingMode: WaitForFirstConsumer` on the PVC's
StorageClass — a property of the class, which a manifest either pins by name or leaves to the
cluster's default. So:

  * A PVC that names NO storage class (absent, null, or "") takes the cluster default and binds
    lazily. Measured on cluster-m24jn 2026-08-15, the default is
    `ocs-external-storagecluster-ceph-rbd` / `WaitForFirstConsumer` — the class every showroom PVC
    gets, and the exact mechanism of the incident above. (`storageClassName: ""` technically means
    static provisioning rather than the default class; it is treated as lazy here because it can
    never bind SOONER than the default would, so the conservative reading is also the correct one.)
  * A PVC that names a class is judged against BINDING_MODES below, whose entries were read off a
    real cluster on a stated date.
  * A named class this guard has never been told about is an EXIT 2, never a pass — the same
    treatment image-pull-policy-guard gives a workshop image at an unrecognized container key.
    Guessing a binding mode is how a gate quietly stops gating.

BINDING_MODES IS NOT A DECLARED-DEBT LEDGER (tools/lint/LEDGERS.md). It never converts a detected
defect into accepted debt: it supplies a physical fact the rule needs, and an absent fact stops the
run instead of passing it. `Immediate` genuinely cannot produce the second deadlock — the claim binds
before any pod exists — so there is no defect to suppress. What it DOES do is make the premise
visible: every clean run names the PVCs whose safety rests on a named Immediate class, because that
safety is a property of the deployer's cluster and not of the manifest.

HOOKS ARE PART OF THE ORDER, NOT A SEPARATE WORLD. Argo orders a sync by (phase, wave), and a
resource annotated `argocd.argoproj.io/hook: Sync` sits on the SAME wave line as the non-hook
resources in the sync phase — Sync hooks run "at the same time as the application of the manifests",
and hooks are wave-ordered along with everything else. `jobs-batch-kueue` is exactly that shape — a
plain wave-0 PVC consumed by a `hook: Sync` Job at wave 1 — so a guard that ignored hooks would
compare the wrong things. A `PreSync` consumer of a `Sync` PVC is the same deadlock reached through
the phase axis instead of the wave axis, which is why the comparison key is the pair and not the
wave alone.

That phase/wave model is Argo's DOCUMENTED ordering, not something measured here; the workshop's
clusters run OpenShift GitOps 1.21.3 (read off cluster-m24jn 2026-08-15). It is not load-bearing for
any finding on today's tree — the one hook pairing in the tree is judged safe by binding mode
whichever way the phases are modelled — so if a future finding turns on it, measure the ordering on
a cluster before believing this paragraph.

WHAT IS AND IS NOT AN ARGO-CREATED PVC:
  * Top-level `kind: PersistentVolumeClaim` documents — yes. These are what Argo applies and waits
    on.
  * StatefulSet `spec.volumeClaimTemplates[]` — NO. Those PVCs are created by the StatefulSet
    controller after the StatefulSet is applied, so they are not in any wave and cannot deadlock
    against one. They are counted and deliberately excluded, including when a chart writes an
    explicit `kind: PersistentVolumeClaim` inside the template (legal, and the shape that would
    fool a walker that indexed by `kind` alone).
  * PodSpecs and PVCs nested in an OpenShift `Template.objects[]` — NO. Argo creates the Template;
    the objects are instantiated later by `oc process`, outside any sync.

A PVC that no rendered workload mounts is NOT a violation — there is nothing for it to deadlock
against — but it is counted and listed on every run, because an unmounted PVC in an early wave is
the same trap holding still until someone adds its consumer.

USAGE
    tools/lint/sync-wave-pvc-guard.py                # check the tree
    tools/lint/sync-wave-pvc-guard.py --list-claims  # every PVC found, its wave, and its consumers
    tools/lint/sync-wave-pvc-guard.py --self-test    # scan the canary fixtures; MUST exit 1

EXIT CODES (same contract as image-pull-policy-guard.py, so the workflow steps read alike):
    0  every Argo-created PVC shares its consumers' (phase, wave)
    1  at least one does not — or, under --self-test, every canary was correctly detected
    2  the guard could not do its job (helm/kustomize/PyYAML missing, a render failed, a COLLAPSED
       scope, a storage class of unknown binding mode, a non-integer sync-wave, a hook phase this
       guard has not been taught, or an undetected canary). Never confuse this with a clean result.

LOCAL YAMLLINT: the canary chart's templates carry Helm actions and are not plain YAML, exactly like
the real chart template dirs. The maintainer yamllint config is gitignored, so this commit cannot
ship the exclusion — add

    tools/lint/sync-wave-pvc-guard.canary/chart/templates/

to the `ignore:` block of your own .yamllint.yaml, next to the image-pull-policy-guard.canary line.
(Re-derive the full list rather than trusting this one:
`git ls-files 'tools/lint/**/*.yaml' | xargs grep -l '{{' | xargs -n1 dirname | sort -u`.)
"""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    WHY THE `__main__` TRY/EXCEPT IS NOT ENOUGH (measured 2026-08-01, image-pull-policy-guard's
    header records it). Module-level code runs before `__main__` exists, so a bad constant, a failed
    import, or a _scope.py that does not PARSE crashes with Python's default rc 1 — which is exactly
    what CI's `--self-test must exit EXACTLY 1` reads as "the canary fired". A completely broken
    guard would be indistinguishable from a working one.

    Installed as the FIRST statement after the imports, so it is already in place before anything
    below it can fail. `os._exit` is what makes the code stick: an excepthook cannot change the exit
    status by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::sync-wave-pvc-guard: crashed before it could report "
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
except Exception as exc:  # noqa: BLE001 — deliberately broad
    # NOT `except ImportError`. A _scope.py that fails to PARSE raises SyntaxError, sails past an
    # ImportError-only handler, and exits 1 — CI's "the canary fired". Anything at all going wrong
    # while loading the scope ledger means this guard cannot start, and that is rc 2 regardless of
    # which exception said so.
    print(f"::error::sync-wave-pvc-guard: cannot import _scope ({exc}) — "
          f"the guard could not start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a machine without PyYAML
    print("sync-wave-pvc-guard: PyYAML is not installed. This guard parses rendered manifests "
          "properly rather than pattern-matching them, so it cannot run without a parser — refusing "
          "to report clean. Install it (python3 -m pip install PyYAML) and re-run.", file=sys.stderr)
    sys.exit(2)


# --------------------------------------------------------------------------------- the Argo model

WAVE_ANNOTATION = "argocd.argoproj.io/sync-wave"
HOOK_ANNOTATION = "argocd.argoproj.io/hook"

# Argo orders a sync by phase first, then by wave within the phase. A resource with no hook
# annotation is a plain Sync-phase resource and shares the wave line with `hook: Sync` resources.
DEFAULT_PHASE = "Sync"
PHASE_RANK = {"PreSync": 0, "Sync": 1, "PostSync": 2}

# `Skip` means Argo never applies the resource at all, so it cannot participate in a deadlock.
# Counted, then dropped.
IGNORED_PHASES = frozenset({"Skip"})

# `SyncFail` only runs after a sync has already failed. A PVC or a PVC consumer there is a shape this
# guard has not been taught to reason about and none exists in the tree; refusing to guess is an
# exit 2, exactly as for an unknown storage class.
UNSUPPORTED_PHASES = frozenset({"SyncFail"})

# Argo itself falls back to wave 0 when the annotation is missing (and, silently, when it does not
# parse). MISSING is modelled explicitly rather than skipped — an unannotated PVC beside an
# annotated Deployment is a real pairing and the commonest way this defect gets written.
DEFAULT_WAVE = 0


# --------------------------------------------------------------------------------- binding modes

IMMEDIATE = "Immediate"
WAIT_FOR_FIRST_CONSUMER = "WaitForFirstConsumer"

# Read off a live cluster, not from memory. `oc get storageclass -o custom-columns=NAME:.metadata.
# name,BINDING:.volumeBindingMode,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/
# is-default-class` on cluster-m24jn, 2026-08-15 — the same cluster and day the deadlock was
# measured. Re-derive on YOUR cluster before adding an entry; a binding mode is a property of the
# class as that cluster ships it, and this table is only as good as its provenance.
#
# A class NOT listed here is an exit 2, never a pass. See binding_mode() and the module docstring:
# this is a premise table, not a suppression ledger, and an unknown premise stops the run.
BINDING_MODES: dict[str, str] = {
    # default=true on this cluster — every PVC in the tree that names no class gets this one, and it
    # is the direct cause of the 52-minute deadlock this guard exists to prevent.
    "ocs-external-storagecluster-ceph-rbd": WAIT_FOR_FIRST_CONSUMER,
    # ODF's Immediate-binding RBD variant, shipped alongside the default.
    "ocs-external-storagecluster-ceph-rbd-immediate": IMMEDIATE,
    # The RWX class jobs-batch-kueue's claims-data names (`datasetStorageClass`). CephFS binds
    # Immediately, which is why that chart's wave-0 PVC / wave-1 Sync-hook Job pairing works.
    "ocs-external-storagecluster-cephfs": IMMEDIATE,
    # Object-bucket class; no PVC in this tree uses it. Listed because it is on the cluster and the
    # next person reading `oc get sc` will wonder why it is missing.
    "openshift-storage.noobaa.io": IMMEDIATE,
}

# What a PVC with no `storageClassName` gets. This is a property of the CLUSTER, not the manifest —
# which is exactly why the "PVC earlier than its consumer" rule cannot be waived for it.
DEFAULT_STORAGE_CLASS_BINDING = WAIT_FOR_FIRST_CONSUMER

RULE_PVC_AFTER = "pvc-after-consumer"
RULE_PVC_BEFORE = "pvc-before-consumer"
RULES = (RULE_PVC_AFTER, RULE_PVC_BEFORE)


# --------------------------------------------------------------------------------- what to render

# Helm charts, rendered under every values permutation that changes WHAT IS EMITTED.
#
# `solve` is not cosmetic: solve worlds materialize workloads the default render never produces (the
# lesson image-pull-policy-guard's header records). `showroom.shared.enabled` is the flag whose
# render CARRIED THIS BUG — false by default, so the defective pair existed in the tree for as long
# as it did precisely because the render nobody looks at is the one that had it.
ENTRY_STATE_VALUE_SETS = (
    {"user": "user1", "clusterDomain": "example.com", "solve": "false"},
    {"user": "user1", "clusterDomain": "example.com", "solve": "true"},
)

WORKSHOP_CONFIG_VALUE_SETS = (
    {"userCount": "2", "clusterDomain": "apps.example.com", "showroom.shared.enabled": "false"},
    {"userCount": "2", "clusterDomain": "apps.example.com", "showroom.shared.enabled": "true"},
)

# The remaining Helm charts in the tree, each with the minimum values it refuses to render without.
# They emit no PVC today; they are rendered anyway so that the day one of them grows a PVC it is
# already covered, rather than covered by whoever remembers to widen this list.
OTHER_CHARTS = (
    ("gitops/user-namespace", {"user": "user1", "suffixes": "dev,stage,prod"}),
    ("helm/bootstrap", {}),
)

# Kustomize units: every TRACKED kustomization.yaml, minus tools/ (other guards' canary fixtures,
# which are deliberately broken in ways of their own). `git ls-files` rather than a filesystem walk,
# for the reason the `kustomize` CI job spells out: the walk descends into the gitignored
# `platform-portfolio/components/*/charts/` that `--enable-helm` inflates at build time.
KUSTOMIZE_EXCLUDE_PREFIX = "tools/"


class GuardError(Exception):
    """The guard cannot do its job. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


# --------------------------------------------------------------------------------- reading Argo bits


def annotations(document: dict) -> dict:
    metadata = document.get("metadata")
    if not isinstance(metadata, dict):
        return {}
    found = metadata.get("annotations")
    return found if isinstance(found, dict) else {}


def object_id(document: dict) -> str:
    metadata = document.get("metadata") if isinstance(document.get("metadata"), dict) else {}
    namespace = metadata.get("namespace") or "<no namespace>"
    return f"{document.get('kind', '<no kind>')}/{metadata.get('name', '<unnamed>')} " \
           f"in {namespace}"


def sync_wave(document: dict, where: str) -> int:
    """The Argo sync wave, modelling ABSENT as 0 rather than skipping the object.

    Argo also falls back to 0 when the annotation is present but does not parse. That silent
    fallback is a defect worth stopping on rather than reproducing: `sync-wave: "3 "` and
    `sync-wave: three` both become wave 0 on the cluster while reading, to a human, like wave 3.
    """
    raw = annotations(document).get(WAVE_ANNOTATION)
    if raw is None:
        return DEFAULT_WAVE
    text = str(raw).strip()
    try:
        return int(text)
    except ValueError as exc:
        raise GuardError(
            f"{where}: {object_id(document)} carries {WAVE_ANNOTATION}: {raw!r}, which is not an "
            f"integer. Argo SILENTLY treats an unparseable wave as 0, so this object is ordered "
            f"first while the manifest reads as though it were ordered last. Fix the annotation; "
            f"this guard refuses to reproduce the silent fallback.") from exc


def sync_phases(document: dict, where: str) -> list[str]:
    """The Argo phases the object participates in. No hook annotation means the plain Sync phase."""
    raw = annotations(document).get(HOOK_ANNOTATION)
    if raw is None:
        return [DEFAULT_PHASE]
    phases = [p.strip() for p in str(raw).split(",") if p.strip()]
    if not phases:
        return [DEFAULT_PHASE]
    for phase in phases:
        if phase in IGNORED_PHASES or phase in PHASE_RANK:
            continue
        if phase in UNSUPPORTED_PHASES:
            raise GuardError(
                f"{where}: {object_id(document)} is a {phase} hook and takes part in a PVC mount. "
                f"{phase} hooks run only after a sync has already failed, so this guard's "
                f"(phase, wave) ordering does not describe them and it refuses to guess. No such "
                f"object exists in the tree today; if one is being added, teach PHASE_RANK "
                f"deliberately rather than letting the gate fall silent.")
        raise GuardError(
            f"{where}: {object_id(document)} carries {HOOK_ANNOTATION}: {raw!r}, and {phase!r} is "
            f"not an Argo hook phase this guard knows ({sorted(PHASE_RANK)}, "
            f"{sorted(IGNORED_PHASES)}, {sorted(UNSUPPORTED_PHASES)}). Refusing to order an object "
            f"whose phase it cannot place.")
    return phases


def order_key(document: dict, where: str) -> tuple[int, int] | None:
    """(phase rank, wave) — what Argo actually sorts by. None when Argo never applies the object.

    A multi-phase hook (`hook: PreSync,PostSync`) has no single position in that order, so it gets a
    GuardError rather than an arbitrary choice: picking one of its phases would silently judge the
    pairing against an ordering that is only half true.
    """
    phases = [p for p in sync_phases(document, where) if p not in IGNORED_PHASES]
    if not phases:
        return None
    if len(phases) > 1:
        raise GuardError(
            f"{where}: {object_id(document)} declares more than one hook phase "
            f"({', '.join(phases)}) and takes part in a PVC mount. It therefore occupies two "
            f"positions in Argo's ordering and this guard cannot compare it against one wave. "
            f"Split it into one object per phase, or teach the guard the case deliberately.")
    return (PHASE_RANK[phases[0]], sync_wave(document, where))


def fmt_order(key: tuple[int, int]) -> str:
    phase = next(name for name, rank in PHASE_RANK.items() if rank == key[0])
    return f"{phase} phase, wave {key[1]}"


# --------------------------------------------------------------------------------- storage classes


def declared_storage_class(document: dict) -> str | None:
    """The class the PVC pins, or None when it takes the cluster default.

    `""` is folded into None deliberately: it means static provisioning rather than "the default
    class", but it can never bind SOONER than the default would, so the conservative reading is also
    the correct one for a deadlock question.
    """
    spec = document.get("spec")
    if not isinstance(spec, dict):
        return None
    name = spec.get("storageClassName")
    if not isinstance(name, str) or not name.strip():
        return None
    return name.strip()


def binding_mode(storage_class: str | None) -> str | None:
    """The PVC's volumeBindingMode, or None when the named class is not in BINDING_MODES.

    None is an exit-2 condition at the call site, never a pass. Deliberately not a `-> bool`: the
    "unknown class" answer has to be distinguishable from "binds immediately", and a predicate that
    collapsed the two would turn a class nobody has measured into a silent all-clear.
    """
    if storage_class is None:
        return DEFAULT_STORAGE_CLASS_BINDING
    return BINDING_MODES.get(storage_class)


def binds_lazily(mode: str) -> bool:
    """True when the claim stays Pending until a consumer pod is scheduled.

    This is the entire precondition of the "PVC ordered before its consumer" deadlock. With
    `Immediate` the claim binds before any pod exists, so that direction genuinely cannot hang — and
    with anything else it can.
    """
    return mode != IMMEDIATE


# --------------------------------------------------------------------------------- walking


def pod_mount_sites(document: dict) -> list[dict]:
    """Every `persistentVolumeClaim.claimName` anywhere in the document, with where it was found.

    Generic on purpose, exactly like image-pull-policy-guard's image walk. `spec.template.spec.
    volumes[]` on a Deployment/StatefulSet/DaemonSet/Job, `spec.jobTemplate.spec.template.spec.
    volumes[]` on a CronJob, `spec.volumes[]` on a bare Pod, an Argo Rollout's pod template and a
    Tekton PipelineRun's `spec.workspaces[]` all fall out of this for free — and none of them is
    reachable by a walk that only knows the Deployment shape.

    `Template.objects[]` is NOT descended into: Argo creates the OpenShift Template, and the objects
    inside it are instantiated later by `oc process`, outside any sync. Judging their waves would
    invent a deadlock that cannot happen.
    """
    sites: list[dict] = []
    is_template = document.get("kind") == "Template"

    def walk(node, path: list) -> None:
        if isinstance(node, dict):
            claim = node.get("persistentVolumeClaim")
            if isinstance(claim, dict) and isinstance(claim.get("claimName"), str):
                sites.append({"claim": claim["claimName"], "path": list(path)})
            for key, value in node.items():
                if is_template and not path and key == "objects":
                    continue
                walk(value, path + [key])
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, path + [index])

    walk(document, [])
    return sites


def volume_claim_template_names(document: dict) -> list[str]:
    """StatefulSet `spec.volumeClaimTemplates[]` names — created by the StatefulSet controller, NOT
    by Argo, and therefore not subject to this rule. Collected only so the count is reportable and
    the exclusion is provable."""
    spec = document.get("spec")
    if not isinstance(spec, dict):
        return []
    templates = spec.get("volumeClaimTemplates")
    if not isinstance(templates, list):
        return []
    names = []
    for entry in templates:
        if not isinstance(entry, dict):
            continue
        metadata = entry.get("metadata")
        names.append(metadata.get("name", "<unnamed>") if isinstance(metadata, dict)
                     else "<unnamed>")
    return names


def fmt_path(path: list) -> str:
    return "/".join(str(step) for step in path)


# --------------------------------------------------------------------------------- a rendered unit


class Unit:
    """One rendered thing Argo would point an Application at: a chart render, or a kustomize build.

    Pairing happens WITHIN a unit and never across, because a wave only orders resources inside one
    sync. Two units that both contain the same object simply reach the same verdict twice.
    """

    def __init__(self, label: str):
        self.label = label
        self.pvcs: dict[tuple[str, str], dict] = {}
        self.mounts: list[dict] = []
        self.volume_claim_templates: list[str] = []
        self.skipped: list[str] = []

    def ingest(self, document: dict) -> None:
        kind = document.get("kind")
        metadata = document.get("metadata") if isinstance(document.get("metadata"), dict) else {}
        namespace = metadata.get("namespace") or ""
        name = metadata.get("name") or ""

        # Top-level PVCs only. A volumeClaimTemplate is nested inside its StatefulSet and never
        # reaches here — including when the chart writes `kind: PersistentVolumeClaim` inside it,
        # which is legal and is the shape that would fool a walker indexing by `kind` alone.
        if kind == "PersistentVolumeClaim":
            key = order_key(document, self.label)
            if key is None:
                self.skipped.append(f"{object_id(document)} (Skip hook — Argo never applies it)")
                return
            self.pvcs[(namespace, name)] = {
                "key": key,
                "name": name,
                "namespace": namespace,
                "storage_class": declared_storage_class(document),
                "id": object_id(document),
            }
            return

        self.volume_claim_templates += [f"{object_id(document)} -> {n}"
                                        for n in volume_claim_template_names(document)]

        sites = pod_mount_sites(document)
        if not sites:
            return
        key = order_key(document, self.label)
        if key is None:
            self.skipped.append(f"{object_id(document)} (Skip hook — Argo never applies it)")
            return
        for site in sites:
            self.mounts.append({
                "claim": site["claim"],
                "namespace": namespace,
                "path": site["path"],
                "key": key,
                "id": object_id(document),
            })


# --------------------------------------------------------------------------------- rendering


def _require(tool: str) -> None:
    if shutil.which(tool) is None:
        raise GuardError(
            f"{tool} is not on PATH. This guard RENDERS rather than grepping — a PVC and the "
            "workload that mounts it can be emitted from one `range` in a single template, which no "
            "text scan can pair — so it cannot run without it. Refusing to report clean.")


def render_helm(root: pathlib.Path, chart: pathlib.Path, values: dict) -> str:
    _require("helm")
    cmd = ["helm", "template", "t", str(chart)]
    for key, value in values.items():
        # helm splits an UNESCAPED comma in a --set value into further key=value pairs, so a list
        # value silently becomes garbage. ns-policy-parity-guard learned this on `suffixes`.
        cmd += ["--set", f"{key}={str(value).replace(',', chr(92) + ',')}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, cwd=root)
    if proc.returncode != 0:
        label = " ".join(f"{k}={v}" for k, v in values.items())
        raise GuardError(
            f"`helm template` failed for {chart} ({label}), rc={proc.returncode}:\n"
            f"{proc.stderr.strip()}\n"
            "A chart that will not render is a chart this guard did not check. Skipping it would "
            "turn a broken chart into a passing gate.")
    return proc.stdout


def render_kustomize(root: pathlib.Path, directory: str) -> str:
    _require("kustomize")
    proc = subprocess.run(["kustomize", "build", "--enable-helm", directory],
                          capture_output=True, text=True, check=False, cwd=root)
    if proc.returncode != 0:
        raise GuardError(f"`kustomize build --enable-helm {directory}` failed "
                         f"(rc={proc.returncode}):\n{proc.stderr.strip()}")
    return proc.stdout


def parse_documents(text: str, source: str) -> list:
    try:
        return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        raise GuardError(f"{source} rendered output that is not parseable as YAML: {exc}") from exc


def build_unit(text: str, label: str) -> Unit:
    unit = Unit(label)
    for document in parse_documents(text, label):
        unit.ingest(document)
    return unit


# --------------------------------------------------------------------------------- discovery


def discover_entry_state_charts(root: pathlib.Path) -> list[pathlib.Path]:
    charts = sorted(p.parent for p in (root / "gitops/entry-states").glob("*/Chart.yaml"))
    if not charts:
        raise GuardError("no entry-state charts found under gitops/entry-states/*/Chart.yaml. The "
                         "repo ships two dozen, so an empty selection means this guard is broken — "
                         "refusing to pass on an empty scope.")
    return charts


def discover_kustomize_dirs(root: pathlib.Path) -> list[str]:
    proc = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=False,
                          cwd=root)
    if proc.returncode != 0:
        raise GuardError(f"`git ls-files` failed (rc={proc.returncode}): {proc.stderr.strip()}")
    dirs = sorted({str(pathlib.PurePosixPath(line).parent) for line in proc.stdout.splitlines()
                   if pathlib.PurePosixPath(line).name == "kustomization.yaml"
                   and not line.startswith(KUSTOMIZE_EXCLUDE_PREFIX)})
    if not dirs:
        raise GuardError("no tracked kustomization.yaml outside tools/. The portfolio ships dozens, "
                         "so an empty selection means discovery broke — refusing to pass on an "
                         "empty scope.")
    return dirs


# The dimensions collect_units() raises, named once so the counters and their floors cannot drift
# apart. self_test asserts each one has a floor.
COLLECT_DIMENSIONS = ("helm renders", "kustomize builds", "PVCs rendered",
                      "shared-cockpit PVCs rendered", "PVC mount sites")


def collect_units(root: pathlib.Path, charts: list[pathlib.Path],
                  kustomize_dirs: list[str]) -> tuple[list[Unit], dict]:
    """(units, scope counters). The counters are raised BY the loops that render, so dropping the
    kustomize half, or the shared=true permutation, collapses a dimension instead of quietly
    shrinking the input set — the blinding shape _scope.py exists for."""
    units: list[Unit] = []
    counts = {dimension: 0 for dimension in COLLECT_DIMENSIONS}

    def take(unit: Unit, shared_cockpit: bool = False) -> None:
        units.append(unit)
        counts["PVCs rendered"] += len(unit.pvcs)
        counts["PVC mount sites"] += len(unit.mounts)
        if shared_cockpit:
            counts["shared-cockpit PVCs rendered"] += len(unit.pvcs)

    for chart in charts:
        for values in ENTRY_STATE_VALUE_SETS:
            label = f"{chart.relative_to(root)} (solve={values['solve']})"
            counts["helm renders"] += 1
            take(build_unit(render_helm(root, chart, values), label))

    workshop_config = root / "gitops/workshop-config"
    for values in WORKSHOP_CONFIG_VALUE_SETS:
        shared = values["showroom.shared.enabled"]
        label = f"gitops/workshop-config (showroom.shared.enabled={shared})"
        counts["helm renders"] += 1
        take(build_unit(render_helm(root, workshop_config, values), label),
             shared_cockpit=(shared == "true"))

    for chart, values in OTHER_CHARTS:
        directory = root / chart
        if not directory.is_dir():
            raise GuardError(f"{chart} does not exist. It was moved or renamed; update "
                             "OTHER_CHARTS rather than leaving the gate pointing at nothing.")
        counts["helm renders"] += 1
        take(build_unit(render_helm(root, directory, values), chart))

    for directory in kustomize_dirs:
        counts["kustomize builds"] += 1
        take(build_unit(render_kustomize(root, directory), directory))

    return units, counts


# --------------------------------------------------------------------------------- the check


def resolve_mounts(unit: Unit) -> tuple[list[tuple[dict, dict]], list[str], list[dict]]:
    """(pairs, blockers, unresolved). A pair is (pvc, mount) in the same rendered unit.

    Claim resolution is namespace-local, so the key is (namespace, claimName). A rendered manifest
    may legitimately omit `metadata.namespace` and inherit the Application's destination, in which
    case one side can carry a namespace the other does not — so an exact miss falls back to a
    name-only match, but ONLY when exactly one rendered PVC has that name. Two PVCs sharing a name
    across namespaces is genuinely ambiguous and is a blocker rather than a coin toss.
    """
    pairs: list[tuple[dict, dict]] = []
    blockers: list[str] = []
    unresolved: list[dict] = []

    by_name: dict[str, list[dict]] = {}
    for pvc in unit.pvcs.values():
        by_name.setdefault(pvc["name"], []).append(pvc)

    for mount in unit.mounts:
        exact = unit.pvcs.get((mount["namespace"], mount["claim"]))
        if exact is not None:
            pairs.append((exact, mount))
            continue
        candidates = by_name.get(mount["claim"], [])
        if len(candidates) == 1:
            pairs.append((candidates[0], mount))
        elif len(candidates) > 1:
            blockers.append(
                f"{unit.label}: {mount['id']} mounts claim {mount['claim']!r} and this render "
                f"contains {len(candidates)} PVCs with that name in different namespaces "
                f"({', '.join(sorted(p['namespace'] or '<none>' for p in candidates))}). Refusing "
                "to guess which one it deadlocks against — give the workload an explicit "
                "metadata.namespace.")
        else:
            unresolved.append(mount)
    return pairs, blockers, unresolved


def evaluate(units: list[Unit]) -> tuple[list[str], list[str], dict, list[str], list[str]]:
    """(violations, blockers, stats, unmounted report lines, immediate-class report lines)."""
    violations: list[str] = []
    blockers: list[str] = []
    unmounted: list[str] = []
    immediate: list[str] = []
    stats = {"pairs": 0, "equal": 0, "unmounted": 0, "unresolved": 0,
             "volumeClaimTemplates": 0, "skipped": 0, "immediate": 0}

    for unit in units:
        stats["volumeClaimTemplates"] += len(unit.volume_claim_templates)
        stats["skipped"] += len(unit.skipped)
        pairs, pair_blockers, unresolved = resolve_mounts(unit)
        blockers += pair_blockers
        stats["unresolved"] += len(unresolved)

        mounted_keys = {(pvc["namespace"], pvc["name"]) for pvc, _ in pairs}
        for key, pvc in sorted(unit.pvcs.items()):
            if key in mounted_keys:
                continue
            stats["unmounted"] += 1
            unmounted.append(
                f"{unit.label}: {pvc['id']} at {fmt_order(pvc['key'])} is mounted by no workload "
                f"this render emits. Not a deadlock today — there is nothing to deadlock against — "
                f"but the moment a consumer is added at a different wave it becomes one.")

        for pvc, mount in pairs:
            stats["pairs"] += 1
            if pvc["key"] == mount["key"]:
                stats["equal"] += 1
                continue

            if mount["key"] < pvc["key"]:
                violations.append(
                    f"[{RULE_PVC_AFTER}] {unit.label}\n"
                    f"      PVC      : {pvc['id']} at {fmt_order(pvc['key'])}\n"
                    f"      consumer : {mount['id']} at {fmt_order(mount['key'])} "
                    f"({fmt_path(mount['path'])})\n"
                    f"      why      : Argo creates the consumer FIRST, its pod is Pending on a "
                    f"claim that does not exist yet, so that wave never goes Healthy and the PVC's "
                    f"wave is never reached. Permanent, and for every storage class.\n"
                    f"      fix      : put the PVC at {fmt_order(mount['key'])}, the SAME position "
                    f"as its consumer.")
                continue

            default_note = "" if pvc["storage_class"] else " (no storageClassName — the cluster " \
                                                           "default class)"
            mode = binding_mode(pvc["storage_class"])
            if mode is None:
                blockers.append(
                    f"{unit.label}: {pvc['id']} names storageClassName "
                    f"{pvc['storage_class']!r}, whose volumeBindingMode this guard has never been "
                    f"told. It sits at {fmt_order(pvc['key'])}, EARLIER than its consumer "
                    f"{mount['id']} at {fmt_order(mount['key'])} — which deadlocks if that class is "
                    f"WaitForFirstConsumer and is fine if it is Immediate. Read the mode off a "
                    f"cluster (`oc get storageclass {pvc['storage_class']} "
                    f"-o jsonpath='{{.volumeBindingMode}}'`) and add it to BINDING_MODES with the "
                    f"cluster and date. Refusing to guess.")
                continue

            if not binds_lazily(mode):
                stats["immediate"] += 1
                immediate.append(
                    f"{unit.label}: {pvc['id']} sits at {fmt_order(pvc['key'])}, earlier than its "
                    f"consumer {mount['id']} at {fmt_order(mount['key'])}. That is safe ONLY "
                    f"because storageClassName {pvc['storage_class']!r} binds {mode} — a property "
                    f"of the deployer's cluster, not of this manifest. Re-pointing that value at a "
                    f"WaitForFirstConsumer class deadlocks the sync with no error anywhere.")
                continue

            violations.append(
                f"[{RULE_PVC_BEFORE}] {unit.label}\n"
                f"      PVC      : {pvc['id']} at {fmt_order(pvc['key'])}{default_note}\n"
                f"      consumer : {mount['id']} at {fmt_order(mount['key'])} "
                f"({fmt_path(mount['path'])})\n"
                f"      binding  : {mode}\n"
                f"      why      : the claim stays Pending until a consumer pod is SCHEDULED, so "
                f"its wave never goes Healthy and Argo never reaches the wave that would create "
                f"the consumer. Nothing reports an error — a Pending PVC is Normal/"
                f"WaitForFirstConsumer and the operation stays Running. It reads as a slow sync, "
                f"forever (measured: 52 minutes, zero pods, cluster-m24jn 2026-08-15).\n"
                f"      fix      : put the PVC at {fmt_order(mount['key'])}, the SAME position as "
                f"its consumer.")

    return violations, blockers, stats, unmounted, immediate


# --------------------------------------------------------------------------------- self-test


def _canary_root(root: pathlib.Path) -> pathlib.Path:
    return root / "tools/lint/sync-wave-pvc-guard.canary"


def _rule_of(violation: str) -> str:
    return violation.split("]", 1)[0].lstrip("[")


def _names_in(lines: list[str], marker: str) -> set[str]:
    """Object names mentioned on a `marker` line of each finding — how the self-test asserts WHICH
    case fired rather than merely that something did."""
    found = set()
    for line in lines:
        for part in line.splitlines():
            stripped = part.strip()
            if stripped.startswith(marker):
                found.add(stripped.split(":", 1)[1].strip().split(" ")[0].split("/")[-1])
    return found


def self_test(root: pathlib.Path) -> int:  # noqa: C901 - one assertion per detector, deliberately
    """Prove each detector on static fixtures. A result other than 1 means detection is unproven.

    Static fixtures, not a mutated copy of live content: what has to be tested is the DETECTOR, and
    a canary derived from real charts quietly becomes an exit 2 the day that content changes shape.
    """
    fixture = _canary_root(root)
    if not fixture.is_dir():
        print("::error::sync-wave-pvc-guard: the canary fixture directory is missing — detection "
              "is unproven, so a clean result on the real tree means nothing.", file=sys.stderr)
        return 2

    failures: list[str] = []
    canary_chart = fixture / "chart"

    # (1) The Argo model, exercised directly. Each of these is a shape the fixture chart cannot
    #     express without also asserting something about Helm.
    absent = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "a"}}
    if sync_wave(absent, "unit") != 0:
        failures.append("an object with NO sync-wave annotation was not modelled as wave 0 — Argo "
                        "treats it as 0, and an unannotated PVC beside an annotated Deployment is "
                        "the commonest way this defect gets written.")
    if order_key(absent, "unit") != (PHASE_RANK[DEFAULT_PHASE], 0):
        failures.append("an object with no hook annotation was not placed in the Sync phase.")
    hook_sync = {"kind": "Job", "metadata": {"name": "j", "annotations": {
        HOOK_ANNOTATION: "Sync", WAVE_ANNOTATION: "1"}}}
    if order_key(hook_sync, "unit") != (PHASE_RANK["Sync"], 1):
        failures.append("a `hook: Sync` object was not placed on the Sync phase's wave line. That "
                        "is jobs-batch-kueue's real shape; getting it wrong compares the wrong "
                        "things on a live chart.")
    presync = {"kind": "Job", "metadata": {"name": "j", "annotations": {HOOK_ANNOTATION: "PreSync",
                                                                       WAVE_ANNOTATION: "99"}}}
    if not order_key(presync, "unit") < order_key(absent, "unit"):
        failures.append("a PreSync hook at wave 99 did not sort BEFORE a Sync-phase object at wave "
                        "0 — the phase axis is not dominating the wave axis, so a PreSync consumer "
                        "of a Sync PVC would not be reported.")
    skipped = {"kind": "Job", "metadata": {"name": "j", "annotations": {HOOK_ANNOTATION: "Skip"}}}
    if order_key(skipped, "unit") is not None:
        failures.append("a `hook: Skip` object was given a position in the sync order. Argo never "
                        "applies it, so judging it invents a deadlock that cannot happen.")

    for document, what in (
        ({"kind": "PersistentVolumeClaim", "metadata": {"name": "p", "annotations": {
            WAVE_ANNOTATION: "three"}}}, "a non-integer sync-wave"),
        ({"kind": "Job", "metadata": {"name": "j", "annotations": {
            HOOK_ANNOTATION: "SyncFail"}}}, "a SyncFail hook"),
        ({"kind": "Job", "metadata": {"name": "j", "annotations": {
            HOOK_ANNOTATION: "PreSync,PostSync"}}}, "a multi-phase hook"),
        ({"kind": "Job", "metadata": {"name": "j", "annotations": {
            HOOK_ANNOTATION: "Whenever"}}}, "an unknown hook phase"),
    ):
        try:
            order_key(document, "unit")
        except GuardError:
            pass
        else:
            failures.append(f"{what} did not stop the run. Argo's own silent fallback is what this "
                            "guard exists not to reproduce.")

    # (2) The binding-mode premise, both answers and the unknown case.
    if binding_mode(None) != WAIT_FOR_FIRST_CONSUMER:
        failures.append("a PVC with no storageClassName was not treated as taking the cluster "
                        "default's WaitForFirstConsumer binding — that is the exact class the "
                        "showroom PVCs get and the mechanism of the measured incident.")
    for spec, what in (({}, "a PVC with no spec.storageClassName"),
                       ({"storageClassName": ""}, "storageClassName: ''"),
                       ({"storageClassName": "   "}, "a whitespace-only storageClassName")):
        if declared_storage_class({"kind": "PersistentVolumeClaim", "spec": spec}) is not None:
            failures.append(f"{what} was read as pinning a class. It takes the cluster default (or, "
                            "for '', static provisioning) — neither of which can bind SOONER than "
                            "the default, so both have to be judged as lazily-binding.")
    if binding_mode("ocs-external-storagecluster-cephfs") != IMMEDIATE:
        failures.append("BINDING_MODES lost the Immediate CephFS class jobs-batch-kueue names.")
    if binding_mode("ocs-external-storagecluster-ceph-rbd") != WAIT_FOR_FIRST_CONSUMER:
        failures.append("BINDING_MODES lost the cluster's DEFAULT class, which is the one that "
                        "deadlocked.")
    if binding_mode("some-class-nobody-measured") is not None:
        failures.append("an unmeasured storage class was given a binding mode. Guessing one turns a "
                        "class nobody has looked at into a silent all-clear.")
    if binds_lazily(IMMEDIATE) or not binds_lazily(WAIT_FOR_FIRST_CONSUMER):
        failures.append("binds_lazily() does not distinguish Immediate from WaitForFirstConsumer, "
                        "which is the entire precondition of the pvc-before-consumer rule.")

    # (3) The walker: a volumeClaimTemplate must never enter the PVC index, and a Template's
    #     objects[] must never be descended into. Both are shapes that LOOK like the real thing.
    sts = {"apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": {"name": "s"},
           "spec": {"volumeClaimTemplates": [
               {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                "metadata": {"name": "data"}, "spec": {}}],
               "template": {"spec": {"containers": []}}}}
    probe = Unit("probe")
    probe.ingest(sts)
    if probe.pvcs:
        failures.append("a StatefulSet's volumeClaimTemplates entry entered the PVC index. Those "
                        "PVCs are created by the StatefulSet controller, not by Argo, so they are "
                        "in no wave and flagging them is a false positive on every StatefulSet.")
    if len(probe.volume_claim_templates) != 1:
        failures.append("volumeClaimTemplates were not counted, so the exclusion above cannot be "
                        "distinguished from the walker never having seen the StatefulSet at all.")
    template = {"apiVersion": "template.openshift.io/v1", "kind": "Template",
                "metadata": {"name": "t"}, "objects": [
                    {"kind": "Deployment", "metadata": {"name": "d"}, "spec": {"template": {
                        "spec": {"volumes": [{"name": "v", "persistentVolumeClaim": {
                            "claimName": "inside-a-template"}}]}}}}]}
    if pod_mount_sites(template):
        failures.append("the walker descended into an OpenShift Template's objects[]. Argo creates "
                        "the Template; `oc process` instantiates its objects later, outside any "
                        "sync, so their waves cannot deadlock.")
    cronjob = {"apiVersion": "batch/v1", "kind": "CronJob", "metadata": {"name": "c"},
               "spec": {"jobTemplate": {"spec": {"template": {"spec": {"volumes": [
                   {"name": "v", "persistentVolumeClaim": {"claimName": "deep"}}]}}}}}}
    if [s["claim"] for s in pod_mount_sites(cronjob)] != ["deep"]:
        failures.append("the walker did not reach a CronJob's jobTemplate-nested volumes[] — a "
                        "Deployment-shaped walk's blind spot.")

    # (4) The renderer + pairing + both rules, on the fixture chart, at every permutation. The
    #     expectations name the OBJECTS, not a total: a count cannot tell which case produced it,
    #     and a canary whose sections claim coverage they do not have is worse than none.
    #
    #     `expected_equal` is asserted EXACTLY, not as a floor. The safe controls are what make the
    #     firing cases mean anything, and a control that silently stops being rendered would satisfy
    #     "it was not flagged" vacuously — the only thing that notices is its disappearance from the
    #     count of pairs that came out equal.
    expectations = [
        # (values, {rule: {expected PVC names}}, expected counters)
        ({"solve": "false", "shared": "false"},
         {RULE_PVC_BEFORE: {"canary-early-default", "canary-early-unannotated",
                            "canary-implicit-namespace"},
          RULE_PVC_AFTER: {"canary-late-plain", "canary-late-immediate",
                           "canary-consumer-unannotated"}},
         {"unmounted": 1, "immediate": 1, "equal": 5, "unresolved": 1, "skipped": 2}),
        ({"solve": "true", "shared": "false"},
         {RULE_PVC_BEFORE: {"canary-early-default", "canary-early-unannotated",
                            "canary-implicit-namespace", "canary-solve-early"},
          RULE_PVC_AFTER: {"canary-late-plain", "canary-late-immediate",
                           "canary-consumer-unannotated"}},
         {"unmounted": 1, "immediate": 1, "equal": 5, "unresolved": 1, "skipped": 2}),
        ({"solve": "false", "shared": "true"},
         {RULE_PVC_BEFORE: {"canary-early-default", "canary-early-unannotated",
                            "canary-implicit-namespace", "canary-shared-early"},
          RULE_PVC_AFTER: {"canary-late-plain", "canary-late-immediate",
                           "canary-consumer-unannotated"}},
         {"unmounted": 1, "immediate": 1, "equal": 5, "unresolved": 1, "skipped": 2}),
    ]
    for values, expected, expected_counts in expectations:
        label = f"canary (solve={values['solve']}, shared={values['shared']})"
        try:
            unit = build_unit(render_helm(root, canary_chart, values), label)
        except GuardError as exc:
            failures.append(f"{label} could not be rendered: {exc}")
            continue
        violations, blockers, stats, unmounted, immediate = evaluate([unit])
        if blockers:
            failures.append(f"{label} produced unexpected blockers: {blockers}")
        for rule in RULES:
            got = _names_in([v for v in violations if _rule_of(v) == rule], "PVC")
            if got != expected.get(rule, set()):
                failures.append(f"{label}: rule {rule} fired on {sorted(got)}, expected "
                                f"{sorted(expected.get(rule, set()))}.")
        # Every counter is asserted EXACTLY, and each has a fixture case only it can move:
        #   unmounted  — canary-unmounted, the PVC nothing consumes
        #   immediate  — canary-early-immediate, safe only because of its named class
        #   equal      — the five safe controls; a control that stops being rendered satisfies
        #                "it was not flagged" vacuously and nothing else would notice
        #   unresolved — canary-unresolved-claim-app, mounting a claim from another Application
        #   skipped    — the canary-skip-hook pair, which Argo never applies
        for counter, expected_count in sorted(expected_counts.items()):
            if stats[counter] != expected_count:
                failures.append(f"{label}: counter {counter!r} is {stats[counter]}, expected "
                                f"{expected_count}. Its fixture case is the only thing that moves "
                                "it, so a mismatch means that case stopped being seen — not that "
                                "the tree changed.")
        if len(unmounted) != expected_counts["unmounted"]:
            failures.append(f"{label}: {stats['unmounted']} unmounted PVC(s) counted but "
                            f"{len(unmounted)} reported. An unmounted PVC in an early wave is the "
                            "same trap waiting for its consumer, so it has to be VISIBLE rather "
                            "than merely not-a-violation.")
        if len(immediate) != expected_counts["immediate"]:
            failures.append(f"{label}: {stats['immediate']} Immediate-class reliance(s) counted but "
                            f"{len(immediate)} reported. That premise has to be re-printed on every "
                            "run, not remembered.")
        if stats["volumeClaimTemplates"] < 1:
            failures.append(f"{label}: the fixture's StatefulSet volumeClaimTemplates were not "
                            "counted, so their exclusion is indistinguishable from the walker "
                            "never reaching the StatefulSet.")

    # (5) Each named SAFE control must be silent — by name, not by a total. A guard that flags every
    #     pair passes every "the bad case fired" assertion ever written.
    control_values = expectations[0][0]
    control_unit = build_unit(render_helm(root, canary_chart, control_values), "canary (control)")
    control_violations, _, _, _, _ = evaluate([control_unit])
    flagged = _names_in(control_violations, "PVC")
    for safe in ("canary-equal-default", "canary-equal-hook-sync", "canary-equal-presync",
                 "canary-equal-cronjob", "canary-early-immediate", "canary-cross-namespace-equal",
                 "canary-unmounted"):
        if safe in flagged:
            failures.append(f"the canary's SAFE case {safe} was flagged. A guard that flags every "
                            "pair proves nothing about the ones that matter.")

    # (6) The unknown-storage-class blocker: an unmeasured class at an earlier wave must STOP the
    #     run, not be skipped. Driven through evaluate() so it is the production path.
    unknown = Unit("canary-unknown-class")
    unknown.ingest({"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                    "metadata": {"name": "u", "namespace": "n",
                                 "annotations": {WAVE_ANNOTATION: "1"}},
                    "spec": {"storageClassName": "some-class-nobody-measured"}})
    unknown.ingest({"apiVersion": "apps/v1", "kind": "Deployment",
                    "metadata": {"name": "d", "namespace": "n",
                                 "annotations": {WAVE_ANNOTATION: "2"}},
                    "spec": {"template": {"spec": {"volumes": [
                        {"name": "v", "persistentVolumeClaim": {"claimName": "u"}}]}}}})
    unknown_violations, unknown_blockers, _, _, _ = evaluate([unknown])
    if len(unknown_blockers) != 1 or unknown_violations:
        failures.append("an earlier-wave PVC on a storage class of unknown binding mode did not "
                        "produce exactly one blocker. Passing it would let a WaitForFirstConsumer "
                        "class nobody measured through the gate.")

    # (7) The ambiguous-claim blocker: two same-named PVCs in different namespaces must not be
    #     resolved by coin toss.
    ambiguous = Unit("canary-ambiguous")
    for namespace in ("ns-a", "ns-b"):
        ambiguous.ingest({"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                          "metadata": {"name": "shared-name", "namespace": namespace}})
    ambiguous.ingest({"apiVersion": "apps/v1", "kind": "Deployment",
                      "metadata": {"name": "d"},
                      "spec": {"template": {"spec": {"volumes": [
                          {"name": "v", "persistentVolumeClaim": {"claimName": "shared-name"}}]}}}})
    if len(evaluate([ambiguous])[1]) != 1:
        failures.append("a claim matching two same-named PVCs in different namespaces was resolved "
                        "instead of blocked — the guard would judge the pairing it happened to "
                        "pick.")

    # (8) collect_units() ITSELF — the production glue main() runs and every assertion above walks
    #     around. Blinded to return no units while still raising its counters, both CI signals stay
    #     green; the invariant that catches it is that what it RETURNS must equal what it COUNTED.
    try:
        collected, counts = collect_units(root, [canary_chart], [])
    except GuardError as exc:
        collected, counts = [], {}
        failures.append(f"collect_units() could not run over the canary chart: {exc}")
    if counts:
        # One chart × two entry-state value sets, plus workshop-config's two and OTHER_CHARTS.
        expected_renders = len(ENTRY_STATE_VALUE_SETS) + len(WORKSHOP_CONFIG_VALUE_SETS) \
            + len(OTHER_CHARTS)
        if counts["helm renders"] != expected_renders:
            failures.append(f"collect_units() reported {counts['helm renders']} helm render(s) for "
                            f"one chart; the declared value sets require {expected_renders}. A "
                            "dropped permutation is a whole world of resources that stops being "
                            "rendered — and showroom.shared.enabled=true is the permutation the "
                            "real defect lived in.")
        if counts["shared-cockpit PVCs rendered"] < 1:
            failures.append("collect_units() raised no shared-cockpit PVC count. That dimension is "
                            "the only thing that notices the showroom.shared.enabled=true render "
                            "being dropped, which is the render that carried the real bug.")
        returned = sum(len(u.pvcs) for u in collected)
        if returned != counts["PVCs rendered"]:
            failures.append(f"collect_units() returned {returned} PVC(s) but counted "
                            f"{counts['PVCs rendered']}. The scope floors are raised from the "
                            "counters, so a filter that drops units after they are counted passes "
                            "every floor while judging nothing.")

    # The scope ledger is a library no CI step runs on its own; exercising it here is what stops it
    # being an unrun gate. Then: every dimension collect_units() raises must have a floor.
    failures += Scope.self_check()
    tree_scope = scope_for_tree()
    unfloored = [d for d in (*COLLECT_DIMENSIONS, "entry-state charts")
                 if tree_scope.floor_for(d) is None]
    if unfloored:
        failures.append(f"scope_for_tree() declares no floor for {unfloored} — a dimension that is "
                        "measured but not judged proves nothing.")

    if failures:
        for failure in failures:
            print(f"::error::sync-wave-pvc-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2

    print("self-test ok — both deadlock directions detected by name, missing annotations modelled "
          "as wave 0, hook phases ordered ahead of waves, StatefulSet volumeClaimTemplates and "
          "Template.objects[] correctly excluded, equal-wave and Immediate-class controls silent, "
          "unknown storage classes and ambiguous claims blocked, and the scope ledger fails an "
          "empty or truncated input set.")
    return 1


# --------------------------------------------------------------------------------- main


def scope_for_tree() -> Scope:
    """Floors for a real-tree run. Measured 2026-08-15 on this tree: 26 entry-state charts, 56 helm
    renders, 53 kustomize builds, 14 PVCs rendered (5 of them in the shared-cockpit render), 16
    mount sites, 16 pairs judged. Each floor sits under the measurement and far above any plausible
    truncation."""
    scope = Scope("sync-wave-pvc-guard")
    scope.require("entry-state charts", 20,
                  "gitops/entry-states ships 26 charts; a smaller number means discovery stopped "
                  "matching, not that six were deleted.")
    scope.require("helm renders", 45,
                  "two value sets per entry-state chart, plus workshop-config twice and the two "
                  "standalone charts. A dropped permutation is a world of resources nobody renders.")
    scope.require("kustomize builds", 40,
                  "the portfolio ships ~50 tracked kustomizations outside tools/. This half renders "
                  "with a different tool and is the easiest to drop without the run looking any "
                  "different.")
    scope.require("PVCs rendered", 9,
                  "14 PVCs are rendered across the tree today. Zero — or one — means the walker or "
                  "the renderer collapsed, and a guard with no PVCs to judge reports clean.")
    scope.require("shared-cockpit PVCs rendered", 3,
                  "the showroom.shared.enabled=true render emits 5 PVCs and is the render the "
                  "measured deadlock lived in. It is false by default, so nothing else in this "
                  "repo notices if that permutation stops being rendered.")
    scope.require("PVC mount sites", 10,
                  "16 workload->claim edges exist today. This is the half that PAIRS; a collapsed "
                  "mount walk leaves every PVC looking merely unmounted, which is not a violation.")
    return scope


def main(argv=None) -> int:  # noqa: C901 - a linear report, not a branchy one
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="scan the canary fixtures instead of the tree; a result other than 1 "
                             "means detection is unproven, not that the tree is fine")
    parser.add_argument("--list-claims", action="store_true",
                        help="print every PVC found, its position in the sync order and its "
                             "consumers, then exit")
    args = parser.parse_args(argv)

    root = repo_root()

    if args.self_test:
        try:
            return self_test(root)
        except GuardError as exc:
            print(f"::error::sync-wave-pvc-guard self-test could not run: {exc}", file=sys.stderr)
            return 2

    scope = scope_for_tree()
    try:
        charts = discover_entry_state_charts(root)
        scope.add("entry-state charts", len(charts))
        kustomize_dirs = discover_kustomize_dirs(root)
        units, counts = collect_units(root, charts, kustomize_dirs)
        scope.merge(counts)
        violations, blockers, stats, unmounted, immediate = evaluate(units)
    except GuardError as exc:
        print(f"::error::sync-wave-pvc-guard: {exc}", file=sys.stderr)
        return 2

    if args.list_claims:
        for unit in units:
            pairs, _, _ = resolve_mounts(unit)
            for key, pvc in sorted(unit.pvcs.items()):
                consumers = [f"{m['id']} @ {fmt_order(m['key'])}" for p, m in pairs
                             if (p["namespace"], p["name"]) == key]
                print(f"{unit.label}\n  {pvc['id']} @ {fmt_order(pvc['key'])} "
                      f"class={pvc['storage_class'] or '<cluster default>'}\n"
                      f"    consumers: {consumers or '<none>'}")
        return 0

    # Before reporting anything: did the run actually inspect what it claims to?
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if blockers:
        print("\n::error::sync-wave-pvc-guard cannot judge every claim:", file=sys.stderr)
        for blocker in blockers:
            print(f"  {blocker}", file=sys.stderr)
        return 2

    if unmounted:
        print("PVCs no rendered workload mounts (not a violation — nothing to deadlock against — "
              "but the trap is already built):")
        for line in unmounted:
            print(f"  {line}")

    if immediate:
        print("\nEarly PVCs whose safety rests on a named Immediate-binding storage class:")
        for line in immediate:
            print(f"  {line}")

    if violations:
        print("\nArgo-created PVCs that do not share their consumer's position in the sync order:")
        for violation in violations:
            print(f"  {violation}")
        # Flush before writing to stderr: the two streams are buffered independently, so without
        # this the ::error:: summary lands ABOVE the findings it summarizes in the CI log.
        sys.stdout.flush()
        print(f"\n::error::{len(violations)} PVC/consumer pair(s) would deadlock their own Argo "
              "sync. Neither side reports an error while it happens — a Pending PVC is "
              "Normal/WaitForFirstConsumer and the operation stays Running — so it reads as a slow "
              "sync forever. Put each PVC in the SAME sync wave as the workload that mounts it.",
              file=sys.stderr)
        return 1

    print(f"\nsync-wave-pvc-guard: clean — {scope.summary()}; "
          f"{stats['pairs']} PVC/consumer pair(s) judged, {stats['equal']} sharing their consumer's "
          f"position, {stats['immediate']} earlier but on an Immediate class, {stats['unmounted']} "
          f"PVC(s) mounted by nothing, {stats['unresolved']} mount(s) of a claim this render does "
          f"not emit, {stats['volumeClaimTemplates']} volumeClaimTemplate(s) excluded (created by "
          f"the StatefulSet controller, not by Argo), {stats['skipped']} Skip-hook object(s) "
          f"ignored.")
    return 0


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either, so it is remapped to 2 — "the
    # guard could not run". Without this, a typo or a missing fixture would make --self-test exit 1
    # and CI would report the guard's detection as PROVEN.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::sync-wave-pvc-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
