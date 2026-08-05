package com.parasol.agent;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
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

    // ---- credential redaction -------------------------------------------------------------------
    // The gateway echoes a rejected key back in full, and `detail` is BOTH logged AND serialised
    // into the 502 body the attendee receives. These pin the redaction that keeps it out of each.
    // Every literal below is a synthetic stand-in of realistic length - never a real credential.

    private static final String FAKE_KEY = "sk-SYNTHETIC-not-a-real-key-0123456789";
    private static final String FAKE_JWT =
            "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0Iiwibn0.c2lnbmF0dXJlLXBsYWNlaG9sZGVy";

    @Test
    void gatewayEchoOfTheRejectedKeyIsRedacted() {
        String body = "Authentication Error, Virtual Key expected. Received=" + FAKE_KEY
                + ", expected to start with 'sk-'";
        String redacted = AgentResource.redactCredentials(body);
        assertFalse(redacted.contains(FAKE_KEY), "the echoed key must not survive redaction");
        assertTrue(redacted.contains("Received=<redacted>"));
        // The diagnostic must stay usable: this is how the attendee tells "wrong kind of key" from
        // the other two faults, so the trailing clause has to survive intact.
        assertTrue(redacted.contains("expected to start with 'sk-'"));
    }

    @Test
    void aJwtStagedWhereAnApiKeyWasExpectedIsRedactedButStillDiagnosable() {
        String redacted = AgentResource.redactCredentials("Virtual Key expected. Received=" + FAKE_JWT);
        assertFalse(redacted.contains(FAKE_JWT));
        assertFalse(redacted.contains("c2lnbmF0dXJlLXBsYWNlaG9sZGVy"), "the signature must not survive");
        assertTrue(redacted.contains("Received=<redacted>"));
    }

    @Test
    void aKeyAnywhereInTheMessageIsRedactedNotJustInTheReceivedField() {
        // The whole point: safety must not depend on the credential sitting in a known field at a
        // known offset. A bare key, or one behind an Authorization header, is caught by shape.
        assertFalse(AgentResource.redactCredentials("upstream rejected " + FAKE_KEY + " at /chat/completions")
                .contains(FAKE_KEY));
        assertFalse(AgentResource.redactCredentials("sent header Authorization: Bearer " + FAKE_JWT)
                .contains(FAKE_JWT));
        assertTrue(AgentResource.redactCredentials("Authorization: Bearer " + FAKE_KEY)
                .contains("Bearer <redacted>"));
    }

    @Test
    void theModelScopeFaultSurvivesRedactionWordForWord() {
        // The third key fault is diagnosed purely from this list. Over-eager redaction would make
        // the page's troubleshooting table unusable, which is its own kind of failure.
        String scoped = "key not allowed to access model. This key can only access models=[qwen3-14b]";
        assertEquals(scoped, AgentResource.redactCredentials(scoped));
    }

    @Test
    void ordinaryTransportFailuresArePassedThroughUnchanged() {
        assertEquals("Connection reset by peer", AgentResource.redactCredentials("Connection reset by peer"));
        assertEquals("Read timed out", AgentResource.redactCredentials("Read timed out"));
        assertNull(AgentResource.redactCredentials(null));
    }

    @Test
    void causeChainReportsTypesAndNeverMessages() {
        // The logger is handed this instead of the throwable, because printStackTrace would write
        // every cause's raw getMessage() - the exact text the key is echoed inside.
        Exception e = new RuntimeException("wrapper carrying " + FAKE_KEY,
                new IllegalStateException("status code: 401, Received=" + FAKE_KEY));
        String chain = AgentResource.causeChain(e);
        assertEquals("RuntimeException -> IllegalStateException", chain);
        assertFalse(chain.contains(FAKE_KEY));
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

        AgentResource.AgentInfo agentInfo = new AgentResource.AgentInfo(
                "qwen3-14b", "http://claims-db:8080/mcp/sse", "http://policy-docs:8080/mcp/sse",
                "built-in default", GroundingPrompt.DEFAULT_PROMPT);
        assertEquals("built-in default", agentInfo.groundingPromptSource());
        assertTrue(agentInfo.groundingPrompt().contains("get_claim") || agentInfo.groundingPrompt().contains("tools"));
    }

    // ---- grounding as configuration -------------------------------------------------------------
    // The system prompt decides whether this agent calls a tool at all, so an unset, blank or
    // whitespace-only value must NEVER leave the agent with no grounding: it falls back to the
    // built-in prompt. The workshop deliberately ships a WEAKER prompt in a ConfigMap for the lab
    // (see the entry state) - that path is exercised here as "a supplied value wins".

    @Test
    void anAbsentGroundingPromptFallsBackToTheBuiltInDefault() {
        GroundingPrompt grounding = new GroundingPrompt(java.util.Optional.empty());
        assertEquals(GroundingPrompt.DEFAULT_PROMPT, grounding.text());
        assertEquals("built-in default", grounding.source());
    }

    @Test
    void aBlankGroundingPromptIsTreatedAsUnsetRatherThanAsAnEmptySystemMessage() {
        // An env var set to "" or to a stray newline is the realistic accident here, and handing the
        // model an empty system message is precisely the ungrounded state this whole mechanism exists
        // to make visible - it must not be reachable by accident.
        assertEquals(GroundingPrompt.DEFAULT_PROMPT, new GroundingPrompt(java.util.Optional.of("")).text());
        assertEquals(GroundingPrompt.DEFAULT_PROMPT, new GroundingPrompt(java.util.Optional.of("  \n\t ")).text());
    }

    @Test
    void aConfiguredGroundingPromptWinsAndSaysSo() {
        String weak = "You are the Parasol Insurance claims assistant. Answer staff questions.";
        GroundingPrompt grounding = new GroundingPrompt(java.util.Optional.of(weak));
        assertEquals(weak, grounding.text());
        assertTrue(grounding.source().contains(GroundingPrompt.PROPERTY));
    }

    @Test
    void theProviderHandsLangchainExactlyTheResolvedText() {
        // This is the method the model's system message actually comes from; if it ever returned
        // Optional.empty() the agent would run with NO system prompt and quietly stop grounding.
        GroundingPrompt grounding = new GroundingPrompt(java.util.Optional.of("weak"));
        assertEquals(java.util.Optional.of("weak"), grounding.getSystemMessage("any-memory-id"));
        assertEquals(java.util.Optional.of(GroundingPrompt.DEFAULT_PROMPT),
                new GroundingPrompt(java.util.Optional.empty()).getSystemMessage(null));
    }

    @Test
    void theBuiltInDefaultActuallyDirectsTheModelAtItsTools() {
        // The fallback is what a bare `podman run` and `quarkus dev` get. If it ever stopped naming
        // the tools, the image would ship ungrounded and only an on-cluster run would notice.
        assertTrue(GroundingPrompt.DEFAULT_PROMPT.contains("You have tools"));
        assertTrue(GroundingPrompt.DEFAULT_PROMPT.contains("search_policies"));
    }
}
