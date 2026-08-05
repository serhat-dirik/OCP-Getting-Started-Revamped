# Declared-debt ledgers — the one convention

A **declared-debt ledger** is a list inside a gate that turns a specific, named failure into
*accepted debt*: the gate keeps detecting it, keeps reporting it, and stops failing on it.

This repo has three, invented independently within a week of each other, each with a different entry
format and a different staleness rule:

| ledger | file | landed |
|---|---|---|
| `EXEMPT` / `KNOWN_UNPROVEN` | `tools/lint/_canary-coverage.py` | 2026-08-01 |
| `_PGA_EXEMPT` | `tools/lint/_parse-guard-args.sh` | 2026-08-01 |
| `KNOWN_STRANDS` | `platform-portfolio/hack/check-adoption-skip.sh` | 2026-08-05 |

A fourth will be written eventually, and whoever writes it will copy whichever one they happened to
see. This file exists so that copy is the right one.

> **Line numbers below are as of 2026-08-06** and every citation also quotes the identifying code
> text — grep the quote if the line has moved. This is not a formality: adding the two-line pointer
> comment to `_canary-coverage.py` and `_parse-guard-args.sh` shifted every citation in those files
> by +3 while this page was being written. Re-derive before trusting the numbers in a review.

## Why a ledger needs a convention at all

The failure this repo keeps paying for is not "we accepted some debt". It is **a declaration that
outlives its defect**, which then reads as either an active alarm about something already fixed, or —
far worse — a false all-clear over something still broken. Three of the incidents already written
into these files are that shape:

* a `--selftest` typo printing a green tick over a check that never ran
  (`_parse-guard-args.sh:12-18`);
* `check-adoption-skip.sh` printing `✅ automatic component adoption is safe across the portfolio`
  over a live break (`check-adoption-skip.sh:30-32`);
* 15 of 21 detectors blindable in a guard that had been green in CI the whole time
  (`_canary-coverage.py:7-10`).

A ledger is the highest-leverage place for that failure to recur, because a ledger's *entire job* is
to suppress a red signal.

## The three-way comparison, measured

### 1. Entry format

| | format | evidence |
|---|---|---|
| `_canary-coverage.py` | `dict[str, str]`. Key `"<guard>.py::pattern:NAME"` / `"::predicate:NAME"` / `"::emit:FUNC:HASH"`; value is free text, **unvalidated**. Both dicts are empty today. | `:147` `EXEMPT: dict[str, str] = {}` · `:160` `KNOWN_UNPROVEN: dict[str, str] = {}` · key built at `:191-199` (`ident`/`key` properties) |
| `_parse-guard-args.sh` | One space-separated **string of basenames**. Reasons live in a comment above, coupled by position. | `:142` `_PGA_EXEMPT="adoption-skippable-guard.sh"` · `:133-137` `Reasons, one per entry, in the same order:` |
| `check-adoption-skip.sh` | `<component> <NS\|OG> <namespace> <sibling> :: <YYYY-MM-DD> \| <why> \| decision: <who defers it>` | `:97` (documented format) · `:110-115` `known_strands()` heredoc, two entries at `:112-113` |

### 2. What a match suppresses

| | suppresses | evidence |
|---|---|---|
| `_canary-coverage.py` `EXEMPT` | the "unproven detector" problem line; **no counter, no print** | `:859-860` `if det.key in EXEMPT: continue` vs the problem it skips at `:864-868` |
| `_canary-coverage.py` `KNOWN_UNPROVEN` | same, but counted | `:861-863` `debt += 1; continue` |
| `_parse-guard-args.sh` | the `UNPARSED` error that would set `rc=1` | `:179-180` `*" ${base} "*) exempt=$((exempt + 1)) ;;` vs `:182-185` |
| `check-adoption-skip.sh` | the `❌` and its `FAILURES` increment; emits `⚠ DECLARED` instead | `:149-155` `report_strand`, `warn` at `:154`; the unmatched path is `:157-161` → `bad()` at `:90` |

### 3. Is a declared item REPORTED, or does the run read as clean?

Measured by running each gate with an entry suppressing a real defect.

