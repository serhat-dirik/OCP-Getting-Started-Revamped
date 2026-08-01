# mcp-agent-cli

The **assistant-neutral MCP client** used by *AI-Assisted Development on OpenShift*. A small
Quarkus command-line application that:

1. takes a natural-language **prompt**,
2. connects to a configured **MCP server**,
3. sends the prompt to an **OpenAI-compatible model** with that server's tools bound,
4. lets the model make tool calls, and
5. prints **the full tool-call trace** — each tool name, its arguments, its result — followed by
   the final answer.

It exists so the module never depends on any attendee licensing a particular IDE assistant.
Everyone gets this client. It reuses `parasol-agent`'s model and MCP wiring, only re-pointed from
the claims servers to a Kubernetes/OpenShift MCP server.

One AI-service interface, one factory, one command, plus the tracer, the read-only filter and the
formatter that make the trace and the safety posture first-class.

> Deploying the MCP server, its scoped ServiceAccount and RBAC, and the deliberately broken
> deployment to diagnose all belong to that module's environment, not to this application. This
> app is built and unit-tested off-cluster.

## What it prints

```
$ mcp-agent-cli "diagnose why parasol-claims is not Ready in user1-dev"

mcp-agent-cli
  model:      llama-scout-17b
  mcp server: http://kubernetes-mcp-server:8080/sse  (1 wired)
  mode:       READ-ONLY (mutating tools hidden from the model)

TOOL-CALL TRACE (2 calls)
  [1] pods_list
      args:   {"namespace":"user1-dev"}
      result: [{"name":"parasol-claims-6d9c...","ready":"0/1","status":"Running"}]
  [2] resources_get
      args:   {"kind":"Deployment","name":"parasol-claims","namespace":"user1-dev"}
      result:
        readinessProbe:
          httpGet: { path: /q/health/reddy, port: 8080 }

read-only: hid 5 mutating tools (RBAC remains the real boundary):
  - pods_delete, pods_exec, pods_run, resources_create_or_update, resources_delete

ANSWER
  parasol-claims is 0/1 Ready because its readinessProbe path is /q/health/reddy, which returns
  404. The correct path is /q/health/ready.
```

**The trace is the point.** The module has attendees watch the tool calls and verify the agent's
claims for themselves, rather than trusting the answer. It is always on and needs no collector.

## Read-only by default

By default the client runs **read-only**: it hides every mutating tool from the model completely,
removing the tool's executor as well as its description, so the model can neither see nor invoke
it. A tool counts as mutating when any whole word of its name is a write verb — `create`,
`delete`, `patch`, `apply`, `scale`, `exec`, `run` and so on. Matching whole words keeps read
tools like `get_deployment` and `replicasets_list` visible.

**This filter is defence in depth, not the security boundary.** A published CVE in a sibling MCP
server made the distinction concrete: its read-only flag filtered tool *discovery* but not tool
*execution*. A read-only flag is a seatbelt — **RBAC on the MCP server's ServiceAccount is the
boundary.**

Pass `--allow-writes` (or set `MCP_READ_ONLY=false`) to offer mutating tools. On a cluster it is
then RBAC, not this flag, that refuses a disallowed write:

```
mcp-agent-cli --allow-writes "fix the readiness probe on parasol-claims and roll it out"
```

## Configuration

Same environment contract as `parasol-agent` for the model. Committed defaults are harmless
local-development placeholders — never real infrastructure and never a real key.

| Environment variable | Sets | Example |
|---|---|---|
| `GENAI_ENDPOINT` | Model base URL | `https://maas-example.apps.<domain>/v1` |
| `GENAI_API_KEY` | Model API key | a short-lived key |
| `GENAI_MODEL` | Model name | `llama-scout-17b` |
| `MCP_SERVER_URL` | The MCP server | `http://kubernetes-mcp-server:8080/sse` |
| `MCP_READ_ONLY` | Read-only mode (default `true`) | `false` to allow writes |
| `MCP_MAX_STEPS` | Caps the agentic loop (default `10`) | bounds token spend |
| `MCP_MUTATING_TOKENS` | Overrides the write-verb list | `delete,scale,exec` |

