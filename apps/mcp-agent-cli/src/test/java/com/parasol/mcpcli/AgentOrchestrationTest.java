package com.parasol.mcpcli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.api.Test;

/**
 * The headline test: mock the model and the MCP server, then drive the tool-execution loop
 * (see {@link ToolLoopHarness}) end-to-end and prove the whole contract off-cluster -
 * <ul>
 *   <li>the model's tool request is actually executed against the (fake) MCP provider,</li>
 *   <li>the tool result is fed back and the model's final answer is returned,</li>
 *   <li>{@link ToolCallTracer} captured the call with name + arguments + result,</li>
 *   <li>under read-only the mutating tool is neither offered to the model nor executed.</li>
 * </ul>
 * The collaborators here - {@link ReadOnlyToolFilter}, the tool executors, {@link ToolCallTracer},
 * and the scripted model that fires the tracer - are the same ones {@link AgentFactory} wires into
 * the real {@code AiServices} in production; only the model and the MCP transport are mocked.
 */
class AgentOrchestrationTest {

    @Test
    void diagnoseLoopExecutesReadToolTracesItAndHidesWritesUnderReadOnly() {
        ToolCallTracer tracer = new ToolCallTracer();
        FakeToolProvider mcp = new FakeToolProvider()
                .add("pods_list", "[{\"name\":\"parasol-claims-1\",\"ready\":\"0/1\",\"status\":\"Running\"}]")
                .add("pods_delete", "deleted"); // a write tool the read-only filter must hide
        ReadOnlyToolFilter readOnly = new ReadOnlyToolFilter(mcp, new ReadOnlyToolPolicy());

        ScriptedChatModel model = new ScriptedChatModel(List.of(tracer),
                ScriptedChatModel.toolResponse("call-1", "pods_list", "{\"namespace\":\"user1-dev\"}"),
                ScriptedChatModel.textResponse("parasol-claims-1 is 0/1 Ready in user1-dev."));

        String answer = ToolLoopHarness.run(model, readOnly,
                "diagnose why parasol-claims is not Ready in user1-dev", 5);

        // orchestration: the read tool ran, the write tool did not, the scripted answer came back
        assertEquals("parasol-claims-1 is 0/1 Ready in user1-dev.", answer);
        assertTrue(mcp.executed().contains("pods_list"));
        assertFalse(mcp.executed().contains("pods_delete"));

        // read-only posture: the mutating tool was never even offered to the model
        assertTrue(model.offeredToolNames().contains("pods_list"));
        assertFalse(model.offeredToolNames().contains("pods_delete"), "read-only must hide the write tool");
        assertTrue(readOnly.filteredOut().containsKey("pods_delete"));

        // trace: name + arguments + result captured for the one call
        List<ToolCall> trace = tracer.trace();
        assertEquals(1, trace.size());
        assertEquals("pods_list", trace.get(0).name());
        assertEquals("{\"namespace\":\"user1-dev\"}", trace.get(0).arguments());
        assertTrue(trace.get(0).result().contains("0/1"));
    }

    @Test
    void writeToolRunsWhenWritesAreAllowed() {
        // No read-only filter (the --allow-writes path): the client does not block the write - on a
        // real cluster RBAC on the ServiceAccount is what would.
        ToolCallTracer tracer = new ToolCallTracer();
        FakeToolProvider mcp = new FakeToolProvider()
                .add("resources_patch", "patched: readinessProbe.httpGet.path=/q/health/ready");

        ScriptedChatModel model = new ScriptedChatModel(List.of(tracer),
                ScriptedChatModel.toolResponse("call-1", "resources_patch", "{\"path\":\"/q/health/ready\"}"),
                ScriptedChatModel.textResponse("Patched the readiness probe and rolled out."));

        String answer = ToolLoopHarness.run(model, mcp, "fix the readiness probe on parasol-claims", 5);

        assertEquals("Patched the readiness probe and rolled out.", answer);
        assertTrue(mcp.executed().contains("resources_patch"));

        List<ToolCall> trace = tracer.trace();
        assertEquals(1, trace.size());
        assertEquals("resources_patch", trace.get(0).name());
        assertTrue(trace.get(0).result().contains("/q/health/ready"));
    }

    @Test
    void multiStepDiagnoseThenReadAgainIsTracedInOrder() {
        // Two read tools across two steps: proves the loop feeds each result back and the trace keeps
        // order across turns.
        ToolCallTracer tracer = new ToolCallTracer();
        FakeToolProvider mcp = new FakeToolProvider()
                .add("pods_list", "[{\"name\":\"parasol-claims-1\",\"ready\":\"0/1\"}]")
                .add("resources_get", "readinessProbe.httpGet.path: /q/health/reddy");
        ReadOnlyToolFilter readOnly = new ReadOnlyToolFilter(mcp, new ReadOnlyToolPolicy());

        ScriptedChatModel model = new ScriptedChatModel(List.of(tracer),
                ScriptedChatModel.toolResponse("c1", "pods_list", "{\"namespace\":\"user1-dev\"}"),
                ScriptedChatModel.toolResponse("c2", "resources_get", "{\"kind\":\"Deployment\",\"name\":\"parasol-claims\"}"),
                ScriptedChatModel.textResponse("The readiness probe path is misspelled: /q/health/reddy."));

        String answer = ToolLoopHarness.run(model, readOnly, "why is parasol-claims not Ready?", 5);

        assertEquals("The readiness probe path is misspelled: /q/health/reddy.", answer);
        List<ToolCall> trace = tracer.trace();
        assertEquals(2, trace.size());
        assertEquals("pods_list", trace.get(0).name());
        assertEquals("resources_get", trace.get(1).name());
        assertTrue(trace.get(1).result().contains("/q/health/reddy"));
    }

    @Test
    void answersDirectlyWhenNoToolIsNeeded() {
        ToolCallTracer tracer = new ToolCallTracer();
        FakeToolProvider mcp = new FakeToolProvider().add("pods_list", "[]");
        ScriptedChatModel model = new ScriptedChatModel(List.of(tracer),
                ScriptedChatModel.textResponse("I did not need any cluster data to answer that."));

        String answer = ToolLoopHarness.run(model, new ReadOnlyToolFilter(mcp, new ReadOnlyToolPolicy()),
                "what is MCP?", 5);

        assertEquals("I did not need any cluster data to answer that.", answer);
        assertTrue(tracer.trace().isEmpty());
        assertTrue(mcp.executed().isEmpty());
    }
}
