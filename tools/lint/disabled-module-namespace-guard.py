#!/usr/bin/env python3
"""disabled-module-namespace-guard.py — workshop-config must not render into a namespace that a
DISABLED module's platform stack was never installed to create.

WHY THIS EXISTS (SEV1-E, the defect it would have caught — fixed in the same slice that added this
file). `modules_disabled:` in bootstrap/vars.yaml is a supported, documented delivery option: an SA
provisioning a shorter workshop lists the modules they are not teaching, and the installer both hides
them from the cockpit AND skips every platform-portfolio stack no remaining module requires
(bootstrap/install.sh `stack_toggle` + the `STACKS` list). A skipped stack never creates its
NAMESPACE.

Two templates in gitops/workshop-config rendered namespaced resources into exactly such namespaces:

  * templates/tempo-jaegerui-access.yaml had NO enable guard at all — a Role and a RoleBinding always
    landed in ogsr-observability-workshop, which only the `observability` stack creates, and only
    observability-health-scale requires that stack;
  * templates/sonarqube-user-seed.yaml HAD a `.Values.sonarqube.enabled` guard, and nothing in the
    repo ever set that value — not bootstrap/install.sh's helm.parameters, not helm/bootstrap — so a
    ServiceAccount, Role, RoleBinding and Job always landed in `sonarqube`, created only by the
    `appsec` stack, required only by app-security-testing.

An Argo CD Application is all-or-nothing at sync, so ONE un-appliable object fails the WHOLE
workshop-config app: no cockpits, no attendee namespaces, no Gitea seeding. `modules_disabled:
[observability-health-scale]` — printed as an example in vars.example.yaml — produced a broken
install. That is why it was a SEV1 and not a cosmetic finding.

The second bullet is the reason this guard checks BEHAVIOUR rather than looking for `if` statements:
the sonarqube template was guarded, it read as guarded in review, and it was not guarded in any
render. Only rendering answers the question.

WHAT IT DOES

    for every configuration of modules_disabled that matters
      -> render gitops/workshop-config with helm
      -> collect every metadata.namespace the render targets but does not itself create
      -> decide, for THAT configuration, whether each such namespace will exist on the cluster
      -> report any that will not

The configurations swept are: the baseline (nothing disabled); for each conditional namespace, ALL
the modules that keep its stack alive disabled together (the adversarial case — a stack shared by two
modules only disappears when both go); each catalogue module disabled on its own (which is the only
thing that can see a namespace appearing ONLY once something is switched off); and every module in
the catalogue disabled at once, which asserts the extreme input still renders and deliberately emits
no namespace finding of its own — see check 4's comment for why duplicating one there would make two
detectors unprovable.

HOW "will this namespace exist?" IS ANSWERED — DERIVED, NEVER REMEMBERED. A hand-maintained table of
namespaces would rot on the first stack rename, and would then go green over the thing it stopped
describing. Four sources, each already the authority for its own fact:

  1. platform-portfolio/stacks/<stack>/kustomization.yaml `resources:` -> the app files a stack
     ACTUALLY ships -> each Application's spec.source.path -> that component's own `resources:` ->
     every `kind: Namespace` in them. Reading the resources LIST rather than globbing apps/*.yaml is
     the same rule platform-portfolio/argocd-bootstrap/lib-components.sh uses, and for the same
     reason: a stack can carry a deliberately commented-out app file (today
     stacks/observability/apps/loki-logging.yaml, capacity-gated), and a glob would credit its
     namespaces to a stack that never installs them.
  2. /modules.yaml `stacks:` -> which modules require which stack, so "disable these N modules and
     the stack goes away" is computed, not assumed.
  3. bootstrap/install.sh -> the base `STACKS=` assignment (always installed) and every
     `STACKS="${STACKS},<name>"` line (conditional). A stack in the base can never be absent, so its
     namespaces are never a finding.
  4. gitops/workshop-config/values.yaml `moduleSlugs` -> the catalogue to sweep (itself generated
     from /modules.yaml by tools/gen-module-slugs.sh).

Only three namespaces are hand-declared, and none of them comes from a portfolio stack at all — see
CLUSTER_OWNED_NAMESPACES below, where each one names its creator.

THE RATCHET, which is the point of building this rather than just fixing two files. A namespace the
render targets that is neither cluster-owned nor traceable to a portfolio stack is NOT ignored and is
NOT assumed fine — it exits 2, un-inspectable, and CI reddens until someone declares what creates it.
So the next template that writes into a new shared namespace cannot repeat SEV1-E quietly; it has to
be classified first. That is deliberately a cost.

THE THREE OUTCOMES ARE DISTINCT, and the third is why this is trustworthy:

    rc 0   every render targeted only namespaces that will exist for that configuration
    rc 1   a render targets a namespace that will NOT exist — the workshop-config Argo app would fail
           to sync entirely on that supported vars.yaml input
    rc 2   the guard COULD NOT INSPECT what it claims to: helm missing or refusing to render, a
           namespace it cannot classify, a collapsed derivation, or a crash

WHAT IS OUT OF SCOPE, and why. gitops/entry-states/* charts also write into shared namespaces, but an
entry state belongs to ONE module and is only ever applied by `ws start` for that module — a disabled
module's entry state is never rendered at a cluster, so the class does not exist there.
platform-portfolio/** is out of scope in the other direction: it is what CREATES the namespaces, and
its own stack selection is the installer's job.

KNOWN BLIND SPOTS IN THE DERIVATION, reported on stdout on every run rather than left implicit. A
component whose kustomization pulls a REMOTE base (components/gitea) or inflates a Helm chart
(components/sonarqube) may create namespaces this guard cannot read from the tree. That degrades
safely and in one direction only: a namespace it cannot attribute to a stack is unclassifiable, which
is rc 2, not a green tick. It can never turn a real finding into a pass.

USAGE
    tools/lint/disabled-module-namespace-guard.py            # check the real tree
    tools/lint/disabled-module-namespace-guard.py --self-test  # prove it fires; must exit EXACTLY 1
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem, not a finding
    print("ERROR: PyYAML is not installed — this guard cannot inspect anything without it.",
          file=sys.stderr)
    sys.exit(2)

try:
    # libyaml, ~10x faster than the pure-Python parser (measured on this repo: 0.024s vs 0.250s per
    # render). This guard parses a ~250-document render close to 300 times per self-test, so the
    # difference is the difference between a 15s and a 75s gate. Identical semantics — CSafeLoader
    # is the C build of SafeLoader, not a laxer parser — so the fallback below is slower and nothing
    # else. Always passed EXPLICITLY to yaml.load/load_all; never bare yaml.load.
    from yaml import CSafeLoader as _Loader
except ImportError:  # pragma: no cover - libyaml absent; correctness unchanged, just slower
    from yaml import SafeLoader as _Loader

REPO_ROOT = Path(__file__).resolve().parents[2]
CHART_DIR = REPO_ROOT / "gitops" / "workshop-config"

# Namespaces that exist on any cluster this workshop installs onto, independent of every
# platform-portfolio stack — so no module selection can ever remove them. Each names its creator;
# nothing else belongs on this list, and anything not on it must be traceable to a stack.
CLUSTER_OWNED_NAMESPACES = {
    # Shipped with OpenShift itself; holds the cluster-wide ImageStreams/Templates catalogue.
    "openshift": "OpenShift built-in",
    # Created by the argocd-bootstrap (the one imperative step) before any stack is selected.
    "openshift-gitops": "argocd-bootstrap",
    # STATE_NS — created directly by bootstrap/install.sh for the ogsr-uninstall-state ConfigMap,
    # outside the portfolio entirely (see .Values.systemNamespace's comment in the chart).
    "ogsr-system": "bootstrap/install.sh",
}


class Uninspectable(Exception):
    """The guard cannot judge the tree — always rc 2, never a silent pass."""


# ── derivation ────────────────────────────────────────────────────────────────────────────────

def _docs(path: Path) -> list:
    try:
        return [d for d in yaml.load_all(path.read_text(), Loader=_Loader) if d]
    except (OSError, yaml.YAMLError) as exc:
        raise Uninspectable(f"cannot parse {path}: {exc}") from exc


def _is_remote(entry: str) -> bool:
    """A kustomize `resources:` entry this guard cannot read from the tree."""
    return entry.startswith(("http://", "https://", "git@")) or "?ref=" in entry


def _kustomize_resources(kdir: Path) -> tuple[list[str], list[str]]:
    """`resources:` of kdir's kustomization, split into local paths and un-readable entries.

    Both lists are built as comprehensions, deliberately. The `opaque` half is a REPORT, not a
    detector — a remote base or a helmCharts inflation is normal in this portfolio and decides no
    exit code (an unattributable namespace is what exits 2, and that decision is made in check()).
    Written as `.append` calls, tools/lint/_canary-coverage.py classified them as finding-emission
    sites and correctly reported them as detectors nothing could prove, because blinding them
    changes neither mode's exit code. The honest fix is the shape, not a ledger entry: this code
    never decided anything, and now it does not look like it does.
    """
    k = kdir / "kustomization.yaml"
    if not k.exists():
        return [], []
    try:
        doc = yaml.load(k.read_text(), Loader=_Loader) or {}
    except yaml.YAMLError as exc:
        raise Uninspectable(f"cannot parse {k}: {exc}") from exc
    entries = doc.get("resources") or []
    where = kdir.relative_to(REPO_ROOT)
    local = [e for e in entries if not _is_remote(e)]
    opaque = [f"{where} -> remote base {e}" for e in entries if _is_remote(e)]
    if "helmCharts" in doc:
        opaque = opaque + [f"{where} -> inflates a Helm chart (helmCharts:)"]
    return local, opaque


def derive_stack_namespaces(root: Path) -> tuple[dict[str, set[str]], list[str]]:
    """stack name -> namespaces its ACTIVE components create. Also returns the blind spots."""
    stacks_dir = root / "platform-portfolio" / "stacks"
    if not stacks_dir.is_dir():
        raise Uninspectable(f"{stacks_dir} is missing — cannot derive which stack creates what")
    out: dict[str, set[str]] = {}
    blind: list[str] = []
    for stack in sorted(p for p in stacks_dir.iterdir() if p.is_dir()):
        app_files, opaque = _kustomize_resources(stack)
        blind.extend(opaque)
        namespaces: set[str] = set()
        for rel in app_files:
            app_path = stack / rel
            if not app_path.exists():
                raise Uninspectable(
                    f"{stack.name}/kustomization.yaml lists {rel}, which does not exist")
            for doc in _docs(app_path):
                if doc.get("kind") != "Application":
                    continue
                comp_rel = ((doc.get("spec") or {}).get("source") or {}).get("path")
                if not comp_rel:
                    continue
                comp_dir = root / comp_rel
                if not comp_dir.is_dir():
                    raise Uninspectable(
                        f"{stack.name} Application points at {comp_rel}, which is not a directory")
                comp_files, comp_opaque = _kustomize_resources(comp_dir)
                blind.extend(comp_opaque)
                for cf in comp_files:
                    cf_path = comp_dir / cf
                    if not cf_path.exists():
                        continue
                    for cdoc in _docs(cf_path):
                        if cdoc.get("kind") == "Namespace":
                            name = (cdoc.get("metadata") or {}).get("name")
                            if name:
                                namespaces.add(name)
        out[stack.name] = namespaces
    if not out:
        raise Uninspectable("no portfolio stacks found — the derivation collapsed")
    return out, sorted(set(blind))


def derive_module_stacks(root: Path) -> dict[str, set[str]]:
    """module slug -> the stacks its lab requires, from /modules.yaml."""
    path = root / "modules.yaml"
    if not path.exists():
        raise Uninspectable(f"{path} is missing — cannot tell which module needs which stack")
    doc = yaml.load(path.read_text(), Loader=_Loader) or {}
    modules = doc.get("modules") or []
    if not modules:
        raise Uninspectable("modules.yaml lists no modules — the derivation collapsed")
    out: dict[str, set[str]] = {}
    for mod in modules:
        slug = mod.get("slug")
        if not slug:
            raise Uninspectable(f"a modules.yaml entry has no slug: {mod!r}")
        out[slug] = {s for s in (mod.get("stacks") or []) if s and s != "null"}
    return out


def derive_stack_gating(root: Path) -> tuple[set[str], set[str]]:
    """(always-installed stacks, conditionally-installed stacks) read from bootstrap/install.sh.

    Parsed rather than declared so a stack moving between the two can never leave this guard
    asserting yesterday's installer. If neither shape is found, that is rc 2 — the installer was
    restructured and this parse needs revisiting, which must not read as "nothing conditional".
    """
    path = root / "bootstrap" / "install.sh"
    if not path.exists():
        raise Uninspectable(f"{path} is missing — cannot tell which stacks are always installed")
    text = path.read_text()
    base = re.search(r'^STACKS="([a-z0-9,\-]+)"\s*$', text, re.MULTILINE)
    if not base:
        raise Uninspectable(
            "no base `STACKS=\"...\"` assignment found in bootstrap/install.sh — the installer's "
            "stack selection was restructured and this guard's parse must be updated")
    always = {s for s in base.group(1).split(",") if s}
    conditional = set(re.findall(r'STACKS="\$\{STACKS\},([a-z0-9\-]+)"', text))
    if not conditional:
        raise Uninspectable(
            "no conditional `STACKS=\"${STACKS},<name>\"` lines found in bootstrap/install.sh — "
            "either the installer changed shape or this parse is broken; refusing to report clean")
    return always, conditional


def module_catalogue(chart_dir: Path) -> list[str]:
    values = yaml.load((chart_dir / "values.yaml").read_text(), Loader=_Loader) or {}
    slugs = values.get("moduleSlugs") or []
    if not slugs:
        raise Uninspectable(
            f"{chart_dir}/values.yaml has no moduleSlugs — regenerate with tools/gen-module-slugs.sh")
    return list(slugs)


# ── rendering ─────────────────────────────────────────────────────────────────────────────────

def render(chart_dir: Path, disabled: list[str]) -> list[dict]:
    """helm template the chart with modulesDisabledCSV=<disabled>, via a VALUES FILE.

    Not `--set`: helm's --set parser splits an unescaped comma into separate keys, so
    `--set modulesDisabledCSV=a,b` fails with `key "b" has no value` and a sweep that used it would
    only ever exercise single-module configurations. A values file carries the CSV verbatim, which
    is what Argo's helm.parameters delivers.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        # userCount 2: two attendees exercise the per-user loops without a 26-module render taking
        # longer than it needs to. The shared-namespace resources this guard is about are rendered
        # once regardless of cohort size.
        yaml.safe_dump({"userCount": 2, "modulesDisabledCSV": ",".join(disabled)}, fh)
        vals = fh.name
    try:
        proc = subprocess.run(
            ["helm", "template", "guard-render", str(chart_dir), "-f", vals],
            capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise Uninspectable("helm is not on PATH — cannot render anything") from exc
    finally:
        os.unlink(vals)
    if proc.returncode != 0:
        raise Uninspectable(
            f"helm refused to render with modulesDisabledCSV={','.join(disabled) or '(empty)'}:\n"
            + proc.stderr.strip())
    try:
        return [d for d in yaml.load_all(proc.stdout, Loader=_Loader) if d]
    except yaml.YAMLError as exc:
        raise Uninspectable(f"the render is not parseable YAML: {exc}") from exc


def foreign_namespaces(docs: list[dict]) -> dict[str, set[str]]:
    """namespace -> kinds, for namespaces the render targets but does not itself create."""
    created = {(d.get("metadata") or {}).get("name")
               for d in docs if d.get("kind") == "Namespace"}
    out: dict[str, set[str]] = {}
    for doc in docs:
        ns = (doc.get("metadata") or {}).get("namespace")
        if not ns:
            continue
        if not isinstance(ns, str):
            # A non-string metadata.namespace means the render emitted something this guard cannot
            # reason about (an unsubstituted placeholder reads as a YAML flow mapping, for one).
            # That is un-inspectable, never clean.
            raise Uninspectable(
                f"a rendered {doc.get('kind') or '?'} has a non-string metadata.namespace "
                f"({ns!r}) — the guard cannot judge what namespace it targets")
        if ns not in created:
            out.setdefault(ns, set()).add(doc.get("kind") or "?")
    return out


# ── the check ─────────────────────────────────────────────────────────────────────────────────

def check(chart_dir: Path, root: Path, quiet: bool = False) -> int:
    def say(*args):
        if not quiet:
            print(*args)

    stack_ns, blind = derive_stack_namespaces(root)
    module_stacks = derive_module_stacks(root)
    always, conditional = derive_stack_gating(root)
    catalogue = module_catalogue(chart_dir)

    # namespace -> owning stack, for every namespace any portfolio stack creates.
    ns_stack: dict[str, str] = {}
    for stack, namespaces in stack_ns.items():
        for ns in namespaces:
            ns_stack[ns] = stack

    say(f"stacks: {len(stack_ns)} ({len(always)} always installed, "
        f"{len(conditional)} conditional) · modules: {len(module_stacks)} · "
        f"catalogue swept: {len(catalogue)}")
    if blind:
        say("derivation blind spots (a namespace only these create is UNCLASSIFIABLE -> rc 2, "
            "never a pass):")
        for b in blind:
            say(f"  · {b}")

    findings: list[str] = []
    unclassifiable: list[str] = []

    def keep_alive(ns: str) -> list[str] | None:
        """Modules whose presence keeps ns's stack installed. None = ns is not stack-owned."""
        stack = ns_stack.get(ns)
        if stack is None:
            return None
        if stack in always:
            return []  # always installed; no module selection can remove it
        return sorted(s for s, stacks in module_stacks.items() if stack in stacks)

    # 1. baseline — everything enabled. Classify every foreign namespace once, here.
    base_docs = render(chart_dir, [])
    base_foreign = foreign_namespaces(base_docs)
    say(f"\nbaseline render: {len(base_docs)} documents, "
        f"{len(base_foreign)} namespaces targeted but not created by the chart")
    for ns in sorted(base_foreign):
        kinds = ",".join(sorted(base_foreign[ns]))
        if ns in CLUSTER_OWNED_NAMESPACES:
            say(f"  {ns:32s} always exists ({CLUSTER_OWNED_NAMESPACES[ns]})   [{kinds}]")
            continue
        alive = keep_alive(ns)
        if alive is None:
            unclassifiable.append(
                f"{ns} (targeted with {kinds}) — no portfolio stack creates it and it is not in "
                f"CLUSTER_OWNED_NAMESPACES. Declare what creates it, or the guard cannot say "
                f"whether a disabled module removes it.")
            continue
        stack = ns_stack[ns]
        if not alive:
            if stack in always:
                say(f"  {ns:32s} always exists (stack {stack}, always installed)   [{kinds}]")
            else:
                # A conditional stack no module requires: its presence is decided by something
                # modules_disabled cannot express (ai-assist follows the MaaS credential;
                # trust-demo is an expert-only override). Rendering into it cannot be proven safe.
                findings.append(
                    f"{ns} is created by the `{stack}` stack, which is CONDITIONAL and which no "
                    f"module requires — its installation is decided outside module selection, so "
                    f"this render cannot be proven safe on any input. Targeted with: {kinds}")
        else:
            say(f"  {ns:32s} needs stack {stack}, kept alive by "
                f"{len(alive)} module(s)   [{kinds}]")

    # 2. the adversarial case per conditional namespace: disable EVERY module that keeps it alive.
    say("")
    for ns in sorted(base_foreign):
        if ns in CLUSTER_OWNED_NAMESPACES:
            continue
        alive = keep_alive(ns)
        if not alive:
            continue
        docs = render(chart_dir, alive)
        still = foreign_namespaces(docs)
        listed = ", ".join(alive)
        if ns in still:
            findings.append(
                f"{ns} is still targeted ({','.join(sorted(still[ns]))}) with "
                f"modules_disabled: [{listed}] — every module needing the `{ns_stack[ns]}` stack is "
                f"disabled there, so the stack is skipped, the namespace is never created, and the "
                f"whole workshop-config Argo app fails to sync on that supported input.")
        else:
            say(f"ok  disabling [{listed}] removes every resource targeting {ns}")

    # 3. sweep the catalogue one module at a time: every render must succeed and stay classifiable.
    say("")
    for slug in catalogue:
        docs = render(chart_dir, [slug])
        for ns in foreign_namespaces(docs):
            if ns in CLUSTER_OWNED_NAMESPACES or ns in base_foreign:
                continue
            unclassifiable.append(
                f"{ns} appears only when {slug} is disabled — a namespace absent from the baseline "
                f"render cannot be classified against it. Declare what creates it.")
    say(f"ok  all {len(catalogue)} single-module renders succeeded and introduced no new namespace")

    # 4. the extreme: the whole catalogue disabled at once must still RENDER. Deliberately no
    #    namespace findings of its own — check 2 already disables, per namespace, exactly the
    #    modules whose absence removes that namespace's stack, so anything this could report there
    #    it has already reported. Emitting it twice would make BOTH sites unprovable: blinding
    #    either one leaves the other firing, the exit code never changes, and
    #    tools/lint/_canary-coverage.py reports them as detectors that can stop working silently
    #    (its "masking each other" finding — copy-drift-guard's bytes headline and diff body, and
    #    rebuild-scan's two halves signing off each other's regressions). What this call uniquely
    #    proves is that helm survives the extreme input at all: a render failure raises
    #    Uninspectable and exits 2 rather than passing.
    render(chart_dir, catalogue)
    say("ok  the whole-catalogue-disabled render still renders")

    # `quiet` belongs to self_test(), whose canary runs are SUPPOSED to fail: printing four
    # full-dress failure reports before the summary makes a passing self-test read like a broken one.
    def report(*args):
        if not quiet:
            print(*args, file=sys.stderr)

    if unclassifiable:
        report("\nCOULD NOT INSPECT — refusing to report clean:")
        for u in unclassifiable:
            report(f"  ! {u}")
        return 2
    if findings:
        report("\nFAIL — workshop-config renders into a namespace a disabled module's stack never "
               "creates:")
        for f in findings:
            report(f"  x {f}")
        report("\nFix: guard the template on the module, with workshop-config.moduleEnabled "
               "(gitops/workshop-config/templates/_helpers.tpl) — and bump the chart version, "
               "because Argo's manifest cache survives a SHA change.")
        return 1
    say("\nPASS — every render targets only namespaces that will exist for that module selection.")
    return 0


# ── self-test ─────────────────────────────────────────────────────────────────────────────────

_NEW_TEMPLATE = """apiVersion: v1
kind: ConfigMap
metadata:
  name: guard-canary
  namespace: {ns}
data:
  why: planted by disabled-module-namespace-guard.py --self-test
"""

# .format(ns=…) is applied HERE, not left to the planter: this string also carries Go-template
# braces, and a stray unsubstituted {ns} renders as `namespace: {ns}` — which YAML reads as a flow
# MAPPING, not a string, and crashed the walker rather than failing as a control.
_GUARDED_TEMPLATE = (
    '{{- if include "workshop-config.moduleEnabled" '
    '(dict "root" $ "slug" "developer-hub-golden-paths") }}\n'
    + _NEW_TEMPLATE.format(ns="rhdh") + "{{- end }}\n"
)

# A namespace that is INVISIBLE in the baseline render and appears only once a module is disabled —
# the one shape the baseline classification cannot see, and the only canary that reaches check 3's
# emission. Without it that detector would be swept as unproven.
_LATE_TEMPLATE = (
    '{{- if not (include "workshop-config.moduleEnabled" '
    '(dict "root" $ "slug" "agentic-ai")) }}\n'
    + _NEW_TEMPLATE.format(ns="appears-only-when-disabled") + "{{- end }}\n"
)


def _mutate_drop_tempo_guard(chart: Path) -> None:
    path = chart / "templates" / "tempo-jaegerui-access.yaml"
    text = path.read_text()
    guard = ('{{- if include "workshop-config.moduleEnabled" '
             '(dict "root" $ "slug" "observability-health-scale") }}\n')
    if guard not in text or not text.rstrip().endswith("{{- end }}"):
        raise Uninspectable(
            "self-test cannot plant the tempo canary — tempo-jaegerui-access.yaml no longer has "
            "the shape this mutation edits. The canary would silently not apply, and a self-test "
            "that plants nothing passes forever.")
    text = text.replace(guard, "", 1)
    path.write_text(text.rstrip()[: -len("{{- end }}")].rstrip() + "\n")


def _mutate_sonarqube_flag_only(chart: Path) -> None:
    path = chart / "templates" / "sonarqube-user-seed.yaml"
    text = path.read_text()
    guarded = ('{{- if and .Values.sonarqube.enabled (include "workshop-config.moduleEnabled" '
               '(dict "root" $ "slug" "app-security-testing")) }}')
    if guarded not in text:
        raise Uninspectable(
            "self-test cannot plant the sonarqube canary — the guarded condition it reverts is not "
            "in sonarqube-user-seed.yaml any more.")
    path.write_text(text.replace(guarded, "{{- if .Values.sonarqube.enabled }}", 1))


def _planter(name: str, ns: str, body: str | None = None):
    def mutate(chart: Path) -> None:
        (chart / "templates" / f"zz-guard-canary-{name}.yaml").write_text(
            body or _NEW_TEMPLATE.format(ns=ns))
    return mutate


# Each case: (name, mutation, expected rc, why this case exists).
# Expected 1 = a real finding. Expected 2 = correctly refused to judge. Expected 0 = a control that
# must NOT fire, because a false positive here blocks authoring.
_CASES = [
    ("pristine", None, 0,
     "the shipped chart is clean — if this ever fires, every other result is noise"),
    ("tempo-unguarded", _mutate_drop_tempo_guard, 1,
     "SEV1-E itself: the Role/RoleBinding in ogsr-observability-workshop with no enable guard"),
    ("sonarqube-flag-only", _mutate_sonarqube_flag_only, 1,
     "SEV1-E's other half: a guard whose flag nothing sets, which reads as guarded in review"),
    ("new-conditional-ns", _planter("portal", "rhdh"), 1,
     "a NEW template writing into another conditional stack's namespace — proves the guard is not "
     "a two-file hardcode"),
    ("non-module-gated-ns", _planter("lightspeed", "openshift-lightspeed"), 1,
     "a namespace whose stack is gated by the MaaS credential, not by module selection — "
     "un-provable on any input, and must not pass just because no module can remove it"),
    ("undeclared-ns", _planter("orgns", "some-org-namespace"), 2,
     "a namespace nothing in the tree creates must be UN-INSPECTABLE, not assumed fine — this is "
     "the ratchet that closes the class rather than the instance"),
    ("late-ns", _planter("late", "appears-only-when-disabled", _LATE_TEMPLATE), 2,
     "a namespace that appears ONLY once a module is disabled is invisible to the baseline "
     "classification — the single-module sweep is the only thing that can see it"),
    ("unconditional-ns-control", _planter("gitea", "ogsr-gitea"), 0,
     "core-devtools is always installed, so writing into its namespace is legal and must not fire"),
    ("guarded-new-template-control", _planter("guarded", "rhdh", _GUARDED_TEMPLATE), 0,
     "the same rhdh write, correctly guarded on its module — the guard must accept the fix pattern, "
     "not merely notice the absence of one"),
]


def self_test() -> int:
    """Plant known defects in a COPY of the chart and assert each is caught.

    rc 1 = every canary fired as expected and every control stayed silent (what CI asserts)
    rc 0 = a detector is blind: a canary produced a clean result
    rc 2 = the harness itself is broken, a canary was missed with the wrong code, or a control fired
    """
    try:
        stack_ns, _ = derive_stack_namespaces(REPO_ROOT)
    except Uninspectable as exc:
        print(f"self-test harness broken: {exc}", file=sys.stderr)
        return 2

    # The derivation is the guard's foundation; if it collapsed, every case below would agree with
    # every other case for the wrong reason. Assert the two namespaces SEV1-E was about are found.
    for stack, ns in (("observability", "ogsr-observability-workshop"), ("appsec", "sonarqube")):
        if ns not in stack_ns.get(stack, set()):
            print(f"self-test harness broken: the derivation no longer finds {ns} under the "
                  f"{stack} stack, so nothing below proves anything.", file=sys.stderr)
            return 2

    blind, wrong = [], []
    for name, mutate, expected, why in _CASES:
        tmp = Path(tempfile.mkdtemp(prefix="dmng-selftest-"))
        try:
            chart = tmp / "workshop-config"
            shutil.copytree(CHART_DIR, chart)
            if mutate is not None:
                before = sorted((p, p.read_text()) for p in (chart / "templates").rglob("*.yaml"))
                mutate(chart)
                after = sorted((p, p.read_text()) for p in (chart / "templates").rglob("*.yaml"))
                if before == after:
                    print(f"self-test harness broken: mutation {name!r} changed nothing — a canary "
                          f"that does not apply makes the self-test pass forever.", file=sys.stderr)
                    return 2
            try:
                rc = check(chart, REPO_ROOT, quiet=True)
            except Uninspectable as exc:
                print(f"  [{name}] uninspectable: {exc}".replace("\n", " ")[:200])
                rc = 2
            status = "ok " if rc == expected else "MISS"
            print(f"  {status} {name:28s} rc={rc} (expected {expected}) — {why}")
            if rc != expected:
                (blind if rc == 0 else wrong).append(f"{name}: rc={rc}, expected {expected}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    if blind:
        print("\nA DETECTOR IS BLIND — a planted defect produced a clean result:", file=sys.stderr)
        for b in blind:
            print(f"  ! {b}", file=sys.stderr)
        return 0
    if wrong:
        print("\nSELF-TEST HARNESS FAILURE — a canary was missed with the wrong code, or a "
              "false-positive control fired:", file=sys.stderr)
        for w in wrong:
            print(f"  ! {w}", file=sys.stderr)
        return 2
    print(f"\nself-test ok — both halves of SEV1-E are caught in a chart copy, a new template "
          f"writing into a third conditional namespace is caught, an undeclared namespace and one "
          f"that appears only once a module is disabled are both REFUSED rather than assumed fine, "
          f"and three controls (pristine, a write into an always-installed stack's namespace, a "
          f"correctly guarded write) stay silent. {len(_CASES)} cases, and every finding-emission "
          f"site in the real-run call graph is reachable by exactly one of them.")
    return 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true",
                        help="plant known defects in a chart copy and prove they are caught; "
                             "exits 1 on success")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    try:
        return check(CHART_DIR, REPO_ROOT)
    except Uninspectable as exc:
        print(f"\nCOULD NOT INSPECT: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