| | what a reader actually sees | verdict |
|---|---|---|
| `_canary-coverage.py` `EXEMPT` | **Nothing.** Output is `✅ … 1 detector(s) proven across 1 swept guard(s); every blinding moved an exit code.` — a sentence that is false for the exempted detector, which is never named. Only the table row's `1 UNPROVEN` hints at it (`:767`). | ❌ |
| `_canary-coverage.py` `KNOWN_UNPROVEN` | A bare count under that same `✅` line: `1 detector(s) carried as KNOWN_UNPROVEN debt`. No detector name, no reason. | ⚠ partial |
| `_parse-guard-args.sh` | A count on the green line itself: `✅ argument parsing: 16 guard(s)… 1 declared exemption(s)…` (`:195`). No name, no reason. | ⚠ partial |
| `check-adoption-skip.sh` | Per-strand `⚠ DECLARED … known, accepted, NOT fixed` (`:154`); a dedicated end block naming component/kind/namespace/sibling and printing the reason in full (`:549-560`); and the final green line **replaced** so it never claims blanket safety (`:564-569`). | ✅ |

`check-adoption-skip.sh:565-567` states the rule the other two miss, in its own words: a green line
claiming blanket safety over known-broken pairs is "the exact false reassurance property 3 was added
to kill."

### 4. Ratchet direction 1 — an UNDECLARED defect still fails

All three conform.

| | evidence |
|---|---|
| `_canary-coverage.py` | `:864-868` builds the problem, `:881-890` returns rc 1 |
| `_parse-guard-args.sh` | `:182-185` `UNPARSED: …` → `rc=1` |
| `check-adoption-skip.sh` | `:157-161` `bad` → `FAILURES` → `:575-576` `exit 1`; proven by canary D (`:284-301`) |

### 5. Ratchet direction 2 — a STALE entry fails

| | detected? | evidence |
|---|---|---|
| `_canary-coverage.py` | **Two sub-directions, with one blind spot.** Key no longer enumerates: `:809-812` + `:877-879`. Detector became PROVEN: `:869-876`. Blind spot: the staleness scan is filtered by `k.split("::", 1)[0] in selected` (`:812`), so a key whose **guard name is misspelled** is invisible forever — it is indistinguishable from a guard that simply was not selected on this run. | ⚠ partial |
| `_parse-guard-args.sh` | **One direction only.** An exempt file that starts using the parser fails (`:161-167` `STALE EXEMPTION: …`). An entry naming a file that **no longer exists** is never detected: `_pga_meta_scan` iterates `for f in "$dir"/*.sh` (`:150`) and never iterates the exemption list, so an entry with nothing to match is silently inert. | ⚠ partial |
| `check-adoption-skip.sh` | **Yes, fully.** `report_stale_declarations` (`:165-180`, called at `:542`) fails on any entry matching no strand this run observed, and names both causes — fixed, or no longer skippable (`:174-176`). | ✅ |

Measured, on the real code:

```
# _canary-coverage.py, same fixture, same run, one letter different in the guard name
well-formed STALE key (proven-guard.py::pattern:NOPE)      rc=1   <- caught
MALFORMED key: guard name misspelled (proven-gaurd.py::…)  rc=0   <- invisible

# _parse-guard-args.sh, the real script run standalone over two fixture directories
DIRECTION A: exempt file ABSENT from the directory   rc=0  ✅ … 0 declared exemption(s) …
DIRECTION B: exempt file NOW USES the shared parser  rc=1  ❌ STALE EXEMPTION: …
```

### 6. Are MALFORMED entries rejected, with an exit code distinct from "defect found"?

| | detected? | evidence |
|---|---|---|
| `_canary-coverage.py` | **One shape only.** A key present in both `EXEMPT` and `KNOWN_UNPROVEN` exits 2 (`:167-172`) — correctly distinct from rc 1. Nothing else is checked: a key with no `::` at all, a misspelled guard name, and an **empty reason string** are all accepted silently. | ⚠ partial |
| `_parse-guard-args.sh` | **No.** There is no format beyond "a filename", so there is nothing to violate; a typo'd name degrades into the undetected staleness case above. | ❌ |
| `check-adoption-skip.sh` | **Yes**, and it is the model. `ledger_lint()` (`:117-134`) is called before anything else (`:205-212`) and exits **2**, not 1 (`:211`), because "a ledger this script cannot parse silently declares nothing" (`:206-207`). It enforces the ` :: ` separator, exactly four key fields, `NS`/`OG`, a leading `YYYY-MM-DD`, and a non-empty `\| decision:` tail. | ✅ |

Measured — `_canary-coverage.py` over `unproven-guard.py`, whose `pattern:UNUSED_RE` is a real hole:

```
control: no entry — the real hole FAILS                        rc=1
entry with a full reason (date + why + decision)               rc=0
entry with reason = '' (no date, no why, no decision)          rc=0    <- silences it just as well
entry with reason = 'TODO'                                     rc=0
```

