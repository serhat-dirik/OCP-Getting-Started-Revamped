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

> **Line numbers below are as of 2026-08-06 (second revision)** and every citation also quotes the
> identifying code text — grep the quote if the line has moved. This is not a formality: adding the
> two-line pointer comment to `_canary-coverage.py` and `_parse-guard-args.sh` shifted every citation
> in those files by +3 while this page was first being written, and the fixes recorded below shifted
> them again — **non-uniformly**, by +13 to +106 in `_canary-coverage.py` and +14 to +31 in
> `_parse-guard-args.sh`. Do not offset the old numbers. Re-derive before trusting them in a review.

### Revision log

* **2026-08-06, first version.** Conformance measured at 13 ✅ / 17 non-✅ across 30 cells.
* **2026-08-06, reconciled (this revision).** Now 22 ✅ / 8 non-✅. Most of that gap closed within
  hours of the page shipping — a sibling change fixed both `tools/lint` ledgers — and the page went
  on describing holes that no longer existed. **A conformance table that silently rots is the exact
  failure this document was written to prevent**: a declaration outliving its defect, reading as an
  active alarm about something already fixed, which a reader then either distrusts wholesale or
  "fixes" a second time. Every §3–§8 cell and every C1–C6 row below was re-derived by driving the
  shipped code, not by editing the old table. What moved, what did not, and one row that was **wrong
  when written**, are listed in "What this revision changed" at the end.

## Why a ledger needs a convention at all

The failure this repo keeps paying for is not "we accepted some debt". It is **a declaration that
outlives its defect**, which then reads as either an active alarm about something already fixed, or —
far worse — a false all-clear over something still broken. Three of the incidents already written
into these files are that shape:

* a `--selftest` typo printing a green tick over a check that never ran
  (`_parse-guard-args.sh:12-18`);
* `check-adoption-skip.sh` printing `✅ automatic component adoption is safe across the portfolio`
  over a live break (`check-adoption-skip.sh:30-31`);
* 15 of 21 detectors blindable in a guard that had been green in CI the whole time
  (`_canary-coverage.py:8-10`).

A ledger is the highest-leverage place for that failure to recur, because a ledger's *entire job* is
to suppress a red signal. This page is itself in scope: see the revision log.

## The three-way comparison, measured

### 1. Entry format

| | format | evidence |
|---|---|---|
| `_canary-coverage.py` | `dict[str, str]`. Key `"<guard>.py::pattern:NAME"` / `"::predicate:NAME"` / `"::emit:FUNC:HASH"`; value is free text, validated **for non-emptiness only**. Both dicts are empty today. | `:160` `EXEMPT: dict[str, str] = {}` · `:173` `KNOWN_UNPROVEN: dict[str, str] = {}` · key built at `:250-257` (`ident`/`key` properties) · validation at `:188-232` `_ledger_problems()` |
| `_parse-guard-args.sh` | One space-separated **string of basenames**. Reasons live in a comment above, coupled by position. | `:156` `_PGA_EXEMPT="adoption-skippable-guard.sh"` · `:137` `Reasons, one per entry, in the same order:` |
| `check-adoption-skip.sh` | `<component> <NS\|OG> <namespace> <sibling> :: <YYYY-MM-DD> \| <why> \| decision: <who defers it>` | `:97` (documented format) · `:110-116` `known_strands()` heredoc, two entries at `:112-113` |

### 2. What a match suppresses

| | suppresses | evidence |
|---|---|---|
| `_canary-coverage.py` `EXEMPT` | the "unproven detector" problem line; emits `⚠ DECLARED EXEMPT` instead | `:937-943` `declared.append(...)` + the `⚠ DECLARED` print, vs the problem it skips at `:944-949` |
| `_canary-coverage.py` `KNOWN_UNPROVEN` | identical mechanics, different claim — the two ledgers differ only in what the entry asserts | same `:937-943` loop, which iterates both |
| `_parse-guard-args.sh` | the `UNPARSED` error that would set `rc=1` | `:198-199` `*" ${base} "*) exempt=$((exempt + 1)) ;;` vs `:200-205` |
| `check-adoption-skip.sh` | the `❌` and its `FAILURES` increment; emits `⚠ DECLARED` instead | `:144-156` `report_strand`, `warn` at `:154`; the unmatched path is `:157-161` → `bad()` at `:90` |

