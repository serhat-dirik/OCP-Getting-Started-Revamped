# claims-db (MCP server)

An **MCP server** that exposes the Parasol claims dataset as tools, so the
`parasol-agent` (and any MCP-capable client) can answer claim questions by
*calling tools* rather than by having the data prompt-stuffed into the model.
This is the "**MCP tools are your APIs**" beat of **M23 — Agentic AI on OpenShift**.

Small enough to read in ten minutes: two entities, one repository, one tools class.

## Tools

| Tool (MCP name)         | Arguments            | Returns                                                             |
|-------------------------|----------------------|--------------------------------------------------------------------|
| `get_claim`             | `claimNumber`        | One grounded sentence: claimant, type, status, amount, adjuster, date |
| `list_claims_by_status` | `status`             | JSON array of matching claims (`Submitted`/`UnderReview`/`Approved`/`Denied`) |
| `get_claim_history`     | `claimNumber`        | The claim's audit timeline, oldest event first                     |

`claimNumber` is normalized leniently (`1001`, `clm-1001`, `CLM-1001` all resolve);
`status` is matched case-insensitively to the four canonical values. The data is the
deterministic **`CLM-1001..CLM-1030`** dataset — the same shape and seed as
`parasol-claims` — so tool output is byte-for-byte reproducible (temperature-0 demos
depend on it).

## MCP endpoint

Provided by the Quarkus MCP Server extension (`quarkus-mcp-server-http`):

- **Streamable HTTP**: `POST /mcp`
- **Legacy SSE**: `GET /mcp/sse`  ← what `parasol-agent`'s LangChain4j MCP client connects to

The agent is wired with `quarkus.langchain4j.mcp.claims-db.url=http://claims-db:8080/mcp/sse`.

## Tech

- **Quarkus 3.33 LTS** (`quarkus.platform.version = 3.33.2.1`), **Java 21**, JVM `fast-jar`.
- **`io.quarkiverse.mcp:quarkus-mcp-server-http` 1.13.1** (built against Quarkus 3.33.2;
  the artifact was renamed from `-sse` in 1.8.0, and `-http` serves both `/mcp` and the
  legacy `/mcp/sse`).
- `quarkus-hibernate-orm-panache` + `quarkus-jdbc-h2` — an **embedded H2** seeded at boot
  from `import.sql`. The server is self-contained and deterministic (no external DB pod),
  which keeps M23 module-independent.
- Health (`/q/health/*`), Prometheus metrics (`/q/metrics`), and OpenTelemetry tracing
  (exporter off by default) are **on by default** — they are curriculum (M11/M12).

## Data source — self-contained by default, PostgreSQL-overridable

The default is an in-memory H2 seeded from `import.sql`. To back the tools with the shared
claims **PostgreSQL** instead (an option the M23 entry-state may choose), override at deploy:

```
QUARKUS_DATASOURCE_DB_KIND=postgresql
QUARKUS_DATASOURCE_JDBC_URL=jdbc:postgresql://parasol-db:5432/parasol
QUARKUS_DATASOURCE_USERNAME=parasol
QUARKUS_DATASOURCE_PASSWORD=parasol
QUARKUS_HIBERNATE_ORM_SCHEMA_MANAGEMENT_STRATEGY=none
```

and add `quarkus-jdbc-postgresql` to the `pom.xml` (kept out of the default build so the
self-contained image stays lean).

## Local development

```bash
# Live-reload dev mode; the MCP server listens on 8081 in %dev so all three M23
# services (claims-db 8081, policy-docs 8082, parasol-agent 8080) coexist locally.
./mvnw quarkus:dev

# List the tools over SSE (raw MCP JSON-RPC handshake is done by the client;
# a quick liveness check:)
curl -s localhost:8081/q/health/ready
```

## Building the image in-cluster

Built on the cluster (cluster-first policy). Binary build, then an immutable tag:

```bash
oc new-build --binary --strategy=docker --name=claims-db -n ogsr-parasol-images
oc start-build claims-db --from-dir=apps/mcp-servers/claims-db --follow -n ogsr-parasol-images
```

`openshift/buildconfig.yaml` defines the Git-strategy `BuildConfig` (`claims-db-git`) for
later CI rebuilds. Image tags are immutable per release.

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` (build) →
  `ubi9/openjdk-21-runtime:1.23` (runtime).
- Runtime runs as numeric non-root **USER 185**, port **8080**; files are copied
  `--chown=185:0` and group-readable, so it runs under an arbitrary injected UID.
