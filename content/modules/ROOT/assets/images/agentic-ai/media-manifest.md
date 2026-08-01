# M23 media manifest — Agentic AI on OpenShift

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
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
asset lands. **The three diagrams below are already rendered and committed** (2026-07-26, label-space
fix 2026-07-28) — only the screenshots and recording remain the pending capture. **Do not shoot those
yet** — this is the spec; capture in the media phase, and scrub the cluster
domain to a placeholder (`apps.example.com`) and the user to `{user}` in every frame. **Never show the
MaaS key** — the attendee never handles it, and it must not appear in any terminal frame or pod-log capture.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `agentic-ai-01-agent-anatomy.svg` | concept.adoc Mermaid "The anatomy of an agent" — `examples/diagrams/agentic-ai/01-agent-anatomy.mmd` | The four parts (model · instructions · tools · memory) inside the parasol-agent box; question in, grounded answer + tool-calls + tokens out; tools connect to the two MCP servers. Reused on concept slide 2 |
| `agentic-ai-02-mcp-tools.svg` | concept.adoc Mermaid "MCP tools are your APIs" — `examples/diagrams/agentic-ai/02-mcp-tools.mmd` | The agent as MCP client in the `{user}-ai` namespace, calling claims-db + policy-docs (tools listed) over HTTP-SSE and the MaaS model endpoint for chat. The module's spine — reused on concept slide 3 |
| `agentic-ai-03-agent-recap.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/agentic-ai/03-agent-recap.mmd` | question → agent (model+instructions+tools+memory) → MCP tools → grounded/cited answer (or honest "not found") + tokens; the `[ADD-ON]` next layer (guardrails · Llama Stack · vector DB) slotting in behind the same contracts |

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
| `agentic-ai-01-topology-three-pods.png` | Lab 1 | ✅ CAPTURED 2026-07-30 (as user1, read-only, no staging — the namespace was already in this state from the entry-state materialization). OpenShift *Topology* for `{user}-ai`: three Ready workloads — `parasol-agent`, `claims-db`, `policy-docs` — each a `D` badge inside a blue ring. Notice the agent's readiness ring (its probe pings both MCP servers). A fourth node (`maas-c...-user1`, a completed one-shot Job, green ring) is also in frame — genuine namespace content, not an artifact of staging; crop or note if a "three nodes only" frame is wanted for the deck. `[CAPTURE-VERIFY]` node labels — resolved by this capture, matches lab.adoc:148's grounded description. |
| `agentic-ai-02-ask-grounded.png` | Lab 2 | ✅ CAPTURED 2026-08-01 (cluster 2, as **user8** in the Showroom cockpit's own ttyd terminal — `oc whoami` = user8, so this is the attendee's real shell, not an admin one). **MARQUEE** — the terminal `POST /agent/ask` response for the imperative CLM-1001 question: `answer` = "The status of claim CLM-1001 is UnderReview.", `toolCalls` = one entry, `get_claim` with `{"claimNumber": "CLM-1001"}`. Embedded at `lab.adoc` ex. 2. The agent URL is behind the `$AGENT` variable in frame, so no cluster domain is rendered |
| `agentic-ai-03-terse-vs-imperative.png` | Lab 2 | ✅ CAPTURED 2026-08-01 as a **`.png`, not the specified `.gif`** — both calls fit in ONE terminal frame, which shows the contrast better than motion does and prints legibly. **MARQUEE (break-and-fix)** — and the contrast REPRODUCED exactly as specified: the terse question returned `"answer": "[get_claim(claimNumber=CLM-1001)]"` with `"toolCalls": []`, the imperative one returned the real `get_claim` call. Same model, same claim, one frame. Embedded at `lab.adoc` ex. 2, just before the checkpoint |
| `agentic-ai-04-mcp-tools-three.png` | Lab 3 | ✅ CAPTURED 2026-08-01 (cockpit terminal, user8). The three claims-db tools driven in turn: `get_claim` CLM-1004 (Tom Becker / home / denied / $8,400 / Angela Davis), `list_claims_by_status` Denied → the four denied claims, `get_claim_history` CLM-1001 → the ordered timeline. Each answer's tool name is printed beneath it |
| `agentic-ai-05-pod-log-tool-schemas.png` | Lab 3 | ⬜ NOT CAPTURED 2026-08-01 — **blocked on console authentication** (see the note under this table). The embed point sits inside the `Console::` tab of a dual-path block, so a terminal `oc logs` capture would be the wrong surface for it. Additional caution for whoever does capture it: this log is where the model *request* is traced, so check the frame for an `Authorization`/`Bearer` header before saving — the MaaS key must never appear |
| `agentic-ai-06-rag-cited.png` | Lab 4 | ✅ CAPTURED 2026-08-01 (cockpit terminal, user8). Both RAG beats in one frame: the auto collision deductible answered **500 USD cited to POL-AUTO-01** via `search_policies`, then the combined CLM-1004 answer citing **POL-CLAIM-01** with *both* `get_claim` and `search_policies` under "--- tools called ---" |
| `agentic-ai-07-metrics-tokens.png` | Lab 5 | ⬜ NOT CAPTURED 2026-08-01 — **blocked on console authentication** (see the note under this table) |
| `agentic-ai-08-not-found.png` | Lab 4 | ✅ CAPTURED 2026-08-01 (cockpit terminal, user8). The honest `CLM-9999` answer — _"The claim number CLM-9999 was not found in our system."_ — instead of a hallucinated claim |
| `agentic-ai-09-pod-container-details.png` | Lab 1 / 3 | ✅ CAPTURED 2026-07-30 (as user1, read-only, via the pod's own object URL — no console clicking needed). The `parasol-agent` pod's *Container details* page: *Container details* column (State Running, Restarts 0, Resource requests/limits, **Readiness probe** `HTTP GET .../q/health/ready`, **Liveness probe** `HTTP GET .../q/health/live`), *Image details* column (`image-registry.openshift-image-registry.svc:5000/ogsr-parasol-images/parasol-agent`, tag `1.0`, Pull policy Always pull), *Network* column (Node, Pod IP). Notice this is where the probe paths and the internal-registry image path actually live — one click deeper than the Topology side panel. Confirms lab.adoc:159-162 and :483-487's grounding notes. |
| `agentic-ai-10-deployment-resources-tab.png` | Lab 1 / 5 | ⬜ NOT CAPTURED — attempted 2026-07-30 via `tools/media/jobs-staged-window-2026-07-30-part2.yaml`, failed closed (no image written). The Topology side panel's *Resources* tab (Pods / Services / Routes headings, inline *View logs* link) exists only behind a graph-node click + a tab click; `capture.py`'s `click_text` matches `button`/`a`/`div[role="button"]`/`label` elements and a Topology SVG node matched none of those, so the click was skipped and the subsequent text assertion correctly failed rather than shooting the un-clicked graph. This view has no direct object-page URL (unlike row 09) — needs a human click-through or a harness enhancement, not a cluster-state change. The view is already grounded in prose at lab.adoc:305-311. Re-checked 2026-08-01: unchanged, and now also blocked upstream of that by the missing console session (see the note under this table). |

### Capture note, 2026-08-01 — how the terminal shots were taken, and why the console ones were not

**Terminal shots came from the attendee's own shell, not a mock.** The Showroom cockpit proxies a
`ttyd` terminal at `<showroom-userN>/tty-top/` (and `/tty-bottom/`) with **no login**, already
running as the attendee (`oc whoami` → `user8`). Playwright can drive it and *can* send Enter to it
— the "browser pane cannot send Enter to ttyd" limitation applies to an in-conversation browser
pane, not to Playwright. `window.term` is exposed by ttyd, so the xterm buffer can be read and
asserted before the shot exactly the way `capture.py` asserts DOM text, and the frame is cropped to
the rows the shell actually wrote (an uncropped 50-row terminal showing 20 lines is mostly black).

**The console shots are blocked on one thing only: an OAuth session.** Establishing a console
session requires a human to type a password into the OpenShift login page — `login.py` exists
precisely because nothing else can do it — and the operator of this pass is barred from typing
credentials anywhere. The cached `tools/media/shot-profile.session.json` holds a valid session for
a *different* cluster; for cluster 2 it carries only an unfinished `login-state`, and a headless
probe against that cluster's console returned **401**. So every row above marked "blocked on console
authentication" is one human login away from being capturable — nothing about the cluster state or
the click-path is wrong, and no workaround was attempted.

## Recording — terminal cast (demo-arc happy path)

| Filename | Notes |
|----------|-------|
| `agentic-ai-demo.cast` | asciinema cast of the terminal-visible demo arc: the imperative claim query (grounded `toolCalls`), the RAG deductible answer citing POL-AUTO-01, the combined CLM-1004 two-tool answer, then the honest edges — the `CLM-9999` not-found and the terse-vs-imperative grounding contrast — and finally `oc get deploy/route` showing "it's just a Deployment with an edge Route." Record in `{user}-ai`; scrub the domain to `apps.example.com`; the agent responses carry no key, but **never** run a command that would print the MaaS key |

## Narration

Narrated walkthrough script derives from the demo flavor (Say/Show/Do ≈ narration + shot list) during the
media phase. The three beats — *the agent calls a tool and grounds its answer*, *RAG cites its source*,
*the honest edges (not-found + engineered grounding) earn the trust* — are the shot list.
