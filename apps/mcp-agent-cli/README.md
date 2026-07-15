# mcp-agent-cli

The **assistant-neutral MCP client** for **M24 — AI-Assisted Development on OpenShift**. A small
Quarkus command-mode + LangChain4j CLI that:

1. takes a natural-language **prompt**,
2. connects to a configured **MCP server** over its transport,
3. sends the prompt to an **OpenAI-compatible model (MaaS)** with the MCP server's tools bound,
4. lets the model make tool calls, and
5. prints **the full tool-call trace** (each tool name + arguments + result) **and the final answer**.

It exists so M24 never depends on any attendee licensing a specific IDE assistant: every attendee
gets *this* client. It reuses **parasol-agent's (M23) exact model + MCP wiring**, only re-pointed
from the claims MCP servers to the platform (an OpenShift/Kubernetes MCP server).

Small enough to read in ten minutes: one AI-service interface, one factory, one command, plus the
tracer / read-only filter / formatter that make the trace and the safety posture first-class.

> Cluster integration (deploying the MCP server, the scoped ServiceAccount + RBAC, the seeded broken
> deployment) lands with the **M24 entry state** — it is *not* part of this app. This app is built
> and unit-tested off-cluster.

## The two things it prints

`POST`-free, one shot in, trace + answer out:

```
$ mcp-agent-cli "diagnose why parasol-claims is not Ready in user1-dev"

mcp-agent-cli
  model:     qwen3-14b
  mcp server: http://kubernetes-mcp-server:8080/mcp/sse  (1 wired)
  mode:      READ-ONLY (mutating tools hidden from the model)

TOOL-CALL TRACE (2 calls)
  [1] pods_list
      args:   {"namespace":"user1-dev"}
      result: [{"name":"parasol-claims-6d9c...","ready":"0/1","status":"Running"}]
  [2] resources_get
      args:   {"kind":"Deployment","name":"parasol-claims","namespace":"user1-dev"}
      result:
        ...
        readinessProbe:
          httpGet: { path: /q/health/reddy, port: 8080 }
        ...

read-only: hid 5 mutating tools (RBAC remains the real boundary):
  - pods_delete  (matched 'delete')
  - pods_exec  (matched 'exec')
  - resources_create_or_update  (matched 'create')
  - resources_delete  (matched 'delete')
  - pods_run  (matched 'run')

ANSWER
  parasol-claims is 0/1 Ready because its readinessProbe path is /q/health/reddy, which returns
  404. The correct path is /q/health/ready.
```

The **tool-call trace** is the point: M24 has attendees *watch the tool calls and verify the agent's
claims themselves*. It is always on and needs no collector.

## Read-only-first (the safety posture M24 teaches)

By default the client runs **read-only**: it hides every mutating tool from the model entirely — it
removes the tool's *executor* as well as its spec, so the model can neither see nor invoke it. A tool
is treated as mutating if any whole word-token of its name is a write verb (`create`, `delete`,
`patch`, `apply`, `scale`, `exec`, `run`, …); whole-token matching keeps read tools like
`get_deployment` or `replicasets_list` visible.

**This client-side filter is defense-in-depth, not the security boundary.** As CVE-2026-46519 showed
(a sibling MCP server whose read-only flag filtered tool *discovery* but not *execution*), a
read-only flag is a seatbelt — **RBAC on the MCP server's ServiceAccount is the boundary**. Pass
`--allow-writes` (or set `MCP_READ_ONLY=false`) to offer mutating tools; on the cluster it is then
RBAC, not this flag, that stops a disallowed write.

```
mcp-agent-cli --allow-writes "fix the readiness probe on parasol-claims and roll it out"
```

## Configuration — model-agnostic, env-driven (nothing hardcoded)

Same env contract as parasol-agent for the model + MCP; the committed defaults are harmless local-dev
placeholders, **never** workshop infra and never a real key.

| Env var             | Maps to                                              | Example                                          |
|---------------------|------------------------------------------------------|--------------------------------------------------|
| `GENAI_ENDPOINT`    | `quarkus.langchain4j.openai.base-url`                | `https://maas-example.apps.<domain>/v1`          |
| `GENAI_API_KEY`     | `quarkus.langchain4j.openai.api-key`                 | the MaaS virtual key (short-lived)               |
| `GENAI_MODEL`       | `quarkus.langchain4j.openai.chat-model.model-name`   | `qwen3-14b` / `llama-scout-17b`                  |
| `MCP_SERVER_URL`    | `quarkus.langchain4j.mcp.platform.url`               | `http://kubernetes-mcp-server:8080/mcp/sse`      |
| `MCP_READ_ONLY`     | `mcp-agent.read-only` (default `true`)               | `false` to allow writes                          |
| `MCP_MAX_STEPS`     | `mcp-agent.max-steps` (default `10`)                 | caps the agentic loop (bounds MaaS token spend)  |
| `MCP_MUTATING_TOKENS` | `mcp-agent.mutating-tokens` (blank = built-in list) | `delete,scale,exec` to override the write verbs  |

CLI flags: `--allow-writes` / `--read-only` (override the configured default), plus the standard
`--help` / `--version`.

