#!/usr/bin/env python3
"""copy-drift-guard.py — prove that this repo's hand-maintained duplicates are still in sync.

WHY THIS EXISTS. Several files in this tree exist twice on purpose. Helm cannot read files outside
its own chart, and platform-portfolio/ must stay dependency-free from the rest of the monorepo
(01-ARCHITECTURE §4.0.8), so the same Pipeline / Task / health-check / seed script is authored in a
canonical place AND copied into the chart that ships it. ADR-0001 blesses the duplication. Nothing
blesses the drift: a copy nobody diffs goes stale silently — the chart renders, Argo syncs, the Job
reports success, and the difference only shows up as a broken exercise in the room.

It has happened twice already:
  * gitops/entry-states/deployment-targets-scheduling/files/import.sql lost the CREATE SEQUENCE for
    claim_number_seq (2026-07-29) — in the one entry state whose solve world runs the app with
    schema-management=none, so that copy is the ONLY thing that creates the sequence POST
    /api/claims draws its numbers from.
  * gitops/workshop-config/templates/parasol-tasks.yaml drifted from pipelines/tasks/*.yaml
    (fixed in 9549990).

THIS SUPERSEDES tools/lint/seed-drift-guard.sh, which guarded exactly one of those pairs with
`cmp -s`. Byte identity cannot express the other pairs: three of them are correctly in sync yet
deliberately NOT byte-identical (the chart copy injects a namespace, an owner label, or extra
evidence comments). A byte gate would have reddened main on work that is right — the worst kind of
gate — so nobody could add them, so they went unguarded. The seed pair is absorbed here as
mode="bytes"; its canary discipline is kept (see self_test).

HOW A PAIR IS COMPARED
  mode "bytes"       — the two files must be byte-identical. For non-YAML content (SQL seeds).
  mode "structural"  — both sides are parsed as YAML and compared as data, so COMMENTS DO NOT
                       MATTER (that is the point) and neither does key order or quoting style.

For a structural pair the copy may differ from its source ONLY in ways the pair DECLARES, and the
vocabulary is deliberately small and dumb:

  allow_added   A list of exact paths the copy is allowed to ADD. Nothing else. A path that the
                SOURCE also sets is rejected as allow-list misuse (finding kind "allowlist-misuse"),
                because an allow-list that can hide a changed VALUE is worse than no gate at all —
                the whole failure mode this tool exists to prevent. A key present in the source and
                missing from the copy is ALWAYS a finding; the allow-list never suppresses that.
                Paths are literal lists, not dotted strings: label keys in this repo contain dots
                (workshop.redhat.com/owner) and a dotted mini-language would have to guess.
                Adding a whole subtree needs the subtree's own path listed — the guard will not
                infer "…and everything under it" from a deeper entry.

  subtree       Compare only this path of each document, when the shared content is a fragment
                (pair "argocd-subscription-health-check": the portfolio file also carries a
                controller memory bump the FSC copy has no business repeating).

  heredoc       Pull the compared YAML out of a shell heredoc embedded in the document (same pair:
                the FSC copy applies its half through `oc patch --patch-file` inside a Job). The
                opener and terminator are declared, and a document where they are not found exactly
                once is an exit-2, never a pass.

  lua_paths     Scalars at these paths are Lua source: full-line `--` comments and blank lines are
                ignored, executable lines are compared verbatim. This is the RIGHT predicate for
                that pair, not a weakened one — the two copies deliberately carry different evidence
                comments, and what must not diverge is the code. The stripper refuses to guess: if a
                `--` survives outside a full-line comment (i.e. it might be inside a string literal)
                the guard exits 2 rather than normalize something it cannot lex.

READING THE HELM SIDE. Helm templates are not valid YAML ({{ }} actions are not YAML syntax), so the
copy side is RENDERED with `helm template <chart> --show-only <template>` and the rendered output is
parsed. This is better than stripping the actions before parsing (what the manual audit did): the
values are real, `include`d label helpers expand to the labels that actually reach the cluster, and
nothing is guessed by a regex. The cost is that the guard needs `helm` on PATH and defaulted values
that render — both already true in CI, and a missing/failing helm is an exit 2, never a pass.
Both sides are parsed by the SAME parser, so any resolver quirk cancels out instead of being drift.

USAGE
    tools/lint/copy-drift-guard.py                 # check every declared pair
    tools/lint/copy-drift-guard.py --pair ID       # one pair, for local debugging
    tools/lint/copy-drift-guard.py --list          # the declared pairs and what each allows
    tools/lint/copy-drift-guard.py --self-test     # scan the canary fixtures; MUST exit 1

EXIT CODES (the same contract as tools/lint/curl-format-guard.py and the guard this replaces, so
the workflow steps read alike):
    0  every declared pair is in sync
    1  drift found — or, under --self-test, every canary was correctly detected
    2  the guard could not do its job (missing file, unparseable side, helm/PyYAML absent, empty
       scope, or a canary that went UNdetected). Never confuse this with a clean result.

ADDING A PAIR: append to PAIRS below. Declare the smallest allow_added that is true; if you find
yourself allow-listing a key the source also sets, the answer is to change one of the files, not the
allow-list.

LOCAL YAMLLINT: the canary chart's templates carry Helm actions and are not plain YAML, exactly like
the three real chart template dirs. The maintainer yamllint config is gitignored (2026-07-19 owner
review) so it cannot ship that exclusion with this commit — add

    tools/lint/copy-drift-guard.canary/chart/templates/

to the `ignore:` block of your own .yamllint.yaml, next to helm/bootstrap/templates/.
"""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys
import textwrap

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _scope import Scope  # noqa: E402  (path must be set first; this file is run as a script)

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a machine without PyYAML
    print("copy-drift-guard: PyYAML is not installed. This guard parses YAML properly rather than "
          "pattern-matching it, so it cannot run without a parser — refusing to report clean. "
          "Install it (python3 -m pip install PyYAML) and re-run.", file=sys.stderr)
    sys.exit(2)


