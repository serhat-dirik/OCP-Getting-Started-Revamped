# policy-docs (MCP server)

An **MCP server** that exposes **RAG-style retrieval** over a small, seeded corpus of
Parasol Insurance policy documents as tools. The `parasol-agent` calls `search_policies`
to *ground* its answers about coverage, deductibles, documentation, claim workflow, SLAs
and payout timing — the "**ground it with RAG over Parasol policy docs**" beat of
**M23 — Agentic AI on OpenShift**.

Small enough to read in ten minutes: one corpus, one retriever, one tools class.

## Tools

| Tool (MCP name)    | Arguments                       | Returns                                                        |
|--------------------|---------------------------------|----------------------------------------------------------------|
| `search_policies`  | `query`, `maxResults` (opt, ≤8) | Top matching policy passages (id, title, category, score, text) |
| `get_policy`       | `policyId`                      | One policy document in full, or a not-found message            |
| `list_policies`    | —                               | The catalog (id, title, category) of all documents            |

## Retrieval is deterministic and vector-free (on purpose)

The corpus is **eight fixed documents** embedded in code (`PolicyCorpus`), and
`search_policies` ranks them with a transparent **weighted term-frequency** score
(title matches weigh more than body matches). No embeddings, no vector store, no model
call — so the same query returns the **same** passages every time, which is what the
"grounded vs ungrounded / RAG honestly" teaching beat needs at temperature 0.

> The production **pgvector / Milvus** retriever is a later **platform phase**. When it
> lands it slots in behind the *same* `search_policies` tool contract — the agent does not
> change. Keeping the app-layer retriever simple is deliberate, not a shortcut.

Several documents (`POL-CLAIM-01..03`) describe the claim workflow statuses, review SLAs
and payout timing, so the agent can **combine** a policy lookup here with a `claims-db`
tool call (e.g. "claim CLM-1004 is Denied — what does Denied mean and could it still be
paid?").

## MCP endpoint

Provided by `quarkus-mcp-server-http`:

- **Streamable HTTP**: `POST /mcp`
- **Legacy SSE**: `GET /mcp/sse`  ← what `parasol-agent`'s LangChain4j MCP client connects to

Wired in the agent as `quarkus.langchain4j.mcp.policy-docs.url=http://policy-docs:8080/mcp/sse`.

## Tech

- **Quarkus 3.33 LTS** (`3.33.2.1`), **Java 21**, JVM `fast-jar`.
- **`io.quarkiverse.mcp:quarkus-mcp-server-http` 1.13.1** (Quarkus 3.33.2).
- No database, no external dependency — pure in-memory retrieval.
- Health (`/q/health/*`), Prometheus metrics (`/q/metrics`) and OpenTelemetry tracing
  (exporter off by default) are **on by default** — curriculum (M11/M12).

## Local development

```bash
# Live-reload dev mode; listens on 8082 in %dev so all three M23 services coexist.
./mvnw quarkus:dev
curl -s localhost:8082/q/health/ready
```

## Building the image in-cluster

```bash
oc new-build --binary --strategy=docker --name=policy-docs -n ogsr-parasol-images
oc start-build policy-docs --from-dir=apps/mcp-servers/policy-docs --follow -n ogsr-parasol-images
```

`openshift/buildconfig.yaml` defines the Git-strategy `BuildConfig` (`policy-docs-git`) for
later CI rebuilds. Image tags are immutable per release.

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` → `ubi9/openjdk-21-runtime:1.23`.
- Runtime runs as numeric non-root **USER 185**, port **8080**.
