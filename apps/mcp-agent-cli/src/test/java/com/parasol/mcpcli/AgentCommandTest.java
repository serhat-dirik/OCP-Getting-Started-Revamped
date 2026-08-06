package com.parasol.mcpcli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/**
 * Fast, offline tests of the CLI's failure-reporting logic - especially the graceful handling of an
 * expired/rejected MaaS key, so a short-lived key degrades to one clean line instead of a stack
 * trace. Same contract {@code parasol-agent} pins for its 401 path.
 */
class AgentCommandTest {

    // ---- credential redaction -------------------------------------------------------------------
    // This CLI runs as a one-shot pod holding the MaaS key, and ai-assisted-development pipes its
    // output to the attendee with `oc logs "$POD"`. rootMessage() unwraps to the gateway's own
    // message, which echoes a rejected key back in full. Synthetic stand-ins only below - never a
    // real credential.

    private static final String FAKE_KEY = "sk-SYNTHETIC-not-a-real-key-0123456789";
    private static final String FAKE_JWT =
            "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0Iiwibn0.c2lnbmF0dXJlLXBsYWNlaG9sZGVy";

    @Test
    void gatewayEchoOfTheRejectedKeyIsRedacted() {
        String redacted = AgentCommand.redactCredentials(
                "Authentication Error, Virtual Key expected. Received=" + FAKE_KEY
                        + ", expected to start with 'sk-'");
        assertFalse(redacted.contains(FAKE_KEY));
        assertTrue(redacted.contains("Received=<redacted>"));
        assertTrue(redacted.contains("expected to start with 'sk-'"));
    }

    @Test
    void redactionHoldsOnThePathTheAuthHeuristicDoesNotRecognise() {
        // The reason redaction happens BEFORE the looksLikeAuthFailure branch: this message echoes
        // the key but matches none of the six auth substrings, so it prints via "+ detail".
        String rateLimited = "status code: 429, upstream rejected " + FAKE_KEY + " (quota exceeded)";
        assertFalse(AgentCommand.looksLikeAuthFailure(rateLimited),
                "guard assumption: this message must NOT look like an auth failure");
        assertFalse(AgentCommand.redactCredentials(rateLimited).contains(FAKE_KEY),
                "so the redaction is the only thing standing between the key and oc logs");
    }

    @Test
    void jwtAndBearerShapesAreRedacted() {
        assertFalse(AgentCommand.redactCredentials("staged credential was " + FAKE_JWT).contains(FAKE_JWT));
        assertTrue(AgentCommand.redactCredentials("Authorization: Bearer " + FAKE_KEY)
                .contains("Bearer <redacted>"));
    }

    @Test
    void ordinaryFailuresAndModelScopeListsSurviveUnchanged() {
        assertEquals("Read timed out", AgentCommand.redactCredentials("Read timed out"));
        String scoped = "key not allowed to access model. This key can only access models=[qwen3-14b]";
        assertEquals(scoped, AgentCommand.redactCredentials(scoped));
        assertNull(AgentCommand.redactCredentials(null));
    }

    @Test
    void rootMessageUnwrapsToDeepestCause() {
        Exception e = new RuntimeException("wrapper",
                new IllegalStateException("middle",
                        new RuntimeException("status code: 401, Unauthorized")));
        assertEquals("status code: 401, Unauthorized", AgentCommand.rootMessage(e));
    }

    @Test
    void rootMessageFallsBackToClassNameWhenNoMessage() {
        assertEquals("NullPointerException", AgentCommand.rootMessage(new NullPointerException()));
    }

    @Test
    void authFailureIsDetectedForExpiredOrRejectedKeys() {
        assertTrue(AgentCommand.looksLikeAuthFailure("status code: 401, Unauthorized"));
        assertTrue(AgentCommand.looksLikeAuthFailure("HTTP 403 Forbidden"));
        assertTrue(AgentCommand.looksLikeAuthFailure("Incorrect API key / authentication error"));
        assertTrue(AgentCommand.looksLikeAuthFailure("invalid_api_key"));
    }

    @Test
    void nonAuthFailuresAreNotFlaggedAsAuth() {
        assertFalse(AgentCommand.looksLikeAuthFailure("Connection reset by peer"));
        assertFalse(AgentCommand.looksLikeAuthFailure("Read timed out"));
        assertFalse(AgentCommand.looksLikeAuthFailure(null));
    }
}