# The eight curated Tasks that the workshop layer republishes into the shared library namespace.
# One pair each: the standalone artifact the module and PipelineRuns reference, versus the body
# embedded in the workshop-config chart. Drifted once already (fixed in 9549990).
PARASOL_TASKS = (
    "acs-image-check", "image-size-report", "k6-load-test", "maven-jdk21",
    "roxctl-deployment-check", "sonar-scan", "trivy-scan", "zap-baseline",
)

# Every hand-maintained duplicate this repo is willing to gate. See the module docstring for the
# vocabulary; `why` is what the next person reads when the gate fails on them.
PAIRS: list[dict] = [
    {
        "id": "claims-seed",
        "mode": "bytes",
        "source": {"file": "apps/parasol-claims/src/main/resources/import.sql"},
        "copy": {"file": "gitops/entry-states/deployment-targets-scheduling/files/import.sql"},
        "why": "deployment-targets-scheduling's solve world runs the app with schema-management=none "
               "and loads the schema+seed from this copy, so a missing statement here is a broken "
               "exercise, not a cosmetic diff. Re-copy the file (cp source copy) — never hand-edit "
               "the copy — and bump the chart version so Argo's manifest cache picks it up.",
    },
    {
        "id": "pipelines-fundamentals-pipeline",
        "mode": "structural",
        "source": {"file": "pipelines/pipeline/parasol-claims-build.yaml"},
        "copy": {"chart": "gitops/entry-states/pipelines-fundamentals",
                 "template": "templates/pipeline.yaml"},
        # The chart copy is namespaced to the attendee's {user}-cicd and carries the delivery owner
        # stamp; the canonical artifact is namespace-free so it can be read/applied anywhere.
        "allow_added": [
            ["metadata", "namespace"],
            ["metadata", "labels", "workshop.redhat.com/owner"],
        ],
        "why": "the module's readable Pipeline artifact and the entry state that materializes it "
               "must describe the same run, or the attendee reads one pipeline and runs another.",
    },
    {
        "id": "app-security-testing-pipeline",
        "mode": "structural",
        "source": {"file": "pipelines/pipeline/parasol-claims-devsecops.yaml"},
        "copy": {"chart": "gitops/entry-states/app-security-testing",
                 "template": "templates/pipeline.yaml"},
        # This one takes only the namespace: it predates the owner-label sweep and its chart does
        # not stamp the Pipeline. Declared as it IS, not as its sibling is.
        "allow_added": [["metadata", "namespace"]],
        "why": "same contract as pipelines-fundamentals: the DevSecOps capstone the attendee reads "
               "is the one the entry state runs.",
    },
    {
        "id": "argocd-subscription-health-check",
        "mode": "structural",
        # Only the health-check override is shared. The portfolio file also raises the controller
        # memory limit, which the FSC entrypoint does elsewhere — hence the subtree.
        "source": {"file": "platform-portfolio/argocd-bootstrap/operator/argocd-controller-resources.yaml",
                   "subtree": ["spec", "resourceHealthChecks"]},
        "copy": {"chart": "helm/bootstrap",
                 "template": "templates/job-argocd-health-tuning.yaml",
                 # The FSC copy applies its half as an `oc patch --patch-file` heredoc inside a Job.
                 "heredoc": {"path": ["spec", "template", "spec", "containers", 0, "args", 0],
                             "opener": "<<'PATCHEOF'", "terminator": "PATCHEOF"},
                 "subtree": ["spec", "resourceHealthChecks"]},
        "allow_added": [],
        # The two copies carry different evidence comments on purpose (the FSC one repeats the KEDA
        # finding inline, where `oc get argocd -o yaml` will show it at debug time). The Lua itself
        # must not diverge — that is what this pair gates.
        "lua_paths": [[0, "check"]],
        "why": "the script-bootstrap path and the FSC/helm path each carry their own copy of the "
               "Subscription health check (platform-portfolio may not depend on the monorepo). A "
               "fix applied to one and not the other means adopted-operator false Degradeds come "
               "back on whichever path the next cluster uses.",
    },
]

