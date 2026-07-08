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
