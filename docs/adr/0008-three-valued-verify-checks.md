# ADR-0008: Three-valued verify checks — negation flips YES and NO, never "could not ask"

Date: 2026-08-01 · Status: accepted · Owner: PM (prior-art survey by research-analyst)

## Context

`tools/verify/_lib.sh` gained a three-outcome read. `oc_read` (line 54) returns **0** the API answered
yes, **1** the API answered no, **2** the API could not be asked — and on 2 it raises the module-global
`VERIFY_INCONCLUSIVE`, which `check()` reads to print ⚠ SKIP instead of ❌. It exists because a silenced
read (`oc get … 2>/dev/null`) makes "object absent" and "cluster unreachable" the same empty string, so a
cluster stutter told an attendee their correct work was wrong — the trust bug this project treats as
worse than a missed failure.

That settles **positive** checks. It does not settle **negative** ones — entry-state clean-slate checks
that must pass when an object is *absent*. Naively negating a three-outcome predicate collapses the third
state: `! could-not-ask` is a pass, so a check that saw nothing certifies a clean bill of health. Two
shapes survive in the tree today (`tools/verify/eventing-deep-dive.sh:73-80`, `no_filtered_trigger` /
`no_dlq_trigger`, both `! <predicate>`), and a wrongly-green entry check is not cosmetic: it sends
`ws prep` down its "already prepared — nothing to do" fast path without purging.

Three module scripts had already solved this by hand, differently each time. This ADR names the semantics,
adds one primitive, and makes the remaining shape greppable.

## Decision

**Kleene three-valued semantics. A negative check is expressed as `reachable AND absent`, never as
`NOT present`, and the negation primitive — named after Nagios' `negate(1)` — inverts YES and NO while
passing "could not ask" through untouched.**

## Evidence: every mature system converges, and none of them negates a positive check

The sharper finding from the survey is not that these systems keep a third state — it is that **none of
them produces an absence verdict by negating a presence check**. Each ships a dedicated absence predicate
gated on a separately measured reachability signal.

- **Nagios / monitoring-plugins `negate`** — the closest structural match, and effectively the
  specification for this ADR. `plugins/negate.c` permutes only OK and CRITICAL; the WARNING and UNKNOWN
  slots are never reassigned. A check-script negation primitive shipped since the 1990s inverts two states
  and passes the third through. The plugin guidelines define exit 3 UNKNOWN as "the check could not be
  performed" — exactly our rc 2. Honest caveat: those guidelines give no explicit rule for *inverted*
  checks. `negate.c` is the guidance.
- **SQL / PostgreSQL** — `NOT NULL → NULL` in the documented logical-operator truth table, and the docs
  forbid negation-as-absence outright: do *not* write `expression = NULL`, use `expression IS NULL`.
  `IS NULL` is a separate operator, two-valued by construction. This is why `WHERE x != 5` drops NULL
  rows: the predicate is UNKNOWN and `WHERE` keeps only TRUE. The AND table justifies our call-site
  ordering — `TRUE AND NULL → NULL`, `FALSE AND NULL → FALSE`.
- **Kubernetes** — `ConditionUnknown` means "kubernetes can't decide if a resource is in the condition or
  not". Controllers branch on it into a distinct outcome rather than negating it. The decisive example is
  the taints: `node.kubernetes.io/not-ready` corresponds to Ready=False and
  `node.kubernetes.io/unreachable` to Ready=Unknown — **two different taints**, refusing to collapse
  "not ready" into "can't tell" at the point where collapsing would be cheapest.
- **Prometheus** — refutes the naive reading and supplies the composition rule. `absent()` is strictly
  two-valued and cannot distinguish "series absent" from "no data"; Prometheus solves it by putting
  reachability in a separate, automatically generated series, and the documented absence-alert pattern is
  a conjunction with reachability on the **left**: `up{job="myjob"} == 1 unless my_metric`.
- **Go** — `os.IsNotExist` reports whether an error is *known to report* non-existence. Absence is
  positively identified, never inferred from failure; presence travels on a separate channel from the
  value, as with comma-ok.
- **JUnit 5** — `ABORTED` ("started but not finished") is a distinct outcome from `FAILED`. Same line
  `warn()` / `VERIFY_SKIP` already draw in `_lib.sh` (line 370).

Nothing in the prior art contradicts itself. The only disagreement is naming — Nagios inverts and passes
the third state through, SQL forbids `NOT` for the job and hands you `IS NULL` — and both land in the
same place: the third state survives.

## The contract

```bash
negate() {
  local rc=0
  "$@" || rc=$?                        # never a bare call — the set -e trap
  if (( VERIFY_INCONCLUSIVE == 1 )); then return 1; fi   # flag LEFT SET -> check() prints SKIP
  if (( rc == 0 )); then return 1; fi                    # present -> the negative check FAILS
  return 0                                               # genuinely absent -> PASS
}
```

