# ADR-0002: Argo CD topology — two shared instances (platform + student)

Date: 2026-07-08 · Status: accepted · Owner: PM (spike by research-analyst)

## Context

The entry-state machinery runs as Argo Applications; M08/M09 additionally have attendees create their *own* Applications/ApplicationSets. Options: one shared instance with per-user AppProjects; per-user instances (~5 pods × 30 users); or two shared instances. Verified: "applications in any namespace" is GA since GitOps 1.13 (cluster runs operator v1.21.1); the operator supports multiple namespace-scoped ArgoCD instances.

## Decision

**Two shared instances.**
1. **Platform instance** — the default `openshift-gitops`: portfolio stacks + workshop layer + all `entry-*` Applications (AppProject `workshop-entries`). Admin-only writes; attendees get read-only visibility (the M08 "the machinery that built your world is Argo CD" reveal).
2. **Student instance** — `student-gitops` (added by the workshop layer in Phase 3, before M08): apps-in-any-namespace enabled, per-user AppProject boxing each user to their own repos/namespaces/`userN-gitops` source namespace.

## Consequences

- One RBAC slip in student-land cannot delete the entry-state machinery — the failure domain is split.
- Cost: one extra Argo instance (~5 pods) — far below per-user instances.
- Phase 0/1 only need the platform instance; `student-gitops` lands with the M08 wave.
