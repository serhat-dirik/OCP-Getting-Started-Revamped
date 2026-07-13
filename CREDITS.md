# Credits

This workshop stands on earlier Red Hat enablement assets and community workshops (Decision D18: reuse-with-credit).
Patterns, narratives, and assets are adapted with visible credit; **no deprecated-era technical steps are ever ported** — every step is re-verified against current product documentation and a live cluster.

Per-module credits appear in each module's wrap-up page. The full list accretes here as modules are built.

| Source | Used in | What was adopted |
|---|---|---|
| Konveyor `customers-tomcat-legacy` (Apache-2.0; via the Red Hat Modern Application Development workshop `rh-mad-workshop`) | M22 — Application Modernization | The `parasol-legacy-claims` migration target: Spring-on-Tomcat WAR structure, the hardcoded-configuration anti-patterns, and the assess → analyze → refactor → deploy arc — re-themed to the Parasol claims domain (insurance domain original). |
| `parasol-insurance` (redhat-ads-tech) | M23 apps (`parasol-agent`, `mcp-servers/claims-db`, `mcp-servers/policy-docs`) | The Parasol Insurance AI claims-triage **domain narrative** (an assistant answering claim questions). Ideas only — re-implemented from scratch in Quarkus LangChain4j + MCP (their AI calls went OpenAI-direct; ours use LangChain4j AI services and MCP tool servers). |
| `agentops-in-prod-showroom` (rhpds) | M23 apps (`parasol-agent`) | The "**tools are your APIs**" + tool-call-tracing framing (agent reports which tools it called, token usage). Framing only — none of its Python/LangGraph/MLflow tech was ported. |
| *(further rows populated as modules reach Definition of Done)* | | |

Maintained as part of Phase 6 assembly; contributions welcome via PR.
