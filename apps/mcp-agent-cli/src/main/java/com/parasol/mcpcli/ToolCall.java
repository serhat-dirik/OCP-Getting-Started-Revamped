package com.parasol.mcpcli;

/**
 * One tool the agent invoked while answering: the tool {@code name}, the JSON {@code arguments}
 * the model passed, and (when available) the tool {@code result}.
 *
 * <p>This is the unit of the <strong>tool-call trace</strong> the CLI prints - the auditability
 * that is the core M24 teaching point ("watch the tool calls; verify its claims yourself"). The
 * {@code result} is {@code null} while a call is still in flight (the model has asked for the tool
 * but its result has not come back yet); {@link ToolCallTracer} fills it in when the result message
 * arrives on the next model round-trip.
 */
public record ToolCall(String name, String arguments, String result) {

    /** A freshly-requested call whose result has not come back yet. */
    static ToolCall pending(String name, String arguments) {
        return new ToolCall(name, arguments, null);
    }

    /** This call with its result filled in. */
    ToolCall withResult(String result) {
        return new ToolCall(name, arguments, result);
    }
}
