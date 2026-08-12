#!/usr/bin/env python3
"""cockpit-attribute-emission-guard.py — every placeholder-defaulted attribute the content
references must be emitted by BOTH cockpit ConfigMaps.

WHY THIS EXISTS. Three times, the same defect, all three measured on live cockpits rather than
found by review:

  1. 2026-07-31 — `sonarqube_url` and `acs_console_url` were referenced by app-security-testing and
     emitted by NEITHER cockpit. antora.yml's `apps.example.com` soft default won, so the Console
     tab of exercises 2 and 4 and two of six rows in exercise 7 handed every attendee a link that
     goes nowhere. showroom.yaml's own comment records it.
  2. 2026-08-12 — `rhdh_url` (12 references) and `student_argo_url` (8) missing from BOTH cockpits.
     Measured on the SERVED attendee cockpit: 6 occurrences of
     backstage-developer-hub-rhdh.apps.example.com and 3 of student-gitops-server-student-gitops
     .apps.example.com across seven lab pages.
  3. 2026-08-12 — `sonarqube_url`, `acs_console_url` and `mta_url` missing from
     showroom-demos.yaml. Three of them existed in showroom.yaml and were simply never copied
     across when that template was written.

All three are fixed (44cc8f4). What none of them had was a check. showroom-demos.yaml says it
outright: "It keeps recurring because two files must move together and nothing checks that they
did." This is that check.

WHY CI COULD NEVER HAVE CAUGHT IT, AND WHY THIS GUARD IS SOURCE-LEVEL. A local Antora build renders
the placeholder for EVERY one of these attributes by construction — there is no cluster, so the soft
default always wins. A check that greps a built site for `example.com` fires on all of them, always,
and is therefore worth nothing. The invariant only exists across three inputs that must move
together, so that is where it is checked:

    content/antora.yml                       which attributes carry a placeholder soft default
    content/modules/**/*.adoc                which of those the content actually references
    gitops/workshop-config/templates/        which of those each cockpit ConfigMap emits
        showroom.yaml, showroom-demos.yaml

THE RULE
    for every attribute with a PLACEHOLDER-SHAPED soft default in antora.yml
    that is referenced anywhere in content:
        BOTH cockpit templates must emit it.

WHAT "PLACEHOLDER-SHAPED" MEANS, AND WHERE THE SHAPE COMES FROM. Derived by reading the 16 soft
(`@`-suffixed) defaults antora.yml actually carries, not by assuming they are all URLs. They fall
into three groups, and only two of them are placeholders:

  * RESERVED-DOMAIN placeholders (10): every value carrying an RFC 2606 / RFC 6761 reserved name —
    `console.apps.example.com`, `apps.example.com`, `gitea.example.com`, `maas.example.com/v1`, …
    A reserved domain is a value that CANNOT be right anywhere. That is the whole signal: nobody
    writes one intending it to be served.
  * SENTINEL placeholders (2): `set-from-ogsr-maas-credentials`, `set-from-cluster`. A different
    spelling of the same idea, and the same defect has already been paid for on this family — the
    demos cockpit did not emit `maas_model` until 2026-08-07, so an SA read the literal sentinel off
    their own screen in front of a customer. antora.yml's own comment on that key is a paragraph
    about it. Any `set-from-…` value is in scope.
  * REAL values that happen to be soft (4): `user: user1`, `password: openshift`,
    `guid: dev-local`, `lab_name: OpenShift Application Platform — Getting Started`. These are soft
    so a deploy can override them, but each renders as something true — `user1` is a live attendee
    slot, `openshift` is the actual shared password. They are NOT placeholders and this guard does
    not demand them.

The rule falls out of the values, so it needs no hand-maintained inventory: add an attribute with an
`example.com` default tomorrow and it is in scope the moment content references it.

`password` deserves a sentence, because a reader will wonder. It is soft, and it is deliberately
NEVER emitted by either cockpit ("never bake a credential into a ConfigMap"). It is out of scope
twice over — `openshift` is not placeholder-shaped, and content references it zero times — so this
guard will not demand a credential in a ConfigMap even if a page starts using {password}.

REFERENCES ARE COUNTED RAW, COMMENTS INCLUDED — deliberately, and it is the failing-closed
direction. Stripping AsciiDoc comments would be more precise (`maas_endpoint`'s three references are
all inside `//` comments today) and would require this guard to know that `// …` is a comment at top
level but literal text inside a `----` listing block. Getting that wrong drops a real reference and
lets a real dead link ship. Counting a comment-only mention as a reference can only ever demand ONE
EXTRA key in a ConfigMap, which is harmless, loud, and has an exemption ledger as its escape hatch.

PARSING THE COCKPITS — they are Helm, so they are not YAML and cannot be parsed as YAML. What is
read is the NAMED TEMPLATE each userdata ConfigMap `include`s (`workshop-config.showroomUserData` /
`…ShowroomDemosUserData`), located by its `define` action and terminated by DEPTH-MATCHED `end` —
the block contains four nested `if`/`range` actions in showroom.yaml, so stopping at the first
`{{- end }}` would silently truncate it to the first three keys. Inside the block, Helm template
comments (`{{- /* … */ -}}`) and `#` YAML comments are removed BEFORE keys are matched: both real
templates carry key-shaped lines inside both kinds of comment (`parameter:` inside a Helm comment,
`# why:` and `#   error:` inside YAML ones), and a comment naming an attribute in key position would
otherwise read as an emission that is not there.

A key emitted CONDITIONALLY counts as emitted. `maas_model`, `maas_endpoint` and
`cluster_ocp_version` all sit behind `{{- if .root.Values.showroom.… }}`, on purpose and with the
reasoning written above each: emitting a BLANK merges over the soft default and the sentence loses
its subject, whereas omitting the key lets the visible placeholder through — wrong, but legibly
wrong. That omission is graded elsewhere (`ws doctor`'s "cockpit attributes" row) against a live
cluster, which is the only place it can be graded. This guard asks the question a static file can
answer: does the template know about the key at all.

WHAT COULD FOOL THIS PARSER, stated so nobody reads its green tick as more than it is:
  * A key emitted from a NESTED named template (`{{ include "…" }}` inside the define block). The
    guard cannot see through that, so it does not try to: an `include`/`template` action inside the
    block is an EXIT 2, never a pass.
  * A key whose NAME is built by interpolation (`{{ $k }}: value`). Not matched, and not matchable.
    The one instance in the tree — `module-{{ $slug }}-hidden` — is not an antora.yml attribute, so
    it is correctly invisible.
  * A key present in the template but which Helm would never reach (dead `{{- if false }}`). Read as
    emitted. Judging reachability means rendering, and rendering means deciding a values set, which
    would turn every conditional key into a false positive.

DELIBERATELY OUT OF SCOPE:
  * whether the emitted VALUE is correct (a right key pointing at the wrong host). That is a live
    fact about a cluster and belongs to `ws doctor`, not to a file comparison.
  * the two Antora playbooks (showroom/site.yml, showroom/site-demo.yml). They are the PLAYBOOK
    layer, which loses to the component descriptor the ConfigMap merges into, so a key there could
    not fix a missing cockpit key anyway.
  * hardcoded URLs in content. attribute-interpolation-guard and the content build own that.

FIX WHEN THIS FIRES
    Add the missing `<attr>: https://…{{ .domain }}` line to the named template at the top of
    gitops/workshop-config/templates/showroom.yaml AND/OR showroom-demos.yaml — the guard names
    which cockpit is missing which key. Ground the hostname on a real route
    (`oc get route -A | grep <thing>`), do not guess it, and put it in BOTH templates even if only
    one rendering references it today. If an attribute genuinely must NOT be emitted, add it to
    EXEMPTIONS below with the reason; silence is not an option the guard accepts.

USAGE
    tools/lint/cockpit-attribute-emission-guard.py                    # check the tree
    tools/lint/cockpit-attribute-emission-guard.py --matrix           # the full per-cockpit table
    tools/lint/cockpit-attribute-emission-guard.py --self-test        # fixtures; MUST exit 1
    # …and every input is overridable, so the gate can be pointed at a KNOWN-BAD copy:
    tools/lint/cockpit-attribute-emission-guard.py \
        --cockpit 'showroom.yaml=/tmp/showroom-without-rhdh.yaml'
    #   (also --antora PATH and --content DIR). A gate nobody can run against a reconstructed
    #   defect is a gate nobody has watched work; all three historical instances above were
    #   replayed through this flag before it was wired into CI.

EXIT CODES (the house contract — same as image-pull-policy-guard.py, so the workflow steps read
alike):
    0  every referenced placeholder-defaulted attribute is emitted by both cockpits
    1  at least one is not — or a stale EXEMPTIONS entry — or, under --self-test, every canary was
       correctly detected
    2  the guard could not do its job (PyYAML missing, an input file absent or unparseable, a
       define block that cannot be located or is not depth-matched, a nested include it cannot see
       through, a COLLAPSED scope, an unreadable EXEMPTIONS entry, or an undetected canary).
       Never confuse this with a clean result.

LOCAL YAMLLINT: the canary's cockpit fixtures are Helm, not YAML, and are named `*.yaml.tmpl` for
exactly that reason — no yamllint exclusion is needed for them. The canary's `antora.yml` IS plain
YAML and lints clean.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tempfile


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    Same remap every guard in this directory carries, for the same measured reason: module-level
    code runs before `__main__` exists, so a bad constant or a failed import crashes with Python's
    default rc 1 — which is exactly what CI's "--self-test must exit EXACTLY 1" reads as "the canary
    fired". `os._exit` is what makes the code stick; an excepthook cannot change the exit status by
    returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::cockpit-attribute-emission-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). Exiting 2 — a crash is 'the guard could not run', never "
          f"'clean' and never 'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad, see image-pull-policy-guard's note
    # NOT `except ImportError`: a _scope.py that fails to PARSE raises SyntaxError, sails past an
    # ImportError-only handler and exits 1 — CI's "the canary fired". Anything at all going wrong
    # while loading the scope ledger means this guard cannot start, and that is rc 2.
    print(f"::error::cockpit-attribute-emission-guard: cannot import _scope ({exc}) — the guard "
          f"could not start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)

try:
    import yaml
except ImportError:  # pragma: no cover — exercised only on a machine without PyYAML
    print("cockpit-attribute-emission-guard: PyYAML is not installed. antora.yml is plain YAML and "
          "this guard parses it properly rather than pattern-matching it, so it cannot run without "
          "a parser — refusing to report clean. Install it "
          "(python3 -m pip install PyYAML) and re-run.", file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    A module-level `re.error` raises before main() can run and Python exits 1, which CI's
    exit-exactly-1 assertion reads as proof of detection. A regex typo must never report detection
    as proven.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::cockpit-attribute-emission-guard: {name} is not a valid regex ({exc}) — "
              f"the guard could not load. Exiting 2: that is 'the guard is broken', not 'clean'.",
              file=sys.stderr)
        sys.exit(2)


# --------------------------------------------------------------------------------- what is placeholder-shaped

# RFC 2606 (example.com/.net/.org, .test, .example, .invalid) and RFC 6761 (.localhost) reserved
# names. The signal is "this value cannot be right ANYWHERE", which is precisely what a reserved
# name guarantees and precisely what makes the soft default a trap rather than a fallback.
PLACEHOLDER_DOMAIN_RE = _compile(
    "PLACEHOLDER_DOMAIN_RE",
    r"(?:^|[./@])(?:example\.(?:com|net|org)|(?:[a-z0-9-]+\.)*(?:example|invalid|test|localhost))"
    r"(?:[:/?#]|$)",
    re.I)

# The second placeholder family: a value that names where the real one comes from.
# `set-from-ogsr-maas-credentials`, `set-from-cluster`. Same defect, different spelling — and this
# family has already cost the project an SA reading the literal sentinel to a customer (2026-08-07).
SENTINEL_RE = _compile("SENTINEL_RE", r"^set-from-[a-z0-9-]", re.I)

# --------------------------------------------------------------------------------- reading the cockpits

# A Helm template comment, `{{- /* … */ -}}`. Removed before ANYTHING else is read: both real
# templates carry key-shaped lines inside one (`parameter: quoting keeps …`), and the comment body
# is prose that can contain anything at all, including a `}}`.
HELM_COMMENT_RE = _compile("HELM_COMMENT_RE", r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", re.S)

# Any other Helm action. Used ONLY to depth-match the define block's `end`; the four nested
# if/range blocks in showroom.yaml's template are why a first-`end` scan would truncate it.
HELM_ACTION_RE = _compile("HELM_ACTION_RE", r"\{\{-?(.*?)-?\}\}", re.S)

# A YAML key at the head of a line. Hyphens allowed because `page-user` is one.
YAML_KEY_RE = _compile("YAML_KEY_RE", r"^[ \t]*([A-Za-z_][A-Za-z0-9_-]*)[ \t]*:(?:[ \t]|$)")

# A named-template call inside the define block. The guard cannot follow one, so finding one is an
# exit 2 rather than a pass over a block whose real contents are somewhere else.
NESTED_INCLUDE_RE = _compile("NESTED_INCLUDE_RE", r"\{\{-?\s*(?:include|template)\s")

# Helm actions that OPEN a block and must be matched by an `end`.
BLOCK_OPENERS = {"if", "range", "with", "define", "block"}

# --------------------------------------------------------------------------------- reading the content

# An Antora attribute reference in a page. Lowercase-with-underscores is the naming convention every
# environment attribute in antora.yml follows; the set is intersected with antora.yml's own keys
# immediately afterwards, so noise like curl's `{http_code}` never reaches a verdict.
ATTR_REF_RE = _compile("ATTR_REF_RE", r"\{([a-z][a-z0-9_]*)\}")

# --------------------------------------------------------------------------------- declared inputs

ANTORA_DESCRIPTOR = "content/antora.yml"
CONTENT_DIR = "content/modules"

# (label, path, named template the userdata ConfigMap includes). Both cockpits, always — a cockpit
# dropped from this list is a cockpit nobody checks, which is instance 3 exactly.
COCKPITS = (
    ("showroom.yaml",
     "gitops/workshop-config/templates/showroom.yaml",
     "workshop-config.showroomUserData"),
    ("showroom-demos.yaml",
     "gitops/workshop-config/templates/showroom-demos.yaml",
     "workshop-config.showroomDemosUserData"),
)

# --------------------------------------------------------------------------------- exemptions

# "This attribute is placeholder-shaped and referenced, and a cockpit deliberately does NOT emit it."
#
# DELIBERATELY EMPTY, and the mechanism is here anyway because the requirement that made this guard
# necessary is that an intentional omission be VISIBLE. Silence is what the three instances above
# looked like from the outside; an entry here looks different, on purpose.
#
# The ledger is linted the way tools/lint/LEDGERS.md requires, and rots in both directions:
#   * an entry with no reason              -> rc 2 (a suppression the gate cannot read declares
#                                            nothing while looking like it does)
#   * an entry naming an attribute that is no longer placeholder-shaped, no longer referenced, or
#     was never in antora.yml                 -> rc 1 (stale: it can never be matched or retired)
#   * an entry whose attribute BOTH cockpits now emit -> rc 1 (the entry is a lie about the tree)
#
# Format: {"<attribute>": "<why it must not be emitted>"}. Adding one is an owner decision.
EXEMPTIONS: dict[str, str] = {}


class GuardError(Exception):
    """The guard cannot do its job. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


