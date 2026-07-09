# ADR-0001: Entry states are Helm-parameterized charts materialized as Argo CD Applications

Date: 2026-07-08 · Status: accepted (PM decision, flagged for Serhat review) · Owner: PM

## Context

Module independence (Decision D11) requires `ws start m09 --user user5` to materialize module 9's world for one user without any other module having run. 01-ARCHITECTURE originally sketched "kustomize bases with a per-user overlay template", which at 30 users × 27 modules means either committing ~800 generated overlay directories to git or teaching `ws` to render+commit per invocation (git plumbing, conflicts, cleanup).

## Decision

Each entry state is a small **Helm chart** (`gitops/entry-states/mNN/`: `Chart.yaml`, `values.yaml`, `templates/`). `ws start` creates one Argo CD **Application** (`entry-mNN-userN`) with `helm.parameters: user=userN, clusterDomain=<detected>`, sourced **from the in-cluster Gitea mirror** (git-localize, D15). Reset = delete Application (prune via resources-finalizer) + recreate. Charts share conventions, not a library chart, until repetition earns one.

## Consequences

- `ws start` is one `oc apply`; no generated files; Argo-native diff/health; reset is free.
- Module authors write Helm templates instead of raw manifests — mitigated by the m01 exemplar + `docs/module-template/`.
- 01-ARCHITECTURE §3 updated to match (same-change rule); the M08 meta-reveal still works: attendees inspect the Application CRs and the charts in Gitea.

## Amendment — 2026-07-09 (Phase 2 G3 wave findings)

Two field-proven semantics were added to the engine after the M04/M05 smoke tests:

1. **`selfHeal: false` on every entry Application** (automated `prune` stays on). In a training lab, attendee
   mutations to chart-owned workloads *are the exercise*, not drift to correct: with selfHeal on, Argo reverted
   the M05 attendee's `oc set volume` within ~1s, so the module's central persistence exercise could never
   complete (G3-M05 SEV1). Creation still auto-syncs, so materialization is unchanged; `ws reset`
   (delete + purge + fresh apply) remains the only re-convergence path — now by design, not just convention.
2. **Declared-conflict eviction on `ws start`/`ws solve`.** Entry charts that materialize the *same named
   workloads* (m02–m05 all own `parasol-claims`/`claims-db` in `{user}-dev`) deadlock when their Applications
   coexist: SharedResourceWarning, both permanently OutOfSync, and the attendee gets a silently wrong world
   while the entry-marker check stays green (G3-M04 SEV2). Each chart's `ws-meta.yaml` now declares
   `conflictsWith:`; start/solve evicts those Applications, purges this module's `purgeNamespaces`, and
   recycles its own Application so the fresh apply triggers a creation auto-sync (required with selfHeal off).
   Disjoint modules (m01 `parasol-web`, m23 `{user}-batch`) still coexist untouched — proven live
   (m01 survived an m04 start on the same user; m01+m02+m05 markers coexisted through the M05 smoke).

Consequence for authors: a module whose chart re-materializes an existing named workload MUST list the other
owners in `conflictsWith` (both directions); the G3 smoke deliberately probes cross-module coexistence to catch
omissions.
