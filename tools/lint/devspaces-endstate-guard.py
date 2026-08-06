#!/usr/bin/env python3
"""devspaces-endstate-guard — devspaces-inner-loop must keep grading the lab, not its first click.

ORIGIN (audit F-06, closed 2026-08-06). `tools/verify/devspaces-inner-loop.sh` graded exactly ONE
thing at completion: that the parasol-claims workspace had been started. That is lab exercise 1 —
clicking a tile on the Dev Spaces dashboard, about six minutes of a ~60-minute module — and it is not
where the lesson is. Everything the module is actually about (wire dev mode to the cluster database,
write an endpoint, watch it hot-reload, COMMIT AND PUSH it to your own fork, deploy what you pushed)
left the check untouched.

Measured live on a dev cluster, 2026-08-06, as user5 and user6 from their own kubeconfigs — both
with `ws-entry-devspaces-inner-loop` materialized in {user}-dev, neither having run one step of the
lab:

    ✅ namespace user6-dev exists            ✅ claims-db deployment has >=1 ready replica
    ✅ entry marker … present                ✅ parasol-claims deployment has >=1 ready replica
    ✅ workshop quota present in user6-dev   ✅ route parasol-claims answers 200 (/q/health/ready)
    ✅ Gitea fork user6/parasol-claims exists
    ⚠  the end state is not gradeable from here …
    ⚠  7 passed · 3 SKIPPED (not graded)     rc=0   (VERIFY_STRICT=1 -> rc=3)

Every one of those seven ✅ is a `ws prep` artefact. Completion mode graded ZERO attendee work and
reported "7 passed". The one end-state check sat on its ⚠ branch because {user}-devspaces is
Forbidden to an attendee until Che adopts it at first dashboard sign-in — which IS exercise 1 — so
that is the DEFAULT outcome for anyone who verifies before starting, not an edge case.

And the tripwire that exists for exactly this could not fire: `verify_summary` returns 4 ("NOTHING
was graded") only when PASS+FAIL is zero, and seven passing entry checks keep it above zero forever.
The module could grade none of the lab and still look busy. That is the structural reason nobody
caught this by reading output.

WHAT THIS GATE PINS. The verify script now also grades the /ping endpoint the attendee writes in
exercise 3 and pushes to their fork in exercise 5 — "the moment the inner loop hands off to the outer
loop", in the lab's own words, and the only durable attendee-authored artefact the module leaves.
This runs the REAL script against four recorded worlds and checks the mark on each line, the closing
verdict and the exit status:

    untouched           prep ran, attendee did nothing        -> the /ping line must be ❌, rc 1
    completed           did the lab, pushed it                -> ✅, "all 11 checks passed", rc 0
    pushed-variant      did the lab AND the Challenge         -> ✅ (the false-❌ direction)
    cluster-unreachable nothing can be asked                  -> ⚠ everywhere, no ❌, strict rc 4

The untouched world is a transcript of the live measurement above. The pushed worlds cannot be built
on a shared workshop cluster — they need a commit written into an attendee's Gitea fork, and `ws prep`
run against a user another lane is using — so they are recorded; see cmd-stub.py.

THE THREE ClaimResource.java WORLDS ARE DERIVED, NOT PASTED. "seeded" is read from
apps/parasol-claims' real source, which is what the fork job seeds; "pushed" is that file plus the
snippet the lab prints for the attendee to type, lifted out of lab.adoc. So the fixture cannot drift
away from either the app or the lab — and if someone renames the endpoint in the lab, or adds a
/ping to the app itself (which would make the check green for everybody, forever), detector [5]/[6]
says so instead of the fixture quietly agreeing with whichever file moved.

WHAT IT CANNOT CHECK, so nobody reads a green tick as more than it is. The recording is of what `oc`
and `curl` PRINTED, so the jsonpaths inside the verify script are data here, not code: a wrong field
selector is invisible to this gate, and a live `ws verify` stays the acceptance test for one. The
Dev Spaces halves of the end state (Che's namespace adoption, what the DevWorkspace controller labels)
are equally recordings and are asserted on cluster, not here.

Detectors, each with a canary of its own in --self-test:
  [1] marks        every recorded line appears with the mark the world requires
  [2] verdict      the closing banner is exactly what the world requires
  [3] exit code    the process status matches, plain and under VERIFY_STRICT=1
  [4] mode split   --entry-only never runs the completion check, and stays rc 0
  [5] lab anchor   the lab still teaches the endpoint the script grades
  [6] seed anchor  the seeded app source must NOT satisfy the predicate
  [7] modelled     no `oc`/`curl` call escaped the recording

Exit codes:
  0  every world reproduces
  1  a world no longer reproduces — or, under --self-test, every canary was correctly detected
  2  the harness could not run (missing fixture, unusable python/bash), so nothing was proven
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tools/verify/devspaces-inner-loop.sh"
LIB = REPO / "tools/verify/_lib.sh"
APP_SOURCE = REPO / "apps/parasol-claims/src/main/java/com/parasol/claims/ClaimResource.java"
LAB = REPO / "content/modules/ROOT/pages/devspaces-inner-loop/lab.adoc"
FIXTURES = Path(__file__).resolve().parent / "devspaces-endstate-fixtures"
STUB = FIXTURES / "cmd-stub.py"
CASES = ("untouched", "completed", "pushed-variant", "cluster-unreachable")

# The endpoint the lab tells the attendee to write. Kept here as the ONE literal this gate is allowed
# to know, because detector [5] exists to prove the lab still says it — if the module ever renames the
# endpoint, that detector fires and this constant is the thing to change, in the same edit as the
# script's regex.
LAB_PATH_ANNOTATION = '@Path("/ping")'


class Harness:
    """Everything that can go wrong before a verdict exists. Missing input is rc 2, never a pass."""

    def __init__(self) -> None:
        self.problems: list[str] = []
        for path in (SCRIPT, LIB, APP_SOURCE, LAB, STUB):
            if not path.is_file():
                self.problems.append(f"{path.relative_to(REPO)} is missing")
        for name in CASES:
            if not (FIXTURES / f"{name}.case").is_file():
                self.problems.append(f"fixture {name}.case is missing")
        if shutil.which("bash") is None:
            self.problems.append("bash is not on PATH")


def parse_case(text: str) -> dict:
    """A .case is a recording plus what the world requires of the report. Tab-separated, one per line."""
    case: dict = {
        "lines": [], "marks": [], "verdict": None, "rc": None, "strict_rc": None,
        "entry_absent": [], "entry_verdict": None, "entry_rc": None, "args": ["--user", "user9"],
    }
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        fields = raw.split("\t")
        kind = fields[0]
        if kind in ("oc", "curl"):
            case["lines"].append(raw)
        elif kind == "mark" and len(fields) >= 3:
            case["marks"].append((fields[1], fields[2]))
        elif kind == "verdict" and len(fields) >= 2:
            case["verdict"] = fields[1]
        elif kind == "rc" and len(fields) >= 2:
            case["rc"] = int(fields[1])
        elif kind == "strict-rc" and len(fields) >= 2:
            case["strict_rc"] = int(fields[1])
        elif kind == "entry-absent" and len(fields) >= 2:
            case["entry_absent"].append(fields[1])
        elif kind == "entry-verdict" and len(fields) >= 2:
            case["entry_verdict"] = fields[1]
        elif kind == "entry-rc" and len(fields) >= 2:
            case["entry_rc"] = int(fields[1])
        elif kind == "args" and len(fields) >= 2:
            case["args"] = fields[1:]
    return case


def build_worlds(directory: Path, app_source: str, lab_text: str) -> list[str]:
    """The three fork contents, derived from the app and the lab rather than pasted.

    Returns a list of problems; an empty list means all three were built. A world that cannot be
    derived is a HARNESS failure, not a quiet fallback to something hand-written — the whole value of
    deriving them is that nobody can edit the app or the lab without this noticing.
    """
    problems: list[str] = []
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "seeded.java").write_text(app_source, encoding="utf-8")

    # Lifted out of the lab, not retyped: this is the exact block the attendee is shown.
    snippet = extract_lab_snippet(lab_text)
    if snippet is None:
        problems.append(
            "could not find the lab's /ping snippet in devspaces-inner-loop/lab.adoc — the fixture's "
            "'pushed' world would be something nobody is taught, so it is not built"
        )
        return problems

    closing = app_source.rstrip().rfind("}")
    if closing < 0:
        problems.append("apps/parasol-claims' ClaimResource.java has no closing brace to insert before")
        return problems
    head, tail = app_source[:closing], app_source[closing:]
    (directory / "pushed.java").write_text(head + snippet + "\n" + tail, encoding="utf-8")

    # The attendee who went further: annotation written the other legal way, and the Challenge's JSON
    # body instead of the sample string. Derived from the same snippet so it cannot drift from it.
    variant = (snippet
               .replace('@Path("/ping")', '@Path( "ping" )')
               .replace('@Produces(MediaType.TEXT_PLAIN)', '@Produces(MediaType.APPLICATION_JSON)')
               .replace('return "parasol-claims dev mode: hot reload works";',
                        'return Map.of("claims", Claim.count());'))
    if variant == snippet:
        problems.append(
            "the variant world is byte-identical to the pushed one, so the false-❌ canary would "
            "prove nothing — the lab's snippet no longer contains what it is derived from"
        )
        return problems
    (directory / "variant.java").write_text(head + variant + "\n" + tail, encoding="utf-8")
    return problems


def extract_lab_snippet(lab_text: str) -> str | None:
    """The `[source,java]` block in the lab that declares the endpoint."""
    for block in re.findall(r"\[source,java\][^\n]*\n----\n(.*?)\n----", lab_text, re.S):
        if LAB_PATH_ANNOTATION in block:
            return block
    return None


def run_case(name: str, case: dict, script_text: str, worlds: Path,
             entry_only: bool = False, strict: bool = False) -> tuple[int, str, list[str]]:
    """The REAL verify script, against this world. Returns (rc, output, unmodelled calls)."""
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        # The script under test is written out so a MUTANT can be run through the identical path as
        # the real one — same _lib.sh, same stub, same argv. A mutant tested any other way proves
        # something about the harness instead of about the script.
        stage = tmpdir / "verify"
        stage.mkdir()
        (stage / "devspaces-inner-loop.sh").write_text(script_text, encoding="utf-8")
        shutil.copy2(LIB, stage / "_lib.sh")

        casefile = tmpdir / "case"
        casefile.write_text("\n".join(case["lines"]) + "\n", encoding="utf-8")
        unknown = tmpdir / "unknown.log"
        unknown.touch()

        binpath = tmpdir / "bin"
        binpath.mkdir()
        for tool in ("oc", "curl"):
            shim = binpath / tool
            shim.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{STUB}" --as {tool} "$@"\n',
                            encoding="utf-8")
            shim.chmod(0o755)

        env = dict(os.environ)
        env["PATH"] = f"{binpath}:{env['PATH']}"
        env["DS_STUB_CASE"] = str(casefile)
        env["DS_STUB_UNKNOWN"] = str(unknown)
        env["DS_STUB_WORLDS"] = str(worlds)
        # The settle budget is a real sleep loop in _lib.sh's _ready_poll. Recorded worlds answer
        # immediately or not at all, so a budget here would only buy latency.
        env["VERIFY_SETTLE_BUDGET_S"] = "0"
        env["VERIFY_SETTLE_POLL_S"] = "1"
        if strict:
            env["VERIFY_STRICT"] = "1"

        argv = ["bash", str(stage / "devspaces-inner-loop.sh"), *case["args"]]
        if entry_only:
            argv.append("--entry-only")
        proc = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=120)
        calls = [line for line in unknown.read_text(encoding="utf-8").splitlines() if line.strip()]
        return proc.returncode, proc.stdout + proc.stderr, calls


def mark_of(output: str, needle: str) -> str | None:
    """The ✅/❌/⚠ on the line that carries `needle`. None when no line carries it."""
    for line in output.splitlines():
        if needle in line:
            stripped = line.strip()
            if stripped[:1] in ("✅", "❌", "⚠", "➖"):
                return stripped[0]
    return None


def findings(script_text: str, cases: dict[str, dict], worlds: Path, only: str | None = None,
             app_source: str | None = None, lab_text: str | None = None,
             run_cases: bool = True) -> list[str]:
    """Every detector, against a given script text. Empty list = the script is honest.

    All three inputs are TEXT, never paths. That is what lets --self-test mutate the app source and
    the lab without writing to the repository: this guard NEVER modifies a tracked file, not even
    briefly. An earlier draft restored what it rewrote and was still wrong — a concurrent reader (the
    canary-coverage meta-guard, another agent's lane, a `ws verify` on somebody's cockpit) sees the
    mutated tree during the window, and this project has already paid for exactly that with a lane
    that hit a syntax error in a file another lane was rewriting mid-run.
    """
    out: list[str] = []
    app_source = APP_SOURCE.read_text(encoding="utf-8") if app_source is None else app_source
    lab_text = LAB.read_text(encoding="utf-8") if lab_text is None else lab_text

    for name in CASES if run_cases else ():
        if only is not None and only != name:
            continue
        case = cases[name]
        rc, output, calls = run_case(name, case, script_text, worlds)

        # [7] modelled — first, because every other verdict below is worthless if the run was fed
        # answers nobody recorded.
        for call in calls:
            out.append(f"[{name}] the run made a call the recording does not model: {call}")

        # [1] marks
        for needle, want in case["marks"]:
            got = mark_of(output, needle)
            if got is None:
                out.append(f"[{name}] no line carries {needle!r} — the check it grades is gone, so "
                           f"this world is no longer graded at all")
            elif got != want:
                out.append(f"[{name}] {needle!r} is {got} and must be {want}")

        # [2] verdict
        if case["verdict"] is not None and case["verdict"] not in output:
            last = next((ln for ln in reversed(output.splitlines()) if ln.strip()), "")
            out.append(f"[{name}] the closing banner must be {case['verdict']!r}; last line was "
                       f"{last.strip()!r}")

        # [3] exit code
        if case["rc"] is not None and rc != case["rc"]:
            out.append(f"[{name}] exit status {rc}, must be {case['rc']}")
        if case["strict_rc"] is not None:
            src, _, scalls = run_case(name, case, script_text, worlds, strict=True)
            for call in scalls:
                out.append(f"[{name}/strict] unmodelled call: {call}")
            if src != case["strict_rc"]:
                out.append(f"[{name}/strict] VERIFY_STRICT=1 exit status {src}, must be "
                           f"{case['strict_rc']}")

        # [4] mode split
        erc, eout, ecalls = run_case(name, case, script_text, worlds, entry_only=True)
        for call in ecalls:
            out.append(f"[{name}/entry] unmodelled call: {call}")
        for needle in case["entry_absent"]:
            if needle in eout:
                out.append(f"[{name}/entry] --entry-only printed {needle!r}. A completion assertion "
                           f"in entry mode reds `ws doctor` for everyone who finished the module, "
                           f"and `ws prep` reads that rc as 'offer to wipe their world'")
        if case["entry_verdict"] is not None and case["entry_verdict"] not in eout:
            last = next((ln for ln in reversed(eout.splitlines()) if ln.strip()), "")
            out.append(f"[{name}/entry] the closing banner must be {case['entry_verdict']!r}; last "
                       f"line was {last.strip()!r}")
        if case["entry_rc"] is not None and erc != case["entry_rc"]:
            out.append(f"[{name}/entry] exit status {erc}, must be {case['entry_rc']}")

    # The two static anchors below are file-level, so a caller narrowed to ONE world (a mutant) —
    # or one that skipped the worlds entirely (an anchor canary) — must not re-run them and get an
    # unrelated finding it would then read as "my mutant was caught".
    if only is not None:
        return out

    # [5] lab anchor — the script grades an endpoint the lab must still teach. A rename in one file
    # and not the other turns a real check into a permanent ❌ (or, worse, a permanent ✅ if the
    # regex is the half that moved).
    if LAB_PATH_ANNOTATION not in lab_text:
        out.append(f"[lab] devspaces-inner-loop/lab.adoc no longer prints {LAB_PATH_ANNOTATION} for "
                   f"the attendee to type, but the verify script still grades it")
    if extract_lab_snippet(lab_text) is None:
        out.append("[lab] the lab's [source,java] block declaring the endpoint is gone, so the "
                   "'pushed' world cannot be derived from what attendees are shown")

    # [6] seed anchor — the whole check rests on the seeded fork NOT already containing the endpoint.
    # Add a /ping to apps/parasol-claims and every attendee grades ✅ from the moment `ws prep` runs.
    if re.search(r'@Path[ \t]*\([ \t]*"/?ping"[ \t]*\)', app_source):
        out.append("[seed] apps/parasol-claims' ClaimResource.java now declares the /ping endpoint "
                   "itself. The fork is SEEDED from it, so the completion check would pass for every "
                   "attendee the moment `ws prep` runs — F-06, reintroduced from the other side")
    return out


# name -> (old, new, which case must catch it on its own, why it matters)
# Each mutant reintroduces a false-pass (or false-fail) shape the audit names, expressed against the
# script's real text. A mutation whose `old` has been reworded out of the file is reported as a NO-OP
# rather than silently skipped: a canary that cannot fire proves nothing.
MUTANTS = (
    ("degenerate-true",
     "ping_endpoint_pushed() {\n  gitea_host || return 1",
     "ping_endpoint_pushed() {\n  return 0  # MUTANT\n  gitea_host || return 1",
     "untouched",
     "the canonical false pass — a predicate that cannot distinguish anything (audit F-05's bare ':')"),
    ("existence-not-content",
     '''grep -Eq '@Path[[:space:]]*\\([[:space:]]*"/?ping"[[:space:]]*\\)' <<<"$HTTP_OUT"''',
     '''[[ -n "$HTTP_OUT" ]]''',
     "untouched",
     "F-06 itself (audit shape 3): grading that the artefact EXISTS where the lab is about its CONTENT"),
    ("loose-regex",
     '''grep -Eq '@Path[[:space:]]*\\([[:space:]]*"/?ping"[[:space:]]*\\)' <<<"$HTTP_OUT"''',
     '''grep -Eq '@Path' <<<"$HTTP_OUT"''',
     "untouched",
     "audit shape 4: a predicate so loose the untouched seed satisfies it too"),
    ("regex-pinned-to-the-sample-string",
     '''grep -Eq '@Path[[:space:]]*\\([[:space:]]*"/?ping"[[:space:]]*\\)' <<<"$HTTP_OUT"''',
     '''grep -Fq 'parasol-claims dev mode: hot reload works' <<<"$HTTP_OUT"''',
     "pushed-variant",
     "the false-❌ direction: grading the sample's return VALUE fails the attendees who did the Challenge"),
    ("regex-no-whitespace-tolerance",
     '''grep -Eq '@Path[[:space:]]*\\([[:space:]]*"/?ping"[[:space:]]*\\)' <<<"$HTTP_OUT"''',
     '''grep -Fq '@Path("/ping")' <<<"$HTTP_OUT"''',
     "pushed-variant",
     "the false-❌ direction again: JAX-RS accepts @Path( \"ping\" ) and so must the check"),
    ("graded-in-entry-mode",
     '''  check "your /ping endpoint is pushed to ${USER_NAME}/parasol-claims (exercises 3 + 5)" ping_endpoint_pushed \\''',
     '''  :
fi
if true; then
  check "your /ping endpoint is pushed to ${USER_NAME}/parasol-claims (exercises 3 + 5)" ping_endpoint_pushed \\''',
     "untouched",
     "the mode split: an entry run that grades completion offers to wipe a finished attendee's world"),
)


def self_test() -> int:
    """Reintroduce each shape and require the suite to catch it. Exit 1 = every canary detected."""
    harness = Harness()
    if harness.problems:
        for problem in harness.problems:
            print(f"::error::devspaces-endstate-guard self-test: {problem}.", file=sys.stderr)
        return 2

    script_text = SCRIPT.read_text(encoding="utf-8")
    app_source = APP_SOURCE.read_text(encoding="utf-8")
    lab_text = LAB.read_text(encoding="utf-8")
    cases = {name: parse_case((FIXTURES / f"{name}.case").read_text(encoding="utf-8"))
             for name in CASES}
    failures: list[str] = []

    with tempfile.TemporaryDirectory() as tmp:
        worlds = Path(tmp) / "worlds"
        problems = build_worlds(worlds, app_source, lab_text)
        if problems:
            for problem in problems:
                print(f"::error::devspaces-endstate-guard self-test: {problem}", file=sys.stderr)
            return 2

        # Control. A suite that does not pass on the real thing proves nothing about the mutants.
        control = findings(script_text, cases, worlds)
        if control:
            failures.append("the UNMUTATED script does not pass its own suite, so nothing below "
                            "means anything:\n      " + "\n      ".join(control))

        for name, old, new, case_name, why in MUTANTS:
            if script_text.count(old) != 1:
                failures.append(
                    f"mutant {name}: tools/verify/devspaces-inner-loop.sh contains "
                    f"{script_text.count(old)} occurrences of the text it mutates (expected 1), so "
                    f"the mutation is a no-op or ambiguous and proves nothing. The code was "
                    f"reworded — re-express the defect, do not delete the canary.")
                continue
            # ONE case per mutant, deliberately: if a mutant were signed off by any case noticing it,
            # a defect that only one world can see could be masked by an unrelated world failing for
            # an unrelated reason. Naming the world is what makes each canary say something.
            caught = findings(script_text.replace(old, new), cases, worlds, only=case_name)
            if not caught:
                failures.append(f"mutant {name} was NOT caught by the {case_name} world ({why}). "
                                f"That world passes with the defect present, so a clean result on "
                                f"the real script is not evidence of anything.")

        # The two anchors are CROSS-FILE: they describe states that would silently destroy this check
        # without touching the verify script at all. Their canaries mutate the other file's TEXT in
        # memory and hand it to findings() — nothing is written to the repository, see findings().

        # [5] canary: the lab stops printing the annotation the script grades.
        if LAB_PATH_ANNOTATION not in lab_text:
            failures.append("[5] canary is a no-op: the lab does not contain the annotation to "
                            "rename, which detector [5] should already have reported.")
        elif not any(f.startswith("[lab]") for f in findings(
                script_text, cases, worlds, run_cases=False,
                lab_text=lab_text.replace(LAB_PATH_ANNOTATION, '@Path("/pong")'))):
            failures.append("[5] did not fire when the lab renamed the endpoint the script grades, "
                            "so the two files can drift apart unnoticed.")

        # [6] canary: the app itself grows the endpoint, which would green every attendee at prep.
        injected = app_source.replace('@Path("/{claimNumber}")', '@Path("/ping")', 1)
        if injected == app_source:
            failures.append("[6] canary is a no-op: apps/parasol-claims' ClaimResource.java no "
                            "longer contains the annotation the canary rewrites.")
        elif not any(f.startswith("[seed]") for f in findings(
                script_text, cases, worlds, run_cases=False, app_source=injected)):
            failures.append("[6] did not fire when the seeded app source itself declared /ping — "
                            "the state in which every attendee passes from the moment prep runs.")

    if failures:
        print("::error::devspaces-endstate-guard self-test FAILED — detection is unproven:",
              file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 2
    print(f"self-test ok — {len(MUTANTS)} false-pass/false-fail canaries and 2 cross-file anchors "
          f"were all detected, and the real script passes all {len(CASES)} worlds (rc=1).")
    return 1


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in argv:
        return self_test()

    harness = Harness()
    if harness.problems:
        for problem in harness.problems:
            print(f"::error::devspaces-endstate-guard: {problem}.", file=sys.stderr)
        return 2

    script_text = SCRIPT.read_text(encoding="utf-8")
    cases = {name: parse_case((FIXTURES / f"{name}.case").read_text(encoding="utf-8"))
             for name in CASES}
    with tempfile.TemporaryDirectory() as tmp:
        worlds = Path(tmp) / "worlds"
        problems = build_worlds(worlds, APP_SOURCE.read_text(encoding="utf-8"),
                               LAB.read_text(encoding="utf-8"))
        if problems:
            for problem in problems:
                print(f"::error::devspaces-endstate-guard: {problem}", file=sys.stderr)
            return 2
        found = findings(script_text, cases, worlds)

    if found:
        print("::error::devspaces-endstate-guard: devspaces-inner-loop no longer grades the lab the "
              "way these worlds require:", file=sys.stderr)
        for problem in found:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"devspaces-endstate-guard: all {len(CASES)} worlds reproduce — the module grades the "
          f"attendee's pushed change, not just the click that opens the workspace.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