# --------------------------------------------------------------------------------- classification


def is_placeholder(value: str) -> bool:
    """Is this soft default a value that CANNOT be right on any cluster?

    Two families, both derived from antora.yml's own contents — see the module docstring. The
    trailing `@` is Antora's soft-set marker, not part of the value, so it comes off first.
    """
    bare = value[:-1] if value.endswith("@") else value
    bare = bare.strip()
    if not bare:
        return False
    return bool(PLACEHOLDER_DOMAIN_RE.search(bare) or SENTINEL_RE.search(bare))


def placeholder_kind(value: str) -> str:
    """Which family — for the --matrix report, so a reader can see WHY an attribute is in scope."""
    bare = value[:-1] if value.endswith("@") else value
    if SENTINEL_RE.search(bare.strip()):
        return "sentinel"
    if PLACEHOLDER_DOMAIN_RE.search(bare.strip()):
        return "reserved-domain"
    return "-"


# --------------------------------------------------------------------------------- antora.yml


def load_soft_defaults(path: pathlib.Path, label: str) -> tuple[dict, list]:
    """({attribute: soft value}, problems). Every problem is an exit-2 condition.

    PyYAML, not a regex: antora.yml is plain YAML with no templating in it, and the house rule is to
    parse what can be parsed. A regex here would also have to survive the file's very long block
    comments, several of which contain `key: value` prose.
    """
    problems: list[str] = []
    if not path.is_file():
        problems.append(
            f"{label} does not exist at {path}. This guard compares three files that must move "
            f"together; with one of them missing it is comparing nothing, and a guard that "
            f"inspects nothing must never print a green tick. Update ANTORA_DESCRIPTOR if the "
            f"descriptor moved.")
        return {}, problems
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        problems.append(f"{label} is not parseable as YAML ({exc}), so the set of soft defaults "
                        f"cannot be derived and nothing below it means anything.")
        return {}, problems

    attributes = None
    if isinstance(document, dict) and isinstance(document.get("asciidoc"), dict):
        attributes = document["asciidoc"].get("attributes")
    if not isinstance(attributes, dict) or not attributes:
        problems.append(
            f"{label} carries no asciidoc.attributes mapping. Either the descriptor's shape "
            f"changed or the file is not the one this guard thinks it is — either way the "
            f"placeholder set would come back empty, which reads identically to 'nothing is "
            f"placeholder-shaped'.")
        return {}, problems

    soft = {name: value for name, value in attributes.items()
            if isinstance(value, str) and value.endswith("@")}
    return soft, problems


