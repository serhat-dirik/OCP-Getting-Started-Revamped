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

## Amendment 1 (2026-07-10) — apps-in-any-namespace does not exist for namespace-scoped instances; attendee app CRs live in the student control plane

GitOps operator 1.21.1 (Argo CD 3.4.4) **refuses `spec.sourceNamespaces` on a namespace-scoped
instance** — verified live four ways (glob and explicit-list `sourceNamespaces`; a hand-set
`application.namespaces` param is reverted by the operator in ~15s; the managed-by-cluster-argocd
label is inert). The operator only honors source namespaces for instances listed in
`ARGOCD_CLUSTER_CONFIG_NAMESPACES` — i.e. **cluster-scoped** ones.

Cluster-scoping `student-gitops` (option A) was REJECTED: it preserves the cosmetic detail
(per-user `{user}-gitops` app-CR namespaces) by sacrificing this ADR's primary promise — an
instance that *physically cannot reach* the platform machinery — and widens any attendee
mistake's blast radius to the cluster.

**Decision (option B):** attendee Application CRs live in the `student-gitops` namespace itself.
Isolation layers, each proven live before ratification: per-user Argo RBAC (userN cannot
sync/delete userM's apps — `argocd admin settings rbac can` verified), per-user AppProjects
boxing destinations to `{user}-dev/stage/prod`, and k8s RBAC denying attendees direct writes to
the control-plane namespace (apps are created via the Argo UI under their SSO identity).
`{user}-gitops` namespaces remain as per-user workspace/markers.

**Engine consequence:** attendee-created apps live outside every purge namespace, so ws-meta
gains `purgeAppsNamespace` + `purgeAppsProject` (`${USER}` resolves); `ws reset` and the
conflict-eviction gc delete the user's apps by `.spec.project` — attendees cannot be relied on
to label what they create in a UI.
