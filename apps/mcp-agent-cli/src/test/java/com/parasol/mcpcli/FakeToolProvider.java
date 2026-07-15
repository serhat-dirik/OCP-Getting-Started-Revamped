package com.parasol.mcpcli;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import dev.langchain4j.agent.tool.ToolSpecification;
import dev.langchain4j.model.chat.request.json.JsonObjectSchema;
import dev.langchain4j.service.tool.ToolExecutor;
import dev.langchain4j.service.tool.ToolProvider;
import dev.langchain4j.service.tool.ToolProviderRequest;
import dev.langchain4j.service.tool.ToolProviderResult;

/**
 * A stand-in for an MCP server at the LangChain4j tool-provider layer - which is exactly where the
 * real MCP integration plugs in ({@code McpToolProvider} is itself a {@link ToolProvider}). Each
 * registered tool has a canned result; executing it records that it ran, so a test can prove the
 * orchestration actually invoked the tool (and that a filtered-out tool never ran). No MCP transport,
 * no cluster.
 */
class FakeToolProvider implements ToolProvider {

    private final Map<String, String> cannedResults = new LinkedHashMap<>();
    private final Set<String> executed = ConcurrentHashMap.newKeySet();

    FakeToolProvider add(String toolName, String result) {
        cannedResults.put(toolName, result);
        return this;
    }

    @Override
    public ToolProviderResult provideTools(ToolProviderRequest request) {
        ToolProviderResult.Builder builder = ToolProviderResult.builder();
        cannedResults.forEach((name, result) -> {
            ToolSpecification spec = ToolSpecification.builder()
                    .name(name)
                    .description("fake tool " + name)
                    .parameters(JsonObjectSchema.builder().build())
                    .build();
            ToolExecutor executor = (executionRequest, memoryId) -> {
                executed.add(executionRequest.name());
                return cannedResults.get(executionRequest.name());
            };
            builder.add(spec, executor);
        });
        return builder.build();
    }

    Set<String> executed() {
        return executed;
    }
}
