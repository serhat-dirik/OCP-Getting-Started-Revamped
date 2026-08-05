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
  mode "text"        — the two sides are the SAME PROSE embedded in two different host languages
                       (today: an LLM grounding prompt that lives once as a Java text block and
                       once as a Helm `define`). Neither side is YAML and neither is a whole file,
                       so each is EXTRACTED by the host language's own rules and the two extracted
                       texts are compared. See EXTRACTING TEXT FROM A HOST LANGUAGE below.

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

EXTRACTING TEXT FROM A HOST LANGUAGE (mode "text")

  java_text_block   The name of a `static final String NAME = <text block>;` constant (a Java text
                    block: triple-quote, newline, content, triple-quote on its own line). What is
                    extracted is the RUNTIME VALUE, by JLS §3.10.6: the common leading indentation
                    ("incidental white space", measured over the non-blank content lines AND the
                    line carrying the closing delimiter) is removed, trailing white space is
                    removed from every line, and — because the closing delimiter is on its own
                    line — the value ends in a line terminator. This is not a normalization we
                    invented; it is what `javac` puts in the constant pool. Any backslash in the
                    block is an exit 2: escape sequences would have to be interpreted, and a
                    comparator that guesses at an escape is one that can call two different
                    strings equal.

  helm_define       The name of a `{{- define "NAME" -}} … {{- end -}}` body. What is extracted is
                    the RENDERED VALUE, by Go's own chomping rule: `-}}` on the opener trims all
                    white space (space, tab, CR, LF) that immediately follows it, and `{{-` on the
                    terminator trims all white space that immediately precedes it. So the body
                    normally arrives with no leading and NO TRAILING newline. A body containing
                    any `{{` action is an exit 2: it is not literal text, it cannot be compared
                    against a string constant, and refusing also removes every question about
                    which `end` closes which action.

  WHAT NORMALIZATION IS APPLIED ON TOP, AND WHY EACH IS SEMANTICALLY EMPTY. Exactly two rules,
  both applied to both sides:

    N1  trailing spaces/tabs are stripped from every line. Java already did this (JLS, above). On
        the Helm side the value reaches the cluster through a `regexReplaceAll` over
        `include … | indent 4` in the ConfigMap that carries it, whose regex is exactly
        "trailing spaces and tabs" — the `indent` pads BLANK lines too and that template strips the
        padding straight back off — so per-line trailing white space provably cannot survive to
        the shipped prompt.
    N2  at most ONE final newline is removed. The Java value ends in one (closing delimiter on its
        own line); the Helm body ends in none (`{{- end -}}` chomped it) and the ConfigMap's `|`
        block scalar puts exactly one back. So this single terminator is a host-language artifact
        on both sides. At MOST one: a copy that grew a second trailing blank line still fails,
        because that one WOULD reach the ConfigMap.

  NEITHER RULE CAN HIDE A WORDING CHANGE, and that is the property to check when touching them.
  N1 only deletes white space at end-of-line; N2 only deletes one end-of-text newline. Neither
  touches a non-whitespace character, LEADING indentation, or a blank line in the middle — so
  relative indentation (the two-space continuations inside the prompt, which the model does see)
  is compared verbatim. There is deliberately NO dedent here: on the Java side the language
  already removed the incidental indent during extraction, and on the Helm side a uniform re-indent
  of the define body WOULD change the shipped ConfigMap value, so it must fail rather than be
  normalized away. `_assert_prompt_normalizer_cannot_hide_wording()` in the self-test pins all of
  this: it asserts one changed word, one changed leading indent, and one extra trailing newline
  each survive normalization, and that trailing spaces and the single terminator do not.

  WHY NOT COMPARE THE RENDERED ConfigMap INSTEAD. It would need `helm template --set solve=true`,
  which this guard's chart renderer has no mechanism for (see the entry-namespaces-helpers pair),
  and it would gate the YAML wrapper as well as the prompt. Comparing the define body is the
  narrower claim and the one the pair is about. Checked by hand 2026-08-06 that the wrapper is
  faithful: `helm template gitops/entry-states/agentic-ai --show-only templates/agent-grounding.yaml
  --set solve=true …` yields a ConfigMap whose `grounding-prompt` value is byte-identical to
  GroundingPrompt.DEFAULT_PROMPT, trailing newline included.

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
    print(f"::error::copy-drift-guard: crashed before it could report "
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
    print(f"::error::copy-drift-guard: cannot import _scope ({exc}) — "
          f"the guard could not start, which is NOT the same as a clean tree.",
          file=sys.stderr)
    sys.exit(2)

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
    {
        "id": "entry-namespaces-helpers",
        "mode": "bytes",
        # Every gitops/entry-states/*/templates/_ns-helpers.tpl (26 charts) is a byte-identical copy
        # of this file — Helm cannot `.Files.Get` outside its own chart root, so the per-user
        # Namespace/ResourceQuota/LimitRange/RoleBinding helpers (ownerLabels, quotaSpec) are
        # duplicated into every entry-state chart that materializes its own namespaces (an attendee
        # cannot create a Namespace/ResourceQuota themselves — probed on cluster 2026-08-02).
        # config-multienv is gated here as the representative copy: tools/gen-entry-namespaces.sh
        # --check re-derives and byte-diffs ALL 26 copies (plus the sibling ns-user-namespaces.yaml,
        # which this guard cannot reach — see that generator's header comment for why: it is a
        # rendered manifest template gated `{{- if .Values.manageNamespaces }}`, so it renders empty
        # under the chart's own default values, and this guard's chart renderer has no mechanism to
        # pass the `--set manageNamespaces=true` override that would be needed to compare it here).
        "source": {"file": "gitops/user-namespace/templates/_helpers.tpl"},
        "copy": {"file": "gitops/entry-states/config-multienv/templates/_ns-helpers.tpl"},
        "why": "a hand-edit to either copy (bypassing tools/gen-entry-namespaces.sh) would silently "
               "change the ResourceQuota/LimitRange numbers or the ownerLabels value used by every "
               "one of the 26 entry-state charts that materialize their own per-user namespaces. "
               "Fix: re-copy the file (cp source copy) — never hand-edit the copy — then run "
               "tools/gen-entry-namespaces.sh so all 26 charts pick up the fix, and bump each "
               "touched chart's version so Argo's manifest cache picks it up.",
    },
    {
        "id": "agentic-ai-grounding-prompt",
        "mode": "text",
        # agentic-ai's write-beat is the GROUNDING PROMPT: the entry state ships a weak draft, the
        # attendee strengthens it, and `ws solve` ships the strengthened one. The strengthened text
        # is byte-identical to the image's own built-in fallback ON PURPOSE — that identity is what
        # makes a hand-completed attendee world and a machine-solved `ws solve` world converge on
        # the same good prompt, so a screenshot, a demo and a lab all show the same behaviour.
        #
        # NOTHING ELSE CAN CATCH THIS. tools/verify/agentic-ai.sh grades a PROPERTY of the live
        # prompt (does it direct the model at its tools) and never the exact wording — deliberately,
        # so any correct attendee edit stays green (rule 14). That is the right predicate for an
        # attendee's text and the wrong one for this pair: a reworded solve prompt, or a reworded
        # image default, keeps every ✅ while quietly ending the convergence. Hence a copy pair.
        "source": {"file": "apps/parasol-agent/src/main/java/com/parasol/agent/GroundingPrompt.java",
                   "java_text_block": "DEFAULT_PROMPT"},
        "copy": {"file": "gitops/entry-states/agentic-ai/templates/_helpers.tpl",
                 "helm_define": "agentic-ai.groundingPromptStrong"},
        "why": "the agent image's built-in default grounding and the `ws solve` grounding must be "
               "the SAME prompt, or a solved world behaves differently from a correctly-completed "
               "one and the module's own screenshots stop matching either. Decide which text is "
               "right, copy it into the other side verbatim (Java text block ↔ define body), and "
               "bump the agentic-ai chart version so Argo's manifest cache picks the new prompt up "
               "— then re-run `ws solve` for one user and re-read GET /agent/info.",
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
MIN_PAIRS = 14

# Structural comparison nodes across all pairs, measured 2026-08-01: 995. The floor is well under
# that (Task bodies and pipelines grow and shrink) and far over what a fragment comparison yields.
MIN_STRUCTURAL_NODES = 600

# Normalized prompt lines actually compared, summed over both sides of every mode="text" pair.
# Measured 2026-08-06: 30 (15 lines each side). The floor is a truncation detector, not an
# assertion of the prompt's length — an extractor that returned only its first line, or only its
# first paragraph, would land under it, and prompts are edited far more often than they are halved.
MIN_TEXT_LINES = 20


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


# ------------------------------------------------------- extracting embedded text (mode "text")


def java_text_block(text: str, name: str, origin: str) -> str:
    """The RUNTIME VALUE of `static final String <name> = \"\"\" … \"\"\";`, per JLS §3.10.6.

    Not a normalization — this is the string `javac` puts in the constant pool. Incidental white
    space (the common leading indent, measured over the non-blank content lines and over the line
    the closing delimiter sits on) is removed, trailing white space is removed from every line, and
    the closing delimiter being on its own line means the value ends in one line terminator.

    Everything it cannot lex exactly is an exit 2 rather than a guess, for the reason
    lua_code_only() gives: a comparator that guesses is one that can call two different strings
    equal, which is the failure this whole file exists to prevent.
    """
    lines = text.splitlines()
    opener = f'{name} = """'
    openers = [i for i, line in enumerate(lines) if line.rstrip().endswith(opener)]
    if len(openers) != 1:
        raise GuardError(
            f"{origin}: found {len(openers)} declaration(s) matching `{opener}`, expected exactly "
            f"1. The constant was renamed, removed, duplicated, or reformatted so the opening "
            f"delimiter no longer ends its line — update the pair rather than comparing something "
            f"else. (Only a text block is supported: a concatenated \"…\" + \"…\" constant would "
            f"have to be evaluated, and this guard does not evaluate Java.)")
    start = openers[0]

    close = None
    for i in range(start + 1, len(lines)):
        if lines[i].lstrip().startswith('"""'):
            close = i
            break
    if close is None:
        raise GuardError(f"{origin}: the {name} text block is never closed by a line beginning "
                         f'with """.')

    content = lines[start + 1:close]
    prefix = lines[close][:lines[close].index('"""')]
    if prefix.strip():
        raise GuardError(
            f"{origin}: the {name} text block's closing delimiter shares its line with content "
            f"({lines[close].strip()!r}). That is legal Java and it changes whether the value ends "
            "in a newline — put the delimiter on its own line rather than have this guard guess.")
    for lineno, line in enumerate(content, start + 2):
        if "\\" in line:
            raise GuardError(
                f"{origin}: line {lineno} of the {name} text block contains a backslash:\n"
                f"    {line.strip()}\n"
                "Comparing it would mean interpreting Java escape sequences, and a comparator that "
                "guesses at an escape can call two different strings equal. Keep the shared prompt "
                "escape-free, or stop gating it as a text pair.")

    indents = [len(line) - len(line.lstrip()) for line in content if line.strip()]
    if not indents:
        raise GuardError(f"{origin}: the {name} text block is entirely blank lines.")
    indent = min(indents + [len(prefix)])
    return "".join(line[indent:].rstrip() + "\n" for line in content)


# The four spellings of a Go/Helm action this extractor accepts, keyed by whether each delimiter
# chomps. Written out rather than pattern-matched: an action is only three tokens, and a regex
# loose enough to accept `{{-  define   "x"  -}}` is loose enough to accept things that mean
# something else. An unrecognized spelling is an exit 2 with the canonical form in the message.
_ACTION_FORMS = (("{{- ", " -}}"), ("{{- ", " }}"), ("{{ ", " -}}"), ("{{ ", " }}"))


def _action_spellings(body: str) -> dict:
    """{rendered action text: (chomps_before, chomps_after)} for one action body ('define "x"')."""
    return {f"{lead}{body}{tail}": (lead.startswith("{{-"), tail.endswith("-}}"))
            for lead, tail in _ACTION_FORMS}


def helm_define_body(text: str, name: str, origin: str) -> str:
    """The RENDERED VALUE of `{{- define "<name>" -}} … {{- end -}}`.

    Go's own chomping rule, not an approximation of it: `-}}` trims every white-space character
    (space, tab, CR, LF) immediately following the action, `{{-` trims every one immediately
    preceding it. So the canonical spelling yields the body with no leading and no trailing
    newline, which is exactly what `include` hands the ConfigMap that ships it.

    A body containing any `{{` is an exit 2. It is then not literal text — it cannot be compared
    against a string constant at all — and refusing also settles, without a nesting analysis, which
    `end` belongs to this `define`.
    """
    lines = text.splitlines()
    define_forms = _action_spellings(f'define "{name}"')
    marker = f'define "{name}"'
    hits = [i for i, line in enumerate(lines) if marker in line]
    if len(hits) != 1:
        raise GuardError(
            f"{origin}: found {len(hits)} line(s) mentioning `{marker}`, expected exactly 1. The "
            "define was renamed, removed, duplicated, or quoted verbatim in a nearby comment — "
            "update the pair (or the comment) rather than comparing something else.")
    start = hits[0]
    opener = lines[start].strip()
    if opener not in define_forms:
        raise GuardError(
            f"{origin}: the define opener is spelled {opener!r}, which this guard does not read. "
            f"Write it as one of {sorted(define_forms)} — the dashes decide whether the value "
            "starts with a newline, so an unrecognized spelling is not a formatting nit.")
    _, opener_chomps_after = define_forms[opener]

    end_forms = _action_spellings("end")
    close = None
    for i in range(start + 1, len(lines)):
        if lines[i].strip() in end_forms:
            close = i
            break
        if "{{" in lines[i]:
            raise GuardError(
                f"{origin}: the {name} define's body contains a template action on line {i + 1}:\n"
                f"    {lines[i].strip()}\n"
                "mode \"text\" compares LITERAL text against a string constant in another "
                "language; a body that renders differently per values has no single text to "
                "compare. Gate the rendered object instead.")
    if close is None:
        raise GuardError(f"{origin}: the {name} define is never closed by an `end` action.")
    end_chomps_before, _ = end_forms[lines[close].strip()]

    # Reconstruct the template text BETWEEN the two actions exactly as Go sees it, then chomp:
    # whatever trailed the opener on its own line, every body line with its terminator, and
    # whatever leads the `end` action on its line.
    opener_tail = lines[start][lines[start].rindex("}}") + 2:]
    end_head = lines[close][:lines[close].index("{{")]
    body = opener_tail + "\n" + "".join(line + "\n" for line in lines[start + 1:close]) + end_head
    if opener_chomps_after:
        body = body.lstrip(" \t\r\n")
    if end_chomps_before:
        body = body.rstrip(" \t\r\n")
    if not body.strip():
        raise GuardError(f"{origin}: the {name} define renders to nothing but white space.")
    return body


def normalize_prompt_text(text: str) -> str:
    """The two host-language artifacts that are NOT part of the prompt. See the module docstring.

    N1 trailing spaces/tabs per line — Java strips them, and the ConfigMap template strips them
       back off the Helm side after `indent` puts them on.
    N2 at most ONE final newline — Java's closing delimiter adds one, `{{- end -}}` chomps one, and
       the ConfigMap's `|` block scalar puts exactly one back.

    Nothing here touches a non-whitespace character, leading indentation, or an interior blank
    line, so no wording or relative-indentation change can survive it. That claim is asserted, not
    just asserted-in-a-comment: see _assert_prompt_normalizer_cannot_hide_wording().
    """
    out = "\n".join(line.rstrip(" \t") for line in text.split("\n"))
    if out.endswith("\n"):
        out = out[:-1]
    return out


def load_text_side(root: pathlib.Path, spec: dict, label: str) -> tuple[str, str]:
    """Read one side of a text pair and extract the declared embedded string from it."""
    extractors = {"java_text_block": java_text_block, "helm_define": helm_define_body}
    declared = [key for key in extractors if key in spec]
    if len(declared) != 1:
        raise GuardError(f"{label}: a mode=\"text\" side must declare exactly one of "
                         f"{sorted(extractors)}; this one declares {declared or 'none'}.")
    path = root / spec["file"]
    if not path.is_file():
        raise GuardError(f"{label} {spec['file']} does not exist. It was moved or renamed; "
                         "update PAIRS rather than leaving the gate pointing at nothing.")
    key = declared[0]
    origin = f"{label} {spec['file']} ({key} {spec[key]})"
    return extractors[key](path.read_text(encoding="utf-8"), spec[key], origin), origin


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


def check_text_pair(root: pathlib.Path, pair: dict) -> PairResult:
    """Compare one prose string embedded in two different host languages. See the module docstring.

    Reported like the bytes pair — a headline naming BOTH files, then a unified diff — because the
    reader's next move is the same: decide which copy is right and re-copy it. The two halves are
    separate statements and each is pinned by name in self_test(), for the reason the bytes
    reporter records: either one alone can be removed with `problems` still non-empty, the kind
    still "text-value", and the self-test still exiting 1.
    """
    source, source_origin = load_text_side(root, pair["source"], "source")
    copy, copy_origin = load_text_side(root, pair["copy"], "copy")
    source_norm = normalize_prompt_text(source)
    copy_norm = normalize_prompt_text(copy)

    problems = []
    if source_norm != copy_norm:
        problems.append(f"  text: {copy_origin} no longer matches {source_origin}")
        import difflib
        diff = difflib.unified_diff(source_norm.splitlines(), copy_norm.splitlines(),
                                    fromfile=pair["source"]["file"], tofile=pair["copy"]["file"],
                                    lineterm="")
        for line in list(diff)[:40]:
            problems.append(f"      {line}")
    # Lines actually compared, raised HERE — past both extractors — so an extractor that silently
    # returned a fragment (or a driver that stopped calling this function) lands under the floor
    # instead of reporting a clean, identical, one-line prompt.
    lines_compared = len(source_norm.splitlines()) + len(copy_norm.splitlines())
    return PairResult(problems, {"text-value"} if problems else set(), nodes=lines_compared)


def check_pair(root: pathlib.Path, pair: dict) -> PairResult:
    """THE production entry point. main() and self_test() both go through here — see PairResult."""
    if pair["mode"] == "bytes":
        return check_bytes_pair(root, pair)
    if pair["mode"] == "text":
        return check_text_pair(root, pair)
    if pair["mode"] != "structural":
        # Not an else-if for tidiness: an unknown mode used to fall through to the structural
        # reader, which would try to parse a Java file as YAML and report whatever came back.
        # An undeclared mode is a pair nobody has written a comparator for — exit 2, never a pass.
        raise GuardError(f"unknown mode {pair['mode']!r}. Declared modes are bytes, structural and "
                         "text; a pair whose mode has no reader cannot be compared at all.")
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
        {   # The two SHAPE detectors. Added 2026-08-01: `type` and `length` were the only two of
            # the eight finding kinds no fixture reached, and both could be blinded with the
            # self-test still exiting 1 and the tree run still exiting 0. A mapping that collapsed
            # to a scalar and a list that grew an item are both invisible to the value/added/missing
            # detectors, which is exactly why they needed their own case.
            "id": "canary-shape-drift", "mode": "structural",
            "source": {"file": f"{fixture}/manifest-source.yaml"},
            "copy": {"chart": chart, "template": "templates/shape-drift.yaml"},
            "allow_added": [["metadata", "namespace"]],
            "expect": {"type", "length"},
        },
        {   # The Lua branch's own precondition: a declared lua_path whose copy side is not a
            # string. It is checked INSIDE the lua branch, before the generic type check, so the
            # pair above cannot reach it — blinding it was green on both signals (2026-08-01).
            "id": "canary-lua-not-a-string", "mode": "structural",
            "source": {"file": f"{fixture}/lua-source.yaml",
                       "subtree": ["spec", "resourceHealthChecks"]},
            "copy": {"chart": chart, "template": "templates/job-lua-nonstring.yaml",
                     "heredoc": {"path": ["spec", "template", "spec", "containers", 0, "args", 0],
                                 "opener": "<<'PATCHEOF'", "terminator": "PATCHEOF"},
                     "subtree": ["spec", "resourceHealthChecks"]},
            "lua_paths": [[0, "check"]],
            "expect": {"type"},
        },
        {   # The same prose in two host languages, differing ONLY in what the normalizer is
            # allowed to erase: the Helm side carries trailing spaces and a trailing tab, and its
            # `{{- end -}}` chomped the final newline the Java text block's closing delimiter adds.
            # If either normalization rule stops working this canary reports drift and the
            # self-test fails — which is the point of making the fixtures non-identical.
            "id": "canary-text-clean", "mode": "text",
            "source": {"file": f"{fixture}/prompt/GroundingFixture.java",
                       "java_text_block": "FIXTURE_PROMPT"},
            "copy": {"file": f"{fixture}/prompt/helpers-clean.tpl",
                     "helm_define": "canary.fixturePrompt"},
            "expect": set(),
        },
        {   # …and ONE WORD changed (drift -> wobble) in an otherwise identical copy. One word is
            # the smallest real defect this pair can suffer and the one a property-grading verify
            # script cannot see, so it is what the canary reproduces.
            "id": "canary-text-drift", "mode": "text",
            "source": {"file": f"{fixture}/prompt/GroundingFixture.java",
                       "java_text_block": "FIXTURE_PROMPT"},
            "copy": {"file": f"{fixture}/prompt/helpers-drifted.tpl",
                     "helm_define": "canary.fixturePrompt"},
            "expect": {"text-value"},
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


def _refuses(fn, *args) -> bool:
    """Did this extractor raise rather than return something it had to guess at?"""
    try:
        fn(*args)
    except GuardError:
        return True
    return False


def _assert_text_extractors_refuse_to_guess() -> None:
    """Both host-language readers must fail loudly on input whose value they cannot know exactly.

    Every case below is a shape that would otherwise be extracted as SOMETHING — a wrong string
    that compares equal or unequal for reasons nobody could see in the report. The pattern is
    lua_code_only()'s and the reasoning is the same: an extractor that guesses can call two
    different strings equal, which is the failure this file exists to prevent.
    """
    q = '"""'
    # Three properties of JLS §3.10.6, each of which a plausible textwrap.dedent() implementation
    # gets wrong: the common indent goes, RELATIVE indent stays, per-line trailing white space
    # goes, and the closing delimiter's own line participates in the minimum (so a delimiter
    # outdented past its content leaves that content indented, and Java really does ship it).
    if java_text_block(f"  static final String P = {q}\n    a  \n      b\n    {q};\n",
                       "P", "unit") != "a\n  b\n":
        raise GuardError("SELF-TEST FAILED — java_text_block does not implement JLS §3.10.6 "
                         "incidental-white-space removal: the common indent and per-line trailing "
                         "white space must go, the relative indent must stay.")
    if java_text_block(f"  static final String P = {q}\n    a\n  {q};\n",
                       "P", "unit") != "  a\n":
        raise GuardError("SELF-TEST FAILED — java_text_block ignores the indentation of the "
                         "CLOSING delimiter's line, which JLS §3.10.6 counts toward the minimum. "
                         "It is how a Java author deliberately keeps leading indentation in a "
                         "text block, and dropping it silently changes the value.")
    for label, bad in (
            ("a constant that is not there", (f"static final String Q = {q}\n x\n {q};\n", "P")),
            ("two declarations of one name", (f"String P = {q}\n a\n {q};\nString P = {q}\n b\n {q};\n", "P")),
            ("an unterminated block", (f"static final String P = {q}\n hello\n", "P")),
            ("content beside the closing delimiter",
             (f"static final String P = {q}\n hello{q};\n", "P")),
            ("a backslash escape", (f"static final String P = {q}\n a\\nb\n {q};\n", "P")),
            ("an all-blank block", (f"static final String P = {q}\n\n\n{q};\n", "P")),
    ):
        if not _refuses(java_text_block, bad[0], bad[1], "unit"):
            raise GuardError(f"SELF-TEST FAILED — java_text_block accepted {label} and returned a "
                             "value it could only have guessed at.")

    tpl = '{{- define "p" -}}\nhello\n{{- end -}}\n'
    if helm_define_body(tpl, "p", "unit") != "hello":
        raise GuardError("SELF-TEST FAILED — helm_define_body does not apply Go's `-}}` / `{{-` "
                         "white-space chomping, so the value it returns is not the rendered one.")
    # The non-chomping spelling means something DIFFERENT, and must be read as such rather than
    # normalized into the chomping one: `{{ define }}`/`{{ end }}` keeps both newlines.
    if helm_define_body('{{ define "p" }}\nhello\n{{ end }}\n', "p", "unit") != "\nhello\n":
        raise GuardError("SELF-TEST FAILED — helm_define_body treats a non-chomping define as if "
                         "it chomped; the two spellings ship different strings.")
    for label, bad in (
            ("a define that is not there", ('{{- define "q" -}}\nx\n{{- end -}}\n', "p")),
            ("two defines of one name",
             ('{{- define "p" -}}\na\n{{- end -}}\n{{- define "p" -}}\nb\n{{- end -}}\n', "p")),
            ("an unrecognized opener spelling", ('{{-define "p"-}}\nhello\n{{- end -}}\n', "p")),
            ("an unclosed define", ('{{- define "p" -}}\nhello\n', "p")),
            ("a body carrying a template action",
             ('{{- define "p" -}}\nhello {{ .Values.user }}\n{{- end -}}\n', "p")),
            ("a white-space-only body", ('{{- define "p" -}}\n   \n{{- end -}}\n', "p")),
    ):
        if not _refuses(helm_define_body, bad[0], bad[1], "unit"):
            raise GuardError(f"SELF-TEST FAILED — helm_define_body accepted {label} and returned a "
                             "value it could only have guessed at.")


def _assert_prompt_normalizer_cannot_hide_wording() -> None:
    """The normalizer may erase host-language artifacts and NOTHING else.

    This is the assertion the module docstring's claim rests on, and it is the reason to write it
    as code: "N1 and N2 cannot hide a wording change" is exactly the kind of sentence that stays in
    a comment while the function underneath it grows a dedent or an rstrip("\\n") and starts
    passing over real drift. Each pair below states one thing normalization must, or must not, do.
    """
    n = normalize_prompt_text
    base = "You are a canary prompt.\n\nRules:\n- Keep this line indented\n  two extra spaces.\n"
    erasable = (
        ("per-line trailing spaces and tabs",
         base.replace("Rules:", "Rules:  \t").replace("\n\n", "\n   \n")),
        ("the single final newline the host language adds or chomps", base[:-1]),
    )
    for label, variant in erasable:
        if n(base) != n(variant):
            raise GuardError(f"SELF-TEST FAILED — normalize_prompt_text no longer erases {label}. "
                             "The real pair would report drift on two copies that ship the same "
                             "prompt, and a gate that cries wolf gets deleted.")
    significant = (
        ("one changed word", base.replace("canary", "decoy")),
        ("one changed character", base.replace("Rules:", "Rules;")),
        ("the leading indentation of one line", base.replace("  two extra", "    two extra")),
        ("an interior blank line", base.replace("prompt.\n\nRules", "prompt.\nRules")),
        ("a SECOND trailing newline, which does reach the ConfigMap", base + "\n"),
    )
    for label, variant in significant:
        if n(base) == n(variant):
            raise GuardError(
                f"SELF-TEST FAILED — normalize_prompt_text erases {label}. A normalization that "
                "can hide a real change is worse than no gate at all: it reports two prompts as "
                "the same prompt, which is the exact defect class mode \"text\" was added for.")


def _report_shape_failures(root: pathlib.Path, canary: dict, mode: str) -> list[str]:
    """Pin BOTH halves of a headline-then-diff report, by name.

    WHY EACH HALF NEEDS ITS OWN ASSERTION (measured 2026-08-01 on the bytes reporter, and true of
    the text one for the same reason). The headline and the unified diff are two separate
    statements appending to the same list, so each MASKS the other: blinding either one alone
    leaves `problems` non-empty, the reported kind unchanged, the self-test at 1 and the real run
    at 0. Nothing but an assertion on the report's SHAPE can tell them apart.

    Both modes are checked through the same function so a third one cannot be added with only half
    the pinning — and so the two can never drift into asserting different things.
    """
    failures: list[str] = []
    try:
        report = check_pair(root, canary).problems
    except GuardError as exc:
        return [f"{canary['id']} could not be re-evaluated for its report shape: {exc}"]
    if not report:
        return [f"{canary['id']} produced no report at all, so neither half of the {mode} "
                "reporter is pinned by anything below."]
    # The HEADLINE specifically — report[0], and it must name BOTH sides. "somewhere in the
    # report" is not enough: difflib's own `--- from` / `+++ to` lines carry each filename on
    # its own, so a report that lost its headline still mentioned every path and passed.
    if not all(side in report[0]
               for side in (canary["source"]["file"], canary["copy"]["file"])):
        failures.append(f"the {mode} report does not OPEN with a line naming both the copy and "
                        f"the source it drifted from; it opens with {report[0].strip()!r}. The "
                        "reader is told a duplicate diverged without being told which file to "
                        "fix or what to re-copy it from.")
    if not any(line.lstrip().startswith(("+", "-")) for line in report[1:]):
        failures.append(f"the {mode} report carries no diff body — only the headline. The diff is "
                        "the whole reason this mode is not a bare equality test, and it can be "
                        "removed without changing any detector kind.")
    return failures


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
        _assert_text_extractors_refuse_to_guess()
        _assert_prompt_normalizer_cannot_hide_wording()
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
        elif expected and not result.problems:
            # kinds and problems come out of the same finding list TODAY, which is precisely why
            # this needs saying: main() prints result.problems and never looks at result.kinds,
            # while every assertion above reads kinds and never looks at problems. Nothing else
            # notices if the two stop agreeing, and a drifted pair whose report is empty is a
            # DRIFT banner with nothing under it.
            failures.append(f"{pair['id']}: reported the detector kinds {sorted(got)} but produced "
                            "no problem text. main() prints the text, not the kinds — a pair that "
                            "drifts would head its report with nothing to read.")
        else:
            print(f"self-test: {pair['id']} → "
                  f"{sorted(got) if got else 'clean, as declared'} ({result.nodes} nodes) ✅")

    # Every mode that reports headline-then-diff, pinned by name. See _report_shape_failures.
    for mode, canary_id in (("bytes", "canary-bytes-drift"), ("text", "canary-text-drift")):
        canary = next((p for p in canaries if p["id"] == canary_id), None)
        if canary is not None:
            failures += _report_shape_failures(root, canary, mode)

    required = {"bytes", "value", "added", "missing", "allowlist-misuse", "lua-value",
                "type", "length", "text-value"}
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
    scope.require("prompt text lines compared", MIN_TEXT_LINES,
                  "normalized lines returned by check_text_pair(), summed over both sides. This is "
                  "the count that collapses if a host-language extractor starts returning a "
                  "fragment — two one-line strings compare equal just as happily as two correct "
                  "prompts do.")
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
        # One branch PER MODE, never an `else` catch-all: with `text` folded into the structural
        # branch its ~32 lines would have counted toward the 600-node structural floor, and a
        # collapsed structural comparison could be masked by an unrelated dimension's volume.
        if pair["mode"] == "bytes":
            scope.add("byte-identical pairs compared")
        elif pair["mode"] == "text":
            scope.add("prompt text lines compared", result.nodes)
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
        print(f"::error::copy-drift-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