| predicate outcome | flag | `negate` returns | rendered |
| --- | --- | --- | --- |
| answered YES (present) | 0 | 1 | ❌ FAIL |
| answered NO (absent) | 0 | 0 | ✅ PASS |
| could not ask | 1 | 1, flag still set | ⚠ SKIP, not graded |

Call sites become the Prometheus join, reachability first:

```bash
no_filtered_trigger() { oc_present get ns "$NS" && negate filtered_trigger_present; }
```

**It keys off the FLAG, not the rc, and that is the load-bearing choice.** Predicates in this tree
collapse rc 2 into rc 1 — `oc_read … || return 1` appears in `oc_present` (`_lib.sh:117`), `cm_key_set`
(342), `deploy_ready` (353), `deploy_ready_min` (361) and in most module-level detectors — but none of
them clears the flag. Keying on the flag makes the primitive correct against every existing predicate
with zero call-site churn.

`negate` does not replace `oc_absent` (`_lib.sh:108`), which stays the right tool when the absence is one
direct `oc` read; `negate` is for composite predicates that already exist in a positive form.

This is a generalization, not an invention: `no_traffic_split` (`serverless-zero-to-hero.sh:69-75`) is
this exact body written by hand, and the clean-slate helpers in
`registry-images-catalog-governance.sh:130-142` and `rollout_absent` (`gitops-at-scale.sh:161`, already
`oc_present get ns … || return 1` then `oc_absent …`) are the same decision reached independently.

## Consequences

- One primitive replaces three hand-written variants, and future negative checks have one shape to copy.
- Negative checks become capable of ⚠ SKIP, which they could not previously express — a suite run over a
  stuttering cluster reports less, and reports it honestly.
- The rule is mechanically checkable, so the class of bug can be closed rather than merely fixed.

## Open — two items this ADR records rather than closes

**1. `check()` greens a flagged rc 0, so the fix is incomplete until its branch order changes.**
Verified in the current file: `check()` (`_lib.sh:279`) clears the flag at line 284, prints ✅ and
returns at lines 294-298 **on rc 0 alone**, and only reaches the `VERIFY_INCONCLUSIVE` test at line 301
on a non-zero rc. Under the contract above `negate` never returns 0 with the flag set, so this is latent
rather than live for `negate` itself — but it is live for any predicate that recovers from an
inconclusive read with `||`, because only `check()` ever clears the flag (the sole assignments to 0 are
line 51's initializer, line 284, and the save/restore around `cluster_api_reachable` at 154/169). The fix
is to move the flag test above the rc-0 branch, which Kleene sanctions: `TRUE AND UNKNOWN = UNKNOWN`.

Accepted asymmetry, recorded deliberately: Kleene also says `FALSE AND UNKNOWN = FALSE`, but a flag-first
`check()` reports SKIP where a definite FAIL was available. That errs toward under-reporting failure —
the safe half of this project's trust rule.

Blast radius, measured 2026-08-01: 103 `check "…" oc …` call sites across `tools/verify/*.sh` (105 lines
match the pattern; two are examples inside `_lib.sh`'s own comments). The change can only convert PASS →
SKIP, never PASS → FAIL, so no attendee acquires a new ❌ from it.

**2. `eventing-deep-dive.sh`'s namespace guard is the Prometheus join done wrong.** Lines 74 and 78 read
`oc get ns "$NS" >/dev/null 2>&1 || return 1` — the reachability conjunct itself is stderr-silenced, so an
unreachable cluster makes the guard return 1 with no flag raised and the check renders ❌ rather than ⚠:
precisely the false red the three-outcome read exists to delete, reintroduced by the guard meant to
prevent a vacuous pass. `oc_present get ns "$NS"` is the correction.

Also noted, harmless to the contract but misleading to a reader: `_lib.sh`'s file header (lines 28-31)
still documents `oc_read` as "rc 1 → THE API COULD NOT BE ASKED", while the implementation returns 2 for
that case and 1 for a real no. The signature comment on line 54 is correct.

## The rule for a future author

> A negative check is `reachable AND absent`, never `! present` — and negation flips YES and NO while
> leaving "could not ask" exactly where it was.

Second line, borrowed from SQL, for the header comment where `negate` lands: *there is no `= NULL`; there
is only `IS NULL`.*

Bare `!` applied to a three-outcome predicate is a greppable defect shape, and
`tools/lint/verify-oc-read-guard.sh` is its natural home: it already pins this contract, already carries a
per-file baseline ratchet for the acknowledged blind-read debt, and already proves behaviour by executing
the extracted function against a canary rather than grepping for text. Scope note for whoever writes the
detector: the graded case is `!` in front of a predicate used as a `check()` argument or as a helper's
final expression; `! deploy_ready …` inside an `if` that only gates which further checks run (e.g.
`networking-dev-devops.sh:130`, `service-mesh-advanced-gateways.sh:123`) collapses the same three states
but decides control flow, not an attendee-visible verdict, and should be triaged separately rather than
swept into the same failure.
