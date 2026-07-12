# Design: `ws smoke` — the attendee-cockpit G1 gate

- **Date:** 2026-07-12 · **Status:** Approved (Serhat)
- **Author:** PM/tech-lead
- **Why now:** land before the M14–M17 wave so the recurring defect class is caught cheaply from the start.

## Problem

The dominant velocity tax on module development is **rework from defects caught late**. Across the M07–M13 wave that was ~19 fix rounds + ~13 re-checks, and one defect family accounted for the largest share (~31 backlog signatures): the **attendee-cockpit / identity class** — things that work from the admin kubeconfig but break for the real attendee inside the ttyd cockpit as `{user}`:

- `ws` not on PATH; `$HOME=/data` (broke `ws`, then again broke Maven via the JVM's `user.home`);
- namespace-isolation leaks (attendee could list all namespaces / see peers);
- publish-doesn't-reach-live-pods (stale clone in a running cockpit);
- `purge_apps` / RBAC in `student-gitops` (the cross-module independence MUST-PASS).

Our early gates (G1 builder self-check, G2 content pass) never exercise the real cockpit path, so this class survives to the **most expensive** gates (G3 smoke, G4 milestone) every time — each discovery costs a full fix + re-verify cycle. We have a memory (`cockpit-terminal-test-gap`) but no *process* that enforces catching it early.

## Design

A standardized, automated smoke that runs the attendee path **from inside the real cockpit** and gates G1.

### 1. Form — a new `ws smoke mNN [userN]` subcommand

Alongside `prep/verify/reset/solve/doctor`. Chosen over a standalone script or extending per-module verify scripts because it reuses ws's user/module resolution, is discoverable, and centralizes the "`oc exec` into the cockpit terminal" logic **once** instead of every builder/tester agent re-writing that incantation ad hoc (which is how the gap kept slipping through).

Mechanics: run from admin/builder context, it `oc exec`s into `showroom-userN`'s `terminal` container and runs the battery **as the attendee** (the in-pod identity), using the existing `check "…" || hint "…"` idiom from the verify scripts.

### 2. Checks — a generic battery (the bulk of the value) + a tiny optional per-module hook

**Generic battery (every module):**
- `ws` on PATH · `$HOME = /home/lab-user` · **`$HOME == JVM user.home`** (the Maven/`/data` bug) · shell identity `= {user}` (not the showroom SA) · no admin kubeconfig reachable
- Isolation: `oc get projects` = own only · `openshift`/peers invisible · cluster-scope `oc get namespaces` Forbidden
- Lifecycle **from the cockpit**: `ws prep mNN` converges to N/N · `ws verify mNN` passes · a representative click-to-run block lands in the terminal
- Freshness: pod clone HEAD == mirror HEAD (the stale-pod class)

**Per-module hook (optional):** a module MAY add a small `smokeCommands:` list to its `ws-meta.yaml` — 1–3 representative attendee commands it genuinely leans on (e.g. an in-terminal `mvn …:makeBom`, an `argocd app delete`). Default empty. YAGNI: the generic battery already catches most; modules add only load-bearing commands.

### 3. Enforcement — DoD item + mandatory agent-brief evidence (not CI)

- Add to `03-DEV-WORKFLOW §4 (Definition of Done)`: *a module cannot pass **G1** until `ws smoke mNN` is green.*
- Make pasting the smoke output a required **G1 evidence item** in the module-builder / platform-engineer briefs (like timing actuals today).
- Not CI: CI can't reach a live cockpit, and our gates are agent-driven — the brief + DoD is the real lever.

## Implementation plan (single delegated slice, platform-engineer)

1. `tools/ws/ws` — add `cmd_smoke()` + a `smoke)` dispatch case; helpers to `oc exec` into `showroom-<user>`'s `terminal` container and run the generic battery as the attendee; read optional `smokeCommands` from the module's `ws-meta.yaml`; emit a `N/N passed` summary with hints. Reuse `check`/`hint` conventions.
2. `tools/ws/ws-completion.bash` — add `smoke` to the subcommand completions.
3. `03-DEV-WORKFLOW §4` — the DoD line above.
4. Agent operating model / builder brief template — the G1 evidence requirement.
5. `docs/module-template/README.md` (or ws-meta schema note) — document the optional `smokeCommands` key.
6. **Verify on the live cluster:** run `ws smoke` against a non-reserved user cockpit; confirm it passes on a healthy module and *fails loudly* on a deliberately-broken one (e.g. a `HOME=/data` or an unsynced clone) — never a false green.

## Non-goals (YAGNI)

- No CI enforcement (impractical against a live cockpit).
- `smokeCommands` is optional, not mandatory per module.
- Not a replacement for G3/G4 — it front-loads the *cockpit-identity class*, not full lab correctness.

## Rollout

Land before M14–M17 build starts. Retrofit M07–M13 opportunistically (they already passed the equivalent checks manually during their gates).
