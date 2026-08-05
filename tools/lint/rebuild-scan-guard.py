#!/usr/bin/env python3
"""`ws rebuild-images --check` and `ws doctor`'s drift row, run against a recorded cluster.

WHY THIS EXISTS. The scan behind both is the only thing in this repo that can answer "is the pod on
the image we think it is". It cannot be checked by reading it: its whole job is to compare a digest
the workload spec does not carry, so a wrong answer looks exactly like a right one — a clean report.
That is not hypothetical either. Its author's own first draft shipped four defects that each
produced a plausible, quiet, WRONG report, and all four were found by running it on a cluster:

  · `IFS=$'\t' read` COLLAPSES empty fields, because TAB is IFS *whitespace*. A CronJob has no
    .spec.selector, so an empty selector column shifted every later field left and every CronJob
    vanished from the scan without a word. The go-template emits a literal "-" for exactly this.
  · Knative runs each Revision as its own Deployment. Those double-counted the ksvc and invited an
    `oc rollout restart` against a resource the Serving controller owns — which looks like a fix and
    is not. Excluded on the revisionUID selector.
  · After a ksvc rolls, the RETIRED Revision's pods stay Running, so a service-wide pod match calls a
    just-fixed service stale. Matched on .status.traffic[].revisionName instead.
  · Splitting the image ref from the left makes the registry's own `:5000` look like a tag.

None of that needs a cluster to REPRODUCE, only to discover. So this gate records one.

WHAT IT DOES. Two halves, and neither is a grep for a string that "looks right":

  CONTRACT (static). rebuild_scan emits an 11-field TSV row that four places read back. Field-count
  drift between a producer and one of its consumers is silent — read just binds fewer names — and the
  symptom is a mislabelled state, not an error. This half pins the arity and the field ORDER of every
  producer/consumer pair in the rebuild path, plus the handful of emptiness guards whose absence is
  what makes a collapse possible in the first place.

  BEHAVIOUR (fixture). Runs the real `tools/ws/ws` with a recorded `oc` at the front of PATH and
  compares the table it prints, row for row and state for state, against what the recording must
  produce — then runs `ws doctor` over the same recording and asserts its one-line summary carries
  the same counts and names the same offenders. Nothing is mocked inside ws; the shell that runs on
  a cluster is the shell that runs here.

WHAT IT CANNOT CHECK, stated plainly. The recording is of TEMPLATED `oc` output, so the go-templates
inside rebuild_enumerate and rebuild_pod_digests are data here, not code — a mistake inside one is
invisible to the behaviour half. That is why the contract half asserts their emptiness guards
directly, and why `ws rebuild-images --check` on a live cluster stays the acceptance test for a
change to those templates. It also cannot tell you the cluster is healthy; it tells you the reporter
is honest.

Exit codes: 0 clean · 1 findings · 2 the guard could not run (which is never a pass).
`--self-test` proves detection by MUTATION: it reintroduces each measured defect into a copy of ws
(or into the recording) and requires the suite to fail on every one, and to pass unmutated. It exits
1 when every mutant was caught, which is what the CI step asserts.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
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
    print(f"::error::rebuild-scan-guard: crashed before it could report "
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
    print(f"::error::rebuild-scan-guard: cannot import _scope ({exc}) — "
          f"the guard could not start, which is NOT the same as a clean tree.",
          file=sys.stderr)
    sys.exit(2)


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    WHY (measured 2026-08-01). Every pattern compiled at MODULE level raises re.error before main()
    — and before any try/except inside it — can run. Python exits 1 on an uncaught exception, and 1
    is exactly what CI's `--self-test must exit EXACTLY 1` assertion accepts as "the canary was
    detected". A one-character regex typo therefore reported the guard's detection as PROVEN while
    the guard could not even load. A regex is the likeliest thing to break in a guard, so the
    compile step is where the exit code has to be fixed.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::rebuild-scan-guard: {name} is not a valid regex ({exc}) — "
              f"the guard could not load. Exiting 2: that is 'the guard is broken', not "
              f"'the canary fired'.", file=sys.stderr)
        sys.exit(2)


try:
    import yaml
except ModuleNotFoundError:
    print("::error::rebuild-scan-guard: PyYAML is not installed. This guard READS a recorded "
          "cluster; without a parser it cannot run, and a guard that cannot run must not report "
          "success.", file=sys.stderr)
    raise SystemExit(2)

REPO = pathlib.Path(__file__).resolve().parents[2]
WS = REPO / "tools/ws/ws"
FIXTURES = REPO / "tools/lint/rebuild-scan-fixtures"
CLUSTER = FIXTURES / "cluster.yaml"
STUB = FIXTURES / "oc-stub.py"

# The 11 fields rebuild_scan emits, in order. Every consumer must read exactly these names in
# exactly this order — the names are the documentation, and a reordering that keeps the arity is
# the one drift a count alone would miss.
SCAN_FIELDS = ["kind", "ns", "name", "cname", "owner", "module",
               "src", "want", "running", "stale", "state"]


# ── the contract half ─────────────────────────────────────────────────────────────────────────

def function_body(source: str, name: str) -> str:
    """The text of a top-level shell function, from `name() {` to the closing `}` in column 1."""
    match = re.search(rf"^{re.escape(name)}\(\)\s*\{{", source, re.M)
    if not match:
        raise LookupError(name)
    rest = source[match.end():]
    end = re.search(r"^\}", rest, re.M)
    return rest[:end.start()] if end else rest


def printf_field_counts(body: str) -> list[int]:
    """Field count of every `printf 'a\\tb\\t…\\n'` in a body — i.e. its tab count plus one."""
    counts = []
    for fmt in re.findall(r"printf\s+'([^']*\\n)'", body):
        if "\\t" not in fmt:
            continue
        counts.append(fmt.count("\\t") + 1)
    return counts


def read_var_lists(body: str) -> list[list[str]]:
    """Variable lists of every `IFS=$'\\t' read -r a b c` in a body."""
    out = []
    for names in re.findall(r"IFS=\$'\\t'\s+read\s+-r\s+([^\n;<]*)", body):
        out.append(names.split())
    return out


def contract_findings(source: str) -> tuple[list[str], int]:
    """(findings, pinned invariants actually checked).

    Takes the script TEXT, never the path: the self-test's contract mutants must never be able to
    leave a mutated tools/ws/ws behind if this process is interrupted.

    The second return value exists because main() runs two independent halves and dropping either
    one left the guard reporting "clean" and exiting 0 (audit 2026-08-01). Both halves now report
    how many things they pinned, and main() measures that against a floor.
    """
    findings: list[str] = []
    checked = 0
    try:
        bodies = {name: function_body(source, name) for name in (
            "rebuild_enumerate", "rebuild_scan", "rebuild_print_table",
            "rebuild_row_summary", "rebuild_image_parts", "cmd_rebuild_images", "cmd_doctor")}
    except LookupError as missing:
        return ([f"tools/ws/ws no longer defines {missing.args[0]}() — the rebuild path was renamed "
                 f"or removed and this guard is checking nothing. Update it deliberately."], 0)

    # 1. rebuild_scan's two row printfs must agree with each other and with all three readers.
    scan_widths = set(printf_field_counts(bodies["rebuild_scan"]))
    checked += 1
    if scan_widths != {len(SCAN_FIELDS)}:
        findings.append(f"rebuild_scan emits rows of width {sorted(scan_widths)}; the row contract "
                        f"is {len(SCAN_FIELDS)} fields ({' '.join(SCAN_FIELDS)}). Its two printfs "
                        f"(the digest-pinned early return and the normal path) must stay identical "
                        f"in width — a reader binds fewer names in silence.")
    for consumer in ("rebuild_print_table", "rebuild_row_summary", "cmd_rebuild_images"):
        checked += 1
        lists = [names for names in read_var_lists(bodies[consumer]) if names[:1] == ["kind"]]
        if not lists:
            findings.append(f"{consumer}() no longer reads a rebuild_scan row "
                            f"(`IFS=$'\\t' read -r kind …`). If it stopped consuming the scan, this "
                            f"guard's pairing is stale; if it was reworded, re-pair it here.")
        for names in lists:
            if names != SCAN_FIELDS:
                findings.append(f"{consumer}() reads {len(names)} field(s) {' '.join(names)} from a "
                                f"rebuild_scan row, which emits {len(SCAN_FIELDS)}: "
                                f"{' '.join(SCAN_FIELDS)}. Field drift is silent — the extra names "
                                f"come back empty and every later name is off by one.")

    # 2. rebuild_enumerate's rows and the reader in rebuild_scan.
    enum_reader = [n for n in read_var_lists(bodies["rebuild_scan"]) if n[:1] == ["kind"]
                   and "sel" in n]
    # Per EMITTED ROW, not per template: the workload template has two row-emitting blocks (plain
    # containers and a CronJob's .spec.jobTemplate containers), so counting tabs across the whole
    # string reports 11 for a 6-field row. Split on the row terminator and count each block.
    enum_tabs = set()
    for tmpl in re.findall(r"local\s+k?tmpl='([^']*)'", bodies["rebuild_enumerate"]):
        for block in tmpl.split('{{"\\n"}}'):
            if '{{"\\t"}}' in block:
                enum_tabs.add(block.count('{{"\\t"}}') + 1)
    checked += 1
    if not enum_reader:
        findings.append("rebuild_scan() no longer reads rebuild_enumerate's rows "
                        "(`IFS=$'\\t' read -r kind ns name sel cname image`).")
    elif enum_tabs and enum_tabs != {len(enum_reader[0])}:
        findings.append(f"rebuild_enumerate's go-template(s) emit {sorted(enum_tabs)} field(s) per "
                        f"row but rebuild_scan reads {len(enum_reader[0])} "
                        f"({' '.join(enum_reader[0])}). The workload and ksvc templates must emit "
                        f"the same width as each other and as the reader.")

    # 3. rebuild_row_summary's output and cmd_doctor's reader.
    summary_widths = set(printf_field_counts(bodies["rebuild_row_summary"]))
    doctor_reads = [n for n in read_var_lists(bodies["cmd_doctor"]) if n[0].startswith("d_")]
    checked += 2
    if summary_widths != {4}:
        findings.append(f"rebuild_row_summary emits {sorted(summary_widths)} field(s); ws doctor "
                        f"reads total/stale/no-tag/offenders.")
    if not doctor_reads:
        findings.append("cmd_doctor() no longer consumes rebuild_row_summary — the image-drift row "
                        "was removed or rewired. `ws doctor` swallowing drift is the gap this row "
                        "exists to close.")
    for names in doctor_reads:
        if len(names) != 4:
            findings.append(f"ws doctor reads {len(names)} field(s) {' '.join(names)} from "
                            f"rebuild_row_summary, which emits 4.")

    # 4. rebuild_image_parts' output and its reader.
    parts_widths = set(printf_field_counts(bodies["rebuild_image_parts"]))
    parts_reads = [n for n in read_var_lists(bodies["rebuild_scan"]) if n[:1] == ["src_ns"]]
    checked += 2
    if parts_widths != {4}:
        findings.append(f"rebuild_image_parts emits {sorted(parts_widths)} field(s); its three "
                        f"printfs (digest ref, tagged ref, bare ref) must all emit 4.")
    for names in parts_reads:
        if len(names) != 4:
            findings.append(f"rebuild_scan reads {len(names)} field(s) from rebuild_image_parts, "
                            f"which emits 4.")

    # 5. The emptiness guards. A collapsed field is only possible where a field CAN be empty, and
    #    each of these is a measured or one-step-away instance rather than a defensive habit.
    checked += 1
    if '{{if not $s}}{{$s = "-"}}{{end}}' not in bodies["rebuild_enumerate"]:
        findings.append('rebuild_enumerate no longer emits the literal "-" for a workload with no '
                        '.spec.selector. A CronJob has none, so the column goes empty, `IFS=$\'\\t\' '
                        'read` collapses it, and every CronJob leaves the scan silently — measured '
                        'on ksls5 2026-07-29 with a probe CronJob that never appeared.')
    ksvc_tmpl = re.search(r"local\s+ktmpl='([^']*)'", bodies["rebuild_enumerate"])
    checked += 1
    if ksvc_tmpl and '{{$sel := printf' not in ksvc_tmpl.group(1):
        findings.append("rebuild_enumerate's ksvc template no longer initializes $sel with a "
                        "printf, so a ksvc with no .status.traffic emits an empty selector column "
                        "and collapses the row the same way a CronJob did.")
    checked += 1
    if "${module:--}" not in bodies["rebuild_scan"] or "${want:--}" not in bodies["rebuild_scan"]:
        findings.append("rebuild_scan must emit ${module:--} and ${want:--}, not bare $module / "
                        "$want. Both come from a lookup that legitimately returns nothing — a ksvc "
                        "without the module label, a tag that does not exist — and an empty field "
                        "in the middle of the row shifts every field after it.")
    checked += 1
    if "${names:--}" not in bodies["rebuild_row_summary"]:
        findings.append("rebuild_row_summary must emit ${names:--}: with no offenders the field is "
                        "empty, `IFS=$'\\t' read` binds nothing to it, and ws doctor prints "
                        "whatever that variable held before.")
    checked += 1
    # The EXECUTABLE form, not the bare word. `"revisionUID" not in body` was satisfied by the
    # explanatory COMMENT two lines above the case statement, so deleting the skip itself and
    # leaving the comment behind passed this check — the exact edit a "simplification" makes.
    # Measured 2026-08-01 while canarying the contract half.
    if 'serving.knative.dev/revisionUID*) continue' not in bodies["rebuild_scan"]:
        findings.append("rebuild_scan no longer skips workloads selected by "
                        "serving.knative.dev/revisionUID. Knative runs each Revision as its own "
                        "Deployment, so those double-count the ksvc row and invite an "
                        "`oc rollout restart` that looks like a fix and is not.")
    return findings, checked


# ── the behaviour half ────────────────────────────────────────────────────────────────────────

class Recording:
    """A temp dir holding a copy of ws, the stub `oc`, and the recorded call map."""

    def __init__(self, root: pathlib.Path, calls: dict, ws_source: str):
        self.root = root
        (root / "tools/ws").mkdir(parents=True)
        (root / "bin").mkdir()
        self.ws = root / "tools/ws/ws"
        self.ws.write_text(ws_source, encoding="utf-8")
        self.ws.chmod(0o755)
        shutil.copy(STUB, root / "bin/oc-stub.py")
        shim = root / "bin/oc"
        shim.write_text('#!/bin/sh\nexec python3 "$(dirname "$0")/oc-stub.py" "$@"\n',
                        encoding="utf-8")
        shim.chmod(0o755)
        self.calls_path = root / "calls.json"
        self.calls_path.write_text(json.dumps(calls), encoding="utf-8")
        self.unknown = root / "unknown-calls.log"
        self.unknown.touch()

    def run(self, argv: list[str]) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = f"{self.root / 'bin'}{os.pathsep}{env['PATH']}"
        env["WS_STUB_CALLS"] = str(self.calls_path)
        env["WS_STUB_UNKNOWN"] = str(self.unknown)
        env["KUBECONFIG"] = str(self.root / "no-such-kubeconfig")
        # Merged, not separated. `err()` writes to stderr and `printf "  %-28s" label` to stdout, so
        # a ws doctor ROW IS SPLIT ACROSS BOTH STREAMS — reading stdout alone shows the label of the
        # drift row followed by the next check's verdict, and every assertion about the row silently
        # tests the wrong text. One pipe reproduces what a terminal shows.
        # encoding is pinned rather than inherited from the locale: every state this compares is
        # spelled with ✅/❌/➖, so a runner that lands on a non-UTF-8 default would turn a real
        # comparison into a decoding accident.
        return subprocess.run(["bash", str(self.ws), *argv], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                              env=env, timeout=180)


# One printed row. Anchored on the two columns that have a SHAPE — pods `n/m` and a state that runs
# to end of line — because the five before them are single tokens and the padding between them is
# not reliable: the IMAGE column is %-40s and `ogsr-parasol-images/parasol-agent@digest` is exactly
# 40 characters, so it overflows to a SINGLE separating space. Splitting on runs of two-or-more
# spaces silently dropped that row (and only that row) from this guard's first run.
ROW = _compile("ROW", r"^\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+/\d+)\s+(.+?)\s*$")


def parse_table(output: str) -> list[tuple[str, ...]]:
    """The consumer table `ws rebuild-images --check` prints, as one tuple per row."""
    return [match.groups() for match in (ROW.match(line) for line in output.splitlines()) if match]


def behaviour_findings(calls: dict, expect: dict, doctor_row: dict,
                       ws_source: str) -> tuple[list[str], int]:
    """(findings, recorded-cluster reproductions actually run). See contract_findings for why the
    count exists: main() drops either half without the run looking any different."""
    findings: list[str] = []
    reproductions = 0
    with tempfile.TemporaryDirectory() as tmp:
        rec = Recording(pathlib.Path(tmp), calls, ws_source)
        for case, spec in expect.items():
            reproductions += 1
            proc = rec.run(spec["argv"])
            got = parse_table(proc.stdout)
            want = [tuple(row) for row in spec["rows"]]
            if got != want:
                findings.append(f"case {case} ({' '.join(spec['argv'])}): the report does not match "
                                f"the recording.\n      expected: " +
                                "\n                ".join(" | ".join(r) for r in want) +
                                "\n      got:      " +
                                ("\n                ".join(" | ".join(r) for r in got) or "(no rows)"))
            if proc.returncode != spec["exit"]:
                findings.append(f"case {case}: exit {proc.returncode}, expected {spec['exit']}. "
                                f"`--check` is consumed by ws doctor and CI as a pass/fail, so its "
                                f"status is part of the contract, not decoration.")
        unknown = rec.unknown.read_text(encoding="utf-8").strip()
        if unknown:
            findings.append("the read-only path made `oc` calls the recording does not model, so "
                            "part of the report above came from no data at all:\n      " +
                            "\n      ".join(sorted(set(unknown.splitlines()))))

        # ws doctor over the same recording. Its other rows fail (nothing else is modelled) and it
        # exits 1 — irrelevant here. What matters is that its ONE line agrees with the table above.
        rec.unknown.write_text("", encoding="utf-8")
        reproductions += 1
        proc = rec.run(["doctor"])
        line = next((ln for ln in proc.stdout.splitlines() if doctor_row["label"] in ln), "")
        if not line:
            findings.append(f"ws doctor printed no '{doctor_row['label']}' row. The drift the table "
                            f"above reports is exactly what doctor must not swallow.")
        else:
            if doctor_row["mark"] not in line:
                findings.append(f"ws doctor's drift row is not marked {doctor_row['mark']} while "
                                f"the recording is drifted: {line.strip()}")
            for fragment in doctor_row["contains"]:
                if fragment not in line:
                    findings.append(f"ws doctor's drift row is missing {fragment!r} — it must carry "
                                    f"the same counts and offenders as the table.\n      "
                                    f"row: {line.strip()}")
    return findings, reproductions


def load_fixture() -> tuple[dict, dict, dict]:
    data = yaml.safe_load(CLUSTER.read_text(encoding="utf-8"))
    calls = {key: value.replace("<TAB>", "\t") for key, value in data["calls"].items()}
    return calls, data["expect"], data["doctor_row"]


# ── entry points ──────────────────────────────────────────────────────────────────────────────

def scope_for_tree() -> Scope:
    """Floors for a real run. Measured 2026-08-01: 14 pinned contract invariants, 4 recorded-cluster
    reproductions (3 `--check` cases plus the ws doctor row)."""
    scope = Scope("rebuild-scan-guard")
    scope.require("pinned contract invariants", 12,
                  "the producer/consumer row-width pairings and the emptiness guards. Zero means "
                  "the contract half did not run — main() calls two independent halves and dropping "
                  "either one used to leave a clean exit 0.")
    scope.require("recorded-cluster reproductions", 4,
                  "every `--check` case in the recording plus the ws doctor row. Zero means the "
                  "behaviour half did not run; fewer means the recording was truncated.")
    return scope


def main(argv=None) -> int:
    # argparse, not `"--self-test" in sys.argv`. The membership test IGNORED every other argument:
    # `--selftest`, one hyphen short, ran the plain check and printed a clean result, so a maintainer
    # proving a detector fires proved nothing. argparse names the offending argument and exits 2 —
    # the same behaviour the six argparse-based guards beside this one already had, and the same
    # exit code tools/lint/_parse-guard-args.sh gives the shell guards.
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="run the canaries instead of the real tree; exits 1 when every canary was "
                         "correctly caught, which is the PASS for this mode")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    for path in (WS, CLUSTER, STUB):
        if not path.is_file():
            print(f"::error::rebuild-scan-guard: {path.relative_to(REPO)} is missing. Scanning "
                  f"nothing is not a pass.", file=sys.stderr)
            return 2
    calls, expect, doctor_row = load_fixture()
    ws_source = WS.read_text(encoding="utf-8")
    scope = scope_for_tree()
    contract, contract_units = contract_findings(ws_source)
    behaviour, behaviour_units = behaviour_findings(calls, expect, doctor_row, ws_source)
    scope.add("pinned contract invariants", contract_units)
    scope.add("recorded-cluster reproductions", behaviour_units)
    # Before reporting anything: did BOTH halves actually run? Dropping either one used to leave a
    # clean exit 0 (audit 2026-08-01).
    collapsed = scope.enforce()
    if collapsed:
        return collapsed
    findings = contract + behaviour
    if findings:
        print("::error::the image-drift scan behind `ws rebuild-images --check` and `ws doctor` no "
              "longer reports what the recorded cluster must produce. Its failure mode is a clean "
              "report, not an error, so treat a finding here as a wrong answer already shipping.",
              file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print(f"rebuild-scan-guard: clean — {scope.summary()} "
          f"({len(calls)} recorded oc calls).")
    return 0


# Each mutation is a defect expressed as the smallest edit that brings it back — MEASURED in this
# code where the comment says so, and otherwise the minimal edit that reintroduces exactly what one
# pinned invariant exists to forbid.
#
# THE KIND SELECTS WHICH HALF MUST CATCH IT, and that is the whole point of the vocabulary:
#   "ws"       — edits a copy of the script; proven by the BEHAVIOUR half alone.
#   "fixture"  — edits the recording; proven by the BEHAVIOUR half alone. This is how the two
#                cluster-shaped defects (a collapsed selector column, a service-wide ksvc pod match)
#                are expressed — they are properties of what `oc` returns, not of the shell.
#   "contract" — edits a copy of the script; proven by the CONTRACT half alone.
#
# Until 2026-08-01 every kind ran BOTH halves and a mutant counted as caught if EITHER fired. The
# two halves then masked each other wholesale: TEN of the fifteen pinned contract invariants could
# be neutered one at a time with `--self-test` still exiting 1 and the tree run still exiting 0,
# because a behaviour mutant that happened to trip the contract check (or vice versa) kept the
# suite green. `kind` read like a distinction the code made; it was documentation. Splitting the
# halves is what turns each pinned invariant into something a canary can actually fail on — and it
# is why every contract check below now has a mutant of its own rather than borrowing one.
MUTANTS = [
    ("digest-compare-disabled", "ws",
     'if [[ -n "$want" && "$d" != "$want" ]]; then stale=$((stale + 1)); fi',
     'if false; then stale=$((stale + 1)); fi',
     "nothing is ever stale — the blind-scan failure this whole gate exists for"),
    ("revisionUID-exclusion-removed", "ws",
     'case "$sel" in *serving.knative.dev/revisionUID*) continue ;; esac',
     ':',
     "each Knative Revision's own Deployment double-counts the ksvc"),
    ("image-ref-split-from-left", "ws",
     'rest="${ref%/*}"',
     'rest="${ref%%/*}"',
     "the registry's own :5000 is taken for a tag"),
    ("no-tag-state-lost", "ws",
     'state="no-tag"',
     'state="current"',
     "a workload pointing at a tag nobody built reports healthy"),
    ("scope-filter-dropped", "ws",
     'if [[ -n "$scope" && "$wl_owner" != "$scope" ]]; then continue; fi',
     ':',
     "--user reports the whole cluster"),
    ("cronjob-selector-placeholder-dropped", "fixture",
     "CronJob<TAB>user1-dev<TAB>claims-nightly<TAB>-<TAB>report",
     "CronJob<TAB>user1-dev<TAB>claims-nightly<TAB><TAB>report",
     "the empty selector column collapses and the CronJob leaves the scan"),
    ("knative-service-wide-selector", "fixture",
     "serving.knative.dev/revision in (parasol-claims-v2)",
     "serving.knative.dev/service=parasol-claims",
     "the retired Revision's still-Running pod reports a rolled ksvc as stale"),
    # Not a defect that shipped — the gap 6138e8c named and left open, and the most likely way this
    # change gets undone: the scan stays correct and `ws doctor` simply stops asking it.
    ("doctor-row-unwired", "ws",
     "IFS=$'\\t' read -r d_total d_stale d_bad d_names",
     "d_total=0 d_stale=0 d_bad=0 d_names=- IFS=$'\\t' read -r _ignored",
     "ws doctor stops consuming the scan and silently reports no drift"),
    ("empty-selector-placeholder-removed", "contract",
     '{{if not $s}}{{$s = "-"}}{{end}}',
     '',
     "the go-template stops emitting the placeholder — invisible to the recording, "
     "which is why the contract half checks it directly"),
    ("module-default-removed", "contract",
     '"${module:--}"',
     '"${module}"',
     "an unlabelled ksvc emits an empty middle field"),
    # ── one mutant per behaviour-half check that nothing isolated ─────────────────────────────
    # Added 2026-08-01, same audit. The behaviour half asks six separate questions of the recorded
    # cluster and every mutant above trips several at once, so five of the six could be neutered
    # one at a time with both CI signals green. Each mutant below changes EXACTLY ONE of them: the
    # `--check` exit status without the rows, the doctor row's label without its contents, its mark
    # without its text, one fragment of its text, and the modelled-call ledger without anything
    # visible at all.
    ("container-column-misreported", "ws",
     '"$kind" "$ns" "$name" "$cname" "$wl_owner" "${module:--}"',
     '"$kind" "$ns" "$name" "$name" "$wl_owner" "${module:--}"',
     "the CONTAINER column reports the workload's name instead of the container's. Nothing about "
     "the verdict changes — same states, same counts, same exit status, same doctor row — so this "
     "is the only shape that reaches the row comparison and nothing else. `oc rollout restart` "
     "takes a workload, but the SA reading the table to find which container is off-digest is "
     "given a name that is not in the pod"),
    ("check-exit-status-lost", "ws",
     '      echo "   roll them:  ws rebuild-images --no-build ${hint_scope}'
     '${filter:+ --image ${filter}}"\n      rebuild_end; trap - EXIT\n      return 1',
     '      echo "   roll them:  ws rebuild-images --no-build ${hint_scope}'
     '${filter:+ --image ${filter}}"\n      rebuild_end; trap - EXIT\n      return 0',
     "`--check` prints the drift and exits 0. ws doctor and CI consume that status as a pass/fail, "
     "so a drifted cluster reports healthy while the table on screen says otherwise"),
    ("doctor-row-label-renamed", "ws",
     'printf "  %-28s" "running image drift"',
     'printf "  %-28s" "image drift"',
     "the doctor row is still computed and still printed, under a label nothing looks for — which "
     "is how a row silently stops being the thing anyone greps for"),
    # `nok`, not `err`: the doctor report's failing rows moved to stdout so a row's label and its
    # status can no longer be split across fds (SEV3-I). These mutants must track that wording — a
    # mutant that no longer matches the source is a no-op, and a no-op mutant proves nothing.
    ("doctor-row-mark-softened", "ws",
     'nok "${d_what}: ${d_names} — detail: ws rebuild-images --check${d_fix}"; fail=1',
     'ok "${d_what}: ${d_names} — detail: ws rebuild-images --check${d_fix}"',
     "the drift row reports ✅ with the drift spelled out beside it, and ws doctor stops failing"),
    ("doctor-row-offenders-dropped", "ws",
     'nok "${d_what}: ${d_names} — detail: ws rebuild-images --check${d_fix}"; fail=1',
     'nok "${d_what} — detail: ws rebuild-images --check${d_fix}"; fail=1',
     "the row keeps its mark and its counts but stops naming WHICH consumers drifted, so the "
     "reader is told a number and given nowhere to go"),
    ("unmodelled-oc-call-introduced", "ws",
     'IFS=$\'\\t\' read -r src_ns src_name reftype refval <<< "$parts"',
     'oc get clusterversion version >/dev/null 2>&1 || true\n    '
     'IFS=$\'\\t\' read -r src_ns src_name reftype refval <<< "$parts"',
     "the read-only path asks the cluster something the recording does not model. Every read in "
     "the scan is written `|| true`, so the answer is silently empty and part of the report comes "
     "from no data at all — the one defect shape that leaves the table and the exit status intact"),
    # ── one mutant per remaining pinned contract invariant ───────────────────────────────────
    # Added 2026-08-01. Each of these checks existed and each could be neutered with both CI
    # signals green, because the behaviour half caught whichever mutant happened to trip it. They
    # are the smallest edit that breaks exactly one producer/consumer pairing: a width, a reader,
    # or an emptiness default. None of them is a defect that shipped — they are the shapes these
    # invariants were written to forbid, which is the only thing a canary for them can be.
    ("scan-row-width-shrunk", "contract",
     "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t0\\t0\\tpinned\\n' \\",
     "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t0\\t0\\tpinned\\n' \\",
     "the digest-pinned early return emits one field fewer than the normal path, so every reader "
     "binds the tail of that row one column to the left"),
    ("consumer-row-reader-unwired", "contract",
     "read -r kind ns name cname owner module src want running stale state; do",
     "read -r knd ns name cname owner module src want running stale state; do",
     "a consumer stops reading a rebuild_scan row at all — the pairing goes stale in silence"),
    ("consumer-row-reader-short", "contract",
     "read -r kind ns name cname owner module src want running stale state; do",
     "read -r kind ns name cname owner module src want running stale; do",
     "a consumer binds one name fewer than the row emits; the surplus field is swallowed"),
    ("enumerate-reader-unwired", "contract",
     "while IFS=$'\\t' read -r kind ns name sel cname image; do",
     "while IFS=$'\\t' read -r kind ns name selector cname image; do",
     "rebuild_scan stops reading rebuild_enumerate's rows under the pinned names"),
    ("enumerate-template-width-shrunk", "contract",
     '{{$k}}{{"\\t"}}{{$ns}}{{"\\t"}}{{$n}}{{"\\t"}}{{$s}}{{"\\t"}}{{.name}}{{"\\t"}}{{.image}}'
     '{{"\\n"}}',
     '{{$k}}{{"\\t"}}{{$ns}}{{"\\t"}}{{$n}}{{"\\t"}}{{$s}}{{"\\t"}}{{.image}}{{"\\n"}}',
     "the workload go-template drops the container-name column while the reader still binds six"),
    ("row-summary-width-grown", "contract",
     "printf '%s\\t%s\\t%s\\t%s\\n'",
     "printf '%s\\t%s\\t%s\\t%s\\t%s\\n'",
     "rebuild_row_summary emits a fifth field ws doctor never reads"),
    ("doctor-row-reader-unwired", "contract",
     "IFS=$'\\t' read -r d_total d_stale d_bad d_names < <(rebuild_row_summary",
     "IFS=$'\\t' read -r doctor_total d_stale d_bad d_names < <(rebuild_row_summary",
     "cmd_doctor stops consuming rebuild_row_summary under the pinned names"),
    ("doctor-row-reader-short", "contract",
     "IFS=$'\\t' read -r d_total d_stale d_bad d_names < <(rebuild_row_summary",
     "IFS=$'\\t' read -r d_total d_stale d_bad < <(rebuild_row_summary",
     "ws doctor binds three of the four summary fields and drops the offender names"),
    ("image-parts-width-shrunk", "contract",
     "printf '%s\\t%s\\ttag\\tlatest\\n'",
     "printf '%s\\t%s\\tlatest\\n'",
     "the bare-reference branch of rebuild_image_parts emits 3 fields where the other two emit 4"),
    ("image-parts-reader-short", "contract",
     "read -r src_ns src_name reftype refval",
     "read -r src_ns src_name reftype",
     "rebuild_scan binds three of rebuild_image_parts' four fields, losing the tag"),
    ("ksvc-selector-init-dropped", "contract",
     '{{$sel := printf "serving.knative.dev/service=%s" $n}}',
     '{{$sel := ""}}',
     "a ksvc with no .status.traffic emits an empty selector column and collapses its row"),
    ("row-summary-names-default-removed", "contract",
     '"${names:--}"',
     '"${names}"',
     "with no offenders the field is empty and ws doctor prints whatever that variable held before"),
    ("revisionUID-case-removed-contract", "contract",
     'case "$sel" in *serving.knative.dev/revisionUID*) continue ;; esac',
     ':',
     "the same edit as the behaviour mutant above, pinned HERE because the contract check used to "
     "be satisfied by the explanatory comment beside the case statement rather than by the case "
     "statement itself"),
]


def self_test() -> int:
    """Reintroduce each measured defect and require the suite to catch it. Exit 1 = all caught."""
    for path in (WS, CLUSTER, STUB):
        if not path.is_file():
            print(f"::error::rebuild-scan-guard self-test: {path.relative_to(REPO)} is missing.",
                  file=sys.stderr)
            return 2
    ws_source = WS.read_text(encoding="utf-8")
    raw = CLUSTER.read_text(encoding="utf-8")
    failures: list[str] = []

    def suite(source: str, fixture_text: str, half: str = "both") -> list[str]:
        """The gate against a given script text and recording.

        `half` is what makes each mutant prove something specific. "both" is the control's mode —
        the unmutated tree has to pass everything. A mutant runs ONE half, so a defect in the
        contract pairings cannot be signed off by the behaviour reproduction noticing it (or the
        reverse); that mutual masking is what hid ten neuterable contract checks until 2026-08-01.
        Running one half is also what makes thirteen extra contract mutants affordable: they never
        spawn the recorded-cluster subprocesses.
        """
        findings = []
        if half in ("both", "contract"):
            findings += contract_findings(source)[0]
        if half in ("both", "behaviour"):
            data = yaml.safe_load(fixture_text)
            calls = {k: v.replace("<TAB>", "\t") for k, v in data["calls"].items()}
            findings += behaviour_findings(calls, data["expect"], data["doctor_row"], source)[0]
        return findings

    # kind -> the half that must catch it, on its own.
    HALF_FOR_KIND = {"contract": "contract", "ws": "behaviour", "fixture": "behaviour"}

    # Control. A suite that fails on the real thing proves nothing about the mutants.
    control = suite(ws_source, raw)
    if control:
        failures.append("the UNMUTATED tree does not pass its own suite, so nothing below means "
                        "anything:\n      " + "\n      ".join(control))

    for name, kind, old, new, why in MUTANTS:
        half = HALF_FOR_KIND.get(kind)
        if half is None:
            failures.append(f"mutant {name} declares kind {kind!r}, which names no half. A mutant "
                            f"whose kind the runner does not understand proves nothing.")
            continue
        if kind == "fixture":
            if old not in raw:
                failures.append(f"mutant {name}: the recording no longer contains {old!r}, so this "
                                f"mutation is a no-op and proves nothing.")
                continue
            found = suite(ws_source, raw.replace(old, new, 1), half)
        else:
            if ws_source.count(old) < 1:
                failures.append(f"mutant {name}: tools/ws/ws no longer contains {old!r}, so this "
                                f"mutation is a no-op and proves nothing. The code was reworded — "
                                f"re-express the defect, do not delete the mutant.")
                continue
            found = suite(ws_source.replace(old, new), raw, half)
        if not found:
            failures.append(f"mutant {name} was NOT caught by the {half} half ({why}). That half "
                            f"passes with the defect present, so a clean result on the real tree "
                            f"means nothing. Do not widen the mutant to the other half — the point "
                            f"of the split is that each half proves its own invariants.")

    # Both halves must report having done work on the UNMUTATED tree, and their floors must be
    # meetable. A mutation suite proves the halves DETECT; only these counts prove they RAN.
    _, contract_units = contract_findings(ws_source)
    data = yaml.safe_load(raw)
    _, behaviour_units = behaviour_findings(
        {k: v.replace("<TAB>", "\t") for k, v in data["calls"].items()},
        data["expect"], data["doctor_row"], ws_source)
    tree_scope = scope_for_tree()
    for dimension, actual in (("pinned contract invariants", contract_units),
                              ("recorded-cluster reproductions", behaviour_units)):
        floor = tree_scope.floor_for(dimension)
        if actual < floor:
            failures.append(f"the unmutated tree reports {actual} {dimension} but the real run's "
                            f"floor is {floor}, so a clean CI run is impossible — the floor and the "
                            f"code have diverged.")
    failures += Scope.self_check()

    if failures:
        for failure in failures:
            print(f"::error::rebuild-scan-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2
    print(f"self-test ok — the unmutated tree passes its own suite, and all {len(MUTANTS)} "
          f"reintroduced defects are detected: " + ", ".join(name for name, *_ in MUTANTS) + ".")
    return 1


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
        print(f"::error::rebuild-scan-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and "
              f"never 'canary detected'.", file=sys.stderr)
        sys.exit(2)
