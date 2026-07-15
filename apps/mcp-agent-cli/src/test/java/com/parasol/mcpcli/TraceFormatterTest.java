package com.parasol.mcpcli;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

/**
 * Pins the exact shape of the printed output - the tool-call trace is the auditable artifact M24 has
 * attendees read, so its formatting is worth a test.
 */
class TraceFormatterTest {

    @Test
    void traceRendersNameArgumentsAndResultForEachCall() {
        String out = TraceFormatter.trace(List.of(
                new ToolCall("pods_list", "{\"namespace\":\"user1-dev\"}", "[{\"ready\":\"0/1\"}]"),
                new ToolCall("resources_get", "{\"name\":\"parasol-claims\"}", "probe: /q/health/reddy")));

        assertTrue(out.contains("TOOL-CALL TRACE (2 calls)"));
        assertTrue(out.contains("[1] pods_list"));
        assertTrue(out.contains("{\"namespace\":\"user1-dev\"}"));
        assertTrue(out.contains("[{\"ready\":\"0/1\"}]"));
        assertTrue(out.contains("[2] resources_get"));
        assertTrue(out.contains("probe: /q/health/reddy"));
        // ordering: pods_list is rendered before resources_get
        assertTrue(out.indexOf("pods_list") < out.indexOf("resources_get"));
    }

    @Test
    void traceHandlesTheNoToolsCase() {
        String out = TraceFormatter.trace(List.of());
        assertTrue(out.contains("(0 calls)"));
        assertTrue(out.contains("without calling any tools"));
    }

    @Test
    void singularCallWording() {
        String out = TraceFormatter.trace(List.of(new ToolCall("pods_list", "{}", "[]")));
        assertTrue(out.contains("(1 call)"));
    }

    @Test
    void pendingResultIsShownNotSwallowed() {
        String out = TraceFormatter.trace(List.of(new ToolCall("pods_list", "{}", null)));
        assertTrue(out.contains("(no result captured)"));
    }

    @Test
    void longResultsAreTruncated() {
        String big = "x".repeat(TraceFormatter.MAX_RESULT_CHARS + 500);
        String out = TraceFormatter.trace(List.of(new ToolCall("pods_log", "{}", big)));
        assertTrue(out.contains("truncated"));
        assertFalse(out.contains(big), "the full oversized result should not be printed");
    }

    @Test
    void headerReflectsReadOnlyPosture() {
        String ro = TraceFormatter.header("qwen3-14b", "http://platform:8080/mcp/sse", true, 1);
        assertTrue(ro.contains("qwen3-14b"));
        assertTrue(ro.contains("READ-ONLY"));

        String rw = TraceFormatter.header("qwen3-14b", "http://platform:8080/mcp/sse", false, 1);
        assertTrue(rw.contains("WRITES ALLOWED"));
        assertTrue(rw.contains("RBAC is the boundary"));
    }

    @Test
    void readOnlyNoteListsHiddenTools() {
        Map<String, String> hidden = new LinkedHashMap<>();
        hidden.put("pods_delete", "delete");
        hidden.put("scale_deployment", "scale");
        String note = TraceFormatter.readOnlyNote(hidden);
        assertTrue(note.contains("hid 2 mutating tools"));
        assertTrue(note.contains("pods_delete"));
        assertTrue(note.contains("scale_deployment"));
        assertTrue(note.contains("RBAC remains the real boundary"));
    }

    @Test
    void readOnlyNoteWhenNothingHidden() {
        assertTrue(TraceFormatter.readOnlyNote(Map.of()).contains("no mutating tools"));
    }

    @Test
    void answerIsLabelled() {
        String out = TraceFormatter.answer("The pod is 0/1 Ready.");
        assertTrue(out.contains("ANSWER"));
        assertTrue(out.contains("The pod is 0/1 Ready."));
    }
}
