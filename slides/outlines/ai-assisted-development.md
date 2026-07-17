# AI-Assisted Development on OpenShift (Vibe Coding, Safely)

## Slide: It runs your cluster now

- An AI assistant that can read and change your cluster is the most useful — and most dangerous — tool this week
- Connect it and it stops hallucinating: it reads live pods, real events, actual logs
- The moment it can call the cluster, it becomes an actor with an identity
- The question is never "do I trust the model" — it's "what can its identity do"
- Vibe coding, safely = scope the identity, audit the actions, keep a human on writes

Notes: Open on the reframe. Engineers are already pasting cluster YAML into chat assistants and asking "why is this pod broken?" The instant that assistant can call the cluster itself instead of guessing, it becomes genuinely useful — and becomes an actor on your platform with whatever powers you gave it. The business framing to land: an AI agent with cluster access is a junior engineer you hired in thirty seconds and handed your keys to. Fast, tireless, occasionally confidently wrong. So the safety question is not about the model's intelligence — it's about the identity it acts through. The module's promise: scope that identity with least privilege, make every action auditable, require a human for writes, and vibe coding becomes safe to bring to work. Everything in the lab performs exactly that.
Visual: A split — left: an engineer pasting `oc get` output into a chat window, shrugging ("is this even current?"); right: the same assistant wired straight into a cluster, with a small padlock labeled "identity: mcp-agent (view, one namespace)". Arrow labeled "now it can act."

## Slide: How an assistant reaches the cluster — MCP + a ServiceAccount

- The assistant speaks MCP (Model Context Protocol) to an MCP server, not to the API directly
- The MCP server exposes cluster operations as tools: list pods, read events, get a deployment
- It runs as a dedicated ServiceAccount (mcp-agent) — its projected token is the ONLY cluster credential
- The client (the assistant) holds NO kubeconfig — only the MCP address and a model key
- Every call the server makes is made AS mcp-agent, and the API server checks its RBAC

Notes: Ground the mechanism. An AI assistant doesn't speak to the Kubernetes API — it speaks MCP, the same open standard the claims assistant used for its data tools in the Agentic AI module. Here the MCP server is pointed at the platform: it advertises list-pods, read-events, get-deployment, read-logs as tools the model can call. The single most important fact is how that server authenticates: it runs as a dedicated ServiceAccount, mcp-agent, and its pod's projected token is the only cluster credential in the entire system. The client — the neutral CLI the attendee runs — holds no kubeconfig; it knows only the MCP server's address and a model key. So when the model calls "list pods in namespace X," the server asks the API server as mcp-agent, and the API server checks: may mcp-agent do this? The agent's powers are exactly mcp-agent's powers — no more. That's the whole design, and it's why RBAC on that SA is the lever.
Visual: Reuse concept diagram ai-assisted-development-...-01-mcp-sa-boundary.svg — client (no kubeconfig) → MCP server (runs as mcp-agent) → RBAC gate → API server; a side branch to the MaaS model. The RBAC gate highlighted red as "the actual boundary."

## Slide: Read-only first — and the flag is not the boundary

- Give agents eyes before hands: a read-only view role diagnoses everything, breaks nothing
- The MCP server's `--read-only` flag and the client's read-only filter are BOTH seatbelts
- CVE-2026-46519: a sibling server's read-only mode filtered tool *discovery*, not *execution* — bypassable
- The boundary is RBAC on the ServiceAccount, enforced by the API server *underneath* the agent
- Set the flags AND scope the identity: belt, suspenders, and a locked door

