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

## Renumber state — COMPLETE (2026-07-10)

- Built module m23→m06 (all artifacts) · repo catalog (index, navs, README) · Project-Shared
  spec/backlog/status (`74cb405` + hand fixes).
- Consistency sweep done: 8 research notes renamed + internally remapped by topic; 18
  maintainer-comment files in gitops/ + platform-portfolio/; spec ranges recomputed (L256
  M01–M19; Build-order note rewritten — stale Connectivity-Link clause dropped, "numbered by
  arrival" claim replaced); backlog research-note filenames corrected. m01–m05 content pages
  verified to carry ZERO numeric cross-refs (prose-only convention).
- On-cluster: the three orphaned `entry-m23-*` apps (user6/7/8) swapped to m06, each verified 10/10.
- Deliberately NOT renumbered (historical records — decode with the table above): dated log
  entries in 06-BACKLOG §Decision-log · pre-2026-07-10 reports (G3/G4, STATUS-*) · m01–m05
  research notes + oldcontent-mining-index + app-repo-publishing (consumed inputs) · ADR
  filenames 0003-m16-*/0004-m22-* (their headers carry a renumber note; content already cites
  new numbers where live).
