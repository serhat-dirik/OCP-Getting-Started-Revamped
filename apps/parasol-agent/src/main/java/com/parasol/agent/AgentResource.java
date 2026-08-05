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
 *   GET  /agent/info   the model + MCP wiring AND the grounding prompt in force
 *                      (no model call - costs nothing to ask)
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

    /**
     * The same grounding the AI service runs on, resolved the same way. Constructed rather than
     * injected because LangChain4j instantiates {@link GroundingPrompt} reflectively and it is
     * therefore not a CDI bean - see its own class comment. Both instances read one config property,
     * so {@code /agent/info} cannot drift from what the model is actually being told.
     */
    private final GroundingPrompt grounding = new GroundingPrompt();

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
            String detail = redactCredentials(rootMessage(e));
            boolean auth = looksLikeAuthFailure(detail);
            // The throwable is deliberately NOT handed to the logger: printStackTrace writes every
            // cause's raw getMessage(), which is the exact text the gateway echoes the key back in,
            // and it lands BELOW the line a reader greps for. Log the redacted detail plus the cause
            // chain (types only) - same diagnostic value, no credential on any line.
            LOG.warnf("Agent model call failed (authFailure=%s): %s [%s]", auth, detail, causeChain(e));
            String error = auth
                    ? "model authentication failed - check the MaaS key (GENAI_API_KEY); it may be expired"
                    : "the model call failed";
            return Response.status(Response.Status.BAD_GATEWAY)
                    .entity(new AskError(error, detail, auth, modelName))
                    .build();
        }
    }

    /**
     * What the agent is wired to talk to, and - just as load-bearing - the grounding prompt this
     * pod is actually running. Makes no model call, so it is free to ask and free to poll.
     *
     * <p>The prompt is echoed IN FULL on purpose. It is the one piece of an agent's behaviour that
     * is invisible from the outside and decisive from the inside, and after editing the ConfigMap
     * the only honest way to know whether the change reached the workload is to have the workload
     * say so. Nothing secret passes through here: the model key is never part of this response.
     */
    @GET
    @Path("/info")
    public Response info() {
        return Response.ok(new AgentInfo(
                modelName, claimsDbUrl, policyDocsUrl, grounding.source(), grounding.text())).build();
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

    /**
     * Blank credential material out of an upstream message before it is logged or returned.
     *
     * <p>WHY THIS EXISTS. The model gateway echoes the rejected key back <em>in full</em> inside its
     * own 401 body ({@code Virtual Key expected. Received=<the key>, expected to start with 'sk-'}).
     * That body becomes {@code detail}, and {@code detail} goes to two places a person reads: the
     * pod log, and {@link AskError#detail()} - which is serialised into the 502 JSON the attendee
     * gets back from {@code POST /agent/ask}. So the credential was one wording change away from
     * being printed in an attendee's terminal.
     *
     * <p>Redaction, never truncation. The near-miss that prompted this was a {@code cut -c1-200} on
     * the log line that cleared the echoed key by TEN characters - safety by accident of arithmetic.
     * A character count is not a defence; naming the thing is.
     *
     * <p>Deliberately shape-based and deliberately narrow. It blanks the value of the gateway's
     * {@code Received=} field and any {@code sk-} or JWT shaped token, and leaves the rest of the
     * sentence alone: the reader still has to be able to tell the three key faults apart (expired /
     * wrong kind of credential / scoped to a different model), and the last of those is diagnosed
     * from a {@code models=[...]} list that must survive. The {@code sk-}/{@code eyJ} prefix is kept
     * on purpose so "you sent a JWT where an API key was expected" is still readable after redaction.
     */
    static String redactCredentials(String message) {
        if (message == null) {
            return null;
        }
        String out = RECEIVED_FIELD.matcher(message).replaceAll("Received=<redacted>");
        out = BEARER_TOKEN.matcher(out).replaceAll("$1 <redacted>");
        return KEY_SHAPED.matcher(out).replaceAll("$1<redacted>");
    }

    /** The gateway's echo-back field. Value ends at the comma (or space) that resumes the sentence. */
    private static final java.util.regex.Pattern RECEIVED_FIELD =
            java.util.regex.Pattern.compile("Received=[^,\\s]*");

    /** An Authorization header quoted back at us by a client library that logs the request. */
    private static final java.util.regex.Pattern BEARER_TOKEN =
            java.util.regex.Pattern.compile("(?i)(Bearer)\\s+[A-Za-z0-9._~+/=-]{8,}");

    /** The two credential shapes this workshop actually handles: a MaaS virtual key, and a JWT. */
    private static final java.util.regex.Pattern KEY_SHAPED =
            java.util.regex.Pattern.compile("(sk-|eyJ)[A-Za-z0-9._~+/=-]{8,}");

    /**
     * The exception chain as class names only, root-ward - e.g. {@code RuntimeException -> HttpException}.
     * Types, never messages: this is the part of a stack trace that is safe to log verbatim.
     */
    static String causeChain(Throwable t) {
        StringBuilder chain = new StringBuilder();
        Throwable current = t;
        while (current != null) {
            if (chain.length() > 0) {
                chain.append(" -> ");
            }
            chain.append(current.getClass().getSimpleName());
            current = current.getCause() == current ? null : current.getCause();
        }
        return chain.toString();
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

    /**
     * Body for {@code GET /agent/info}: the model, both MCP tool servers, and the grounding prompt
     * in force plus where it came from ({@code config …} or {@code built-in default}).
     */
    public record AgentInfo(String model, String claimsDbMcpUrl, String policyDocsMcpUrl,
                            String groundingPromptSource, String groundingPrompt) {
    }
}