### 3. Is a declared item REPORTED, or does the run read as clean?

Measured by running each gate with an entry suppressing a real defect.

| | what a reader actually sees | verdict |
|---|---|---|
| `_canary-coverage.py` `EXEMPT` | Named at detection, reprinted with its reason in a dedicated block, and the green line changes: `✅ … no NEW unproven detector — … and the 1 entry(ies) above remain UNPROVEN by declaration.` (`:941-942`, `:962-979`, `:995-1003`) | ✅ |
| `_canary-coverage.py` `KNOWN_UNPROVEN` | Identical — the same three code paths iterate both ledgers. | ✅ |
| `_parse-guard-args.sh` | Each entry is now **named**: `⚠ DECLARED EXEMPTION (adoption-skippable-guard.sh …)` (`:231-235`). But the reason is a **fixed sentence printed for every entry**, not the entry's own — with two entries both get the first one's justification. And the block sits *inside* `if [[ "$rc" -eq 0 ]]` (`:225-236`), so on any failing run the declared exemption is invisible. The green line itself is unchanged, with the count riding it (`:226`). | ⚠ partial |
| `check-adoption-skip.sh` | Per-strand `⚠ DECLARED … known, accepted, NOT fixed` (`:154`); a dedicated end block naming component/kind/namespace/sibling and printing the reason in full (`:549-560`); and the final green line **replaced** so it never claims blanket safety (`:564-569`). | ✅ |

`check-adoption-skip.sh:565-567` states the rule, in its own words: a green line claiming blanket
safety over known-broken pairs is "the exact false reassurance property 3 was added to kill."
`_canary-coverage.py:996-999` now states the same rule about its own green line.

Measured — the same fixture, the same real hole, once per ledger:

```
# _canary-coverage.py over unproven-guard.py, EXEMPT entry in force → rc 0, and the reader sees:
⚠ DECLARED EXEMPT  unproven-guard.py:42  pattern:UNUSED_RE: still UNPROVEN, known, accepted
  — NOT fixed. 2026-08-06 | fixture: the hole itself | decision: probe

_canary-coverage: 1 declared ledger entry(ies) — accepted debt, NOT proof:
  ⚠ EXEMPT  unproven-guard.py::pattern:UNUSED_RE  (unproven-guard.py:42)  observed UNPROVEN on this run
      2026-08-06 | fixture: the hole itself | decision: probe

✅ _canary-coverage: no NEW unproven detector — 1 detector(s) proven across 1 swept guard(s),
   and the 1 entry(ies) above remain UNPROVEN by declaration. The ledgers may shrink, never grow.

# with both ledgers EMPTY the sentence goes back to the strong claim, and says why it may:
✅ _canary-coverage: 3 detector(s) proven across 1 swept guard(s); every blinding moved an exit
   code. Both ledgers are empty, so that claim carries no exceptions.

# _parse-guard-args.sh, the real script over the real tree → rc 0:
✅ argument parsing: 16 guard(s)/library(ies) on the shared parser, 1 declared exemption(s), …
   ⚠ DECLARED EXEMPTION (adoption-skippable-guard.sh is not on the shared parser, by decision …)
```

The debt block is printed **before** the verdict (`:962-966`), so it survives a failing run —
measured: a run that exits 1 on a stale entry still prints both carried entries with their reasons.

### 4. Ratchet direction 1 — an UNDECLARED defect still fails

All three conform.

| | evidence |
|---|---|
| `_canary-coverage.py` | `:944-949` builds the problem, `:981-990` returns rc 1. Measured: `unproven-guard.py` with no entry → rc 1 |
| `_parse-guard-args.sh` | `:200-205` `UNPARSED: …` → `rc=1`. Measured: a fixture dir with an unwired `rogue-guard.sh` → rc 1 |
| `check-adoption-skip.sh` | `:157-161` `bad` → `FAILURES` → `:575-576` `exit 1`; proven by canary D (`:284-301`) |

### 5. Ratchet direction 2 — a STALE entry fails

