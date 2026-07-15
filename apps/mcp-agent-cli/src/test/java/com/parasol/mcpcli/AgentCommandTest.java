package com.parasol.mcpcli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/**
 * Fast, offline tests of the CLI's failure-reporting logic - especially the graceful handling of an
 * expired/rejected MaaS key, so a short-lived key degrades to one clean line instead of a stack
 * trace. Same contract {@code parasol-agent} pins for its 401 path.
 */
class AgentCommandTest {

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