# --------------------------------------------------------------------------------- the cockpits


def strip_yaml_comments(text: str) -> str:
    """Blank every whole-line `#` comment, keeping line count so messages stay locatable.

    Load-bearing on the real templates, not a defensive nicety: showroom.yaml carries
    `#   error: You must be logged in to the server (Unauthorized)` inside a prose comment and
    showroom-demos.yaml carries `# choices: click-to-run.js hardcodes …`. A comment that happened to
    name an ATTRIBUTE in key position would otherwise read as an emission that does not exist —
    which is the exact false-pass this guard cannot afford, since a false pass here is a dead link
    for every attendee.
    """
    return "\n".join("" if line.lstrip().startswith("#") else line
                     for line in text.splitlines())


def extract_define_block(text: str, define_name: str) -> tuple[str, bool]:
    """(body, found) for `{{- define "<name>" }} … {{- end }}`, with DEPTH-MATCHED end.

    Depth-matched because showroom.yaml's template body contains four nested `if`/`range` blocks
    (maas_model, maas_endpoint, cluster_ocp_version, the disabled-module range). Stopping at the
    first `{{- end }}` would return the first three keys and report the other fourteen missing — a
    guard that fires on a correct tree gets switched off, taking the detector that matters with it.

    Helm comments are removed first: the comment body is prose and can contain `}}`, `end`, or a
    key-shaped line, all of which would derail the scan.
    """
    stripped = HELM_COMMENT_RE.sub("", text)
    opener = re.search(r"\{\{-?\s*define\s+\"" + re.escape(define_name) + r"\"\s*-?\}\}", stripped)
    if opener is None:
        return "", False

    depth = 1
    for action in HELM_ACTION_RE.finditer(stripped, opener.end()):
        head = action.group(1).strip().split(None, 1)[0] if action.group(1).strip() else ""
        if head in BLOCK_OPENERS:
            depth += 1
        elif head == "end":
            depth -= 1
            if depth == 0:
                return stripped[opener.end():action.start()], True
    return "", False


