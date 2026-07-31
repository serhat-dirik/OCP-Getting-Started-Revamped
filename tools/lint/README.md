# tools/lint/

This directory holds the guards CI runs in `.github/workflows/lint.yml` (24 jobs as of
2026-08-01 — verify with `grep -cE '^  [a-z][a-z-]*:$' .github/workflows/lint.yml` before quoting
a number, it has grown every week). Two more checks — `vale` and `yamllint` — are **not** CI jobs;
they run locally on maintainer machines only (see the comment above the `shellcheck:` job).

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
  `_check-coverage.sh`, `_extract-func.sh`, `_scope.py`. These are libraries other guards source or
  import — nothing in CI invokes them as a job by name, but running them standalone (see below)
  proves the library itself still works, which is why each one is also runnable directly.

Guards come in two shapes, because the repo has both Python and Bash checks and each language grew
its own convention independently. Pick whichever matches the guard you're closest to; don't force
one shape into the other file type.

## How to write a new guard

### Bash shape: `check_*()` + `run_check()`

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/_extract-func.sh"     # if you need to drive a real function
source "$(dirname "${BASH_SOURCE[0]}")/_check-coverage.sh"

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

### Run BOTH modes — this is not optional, and it really happened

A guard whose real-run invocation **crashes** (a typo, an unhandled exception, a path that doesn't
exist in CI) exits with a non-zero code. If your CI step only checks `--self-test`'s exit code,
that crash is invisible: `--self-test` runs a completely separate code path (it scans a small local
canary, not the real tree) and can still correctly exit 1 while the real run silently fails to
scan anything. This is not hypothetical caution — it happened for real the night of 2026-08-01, and
is exactly why every guard's CI job runs `--self-test` **and then** the real invocation, checking
both exit codes.

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

## A guard's docstring/header is not optional reading

Every guard here was written to close a specific gap that shipped and was only caught later — the
docstring says what the gap was, on what date, and in which file, precisely so the next person
touching the guard doesn't "simplify" away the exact behavior the incident requires. When editing
a guard, read its header first; when writing a new one, write the header first — it is the design
review, not a decoration.
