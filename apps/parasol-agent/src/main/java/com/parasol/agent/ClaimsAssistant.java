package com.parasol.agent;

import dev.langchain4j.service.MemoryId;
import dev.langchain4j.service.Result;
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
 *
 * <p>THERE IS NO {@code @SystemMessage} HERE, DELIBERATELY. The system prompt - the text that decides
 * whether this agent calls a tool or answers from the model's own weights - is
 * <strong>configuration</strong>, supplied by {@link GroundingPrompt} from
 * {@code parasol.agent.grounding-prompt} and, in the workshop, from a ConfigMap an attendee edits.
 * Baking it into the annotation would make the single most consequential knob in an agent a rebuild
 * away from being turned. {@code systemMessageProviderSupplier} is the extension's own hook for that:
 * the named {@link io.quarkiverse.langchain4j.runtime.aiservice.SystemMessageProvider} supplies the
 * system message on every call.
 */
@RegisterAiService(systemMessageProviderSupplier = GroundingPrompt.class)
public interface ClaimsAssistant {

    @McpToolBox({"claims-db", "policy-docs"})
    Result<String> ask(@MemoryId String conversationId, @UserMessage String question);
}
