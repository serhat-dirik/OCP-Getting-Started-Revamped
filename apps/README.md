# apps/ — Parasol Insurance sample services

The applications behind the workshop's story: Parasol Insurance modernizing its claims
platform. Every module works on these same services, so nothing is a throwaway example.

They are deliberately small — a service should fit in your head in ten minutes. Quarkus and
Java 21 unless a module needs a second runtime, UBI-based, built inside the cluster. Health
probes, metrics, tracing and externalized configuration are on by default, because several
modules teach by inspecting them. Seeded data is deterministic (stable claim IDs like
`CLM-1001`), so the lab text can quote exact values.

| Service | Runtime | What it is | Used by |
|---|---|---|---|
| **parasol-web** | Quarkus (Java 21) | The claims portal frontend, and the first app anyone deploys. Self-contained — no backend needed. | Platform Orientation, and most modules that need a browser-facing app |
| **parasol-claims** | Quarkus (Java 21) | The core claims service: REST API on PostgreSQL, owning the `CLM-1001`–`CLM-1030` dataset. The main character — most modules act on this one. | Nearly every module |
| **parasol-notifications** | Node.js or Python | The polyglot moment: a second runtime, so build strategies can be compared side by side. Kept intentionally simple. | Ways to Build & Deliver Apps · Packaging & Distributing Your App |
| **parasol-fraud** | Quarkus (Java 21) | A bearer-only fraud-scoring service. It is the token-exchange target that proves an escalation gets refused. | Securing Apps with Keycloak · Service Mesh |
| **parasol-legacy-claims** | Legacy Java on JBoss Web Server / Tomcat | Deliberately un-modern — servlet-era patterns, hardcoded configuration. This is the thing being migrated. | Application Modernization |
| **parasol-agent** | Quarkus + LangChain4j | The AI agent: model calls, RAG over policy documents, and MCP tool use. | Agentic AI on OpenShift |
| **mcp-servers/claims-db** | Quarkus (MCP server) | Exposes the claims dataset to the agent as callable tools. | Agentic AI on OpenShift |
| **mcp-servers/policy-docs** | Quarkus (MCP server) | Retrieves policy documents, so an answer can be grounded in a source. | Agentic AI on OpenShift |
| **mcp-agent-cli** | Quarkus + LangChain4j | An assistant-neutral MCP client. Prompts a model with cluster tools bound and prints the full tool-call trace. Read-only unless told otherwise. | AI-Assisted Development |
| **parasol-service-template** | Backstage template + Quarkus skeleton | Not a running service — the golden-path template that scaffolds a brand-new Parasol service. | Developer Hub & Golden Paths |

Modules are named rather than numbered here on purpose: a module's number is just its position
in the catalog, so it changes whenever the catalog does.

## Reading a service

Each service has its own `README.md` covering what it does, its endpoints, how it builds in the
cluster, and how to run it locally.

Where a module teaches by fixing something, the service ships that fault on purpose and its
README says so under **"Intentional flaws — do not fix"**. If a service looks wrong, check there
before correcting it.
