# claims-db (MCP server)

An **MCP server** that exposes the Parasol claims dataset as tools, so the
`parasol-agent` (and any MCP-capable client) can answer claim questions by
*calling tools* rather than by having the data prompt-stuffed into the model.
This is the "**MCP tools are your APIs**" beat of the *Agentic AI on OpenShift* module.

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
  which keeps that module independent of the others.
- Health (`/q/health/*`), Prometheus metrics (`/q/metrics`), and OpenTelemetry tracing
  (exporter off by default) are **on by default** — they are curriculum for *Observability, Health & Scale*.

## Data source — self-contained by default, PostgreSQL-overridable

The default is an in-memory H2 seeded from `import.sql`. To back the tools with the shared
claims **PostgreSQL** instead (an option that module may choose), override at deploy:

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
# Live-reload dev mode; the MCP server listens on 8081 in %dev so all three of that module's
# services (claims-db 8081, policy-docs 8082, parasol-agent 8080) coexist locally.
./mvnw quarkus:dev

# List the tools over SSE (raw MCP JSON-RPC handshake is done by the client;
# a quick liveness check:)
curl -s localhost:8081/q/health/ready
```

## Building the image in-cluster

Built declaratively by GitOps, not a manual step: the `claims-db` BuildConfig + ImageStream in
`gitops/workshop-config/templates/parasol-images-build.yaml` (Argo CD `workshop-config` Application)
clones this repo (`contextDir: apps/mcp-servers/claims-db`) and pushes `claims-db:latest`; `1.0` is
a declared ImageStream tag aliasing `latest`, so the `agentic-ai` entry state — which pins it by
full in-cluster-registry spec — resolves without anyone having run a build by hand. The git source
follows `vars.yaml`'s `repo_url` (bootstrap/install.sh -> `parasolImages.build.repoUrl`), so a fork
install builds this image from the fork.

```bash
# Manual rebuild (e.g. after editing this app) — moves latest and the 1.0 alias together:
oc start-build claims-db -n ogsr-parasol-images --follow
```


## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` (build) →
  `ubi9/openjdk-21-runtime:1.23` (runtime).
- Runtime runs as numeric non-root **USER 185**, port **8080**; files are copied
  `--chown=185:0` and group-readable, so it runs under an arbitrary injected UID.
