package com.parasol.mcpcli;

import java.util.List;
import java.util.Map;

/**
 * Renders the tool-call trace, the wiring header, and the final answer as plain text for the
 * terminal. Pure functions (no I/O) so the exact formatting - the auditable artifact M24 asks
 * attendees to read - is unit-tested directly.
 */
public final class TraceFormatter {

    /** Results longer than this are truncated in the trace, with a note, to keep the terminal readable. */
    static final int MAX_RESULT_CHARS = 1200;

    private TraceFormatter() {
    }

    /** The wiring the agent is about to use - printed before the run so the trace is self-describing. */
    public static String header(String model, String mcpUrl, boolean readOnly, int mcpServerCount) {
        return """
                mcp-agent-cli
                  model:     %s
                  mcp server: %s  (%d wired)
                  mode:      %s""".formatted(
                nullSafe(model, "<unset>"),
                nullSafe(mcpUrl, "<unset>"),
                mcpServerCount,
                readOnly ? "READ-ONLY (mutating tools hidden from the model)"
                         : "WRITES ALLOWED (mutating tools offered; RBAC is the boundary)");
    }

    /** The TOOL-CALL TRACE block: every tool the agent called, with arguments and result, in order. */
    public static String trace(List<ToolCall> calls) {
        int n = calls == null ? 0 : calls.size();
        StringBuilder sb = new StringBuilder();
        sb.append("TOOL-CALL TRACE (").append(n).append(n == 1 ? " call)" : " calls)");
        if (n == 0) {
            sb.append("\n  (the model answered without calling any tools)");
            return sb.toString();
        }
        for (int i = 0; i < n; i++) {
            ToolCall call = calls.get(i);
            sb.append("\n  [").append(i + 1).append("] ").append(nullSafe(call.name(), "<unnamed>"));
            sb.append("\n      args:   ").append(oneLine(nullSafe(call.arguments(), "{}")));
            sb.append("\n      result: ").append(formatResult(call.result()));
        }
        return sb.toString();
    }

    /** A note about the read-only posture actually applied: which tools were hidden. */
    public static String readOnlyNote(Map<String, String> filteredOut) {
        if (filteredOut == null || filteredOut.isEmpty()) {
            return "read-only: no mutating tools were offered by the server.";
        }
        StringBuilder sb = new StringBuilder("read-only: hid ")
                .append(filteredOut.size())
                .append(filteredOut.size() == 1 ? " mutating tool" : " mutating tools")
                .append(" (RBAC remains the real boundary):");
        filteredOut.forEach((name, verb) -> sb.append("\n  - ").append(name).append("  (matched '").append(verb).append("')"));
        return sb.toString();
    }

    /** The final answer, clearly separated from the trace. */
    public static String answer(String text) {
        return "ANSWER\n" + indent(nullSafe(text, "(no answer)").strip(), "  ");
    }

    private static String formatResult(String result) {
        if (result == null) {
            return "(no result captured)";
        }
        String value = result;
        boolean truncated = false;
        if (value.length() > MAX_RESULT_CHARS) {
            value = value.substring(0, MAX_RESULT_CHARS);
            truncated = true;
        }
        String rendered = value.contains("\n")
                ? "\n" + indent(value, "        ")
                : value;
        if (truncated) {
            rendered = rendered + "\n        ... (truncated, " + result.length() + " chars total)";
        }
        return rendered;
    }

    private static String oneLine(String s) {
        return s.replace("\n", " ").replace("\r", " ").trim();
    }

    private static String indent(String s, String prefix) {
        return s.lines().map(line -> prefix + line).reduce((a, b) -> a + "\n" + b).orElse(prefix);
    }

    private static String nullSafe(String s, String fallback) {
        return (s == null || s.isEmpty()) ? fallback : s;
    }
}