| | detected? | evidence |
|---|---|---|
| `_canary-coverage.py` | **Yes, three directions.** Key no longer enumerates: `:879-885` + `:958-960` → rc 1. Detector became PROVEN: `:950-957` → rc 1. The former blind spot — a key whose guard name is misspelled, filtered out by `k.split("::", 1)[0] in selected` (`:885`) before the staleness scan could see it — is now caught **by shape** in `_ledger_problems()` before any sweep (`:221-226`), as rc 2. The `selected` filter itself remains and is deliberate (`:879-882`): under `--guard <one>`, an entry for a *real* guard that was not swept is not re-checked — but it is no longer silent, because the debt block names it and says so (`:977-979`). | ✅ |
| `_parse-guard-args.sh` | **Yes, both directions.** An exempt file that starts using the parser fails (`:180-186` `STALE EXEMPTION`). An entry naming a file that is **not there** now fails too: a second loop iterates the LEDGER rather than the directory (`:219-224` `VANISHED EXEMPTION`), which is the fix for the "the scan only visits files" hole. | ✅ |
| `check-adoption-skip.sh` | **Yes, fully.** `report_stale_declarations` (`:165-180`, called at `:542`) fails on any entry matching no strand this run observed, and names both causes — fixed, or no longer skippable (`:174-176`). | ✅ |

Measured, on the real code:

```
# _canary-coverage.py, run_gate driven with an injected entry, control first
control: proven-guard.py, no entry                             rc=0
stale key: names a detector that no longer enumerates          rc=1   <- caught
entry that is now PROVEN                                       rc=1   <- caught
key whose guard name is misspelled by one letter               rc=2   <- caught (as malformed)

# _parse-guard-args.sh, the unmodified script run standalone over three fixture directories
CONTROL:     exempt file present + genuinely unparsed   rc=0  ✅ … ⚠ DECLARED EXEMPTION (…)
DIRECTION A: exempt file ABSENT from the directory      rc=1  ❌ VANISHED EXEMPTION: …
DIRECTION B: exempt file NOW USES the shared parser     rc=1  ❌ STALE EXEMPTION: …
```

### 6. Are MALFORMED entries rejected, with an exit code distinct from "defect found"?

| | detected? | evidence |
|---|---|---|
| `_canary-coverage.py` | **Four shapes, all rc 2** — `_ledger_problems()` (`:188-232`) runs at the top of `run_gate` before anything is swept and returns 2 (`:843-851`): a key in both ledgers (`:206-211`), a key with no `::` (`:215-219`), a key naming a guard that is not a file under `tools/lint/` or the fixtures (`:221-226`), an empty reason (`:227-231`). **Not** checked: the reason's *shape*. `"TODO"` and `"x"` are accepted and suppress a real hole exactly as well as a justified entry. | ⚠ partial |
| `_parse-guard-args.sh` | **Detected, not distinguished.** There is still no format beyond "a filename", so there is no shape to violate — but C4's fourth bullet ("a key that matches nothing is malformed, not absent") is now enforced: `VANISHED EXEMPTION` (`:219-224`). It sets `rc=1`, the **same code** `UNPARSED` uses for a real defect (`:200-205`), so a reader cannot tell "your ledger is wrong" from "a guard is wrong" by exit code. | ⚠ partial |
| `check-adoption-skip.sh` | **Yes**, and it is the model. `ledger_lint()` (`:117-134`) is called before anything else (`:205-212`) and exits **2**, not 1 (`:211`), because "a ledger this script cannot parse silently declares nothing" (`:206-207`). It enforces the ` :: ` separator, exactly four key fields, `NS`/`OG`, a leading `YYYY-MM-DD`, and a non-empty `\| decision:` tail. | ✅ |

Measured — `_canary-coverage.py` over `unproven-guard.py`, whose `pattern:UNUSED_RE` is a real hole:

```
control: no entry — the real hole FAILS                        rc=1
entry with a full reason (date + why + decision)               rc=0
entry with reason = '' (no date, no why, no decision)          rc=2    <- now rejected
entry with reason = 'TODO'                                     rc=0    <- silences it just as well
entry with reason = 'x'                                        rc=0    <- one character is a reason
```

and over `proven-guard.py`, whose control is a clean rc 0:

```
key whose guard name is misspelled by one letter               rc=2
key with no '::' at all                                        rc=2
the same key in BOTH EXEMPT and KNOWN_UNPROVEN                 rc=2
```

The real `ledger_lint()`, driven through `_extract-func.sh` against fixtures — unchanged since the
first revision, re-measured:

