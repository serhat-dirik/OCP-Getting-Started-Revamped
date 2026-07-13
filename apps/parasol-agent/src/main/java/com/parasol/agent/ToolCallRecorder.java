package com.parasol.agent;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.spi.CDI;

/**
 * A {@link ChatModelListener} that records the tools the model asked to call.
 *
 * <p>quarkus-langchain4j auto-registers every {@code ChatModelListener} CDI bean around the model.
 * On each response we pull the {@link AiMessage}'s tool-execution requests (name + JSON arguments)
 * and hand them to the request-scoped {@link ToolCallCollector}. We resolve the collector through
 * {@code CDI.current()} and swallow a missing request context, because the model callback may run
 * on a different (event-loop) thread than the request - if the context is not propagated we simply
 * do not record (the answer is unaffected).
 */
@ApplicationScoped
public class ToolCallRecorder implements ChatModelListener {

    @Override
    public void onResponse(ChatModelResponseContext responseContext) {
        AiMessage aiMessage = responseContext.chatResponse().aiMessage();
        if (aiMessage == null || !aiMessage.hasToolExecutionRequests()) {
            return;
        }
        try {
            ToolCallCollector collector = CDI.current().select(ToolCallCollector.class).get();
            for (ToolExecutionRequest request : aiMessage.toolExecutionRequests()) {
                collector.record(request.name(), request.arguments());
            }
        } catch (RuntimeException contextNotActive) {
            // No active request context on this thread - skip recording, keep answering.
        }
    }
}