# Pair (c) — expanded rather than special-cased, so each Task fails on its own name.
for _task in PARASOL_TASKS:
    PAIRS.append({
        "id": f"parasol-task-{_task}",
        "mode": "structural",
        "source": {"file": f"pipelines/tasks/{_task}.yaml"},
        "copy": {"chart": "gitops/workshop-config",
                 "template": "templates/parasol-tasks.yaml",
                 "select": {"kind": "Task", "name": _task}},
        # The library copy is stamped for `oc get -A -l workshop.redhat.com/owner=ogsr`; the
        # standalone artifact is the portable one and is not.
        "allow_added": [["metadata", "labels", "workshop.redhat.com/owner"]],
        "why": "attendees resolve this Task from the shared library by cluster resolver but READ "
               "the standalone artifact. The two drifted before (9549990) and the lab taught a "
               "Task nobody was running.",
    })


# A LITERAL, deliberately not len(PAIRS): the point is that shrinking PAIRS must not be able to
# shrink its own floor. Truncating the list the driver iterates (`PAIRS[:1]`) collapses the "pairs
# compared" count below this; editing PAIRS itself trips the self-test, which asserts the two agree.
# Adding a pair means bumping this number in the same change.
MIN_PAIRS = 12

# Structural comparison nodes across all pairs, measured 2026-08-01: 995. The floor is well under
# that (Task bodies and pipelines grow and shrink) and far over what a fragment comparison yields.
MIN_STRUCTURAL_NODES = 600


