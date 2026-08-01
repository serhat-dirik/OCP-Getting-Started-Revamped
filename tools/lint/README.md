# tools/lint/

This directory holds the guards CI runs in `.github/workflows/lint.yml`. Don't hardcode that job
count anywhere, including here — it has already gone stale six times elsewhere in this repo and
will be wrong again by the time you read this. Count it yourself:
`grep -cE '^  [a-z][a-z-]*:$' .github/workflows/lint.yml` (matches the file's `jobs:` keys — 2-space
indented, lowercase-with-hyphens, colon at end of line). Two more checks — `vale` and `yamllint` —
are **not** CI jobs; they run locally on maintainer machines only (see the comment above the
`shellcheck:` job).

A guard exists because something shipped broken and review didn't catch it. Read a guard's header
before touching it — it names the real incident, and the incident is the spec.

## What's in here

- **Guards** — one file per check, named `<thing>-guard.py` or `<thing>-guard.sh`, each pairing a
  detector with a fixture that proves the detector fires (and, for several, that its exemptions
  correctly stay silent). Most also ship a canary fixture alongside them:
  `<name>-guard.canary.adoc` / `.canary.txt`, or a `<name>-guard.canary/` directory for guards that
  need multiple files to construct a realistic scenario (`copy-drift-guard.canary/`,
  `image-pull-policy-guard.canary/`, `rebuild-scan-fixtures/`).
- **Shared infrastructure**, prefixed `_` so they sort together and read as "not a guard":
  `_check-coverage.sh`, `_extract-func.sh`, `_parse-guard-args.sh`, `_scope.py`. These are libraries
  other guards source or import — running them standalone (see below) proves the library itself
  still works, which is why each one is also runnable directly.
- **`_canary-coverage.py`** — the one `_`-prefixed file that is not a library but a **guard about
  the guards**: it blinds each Python guard's detectors one at a time and requires an exit code to
  change. Its fixtures live in `_canary-coverage.canary/` and are themselves tiny fake guards with
  known answers. See "Proving a detector is load-bearing" below; it is the thing that stops a
  guard's own green tick from meaning less than it looks like.

Guards come in two shapes, because the repo has both Python and Bash checks and each language grew
its own convention independently. Pick whichever matches the guard you're closest to; don't force
one shape into the other file type.

## How to write a new guard

### Bash shape: `check_*()` + `run_check()`

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/_extract-func.sh"     # if you need to drive a real function
source "$(dirname "${BASH_SOURCE[0]}")/_check-coverage.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_parse-guard-args.sh" # ALWAYS — see "arguments" below

check_something() {   # <args> → 0 clean, 1 finding, 2 could not inspect
  ran_check            # FIRST statement — see "why check_* must be named that way" below
  ...
}

run_check() {
  coverage_reset
  local rc=0
  check_something ... || rc=$?
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}
```

Then wire a `--self-test` path (a fixture the detector must fire on, run through the same
`check_*` functions — never a reimplementation) and a real-run path (`run_check` against the real
tree), and add a CI job (see "Wiring into CI" below). `operatorgroup-uniqueness-guard.sh` is a good
compact worked example of this whole shape.

### Arguments: never hand-roll the check

Dispatch on `parse_guard_args`, never on a bare comparison:

```bash
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then self_test; exit $?; fi
run_check "$REPO_ROOT"; exit $?
```

The shape it replaces — `if [[ "${1:-}" == "--self-test" ]]` — discarded every other argument in
silence, so `--selftest` (one hyphen short) ran the PLAIN check and printed a green tick. A
maintainer who typos the flag believes they just proved detection; they proved nothing, because the
plain check passes on a healthy tree by definition. CI's exit-exactly-1 assertion catches that; a
laptop does not, and the laptop is where guards get run to justify a change. `parse_guard_args`
names the offending argument and exits **2** (this tree's "could not inspect what it claims to
inspect" code — never 1, which would satisfy CI's self-test assertion and re-open the hole).

A guard needing more flags writes its own `while … case` parser that also rejects unknown arguments
by name (`adoption-skippable-guard.sh` is the worked example) and adds itself to `_PGA_EXEMPT` in
`_parse-guard-args.sh` with a reason. `bash tools/lint/_parse-guard-args.sh` meta-scans the
directory and fails on any `.sh` that is neither wired nor exempt, so adoption cannot rot.

Python guards get the same contract from `argparse` (`ap.parse_args()` names the offender and exits
2 already) — use it, not `"--self-test" in sys.argv`, which has the identical silent-discard bug.

### Python shape: `find_offenders()` + a canary with per-section assertions

```python
def find_offenders(path):   # → yields (line_no, rule, message)
    ...