```
well-formed (the shipped shape)     rc=0  <no problems>
missing the :: separator            rc=1  line 1: no " :: " separating the key from the reason
5 key fields, not 4                 rc=1  line 1: key must be exactly <component> <NS|OG> <namespace> <sibling>
kind is neither NS nor OG           rc=1  line 1: kind "XX" is neither NS nor OG
no leading YYYY-MM-DD date          rc=1  line 1: reason must start with a YYYY-MM-DD date
no | decision: pointer              rc=1  line 1: reason must end with "| decision: <...>"
empty decision pointer              rc=1  line 1: reason must end with "| decision: <...>"

the SHIPPED KNOWN_STRANDS through it  rc=0  <no problems>   (2 entries)
```

(`ledger_lint` returns 1 to its caller; the caller converts that to `exit 2` at `:205-212`.)

### 7. Does the self-test prove the ledger's own behaviour?

| | covered by a canary | NOT covered |
|---|---|---|
| `_canary-coverage.py` | **Ten cases** (`:1121-1163`), each against its own control run with the ledger empty first (`gate()`, `:1097-1118`): four rot directions (stale `EXEMPT`, stale `KNOWN_UNPROVEN`, `EXEMPT`-now-proven, `KNOWN_UNPROVEN`-now-proven); `KNOWN_UNPROVEN` converting a real hole from rc 1 to rc 0; four malformed shapes asserting rc **2** (`:1134-1148`); and the reporting contract, which asserts on captured stdout that the entry is named at detection, reprinted with its reason, and the green line no longer claims blanket success (`:1154-1162`). Plus a blanket assertion, applied to every case, that `every blinding moved an exit code` never appears while any entry is in force (`:1175-1178`). | The C1 **format** — there is no branch to canary, because nothing validates it (§6). And no single case runs a stale entry **alongside** a live one; the over-fire control is a separate case rather than a same-run control. |
| `_parse-guard-args.sh` | Canaries F/G/H (`:342-382`) on wiring: the meta-scan catches an unparsed guard, stays silent on a wired one, catches a half-conversion. Canaries **I/J/K** (`:384-440`) on the ledger, over one fixture directory holding a genuinely-unparsed `exempt-guard.sh` and a wired `wired-guard.sh`: **I** is the over-fire control (live entry → rc 0 **and named**), **J** fails a `VANISHED` entry while asserting the live one is *not* flagged, **K** fails a `STALE` one by name. All three drive the real `_pga_meta_scan` with a fixture-local `_PGA_EXEMPT` via a subshell (`:259-264`), never a re-implementation. | A malformed-entry canary — there is no rc-2 branch to drive (§6). |
| `check-adoption-skip.sh` | Canaries D/E/F (`:284-335`), which call the **real** `report_strand` / `report_stale_declarations` and measure their effect on the **real** `FAILURES` counter, restoring it afterwards (`:291-296`, `:309-312`, `:328-330`). F carries an over-fire control: one live entry that must stay quiet alongside the stale one that must fail. | **`ledger_lint()` — still no canary.** One call site (`:205`), reached *before* `self_test()` runs (`:351`), and never driven against a malformed fixture. Verified by extracting `self_test` and grepping it: no `ledger_lint` call inside. The linter works (measured in §6); nothing in the file proves it. |

Canary G is worth reading before writing a canary of your own (`:355-362`). Its first version ran
with the **real** ledger in force and asserted rc 0 over a directory that does not contain the
exempted file — i.e. it asserted, as a requirement, that the scan must stay quiet about an entry
naming a file that is not there. The self-test had enshrined the very hole §5 measured. Fixing the
scan meant fixing the canary. `_canary-coverage.py:1091-1096` records the sibling lesson: its ledger
block's first draft asserted rc 1 on a fixture that returned rc 1 anyway, so the assertion could not
fail. That is why every case in both files runs a control first.

### 8. Does CI assert the self-test's exact exit code?

All three conform.

| | evidence |
|---|---|
| `_canary-coverage.py` | `.github/workflows/lint.yml:1476-1483` — `if [ "$rc" -ne 1 ]` → fail; real run at `:1529` |
| `_parse-guard-args.sh` | `.github/workflows/lint.yml:1271-1280` — assert, then the real meta-scan at `:1280` |
| `check-adoption-skip.sh` | `.github/workflows/lint.yml:1196-1212` — assert, then the real check at `:1207` |

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