And the real `ledger_lint()`, driven through `_extract-func.sh` against fixtures:

```
well-formed (the shipped shape)     rc=0  <no problems>
missing the :: separator            rc=1  line 1: no " :: " separating the key from the reason
5 key fields, not 4                 rc=1  line 1: key must be exactly <component> <NS|OG> <namespace> <sibling>
kind is neither NS nor OG           rc=1  line 1: kind "XX" is neither NS nor OG
no leading YYYY-MM-DD date          rc=1  line 1: reason must start with a YYYY-MM-DD date
no | decision: pointer              rc=1  line 1: reason must end with "| decision: <...>"
empty decision pointer              rc=1  line 1: reason must end with "| decision: <...>"
```

### 7. Does the self-test prove the ledger's own behaviour?

| | covered by a canary | NOT covered |
|---|---|---|
| `_canary-coverage.py` | Five cases (`:1002-1013`), each against its own control run with the ledger empty first (`gate()`, `:988-1000`): stale `EXEMPT` key, stale `KNOWN_UNPROVEN` key, `EXEMPT`-now-proven, `KNOWN_UNPROVEN`-now-proven, and `KNOWN_UNPROVEN` converting a real hole from rc 1 to rc 0. | The malformed branch. No case puts a key in both ledgers, so `:167-172`'s rc 2 is never exercised. |
| `_parse-guard-args.sh` | Canaries F/G/H (`:285-318`): the meta-scan catches an unparsed guard, stays silent on a wired one, catches a half-conversion. | **The `STALE EXEMPTION` branch (`:161-167`) has no canary at all.** Worse, canary G (`:298-306`) *asserts rc 0* over a directory where the exempt file is absent — the self-test actively enshrines the undetected-staleness hole. |
| `check-adoption-skip.sh` | Canaries D/E/F (`:284-335`), which call the **real** `report_strand` / `report_stale_declarations` and measure their effect on the **real** `FAILURES` counter, restoring it afterwards (`:291-296`, `:309-312`, `:328-330`). F carries an over-fire control: one live entry that must stay quiet alongside the stale one that must fail. | `ledger_lint()` — one call site (`:205`), reached before `self_test()` runs (`:350`), and never driven against a malformed fixture. The linter works (measured above); nothing in the file proves it. |

`_canary-coverage.py:980-987` is worth reading before writing any of this: its ledger block's first
draft asserted rc 1 on a fixture that returned rc 1 anyway, so the assertion could not fail. That is
why every case here runs a control first.

### 8. Does CI assert the self-test's exact exit code?

All three conform.

| | evidence |
|---|---|
| `_canary-coverage.py` | `.github/workflows/lint.yml:1458-1465` — `if [ "$rc" -ne 1 ]` → fail; real run at `:1511` |
| `_parse-guard-args.sh` | `.github/workflows/lint.yml:1253-1262` |
| `check-adoption-skip.sh` | `.github/workflows/lint.yml:1178-1194` |

## The convention

Any new declared-debt ledger — and any change to an existing one — must satisfy all six.

### C1. Every entry carries a date, an owner-visible reason, and a pointer to the decision

Not a comment near the list: **fields of the entry itself**, machine-checkable. The reference shape
is `check-adoption-skip.sh:97`:

```
<key fields> :: <YYYY-MM-DD> | <why this is accepted> | decision: <who/what defers it>
```

The date says when it was accepted, so age is visible without archaeology. The reason is written for
the person who hits the ⚠ at 2am and has never seen the file. The decision pointer is what makes the
entry auditable: `decision: owner deferred functional RHBK coexistence …` (`:112`) names a call
someone made, not a mood someone was in.

A reason that lives only in a neighbouring comment fails this: `_parse-guard-args.sh:133-137` couples
reasons to entries *by position*, which survives exactly until someone adds a second entry.

### C2. A declared item is REPORTED as accepted debt — never rendered as safe or clean

Three things, all of them:

1. **Named at the point of detection** — `⚠ DECLARED …` with the specific item, not a total.
2. **A dedicated summary block** that reprints each declared item with its full reason, so a reader
   scanning for known debt finds it without reading the whole log
   (`check-adoption-skip.sh:549-560`).
3. **The success line must change.** Not `✅ adoption is safe across the portfolio`, but
   `✅ no NEW adoption break — every property holds except the N strand(s) declared above, which
   remain BROKEN by owner decision` (`:564-569`). A count buried in an otherwise unchanged green
   sentence does not clear this bar; neither does silence.