Notes: This is the module's thesis slide. Read-only first: an agent that can only get/list/watch can diagnose all day and break nothing, so that's where you start. The MCP server ships a --read-only flag and the neutral client has its own filter that hides mutating tools — use both, they're good defense in depth. But do not mistake either for the boundary. Tell the CVE story: a sibling open-source MCP server had a read-only mode that filtered the *list* of tools it advertised but not the tools it would actually *execute*, so a caller who named a mutating tool directly bypassed read-only entirely (CVE-2026-46519, fixed upstream). The lesson isn't "that project was careless" — it's that a flag in the agent's own software is only as trustworthy as that software. RBAC is enforced by the Kubernetes API server, underneath the agent, so even a buggy or malicious client that tries a forbidden write gets a 403. Set the flags AND scope the ServiceAccount so that if the flags fail, nothing bad is actually permitted.
Visual: Two seatbelts (labeled "server --read-only" and "client filter") drawn as thin dashed lines, and behind them a solid vault door labeled "RBAC on mcp-agent (API server enforced)". A small "CVE-2026-46519: seatbelt unbuckled → door still locked" caption.

## Slide: Diagnose read-only — watch the trace, verify the claim

- Ask the agent why the claims service is broken — imperatively: "list pods, get the deployment, read events"
- It calls the cluster: pods_list_in_namespace → resources_get → events_list (the tool-call trace is the receipt)
- Grounded answer: the readiness probe points at /q/health/reddy, which 404s
- Then verify it YOURSELF with oc — the agent told the truth, and you checked
- Grounding is engineered: terse prompts make some models narrate a tool call as text instead of running it

Notes: Make the read-only movement physical. The attendee asks the agent, phrased like briefing a junior engineer — tell it what to inspect — and watches three real tool calls scroll by: list the pods (parasol-claims is 0/1), get the deployment (readinessProbe path /q/health/reddy), read the events (Readiness probe failed, statuscode 404). The tool-call trace is the receipt: the answer is built from what those calls returned, not the model's imagination, and mode: READ-ONLY means no write was even possible. Then the discipline that separates a useful agent from a trusted one: verify the claim yourself. oc get the probe path, oc get the 404 event — the agent told the truth, and you confirmed it. That's the trust loop. Close on the honest edge: you phrased it imperatively on purpose. A terse "why is it broken?" makes some models print a tool call as text and answer from memory (0 real calls). Grounding is something you engineer — through phrasing, the system prompt, and tool-forcing — not a guarantee.
Visual: A terminal showing the TOOL-CALL TRACE (3 calls) block, with a green check beside the answer and a second panel showing the matching `oc get ... /q/health/reddy` + the 404 event — "the agent's claim, verified."

## Slide: Scoped write on purpose — the human grant, the fix, the audit

- Diagnosing is safe; fixing means writing — and writing is YOUR decision
- Grant a small deployer Role: patch deployments, this namespace only, no secrets, no scale
- Flip the write path on; the client's read-only filter still hides 6 mutating tools (seatbelt)
- The agent patches the one bad field → parasol-claims goes 1/1
- managedFields records the writer: manager = kubernetes-mcp-server — an auditable trail

Notes: The governed-write movement. Diagnosing was safe; fixing means writing, and writing is a decision the human makes. So the attendee grants mcp-agent a narrow deployer Role — patch/update deployments, in this namespace, nothing else: not edit (which can touch secrets), not cluster-wide, not scale. Confirm the grant did exactly that: can-i patch deployments = yes, can-i get secrets = still no. Then enable the write path on the server and, before allowing writes, see the client's seatbelt — even with the server now offering mutating tools, the client in read-only mode hides 6 of them, reporting "RBAC remains the real boundary." Then allow writes and the agent patches the probe path to /q/health/ready; parasol-claims rolls out to 1/1. Finally, review the audit trail: the deployment's managedFields record every writer by name, and the agent's write shows as manager: kubernetes-mcp-server, op=Apply — recorded by the API server itself. Between the tool-call trace and managedFields, every write is accountable. (Note for delivery: on smaller models the agent may narrate the change as text; that's the review-the-agent lesson — you approve and apply the patch it proposed.)
Visual: A three-panel strip: (1) the deployer Role YAML with "no secrets, no scale" circled; (2) can-i matrix (patch deployments: yes / get secrets: no); (3) parasol-claims 0/1 → 1/1 with a managedFields callout "manager: kubernetes-mcp-server".

