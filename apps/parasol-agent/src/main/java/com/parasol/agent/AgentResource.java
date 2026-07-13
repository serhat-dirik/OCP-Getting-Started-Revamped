package com.parasol.agent;

import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import dev.langchain4j.model.output.TokenUsage;
import dev.langchain4j.service.Result;
import dev.langchain4j.service.tool.ToolExecution;
import io.smallrye.common.annotation.Blocking;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * REST surface for the Parasol agent.
 *
 * <pre>
 *   POST /agent/ask    ask the agent a claims/policy question; returns the answer,
 *                      the tools it called (name + arguments + result), and token usage
 *   GET  /agent/info   the model + MCP wiring the agent is configured with (no model call)
 * </pre>
 *
 * <p>{@code /ask} is {@code @Blocking}: the model + MCP tool round-trips take seconds, so the
 * call runs on a worker thread, never the event loop. Model failures (including an expired MaaS
 * key -&gt; HTTP 401) are caught and returned as a clean {@code 502} with an {@code authFailure}
 * flag, so a short-lived key degrades gracefully instead of throwing a stack trace at the caller.
 */
@Path("/agent")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class AgentResource {

    private static final Logger LOG = Logger.getLogger(AgentResource.class);

    @Inject
    ClaimsAssistant assistant;

    @Inject
    ToolCallCollector toolCallCollector;

    @ConfigProperty(name = "quarkus.langchain4j.openai.chat-model.model-name", defaultValue = "unknown")
    String modelName;

    @ConfigProperty(name = "quarkus.langchain4j.mcp.claims-db.url", defaultValue = "")
    String claimsDbUrl;

    @ConfigProperty(name = "quarkus.langchain4j.mcp.policy-docs.url", defaultValue = "")
    String policyDocsUrl;

    /** Ask the agent a question. The model decides which MCP tools to call to answer it. */
    @POST
    @Path("/ask")
    @Blocking
    public Response ask(AskRequest request) {
        if (request == null || request.question() == null || request.question().isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new AskError("question is required", null, false, modelName))
                    .build();
        }
        try {
            // Fresh memory id per request: no cross-request history, but the tool-calling
            // round-trip within THIS request still has somewhere to hold its messages.
            Result<String> result = assistant.ask(UUID.randomUUID().toString(), request.question());
            // The ChatModelListener records MCP tool calls (name + arguments) into the request-
            // scoped collector; Result.toolExecutions() only covers local @Tool beans, so prefer
            // the collector and fall back to toolExecutions() if it captured nothing.
            List<ToolCall> toolCalls = toolCallCollector.calls();
            if (toolCalls.isEmpty()) {
                toolCalls = result.toolExecutions().stream()
                        .map(AgentResource::toToolCall)
                        .toList();
            }
            return Response.ok(new AskResponse(
                    request.question(),
                    result.content(),
                    toolCalls,
                    modelName,
                    usage(result.tokenUsage()))).build();
        } catch (Exception e) {
            String detail = rootMessage(e);
            boolean auth = looksLikeAuthFailure(detail);
            LOG.warnf(e, "Agent model call failed (authFailure=%s): %s", auth, detail);
            String error = auth
                    ? "model authentication failed - check the MaaS key (GENAI_API_KEY); it may be expired"
                    : "the model call failed";
            return Response.status(Response.Status.BAD_GATEWAY)
                    .entity(new AskError(error, detail, auth, modelName))
                    .build();
        }
    }

    /** What the agent is wired to talk to. Handy for a smoke check without spending a token. */
    @GET
    @Path("/info")
    public Response info() {
        return Response.ok(new AgentInfo(modelName, claimsDbUrl, policyDocsUrl)).build();
    }

    private static ToolCall toToolCall(ToolExecution execution) {
        return new ToolCall(
                execution.request().name(),
                execution.request().arguments(),
                execution.result());
    }

    private static Usage usage(TokenUsage tokenUsage) {
        if (tokenUsage == null) {
            return null;
        }
        return new Usage(
                tokenUsage.inputTokenCount(),
                tokenUsage.outputTokenCount(),
                tokenUsage.totalTokenCount());
    }

    /** Unwrap to the deepest cause so the caller sees the real reason (e.g. the HTTP 401). */
    static String rootMessage(Throwable t) {
        Throwable current = t;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        String message = current.getMessage();
        return message == null ? current.getClass().getSimpleName() : message;
    }

    static boolean looksLikeAuthFailure(String detail) {
        if (detail == null) {
            return false;
        }
        String lower = detail.toLowerCase();
        return lower.contains("401") || lower.contains("403")
                || lower.contains("unauthorized") || lower.contains("authentication")
                || lower.contains("invalid api key") || lower.contains("invalid_api_key");
    }

    /** Request body for {@code POST /agent/ask}. */
    public record AskRequest(String question) {
    }

    /** Token accounting for one answer (null fields when the provider does not report usage). */
    public record Usage(Integer inputTokens, Integer outputTokens, Integer totalTokens) {
    }

    /** Success body for {@code POST /agent/ask}. */
    public record AskResponse(String question, String answer, List<ToolCall> toolCalls,
                              String model, Usage tokenUsage) {
    }

    /** Error body for {@code POST /agent/ask} (bad input or an upstream model failure). */
    public record AskError(String error, String detail, boolean authFailure, String model) {
    }

    /** Body for {@code GET /agent/info}. */
    public record AgentInfo(String model, String claimsDbMcpUrl, String policyDocsMcpUrl) {
    }
}