def cockpit_emitted_keys(text: str, define_name: str, label: str) -> tuple[set, list]:
    """(keys the named template emits, problems). Every problem is an exit-2 condition."""
    problems: list[str] = []
    body, found = extract_define_block(text, define_name)
    if not found:
        problems.append(
            f"{label}: could not locate the named template {define_name!r} with a depth-matched "
            f"`end`. That template IS the cockpit's attribute payload — the userdata ConfigMap is "
            f"one `include` of it — so without it this guard has no idea what the cockpit emits "
            f"and must not guess. Either the template was renamed (update COCKPITS) or its "
            f"`{{{{- define }}}}`/`{{{{- end }}}}` pairing is broken.")
        return set(), problems

    if NESTED_INCLUDE_RE.search(body):
        problems.append(
            f"{label}: the {define_name!r} body calls another named template. This guard reads the "
            f"block as text and cannot follow an include, so a key emitted from the callee would "
            f"be invisible and this run would report a cockpit as complete when it may not be. "
            f"Refusing to guess. Either inline the keys or teach this guard to resolve includes.")
        return set(), problems

    keys = {match.group(1) for line in strip_yaml_comments(body).splitlines()
            for match in [YAML_KEY_RE.match(line)] if match}
    if not keys:
        problems.append(
            f"{label}: the {define_name!r} body yielded ZERO keys. The block was found, so this is "
            f"the parser failing rather than the template being empty — and an empty emitted-key "
            f"set makes every referenced attribute look missing, or (with the comparison inverted) "
            f"nothing look missing at all.")
    return keys, problems


# --------------------------------------------------------------------------------- the content


def content_references(directory: pathlib.Path, label: str) -> tuple[dict, int, list]:
    """({attribute: raw reference count}, files scanned, problems).

    RAW — comments included. See the module docstring: stripping them is the failing-OPEN direction
    and would require this guard to know that `//` is a comment at top level and literal text inside
    a listing block.
    """
    problems: list[str] = []
    if not directory.is_dir():
        problems.append(
            f"{label} is not a directory ({directory}). With no pages to read, every attribute "
            f"looks unreferenced and every cockpit looks complete — the shape of a green tick over "
            f"a check that did not happen. Update CONTENT_DIR if the tree moved.")
        return {}, 0, problems

    counts: dict = {}
    files = sorted(directory.rglob("*.adoc"))
    for page in files:
        try:
            text = page.read_text(encoding="utf-8")
        except OSError as exc:
            problems.append(f"{page} could not be read ({exc}); a page this guard cannot read is a "
                            f"page whose attribute references are unknown, not absent.")
            continue
        for match in ATTR_REF_RE.finditer(text):
            counts[match.group(1)] = counts.get(match.group(1), 0) + 1
    return counts, len(files), problems


# --------------------------------------------------------------------------------- the check


def evaluate(required: dict, emitted: dict, soft: dict, references: dict) -> tuple[list, list]:
    """(violations, blockers).

    `required`  {attribute: reference count} — placeholder-shaped AND referenced.
    `emitted`   {cockpit label: set of keys}.
    `soft`/`references` are passed so the EXEMPTIONS ledger can be judged against the same facts the
    verdict is, rather than against a second derivation that could disagree with it.
    """
    violations: list[str] = []
    blockers: list[str] = []

    for attribute, why in sorted(EXEMPTIONS.items()):
        if not why or not why.strip():
            blockers.append(
                f"EXEMPTIONS[{attribute!r}] has an empty reason. An entry suppresses a finding "
                f"exactly as effectively with no justification as with one, so the reason IS the "
                f"entry — write why this attribute must not reach a cockpit ConfigMap.")
            continue
        if attribute not in required:
            reason = ("it is not in antora.yml at all" if attribute not in soft else
                      "its soft default is no longer placeholder-shaped"
                      if not is_placeholder(soft[attribute]) else
                      "no page references it any more")
            violations.append(
                f"EXEMPTIONS[{attribute!r}] is stale: {reason}, so this entry can never be "
                f"matched, reported or retired — it suppresses in silence forever. Delete it, or "
                f"re-key it to the attribute it was meant for.")
            continue
        if all(attribute in keys for keys in emitted.values()):
            violations.append(
                f"EXEMPTIONS[{attribute!r}] says a cockpit deliberately does not emit it "
                f"({why.strip()}) — but EVERY cockpit now does. The entry is a lie about the tree; "
                f"delete it, so the attribute is protected by the rule like every other one.")

    for attribute in sorted(required):
        if attribute in EXEMPTIONS:
            continue
        missing = sorted(label for label, keys in emitted.items() if attribute not in keys)
        if missing:
            violations.append(
                f"{{{attribute}}} — referenced {references.get(attribute, 0)} time(s) in content, "
                f"soft default {soft[attribute]!r}\n"
                f"      missing from : {', '.join(missing)}\n"
                f"      effect       : antora.yml's placeholder wins wherever the cockpit is "
                f"silent, so every reader of those pages gets a link to "
                f"{soft[attribute].rstrip('@')} — a page that renders successfully while being "
                f"wrong.\n"
                f"      fix          : add `{attribute}: https://…{{{{ .domain }}}}` to the named "
                f"template at the top of each cockpit above, grounding the host on a real route "
                f"(`oc get route -A`), not on a guess.")

    return violations, blockers


# --------------------------------------------------------------------------------- gathering


def gather(root: pathlib.Path, antora_path: pathlib.Path, content_dir: pathlib.Path,
           cockpit_paths: dict, scope: Scope,
           cockpits=COCKPITS) -> tuple[dict, dict, dict, dict, list, list]:
    """Read all three inputs and raise every scope counter from the code that did the work.

    Returns (soft, required, emitted, references, problems, cockpit_order). `problems` are exit-2
    conditions from the readers; the caller decides.

    `cockpits` is a PARAMETER, defaulted to the module-level declaration, for one reason: this is
    the production glue — the function main() reaches its verdict through and every assertion in
    self_test() would otherwise walk around, calling the readers directly. image-pull-policy-guard
    paid for exactly that gap (its collect_sites() could be blinded to return nothing while both CI
    signals stayed green). Taking the spec as an argument is what lets the self-test drive THIS
    function over fixtures instead of a re-implementation of it.
    """
    problems: list[str] = []

    soft, antora_problems = load_soft_defaults(antora_path, ANTORA_DESCRIPTOR)
    problems += antora_problems
    scope.add("antora soft defaults", len(soft))

    placeholders = {name: value for name, value in soft.items() if is_placeholder(value)}
    scope.add("placeholder-shaped attributes", len(placeholders))

    references, files_scanned, content_problems = content_references(content_dir, CONTENT_DIR)
    problems += content_problems
    scope.add("content pages scanned", files_scanned)

    required = {name: references[name] for name in placeholders if references.get(name)}
    scope.add("attributes required of the cockpits", len(required))

    emitted: dict = {}
    order: list = []
    for label, _default_path, define_name in cockpits:
        path = cockpit_paths[label]
        order.append(label)
        if not path.is_file():
            problems.append(
                f"{label} does not exist at {path}. A cockpit this guard cannot read is a cockpit "
                f"whose emitted keys are UNKNOWN — and an unknown that defaults to 'complete' is "
                f"how instance 3 shipped. Update COCKPITS if the template moved.")
            emitted[label] = set()
            continue
        keys, cockpit_problems = cockpit_emitted_keys(
            path.read_text(encoding="utf-8"), define_name, label)
        problems += cockpit_problems
        emitted[label] = keys
        scope.add("cockpit templates read", 1)
        scope.add("cockpit keys extracted", len(keys))

    return soft, required, emitted, references, problems, order


