package com.parasol.agent;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/**
 * Fast, offline unit tests for the agent's error-handling logic.
 *
 * <p>Deliberately a PLAIN JUnit test (not {@code @QuarkusTest}): the agent's REST path needs a live
 * model and the two MCP servers, and booting the full app offline makes the langchain4j MCP client
 * block the event loop retrying dead endpoints. The end-to-end REST contract is proven far more
 * strongly by the documented on-cluster smoke against MaaS; here we pin the deterministic bits that
 * decide how a model failure is reported - especially the graceful 401 handling for a short-lived
 * MaaS key.
 */
class AgentResourceTest {

    @Test
    void rootMessageUnwrapsToDeepestCause() {
        Exception e = new RuntimeException("wrapper",
                new IllegalStateException("middle",
                        new RuntimeException("status code: 401, Unauthorized")));
        assertEquals("status code: 401, Unauthorized", AgentResource.rootMessage(e));
    }

    @Test
    void rootMessageFallsBackToClassNameWhenNoMessage() {
        assertEquals("NullPointerException", AgentResource.rootMessage(new NullPointerException()));
    }

    @Test
    void authFailureIsDetectedForExpiredOrRejectedKeys() {
        assertTrue(AgentResource.looksLikeAuthFailure("status code: 401, Unauthorized"));
        assertTrue(AgentResource.looksLikeAuthFailure("HTTP 403 Forbidden"));
        assertTrue(AgentResource.looksLikeAuthFailure("Incorrect API key / authentication error"));
        assertTrue(AgentResource.looksLikeAuthFailure("invalid_api_key"));
    }

    @Test
    void nonAuthFailuresAreNotFlaggedAsAuth() {
        assertFalse(AgentResource.looksLikeAuthFailure("Connection reset by peer"));
        assertFalse(AgentResource.looksLikeAuthFailure("Read timed out"));
        assertFalse(AgentResource.looksLikeAuthFailure(null));
    }

    @Test
    void responseRecordsCarryTheirValues() {
        ToolCall call = new ToolCall("get_claim", "{\"claimNumber\":\"CLM-1001\"}", null);
        AgentResource.Usage usage = new AgentResource.Usage(512, 61, 573);
        AgentResource.AskResponse response = new AgentResource.AskResponse(
                "q", "a", java.util.List.of(call), "qwen3-14b", usage);
        assertEquals("get_claim", response.toolCalls().get(0).tool());
        assertEquals(573, response.tokenUsage().totalTokens());

        AgentResource.AskError error = new AgentResource.AskError("model authentication failed", "401", true, "qwen3-14b");
        assertTrue(error.authFailure());
    }
}