Exit 0 means "no *new* defect". It must never be printed as "no defect".

### C3. The two-directional ratchet

* **An undeclared defect fails.** The gate stays live for new breaks — the only reason a ledger is
  tolerable at all.
* **An entry matching no defect in this run fails**, and says to delete it. Both causes need naming:
  the defect was fixed, or the thing stopped being in scope
  (`check-adoption-skip.sh:174-176`).

Direction 2 is what stops the ledger becoming a stale doc with a green tick over it. It is the
requirement most easily lost: `_parse-guard-args.sh` has half of it, and `_canary-coverage.py` has
both halves with a blind spot where a mistyped key is filtered out before the staleness check runs.

**If your staleness scan iterates the observed defects, it must also iterate the ledger.** Every
entry has to be accounted for by name — otherwise an entry that matches nothing simply never comes
up, which is precisely how both partial implementations here lose direction 2.

### C4. Malformed entries fail loudly, with an exit code distinct from "defect found"

A ledger the gate cannot parse declares nothing, and a gate that silently declares nothing reports
accepted debt as a fresh break — or a fresh break as accepted debt. So:

* Lint the ledger **before** running the check (`check-adoption-skip.sh:205-212`).
* Exit **2**, never 1. In this tree 1 means "the thing I check is broken" and 2 means "I could not
  check what I claim to check"; a malformed ledger is the second. And 1 is load-bearing elsewhere:
  CI asserts `--self-test` exits exactly 1, so a malformed-ledger rc of 1 would satisfy that
  assertion (`_parse-guard-args.sh:44-47`).
* Validate every field C1 requires. An entry whose reason is `""` must not be accepted — as
  measured above, `_canary-coverage.py` accepts one and it suppresses a real hole just as
  effectively as a justified entry.
* **A key that matches nothing is malformed, not absent.** This is the failure mode C3's blind spots
  come from. If a key's shape can be validated statically (a guard filename that must exist, a
  component that must be in the portfolio), validate it.

### C5. The self-test proves all of the above, and CI asserts its exact exit code

Canaries, driving the **real** functions the real run calls — never a re-implementation — and each
with its own control:

| canary | asserts |
|---|---|
| undeclared defect | still reported, still counted toward the exit code (C3a) |
| declared defect | reported as ⚠ debt, contributes **zero** to the exit code (C2) |
| stale entry, alongside a live one | the stale entry fails; **the live one stays quiet** (C3b + its over-fire control) |
| malformed entry | rejected with rc 2, distinct from a defect's rc 1 (C4) |

The over-fire control is not optional. A staleness check that flags everything passes a one-sided
"the stale entry failed" assertion (`check-adoption-skip.sh:319-321`). Likewise, drive the real
counter and restore it (`:291-296`) rather than asserting about a copy: "a re-implementation of the
accounting could pass while the gate is broken" (`:220-222`).

CI runs the self-test first and asserts `rc -eq 1` exactly, then runs the real check — the shape at
`.github/workflows/lint.yml:1178-1194`. An unrun gate is worse than none.

### C6. Adding an entry is an OWNER decision, not an agent's

Writing an entry converts a red gate into accepted debt. That is a product decision about shipping a
known defect, and it belongs to the repo owner — never to a coding agent, and never to whoever
happens to be trying to get CI green.

An agent that finds a gate red has exactly three options: **fix the defect**, **fix the gate if the
gate is wrong**, or **report it and stop**. Adding a ledger entry is not one of them. If the entry is
genuinely the right answer, say so in the report, with the evidence, and let the owner decide.

This rule is already stated in two places and must be stated in every new ledger:
`check-adoption-skip.sh:67` and `:102-103`, and `platform-portfolio/README.md` § Adoption.

The corollary, from `tools/lint/README.md:272`: **if a new detector comes out unproven, the fix is a
witness, not a ledger entry.** Reach for a ledger only when the defect genuinely outlives the gate.

## Conformance today

`✅` conforms · `⚠` partial · `❌` does not