def scope_for_tree() -> Scope:
    """Floors for a real-tree run. Measured 2026-08-12: 16 soft defaults, 12 placeholder-shaped,
    141 pages, 11 attributes required, 2 cockpits carrying 33 keys between them. Each floor sits
    under the measurement and far over anything a truncation produces."""
    scope = Scope("cockpit-attribute-emission-guard")
    scope.require("antora soft defaults", 10,
                  "content/antora.yml carries 16 `@`-soft defaults; a smaller number means the "
                  "descriptor parse stopped matching, not that six were deleted.")
    scope.require("placeholder-shaped attributes", 8,
                  "12 of those 16 are placeholder-shaped (10 reserved-domain, 2 sentinel). A "
                  "collapse here empties the required set, and an empty required set is a guard "
                  "that judges nothing while printing clean — the exact shape this repo has been "
                  "burned by.")
    scope.require("content pages scanned", 100,
                  "content/modules ships 141 .adoc pages. One directory's worth means the rglob "
                  "stopped descending, and an unread page's attribute references read as absent.")
    scope.require("attributes required of the cockpits", 6,
                  "11 attributes are both placeholder-shaped and referenced. This is the set the "
                  "whole gate is about; if it shrinks, the gate quietly stops covering the "
                  "attributes that are no longer in it.")
    scope.require("cockpit templates read", len(COCKPITS),
                  "BOTH cockpits, every run. Instance 3 was precisely one cockpit being left out "
                  "of a change, so a run that reads one of them proves nothing about the other.")
    scope.require("cockpit keys extracted", 20,
                  "the two named templates emit 33 keys between them. A near-zero count means the "
                  "define-block scan or the key regex broke, which would make every attribute look "
                  "missing — or, inverted, nothing.")
    return scope


# --------------------------------------------------------------------------------- self-test


def _canary_root(root: pathlib.Path) -> pathlib.Path:
    return root / "tools/lint/cockpit-attribute-emission-guard.canary"