class GuardError(Exception):
    """The guard cannot do its job for this pair. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


# ---------------------------------------------------------------------------- loading a side


def _load_yaml_documents(text: str, origin: str) -> list:
    try:
        docs = [d for d in yaml.safe_load_all(text) if d is not None]
    except yaml.YAMLError as exc:
        raise GuardError(f"{origin} is not parseable as YAML: {exc}") from exc
    if not docs:
        raise GuardError(f"{origin} parsed to zero YAML documents — refusing to compare nothing.")
    return docs


def _select_document(docs: list, selector: dict | None, origin: str):
    """Pick the one document this side is about. Ambiguity is an error, never a first-match guess."""
    if selector is None:
        if len(docs) != 1:
            raise GuardError(
                f"{origin} holds {len(docs)} YAML documents and the pair declares no `select`. "
                "Add select: {kind: …, name: …} — picking the first would gate the wrong object.")
        return docs[0]
    matches = [
        d for d in docs
        if isinstance(d, dict)
        and d.get("kind") == selector["kind"]
        and isinstance(d.get("metadata"), dict)
        and d["metadata"].get("name") == selector["name"]
    ]
    if len(matches) != 1:
        raise GuardError(
            f"{origin}: selector kind={selector['kind']} name={selector['name']} matched "
            f"{len(matches)} document(s), expected exactly 1. The object was renamed, removed, or "
            "duplicated — update the pair rather than leaving the gate pointing at nothing.")
    return matches[0]


def _render_chart(root: pathlib.Path, chart: str, template: str) -> str:
    """`helm template --show-only`, because a Helm template is not YAML until Helm has rendered it."""
    if shutil.which("helm") is None:
        raise GuardError("helm is not on PATH. The copy side of this pair is a Helm template, which "
                         "is not valid YAML until it is rendered — refusing to guess at it.")
    cmd = ["helm", "template", str(root / chart), "--show-only", template]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise GuardError(f"`helm template {chart} --show-only {template}` failed "
                         f"(rc={proc.returncode}):\n{proc.stderr.strip()}")
    if not proc.stdout.strip():
        raise GuardError(f"`helm template {chart} --show-only {template}` rendered nothing. The "
                         "template was renamed, or its content is behind a value that defaults off.")
    return proc.stdout


def _extract_heredoc(document, spec: dict, origin: str) -> str:
    """Return the body of the declared shell heredoc carried inside `document` at spec['path']."""
    scalar = _walk_path(document, spec["path"], origin, what="heredoc host")
    if not isinstance(scalar, str):
        raise GuardError(f"{origin}: {_fmt_path(spec['path'])} is a {type(scalar).__name__}, not the "
                         "shell script the heredoc was declared to live in.")
    lines = scalar.splitlines()
    openers = [i for i, line in enumerate(lines) if spec["opener"] in line]
    if len(openers) != 1:
        raise GuardError(f"{origin}: found {len(openers)} occurrences of the heredoc opener "
                         f"{spec['opener']!r}, expected exactly 1. The script was restructured — "
                         "update the pair rather than comparing a fragment of it.")
    body: list[str] = []
    for line in lines[openers[0] + 1:]:
        if line.strip() == spec["terminator"]:
            break
        body.append(line)
    else:
        raise GuardError(f"{origin}: heredoc opened with {spec['opener']!r} is never terminated by "
                         f"{spec['terminator']!r}.")
    if not body:
        raise GuardError(f"{origin}: the {spec['terminator']!r} heredoc body is empty.")
    return textwrap.dedent("\n".join(body)) + "\n"


def _walk_path(node, path, origin: str, what: str = "subtree"):
    """Follow a declared literal path into parsed YAML. A missing step is an error, not a None."""
    cursor = node
    for step in path:
        if isinstance(step, int):
            if not isinstance(cursor, list) or step >= len(cursor):
                raise GuardError(f"{origin}: declared {what} path {_fmt_path(path)} does not exist "
                                 f"(index {step} is out of range).")
        else:
            if not isinstance(cursor, dict) or step not in cursor:
                raise GuardError(f"{origin}: declared {what} path {_fmt_path(path)} does not exist "
                                 f"(no key {step!r}).")
        cursor = cursor[step]
    return cursor


def load_side(root: pathlib.Path, spec: dict, label: str):
    """Parse one side of a structural pair down to the object that must match."""
    if "chart" in spec:
        origin = f"{label} {spec['chart']}/{spec['template']} (helm-rendered)"
        text = _render_chart(root, spec["chart"], spec["template"])
    else:
        path = root / spec["file"]
        if not path.is_file():
            raise GuardError(f"{label} {spec['file']} does not exist. It was moved or renamed; "
                             "update PAIRS rather than leaving the gate pointing at nothing.")
        origin = f"{label} {spec['file']}"
        text = path.read_text(encoding="utf-8")

    document = _select_document(_load_yaml_documents(text, origin), spec.get("select"), origin)

    if "heredoc" in spec:
        inner = _extract_heredoc(document, spec["heredoc"], origin)
        document = _select_document(_load_yaml_documents(inner, f"{origin} heredoc"), None,
                                    f"{origin} heredoc")
        origin = f"{origin} heredoc"

    if "subtree" in spec:
        document = _walk_path(document, spec["subtree"], origin)
    return document, origin


# ---------------------------------------------------------------------------- normalizing Lua


def lua_code_only(text: str, origin: str) -> str:
    """Drop full-line `--` comments and blank lines; keep every executable line verbatim.

    Refuses to normalize what it cannot lex: a `--` anywhere other than the start of a stripped
    line might be inside a Lua string literal, and a comment-stripper that guesses about that could
    delete real code from one side and call the pair clean. Both current copies satisfy the
    precondition (checked, 2026-07-29: zero such occurrences in either Lua body).
    """
    kept = []
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("--"):
            continue
        if "--" in line:
            raise GuardError(
                f"{origin}: line {lineno} contains `--` outside a full-line comment:\n"
                f"    {line.strip()}\n"
                "This guard only knows how to ignore whole-line Lua comments; a `--` mid-line could "
                "be inside a string literal. Refusing to guess — move the comment onto its own line, "
                "or drop lua_paths from this pair and compare the scalars verbatim.")
        kept.append(line.rstrip())
    if not kept:
        raise GuardError(f"{origin}: the Lua scalar is entirely comments and blank lines.")
    return "\n".join(kept)


# ---------------------------------------------------------------------------- comparing


def _fmt_path(path) -> str:
    """Render a literal path readably without inventing a syntax that could be ambiguous."""
    if not path:
        return "<root>"
    out = []
    for step in path:
        if isinstance(step, int):
            out.append(f"[{step}]")
        elif any(c in str(step) for c in ".[]/ "):
            out.append(f"['{step}']")
        else:
            out.append(f".{step}")
    return "".join(out).lstrip(".")


class Comparison:
    """Walks two parsed sides and records every way the copy is not the source."""

    def __init__(self, allow_added, lua_paths):
        self.allow_added = [list(p) for p in (allow_added or [])]
        self.lua_paths = [list(p) for p in (lua_paths or [])]
        self.findings: list[tuple[str, list, str]] = []
        # How many nodes this walk actually visited. Reported up to the scope ledger so a pair that
        # silently compares a fragment of what it used to — or nothing — fails instead of passing.
        self.nodes = 0

    def _record(self, kind, path, detail):
        self.findings.append((kind, list(path), detail))

    def compare(self, source, copy, path=None):
        path = list(path or [])
        self.nodes += 1

        if path in self.lua_paths:
            if not isinstance(source, str) or not isinstance(copy, str):
                self._record("type", path, "declared as Lua but at least one side is not a string")
                return
            src_code = lua_code_only(source, f"source {_fmt_path(path)}")
            cpy_code = lua_code_only(copy, f"copy {_fmt_path(path)}")
            if src_code != cpy_code:
                self._record("lua-value", path, _first_line_delta(src_code, cpy_code))
            return

        if type(source) is not type(copy) and not (
                isinstance(source, (int, float)) and isinstance(copy, (int, float))):
            self._record("type", path,
                         f"source is {type(source).__name__}, copy is {type(copy).__name__}")
            return

        if isinstance(source, dict):
            for key in source:
                child = path + [key]
                if key not in copy:
                    self._record("missing", child,
                                 "set in the source, absent from the copy (never allow-listed)")
                    continue
                if child in self.allow_added:
                    self._record("allowlist-misuse", child,
                                 "declared in allow_added, but the SOURCE sets it too. An "
                                 "allow-listed key may only be ADDED by the copy — this entry could "
                                 "hide a changed value. Remove it from allow_added.")
                self.compare(source[key], copy[key], child)
            for key in copy:
                child = path + [key]
                if key not in source and child not in self.allow_added:
                    self._record("added", child,
                                 f"present only in the copy (= {_short(copy[key])}). If this is "
                                 "intentional, declare the exact path in the pair's allow_added.")
            return

        if isinstance(source, list):
            if len(source) != len(copy):
                self._record("length", path,
                             f"source has {len(source)} item(s), copy has {len(copy)}")
                return
            for i, (s_item, c_item) in enumerate(zip(source, copy)):
                self.compare(s_item, c_item, path + [i])
            return

        if source != copy:
            self._record("value", path, f"source = {_short(source)} / copy = {_short(copy)}")


def _short(value, limit: int = 120) -> str:
    text = repr(value)
    return text if len(text) <= limit else text[:limit] + "…"


def _first_line_delta(source: str, copy: str) -> str:
    """The first differing executable line, which is what the reader needs to go fix."""
    s_lines, c_lines = source.splitlines(), copy.splitlines()
    for i in range(max(len(s_lines), len(c_lines))):
        s = s_lines[i] if i < len(s_lines) else "<end of source>"
        c = c_lines[i] if i < len(c_lines) else "<end of copy>"
        if s != c:
            return (f"first differing executable line (comments ignored), #{i + 1}:\n"
                    f"        source: {s.strip()}\n"
                    f"        copy  : {c.strip()}")
    return "executable content differs"  # pragma: no cover - unreachable while the strings differ


# ---------------------------------------------------------------------------- per-pair drivers


class PairResult:
    """What checking one pair produced: the human problems, the DETECTOR KINDS behind them, and how
    much was actually inspected.

    The kinds are carried here for one reason. The self-test used to reach past check_pair() and
    call load_side + Comparison itself, so `check_structural_pair` — the production path for 11 of
    the 12 pairs and the ONLY route to four of the six detectors — could be blinded to return no
    findings and BOTH the self-test and the real run stayed green (audit, 2026-08-01). The self-test
    now goes through check_pair() like main() does, which it can only do if the kinds survive the
    trip.
    """

    def __init__(self, problems=None, kinds=None, nodes: int = 0):
        self.problems: list[str] = list(problems or [])
        self.kinds: set[str] = set(kinds or ())
        self.nodes = nodes

    def __bool__(self) -> bool:
        return bool(self.problems)


def check_bytes_pair(root: pathlib.Path, pair: dict) -> PairResult:
    problems = []
    paths = {}
    for label, spec in (("source", pair["source"]), ("copy", pair["copy"])):
        path = root / spec["file"]
        if not path.is_file():
            raise GuardError(f"{label} {spec['file']} does not exist. It was moved or renamed; "
                             "update PAIRS rather than leaving the gate pointing at nothing.")
        paths[label] = path
    source_bytes = paths["source"].read_bytes()
    copy_bytes = paths["copy"].read_bytes()
    if source_bytes != copy_bytes:
        problems.append(f"  bytes: {pair['copy']['file']} is no longer a byte-identical copy of "
                        f"{pair['source']['file']}")
        import difflib
        diff = difflib.unified_diff(
            source_bytes.decode("utf-8", "replace").splitlines(),
            copy_bytes.decode("utf-8", "replace").splitlines(),
            fromfile=pair["source"]["file"], tofile=pair["copy"]["file"], lineterm="")
        for line in list(diff)[:40]:
            problems.append(f"      {line}")
    # One node per side actually read. Raised HERE, past the two is_file() gates, so a driver that
    # stops reaching this function cannot satisfy the floor by other means.
    return PairResult(problems, {"bytes"} if problems else set(), nodes=2)


def check_structural_pair(root: pathlib.Path, pair: dict) -> PairResult:
    source, _ = load_side(root, pair["source"], "source")
    copy, _ = load_side(root, pair["copy"], "copy")
    comparison = Comparison(pair.get("allow_added"), pair.get("lua_paths"))
    comparison.compare(source, copy)
    return PairResult(
        [f"  {kind}: {_fmt_path(path)}\n      {detail}"
         for kind, path, detail in comparison.findings],
        {kind for kind, _, _ in comparison.findings},
        nodes=comparison.nodes)


def check_pair(root: pathlib.Path, pair: dict) -> PairResult:
    """THE production entry point. main() and self_test() both go through here — see PairResult."""
    if pair["mode"] == "bytes":
        return check_bytes_pair(root, pair)
    return check_structural_pair(root, pair)


# ---------------------------------------------------------------------------- self-test


def _canary_pairs(root: pathlib.Path) -> list[dict]:
    """Synthetic pairs over tools/lint/copy-drift-guard.canary/, one per detector.

    Each declares the finding kinds it MUST produce (or none, for the pairs that must stay clean).
    Deliberately static fixtures rather than a canary derived from a live file: the guard this
    replaces built its canary by deleting a CREATE SEQUENCE line from the real import.sql, which
    quietly turns into an exit 2 the day the app's seed script changes shape. What has to be tested
    here is the DETECTOR, not the data.
    """
    fixture = "tools/lint/copy-drift-guard.canary"
    chart = f"{fixture}/chart"
    return [
        {   # The 2026-07-29 seed defect, reproduced: the copy is missing one statement.
            "id": "canary-bytes-drift", "mode": "bytes",
            "source": {"file": f"{fixture}/seed/source.sql"},
            "copy": {"file": f"{fixture}/seed/copy-drifted.sql"},
            "expect": {"bytes"},
        },
        {   # …and the same detector must NOT cry wolf on an identical pair.
            "id": "canary-bytes-clean", "mode": "bytes",
            "source": {"file": f"{fixture}/seed/source.sql"},
            "copy": {"file": f"{fixture}/seed/copy-clean.sql"},
            "expect": set(),
        },
        {   # A rendered chart copy that differs only in what the pair allows: must be clean.
            "id": "canary-structural-clean", "mode": "structural",
            "source": {"file": f"{fixture}/manifest-source.yaml"},
            "copy": {"chart": chart, "template": "templates/clean.yaml"},
            "allow_added": [["metadata", "namespace"],
                            ["metadata", "labels", "workshop.redhat.com/owner"]],
            "expect": set(),
        },
        {   # Real semantic drift of all three shapes at once.
            "id": "canary-structural-drift", "mode": "structural",
            "source": {"file": f"{fixture}/manifest-source.yaml"},
            "copy": {"chart": chart, "template": "templates/drifted.yaml"},
            "allow_added": [["metadata", "namespace"],
                            ["metadata", "labels", "workshop.redhat.com/owner"]],
            "expect": {"value", "added", "missing"},
        },
        {   # An allow-list entry pointed at a key the source sets: the misuse must be reported
            # even though the value also differs, or a future pair could silence a real change.
            "id": "canary-allowlist-misuse", "mode": "structural",
            "source": {"file": f"{fixture}/manifest-source.yaml"},
            "copy": {"chart": chart, "template": "templates/misuse.yaml"},
            "allow_added": [["metadata", "namespace"],
                            ["metadata", "labels", "workshop.redhat.com/owner"],
                            ["spec", "params", 0, "default"]],
            "expect": {"allowlist-misuse", "value"},
        },
        {   # Lua in a heredoc in a Job: identical code, different comments -> clean.
            "id": "canary-lua-clean", "mode": "structural",
            "source": {"file": f"{fixture}/lua-source.yaml",
                       "subtree": ["spec", "resourceHealthChecks"]},
            "copy": {"chart": chart, "template": "templates/job-clean.yaml",
                     "heredoc": {"path": ["spec", "template", "spec", "containers", 0, "args", 0],
                                 "opener": "<<'PATCHEOF'", "terminator": "PATCHEOF"},
                     "subtree": ["spec", "resourceHealthChecks"]},
            "lua_paths": [[0, "check"]],
            "expect": set(),
        },
        {   # …and one changed Lua branch -> drift.
            "id": "canary-lua-drift", "mode": "structural",
            "source": {"file": f"{fixture}/lua-source.yaml",
                       "subtree": ["spec", "resourceHealthChecks"]},
            "copy": {"chart": chart, "template": "templates/job-drifted.yaml",
                     "heredoc": {"path": ["spec", "template", "spec", "containers", 0, "args", 0],
                                 "opener": "<<'PATCHEOF'", "terminator": "PATCHEOF"},
                     "subtree": ["spec", "resourceHealthChecks"]},
            "lua_paths": [[0, "check"]],
            "expect": {"lua-value"},
        },
    ]


def _assert_lua_stripper_refuses_to_guess() -> None:
    """The Lua normalizer must fail loudly on input it cannot lex, not silently mangle it."""
    try:
        lua_code_only('local s = "a -- b"\n', "unit")
    except GuardError:
        pass
    else:
        raise GuardError("SELF-TEST FAILED — lua_code_only accepted a `--` inside a string literal. "
                         "It would strip real code and call the pair clean.")
    # Lua's `..` concatenation is everywhere in the real snippet and must NOT trip the refusal.
    lua_code_only('msg = msg .. condition.type .. "\\n"\n', "unit")


def self_test(root: pathlib.Path) -> int:
    fixture_root = root / "tools/lint/copy-drift-guard.canary"
    if not fixture_root.is_dir():
        print("::error::copy-drift-guard: the canary fixture directory is missing — detection is "
              "unproven, so a clean result on the real tree means nothing.", file=sys.stderr)
        return 2

    canaries = _canary_pairs(root)
    if not canaries:
        print("::error::copy-drift-guard: no canary pairs declared — refusing to call a self-test "
              "over an empty scope a pass.", file=sys.stderr)
        return 2

    try:
        _assert_lua_stripper_refuses_to_guess()
    except GuardError as exc:
        print(f"::error::copy-drift-guard {exc}", file=sys.stderr)
        return 2

    kinds_seen: set[str] = set()
    failures: list[str] = []
    for pair in canaries:
        expected = pair["expect"]
        try:
            # THROUGH check_pair, deliberately. The previous version called load_side + Comparison
            # directly, which meant check_structural_pair — the production path for 11 of the 12
            # real pairs — was never executed by the self-test at all, and could be blinded to
            # return nothing with both the self-test and the real run staying green.
            result = check_pair(root, pair)
        except GuardError as exc:
            failures.append(f"{pair['id']}: the guard could not evaluate its own canary — {exc}")
            continue
        got = result.kinds
        kinds_seen |= got
        if got != expected:
            verb = ("detected nothing" if not got else f"detected {sorted(got)}")
            failures.append(f"{pair['id']}: expected {sorted(expected) or 'a clean result'}, "
                            f"{verb}.")
        elif result.nodes < 1:
            failures.append(f"{pair['id']}: behaved as declared but reported inspecting 0 nodes — "
                            "the count the real run's scope floor depends on is not being raised.")
        else:
            print(f"self-test: {pair['id']} → "
                  f"{sorted(got) if got else 'clean, as declared'} ({result.nodes} nodes) ✅")

    required = {"bytes", "value", "added", "missing", "allowlist-misuse", "lua-value"}
    missing_detectors = required - kinds_seen
    if missing_detectors:
        failures.append(f"the canary set never exercised detector(s) {sorted(missing_detectors)} — "
                        "the guard, not the fixture, is unproven for that class.")

    # The scope ledger is a library no CI step runs on its own; exercising it here is what stops it
    # from being an unrun gate.
    failures += Scope.self_check()
    # …and the declared floor must still match the declared pair list. PAIRS[:1] was undetected.
    if scope_for_tree().floor_for("pairs compared") != len(PAIRS):
        failures.append(f"MIN_PAIRS ({scope_for_tree().floor_for('pairs compared')}) no longer "
                        f"equals len(PAIRS) ({len(PAIRS)}). A pair was added or removed without "
                        "re-stating the floor, so the floor has stopped asserting the real set.")

    if failures:
        for failure in failures:
            print(f"::error::copy-drift-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2

    print(f"self-test ok — every canary behaved as declared, all through check_pair() as main() "
          f"uses it ({len(canaries)} fixture pairs, {len(required)} detectors proven), and the "
          f"scope ledger fails an empty or truncated input set.")
    return 1


# ---------------------------------------------------------------------------- main


def scope_for_tree() -> Scope:
    """Floors for a full run (every declared pair). `--pair ID` is local debugging and gets the
    reduced ledger built in main() instead — a floor of 12 on a deliberate one-pair run would be a
    false alarm, and false alarms are how gates get deleted."""
    scope = Scope("copy-drift-guard")
    scope.require("pairs compared", MIN_PAIRS,
                  f"the guard declares {MIN_PAIRS} hand-maintained duplicates. Fewer means the "
                  "driver is iterating a truncated list, not that duplicates were retired.")
    scope.require("structural nodes compared", MIN_STRUCTURAL_NODES,
                  "YAML nodes actually walked by Comparison.compare(). This is the count that "
                  "collapses when check_structural_pair stops doing the comparison — the blinding "
                  "that kept BOTH the self-test and the real run green (audit 2026-08-01).")
    scope.require("byte-identical pairs compared", 1,
                  "the claims-seed pair is the one non-YAML duplicate; its mode has its own reader "
                  "and would otherwise be provable only by the canary.")
    return scope


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="scan the canary fixtures instead of the tree; a result other than 1 "
                             "means detection is unproven, not that the tree is fine")
    parser.add_argument("--pair", metavar="ID",
                        help="check only this pair id (local debugging; CI runs them all)")
    parser.add_argument("--list", action="store_true", help="print the declared pairs and exit")
    args = parser.parse_args(argv)

    root = repo_root()

    if args.list:
        for pair in PAIRS:
            allowed = [_fmt_path(p) for p in pair.get("allow_added", [])]
            print(f"{pair['id']:38s} {pair['mode']:11s} allows-added: {allowed or 'nothing'}")
        return 0

    if args.self_test:
        return self_test(root)

    pairs = PAIRS
    scope = scope_for_tree()
    if args.pair:
        pairs = [p for p in PAIRS if p["id"] == args.pair]
        if not pairs:
            print(f"copy-drift-guard: no declared pair with id {args.pair!r} — refusing to report "
                  f"clean over an empty scope. Try --list.", file=sys.stderr)
            return 2
        # Deliberate single-pair debugging: the only floor that still means anything is "the pair
        # was actually compared".
        scope = Scope("copy-drift-guard --pair")
        scope.require("pairs compared", 1, "the requested pair must actually be compared.")

    if not pairs:
        print("::error::copy-drift-guard has no pairs declared — refusing to report clean over an "
              "empty scope.", file=sys.stderr)
        return 2

    drifted = 0
    for pair in pairs:
        try:
            result = check_pair(root, pair)
        except GuardError as exc:
            print(f"::error::copy-drift-guard [{pair['id']}] cannot be checked: {exc}",
                  file=sys.stderr)
            return 2
        scope.add("pairs compared")
        if pair["mode"] == "bytes":
            scope.add("byte-identical pairs compared")
        else:
            scope.add("structural nodes compared", result.nodes)
        if result.problems:
            drifted += 1
            print(f"\nDRIFT [{pair['id']}]")
            for problem in result.problems:
                print(problem)
            print(f"  why it matters: {pair['why']}")

    # Before reporting anything: did the run actually inspect what it claims to?
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    if drifted:
        print(f"\n::error::{drifted} of {len(pairs)} hand-maintained copies drifted from their "
              "source. Fix the copy (or the source — decide which one is right), and if the copy "
              "lives in a Helm chart, bump the chart version so Argo's manifest cache picks it up.",
              file=sys.stderr)
        return 1

    print(f"copy-drift-guard: clean ({scope.summary()}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
