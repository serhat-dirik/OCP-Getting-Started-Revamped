#!/usr/bin/env python3
"""completion-coverage-guard.py — a module that grades NOTHING at completion prints a green banner
over an untouched world.

ORIGIN (2026-08-05, the 27-module / 8-attendee verification wave). The wave's headline finding was
not the ❌s — those were expected, because it graded lab COMPLETION on worlds where nobody had done
the lab. It was the ✅. `tools/verify/trusted-supply-chain.sh` printed

    ✅ all 11 checks passed

against a namespace the attendee had never touched, because its FULL mode contains no end-state
check at all: every one of its eleven checks asserts the world `ws prep` already materialized, and
the single mode-split branch adds a check in --entry-only mode only. Run it before the lab, run it
after the lab, run it instead of the lab — same green banner, rc 0.

WHY NOTHING ELSE IN CI SEES IT. The script is valid shell, shellcheck-clean, it sources _lib.sh, it
calls verify_summary, it exits 0. verify-summary-skip-guard.sh asserts the BANNER tells the truth
about the outcomes that ran; it cannot know that the outcomes which ran were all entry-state ones.
verify-oc-read-guard.sh asserts each check can distinguish "false" from "could not ask". Both are
satisfied by a script that grades the wrong world perfectly. The defect is an ABSENCE, and only a
check for the absence finds it.

WHY IT MATTERS MORE THAN A FALSE ❌. This project's standing rule is that a false ❌ destroys trust
in every other ✅ (tools/verify/README.md). A false ✅ is worse in kind: a false ❌ is contradicted
within twenty minutes by an attendee who looks at their own cluster, while a false ✅ is never
contradicted by anything. The attendee closes the module believing they did it. They find out in the
next module that depends on the skill, or in production, or never.

WHAT IT CHECKS:
  [1] COMPLETION-BLIND SCRIPT. For every module in /modules.yaml, its tools/verify/<slug>.sh must
      contain at least one GRADED outcome that (a) does NOT run under --entry-only, and (b) DOES
      run in plain full mode — the mode an attendee's own `ws verify <module>` uses. Requirement (b) is
      not pedantry: a completion check reachable only under --solve grades the machine-solved world
      and leaves the hand-completed one ungraded, which is the same green-over-nothing banner for
      everyone who actually did the lab by hand.

      Only GRADED outcomes count, in either of the two idioms the tree uses: a `check` call, or a
      hand-rolled `VERIFY_FAIL=$((VERIFY_FAIL+1))` arm (agentic-ai.sh grades its whole end state
      that way, `case`ing a tri-state helper). warn/na/info are the other three outcomes of the
      _lib.sh contract and none of them GRADE: a completion branch containing only `warn` is
      exactly the "did NOT fully verify" case, and one containing only `na`/`info` asserts nothing.
      A VERIFY_PASS increment with no ❌ arm beside it does not count either — an outcome that
      cannot fail is the rubber stamp this guard exists to catch.

      MEASURED against the committed tree at the time of writing (2026-08-05): replayed over
      `git show HEAD:` for all 26 modules, detector [1] reports exactly one script —
      trusted-supply-chain, with 11 checks in both modes and 0 at completion, which is precisely
      the "✅ all 11 checks passed" the wave saw — and nothing else. 25 healthy scripts, spanning
      both mode-split polarities, `case`-arm gating, four-line `&&` conditions and hand-rolled
      accounting, stayed silent.

  [2] CATALOGUED MODULE WITH NO SCRIPT. A slug in /modules.yaml with no tools/verify/<slug>.sh
      grades nothing at completion by absence rather than by omission — same outcome for the
      attendee, and `ws verify` has nothing to run.

  [3] STALE EXEMPTION. An ALLOWLIST entry whose module no longer needs it (the script has since
      grown a completion check) or whose slug is not in the catalogue at all. An exemption that
      outlives its reason is how a guard quietly stops guarding.

HOW THE MODE GATE IS RECOGNIZED — keyed off the real idiom, read off the shipped tree, not guessed.
parse_verify_args (tools/verify/_lib.sh) sets ENTRY_ONLY and SOLVE_MODE to the strings "true"/
"false", and every one of the 26 scripts branches on them with a literal `[[ "$ENTRY_ONLY" == "true"
]]` / `!= "true"` test. Both polarities are in live use and both are idiomatic:

    if [[ "$ENTRY_ONLY" != "true" ]]; then   check …   fi          # build-deliver, pipelines-fundamentals
    if [[ "$ENTRY_ONLY" == "true" ]]; then   …   else   check …   fi   # config-multienv, storage-stateful …
    if [[ "$ENTRY_ONLY" == "true" ]]; then … elif … then check … else check … fi   # agentic-ai

so the scanner tracks if/elif/else/fi nesting and works out, per branch, what ENTRY_ONLY and
SOLVE_MODE must be for that branch to execute. It reads `[[ "$FAILOVER_DRILL" == "true" && \
"$ENTRY_ONLY" == "true" ]]` (resilience-multicluster-dr) correctly as still requiring entry mode,
and refuses to guess about a `||` — an unrecognized gate makes a region UNKNOWN, and an unknown
region never counts as completion coverage. That direction is deliberate: an unparsed gate should
cost a maintainer a comment, not silently certify a module.

DELIBERATE NON-GOALS. It does not judge whether the completion checks are GOOD ones — that a check
asserts the right object, or is outcome-based, or would survive a re-run. Those are the reviewer's
job and, respectively, verify-oc-read-guard's and verify-mutation-guard's. This guard answers one
question that no human reliably re-asks after the tenth module: does full mode grade anything at
all?

Exit codes:
  0  contract holds
  1  contract broken — or, under --self-test, every canary was correctly detected
  2  the guard could not inspect what it claims to inspect (no catalogue, unparsable script)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "modules.yaml"
VERIFY_DIR = REPO / "tools" / "verify"

# ---------------------------------------------------------------------------
# ALLOWLIST — explicit, reviewable exemptions.
#
# A module whose lesson genuinely leaves NOTHING gradeable behind may exist: a pure reading/tour
# module, or one whose entire exercise is a read-only console walk. Such a module belongs HERE, with
# the reason written out, so the exemption is visible in review and in `git log` — never by
# weakening detector [1], which would re-open the class for all 26.
#
# Adding an entry is a claim about the LAB, not about the script: "there is no artifact a completed
# attendee leaves behind that a completed-lab check could read". If the honest answer is instead
# "there is one, nobody has written the check yet", the entry is wrong — write the check.
#
# Detector [3] deletes stale entries for you by failing: an allowlisted module that later grows a
# completion check is reported until the entry is removed.
#
#   slug: reason (dated, and naming what was looked for and not found)
ALLOWLIST: dict[str, str] = {
    # (empty — every module in the catalogue currently has, or must grow, a completion check)
}

# ---------------------------------------------------------------------------
# Shell scanning
#
# Not a bash parser, and it does not need to be. These 26 scripts share one narrow house shape,
# pinned by tools/verify/README.md and the module template: helpers are column-0 `name() {` … `}`
# functions, the graded body is a flat sequence of `check …` lines, and mode splits are top-level
# if/elif/else/fi. The scanner reads exactly that shape and reports anything it cannot read as an
# INSPECTION FAILURE (rc 2) rather than passing it.

# `name() {`, optionally with a trailing comment — devspaces-inner-loop.sh writes
# `ws_ns_read() {  # ws_ns_read <resource>`, and a stricter regex skipped the function, then choked
# on the one-line `if …; then …; fi` inside it.
FUNC_OPEN = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*\s*\(\)\s*\{\s*(#.*)?$")
FUNC_CLOSE = re.compile(r"^\}\s*(#.*)?$")
# Keywords and the graded outcomes, recognized ONLY in command position (see command_words).
#
# TWO grading idioms, both live. `check` is the ordinary one, and of the four outcomes in _lib.sh it
# is the only one that GRADES — warn/na/info deliberately do not count, which is what makes a
# completion branch full of warns read as no coverage.
#
# The second idiom is a hand-rolled ❌: where a helper returns a TRI-state rc, scripts `case` on it
# and account for the outcome themselves —
#
#     0) echo "✅ agent executed a tool-grounded query"; VERIFY_PASS=$((VERIFY_PASS+1)) ;;
#     1) echo "❌ agent answered WITHOUT executing a tool"; VERIFY_FAIL=$((VERIFY_FAIL+1)) ;;
#     *) warn "the agent Route did not answer" ;;
#
# (tools/verify/agentic-ai.sh, whose entire end state is graded this way). Counting only `check`
# would report that module as grading nothing — a false accusation that teaches the next maintainer
# the guard is noise.
#
# It is the VERIFY_FAIL arm that counts, never VERIFY_PASS on its own: an outcome with no path to ❌
# cannot fail, and a check that cannot fail is the rubber stamp this whole guard exists to prevent.
KEYWORD = re.compile(
    r"\b(?P<kw>if|then|elif|else|fi|check)\b"
    r"|(?P<manual>VERIFY_FAIL=\$\(\(\s*VERIFY_FAIL\s*\+\s*1\s*\)\))"
)

# `"$ENTRY_ONLY" == "true"` and every spelling of it the tree uses (also ${ENTRY_ONLY}, bare $X, and
# `=` for `==`, which bash accepts inside [[ ]]).
MODE_TEST = re.compile(
    r"""["']?\$\{?(?P<var>ENTRY_ONLY|SOLVE_MODE)\}?["']?\s*
        (?P<op>==|!=|=)\s*
        ["']?(?P<val>true|false)["']?""",
    re.X,
)


class Unparsable(Exception):
    """The scanner met a shape it cannot read. Never downgraded to a pass."""


def _required(op: str, val: str) -> bool:
    """The value the variable must hold for this comparison to be TRUE."""
    truthy = val == "true"
    return truthy if op in ("==", "=") else not truthy


def condition_constraints(cond: str):
    """(constraints, simple) for an if/elif condition.

    constraints maps ENTRY_ONLY/SOLVE_MODE -> the value it must hold for the branch to run.
    `simple` says the condition is NOTHING BUT one mode test, which is what licenses negating it
    for the else branch. A compound `&&` still constrains the then-branch (both conjuncts must
    hold) but its negation does not constrain the else branch — `!(A && B)` leaves the mode free —
    so the else of a compound gate is UNKNOWN, never assumed to be the completion side.
    """
    # A disjunction can be satisfied without the mode test being true, so it constrains nothing.
    if "||" in cond:
        return {}, False
    found = {m.group("var"): _required(m.group("op"), m.group("val")) for m in MODE_TEST.finditer(cond)}
    # Peel the condition down to its bare comparison to decide whether it is a SOLE mode test.
    # Order matters, and getting it wrong is not a near-miss: the first version left the trailing
    # `;` on `[[ "$ENTRY_ONLY" == "true" ]];`, so `]]$` never matched, every such gate read as
    # compound, no else branch was ever recognized as the completion side — and the guard reported
    # 21 of 26 healthy scripts as blind. A gate that cries wolf 21 times is switched off on day one.
    s = cond.strip()
    s = re.sub(r";?\s*then\b.*$", "", s).strip()
    s = re.sub(r";\s*$", "", s).strip()
    if s.startswith("[[") and s.endswith("]]"):
        s = s[2:-2].strip()
    elif s.startswith("[") and s.endswith("]"):
        s = s[1:-1].strip()
    simple = len(found) == 1 and bool(MODE_TEST.fullmatch(s))
    return found, simple


class Frame:
    """One if/elif/else/fi construct, and what the CURRENT branch requires of the mode variables."""

    def __init__(self, cond: str, line: int):
        self.line = line
        self.cur, simple = condition_constraints(cond)
        # What the else branch may assume: the negation of the if-condition, but only when that
        # condition was nothing but a single mode test.
        self.else_cur = {k: (not v) for k, v in self.cur.items()} if simple else {}

    def branch_elif(self, cond: str) -> None:
        extra, simple = condition_constraints(cond)
        # An elif runs when every earlier condition was false AND this one is true.
        self.cur = dict(self.else_cur)
        for k, v in extra.items():
            self.cur[k] = v if k not in self.cur else (v if v == self.cur[k] else None)
        # Narrowing the else further only ever ADDS constraints; an unparsed elif leaves what the
        # if-condition already established untouched (else ⊆ ¬if).
        if simple:
            for k, v in extra.items():
                self.else_cur.setdefault(k, not v)

    def branch_else(self) -> None:
        self.cur = dict(self.else_cur)


def logical_lines(text: str):
    """Yield (lineno, joined_line) with backslash continuations folded and comment lines dropped.

    resilience-multicluster-dr.sh spreads one `if` condition over four continuation lines; read a
    line at a time, its `; then` is invisible and the whole construct is misparsed.
    """
    out = []
    buf, start = "", 0
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip("\n")
        if not buf and line.lstrip().startswith("#"):
            continue
        if not buf:
            start = i
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append((start, buf + line))
        buf = ""
    if buf:
        # The file ended inside a line continuation. Flushing the fragment would hand the scanner a
        # condition with no `then` and a stack that can never balance; reporting it as unreadable
        # is the honest outcome, and rc 2 says "could not inspect", not "clean".
        raise Unparsable("file ends inside a `\\` line continuation")
    return out


def mask_quotes(line: str) -> str:
    """Blank out quoted spans, preserving length so offsets still line up with the raw text.

    Every check carries a long human label and every failing check a longer `hint`, and those
    strings are full of the words this scanner keys off — "…if the pod is not ready…", "…then
    re-run…". Tokenizing the raw text reads them as shell keywords and desynchronizes the stack.
    """
    out = []
    quote = ""
    for ch in line:
        if quote:
            out.append(ch if ch == quote else "x")
            if ch == quote:
                quote = ""
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        out.append(ch)
    return "".join(out)


def command_words(line: str):
    """Yield (word, start, end) for keywords in COMMAND POSITION on a masked line.

    Command position, not "start of line": the tree puts `if` after a case pattern
    (`false)      if [[ … ]]; then`, jobs-batch-kueue.sh) and closes with `fi ;;`, and it writes
    whole one-line constructs (`if grep -qi forbidden "$tmp"; then rm -f "$tmp"; return 1; fi`,
    devspaces-inner-loop.sh). Anchoring to column 0 mis-parsed both — the first version of this
    scanner did, and reported them as unreadable files.
    """
    for m in KEYWORD.finditer(line):
        prefix = line[:m.start()].rstrip()
        if prefix and prefix[-1] not in ";&|(){}":
            # `then`/`else`/`do` also introduce a command list.
            if not re.search(r"\b(then|else|do)$", prefix):
                continue
        yield (m.group("kw") or "manual-fail"), m.start(), m.end()


def scan_script(path: Path):
    """Classify every `check` in one verify script by the mode(s) it can run in.

    counts keys: both (runs in every mode — entry state only), completion (what this guard
    requires), entry_only, solve_only, unknown (a gate it declined to guess at).
    """
    text = path.read_text(errors="replace")
    stack: list[Frame] = []
    in_func = False
    counts = {"both": 0, "completion": 0, "entry_only": 0, "solve_only": 0, "unknown": 0}
    # An `if`/`elif` whose condition is still being collected (it ends at the matching `then`).
    pending: list | None = None  # [kind, condition_text, lineno]

    for lineno, line in logical_lines(text):
        # Helper functions are skipped WHOLE: their bodies carry their own if/fi nesting, and no
        # verify script defines a `check` inside one (asserted over all 26 scripts, 2026-08-05).
        if not in_func and FUNC_OPEN.match(line):
            in_func = True
            continue
        if in_func:
            if FUNC_CLOSE.match(line):
                in_func = False
            continue

        masked = mask_quotes(line)
        cursor = 0
        for word, start, end in command_words(masked):
            if pending is not None and word != "then":
                # Still inside a condition — `[[ … ]] && cmd && …` may mention nothing else.
                continue
            if word in ("if", "elif"):
                if word == "elif" and not stack:
                    raise Unparsable(f"{path.name}:{lineno}: `elif` with no open `if`")
                pending = [word, "", lineno]
                cursor = end
                continue
            if word == "then":
                if pending is None:
                    continue  # `then` of a construct inside a skipped region
                cond = (pending[1] + line[cursor:start]).strip()
                if pending[0] == "if":
                    stack.append(Frame(cond, pending[2]))
                else:
                    stack[-1].branch_elif(cond)
                pending = None
                continue
            if word == "else":
                if not stack:
                    raise Unparsable(f"{path.name}:{lineno}: `else` with no open `if`")
                stack[-1].branch_else()
                continue
            if word == "fi":
                if not stack:
                    raise Unparsable(f"{path.name}:{lineno}: `fi` with no open `if`")
                stack.pop()
                continue
            if word in ("check", "manual-fail"):
                # Merge the constraints of every enclosing branch. A contradiction (one frame
                # demands entry mode, another demands full mode) is dead code — counted as
                # unknown, never as coverage.
                merged: dict[str, object] = {}
                for fr in stack:
                    for k, v in fr.cur.items():
                        if v is None or (k in merged and merged[k] != v):
                            merged[k] = None
                        else:
                            merged[k] = v
                entry = merged.get("ENTRY_ONLY", "unset")
                solve = merged.get("SOLVE_MODE", "unset")
                if entry is None or solve is None:
                    counts["unknown"] += 1
                elif entry is True:
                    counts["entry_only"] += 1
                elif entry is False:
                    # Gated out of entry mode — the completion side. It only COUNTS if a plain
                    # `ws verify` (SOLVE_MODE=false) also reaches it.
                    if solve is True:
                        counts["solve_only"] += 1
                    else:
                        counts["completion"] += 1
                else:
                    # No mode gate at all: runs identically before and after the lab, so it can
                    # only ever assert the world `ws prep` built.
                    counts["both"] += 1
        if pending is not None:
            # Condition continues on the next logical line (a `case` arm, or an `if` whose `then`
            # sits further down); keep collecting.
            pending[1] += line[cursor:] + " "

    if stack:
        raise Unparsable(f"{path.name}: {len(stack)} unterminated `if` (first at line {stack[0].line})")
    if pending is not None:
        raise Unparsable(f"{path.name}:{pending[2]}: `if` condition never reached a `then`")
    return counts


# ---------------------------------------------------------------------------
# Catalogue


def module_slugs(catalog: Path = CATALOG) -> list[str]:
    """Ordered slugs from /modules.yaml — position is the module number (see that file's header)."""
    if not catalog.exists():
        return []
    slugs = []
    for line in catalog.read_text(errors="replace").splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = re.match(r"^\s*-\s*slug:\s*([A-Za-z0-9][A-Za-z0-9-]*)\s*(?:#.*)?$", line)
        if m:
            slugs.append(m.group(1))
    return slugs


def audit(slugs: list[str], verify_dir: Path = VERIFY_DIR, allowlist: dict[str, str] | None = None):
    """Return (blind, missing, stale, inspected_count) for one catalogue + verify directory."""
    allow = ALLOWLIST if allowlist is None else allowlist
    blind, missing, stale = [], [], []
    # A COUNT, not a list of names: nothing downstream needs the names, and an `.append` here would
    # be a finding-emission site that no exit code can witness (tools/lint/_canary-coverage.py
    # reports exactly that as an unproven detector — correctly).
    inspected = 0
    seen_ok: set[str] = set()
    for slug in slugs:
        script = verify_dir / f"{slug}.sh"
        if not script.exists():
            missing.append(slug)
            continue
        counts = scan_script(script)
        inspected += 1
        if counts["completion"] > 0:
            seen_ok.add(slug)
            continue
        if slug in allow:
            continue
        blind.append((slug, script, counts))
    for slug, reason in allow.items():
        if slug not in slugs:
            stale.append((slug, "not in /modules.yaml", reason))
        elif slug in seen_ok:
            stale.append((slug, "now has a completion check — exemption no longer applies", reason))
    return blind, missing, stale, inspected


def report(blind, missing, stale) -> int:
    rc = 0
    if blind:
        rc = 1
        print(f"❌ [1] {len(blind)} verify script(s) grade NOTHING at completion — full mode prints a")
        print("       green banner over a world the attendee never touched.")
        for slug, script, c in blind:
            rel = script.relative_to(REPO)
            print(f"   {rel}")
            print(f"      graded outcomes: {c['both']} run in BOTH modes (so they can only assert "
                  f"the entry state) · {c['entry_only']} entry-only · {c['solve_only']} "
                  f"--solve-only · {c['unknown']} behind a gate this guard could not read")
            if c["solve_only"]:
                print("      ↳ its only completion checks need --solve. `ws verify <module>` after a")
                print("        HAND-completed lab still grades nothing.")
            elif c["unknown"]:
                print("      ↳ a gate could not be read. If it IS the mode split, spell it")
                print('        `if [[ "$ENTRY_ONLY" != "true" ]]; then` so both this guard and the')
                print("        next maintainer can see it.")
            else:
                print("      ↳ add an end-state block:")
                print('        if [[ "$ENTRY_ONLY" != "true" ]]; then  check "<what a completed lab')
                print('        leaves behind>" … || hint "<the lab step that creates it>"  fi')
            print("      If the lab truly leaves nothing gradeable behind, say so in ALLOWLIST at the")
            print("      top of tools/lint/completion-coverage-guard.py — with the reason.")
    if missing:
        rc = 1
        print(f"❌ [2] {len(missing)} catalogued module(s) have no verify script at all:")
        for slug in missing:
            print(f"   {slug} — expected tools/verify/{slug}.sh (`ws verify {slug}` has nothing to run)")
    if stale:
        rc = 1
        print(f"❌ [3] {len(stale)} stale ALLOWLIST entry/entries — an exemption that outlived its reason:")
        for slug, why, reason in stale:
            print(f"   {slug}: {why}")
            print(f"      recorded reason: {reason}")
    if rc == 0:
        print("✅ completion coverage: every catalogued module's verify script grades at least one")
        print("   end-state outcome that a plain `ws verify` reaches and `--entry-only` skips")
    return rc


# ---------------------------------------------------------------------------
# Fixtures

_PREAMBLE = """#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

thing_present() {
  oc_read get deploy thing -n "$1" -o name || return 1
  grep -q thing <<<"$OC_OUT"
}

check "namespace ${NS} exists" oc get ns "$NS" || hint "ws start demo --user ${USER_NAME}"
"""

# TWO clean fixtures, one per live polarity, each proved silent ON ITS OWN. Deliberately not one
# fixture carrying both: the first version of this guard combined them, the `== "true"` … `else`
# half was mis-parsed into no coverage at all, and the fixture still passed because the OTHER half
# supplied the coverage. It took the real-tree run (21 of 26 healthy scripts flagged) to expose
# what the self-test had certified. A canary that can be satisfied by the wrong half proves nothing.
#
# Clean A — `== "true"` … `else`, the majority shape (config-multienv, storage-stateful, …), with a
# --solve-only check nested BESIDE a real completion check, and a one-line `if … fi` in a case arm.
FIXTURE_CLEAN_ELSE = _PREAMBLE + """
case "${USER_NAME}" in
  user*) if [[ -n "$NS" ]]; then info "namespace ${NS}"; fi ;;
esac

if [[ "$ENTRY_ONLY" == "true" ]]; then
  check "clean slate: thing not deployed yet" thing_absent "$NS" || hint "ws reset demo"
else
  check "thing deployed by the attendee" thing_present "$NS" || hint "lab exercise 2"
  if [[ "$SOLVE_MODE" == "true" ]]; then
    check "solve marker present" oc get cm ws-solve-demo -n "$NS" || hint "ws solve demo"
  fi
fi
verify_summary
"""

# Clean B — `!= "true"`, the other live shape (build-deliver, pipelines-fundamentals, …), with a
# label and a hint full of the words this scanner keys off.
FIXTURE_CLEAN_NEGATED = _PREAMBLE + """
if [[ "$ENTRY_ONLY" != "true" ]]; then
  check "route answers 200 (if it does not, then check the Route)" route_answers_200 "$NS" \\
    || hint "publish it — lab exercise 4; if the Route exists, then delete and re-create it"
fi
verify_summary
"""

# Clean C — the hand-rolled grading idiom (agentic-ai.sh): a tri-state helper, `case`d, accounted
# for by the script itself. Its ❌ arm is a graded completion outcome and must read as coverage.
FIXTURE_CLEAN_MANUAL = _PREAMBLE + """
if [[ "$ENTRY_ONLY" != "true" ]]; then
  ask_rc=0; tool_grounded_answer || ask_rc=$?
  case "$ask_rc" in
    0) echo "✅ agent executed a tool-grounded query"; VERIFY_PASS=$((VERIFY_PASS+1)) ;;
    1) echo "❌ agent answered WITHOUT executing a tool"
       VERIFY_FAIL=$((VERIFY_FAIL+1))
       hint "retry once, then: ws solve demo --user ${USER_NAME}" ;;
    *) warn "the agent Route did not answer — cannot evaluate from here" ;;
  esac
fi
verify_summary
"""

# Canary A — the shipped trusted-supply-chain shape: every check runs in both modes, and the one
# mode-split branch ADDS an entry-only check. Full mode grades nothing.
FIXTURE_BOTH_MODES_ONLY = _PREAMBLE + """
check "entry marker present" oc get cm ws-entry-demo -n "$NS" || hint "ws start demo"
check "warm artifact present" thing_present "$NS" || hint "ws prep demo"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  check "seed still present" seed_present "$NS" || hint "ws reset demo"
fi
verify_summary
"""

# Canary B — a completion branch that GRADES nothing: warn/na/info are not checks.
FIXTURE_UNGRADED_END = _PREAMBLE + """
if [[ "$ENTRY_ONLY" != "true" ]]; then
  warn "end state not evaluated from here" || true
  na "cluster has no such capability"
  info "see the module wrap-up"
fi
verify_summary
"""

# Canary C — the only completion check needs --solve, so the attendee's own `ws verify` after a
# hand-completed lab still grades nothing.
FIXTURE_SOLVE_ONLY = _PREAMBLE + """
if [[ "$ENTRY_ONLY" != "true" && "$SOLVE_MODE" == "true" ]]; then
  check "solve marker present" oc get cm ws-solve-demo -n "$NS" || hint "ws solve demo"
fi
verify_summary
"""

# Canary D — an inverted gate: the end-state checks sit in the ENTRY-ONLY branch, so full mode runs
# nothing graded. Cheap typo, invisible in review, identical symptom.
FIXTURE_INVERTED = _PREAMBLE + """
if [[ "$ENTRY_ONLY" == "true" ]]; then
  check "thing deployed by the attendee" thing_present "$NS" || hint "lab exercise 2"
fi
verify_summary
"""

# Canary E — hand-rolled accounting with NO path to ❌. Every arm ticks VERIFY_PASS, so the banner
# counts outcomes that could not have failed: a rubber stamp wearing a green tick, which is the
# exact shape of the false ✅ this guard exists for.
FIXTURE_PASS_ONLY = _PREAMBLE + """
if [[ "$ENTRY_ONLY" != "true" ]]; then
  ask_rc=0; tool_grounded_answer || ask_rc=$?
  case "$ask_rc" in
    0) echo "✅ agent executed a tool-grounded query"; VERIFY_PASS=$((VERIFY_PASS+1)) ;;
    *) echo "✅ agent reachable"; VERIFY_PASS=$((VERIFY_PASS+1)) ;;
  esac
fi
verify_summary
"""


def _write(d: Path, slug: str, body: str) -> None:
    (d / f"{slug}.sh").write_text(body)


def self_test(tmp: Path) -> int:
    vd = tmp / "verify"
    vd.mkdir()
    cat = tmp / "modules.yaml"

    def catalogue(*slugs: str) -> Path:
        cat.write_text("# comment: - slug: not-a-module\nmodules:\n"
                       + "".join(f"  - slug: {s}\n    title: \"T\"\n    stacks: []\n" for s in slugs))
        return cat

    # Proof 0 — each clean fixture must stay silent ON ITS OWN. A detector that fires on the house
    # idiom gets switched off within a day, taking the whole class with it.
    for slug, body, shape in (
        ("clean-else", FIXTURE_CLEAN_ELSE, '`== "true"` … else'),
        ("clean-negated", FIXTURE_CLEAN_NEGATED, '`!= "true"`'),
        ("clean-manual", FIXTURE_CLEAN_MANUAL, "hand-rolled VERIFY_FAIL accounting"),
    ):
        _write(vd, slug, body)
        blind, missing, stale, _ = audit(module_slugs(catalogue(slug)), vd, {})
        if blind or missing or stale:
            print(f"❌ SELF-TEST FAILED: the CLEAN {shape} fixture was flagged "
                  f"(blind={[b[0] for b in blind]}, missing={missing}, stale={stale}).")
            print("   That polarity of the mode split is live in the tree and must read as covered.")
            return 2
        (vd / f"{slug}.sh").unlink()
    _write(vd, "clean", FIXTURE_CLEAN_ELSE)

    # Canaries A–E, each proved against the detector that owns it.
    for slug, body, why in (
        ("both-only", FIXTURE_BOTH_MODES_ONLY, "a script with no end-state checks at all"),
        ("ungraded-end", FIXTURE_UNGRADED_END, "a completion branch holding only warn/na/info"),
        ("solve-only", FIXTURE_SOLVE_ONLY, "a completion check reachable only under --solve"),
        ("inverted", FIXTURE_INVERTED, "end-state checks gated INTO --entry-only by mistake"),
        ("pass-only", FIXTURE_PASS_ONLY, "hand-rolled accounting with no arm that can reach ❌"),
    ):
        _write(vd, slug, body)
        blind, _, _, _ = audit(module_slugs(catalogue(slug)), vd, {})
        if not any(b[0] == slug for b in blind):
            print(f"❌ SELF-TEST FAILED: {why} was NOT detected — detector [1] is blind, and a module")
            print("   that grades nothing at completion would ship a green banner over an untouched world.")
            return 2
        (vd / f"{slug}.sh").unlink()

    # Canary E — a catalogued module with no script at all (detector [2]).
    _, missing, _, _ = audit(module_slugs(catalogue("clean", "ghost-module")), vd, {})
    if missing != ["ghost-module"]:
        print(f"❌ SELF-TEST FAILED: a catalogued module with no verify script was not reported "
              f"(missing={missing}) — detector [2] is blind.")
        return 2

    # Canary F — allowlist entries that outlived their reason (detector [3]), both shapes.
    _, _, stale, _ = audit(module_slugs(catalogue("clean")), vd,
                           {"clean": "r1", "long-gone": "r2"})
    if {s[0] for s in stale} != {"clean", "long-gone"}:
        print(f"❌ SELF-TEST FAILED: stale exemptions not reported (stale={[s[0] for s in stale]}) — "
              "detector [3] is blind and an exemption could outlive its reason forever.")
        return 2

    # Proof 1 — the allowlist must actually suppress, or a legitimate exemption is impossible and
    # the next maintainer weakens the detector instead.
    _write(vd, "both-only", FIXTURE_BOTH_MODES_ONLY)
    blind, _, _, _ = audit(module_slugs(catalogue("both-only")), vd, {"both-only": "documented reason"})
    if blind:
        print("❌ SELF-TEST FAILED: an ALLOWLIST entry did not suppress its finding.")
        return 2

    # Proof 2 — an unreadable script is an INSPECTION FAILURE, never a pass. Both shapes: an `if`
    # that never closes, and a file that ends inside a line continuation.
    for slug, body, shape in (
        ("broken-if", _PREAMBLE + '\nif [[ "$ENTRY_ONLY" != "true" ]]; then\n  check "x" true\n',
         "an unterminated `if`"),
        ("broken-cont", _PREAMBLE + '\ncheck "x" true \\\n', "a file ending inside a continuation"),
    ):
        _write(vd, slug, body)
        try:
            audit(module_slugs(catalogue(slug)), vd, {})
        except Unparsable:
            (vd / f"{slug}.sh").unlink()
            continue
        print(f"❌ SELF-TEST FAILED: {shape} parsed cleanly — the scanner would silently mis-read")
        print("   real mode gates and certify whatever it happened to see.")
        return 2

    # Proof 3 — the guard must be able to SEE the real catalogue and the real scripts, or a clean
    # verdict on the real tree means nothing.
    real = module_slugs()
    if not real:
        print("❌ SELF-TEST FAILED: /modules.yaml yielded no slugs — the real scan would pass by "
              "inspecting nothing.")
        return 2
    present = [s for s in real if (VERIFY_DIR / f"{s}.sh").exists()]
    if not present:
        print("❌ SELF-TEST FAILED: no verify script matched any catalogued slug — the real scan "
              "would pass by inspecting nothing.")
        return 2

    print("✅ self-test ok — three clean fixtures each silent on their own (both mode-split")
    print("   polarities, hand-rolled VERIFY_FAIL accounting, helper functions, case-arm one-liners,")
    print("   a --solve check beside a real one); no-end-state / ungraded-end / solve-only /")
    print("   inverted-gate / pass-only canaries caught; missing-script and stale-exemption canaries")
    print(f"   caught; allowlist suppresses; unparsable script raises; {len(present)} of {len(real)} "
          "catalogued modules visible to the real scan.")
    return 1  # house convention: every canary caught == exit exactly 1


def main(argv=None) -> int:
    # argv is a PARAMETER, not read from sys.argv, because tools/lint/_canary-coverage.py drives
    # every guard by calling `mod.main(argv)` in-process to blind one detector at a time. A
    # zero-argument main() raises TypeError there, the sweep records "unmutated control ran 2/2",
    # and this guard's detectors go UNPROVEN while every job still looks green.
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the detectors fire against planted canaries (exit 1 = PASS)")
    args = ap.parse_args(argv)

    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return self_test(Path(td))

    slugs = module_slugs()
    if not slugs:
        print(f"❌ no module slugs read from {CATALOG} — refusing to report a clean scan of nothing.")
        return 2
    if not VERIFY_DIR.is_dir():
        print(f"❌ {VERIFY_DIR} is not a directory — refusing to report a clean scan of nothing.")
        return 2
    try:
        blind, missing, stale, inspected = audit(slugs)
    except Unparsable as exc:
        print(f"❌ could not parse a verify script: {exc}")
        print("   The guard will not certify completion coverage it could not read.")
        return 2
    print(f"   inspected {inspected} verify script(s) for {len(slugs)} catalogued module(s)"
          + (f" · {len(ALLOWLIST)} allowlisted" if ALLOWLIST else ""))
    return report(blind, missing, stale)


if __name__ == "__main__":
    sys.exit(main())