A reason that lives only in a neighbouring comment fails this: `_parse-guard-args.sh:135-139` couples
reasons to entries *by position*, which survives exactly until someone adds a second entry. Its
`⚠ DECLARED EXEMPTION` line does not rescue it — that reason is a **literal in the print statement**
(`:233`), so a second entry inherits the first entry's justification verbatim. Measured with two
entries: both printed "its own parser must reject unknown arguments by name", true of one of them.

**Non-emptiness is not the format.** `_canary-coverage.py` rejects `""` (`:227-231`) and accepts
`"TODO"` — which is the shape this requirement exists to forbid, since an entry with no date has no
visible age and an entry with no decision pointer names no one.

### C2. A declared item is REPORTED as accepted debt — never rendered as safe or clean

Three things, all of them:

1. **Named at the point of detection** — `⚠ DECLARED …` with the specific item, not a total, and
   on **every** run, not only the ones that end green. An entry printed only inside the success
   branch disappears exactly when the log is longest.
2. **A dedicated summary block** that reprints each declared item with **its own** full reason, so a
   reader scanning for known debt finds it without reading the whole log
   (`check-adoption-skip.sh:549-560`; `_canary-coverage.py:962-979`, printed before the verdict so a
   failing run still carries it).
3. **The success line must change.** Not `✅ adoption is safe across the portfolio`, but
   `✅ no NEW adoption break — every property holds except the N strand(s) declared above, which
   remain BROKEN by owner decision` (`:564-569`). A count buried in an otherwise unchanged green
   sentence does not clear this bar; neither does silence. `_canary-coverage.py:995-1007` shows the
   pattern applied conditionally: the strong sentence is still printed when both ledgers are empty,
   and it says so — "Both ledgers are empty, so that claim carries no exceptions."

Exit 0 means "no *new* defect". It must never be printed as "no defect".

### C3. The two-directional ratchet

* **An undeclared defect fails.** The gate stays live for new breaks — the only reason a ledger is
  tolerable at all.
* **An entry matching no defect in this run fails**, and says to delete it. Both causes need naming:
  the defect was fixed, or the thing stopped being in scope
  (`check-adoption-skip.sh:174-176`).

Direction 2 is what stops the ledger becoming a stale doc with a green tick over it. It was the
requirement most easily lost: both `tools/lint` ledgers shipped with half of it and both were
completed on 2026-08-06.

**If your staleness scan iterates the observed defects, it must also iterate the ledger.** Every
entry has to be accounted for by name — otherwise an entry that matches nothing simply never comes
up, which is precisely how both `tools/lint` ledgers lost direction 2 for five days.
`_parse-guard-args.sh:213-224` is the minimal fix: a second loop, over `${_PGA_EXEMPT}` rather than
over `"$dir"/*.sh`, whose comment says why it exists.

### C4. Malformed entries fail loudly, with an exit code distinct from "defect found"

A ledger the gate cannot parse declares nothing, and a gate that silently declares nothing reports
accepted debt as a fresh break — or a fresh break as accepted debt. So:

* Lint the ledger **before** running the check (`check-adoption-skip.sh:205-212`;
  `_canary-coverage.py:843-851`, the first statement in `run_gate`).
* Exit **2**, never 1. In this tree 1 means "the thing I check is broken" and 2 means "I could not
  check what I claim to check"; a malformed ledger is the second. And 1 is load-bearing elsewhere:
  CI asserts `--self-test` exits exactly 1, so a malformed-ledger rc of 1 would satisfy that
  assertion (`_parse-guard-args.sh:44-47`). This is the half `_PGA_EXEMPT` still misses — it detects
  a vanished entry and reports it at rc 1, indistinguishable from an unparsed guard.
* Validate every field C1 requires. An entry whose reason is `""` must not be accepted — and neither
  must `"TODO"`. `_canary-coverage.py` rejects the first and accepts the second, and as measured in
  §6 the second suppresses a real hole exactly as effectively as a justified entry.
