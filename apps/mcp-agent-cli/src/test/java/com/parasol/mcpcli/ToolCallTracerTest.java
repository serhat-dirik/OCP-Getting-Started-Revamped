package com.parasol.mcpcli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.util.HashMap;
import java.util.List;

import org.junit.jupiter.api.Test;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;

/**
 * Proves the tracer captures MCP tool calls from the real LangChain4j model callbacks and pairs each
 * returned result back to its request (by id, falling back to tool name) - the mechanism behind the
 * printed tool-call trace. Uses genuine LangChain4j message types, no model.
 */
class ToolCallTracerTest {

    private ChatModelResponseContext responseWith(AiMessage aiMessage) {
        ChatResponse response = ChatResponse.builder().aiMessage(aiMessage).build();
        ChatRequest request = ChatRequest.builder().messages(UserMessage.from("prompt")).build();
        return new ChatModelResponseContext(response, request, ModelProvider.OTHER, new HashMap<>());
    }

    private ChatModelRequestContext requestWith(List<ChatMessage> messages) {
        ChatRequest request = ChatRequest.builder().messages(messages).build();
        return new ChatModelRequestContext(request, ModelProvider.OTHER, new HashMap<>());
    }

    private static ToolExecutionRequest req(String id, String name, String args) {
        return ToolExecutionRequest.builder().id(id).name(name).arguments(args).build();
    }

    @Test
    void capturesNameArgsAndResultInOrderPairedById() {
        ToolCallTracer tracer = new ToolCallTracer();

        ToolExecutionRequest a = req("1", "pods_list", "{\"namespace\":\"user1-dev\"}");
        ToolExecutionRequest b = req("2", "resources_get", "{\"kind\":\"Deployment\",\"name\":\"parasol-claims\"}");
        AiMessage aiMessage = AiMessage.from(List.of(a, b));

        // Model asks for two tools...
        tracer.onResponse(responseWith(aiMessage));
        // ...then the next request carries both results (deliberately out of order to prove id pairing).
        tracer.onRequest(requestWith(List.of(
                UserMessage.from("prompt"),
                aiMessage,
                ToolExecutionResultMessage.from("2", "resources_get", "probe path is /q/health/reddy"),
                ToolExecutionResultMessage.from("1", "pods_list", "[{\"name\":\"parasol-claims-1\",\"ready\":\"0/1\"}]"))));

        List<ToolCall> trace = tracer.trace();
        assertEquals(2, trace.size());
        assertEquals("pods_list", trace.get(0).name());
        assertEquals("{\"namespace\":\"user1-dev\"}", trace.get(0).arguments());
        assertEquals("[{\"name\":\"parasol-claims-1\",\"ready\":\"0/1\"}]", trace.get(0).result());
        assertEquals("resources_get", trace.get(1).name());
        assertEquals("probe path is /q/health/reddy", trace.get(1).result());
    }

    @Test
    void pairsByToolNameWhenIdsDoNotMatch() {
        ToolCallTracer tracer = new ToolCallTracer();
        tracer.onResponse(responseWith(AiMessage.from(req("A1", "pods_log", "{\"pod\":\"x\"}"))));
        // Result carries a different id but the same tool name -> name fallback pairs it.
        tracer.onRequest(requestWith(List.of(
                UserMessage.from("p"),
                ToolExecutionResultMessage.from("B2", "pods_log", "log line"))));

        List<ToolCall> trace = tracer.trace();
        assertEquals(1, trace.size());
        assertEquals("pods_log", trace.get(0).name());
        assertEquals("log line", trace.get(0).result());
    }

    @Test
    void recordsAResultThatHasNoMatchingRequestRatherThanDroppingIt() {
        ToolCallTracer tracer = new ToolCallTracer();
        tracer.onRequest(requestWith(List.of(
                UserMessage.from("p"),
                ToolExecutionResultMessage.from("z", "mystery_tool", "surprise"))));

        List<ToolCall> trace = tracer.trace();
        assertEquals(1, trace.size());
        assertEquals("mystery_tool", trace.get(0).name());
        assertEquals("surprise", trace.get(0).result());
        assertNull(trace.get(0).arguments());
    }

    @Test
    void resetClearsTheTrace() {
        ToolCallTracer tracer = new ToolCallTracer();
        tracer.onResponse(responseWith(AiMessage.from(req("1", "pods_list", "{}"))));
        assertEquals(1, tracer.trace().size());
        tracer.reset();
        assertEquals(0, tracer.trace().size());
    }
}