`OTEL_EXPORTER_OTLP_ENDPOINT` + `QUARKUS_OTEL_SDK_DISABLED=false` turn on tracing to Tempo (each
model call + MCP tool call becomes a span) — optional; the printed trace is the always-on audit
surface.

## How it wires MCP tools + the model (reused from M23)

- The model is the **quarkus-langchain4j OpenAI** bean configured by `quarkus.langchain4j.openai.*`
  (`GENAI_*`) — OpenAI-compatible, so the same code runs against any MaaS model.
- The MCP server is one **quarkus-langchain4j MCP** client named `platform`, configured by
  `quarkus.langchain4j.mcp.platform.*` (`MCP_SERVER_URL`), connected over HTTP/SSE — the same
  transport parasol-agent uses against `claims-db`.
- `AgentFactory` assembles the agent programmatically with LangChain4j's `AiServices` builder:
  the injected model + the MCP tools (wrapped in the read-only filter when read-only) + a step cap.
  Building it in code (rather than `@RegisterAiService`) is deliberate — it lets the read-only filter
  slot in and lets the unit tests exercise the very same construction path with a mocked model and a
  fake MCP tool provider.
- `ToolCallTracer` is a LangChain4j `ChatModelListener` (auto-attached to the model by
  quarkus-langchain4j, exactly like parasol-agent's recorder). It records each MCP tool call's name +
  arguments and pairs the result back when it returns — LangChain4j's `Result.toolExecutions()`
  covers only local `@Tool` beans, never MCP tools, so a listener is the way to see them.

The agent holds **only** the MCP URL and the model key — **no kubeconfig, no admin token**. The MCP
server runs as the scoped `mcp-agent` ServiceAccount; RBAC on that SA is the boundary (ties M14).

## Configuration failures degrade gracefully

If the model call fails — most commonly the short-lived MaaS key has expired → HTTP 401 — the CLI
prints whatever tool calls it already traced, then one clean line
(`error: model authentication failed - check the MaaS key (GENAI_API_KEY); it may be expired.`) and
exits `1`, instead of dumping a stack trace. Exit codes: `0` success, `1` model/run failure, `2` bad
usage.

## Tech

- **Quarkus 3.33 LTS** (`3.33.2.1`), **Java 21**, JVM `fast-jar`, **command mode** (picocli) — no
  HTTP server (so, deliberately, no health/metrics endpoint: a one-shot CLI has nothing to expose
  them on; its inspectable instrumentation is the printed tool-call trace).
- **Quarkiverse LangChain4j 1.10.0** (`quarkus-langchain4j-openai` + `quarkus-langchain4j-mcp`,
  managed by `quarkus-langchain4j-bom`) — the exact stack parasol-agent proved in M23.
- OpenTelemetry (exporter off by default) — optional agent tracing.

## Local development

Needs an OpenAI-compatible endpoint and a reachable MCP server.

```bash
export GENAI_ENDPOINT=http://localhost:11434/v1   # e.g. a local Ollama, or a MaaS URL
export GENAI_API_KEY=sk-local-dev                  # your key
export GENAI_MODEL=llama3.2                         # any served model
export MCP_SERVER_URL=http://localhost:8080/mcp/sse # a local kubernetes-mcp-server (npx/binary/container)

# Run once (Quarkus command mode passes the args straight to the CLI):
./mvnw -q quarkus:dev -Dquarkus.args='"list the pods in user1-dev"'
# or against the built jar:
./mvnw -q -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar "list the pods in user1-dev"
```

`./mvnw test` runs fast and fully offline. The tests **mock the model and the MCP server** (no MaaS,
no cluster) to prove the tool-call orchestration, the trace capture/formatting, and the read-only
filtering:

- `AgentOrchestrationTest` — drives the tool-execution loop with a scripted model + a fake MCP tool
  provider: the read tool is executed, the result is fed back, the answer is returned, the trace is
  captured, and under read-only the write tool is neither offered nor run.
- `ToolCallTracerTest` — the tracer pairs each tool result back to its request (by id, then name).
- `ReadOnlyToolPolicyTest` / `ReadOnlyToolFilterTest` — the read-only classifier and the filter that
  removes mutating tools (spec + executor) and reports what it hid.
- `TraceFormatterTest` — the exact printed trace shape.
- `AgentCommandTest` — graceful auth-failure detection (the expired-key path).

> The tests use plain JUnit (not `@QuarkusTest`) — like parasol-agent — because booting the app
> offline makes the LangChain4j MCP client block retrying the unreachable endpoint. They build a
> vanilla LangChain4j tool loop over the real collaborators (see `ToolLoopHarness`); production uses
> the real Quarkus `AiServices`.

## Building the image in-cluster

```bash
oc new-build --binary --strategy=docker --name=mcp-agent-cli -n parasol-images
oc start-build mcp-agent-cli --from-dir=apps/mcp-agent-cli --follow -n parasol-images
```

`openshift/buildconfig.yaml` defines the Git-strategy `BuildConfig` (`mcp-agent-cli-git`) for later
CI rebuilds. Image tags are immutable per release.

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` → `ubi9/openjdk-21-runtime:1.23`.
- Runtime runs as numeric non-root **USER 185**. No `EXPOSE` — it is a CLI; container args are the
  prompt + flags.
