# apps/ — Parasol Insurance sample services

The application portfolio behind the workshop's running story: Parasol Insurance
modernizing its claims platform. Services are **Quarkus-primary**, small enough
to read in a workshop (a service should fit in your head in ten minutes), UBI-based,
and built in-cluster. Health probes, metrics, OpenTelemetry tracing, and
externalized config are on by default — modules teach by inspecting them — and
seeded data is deterministic (fixed seeds, stable claim IDs like `CLM-1001`) so
lab text can reference exact values.

| Service | Runtime | Role in the story | Introduced |
|---|---|---|---|
| **parasol-web** | Quarkus (Java 21) | Claims-portal web frontend; the first app attendees deploy. Self-contained, no backend. | M01 (now) |
| **parasol-claims** | Quarkus (Java 21) | Core claims service (REST + PostgreSQL). Star of the inner-loop, pipeline, and GitOps modules; owns the full `CLM-1001..CLM-1030` dataset. | M02+ |
| **parasol-notifications** | Node or Python (kept intentionally simple) | The polyglot moment — a second runtime to contrast build strategies. | M02, M25 |
| **parasol-fraud** | Quarkus (Java 21) | Bearer-only fraud-scoring service; the token-exchange target (`aud=fraud`) for the security module. | M29 |
| **parasol-legacy-claims** | Legacy Java on JWS/Tomcat | Deliberately un-modern (servlet-era patterns, hardcoded config) — the modernization target. | M21 |
| **parasol-agent** | Quarkus + LangChain4j | Agentic AI service: model calls, RAG, MCP tool use. | M23 |
| **mcp-servers/** | Quarkus (MCP servers) | MCP servers for the agent: `claims-db` (claims dataset as tools), `policy-docs` (RAG-style policy retrieval). | M23, M24 |
| **mcp-agent-cli** | Quarkus + LangChain4j (picocli) | Assistant-neutral MCP client: prompts a MaaS model with cluster MCP tools bound and prints the full tool-call trace. Read-only by default. | M24 |

Plus **`parasol-service-template/`** — not a running service but the M10
golden-path Backstage Software Template (a `template.yaml` + a buildable Quarkus
JDK-21 `skeleton/`) that scaffolds new Parasol services.

**parasol-web**, **parasol-claims**, **parasol-notifications**, and
**parasol-fraud** exist today (plus the **parasol-service-template** golden path),
as do the M23 agentic-AI trio — **parasol-agent** and the two **mcp-servers/**
(`claims-db`, `policy-docs`); the rest arrive in later waves. Each service carries its own `README.md` (what it
is, endpoints, how it builds in-cluster, local dev) and, where a spec calls for a
teachable flaw, an **"Intentional flaws — do not fix"** section documenting the
deliberate break.

See `../Project-Shared/instructions/02-MODULE-SPECS.md` for the module specs each
service serves, and each service's README for build and run details.