* **A key that matches nothing is malformed, not absent.** This is the failure mode C3's blind spots
  come from. If a key's shape can be validated statically (a guard filename that must exist, a
  component that must be in the portfolio), validate it — `_canary-coverage.py:182-185` is four
  lines (`(LINT / guard).is_file() or (CANARY / guard).is_file()`) and closes a hole that had
  survived a full audit.

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
"the stale entry failed" assertion (`check-adoption-skip.sh:319-321`; `_parse-guard-args.sh:395-408`
is the same control written as its own canary, and `:423-426` asserts the live entry was *not*
flagged inside the failing run). Likewise, drive the real counter and restore it (`:291-296`) rather
than asserting about a copy: "a re-implementation of the accounting could pass while the gate is
broken" (`:220-222`).

And assert on the **output**, not only the exit code. `_canary-coverage.py:1154-1178` is the shape:
one required substring per C2 element, plus a forbidden substring (`every blinding moved an exit
code`) checked on every case. An entry that moves an exit code while staying invisible in the log is
half the defect these cases exist to prevent.

CI runs the self-test first and asserts `rc -eq 1` exactly, then runs the real check — the shape at
`.github/workflows/lint.yml:1196-1212`. An unrun gate is worse than none.

### C6. Adding an entry is an OWNER decision, not an agent's

Writing an entry converts a red gate into accepted debt. That is a product decision about shipping a
known defect, and it belongs to the repo owner — never to a coding agent, and never to whoever
happens to be trying to get CI green.

An agent that finds a gate red has exactly three options: **fix the defect**, **fix the gate if the
gate is wrong**, or **report it and stop**. Adding a ledger entry is not one of them. If the entry is
genuinely the right answer, say so in the report, with the evidence, and let the owner decide.

All three ledgers state it in their own file, and every new one must:
`check-adoption-skip.sh:67` and `:102-103`, `_canary-coverage.py:136`,
`_parse-guard-args.sh:133` — plus `platform-portfolio/README.md` § Adoption.

The corollary, from `tools/lint/README.md`, § "Proving a detector is load-bearing": **if a new
detector comes out unproven, the fix is a witness, not a ledger entry.** Reach for a ledger only when
the defect genuinely outlives the gate.

## Conformance today

`✅` conforms · `⚠` partial · `❌` does not · **(chg)** marks a cell that moved in this revision

| requirement | `_canary-coverage.py` | `_parse-guard-args.sh` | `check-adoption-skip.sh` |
|---|---|---|---|
| **C1** date + reason + decision, as fields | ⚠ **(chg)** `""` now rejected (`:227-231`), but the value is still free text: `"TODO"` → rc 0 | ❌ no reason field; positional comments (`:135-139`) and a canned literal in the print (`:233`) | ✅ enforced by `ledger_lint` (`:120-131`) |
| **C2a** named at detection | ✅ **(chg)** `⚠ DECLARED <label> <where> <ident>` with the reason (`:937-943`) | ⚠ **(chg)** named (`:231-235`), but only on the rc-0 path (`:225-236`) and with a shared canned reason | ✅ `warn` per strand (`:154`) |
| **C2b** summary block with reasons | ✅ **(chg)** `:962-979`, printed before the verdict so a failing run keeps it | ⚠ **(chg)** each entry listed, but the "reason" is one literal for all of them (`:233`) | ✅ `:549-560` |
| **C2c** success line changes | ✅ **(chg)** `:995-1003` when non-empty; `:1004-1007` keeps the strong claim only when both are empty | ❌ the count still rides an unchanged green line (`:226`) | ✅ `:564-569` |
| **C3a** undeclared defect fails | ✅ `:944-949` → rc 1 | ✅ `:200-205` → rc 1 | ✅ `:157-161` → `exit 1` |
| **C3b** stale entry fails | ✅ **(chg)** no-longer-enumerates (`:879-885`+`:958-960`), now-proven (`:950-957`), misspelled guard (`:221-226`, as rc 2) | ✅ **(chg)** `STALE EXEMPTION` (`:180-186`) **and** `VANISHED EXEMPTION` (`:219-224`) | ✅ `:165-180`, called `:542` |
| **C4** malformed → distinct exit | ⚠ **(chg)** four shapes → rc 2 (`:188-232`, `:843-851`); reason FORMAT still unvalidated | ⚠ **(chg)** a key that can never match is now caught (`:219-224`) but at rc **1**, the defect code | ✅ `ledger_lint` → `exit 2` (`:117-134`, `:205-212`) |
| **C5** self-test proves it | ✅ **(chg)** 10 cases with controls (`:1121-1163`), incl. 4 malformed → rc 2 and an output-contract case | ✅ **(chg)** F/G/H wiring + I/J/K ledger with an over-fire control (`:342-440`); canary G no longer enshrines the hole | ⚠ D/E/F on real functions + real counter (`:284-335`); **`ledger_lint` still uncovered** |
| **C5** CI asserts exact rc | ✅ `lint.yml:1476-1483` | ✅ `lint.yml:1271-1280` | ✅ `lint.yml:1196-1212` |
| **C6** owner rule stated in-file | ✅ `:136` "Adding an entry is an OWNER decision, not an agent's." | ✅ `:133`, same sentence | ✅ `:67`, `:102-103` |

