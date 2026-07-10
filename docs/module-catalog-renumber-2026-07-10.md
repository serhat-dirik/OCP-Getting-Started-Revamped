# Module catalog renumber — 2026-07-10 (Serhat directive: sequential teaching order)

The catalog was renumbered to contiguous M01–M27 in teaching order (commit `74cb405`). Anything
written before 2026-07-10 (status reports, G3/G4 test reports, research build notes, git history,
old INBOX entries) uses the OLD numbers. This table is the permanent decoder.

**Never blind-remap by number** — a bare "M06" is ambiguous across the boundary (old M06 =
Pipelines, new M06 = Jobs). Always disambiguate by module TOPIC.

| OLD | NEW | Module | Notes |
|-----|-----|--------|-------|
| M01–M05 | M01–M05 | Orientation · Build/Deliver · Dev Spaces · Config · Storage | unchanged |
| M23 | **M06** | Jobs, Batch & Queued Workloads | the only BUILT module that renamed (files, entry state, verify, navs all moved in `74cb405`) |
| M06 | M07 | Pipelines Fundamentals & Task Libraries | |
| M07 | M08 | Trusted Software Supply Chain [ADS] | |
| M08 | M09 | GitOps Fundamentals | |
| M09 | M10 | GitOps at Scale & Progressive Delivery | |
| M10 | M11 | Developer Hub & Golden Paths [ADS] | |
| M11 | M12 | Observability, Health & Scale | |
| M29 | M13 | Securing Apps with Keycloak | |
| M12 | M14 | Multi-User, Multi-Tenancy & Workload Security | |
| M13 | M15 | Networking for Dev & DevOps | |
| M14 | M16 | Deployment Targets & Scheduling | |
| M15 | M17 | Registry, Images & Catalog Governance | |
| M16 | M18 | Service Mesh 3 & Advanced Gateways | |
| M17 | M19 | Serverless Zero-to-Hero | |
| M19 | M20 | OpenShift Virtualization for App Teams | |
| M20 | M21 | Resilience, Multi-Cluster & DR | |
| M21 | M22 | Application Modernization (MTA + AI) | |
| M22 | M23 | Agentic AI on OpenShift [ADD-ON] | |
| M24 | M24 | Eventing Deep-Dive & Serverless Workflows | unchanged |
| M25 | M25 | Packaging & Distributing Your App | unchanged |
| M27 | M26 | Operator Development Deep-Dive | |
| M28 | M27 | AI-Assisted Development (MCP) [ADD-ON] | |

Old **M18** (Kafka — folded into M24) and old **M26** (Connectivity Link — cut, D17) never existed
as content; any old-text reference to them is stale, not remappable.

## Renumber state (as of 2026-07-10, commit `17ccb31`)

DONE: built module m23→m06 (all artifacts) · repo catalog (index.adoc, 3 navs, README) ·
Project-Shared spec/backlog/status headline numbers · `[OCP]` entitlement row + README ranges
hand-fixed.

REMAINING (a content-editor sweep — safe to re-run because it verifies by TOPIC, which is
idempotent; pure number-pattern remapping is NOT re-runnable):
1. Cross-refs to other modules inside built content m01–m05 (disambiguate M06 Jobs-vs-Pipelines by topic).
2. `docs/research/` build-note file renames (collision-heavy: use two-phase temp names; m23→m06,
   m06→m07, m07→m08, m08→m09, m09→m10, m10→m11, m11→m12, m29→m13) + their internal titles/cross-refs.
3. Range expressions in 02-MODULE-SPECS body (lines ~146, 256, 287, 346 were endpoint-remapped and
   may be distorted — recompute each from the module SET it means).
4. Maintainer comments in gitops/ + platform-portfolio/ that reference other modules by number.
5. ON-CLUSTER (needs cluster): orphan Argo apps `entry-m23-user6`/`entry-m23-user8` still carry the
   old id — delete and re-materialize as m06 (`ws start m06 --user userN`); marker ConfigMaps are
   chart-owned and follow automatically. Mirror-sync after any push.