## Slide: The forbidden test — watch RBAC say no

- Same agent, writes still enabled — now point it at a NEIGHBOURING namespace
- It genuinely tries: the trace shows pods_list_in_namespace on user1-dev
- The API server returns: pods is forbidden … cannot list … in namespace "user1-dev"
- Not the agent's manners — mcp-agent has no view there, so it's a 403 the platform enforces
- oc auth can-i --as confirms the scope: yes at home, no next door, no cluster-wide

Notes: The climax the whole module builds to. The agent can now read and patch the attendee's namespace. Point it at someone else's. Writes are still allowed and the server still offers every tool — the only thing between the agent and a neighbour's namespace is RBAC on mcp-agent. Ask it to list pods and events in user1-dev, and watch the trace: it *calls* the tool — this is not the client refusing on the agent's behalf — and the API server returns "pods is forbidden: User system:serviceaccount:user3-dev:mcp-agent cannot list resource pods in the namespace user1-dev." The agent reports the denial honestly and doesn't try to work around it. That denial IS the lesson: mcp-agent has a view RoleBinding in the attendee's namespace and nowhere else, so a read of user1-dev is a 403, enforced by the platform underneath the agent. Confirm from the other side with oc auth can-i --as impersonation: yes in your namespace, no next door, no cluster nodes. This is why you scope with a namespaced RoleBinding, never cluster-reader — on a shared cluster the blast radius is exactly the namespace you put the agent in. Trust didn't stop it; the platform did.
Visual: Reuse concept diagram ai-assisted-development-...-02-two-phase-rbac.svg, zoomed on the denial branch: the agent's call to user1-dev bouncing off a red RBAC wall labeled "403 — no binding here", with the can-i matrix (yes/no/no) beside it.

## Slide: The Lightspeed family, and a team policy you can adopt

- Red Hat Lightspeed: OpenShift Lightspeed (GA, console + MCP host); Developer Lightspeed for RHDH [ADS] (Dev Preview); for MTA [ADS] (GA)
- Same spine, different surfaces — every one is governed by the RBAC you just scoped
- Team policy: read-only first · identity is the boundary, not the flag · namespace allowlists
- No secrets by default · writes are a reviewed, per-task human grant · every action auditable
- Your agent is a junior engineer with root, unless you stop it — scope it with RBAC, not trust

Notes: Land the plane on where this fits and what to take home. The neutral client in the lab was deliberately generic so the lesson is about the platform boundary, not one product — but in practice Red Hat ships a Lightspeed family: OpenShift Lightspeed (GA) for the cluster console, which can itself act as an MCP host; Developer Lightspeed for Red Hat Developer Hub [ADS] (Developer Preview) for non-coding developer questions in the portal; and Developer Lightspeed for MTA [ADS] (GA) for in-IDE Java modernization. They differ in surface and job, but they share this module's spine: an assistant is only as powerful as the identity it acts through, and every one is governed by the same RBAC the attendee just scoped by hand. Then the takeaway — a team policy checklist, every line performed today: read-only first; the identity's RBAC is the boundary, the read-only flag is a seatbelt; namespace allowlists, never cluster-wide; no secrets by default; writes are a reviewed, per-task human grant; every action auditable via the tool-call trace and managedFields; bound, short-lived tokens. Close on the line: your agent is a junior engineer with root, unless you stop it — so you scope it with RBAC, not trust.
Visual: A checklist card (the 8-line team policy) on the right; on the left, three small product tiles (OpenShift Lightspeed / Dev Lightspeed for RHDH / for MTA) all funneling into one shared "RBAC-governed ServiceAccount" base. Footer: "scope it with RBAC, not trust."
