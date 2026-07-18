# Credits

This workshop stands on earlier Red Hat enablement assets and community workshops (Decision D18: reuse-with-credit).
Patterns, narratives, and assets are adapted with visible credit; **no deprecated-era technical steps are ever ported** — every step is re-verified against current product documentation and a live cluster.

Credits live in this file only — never inside a module's pages. The full list accretes here as modules are built.

| Source | Used in | What was adopted |
|---|---|---|
| Konveyor `customers-tomcat-legacy` (Apache-2.0; via the Red Hat Modern Application Development workshop `rh-mad-workshop`) | Application Modernization | The `parasol-legacy-claims` migration target: Spring-on-Tomcat WAR structure, the hardcoded-configuration anti-patterns, and the assess → analyze → refactor → deploy arc — re-themed to the Parasol claims domain (insurance domain original). |
| `parasol-insurance` (redhat-ads-tech) | Agentic AI on OpenShift apps (`parasol-agent`, `mcp-servers/claims-db`, `mcp-servers/policy-docs`) | The Parasol Insurance AI claims-triage **domain narrative** (an assistant answering claim questions). Ideas only — re-implemented from scratch in Quarkus LangChain4j + MCP (their AI calls went OpenAI-direct; ours use LangChain4j AI services and MCP tool servers). |
| `agentops-in-prod-showroom` (rhpds) | Agentic AI on OpenShift apps (`parasol-agent`); AI-Assisted Development on OpenShift | The "**tools are your APIs**" + tool-call-tracing + "**review the agent critically**" framing (the agent reports which tools it called; you read the trace and verify its claims). Framing only — none of its Python/LangGraph/MLflow tech was ported; M24 re-points it at the platform MCP server. |
| `app-connectivity-workshop` (redhat-ads-tech) | Resilience, Multi-Cluster & DR (Red Hat Service Interconnect `[ADD-ON]` section) | The Virtual Application Network narrative and the Skupper v2 `Site` / `Connector` / `Listener` / `AccessGrant`→`AccessToken` resource shapes — re-homed to Parasol's claims service across two simulated sites. Ideas + CR shapes only; re-verified live on a current cluster. |
| Red Hat `openshift/starter-guides` | Ways to Build & Deliver Apps | The Source-to-Image narrative arc (source → builder image → running app) and the S2I-versus-Dockerfile framing. Narrative only — every step is freshly built and re-verified on a live cluster; the Parasol apps, the PostgreSQL catalog template, and the build flows are original. |
| `rcarrata/devsecops-demo` (Apache-2.0) | Pipelines Fundamentals, Application Security Testing & Trusted Software Supply Chain — DevSecOps pipeline | The staged security-gate-at-every-stage arc, the block-the-bad-image + fix-image remediation beat, and the `roxctl deployment check` and ZAP DAST stages — re-implemented on our modern stack (in-cluster Gitea, internal registry, Quarkus Parasol claims, and current tool versions: SonarQube Community Build / Trivy / ZAP / RHACS). No code ported. |
| *(further rows populated as modules reach Definition of Done)* | | |

Maintained as part of Phase 6 assembly; contributions welcome via PR.
