package com.parasol.mcpcli;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.agent.tool.ToolSpecification;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.service.tool.ToolExecutor;
import dev.langchain4j.service.tool.ToolProvider;
import dev.langchain4j.service.tool.ToolProviderRequest;
import dev.langchain4j.service.tool.ToolProviderResult;

/**
 * A faithful, offline re-creation of LangChain4j's {@code AiServices} tool-execution loop, used to
 * prove the orchestration end-to-end without the {@code AiServices} proxy.
 *
 * <p><strong>Why a harness instead of the real {@code AiServices}?</strong> quarkus-langchain4j
 * replaces LangChain4j's service/prompt SPIs with Arc-backed ones (context factory, services factory,
 * prompt-template factory). In a plain JUnit test there is no running Arc container, so invoking the
 * real {@code AiServices} proxy NPEs; and {@code @QuarkusTest} is not an option here because booting
 * the app would make the MCP client block on the unreachable default endpoint (the same reason
 * {@code parasol-agent}'s tests stay plain JUnit). {@link AgentFactory} uses the real
 * {@code AiServices.builder(...)} in production, where Arc is up.
 *
 * <p>This loop runs the <em>same steps</em> {@code AiServices} runs, over the CLI's <em>real</em>
 * collaborators: the (mock) {@link ChatModel} - which fires {@link ToolCallTracer} exactly as a real
 * model does - the real {@link ToolProvider} (including {@link ReadOnlyToolFilter}), and the real
 * {@link ToolExecutor}s the provider returns. So it genuinely exercises tool selection, execution,
 * result feedback, the step cap, and the trace.
 */
final class ToolLoopHarness {

    private ToolLoopHarness() {
    }

    static String run(ChatModel model, ToolProvider toolProvider, String userPrompt, int maxSteps) {
        UserMessage userMessage = UserMessage.from(userPrompt);

        ToolProviderResult provided = toolProvider.provideTools(new ToolProviderRequest("memory-id", userMessage));
        Map<String, ToolExecutor> executorByName = new HashMap<>();
        List<ToolSpecification> specifications = new ArrayList<>();
        if (provided != null && provided.tools() != null) {
            provided.tools().forEach((spec, executor) -> {
                executorByName.put(spec.name(), executor);
                specifications.add(spec);
            });
        }

        List<ChatMessage> messages = new ArrayList<>();
        messages.add(userMessage);

        for (int step = 0; step < maxSteps; step++) {
            ChatRequest request = ChatRequest.builder()
                    .messages(new ArrayList<>(messages))
                    .toolSpecifications(specifications)
                    .build();
            // The model fires the tracer's onRequest/onResponse itself, as a real model does.
            ChatResponse response = model.chat(request);
            AiMessage aiMessage = response.aiMessage();
            messages.add(aiMessage);

            if (!aiMessage.hasToolExecutionRequests()) {
                return aiMessage.text();
            }
            for (ToolExecutionRequest toolRequest : aiMessage.toolExecutionRequests()) {
                ToolExecutor executor = executorByName.get(toolRequest.name());
                String result = executor == null
                        ? "ERROR: tool not available to this client: " + toolRequest.name()
                        : executor.execute(toolRequest, "memory-id");
                messages.add(ToolExecutionResultMessage.from(toolRequest, result));
            }
        }
        throw new IllegalStateException("tool loop exceeded maxSteps=" + maxSteps);
    }
}
