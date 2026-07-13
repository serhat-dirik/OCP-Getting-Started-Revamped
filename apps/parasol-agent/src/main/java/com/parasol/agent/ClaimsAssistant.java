package com.parasol.agent;

import dev.langchain4j.service.MemoryId;
import dev.langchain4j.service.Result;
import dev.langchain4j.service.SystemMessage;
import dev.langchain4j.service.UserMessage;
import io.quarkiverse.langchain4j.RegisterAiService;
import io.quarkiverse.langchain4j.mcp.runtime.McpToolBox;

/**
 * The Parasol claims assistant - a LangChain4j AI service backed by an OpenAI-compatible model
 * (MaaS) and the two Parasol MCP servers as its tools.
 *
 * <p>The agent is effectively <strong>stateless per request</strong>: {@code ask} takes a
 * {@code @MemoryId} and the REST layer passes a FRESH id (a UUID) on every call, so no two
 * requests share conversation history. A per-request memory (rather than no memory at all) is
 * required so the tool-calling round-trip - model asks for a tool, the tool result is fed back,
 * the model answers - has somewhere to hold its intermediate messages. Combined with temperature
 * 0 (see application.properties) and the deterministic tool servers, this keeps demos reproducible.
 *
 * <p>{@code @McpToolBox} wires in BOTH MCP servers (configured under
 * {@code quarkus.langchain4j.mcp.claims-db.*} and {@code ...policy-docs.*}); LangChain4j discovers
 * their tools over HTTP-SSE and lets the model decide which to call. The method returns a
 * {@link Result} so the REST layer can report not just the answer but exactly which tools ran and
 * how many tokens were spent (the "observe the agent" beat, M12).
 */
@RegisterAiService
public interface ClaimsAssistant {

    @SystemMessage("""
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
            """)
    @McpToolBox({"claims-db", "policy-docs"})
    Result<String> ask(@MemoryId String conversationId, @UserMessage String question);
}
