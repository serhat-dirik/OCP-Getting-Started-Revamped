# parasol-agent

The Parasol Insurance **agentic AI service**: a Quarkus + LangChain4j app that answers
claims and policy questions by calling an **OpenAI-compatible model** (MaaS) and using the
**`claims-db`** and **`policy-docs`** MCP servers as its **tools**. It is the star of
**M23 — Agentic AI on OpenShift** and the concrete payoff of the module's thesis: *an AI
app is just an app* — same probes, metrics, tracing, config, and golden path as every other
Parasol service.

Small enough to read in ten minutes: one AI-service interface, one REST resource.

## Endpoints

| Method + path       | Purpose                                                                           |
|---------------------|-----------------------------------------------------------------------------------|
| `POST /agent/ask`   | Ask a question; returns the answer, **which tools the agent called** (name + args + result), and token usage |
| `GET /agent/info`   | The model + MCP wiring the agent is configured with (no model call)               |
| `GET /q/health/live` · `/q/health/ready` | Liveness / readiness. **Readiness also pings both MCP servers**, so a Ready agent has proven its tool wiring. |
| `GET /q/metrics`    | Prometheus metrics (Micrometer) — request latency + LangChain4j model/tool metrics |

### `POST /agent/ask`

```bash
curl -sS localhost:8080/agent/ask -H 'content-type: application/json' \
  -d '{"question":"What is the status of claim CLM-1001?"}' | jq
```

```json
{
  "question": "What is the status of claim CLM-1001?",
  "answer": "Claim CLM-1001 (Alice Nguyen, auto) is currently UnderReview, for $4200.00, handled by adjuster Rebecca Torres.",
  "toolCalls": [
    { "tool": "get_claim", "arguments": "{\"claimNumber\":\"CLM-1001\"}",
      "result": "Claim CLM-1001: claimant Alice Nguyen, line of business auto, status UnderReview, amount 4200.00 USD, adjuster Rebecca Torres, incident date 2026-05-14." }
  ],
  "model": "qwen3-14b",
  "tokenUsage": { "inputTokens": 512, "outputTokens": 61, "totalTokens": 573 }
}
```

If the model call fails (for example the short-lived MaaS key has expired → HTTP 401), the
endpoint returns a clean `502` with `"authFailure": true` instead of a stack trace — the
agent **degrades gracefully**.

## How the agent wires MCP tools + the model

- **`ClaimsAssistant`** is a `@RegisterAiService` interface. `@McpToolBox({"claims-db",
  "policy-docs"})` hands the model both MCP servers' tools; LangChain4j discovers them over
  **HTTP-SSE** at startup and lets the model choose which to call. The method returns a
  LangChain4j `Result<String>`, which is how `/agent/ask` reports the answer **and** the exact
  `toolExecutions()` + `tokenUsage()`.
- The service is **stateless** (`NoChatMemoryProviderSupplier`) and runs at **temperature 0**,
  so answers are reproducible — the workshop demo lands the same way every time.

## Configuration — model-agnostic, env-driven

Nothing about a specific model or endpoint is baked in. The workshop injects three values at
deploy time (committed defaults are harmless local-dev placeholders, **never** workshop infra):

| Env var             | Maps to                                              | Example                                    |
|---------------------|------------------------------------------------------|--------------------------------------------|
| `GENAI_ENDPOINT`    | `quarkus.langchain4j.openai.base-url`                | `https://maas-example.apps.<domain>/v1`    |
| `GENAI_API_KEY`     | `quarkus.langchain4j.openai.api-key`                 | `sk-…` (MaaS virtual key; short-lived)     |
| `GENAI_MODEL`       | `quarkus.langchain4j.openai.chat-model.model-name`   | `qwen3-14b` (cluster 1) / `llama-scout-17b` (cluster 2) |
| `CLAIMS_DB_MCP_URL` | `quarkus.langchain4j.mcp.claims-db.url`              | `http://claims-db:8080/mcp/sse`            |
| `POLICY_DOCS_MCP_URL` | `quarkus.langchain4j.mcp.policy-docs.url`          | `http://policy-docs:8080/mcp/sse`          |

The same image runs against any OpenAI-compatible model — only these env values change.
`OTEL_EXPORTER_OTLP_ENDPOINT` + `QUARKUS_OTEL_SDK_DISABLED=false` turn on tracing to Tempo (M12).

## Tech

- **Quarkus 3.33 LTS** (`3.33.2.1`), **Java 21**, JVM `fast-jar`.
- **Quarkiverse LangChain4j 1.10.0** (`quarkus-langchain4j-openai` + `quarkus-langchain4j-mcp`,
  managed by `quarkus-langchain4j-bom`) — the **LangChain4j-direct-to-MaaS** graded path from
  the M23 build note (Llama Stack is Tech Preview; the Responses API is Developer Preview).
- Health, Prometheus metrics, OpenTelemetry (exporter off by default) — **on by default**, curriculum.

## Local development

Needs an OpenAI-compatible endpoint and the two MCP servers. Start the MCP servers first
(`claims-db` on 8081, `policy-docs` on 8082 in `%dev`), then:

```bash
export GENAI_ENDPOINT=http://localhost:11434/v1   # e.g. a local Ollama, or a MaaS URL
export GENAI_API_KEY=sk-...                        # your key
export GENAI_MODEL=llama3.2                        # any served model
./mvnw quarkus:dev
curl -sS localhost:8080/agent/ask -H 'content-type: application/json' \
  -d '{"question":"List the denied claims and explain what Denied means."}' | jq
```

`./mvnw test` runs fast and fully offline — plain JUnit tests over the error-handling logic
(auth-failure detection, cause unwrapping, response mapping). The end-to-end REST path is
validated by the on-cluster smoke instead, because it needs a live model and both MCP servers
running (booting the app without them makes the MCP client block retrying dead endpoints).

## Building the image in-cluster

```bash
oc new-build --binary --strategy=docker --name=parasol-agent -n parasol-images
oc start-build parasol-agent --from-dir=apps/parasol-agent --follow -n parasol-images
```

`openshift/buildconfig.yaml` defines the Git-strategy `BuildConfig` (`parasol-agent-git`) for
later CI rebuilds. Image tags are immutable per release.

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` → `ubi9/openjdk-21-runtime:1.23`.
- Runtime runs as numeric non-root **USER 185**, port **8080**.