Flags: `--allow-writes` / `--read-only`, plus `--help` and `--version`.

Setting `OTEL_EXPORTER_OTLP_ENDPOINT` and `QUARKUS_OTEL_SDK_DISABLED=false` turns on tracing, so
each model call and tool call becomes a span. Optional — the printed trace is the always-on audit
surface.

## How it works

- The model is the LangChain4j OpenAI client, so the same code runs against any compatible
  endpoint.
- The MCP server is a single LangChain4j MCP client named `platform`, connected over HTTP/SSE —
  the same transport `parasol-agent` uses.
- `AgentFactory` assembles the agent programmatically rather than declaratively. That is
  deliberate: it lets the read-only filter slot in, and lets the unit tests exercise the same
  construction path with a mocked model and a fake tool provider.
- `ToolCallTracer` is a LangChain4j chat-model listener. It records each tool call's name and
  arguments and pairs the result back when it returns. A listener is the only way to see MCP tool
  calls — LangChain4j's own `Result.toolExecutions()` covers locally-defined tools only.

The client holds **only** the MCP URL and the model key — no kubeconfig and no admin token. The
MCP server runs as a scoped ServiceAccount, and RBAC on that account is what actually constrains
it.

## When something fails

If the model call fails — most often an expired key returning 401 — the CLI prints whatever tool
calls it already traced, then one clean line naming the cause, and exits. No stack trace.

Exit codes: `0` success, `1` model or run failure, `2` bad usage.

## Tech

- **Quarkus 3.33 LTS**, **Java 21**, JVM `fast-jar`, **command mode** (picocli). No HTTP server —
  and therefore, deliberately, no health or metrics endpoint: a one-shot CLI has nothing to serve
  them on, and its inspectable instrumentation is the printed trace.
- **Quarkiverse LangChain4j** (`quarkus-langchain4j-openai` and `quarkus-langchain4j-mcp`).
- OpenTelemetry, exporter off by default.

## Local development

Needs an OpenAI-compatible endpoint and a reachable MCP server.

```bash
export GENAI_ENDPOINT=http://localhost:11434/v1
export GENAI_API_KEY=...
export GENAI_MODEL=llama3.2
export MCP_SERVER_URL=http://localhost:8080/sse

./mvnw -q quarkus:dev -Dquarkus.args='"list the pods in user1-dev"'

# or against the built jar:
./mvnw -q -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar "list the pods in user1-dev"
```

`./mvnw test` runs fast and fully offline. The tests **mock both the model and the MCP server**,
proving the tool-call orchestration, the trace capture and formatting, and the read-only
filtering:

- `AgentOrchestrationTest` — drives the tool loop with a scripted model and a fake tool provider:
  the read tool runs, its result is fed back, the answer returns, the trace is captured, and under
  read-only the write tool is neither offered nor run.
- `ToolCallTracerTest` — the tracer pairs each result back to its request.
- `ReadOnlyToolPolicyTest` / `ReadOnlyToolFilterTest` — the classifier, and the filter that removes
  mutating tools and reports what it hid.
- `TraceFormatterTest` — the exact printed shape.
- `AgentCommandTest` — the expired-key path.

The tests use plain JUnit rather than `@QuarkusTest`, because booting the app offline makes the
MCP client block retrying an unreachable endpoint. They build a vanilla LangChain4j tool loop over
the real collaborators; production uses the Quarkus one.

## How the image is built

GitOps builds it — there is no manual step. A BuildConfig and ImageStream in
`gitops/workshop-config/templates/parasol-images-build.yaml` clone this repository and push
`mcp-agent-cli:latest`, with `1.0` as an alias. The Git source follows `repo_url` from your
`vars.yaml`, so **a fork install builds this image from the fork**.

```bash
# Rebuild after editing this app — moves latest and the 1.0 alias together:
oc start-build mcp-agent-cli -n ogsr-parasol-images --follow
```

## Container notes

- UBI9 multi-stage build: `ubi9/openjdk-21` for the build, `ubi9/openjdk-21-runtime` at runtime.
- Runs as numeric non-root **USER 185**. No exposed port — it is a CLI, and the container
  arguments are the prompt and its flags.