**Summary.** `check-adoption-skip.sh` is still the reference for *entry format* and *malformed
handling*: copy `KNOWN_STRANDS`, `ledger_lint()`, `report_strand()`, `report_stale_declarations()`
and the D/E/F canaries. It is no longer the reference for everything — `_canary-coverage.py` now has
the strongest staleness logic (three directions, including one the others have no analogue for), the
strongest self-test (ten cases, four of them asserting the distinct rc 2, one asserting on captured
output), and a conditional green line worth copying. `_PGA_EXEMPT` is still the weakest and still the
one most likely to be copied, because it is the simplest-looking — but its remaining gaps are all
consequences of the same root cause: **a bare string of basenames has nowhere to put a reason**, so
C1, C2b and C4's format bullet cannot be met without changing the format.

**What still does NOT conform** — 8 of 30 cells, re-measured today, one per file:

1. `_canary-coverage.py` validates a reason only for **non-emptiness**, not for the
   `<date> | <why> | decision: <who>` format C1 asks for (C1, C4). Measured: `"TODO"` and `"x"` are
   accepted and silence a real hole exactly as effectively as a justified entry.
2. `_PGA_EXEMPT` reasons live in **positional comments** (`:135-139`) and a canned print literal
   (`:233`), not in the entries (C1, C2a, C2b); the green line still carries a bare count (C2c); and
   a vanished entry reports at rc **1**, not a distinct rc 2 (C4).
3. `check-adoption-skip.sh`'s `ledger_lint()` has **no canary** (C5). It is reached before
   `self_test()` runs, so nothing ever drives it against a malformed fixture — the one requirement
   this file is otherwise the reference for is the one requirement it cannot prove about itself.

So none of the three is fully conformant. That is a statement about the three files, not a licence: a
**new** ledger conforms on day one, and the gaps above are named so they can be closed deliberately
rather than propagated by imitation.

## Checklist for a new ledger

1. Entries are structured records with `<key fields> :: <date> | <why> | decision: <who>`.
2. A `*_lint()` runs before the check and exits **2** on any malformed entry, including a key that
   could never match and a reason that does not carry all three fields.
3. An undeclared defect still fails; an entry matching nothing this run fails and says to delete it.
4. Declared items get named at detection **on every run**, reprinted in a summary block with their
   own reasons, and change the success line.
5. Canaries drive the real functions and the real counter: undeclared-still-counts,
   declared-counts-zero, stale-fails-while-live-stays-quiet, malformed-exits-2 — and at least one
   asserts on captured OUTPUT, not just an exit code.
6. The CI step asserts `--self-test` exits exactly 1 before running the real check.
7. The file says, in its own words, that adding an entry is an owner decision.
8. Add the ledger to the tables above, with evidence — **and re-derive every existing cell while you
   are there**, by driving the code, not by copying the old table forward. See the revision log:
   this page shipped with 17 non-conforming cells and most of them were fixed within hours, which
   made the page itself a declaration that had outlived its defect. A ledger that outlives its
   defect must fail; so must its documentation.

## Reproducing the measurements in this file

```bash
bash platform-portfolio/hack/check-adoption-skip.sh --self-test   # must exit 1
bash tools/lint/_parse-guard-args.sh --self-test                  # must exit 1
python3 tools/lint/_canary-coverage.py --self-test                # must exit 1
```

The probes behind sections 3, 5 and 6 drive the shipped code without editing it:

* **`_canary-coverage.py`** — `importlib` the module, write a key into `EXEMPT` / `KNOWN_UNPROVEN`,
  call `run_gate([fixture], {"*"}, 1e9, 4, 120)`, pop the key in a `finally`. Capture stdout with
  `contextlib.redirect_stdout` to check what a reader sees. This is the pattern the file uses on
  itself at `:1097-1118`; run the control with the ledger empty first or the case proves nothing.
* **`ledger_lint()`** — `source tools/lint/_extract-func.sh`, then
  `eval "$(extract_func platform-portfolio/hack/check-adoption-skip.sh ledger_lint)"` and call it
  with a one-line fixture file. `known_strands` extracts the same way, so the shipped ledger can be
  run through the shipped linter.
* **`_pga_meta_scan`** — copy the **unmodified** `_parse-guard-args.sh` into a fixture directory and
  run it there: its standalone entry point scans its own dirname (`:130`, `:466`) with the real
  `_PGA_EXEMPT` in force, so a fixture directory that does or does not contain
  `adoption-skippable-guard.sh` exercises both staleness directions. To vary the ledger instead of
  the directory, edit `_PGA_EXEMPT` in the **copy** — never the shipped file.

## See also

* `tools/lint/README.md` § "Proving a detector is load-bearing" — the `EXEMPT`/`KNOWN_UNPROVEN` pair
  in context, and the exit-code convention every guard here follows.
* `platform-portfolio/README.md` § "Declared known strands" — `KNOWN_STRANDS` as a ratchet, with the
  three-row table of what each situation produces.

## What this revision changed

Re-derived 2026-08-06 by driving all three implementations. All **30** conformance cells (10
requirements × 3 files) were re-measured, not carried forward. **14 differ** from the first version:

**10 verdicts moved, every one because the code was fixed** — not because the first measurement was
wrong: C1, C2a, C2b, C2c, C3b and C5-self-test for `_canary-coverage.py`; C2b, C3b, C4 and
C5-self-test for `_parse-guard-args.sh`.

**2 kept their symbol but had their evidence rewritten**, because the substance moved while the
verdict did not: C4 for `_canary-coverage.py` (was "only the both-ledgers contradiction"; now four
shapes, all rc 2 — still ⚠ only because the reason FORMAT is unvalidated) and C2a for
`_parse-guard-args.sh` (was "counted only"; now named, but only on the rc-0 path and with a shared
canned reason).

**2 were wrong when written.** The first version marked **C6 ❌ for both `tools/lint` ledgers**,
arguing that `_canary-coverage.py`'s "may shrink, never grow" is a ratchet rule and not an ownership
rule. That overlooked the pointer comment two lines above it — *"Adding an entry is an OWNER
decision, not an agent's"* — which is verbatim what C6 asks for, and which was added to **both**
files by the very same commit that added this page. The page shipped scoring two files ❌ on a
requirement its own sibling hunk had just made them meet. Corrected to ✅/✅; nothing in either file
changed. These two are the only cells of the fourteen that were a mistake rather than a fact with a
shelf life.

**16 re-confirmed unchanged**, by re-running the measurement rather than by re-reading the table:
the entire `check-adoption-skip.sh` column (all 10 rows, including `ledger_lint`'s missing canary);
C3a and C5-CI for both `tools/lint` ledgers; and C1 and C2c for `_parse-guard-args.sh`.
`check-adoption-skip.sh` is **byte-identical** to the commit that first shipped this page (`git diff`
against it is empty), so every line number cited for it here is still the original.

§3, §5, §6 and §7 were rewritten around new measurements; §5's and §6's measured blocks are
entirely new output, captured from the shipped code on the day of this revision.

**Line numbers.** Every citation into the two `tools/lint` files moved, and **not by a constant** —
code was inserted at several points, so the shift grows down the file. `_canary-coverage.py`:
`EXEMPT` +13 (`:147`→`:160`), the declared-detector branch +78 (`:859`→`:937`), the green line +106
(`:894`→`:1000`). `_parse-guard-args.sh`: the ledger +14 (`:142`→`:156`), the `UNPARSED` case +19
(`:179`→`:198`), the green line +31 (`:195`→`:226`). Do not offset the old numbers; grep the quoted
text. `.github/workflows/lint.yml` moved uniformly +18. `check-adoption-skip.sh` did not move.