def self_test(root: pathlib.Path) -> int:
    """Prove each detector on static fixtures. A result other than 1 means detection is unproven.

    Static fixtures, not a mutated copy of the real templates: what is under test is the DETECTOR,
    and a canary derived from live content quietly becomes an exit 2 the day that content changes
    shape. The historical reconstructions — which DO use copies of the real templates — are a
    separate exercise, run through the `--cockpit` override rather than from here.
    """
    fixture = _canary_root(root)
    if not fixture.is_dir():
        print("::error::cockpit-attribute-emission-guard: the canary fixture directory is missing "
              "— detection is unproven, so a clean result on the real tree means nothing.",
              file=sys.stderr)
        return 2

    failures: list[str] = []

    def read(name: str) -> str:
        return (fixture / name).read_text(encoding="utf-8")

    # (1) THE CLASSIFIER — the rule that decides what is in scope at all, on the real shapes taken
    #     verbatim from content/antora.yml. Both placeholder families and all four real values.
    classifier_cases = [
        ("https://console.apps.example.com@", True, "reserved-domain URL"),
        ("apps.example.com@", True, "bare reserved domain"),
        ("https://maas.example.com/v1@", True, "reserved domain with a path"),
        ("https://backstage-developer-hub-rhdh.apps.example.com@", True, "instance 2"),
        ("https://sonarqube-sonarqube.apps.example.com@", True, "instance 1"),
        ("set-from-ogsr-maas-credentials@", True, "sentinel — the SA-in-front-of-a-customer case"),
        ("set-from-cluster@", True, "sentinel"),
        ("user1@", False, "a LIVE attendee slot, not a placeholder"),
        ("openshift@", False, "the real shared password"),
        ("dev-local@", False, "a real identity string"),
        ("OpenShift Application Platform — Getting Started@", False, "a real title"),
        ("https://gitea-ogsr-gitea.apps.cluster-abc.example.opentlc.com@", False,
         "a REAL RHDP host that merely contains the word 'example' as a label — must not be "
         "mistaken for example.com, or a correctly-defaulted attribute becomes a false positive"),
        ("@", False, "an empty soft default classifies as nothing"),
    ]
    for value, expected, why in classifier_cases:
        if is_placeholder(value) != expected:
            failures.append(f"classifier: {value!r} ({why}) should be "
                            f"{'placeholder-shaped' if expected else 'a real value'} and is not.")
    if placeholder_kind("set-from-cluster@") != "sentinel" or \
            placeholder_kind("apps.example.com@") != "reserved-domain" or \
            placeholder_kind("user1@") != "-":
        failures.append("placeholder_kind() no longer reports the family a value belongs to, so "
                        "--matrix would stop telling a reader WHY an attribute is in scope.")

    # (2) THE DESCRIPTOR READER, including every way it must refuse to answer.
    soft, soft_problems = load_soft_defaults(fixture / "antora.yml", "canary antora.yml")
    if soft_problems:
        failures.append(f"the canary antora.yml did not parse: {soft_problems}")
    expected_soft = {"ocp_console_url", "cluster_domain", "rhdh_url", "student_argo_url",
                     "sonarqube_url", "acs_console_url", "mta_url", "maas_endpoint", "maas_model",
                     "cluster_ocp_version", "user", "password", "real_host_url"}
    if set(soft) != expected_soft:
        failures.append(f"soft-default extraction found {sorted(soft)}, expected "
                        f"{sorted(expected_soft)} — a HARD (no `@`) attribute leaked in, or a soft "
                        f"one was dropped. Only soft defaults can be overridden by a cockpit, so "
                        f"the distinction is the gate's premise.")
    if load_soft_defaults(fixture / "no-such-file.yml", "absent")[1] == []:
        failures.append("a MISSING antora.yml produced no problem — the guard would compare "
                        "against an empty attribute set and call it clean.")
    if load_soft_defaults(fixture / "antora-unparseable.yml.fixture", "bad yaml")[1] == []:
        failures.append("an UNPARSEABLE antora.yml produced no problem — a parse failure would "
                        "read as 'no soft defaults', which reads as 'nothing to check'.")
    if load_soft_defaults(fixture / "antora-no-attributes.yml.fixture", "no attrs")[1] == []:
        failures.append("an antora.yml with no asciidoc.attributes mapping produced no problem — "
                        "the empty placeholder set that follows is indistinguishable from a clean "
                        "tree.")

    # (3) THE COCKPIT PARSER. Four fixtures, one per thing that can go wrong, plus the correct one.
    complete_keys, complete_problems = cockpit_emitted_keys(
        read("cockpit-complete.yaml.tmpl"), "canary.userData", "cockpit-complete")
    if complete_problems:
        failures.append(f"the COMPLETE cockpit fixture produced problems it should not: "
                        f"{complete_problems}")
    expected_keys = {"user", "page-user", "cluster_domain", "ocp_console_url", "rhdh_url",
                     "student_argo_url", "sonarqube_url", "acs_console_url", "mta_url",
                     "maas_model", "maas_endpoint", "cluster_ocp_version", "real_host_url", "guid"}
    if complete_keys != expected_keys:
        failures.append(
            f"the cockpit parser extracted {sorted(complete_keys)}, expected "
            f"{sorted(expected_keys)}. The fixture plants, deliberately: keys AFTER four nested "
            f"if/range blocks (a first-`end` scan returns only the first few), a key-shaped line "
            f"inside a Helm `{{{{- /* */ -}}}}` comment, a key-shaped line inside a `#` comment, "
            f"and an interpolated key name — all four are in the real templates.")

    missing_keys, missing_problems = cockpit_emitted_keys(
        read("cockpit-missing-keys.yaml.tmpl"), "canary.userData", "cockpit-missing")
    if missing_problems:
        failures.append(f"the MISSING-KEYS cockpit fixture produced parser problems: "
                        f"{missing_problems}")
    if {"rhdh_url", "student_argo_url"} & missing_keys:
        failures.append("the missing-keys fixture omits rhdh_url and student_argo_url (instance 2) "
                        "and the parser claims to have found them — a comment naming an attribute "
                        "is being read as an emission.")

    if cockpit_emitted_keys(read("cockpit-no-define.yaml.tmpl"),
                            "canary.userData", "no-define")[1] == []:
        failures.append("a cockpit whose named template cannot be located produced NO problem. "
                        "That returns an empty key set, which makes every attribute look missing "
                        "— or, with one comparison flipped, nothing at all.")
    if cockpit_emitted_keys(read("cockpit-unterminated.yaml.tmpl"),
                            "canary.userData", "unterminated")[1] == []:
        failures.append("a define block with no depth-matched `end` produced NO problem — the "
                        "depth matcher would be free to run off the end of the file silently.")
    nested_keys, nested_problems = cockpit_emitted_keys(
        read("cockpit-nested-include.yaml.tmpl"), "canary.userData", "nested-include")
    if not nested_problems or nested_keys:
        failures.append("a define block that calls ANOTHER named template produced no problem. "
                        "The guard cannot follow an include, so reading such a block as complete "
                        "would report a cockpit as fine on the strength of keys it never saw.")
    empty_keys, empty_problems = cockpit_emitted_keys(
        read("cockpit-empty-block.yaml.tmpl"), "canary.userData", "empty-block")
    if not empty_problems or empty_keys:
        failures.append("a define block that is FOUND, correctly terminated and yields zero keys "
                        "produced no problem. That is the parser failing, and an empty key set "
                        "returned as a verdict makes every attribute look missing — or, with one "
                        "comparison flipped, nothing at all.")

    # (4) THE CONTENT SCANNER.
    references, files_scanned, content_problems = content_references(
        fixture / "content", "canary content")
    if content_problems:
        failures.append(f"the canary content tree produced problems: {content_problems}")
    if files_scanned < 2:
        failures.append(f"the content scanner walked {files_scanned} page(s); the fixture ships "
                        f"more than one, so the rglob is not descending.")
    for attribute in ("rhdh_url", "student_argo_url", "sonarqube_url", "mta_url"):
        if not references.get(attribute):
            failures.append(f"the content scanner did not see {{{attribute}}} in the canary pages.")
    if not references.get("maas_endpoint"):
        failures.append("the content scanner dropped a COMMENT-ONLY reference ({maas_endpoint} in "
                        "the fixture appears only inside a `//` comment). References are counted "
                        "raw on purpose — that is the failing-closed direction, and changing it "
                        "silently narrows what the cockpits are required to emit.")
    if references.get("never_mentioned_url"):
        failures.append("the content scanner invented a reference to an attribute no page names.")
    if content_references(fixture / "no-such-dir", "absent")[2] == []:
        failures.append("a MISSING content directory produced no problem — with no pages, every "
                        "attribute is unreferenced and every cockpit is complete.")
    # A page the scanner cannot READ. Built in a temp dir rather than committed, for two reasons: a
    # chmod-000 fixture is not root-safe (CI images differ) and a committed unreadable file is a
    # trap for every other tool in the repo. A DIRECTORY named `*.adoc` is the portable version —
    # rglob matches it, read_text raises IsADirectoryError, and the answer is the same either way:
    # an unreadable page's attribute references are UNKNOWN, never absent.
    with tempfile.TemporaryDirectory() as tmp:
        unreadable = pathlib.Path(tmp) / "pages"
        (unreadable / "trap.adoc").mkdir(parents=True)
        (unreadable / "real.adoc").write_text("{rhdh_url}\n", encoding="utf-8")
        probe_refs, probe_files, probe_problems = content_references(unreadable, "unreadable page")
        if not probe_problems:
            failures.append("a page the scanner could not READ produced no problem. It would be "
                            "skipped silently, and an unread page's references read as absent — "
                            "which is a cockpit reported complete on the strength of a page "
                            "nobody looked at.")
        if not probe_refs.get("rhdh_url"):
            failures.append("the scanner stopped reading the rest of the directory after the "
                            "unreadable page — one bad file must not blind the whole walk.")
        if probe_files != 2:
            failures.append(f"the scanner counted {probe_files} page(s) where the fixture plants 2; "
                            f"the page count feeds a scope floor, so it must count what rglob "
                            f"selected, not what it managed to read.")

    # (5) THE VERDICT — the function main() actually reaches a decision through.
    placeholders = {n: v for n, v in soft.items() if is_placeholder(v)}
    required = {n: references[n] for n in placeholders if references.get(n)}
    if "user" in required or "password" in required:
        failures.append("a real-valued soft default (user/password) reached the required set. "
                        "`user1` is a live attendee slot and `openshift` is the real shared "
                        "password; demanding either would be wrong, and demanding `password` in a "
                        "ConfigMap would be a credential leak this guard was asking for.")
    if "real_host_url" in required:
        failures.append("a REAL RHDP host containing the word 'example' as a label reached the "
                        "required set — the reserved-domain rule is over-matching, and a guard "
                        "that fires on correct defaults gets switched off.")

    both_good = {"cockpit-complete": complete_keys, "cockpit-second": set(complete_keys)}
    violations, blockers = evaluate(required, both_good, soft, references)
    if violations or blockers:
        failures.append(f"the CLEAN case (both cockpits emitting everything) reported "
                        f"{violations + blockers}. A guard that fires on a correct tree is a guard "
                        f"someone switches off.")

    one_bad = {"cockpit-complete": complete_keys, "cockpit-second": missing_keys}
    violations, blockers = evaluate(required, one_bad, soft, references)
    if blockers:
        failures.append(f"the one-cockpit-short case produced blockers rather than findings: "
                        f"{blockers}")
    flagged = {line.split("}")[0].lstrip("{") for line in violations}
    if flagged != {"rhdh_url", "student_argo_url"}:
        failures.append(f"the one-cockpit-short case flagged {sorted(flagged)}, expected "
                        f"['rhdh_url', 'student_argo_url'] — instance 2, reconstructed. Anything "
                        f"else means the per-cockpit comparison is not per-cockpit.")
    if violations and "cockpit-second" not in violations[0]:
        failures.append("the finding does not NAME the cockpit that is missing the key. 'some "
                        "cockpit is short' sends the reader to diff two 700-line templates by "
                        "hand, which is what the last three instances already cost.")

    # (6) THE EXEMPTIONS LEDGER — every rot direction, each against its own control.
    ledger_cases = [
        ("an entry with an empty reason", {"rhdh_url": "   "}, 0, 1,
         "a suppression the gate cannot read declares nothing while looking like it does"),
        ("an entry naming an unknown attribute", {"no_such_url": "fixture: stale"}, 1, 0,
         "it can never be matched, reported or retired"),
        ("an entry naming a REAL-valued attribute", {"user": "fixture: not placeholder"}, 1, 0,
         "it names something the rule never covered"),
        ("an entry every cockpit now honours", {"rhdh_url": "fixture: now a lie"}, 1, 0,
         "the tree disagrees with the ledger"),
    ]
    for label, entries, want_violations, want_blockers, why in ledger_cases:
        saved = dict(EXEMPTIONS)
        EXEMPTIONS.clear()
        EXEMPTIONS.update(entries)
        try:
            got_v, got_b = evaluate(required, both_good, soft, references)
        finally:
            EXEMPTIONS.clear()
            EXEMPTIONS.update(saved)
        if len(got_v) != want_violations or len(got_b) != want_blockers:
            failures.append(f"ledger case {label!r}: got {len(got_v)} violation(s) and "
                            f"{len(got_b)} blocker(s), expected {want_violations}/{want_blockers}. "
                            f"An entry that can rot silently is the mute button it replaced ({why}).")

    # A LIVE exemption must actually suppress, or the ledger is decorative.
    saved = dict(EXEMPTIONS)
    EXEMPTIONS.clear()
    EXEMPTIONS.update({"rhdh_url": "fixture: deliberately not emitted by the second cockpit"})
    try:
        suppressed, _ = evaluate(required, one_bad, soft, references)
    finally:
        EXEMPTIONS.clear()
        EXEMPTIONS.update(saved)
    still = {line.split("}")[0].lstrip("{") for line in suppressed}
    if "rhdh_url" in still or "student_argo_url" not in still:
        failures.append("a live EXEMPTIONS entry did not suppress exactly its own attribute — it "
                        "either did nothing or silenced its neighbours too.")

    # (7) gather() ITSELF — the production glue main() reaches its verdict through, and the thing
    #     every assertion above walks around by calling the readers directly. image-pull-policy
    #     measured the consequence of leaving this untested: its equivalent could be blinded to
    #     return nothing while still raising its counters, and BOTH CI signals stayed green. A
    #     filter or a slice appended at the end of that function is the realistic shape.
    #
    #     Driven over the fixtures via the `cockpits` parameter, with a floor-less Scope: what is
    #     being proven is the WIRING (does gather assemble the required set, keep the cockpits
    #     apart, and surface a reader's problem), not the real tree's numbers, which the floors on
    #     the real run pin separately.
    fixture_cockpits = (
        ("complete", "unused", "canary.userData"),
        ("short", "unused", "canary.userData"),
    )
    fixture_paths = {"complete": fixture / "cockpit-complete.yaml.tmpl",
                     "short": fixture / "cockpit-missing-keys.yaml.tmpl"}
    probe_scope = Scope("cockpit-attribute-emission-guard (canary)")
    g_soft, g_required, g_emitted, g_refs, g_problems, g_order = gather(
        root, fixture / "antora.yml", fixture / "content", fixture_paths, probe_scope,
        cockpits=fixture_cockpits)
    if g_problems:
        failures.append(f"gather() reported problems over a readable fixture set: {g_problems}")
    if g_order != ["complete", "short"]:
        failures.append(f"gather() returned cockpit order {g_order}, expected ['complete', "
                        f"'short']. That list drives the --matrix columns and the count in the "
                        f"clean line; an empty one reports a run over no cockpits as a run.")
    if set(g_required) != set(required):
        failures.append(f"gather() derived the required set {sorted(g_required)}, but the same "
                        f"inputs read directly give {sorted(required)}. The glue and the readers "
                        f"disagree, so one of them is not being tested by anything.")
    if g_emitted.get("complete") != complete_keys or g_emitted.get("short") != missing_keys:
        failures.append("gather() did not keep the two cockpits' key sets apart — the per-cockpit "
                        "verdict is the whole point, and instance 3 was one cockpit differing "
                        "from the other.")
    if g_refs != references or g_soft != soft:
        failures.append("gather() returned different references or soft defaults than the readers "
                        "it calls; a counter can then be satisfied by work whose result was "
                        "thrown away.")
    for dimension, expected in (("cockpit templates read", 2),
                                ("attributes required of the cockpits", len(required))):
        if probe_scope.get(dimension) != expected:
            failures.append(f"gather() raised {probe_scope.get(dimension)} for {dimension!r}, "
                            f"expected {expected}. The scope floors are raised from these "
                            f"counters, so one that does not track the work passes every floor "
                            f"while proving nothing.")
    # …and a cockpit path that is not there must surface as a problem from gather, not as an empty
    # key set that reads as "this cockpit emits nothing" and flags every attribute.
    absent_paths = dict(fixture_paths)
    absent_paths["short"] = fixture / "no-such-cockpit.yaml.tmpl"
    if not gather(root, fixture / "antora.yml", fixture / "content", absent_paths,
                  Scope("canary"), cockpits=fixture_cockpits)[4]:
        failures.append("gather() reported no problem for a cockpit file that does not exist — an "
                        "unknown that defaults to a verdict is how instance 3 shipped.")

    # (7b) The `--cockpit LABEL=PATH` override, which is what makes this gate testable against a
    #      known-bad copy at all. A malformed one must stop the run: silently ignoring it would
    #      mean a reconstruction ran against the REAL template and came back clean, which reads as
    #      "the guard does not catch this" when it never looked.
    good_paths, good_problems = _parse_cockpit_overrides(
        root, [f"showroom.yaml={fixture / 'cockpit-complete.yaml.tmpl'}"])
    if good_problems or good_paths["showroom.yaml"] != fixture / "cockpit-complete.yaml.tmpl":
        failures.append(f"a well-formed --cockpit override was rejected or ignored: "
                        f"{good_problems}, {good_paths['showroom.yaml']}")
    if good_paths["showroom-demos.yaml"] != root / COCKPITS[1][1]:
        failures.append("overriding one cockpit changed the other's path; each override must be "
                        "independent or a reconstruction silently tests the wrong pair.")
    for bad in ("no-equals-sign", "not-a-cockpit=/tmp/x.yaml", "=/tmp/x.yaml"):
        if not _parse_cockpit_overrides(root, [bad])[1]:
            failures.append(f"--cockpit {bad!r} was accepted. A malformed override that is "
                            f"silently dropped runs the guard against the REAL template and "
                            f"reports clean, which reads as 'it does not catch this'.")

    # (8) The scope ledger, exercised (no CI step runs _scope.py on its own), then: every counter
    #     gather() raises must have a floor. A dimension measured but not judged proves nothing.
    failures += Scope.self_check()
    tree_scope = scope_for_tree()
    measured = ("antora soft defaults", "placeholder-shaped attributes", "content pages scanned",
                "attributes required of the cockpits", "cockpit templates read",
                "cockpit keys extracted")
    unfloored = [d for d in measured if tree_scope.floor_for(d) is None]
    if unfloored:
        failures.append(f"scope_for_tree() declares no floor for {unfloored}.")

    if failures:
        for failure in failures:
            print(f"::error::cockpit-attribute-emission-guard SELF-TEST FAILED — {failure}",
                  file=sys.stderr)
        return 2

    print("self-test ok — both placeholder families classified (and a real RHDP host containing "
          "'example' correctly NOT); the descriptor reader refuses a missing, unparseable or "
          "shapeless antora.yml; the cockpit parser survives nested if/range blocks and both "
          "comment styles and refuses a missing define, an unterminated one, a nested include and "
          "a block that yields zero keys; comment-only content references are still counted and an "
          "unreadable page is reported rather than skipped; instance 2 is reconstructed and "
          "flagged per cockpit BY NAME; all four EXEMPTIONS rot directions fire and a live entry "
          "suppresses exactly itself; gather() — the glue main() decides through — assembles the "
          "same answer as its readers and raises counters that track the work; a malformed "
          "--cockpit override stops the run; and the scope ledger fails an empty or truncated "
          "input set.")
    return 1


