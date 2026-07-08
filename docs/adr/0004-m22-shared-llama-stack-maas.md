# ADR-0004: M22 AI architecture — one shared Llama Stack over MaaS, Quarkus-direct fallback

Date: 2026-07-08 · Status: accepted (re-verify at M22 build — fastest-moving area) · Owner: PM (spike by research-analyst)

## Context

RHOAI 3.3 is current. Llama Stack on OpenShift is **Technology Preview** (`LlamaStackDistribution` CR + operator); remote OpenAI-compatible providers are a documented shape (BYO provider → our MaaS endpoint, qwen3-14b), so a GPU-less cluster works. MCP is integrated into the API layer; the Responses API is the Red Hat AI 3 headline surface. TrustyAI **FMS Guardrails Orchestrator is GA** (NeMo orchestrator TP). Per-user Llama Stack instances would mean 30× TP reconciles + 30 vector DBs.

## Decision

**One shared `LlamaStackDistribution`** configured with the remote MaaS provider; per-user isolation via per-user vector-store IDs and per-user MCP server pods; guardrails via the **GA FMS Orchestrator** (shared). **Mandatory documented fallback:** `parasol-agent` (Quarkus LangChain4j) targets an OpenAI-compatible base URL, so if the shared TP instance thrashes under 30 users, the module re-points the same code directly at MaaS — MCP and guardrails lessons stand.

## Consequences

- All three teaching goals (Responses API, MCP-on-OpenShift, guardrails) at bounded cost.
- TP risk is contained by the fallback seam; hard re-verify rule at M22 build time (product names/APIs).
