# Agentic AI on OpenShift

## Slide: A model alone is confidently wrong about YOUR data

- Staff ask all day: "status of this claim?" · "what does our policy say?"
- A model has never seen claim CLM-1004 — asked directly, it INVENTS a status
- Your data is live; a model is a frozen snapshot
- You can't prompt-stuff a database of millions of claims
- The fix is an AGENT: the model does language, your systems provide the FACTS

Notes: Open on the temptation and why it fails. The easy move is to send the question straight to a model — "what is the status of claim CLM-1004?" It fails for structural reasons. The model has never seen claim CLM-1004; it lives in Parasol's claims system, not the training set, so the model guesses — a fluent, plausible, wrong answer. That is hallucination, and for a claim or a payout it is worse than useless. Even if the claim were in the training data, it was Submitted last week and Approved today — a model is a snapshot, your systems are live. And "just paste it into the prompt" does not scale past a demo — real Parasol has millions of claims. An agent solves all three the same way: it calls tools. The model does the language; your systems provide the facts.
Visual: Left panel "Ask the model" — a chat bubble "CLM-1004 is Approved ✓" stamped with a big red "HALLUCINATED — the model never saw this claim." Right panel "Ask the agent" — the same question routed through an agent that calls a get_claim tool, returning "CLM-1004: Denied" stamped green "GROUNDED — from the system of record." Arrow between labeled "tools, not training."

## Slide: The anatomy of an agent

- Not magic, not a model — FOUR parts working together
- Model — reasons and DECIDES which tool to call (model-agnostic; MaaS-served)
- Instructions — the system prompt: "use your tools, never guess, cite the policy id"
- Tools — the MCP servers: claims-db · policy-docs (this is the point)
- Memory — per-request only; with temperature 0, answers are reproducible

Notes: An agent is not a model and not magic — it is four parts working together. The model is the reasoning engine; on this workshop it is served over an OpenAI-compatible Models-as-a-Service endpoint, and the agent is model-agnostic — the same code runs against any served model, only an environment value changes. The instructions are the system prompt that sets the agent's job and rules: use your tools instead of guessing, never invent claim details, cite the policy id you relied on — this is where you encode behaviour, and it is ordinary text you can read and change. The tools are the functions the model may call — the two MCP servers, claims-db and policy-docs — and they are the whole point, because they are how the agent touches your world. Memory is where the multi-step tool conversation is held; Parasol's agent uses a fresh per-request memory, which with temperature 0 keeps answers reproducible.
Visual: The concept diagram agentic-ai-01-agent-anatomy.svg — a rounded "parasol-agent" box containing four labelled parts (Model, Instructions, Tools, Memory), a question arrow in, and a "grounded answer + which tools it called + tokens" arrow out; the Tools part connects out to the two MCP servers.

## Slide: MCP tools are your APIs