| requirement | `_canary-coverage.py` | `_parse-guard-args.sh` | `check-adoption-skip.sh` |
|---|---|---|---|
| **C1** date + reason + decision, as fields | ❌ value is free text; `""` accepted (`:147`, `:160`) | ❌ no reason field at all; reasons are positional comments (`:133-137`, `:142`) | ✅ enforced by `ledger_lint` (`:120-131`) |
| **C2a** named at detection | ⚠ `KNOWN_UNPROVEN` counted only; `EXEMPT` silent (`:859-863`) | ⚠ counted only (`:195`) | ✅ `warn` per strand (`:154`) |
| **C2b** summary block with reasons | ❌ none | ❌ none | ✅ `:549-560` |
| **C2c** success line changes | ❌ `✅ … every blinding moved an exit code` regardless (`:894-895`) | ❌ the count rides the green line (`:195`) | ✅ `:564-569` |
| **C3a** undeclared defect fails | ✅ `:864-868` → rc 1 | ✅ `:182-185` → rc 1 | ✅ `:157-161` → `exit 1` |
| **C3b** stale entry fails | ⚠ two sub-directions (`:809-812`+`:877-879`, `:869-876`), blind to a misspelled guard name (`:812`) | ⚠ only "exempt file adopted the parser" (`:161-167`); a vanished file is invisible (`:150`) | ✅ `:165-180`, called `:542` |
| **C4** malformed → distinct exit | ⚠ only both-ledgers → rc 2 (`:167-172`); no shape/date/reason validation | ❌ nothing to validate | ✅ `ledger_lint` → `exit 2` (`:117-134`, `:205-212`) |
| **C5** self-test proves it | ⚠ 5 cases with controls (`:1002-1013`); malformed branch uncovered | ⚠ F/G/H cover adoption (`:285-318`); the `STALE EXEMPTION` branch has **no canary**, and G asserts rc 0 over the blind spot | ⚠ D/E/F on real functions + real counter (`:284-335`); `ledger_lint` uncovered |
| **C5** CI asserts exact rc | ✅ `lint.yml:1458-1465` | ✅ `lint.yml:1253-1262` | ✅ `lint.yml:1178-1194` |
| **C6** owner rule stated in-file | ❌ "may shrink, never grow" (`:149-154`) is a ratchet rule, not an ownership rule | ❌ absent | ✅ `:67`, `:102-103` |

**Summary.** `check-adoption-skip.sh` is the reference implementation: copy `KNOWN_STRANDS`,
`ledger_lint()`, `report_strand()`, `report_stale_declarations()` and the D/E/F canaries.
`_canary-coverage.py` has the strongest *staleness* logic (it catches an entry that became true, which
the others have no analogue for) and the weakest *reporting* — an `EXEMPT` entry is entirely invisible
in the output. `_PGA_EXEMPT` is the weakest overall and the one most likely to be copied, because it
is the simplest-looking.

None of the three is fully conformant. That is a statement about the three files, not a licence: a
**new** ledger conforms on day one, and the gaps above are named so they can be closed deliberately
rather than propagated by imitation.

## Checklist for a new ledger

1. Entries are structured records with `<key fields> :: <date> | <why> | decision: <who>`.
2. A `*_lint()` runs before the check and exits **2** on any malformed entry, including a key that
   could never match.
3. An undeclared defect still fails; an entry matching nothing this run fails and says to delete it.
4. Declared items get named at detection, reprinted in a summary block, and change the success line.
5. Canaries drive the real functions and the real counter: undeclared-still-counts,
   declared-counts-zero, stale-fails-while-live-stays-quiet, malformed-exits-2.
6. The CI step asserts `--self-test` exits exactly 1 before running the real check.
7. The file says, in its own words, that adding an entry is an owner decision.
8. Add the ledger to the tables above, with evidence.

## Reproducing the measurements in this file

```bash
bash platform-portfolio/hack/check-adoption-skip.sh --self-test   # must exit 1
bash tools/lint/_parse-guard-args.sh --self-test                  # must exit 1
python3 tools/lint/_canary-coverage.py --self-test                # must exit 1
```

The probes behind sections 3, 5 and 6 drive the shipped code without editing it: the Python ledgers
via `importlib` + `run_gate(...)` with a dict entry injected and popped (the pattern
`_canary-coverage.py:988-1000` uses on itself); `ledger_lint()` via
`extract_func` from `tools/lint/_extract-func.sh`; and `_pga_meta_scan` by copying the unmodified
`_parse-guard-args.sh` into a fixture directory and running it there, since its standalone entry point
scans its own dirname (`:127`, `:343`).

## See also

* `tools/lint/README.md` § "Proving a detector is load-bearing" — the `EXEMPT`/`KNOWN_UNPROVEN` pair
  in context, and the exit-code convention every guard here follows.
* `platform-portfolio/README.md` § "Declared known strands" — `KNOWN_STRANDS` as a ratchet, with the
  three-row table of what each situation produces.