RULES = (RULE_ONE, RULE_TWO)   # every rule name your detector can emit

def self_test():
    # scan a canary fixture, assert each of its sections independently, and prove each named
    # regex is load-bearing by mutating it (never-match / always-match) and requiring the
    # section's outcome to flip. See credential-redaction-guard.py's self_test() for the fullest
    # worked version of this — it is the reference implementation, not just an example.
```

`credential-redaction-guard.py`'s canary marks each section with a one-line contract:

```
// EXPECT: <rule-name(s)|none> | <blind|flood|-> <PATTERN_NAME> — why
```

`blind` swaps the named pattern for one that matches nothing, `flood` swaps it for one that
matches everything; either way the section's outcome (fires / stays silent) must flip, or the
self-test fails with "section not testing what it claims to." Other Python guards invent their own
canary marker syntax (`curl-format-guard.canary.adoc` marks expectations per LINE, not per
section) — the syntax varies, the contract does not: **every canary section/line must declare what
it proves, and mutating the thing it names must change the outcome.** A canary that only asserts
"something fired" proves nothing (see "run BOTH modes," below, for why that bit us for real).

### The naming rule that is load-bearing, not stylistic

**A Bash detector MUST be named `check_*`.** `_check-coverage.sh`'s coverage assertion derives its
expectation from `declare -F | grep -E '^check_'` — not from a hand-maintained list, and not from
`run_check()`'s own source, because that is the one place a deleted call site cannot also edit the
expectation. A detector under any other name is invisible to the assertion that exists
specifically to catch a dropped call site. Name it wrong and it is not "still checked, just not
tracked" — it is a silent hole, indistinguishable from clean.

### Scope floors (Python guards): `_scope.py`

A guard whose detectors all work and are all wired can still be broken in a third way: the code
deciding **what to scan** can silently narrow or empty the input set while the guard still prints
"clean." Declare floors for every dimension your guard measures, and — the one rule that makes
this work — **feed `Scope.add()` a count produced BY the code path being proven, never recomputed
beside it**. A count taken from `len(charts)` after discovery ran proves discovery ran; a count
recomputed independently in `main()` proves nothing, because it can stay correct even after the
real discovery breaks.

```python
from _scope import Scope

scope = Scope("my-guard")
scope.require("files scanned", 90, "the repo has this many candidate files; a smaller number "
                                    "means discovery broke, not that files were deleted")
...
scope.add("files scanned", len(files))     # len(files) IS what the scan produced, not a guess
rc = scope.enforce()
if rc:
    return rc
```

Pick a floor **below today's real measurement** (so ordinary repo growth doesn't redden main) and
**far above any plausible truncation** (a `[:1]` slice, an empty list). Where the scanned set is
something the guard itself declares (a fixed list of sites, a fixed list of file pairs), the floor
is that declared count exactly — shrinking a declared list is an editorial act that should update
its own floor at the same time.

### `_extract-func.sh`: driving a real function instead of reimplementing it

Several guards need to exercise a function that lives in a real, imperative script
(`bootstrap/install.sh`, `bootstrap/ogsr-uninstall.sh`) without executing the whole script (which
would run a real install/uninstall). `extract_func <file> <name>` pulls just that function's text
out by static extraction — never by sourcing the target script. `extract_func_indented` is the same
walker for a function embedded inside a YAML block scalar with a fixed indent (its only caller is
`uninstall-state-lifetime-guard.sh`, reading `helm/bootstrap/templates/job-state-capture.yaml`).
Six guards used to carry their own hand-copied version of this walker; five of them shared a bug
that swallowed every definition after a one-line function (`name() { ...; }` with no bare `}` line
to stop at) — this file replaces all of them.

## Wiring a guard into CI

Add a job to `.github/workflows/lint.yml` that runs **both** modes, in this order:

```yaml
- name: My new guard
  run: |
    rc=0
    python3 tools/lint/my-new-guard.py --self-test || rc=$?
    if [ "$rc" -ne 1 ]; then
      echo "::error::self-test must exit 1; got rc=$rc"
      exit 1
    fi
    python3 tools/lint/my-new-guard.py
