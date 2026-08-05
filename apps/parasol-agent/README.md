# parasol-agent

The Parasol Insurance **agentic AI service**: a Quarkus + LangChain4j application that answers
claims and policy questions by calling an **OpenAI-compatible model** and using the
**`claims-db`** and **`policy-docs`** MCP servers as its tools.

It is the centrepiece of *Agentic AI on OpenShift*, and the payoff of that module's argument —
**an AI app is just an app**: same probes, metrics, tracing, configuration and golden path as
every other Parasol service.

One AI-service interface and one REST resource. Ten minutes to read.

## Endpoints

| Method + path | Purpose |
|---|---|
| `POST /agent/ask` | Ask a question. Returns the answer, **which tools the agent called** (name, arguments, result), and token usage |
| `GET /agent/info` | The model and MCP wiring in effect, **and the grounding prompt this pod is running** — makes no model call |
| `GET /q/health/live` · `/q/health/ready` | Liveness / readiness. **Readiness also pings both MCP servers**, so a Ready agent has proven its tool wiring |
| `GET /q/metrics` | Prometheus metrics, including model and tool metrics |

### `POST /agent/ask`

```bash
curl -sS localhost:8080/agent/ask -H 'content-type: application/json' \
  -d '{"question":"What is the status of claim CLM-1001?"}' | jq
```

The answer below is what a **grounded** agent returns. Whether it grounds at all depends on the
system prompt in force — see *Grounding is configuration*.

```json
{
  "question": "What is the status of claim CLM-1001?",
  "answer": "Claim CLM-1001 (Alice Nguyen, auto) is currently UnderReview, for $4200.00, handled by adjuster Rebecca Torres.",
  "toolCalls": [
    { "tool": "get_claim", "arguments": "{\"claimNumber\":\"CLM-1001\"}",
      "result": "Claim CLM-1001: claimant Alice Nguyen, line of business auto, status UnderReview, amount 4200.00 USD, adjuster Rebecca Torres, incident date 2026-05-14." }
  ],
  "model": "llama-scout-17b",
  "tokenUsage": { "inputTokens": 512, "outputTokens": 61, "totalTokens": 573 }
}
```

If the model call fails — an expired API key returning 401, for instance — the endpoint returns a
clean `502` with `"authFailure": true` rather than a stack trace. The agent degrades gracefully.

## How it wires the model and its tools

- **`ClaimsAssistant`** is a `@RegisterAiService` interface. `@McpToolBox({"claims-db",
  "policy-docs"})` hands the model both MCP servers' tools; LangChain4j discovers them over
  HTTP-SSE at startup and lets the model choose which to call. The method returns a
  `Result<String>`, which is how `/agent/ask` can report the answer **and** the exact tool
  executions and token usage.
- **There is no `@SystemMessage` on it.** The system prompt comes from `GroundingPrompt`, wired via
  `@RegisterAiService(systemMessageProviderSupplier = GroundingPrompt.class)` — see *Grounding is
  configuration* below.
- The service is **stateless per request** and runs at **temperature 0**, so answers are
  reproducible and a demo lands the same way every time. Each call gets a fresh memory ID, so no
  two requests share history; the per-request memory window exists only to hold the intermediate
  messages of a tool-calling round trip — model requests a tool, the result is fed back, the model
  answers.

## Configuration

Nothing about a specific model or endpoint is baked in. The workshop injects these at deploy
time; the committed defaults are harmless local-development placeholders.

| Environment variable | Sets | Example |
|---|---|---|
| `GENAI_ENDPOINT` | Model base URL | `https://maas-example.apps.<domain>/v1` |
| `GENAI_API_KEY` | Model API key | a short-lived key |
| `GENAI_MODEL` | Model name | `llama-scout-17b` |
| `CLAIMS_DB_MCP_URL` | Claims MCP server | `http://claims-db:8080/mcp/sse` |
| `POLICY_DOCS_MCP_URL` | Policy MCP server | `http://policy-docs:8080/mcp/sse` |
| `PARASOL_AGENT_GROUNDING_PROMPT` | The agent's system prompt | see below — unset means the built-in default |

The same image runs against any OpenAI-compatible model — only these values change. Setting
`OTEL_EXPORTER_OTLP_ENDPOINT` and `QUARKUS_OTEL_SDK_DISABLED=false` turns on tracing, which is
what *Observability, Health & Scale* reads.

### Grounding is configuration

The system prompt decides whether this agent **calls a tool** or answers from the model's own
weights. That makes it the single most consequential setting in the service, so it is not compiled
in: `GroundingPrompt` reads it from `parasol.agent.grounding-prompt`
(`PARASOL_AGENT_GROUNDING_PROMPT`), which on OpenShift comes from a ConfigMap — the same
externalized-config idiom that feeds it `GENAI_MODEL`. Tuning an agent's behaviour becomes a
ConfigMap edit and a rollout instead of a rebuild.

Three things follow from that, and all three are deliberate:

- **The image is correct on its own.** With nothing configured, `GroundingPrompt.DEFAULT_PROMPT`
  applies — a strong prompt that names the tools and forbids inventing what a tool did not return.
  `quarkus dev` and a bare `podman run` ground properly with no ConfigMap in sight. A blank or
  whitespace-only value counts as unset, so a stray empty env var cannot leave the agent with no
  system message at all.
- **A ConfigMap edit needs a rollout.** The prompt arrives as an environment variable, and an
  environment variable cannot change under a running pod. `GET /agent/info` reports
  `groundingPrompt` and `groundingPromptSource` (`config …` or `built-in default`) precisely so you
  can tell what a pod is *actually* running rather than what you last saved.
- **`GroundingPrompt` is not a CDI bean, on purpose.** `AiServicesRecorder` instantiates the
  configured provider reflectively — `loadClass(name).getConstructor().newInstance()` — so the class
  keeps a public no-arg constructor and reads config through `ConfigProvider`. Do not "fix" this by
  adding `@ApplicationScoped` and constructor injection. Checked against quarkus-langchain4j 1.10.0's
  own bytecode: `RegisterAiService.BeanIfExistsSystemMessageProviderSupplier` looks like the right
  answer and is not one — the build accepts it, wires nothing, and the marker class's own
  `getSystemMessage` throws `UnsupportedOperationException("should never be called")`.

The workshop's `agentic-ai` entry state deliberately ships a **weak** prompt in
`cm/parasol-agent-grounding` — one that never mentions tools — because rewriting it is the module's
exercise. That weakness lives in the entry state, not in this app; see the entry chart's
`templates/_helpers.tpl` for both texts and the reasoning.

### Choosing a model is a teaching decision, not just configuration

The wiring is model-agnostic. The teaching is not.

The module's whole point is that the agent **calls tools** and grounds its answers in real
records, so the model must be one that **elects to call a tool on its own**. A model that only
calls a tool when a specific function is forced by name is not good enough.

This has been measured by replaying the agent's exact wire payload — system prompt and all six
MCP tool schemas — at temperature 0:

| Model | Result |
|---|---|
| `llama-scout-17b` | Grounds correctly. The module's captured outputs were produced on it. |
| `deepseek-r1-distill-qwen-14b` | **Never emits a tool call.** It narrates one in prose instead — *"To determine the status of claim CLM-1001, I will use the claims tool…"* — and then invents the record. **Do not point the workshop at it.** |

Sharpening the system prompt, shortening it, and sending `tool_choice: "auto"` explicitly were
all tried against the second model. None of them helped.

Two request-level notes for anyone debugging a model that will not call tools:

- `tool_choice: "required"` can break a serving endpoint outright — the connection closes with no
  response, rather than returning a clean error.
- Forcing a named function does work, and returns correct arguments. That proves the model *can*
  emit a call and simply never *chooses* to.

**That named-function forcing is deliberately not used here.** Forcing a tool on every request
would fake the very grounding the module asks attendees to verify, and it would erase the
break-and-fix beat where the agent comes back with no tool calls at all.
Grounding is engineered through the system prompt and the tool schemas — and, when a model cannot
elect a tool at all, by choosing a different model.

## Tech

- **Quarkus 3.33 LTS**, **Java 21**, JVM `fast-jar`.
- **Quarkiverse LangChain4j** (`quarkus-langchain4j-openai` and `quarkus-langchain4j-mcp`),
  talking directly to an OpenAI-compatible endpoint.
- Health, Prometheus metrics and OpenTelemetry are on by default — curriculum, not extras.

## Local development

Needs an OpenAI-compatible endpoint and both MCP servers. Start those first (`claims-db` on 8081,
`policy-docs` on 8082 in dev mode), then:

```bash
export GENAI_ENDPOINT=http://localhost:11434/v1   # a local Ollama, or any compatible URL
export GENAI_API_KEY=...
export GENAI_MODEL=llama3.2
# Optional: try a different grounding without touching the code. Unset = the built-in default.
# export PARASOL_AGENT_GROUNDING_PROMPT="You are the Parasol claims assistant. Always call a tool."
./mvnw quarkus:dev

curl -sS localhost:8080/agent/ask -H 'content-type: application/json' \
  -d '{"question":"List the denied claims and explain what Denied means."}' | jq
```

`./mvnw test` runs fast and fully offline — plain JUnit over the error-handling logic. The
end-to-end REST path is covered by the on-cluster smoke test instead, because it needs a live
model and both MCP servers; booting the app without them makes the MCP client block retrying
dead endpoints.

## How the image is built

GitOps builds it — there is no manual step. A BuildConfig and ImageStream in
`gitops/workshop-config/templates/parasol-images-build.yaml` clone this repository and push
`parasol-agent:latest`, with `1.0` as an alias. The Git source follows `repo_url` from your
`vars.yaml`, so **a fork install builds this image from the fork**.

```bash
# Rebuild after editing this app — moves latest and the 1.0 alias together:
oc start-build parasol-agent -n ogsr-parasol-images --follow
```

## Container notes

- UBI9 multi-stage build: `ubi9/openjdk-21` for the build, `ubi9/openjdk-21-runtime` at runtime.
- Runs as numeric non-root **USER 185** on port **8080**.