# --------------------------------------------------------------------------------- main


def _parse_cockpit_overrides(root: pathlib.Path, raw: list) -> tuple[dict, list]:
    """{label: path}, defaults filled in. `--cockpit LABEL=PATH` points the gate at a copy.

    This exists because a gate nobody can run against a known-bad input is a gate nobody has
    watched work. All three historical instances were replayed through it — on COPIES, never on the
    real templates.
    """
    paths = {label: root / default for label, default, _ in COCKPITS}
    problems: list[str] = []
    known = {label for label, _, _ in COCKPITS}
    for item in raw:
        label, sep, value = item.partition("=")
        if not sep or label not in known:
            problems.append(f"--cockpit {item!r} is not `LABEL=PATH` with LABEL in {sorted(known)}.")
            continue
        paths[label] = pathlib.Path(value).expanduser()
    return paths, problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="scan the canary fixtures instead of the tree; a result other than 1 "
                             "means detection is unproven, not that the tree is fine")
    parser.add_argument("--matrix", action="store_true",
                        help="print the per-attribute per-cockpit table, then the verdict")
    parser.add_argument("--antora", metavar="PATH", help=f"override {ANTORA_DESCRIPTOR}")
    parser.add_argument("--content", metavar="DIR", help=f"override {CONTENT_DIR}")
    parser.add_argument("--cockpit", action="append", default=[], metavar="LABEL=PATH",
                        help="point one cockpit at a copy (repeatable) — for replaying a known-bad "
                             "template without touching the real one")
    args = parser.parse_args(argv)

    root = repo_root()

    if args.self_test:
        try:
            return self_test(root)
        except GuardError as exc:
            print(f"::error::cockpit-attribute-emission-guard self-test could not run: {exc}",
                  file=sys.stderr)
            return 2

    cockpit_paths, override_problems = _parse_cockpit_overrides(root, args.cockpit)
    if override_problems:
        for line in override_problems:
            print(f"::error::cockpit-attribute-emission-guard: {line}", file=sys.stderr)
        return 2

    antora_path = pathlib.Path(args.antora).expanduser() if args.antora \
        else root / ANTORA_DESCRIPTOR
    content_dir = pathlib.Path(args.content).expanduser() if args.content \
        else root / CONTENT_DIR

    scope = scope_for_tree()
    soft, required, emitted, references, problems, order = gather(
        root, antora_path, content_dir, cockpit_paths, scope)

    if problems:
        print("\n::error::cockpit-attribute-emission-guard could not read what it compares:",
              file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 2

    if args.matrix:
        width = max((len(n) for n in soft), default=10)
        print(f"{'attribute':{width}s} {'family':16s} {'refs':>5s}  " +
              "  ".join(f"{label:20s}" for label in order))
        for name in sorted(soft):
            kind = placeholder_kind(soft[name])
            marker = "REQUIRED" if name in required else ("exempt" if name in EXEMPTIONS else "")
            cells = "  ".join(f"{('emitted' if name in emitted[label] else '— MISSING'):20s}"
                              for label in order)
            print(f"{name:{width}s} {kind:16s} {references.get(name, 0):5d}  {cells}  {marker}")
        print()

    # Before reporting anything: did the run actually inspect what it claims to?
    collapsed = scope.enforce()
    if collapsed:
        return collapsed

    violations, blockers = evaluate(required, emitted, soft, references)

    if blockers:
        print("\n::error::cockpit-attribute-emission-guard cannot judge the exemption ledger:",
              file=sys.stderr)
        for blocker in blockers:
            print(f"  {blocker}", file=sys.stderr)
        return 2

    if violations:
        print("\nAttributes whose placeholder default would reach a reader:")
        for violation in violations:
            print(f"  {violation}")
        print(f"\n::error::{len(violations)} finding(s). A soft default is a fallback that renders "
              f"SUCCESSFULLY while being wrong — no build fails, no check goes red, and the "
              f"attendee gets a dead link. This exact defect has shipped three times; see the "
              f"guard's header.", file=sys.stderr)
        return 1

    print(f"cockpit-attribute-emission-guard: clean — {scope.summary()}; "
          f"{len(required)} attribute(s) required of "
          f"{len(order)} cockpit(s), {len(EXEMPTIONS)} declared-exempt.")
    return 0


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either, so it is remapped to 2.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::cockpit-attribute-emission-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
              f"'canary detected'.", file=sys.stderr)
        sys.exit(2)