```

### The exit-code convention (deliberately inverted from the usual shell meaning)

- `--self-test` **MUST exit exactly 1** when everything works: every canary correctly detected,
  every exemption correctly silent, every mutation correctly flipped its section. **0 means the
  guard is blind** (nothing fired). **2 means the harness itself is broken or unproven** — fixture
  missing, a scope floor breached, a section with no `EXPECT`, a rule or pattern no section covers.
  CI asserts `rc -eq 1`, not the usual "0 is success."
- A real run exits **0** clean, **1** findings-present, **2** "could not inspect what it claims to"
  (empty scope, scope floor breached, fixture missing). Treat 2 as worse than 1, not better —
  it means the guard has no evidence at all, not that it looked and found nothing.

#### Python guards: a CRASH must exit 2, and this is not optional

Python exits **1** on any uncaught exception. So without deliberate handling, a guard that fails to
compile a regex, cannot import `_scope`, or throws inside a detector exits with **the exact code CI
treats as "detection proven."** A completely broken guard and a working one were indistinguishable.
Measured on 2026-08-01: **ten of eleven** Python guards here had this, and one had already shipped
broken in-tree with a green tick beside it.

Every Python guard therefore installs, as its first statement after the imports:

```python
def _crash_exit_2(exc_type, exc, tb):
    traceback.print_exception(exc_type, exc, tb)
    os._exit(2)                      # os._exit, not sys.exit — an excepthook cannot raise
sys.excepthook = _crash_exit_2
```

plus a `try/except` around `__main__` and a `_compile(name, pattern)` helper that exits 2 on
`re.error`. All three are needed and none is redundant: **module-level code runs before `__main__`
exists**, so the wrapper alone misses a bad regex or a raising import; and the helper produces the
specific message (`LITERAL_RE is not a valid regex`) that a bare traceback does not. Guard the
`_scope` import with `except Exception`, **not `except ImportError`** — a `_scope.py` that fails to
*parse* raises `SyntaxError` and sails straight past an ImportError-only handler.

The shape is identical across all eleven files; copy it from any of them. A new guard written the
obvious way — `sys.exit(main())` — silently re-opens the hole, which is why `canary-coverage`
exists as a CI job rather than as advice in this file.

Bash guards are unaffected: a broken one exits 127 or 2, not 1.

### Run BOTH modes — this is not optional, and it really happened

A guard whose real-run invocation **crashes** (a typo, an unhandled exception, a path that doesn't
exist in CI) exits with a non-zero code. If your CI step only checks `--self-test`'s exit code,
that crash is invisible: `--self-test` runs a completely separate code path (it scans a small local
canary, not the real tree) and can still correctly exit 1 while the real run silently fails to
scan anything. This is not hypothetical caution — it happened for real the night of 2026-08-01, and
is exactly why every guard's CI job runs `--self-test` **and then** the real invocation, checking
both exit codes.

## Proving a detector is load-bearing: `_canary-coverage.py`

A guard's own CI job asserts that **something** fired. It cannot assert that **each** detector is
individually load-bearing, and on 2026-08-01 an audit showed how far apart those two claims are: of
21 detectors in `rebuild-scan-guard.py`, **15 could be blinded with `--self-test` still exiting 1
and the real run still exiting 0**. Its two halves counted a mutant caught if *either* fired, so
each half was signing off the other's regressions. The same night turned up a `self_test()` that
re-implemented the pipeline and never called the function the real run uses, two finding kinds
masking each other, and a documented predicate that nothing called at all. Every one of those
guards was green in `lint.yml` the whole time.

The technique that found them is one sentence: **blind ONE detector, re-run BOTH modes, and require
an exit code to change.** `_canary-coverage.py` is that sentence as a CI job (`canary-coverage`).

```sh
python3 tools/lint/_canary-coverage.py --self-test          # must exit 1
python3 tools/lint/_canary-coverage.py                      # budget mode: what CI runs
python3 tools/lint/_canary-coverage.py --all                # sweep everything, ignore the budget
python3 tools/lint/_canary-coverage.py --guard copy-drift-guard.py   # one guard, while you edit it
```

**What it counts as a detector**, all three restricted to the real-run call graph (reachable from
`main()` without going through `self_test()`, and never inside an `if args.self_test:` branch —
blinding a harness assertion cannot move an exit code, so counting one would report every guard as
holed):

| kind | what it is | how it is blinded |
| --- | --- | --- |
| `pattern:NAME` | a module-level `re.Pattern` the real run reads | swapped for one that matches nothing |
| `predicate:NAME` | a module-level `-> bool` function the real run reads | forced to `False`, then to `True` — a predicate that survives *both* is the dead-code shape |
| `emit:FUNC:HASH` | a finding-emission site: `.append`/`.extend` onto an outcome-deciding `[]` local, a `yield`, or a call to a class's one-line recorder method (`self._record(…)`) | replaced by a no-op |

`HASH` is a hash of the statement text, not a line number, so a ledger entry naming it survives
everything moving down a few lines and expires exactly when the statement itself changes.

**If your new detector comes out UNPROVEN, the fix is a witness, not a ledger entry.** Write the
canary case only that detector can catch — or, for the ones that *enable* detection rather than
trigger it (blinding them makes the guard quieter, so no safe case can ever witness them), the case
that must stay silent and only stays silent because of them. That is what the five click-to-run
patterns and `curl-format`'s `INTRINSIC_ATTRIBUTES` needed.

**Two ledgers, for the two things a witness can't be written for.** Both are still swept, and both
error in *two* directions — when the key stops enumerating, and when the detector becomes proven —
which is the `_PGA_EXEMPT` shape and the only reason a list like this doesn't rot:

- `EXEMPT` — "this detector **cannot** be witnessed by either mode, and here is the structural
  reason." Empty today.
- `KNOWN_UNPROVEN` — "this detector **can** be witnessed and isn't — yet." Debt, with the witness
  spelled out in the entry. **It may shrink, never grow**: a new unproven detector fails CI, and an
  entry that acquires a witness fails CI too, so paying the debt is the only way to stop hearing
  about it.

**Runtime — why the default is a budget and not `--all`.** Measured on this tree: nine of the ten
Python guards cost under 5s for both baseline modes, so their full sweep is ~2 minutes wall at
`-j4`. `rebuild-scan-guard.py` costs ~75s per detector (its `--self-test` runs 21 internal mutants,
several spawning `bash tools/ws/ws`) across 24 detectors — 360-470s even at `-j8`, half an hour serial. So a guard is
swept when the diff **touched** it (always, budget ignored) or when its projected cost fits
`--budget` (default 240s). Nothing hardcodes which guard is the slow one; a guard that gets slow
drops out on its own and rejoins when it gets fast. The consequence worth knowing: an expensive
guard's detectors are re-proven **when it or its fixtures change**, not on every push.

**Exit codes.** `--self-test` exits 1 (it correctly classified fixture guards with known answers,
including a deliberately unwitnessable detector); the real run exits 0 clean, **1** for an unproven
detector or a rotten ledger entry, **2** for could-not-inspect — a guard that will not import, an
unmutated control that is not 0/1, a mutation that failed to land, zero guards selected, zero
detectors enumerated. 1 and 2 are deliberately different codes: the first is a finding about a
guard, the second is a finding about the sweep, and a guard that fails to import must never read as
a guard with a hole.

**It does not cover the Bash guards.** They have no module-level attribute to patch;
`_check-coverage.sh` asserts every `check_*` **ran**, which is strictly weaker than "its finding
could not be silenced". Read the `canary-coverage` tick as a claim about the Python guards only.

## Local reproduction

- **podman**: the machine auto-stops between sessions; "connection refused" from a linter means
  restart it (`podman machine start`) and re-run — never read an unrun gate as a passing one.
- **shellcheck version must match CI's**, not just its name. CI installs shellcheck via
  `apt-get install shellcheck` on `ubuntu-latest`, which is **0.9.x**. The convenient local image
  `koalaman/shellcheck:stable` is **0.11.x** and reports a genuinely different finding set — an
  unused-function finding is `SC2329` on shellcheck ≥0.10 but `SC2317` on 0.9.x, so a
  `# shellcheck disable=SC2329` comment silences nothing on CI (name both codes if you need to
  suppress a real 0.9.x/0.11.x split). Pin the version explicitly to reproduce CI locally:
  `podman run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.9.0 /mnt/tools/lint/my-new-guard.sh`.
