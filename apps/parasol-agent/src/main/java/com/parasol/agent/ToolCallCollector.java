package com.parasol.agent;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import jakarta.enterprise.context.RequestScoped;

/**
 * Per-request record of the MCP tools the agent called.
 *
 * <p>Request-scoped so each {@code POST /agent/ask} sees only its own tool calls. Populated by
 * {@link ToolCallRecorder} (a {@code ChatModelListener}) as the model asks for tools, then read
 * by {@link AgentResource} to build the {@code toolCalls} in the response. This is how we surface
 * the calls even though LangChain4j's {@code Result.toolExecutions()} does not include MCP-tool
 * executions (only local {@code @Tool} beans).
 */
@RequestScoped
public class ToolCallCollector {

    private final List<ToolCall> calls = Collections.synchronizedList(new ArrayList<>());

    void record(String tool, String arguments) {
        calls.add(new ToolCall(tool, arguments, null));
    }

    List<ToolCall> calls() {
        return List.copyOf(calls);
    }
}
