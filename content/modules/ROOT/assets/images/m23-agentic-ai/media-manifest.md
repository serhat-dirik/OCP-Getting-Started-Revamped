# M23 media manifest — Agentic AI on OpenShift

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
This module's **marquee visual is the `POST /agent/ask` response** — the JSON showing the `answer`, the
populated `toolCalls` array (which tool the agent chose and with what arguments), and the `tokenUsage` —
because that single artifact carries the whole thesis: the model called *your* tool and grounded its
answer. The second marquee is the **terse-vs-imperative contrast** (the same claim answered ungrounded
then grounded), the module's break-and-fix. All agent responses, tool calls, token numbers and grounded
facts were captured on-cluster by driving the live `parasol-agent` (model served by the workshop MaaS
endpoint) on 2026-07-13/14; the OpenShift **console** click-paths (Topology, pod logs, Observe → Metrics)
are the deferred media pass and carry `[CAPTURE-VERIFY]` in the `.adoc`. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a commented
`// media-pass:` (diagrams) or `[CAPTURE-VERIFY]` (console) line — replace with the `image::…` when the
asset lands. **Do not shoot yet** — this is the spec; capture in the media phase, and scrub the cluster
domain to a placeholder (`apps.example.com`) and the user to `{user}` in every frame. **Never show the
MaaS key** — the attendee never handles it, and it must not appear in any terminal frame or pod-log capture.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m23-agentic-ai-01-agent-anatomy.svg` | concept.adoc Mermaid "The anatomy of an agent" | The four parts (model · instructions · tools · memory) inside the parasol-agent box; question in, grounded answer + tool-calls + tokens out; tools connect to the two MCP servers. Reused on concept slide 2 |
| `m23-agentic-ai-02-mcp-tools.svg` | concept.adoc Mermaid "MCP tools are your APIs" | The agent as MCP client in the `{user}-ai` namespace, calling claims-db + policy-docs (tools listed) over HTTP-SSE and the MaaS model endpoint for chat. The module's spine — reused on concept slide 3 |
| `m23-agentic-ai-03-agent-recap.svg` | wrapup.adoc Mermaid recap | question → agent (model+instructions+tools+memory) → MCP tools → grounded/cited answer (or honest "not found") + tokens; the `[ADD-ON]` next layer (guardrails · Llama Stack · vector DB) slotting in behind the same contracts |

Shared legend: the agent box (MCP client), the MCP-server/tool box, the model-endpoint box, the
grounded-answer card (answer + citation + tokens + tool calls), and the dashed `[ADD-ON]` layer —
Red Hat-neutral palette, no vendor-logo soup. Do **not** print product version numbers on the diagrams
(course standard — plain names only).

## Screenshots — the agent response (MARQUEE) + the grounding contrast

16:10, default console theme, `{user}`=`user1`, numbered red-circle annotations matching step numbers.
For the multi-click console flows an **animated gif/mp4 (<30 s, silent) is PREFERRED** over static shots
(`04-STYLE-GUIDE §4`).

| Filename | Lab step | Shows / what to notice |
|----------|----------|------------------------|
| `m23-agentic-ai-01-topology-three-pods.png` | Lab 1 | OpenShift *Topology* for `{user}-ai`: three Ready workloads — `parasol-agent`, `claims-db`, `policy-docs`. Notice the agent's readiness ring (its probe pings both MCP servers). `[CAPTURE-VERIFY]` node labels |
| `m23-agentic-ai-02-ask-grounded.png` | Lab 2 | **MARQUEE** — the terminal `POST /agent/ask` response for the imperative CLM-1001 question: the `answer` (UnderReview) and the populated `toolCalls` (`get_claim`). Notice the tool the model chose + its arguments |
| `m23-agentic-ai-03-terse-vs-imperative.gif` | Lab 2 | **MARQUEE (break-and-fix)** — two calls back-to-back: the terse question returning `[get_claim(...)]` with `toolCalls: []` (ungrounded), then the imperative question returning a real `get_claim` call (grounded). Notice: same claim, same model, different phrasing |
| `m23-agentic-ai-04-mcp-tools-three.png` | Lab 3 | The three claims-db tools driven in turn (`get_claim` CLM-1004, `list_claims_by_status` Denied → four claims, `get_claim_history` CLM-1001). Notice each answer's `toolCalls` names the tool |
| `m23-agentic-ai-05-pod-log-tool-schemas.png` | Lab 3 | The `parasol-agent` pod log: the system prompt + the tool *definitions* (`get_claim`, `search_policies`, …) sent to the model. Notice "the agent has tools" is literally a list of function schemas. `[CAPTURE-VERIFY]` console *View logs* |
| `m23-agentic-ai-06-rag-cited.png` | Lab 4 | The RAG answer for the auto deductible — 500 USD **cited to POL-AUTO-01** — and the combined CLM-1004 answer citing POL-CLAIM-01 with *both* tools in `toolCalls`. Notice the citation is the tell of a grounded answer |
| `m23-agentic-ai-07-metrics-tokens.png` | Lab 5 | Console *Observe → Metrics* charting `gen_ai_client_token_usage_total` by token type and model (or the CLI `/q/metrics` grep). Notice input tokens dominate — the tool schemas travel with each call. `[CAPTURE-VERIFY]` query browser |
| `m23-agentic-ai-08-not-found.png` | Lab 4 | The honest `CLM-9999` answer — _"not found in our system"_ — instead of a hallucinated claim. Notice the agent says "I don't know" when the tool does |

## Recording — terminal cast (demo-arc happy path)

| Filename | Notes |
|----------|-------|
| `m23-agentic-ai-demo.cast` | asciinema cast of the terminal-visible demo arc: the imperative claim query (grounded `toolCalls`), the RAG deductible answer citing POL-AUTO-01, the combined CLM-1004 two-tool answer, then the honest edges — the `CLM-9999` not-found and the terse-vs-imperative grounding contrast — and finally `oc get deploy/route` showing "it's just a Deployment with an edge Route." Record in `{user}-ai`; scrub the domain to `apps.example.com`; the agent responses carry no key, but **never** run a command that would print the MaaS key |

## Narration

Narrated walkthrough script derives from the demo flavor (Say/Show/Do ≈ narration + shot list) during the
media phase. The three beats — *the agent calls a tool and grounds its answer*, *RAG cites its source*,
*the honest edges (not-found + engineered grounding) earn the trust* — are the shot list.