- **`yamllint` needs an ignore entry that is NOT in the repo, and nothing else will tell you.**
  `.yamllint.yaml` is gitignored (`.gitignore:56`, removed from the tree deliberately), so it exists
  only on each maintainer's machine. Several guards here ship **Helm-template** canary fixtures whose
  `templates/` directories are unparseable YAML by design (`{{ … }}` where a value belongs), and a
  local `yamllint .` fails on them unless your config ignores those paths.

  **Derive the list rather than trusting one written here** — the paths are not all the same shape
  (two are `<guard>.canary/chart/templates/`, one is `<guard>.canary/templates/`), and I got that
  wrong the first time I wrote it down:

  ```sh
  git ls-files 'tools/lint/**/*.yaml' | xargs grep -l '{{' | xargs -n1 dirname | sort -u
  ```

  Put each result under `ignore:` in your `.yamllint.yaml`. CI is unaffected — `yamllint` is not a
  CI job (see the top of this file) — so this bites only the person running the linter locally to
  convince themselves a change is safe, which is the worst possible audience for a spurious failure.
  **If you add a guard with a Helm-template fixture, re-run that command**, because the config file
  it belongs in cannot be committed to say it for you.

## A guard's docstring/header is not optional reading

Every guard here was written to close a specific gap that shipped and was only caught later — the
docstring says what the gap was, on what date, and in which file, precisely so the next person
touching the guard doesn't "simplify" away the exact behavior the incident requires. When editing
a guard, read its header first; when writing a new one, write the header first — it is the design
review, not a decoration.
