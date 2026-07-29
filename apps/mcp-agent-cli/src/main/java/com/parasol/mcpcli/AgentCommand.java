package com.parasol.mcpcli;

import java.util.List;
import java.util.concurrent.Callable;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import io.quarkus.picocli.runtime.annotations.TopCommand;
import jakarta.inject.Inject;
import picocli.CommandLine.Command;
import picocli.CommandLine.Option;
import picocli.CommandLine.Parameters;

/**
 * The CLI entry point: one natural-language prompt in, a tool-call trace and a final answer out.
 *
 * <pre>
 *   mcp-agent-cli "diagnose why parasol-claims is not Ready in user1-dev"
 *   mcp-agent-cli --allow-writes "fix the readiness probe on parasol-claims and roll it out"
 * </pre>
 *
 * <p>It is assistant-neutral by design: it is the provided client M24 hands every attendee, so the
 * module never depends on anyone licensing a specific IDE assistant. Read-only-first is the default;
 * writes must be asked for explicitly ({@code --allow-writes}), and even then RBAC on the agent's
 * ServiceAccount - not this flag - is the real boundary.
 *
 * <p>A model failure (for example an expired MaaS key -&gt; HTTP 401) is caught and reported as a
 * clean one-line message with exit code 1, printing whatever tool calls were already traced, rather
 * than dumping a stack trace - the same graceful degradation {@code parasol-agent} does for a
 * short-lived key.
 */
@TopCommand
@Command(name = "mcp-agent-cli", mixinStandardHelpOptions = true,
        description = "Ask an MCP-connected agent to inspect/operate the cluster; prints the tool-call trace and the answer.")
public class AgentCommand implements Callable<Integer> {

    @Parameters(arity = "1..*", paramLabel = "PROMPT",
            description = "The natural-language prompt for the agent (quote it).")
    List<String> promptWords;

    @Option(names = "--allow-writes",
            description = "Offer mutating tools to the model (default: read-only, mutating tools hidden).")
    boolean allowWrites;

    @Option(names = "--read-only",
            description = "Force read-only even if configuration allows writes.")
    boolean forceReadOnly;

    @Inject
    AgentFactory factory;

    @Inject
    ToolCallTracer tracer;

    @ConfigProperty(name = "quarkus.langchain4j.openai.chat-model.model-name", defaultValue = "unknown")
    String modelName;

    @ConfigProperty(name = "quarkus.langchain4j.mcp.platform.url", defaultValue = "")
    String mcpUrl;

    @ConfigProperty(name = "mcp-agent.read-only", defaultValue = "true")
    boolean configReadOnly;

    @Override
    public Integer call() {
        if (allowWrites && forceReadOnly) {
            System.err.println("error: --allow-writes and --read-only are mutually exclusive.");
            return 2;
        }
        String prompt = promptWords == null ? "" : String.join(" ", promptWords).strip();
        if (prompt.isEmpty()) {
            System.err.println("error: a prompt is required.");
            return 2;
        }

        boolean readOnly = forceReadOnly || (!allowWrites && configReadOnly);
        tracer.reset();

        AgentFactory.BuiltAgent agent = factory.create(readOnly);
        System.out.println(TraceFormatter.header(modelName, mcpUrl, readOnly, agent.mcpServerCount()));
        System.out.println();

        try {
            String answer = agent.assistant().chat(prompt);
            System.out.println(TraceFormatter.trace(tracer.trace()));
            if (readOnly && agent.filter() != null) {
                System.out.println();
                System.out.println(TraceFormatter.readOnlyNote(agent.filter().filteredOut()));
            }
            System.out.println();
            System.out.println(TraceFormatter.answer(answer));
            return 0;
        } catch (Exception e) {
            // Print whatever the agent managed to call before it failed - the trace is never silently lost.
            System.out.println(TraceFormatter.trace(tracer.trace()));
            // Redact BEFORE branching, not inside the safe branch: looksLikeAuthFailure is a
            // substring heuristic over six tokens, so a 429/500 whose body happens to echo the key
            // without saying "401"/"authentication" falls through to the "+ detail" branch and lands
            // in `oc logs`. The redaction has to hold on the path the heuristic does not recognise.
            String detail = redactCredentials(rootMessage(e));
            System.err.println();
            System.err.println(looksLikeAuthFailure(detail)
                    ? "error: model authentication failed - check the MaaS key (GENAI_API_KEY); it may be expired."
                    : "error: the run failed - " + detail);
            return 1;
        }
    }

    /**
     * Blank credential material out of an upstream message before it is printed.
     *
     * <p>WHY THIS EXISTS. This CLI runs as a one-shot pod with the MaaS key in its environment, and
     * M24 reads its output with {@code oc logs "$POD"} straight into the attendee's terminal. The
     * model gateway echoes a rejected key back in full inside its 401 body
     * ({@code Virtual Key expected. Received=<the key>, ...}), and {@link #rootMessage} deliberately
     * unwraps to exactly that deepest message. So the key was one unrecognised status code away from
     * being printed.
     *
     * <p>Redaction, never truncation - the sibling near-miss was a {@code cut -c1-200} that cleared
     * an echoed key by ten characters. A character count is not a defence. Kept narrow on purpose:
     * the {@code sk-}/{@code eyJ} prefix survives so "you sent a JWT where an API key was expected"
     * is still diagnosable, and a {@code models=[...]} scope list is left intact.
     *
     * <p>Mirrors {@code AgentResource.redactCredentials} in parasol-agent. Duplicated rather than
     * shared: these are two independent Maven modules with no common artifact, and a shared library
     * for three regexes would cost more than it saves.
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

    /** Unwrap to the deepest cause so the message is the real reason (e.g. the HTTP 401), not a wrapper. */
    static String rootMessage(Throwable t) {
        Throwable current = t;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        String message = current.getMessage();
        return message == null ? current.getClass().getSimpleName() : message;
    }

    /** Heuristic: does this failure look like a rejected/expired key rather than a transport error? */
    static boolean looksLikeAuthFailure(String detail) {
        if (detail == null) {
            return false;
        }
        String lower = detail.toLowerCase();
        return lower.contains("401") || lower.contains("403")
                || lower.contains("unauthorized") || lower.contains("authentication")
                || lower.contains("invalid api key") || lower.contains("invalid_api_key");
    }
}