- MCP (Model Context Protocol) = the standard adapter over your services
- An MCP SERVER advertises tools (name, args, result); the agent is the CLIENT
- claims-db + policy-docs are plain Deployments — probes, metrics, Services
- New capability = deploy a service + register a tool, NOT retrain a model
- Write the tool once — every MCP-capable agent (and AI-Assisted Development's coding assistant) reuses it

Notes: This is the most important idea in the module: the tools an agent calls are just your services, behind a small standard adapter. MCP — the Model Context Protocol — is that standard. An MCP server advertises a set of tools: a name, the arguments, and what it returns; an MCP client, here the agent, discovers them and lets the model call them. Parasol wraps its claims data and policy search as two MCP servers. Three things follow. A tool is a contract, not a model concern — get_claim returns one grounded sentence, and the model neither knows nor cares whether that came from H2, PostgreSQL, or a mainframe. Tools are ordinary services on the platform — claims-db and policy-docs are plain Deployments with health probes and metrics, exactly like any microservice, so giving the agent a new capability means deploying a service and registering a tool, not retraining a model. And the same tool serves any MCP-capable client — the claims-db server here is reused unchanged in AI-Assisted Development by a coding assistant. Write the tool once; every agent uses it.
Visual: The concept diagram agentic-ai-02-mcp-tools.svg — the user posting to parasol-agent (the MCP client) inside a namespace box; the agent making tool calls over HTTP-SSE to claims-db and policy-docs (each listing its tools) and a chat call out to the MaaS model endpoint. A caption strip: "a tool is just your service + a standard adapter."

## Slide: RAG honestly — and grounding is engineered

- RAG = retrieve the relevant passage, then answer FROM it (and CITE it)
- The citation is the tell: a grounded answer points at its source (POL-AUTO-01)
- It fails when retrieval fails — garbage retrieval, confident garbage answer
- The model DECIDES to call a tool — how you ASK changes whether it does
- Same claim, terse vs imperative: ungrounded text-echo → grounded tool call

Notes: policy-docs is a RAG tool — Retrieval-Augmented Generation means retrieve the few relevant documents and let the model generate its answer from those passages, not from memory. When a staffer asks about the auto deductible, the agent calls search_policies, gets the POL-AUTO-01 passage, and answers from it — 500 USD, cited to POL-AUTO-01. The citation is the tell: a grounded answer can point at its source. Be honest about RAG: it helps when the answer is written down and the query can find it; it fails when retrieval fails, because grounding is only as good as the retrieval; and it is not a database query — RAG finds relevant text, structured tools compute facts, and a good agent uses both. Then the part most demos hide: the model decides whether to call a tool, and how you ask changes that decision. The same claim, asked tersely, made this model print the tool call as text and ground nothing; asked imperatively, it executed the tool and grounded. The lesson is not that the model is broken — it is that grounding is something you engineer, through the system prompt and clear phrasing. When you see a grounded answer, someone made it ground.
Visual: Split card. Left "RAG": a query flowing into a small doc-stack, one doc (POL-AUTO-01) highlighted and flowing into an answer that carries a "cited: POL-AUTO-01" badge; a small caution "retrieval fails → answer fails." Right "Grounding is engineered": two rows for the same claim — top row terse question → speech bubble "[get_claim(...)]" with a grey "ungrounded, toolCalls: []"; bottom row imperative question → a run tool icon → green "grounded: UnderReview."

## Slide: Guardrails and the Red Hat AI stack [ADD-ON]

- Guardrails belong to the PLATFORM, not each agent's code
- FMS Guardrails Orchestrator (GA): regex-detector sidecar blocks/masks PII
- The graded path is the SIMPLEST thing that teaches — the rest is additive
- [ADD-ON] layers: in-cluster serving · Llama Stack runtime · vector DB · guardrails
- Each slots in behind an interface the agent ALREADY uses — adopt when the need is real

Notes: An agent that reads live claims can also leak them or be steered into answering something it should not. You do not want that protection scattered through every agent's code — you want it as a platform layer the request passes through, like a mesh handling TLS. On Red Hat OpenShift AI that layer is the TrustyAI FMS Guardrails Orchestrator, generally available; its GPU-free option is a regex-detector sidecar that scans inputs and outputs for patterns like Social Security and credit-card numbers and blocks or masks them before they reach or leave the model. Guardrails are not deployed on this cluster — they are the ADD-ON layer, and the point is where the responsibility lives. Step back and see the stack: the graded path you build — Models-as-a-Service, Quarkus LangChain4j, deterministic RAG — is deliberately the simplest thing that teaches the ideas. Above it sit additive ADD-ON layers: in-cluster model serving, a Llama Stack agent runtime, a vector database for RAG at scale, and guardrails. Each slots in behind an interface the agent already uses, so you adopt them when the need is real, not on day one. That restraint is the engineering.
Visual: A layered stack diagram (bottom to top): "Model serving (MaaS today · in-cluster serving [ADD-ON])", "Agent runtime (Quarkus LangChain4j today · Llama Stack [ADD-ON])", "Retrieval (keyword today · vector DB [ADD-ON])", "Guardrails [ADD-ON]", "Observability (metrics + tokens today · traces→Tempo [ADD-ON])". The "today" half of each layer is solid; the [ADD-ON] half is a dashed outline labelled "adopt when the need is real."

## Slide: AI apps are apps — what you'll do

- Drive the agent: watch it call get_claim / search_policies and GROUND its answers
- See the honest edges: an unknown claim answered "not found," an ungrounded text-echo
- Observe it: per-answer tokens + tool calls, GenAI Prometheus metrics
- Confirm the punchline: a Deployment + Service + edge Route + probes, like any app
- When NOT to: plain API beats an agent · don't RAG what fits the prompt · no PII without guardrails

Notes: In the lab you drive the live agent and watch it call get_claim and search_policies to ground its answers, citing the policy it used. You see the honest edges that earn trust — an unknown claim answered "not found" instead of invented, and the terse question that prints the tool call as text without running it. You observe the agent — each answer reports its tokens and which tools it called, and Prometheus exposes GenAI token metrics per model. And you confirm the punchline: strip away the word AI and the agent is a Quarkus Deployment with a Service, an edge Route, and health probes — the readiness probe even pings both MCP servers, so a Ready agent has proven its tool wiring — shipped through the same golden path as every other app. Close on honesty about when not to use this: when a plain API call will do, don't add a model; don't RAG what fits in the prompt; and never put an agent on regulated data without the guardrail layer. The model is new; the disciplines are not.
Visual: Three-column "what you'll do" band — (1) a terminal showing a /agent/ask response with a highlighted toolCalls array; (2) a Topology view of three pods (parasol-agent, claims-db, policy-docs) all Ready; (3) a small "when NOT to use" checklist with three ticks. Footer ribbon: "AI apps are apps — same probes, same metrics, same golden path."
