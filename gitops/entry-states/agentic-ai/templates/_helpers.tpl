{{/* The module namespace — a dedicated per-user namespace this chart materializes INTO but does
     NOT own (workshop layer creates {user}-ai with quota/limits/RBAC, per-user-ai.yaml, like
     {user}-modernize / {user}-batch / {user}-mesh). Disjoint from every other module → no
     conflictsWith. */}}
{{- define "agentic-ai.namespace" -}}{{ .Values.user }}-ai{{- end -}}

{{/* The agent's public Route host, derived from the cluster ingress domain (attendee-safe — the
     same pattern the verify script + ws use). OpenShift auto-assigns exactly this host for a Route
     named parasol-agent in {user}-ai, so verify can curl POST /agent/ask without a cross-namespace
     route read. */}}
{{- define "agentic-ai.agentRouteHost" -}}parasol-agent-{{ .Values.user }}-ai.{{ .Values.clusterDomain }}{{- end -}}

{{/* ── GROUNDING: the module's write-beat ────────────────────────────────────────────────────────
     The agent reads its system prompt from the parasol-agent-grounding ConfigMap
     (PARASOL_AGENT_GROUNDING_PROMPT → parasol.agent.grounding-prompt), so this text — not any
     workload — is what the attendee changes. The entry state ships the WEAK draft; ws solve ships
     the strengthened one.

     WHY WEAK AT ENTRY. Before this, agentic-ai's entry state WAS its end state: all four agent tools
     are read-only, the attendee changed nothing durable, and `ws solve` rendered byte-identically to
     `ws prep`. Making the grounding the thing the attendee writes gives the module a real end state
     and puts its actual lesson — grounding is engineered, not granted — under the attendee's hands.

     The weak draft is a plausible FIRST DRAFT, not a strawman: it never mentions tools because
     whoever wrote it was thinking about tone, not about tool choice. That is the realistic failure.
     It deliberately contains no occurrence of the word "tool" and no tool name, which is also what
     lets tools/verify/agentic-ai.sh use one detector for both modes: entry asserts its ABSENCE, end
     asserts its PRESENCE — an exact negation, never two predicates that could drift apart. */}}
{{- define "agentic-ai.groundingPromptWeak" -}}
You are the Parasol Insurance claims assistant.
Answer questions from Parasol staff about claims and policies as helpfully as you can.
Keep answers short and professional.
{{- end -}}

{{/* The strengthened grounding — what a good answer to the exercise looks like, and byte-identical
     to the image's own built-in fallback (GroundingPrompt.DEFAULT_PROMPT in apps/parasol-agent), so
     `ws solve` lands the agent exactly where a correct attendee edit lands it. Verify grades the
     PROPERTY this text has (it directs the model at its tools), never this exact wording — any
     correct attendee prompt stays green (rule 14). */}}
{{- define "agentic-ai.groundingPromptStrong" -}}
You are the Parasol Insurance claims assistant. You help staff answer questions about
insurance claims and Parasol's policies.

You have tools. USE THEM instead of guessing:
- To answer anything about a specific claim (its status, amount, adjuster, type, or
  history), call the claims tools. Claim numbers look like CLM-1001.
- To answer anything about coverage, deductibles, required documents, claim workflow,
  service levels, or payout timing, call search_policies and base your answer only on
  the policy passages it returns. Cite the policy id (e.g. POL-AUTO-01) you relied on.

Rules:
- Never invent claim details or policy terms. If a tool says a claim was not found, or a
  search returns nothing relevant, say so plainly rather than guessing.
- Be concise: a few sentences. Give the specific figures the tools return.
- If a question needs both a claim fact and a policy rule, call both kinds of tool.
{{- end -}}

{{/* The prompt this render actually ships. Used TWICE — as the ConfigMap value and, hashed, as the
     agent pod template's checksum annotation — so `ws solve` rolls the pods instead of leaving them
     serving the weak prompt from their existing environment. */}}
{{- define "agentic-ai.groundingPrompt" -}}
{{- if .Values.solve -}}
{{- include "agentic-ai.groundingPromptStrong" . -}}
{{- else -}}
{{- include "agentic-ai.groundingPromptWeak" . -}}
{{- end -}}
{{- end -}}
