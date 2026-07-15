# Module catalog renumber — 2026-07-10 (project directive: sequential teaching order)

> **Two reorders now exist — this page decodes BOTH.** (1) The **2026-07-10 Gen 1 → Gen 2**
> sequential renumber (table immediately below). (2) The **2026-07-12 Gen 2 → Gen 3** reorder —
> drop Virtualization + Block D compaction (section at the bottom). Net after 2026-07-12:
> **M20 = Eventing** (NOT Virtualization) and **M24 = AI-Assisted Development** (NOT Eventing).
> Always disambiguate a bare number by TOPIC and by the document's date.

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

---

## 2026-07-12 reorder (Gen 3): drop Virtualization + Block D compaction

Second directive (2026-07-12): OpenShift Virtualization is **dropped** (no bare-metal/virt
dependency on any workshop cluster), and Block D is compacted so Eventing sits right behind
Serverless and the two AI electives stay adjacent. **M01–M17 are unchanged** (Gen 2 = Gen 3 for
them). Only the Block D tail moves. Net library = **26 modules (M01–M26)**.

**Never blind-remap by number across THIS boundary either** — a pre-2026-07-12 "M20" is
Virtualization, a post-2026-07-12 "M20" is Eventing; a pre-2026-07-12 "M24" is Eventing, a post
"M24" is AI-Assisted Development. Decode by TOPIC + date.

| Gen 2 (2026-07-10) | Module (topic) | Gen 3 (2026-07-12) |
|-----|--------|-----|
| M18 | Service Mesh 3 & Advanced Gateways | **M18** (unchanged) |
| M19 | Serverless Zero-to-Hero | **M19** (unchanged) |
| M20 | OpenShift Virtualization for App Teams | **DROPPED** (retired; ID reused for Eventing) |
| M21 | Resilience, Multi-Cluster & DR | **M21** (unchanged) |
| M22 | Application Modernization (MTA + AI) | **M22** (unchanged) |
| M23 | Agentic AI on OpenShift [ADD-ON] | **M23** (unchanged) |
| M24 | Eventing Deep-Dive & Serverless Workflows | **M20** (moves up, behind Serverless) |
| M25 | Packaging & Distributing Your App | **M25** (unchanged) |
| M26 | Operator Development Deep-Dive | **M26** (unchanged) |
| M27 | AI-Assisted Development (MCP) [ADD-ON] | **M24** (moves up, beside Agentic AI) |

The three real changes: (1) **drop Virtualization**, (2) **Eventing M24 → M20**, (3)
**AI-Assisted Dev M27 → M24**. Everything else keeps its number.

Final Block D order (Gen 3): **M18** Service Mesh · **M19** Serverless · **M20** Eventing ·
**M21** Resilience · **M22** Modernization · **M23** Agentic AI · **M24** AI-Assisted Dev ·
**M25** Packaging · ~~**M26** Operator Dev~~.

> **M26 Operator Development — CUT 2026-07-15** (owner directive: "too advanced," before any content or
> entry-state was built). The Block-D tail is now **M24** AI-Assisted Dev · **M25** Packaging. The AppSec
> module remains at **M27** (built), leaving a gap at M26 unless the owner elects to renumber M27→M26.
> `docs/adr/0006-*` and `docs/research/m26-build-note.md` are retained as retired research records.

### Renumber state — COMPLETE (2026-07-12)

- Docs-only pass (no built content moved — only M01–M14 are built, none change number). Landed:
  repo catalog roadmap (`content/…/index.adoc`), navs (`nav-workshop`/`nav-instructor`/`nav-demo`
  Block-D "coming soon" placeholder), this decoder, m18/m19/m20 research build notes de-hedged,
  m14 note `M27`→`M24` by topic. Private specs (`02-MODULE-SPECS`, `08-MODULE-CATALOG`,
  `06-BACKLOG`, `00-PROJECT-BRIEF`, `01-ARCHITECTURE`, `05-REFERENCES`) renumbered by topic +
  Virtualization dropped.
- Deliberately NOT touched: the Gen 1 → Gen 2 table above and its dated notes (historical);
  `oldcontent-mining-index.md` (consumed input, decode via tables); ADR headers; built M01–M14
  content pages (any Virtualization prose in m01/m03 built pages = a **separate** virt-cleanup
  follow-up, tracked with the M03 VM-showcase swap).
