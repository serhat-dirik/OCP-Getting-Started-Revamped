package com.parasol.mcpcli;

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.agent.tool.ToolSpecification;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;

/**
 * A fully-mocked {@link ChatModel} for offline unit tests: it returns a fixed script of responses
 * instead of calling a real model, and it fires the attached {@link ChatModelListener}s exactly as a
 * real model does (a real model's {@code chat(ChatRequest)} invokes its listeners; LangChain4j's
 * {@code ToolService} calls that same {@code chat(ChatRequest)}). That lets a test drive the real
 * {@code AiServices} tool-execution loop - and prove {@link ToolCallTracer} captures the calls -
 * with no MaaS endpoint and no cluster.
 *
 * <p>It also records every tool name it was <em>offered</em> across the run, so a test can assert the
 * read-only filter removed a mutating tool from what the model can even see.
 */
class ScriptedChatModel implements ChatModel {

    private final Deque<ChatResponse> script = new ArrayDeque<>();
    private final List<ChatModelListener> listeners;
    private final Set<String> offeredToolNames = new LinkedHashSet<>();
    private int requestCount;

    ScriptedChatModel(List<ChatModelListener> listeners, ChatResponse... responses) {
        this.listeners = listeners;
        for (ChatResponse r : responses) {
            script.addLast(r);
        }
    }

    @Override
    public ChatResponse chat(ChatRequest chatRequest) {
        requestCount++;
        if (chatRequest.toolSpecifications() != null) {
            for (ToolSpecification spec : chatRequest.toolSpecifications()) {
                offeredToolNames.add(spec.name());
            }
        }
        for (ChatModelListener listener : listeners) {
            listener.onRequest(new ChatModelRequestContext(chatRequest, ModelProvider.OTHER, new HashMap<>()));
        }
        if (script.isEmpty()) {
            throw new IllegalStateException("ScriptedChatModel exhausted after " + requestCount + " request(s)");
        }
        ChatResponse response = script.removeFirst();
        for (ChatModelListener listener : listeners) {
            listener.onResponse(new ChatModelResponseContext(response, chatRequest, ModelProvider.OTHER, new HashMap<>()));
        }
        return response;
    }

    Set<String> offeredToolNames() {
        return offeredToolNames;
    }

    int requestCount() {
        return requestCount;
    }

    // --- response builders --------------------------------------------------

    /** A response in which the model asks to call one tool. */
    static ChatResponse toolResponse(String id, String toolName, String argumentsJson) {
        ToolExecutionRequest request = ToolExecutionRequest.builder()
                .id(id).name(toolName).arguments(argumentsJson).build();
        return ChatResponse.builder().aiMessage(AiMessage.from(request)).build();
    }

    /** A final text response (no tool calls). */
    static ChatResponse textResponse(String text) {
        return ChatResponse.builder().aiMessage(AiMessage.from(text)).build();
    }
}
