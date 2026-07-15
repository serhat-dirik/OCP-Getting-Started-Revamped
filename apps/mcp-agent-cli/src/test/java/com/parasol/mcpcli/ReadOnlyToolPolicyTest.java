package com.parasol.mcpcli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Set;

import org.junit.jupiter.api.Test;

/**
 * The read-only-first classifier: which tool names are safe to expose in read-only mode. Exhaustive
 * and fast - no model, no MCP. This encodes the safety posture M24 teaches (and is honest that it is
 * a heuristic, not the RBAC boundary).
 */
class ReadOnlyToolPolicyTest {

    private final ReadOnlyToolPolicy policy = new ReadOnlyToolPolicy();

    @Test
    void readOnlyToolsAreAllowed() {
        for (String name : new String[] {
                "pods_list", "pods_get", "pods_log", "events_list", "resources_get",
                "resources_list", "namespaces_list", "projects_list", "configuration_view" }) {
            assertTrue(policy.isReadOnly(name), name + " should be read-only");
            assertTrue(policy.mutatingToken(name).isEmpty(), name + " should match no write verb");
        }
    }

    @Test
    void mutatingToolsAreFlagged() {
        for (String name : new String[] {
                "pods_delete", "pods_exec", "resources_create_or_update", "resources_delete",
                "scale_deployment", "pods_run", "resources_create", "deployment_restart" }) {
            assertFalse(policy.isReadOnly(name), name + " should be flagged mutating");
            assertTrue(policy.mutatingToken(name).isPresent(), name + " should match a write verb");
        }
    }

    @Test
    void matchIsCaseInsensitiveAndReportsTheVerb() {
        assertFalse(policy.isReadOnly("PODS_DELETE"));
        assertEquals("delete", policy.mutatingToken("PODS_DELETE").orElseThrow());
    }

    @Test
    void readToolsWhoseNounsContainAVerbAreNotFalselyFlagged() {
        // Whole-token matching must NOT hide read tools whose *nouns* embed a verb substring:
        // "deployment" contains "deploy", "replicaset"/"statefulset" contain "set".
        for (String name : new String[] {
                "get_deployment", "deployments_list", "replicasets_list", "statefulsets_get",
                "daemonsets_list", "resources_get" }) {
            assertTrue(policy.isReadOnly(name), name + " is a read tool and must stay visible");
        }
    }

    @Test
    void reportsTheFirstVerbTokenDeterministically() {
        // "scale_deployment" contains both "scale" (verb) and "deployment" (noun w/ "deploy");
        // whole-token, left-to-right matching returns "scale", never the noun's substring.
        assertEquals("scale", policy.mutatingToken("scale_deployment").orElseThrow());
    }

    @Test
    void splitsCamelCaseNames() {
        assertFalse(policy.isReadOnly("scaleDeployment"));
        assertTrue(policy.isReadOnly("getDeployment"));
    }

    @Test
    void nullNameFailsClosed() {
        assertFalse(policy.isReadOnly(null));
        assertTrue(policy.mutatingToken(null).isPresent());
    }

    @Test
    void tokenSetIsConfigurable() {
        // A custom denylist: only "zap" is mutating, so the default verbs no longer apply.
        ReadOnlyToolPolicy custom = ReadOnlyToolPolicy.fromTokens("zap, frobnicate");
        assertFalse(custom.isReadOnly("zap_cluster"));
        assertTrue(custom.isReadOnly("pods_delete"), "delete is not in the custom denylist");
    }

    @Test
    void blankTokenOverrideFallsBackToDefaults() {
        ReadOnlyToolPolicy fallback = ReadOnlyToolPolicy.fromTokens("   ");
        assertEquals(ReadOnlyToolPolicy.DEFAULT_MUTATING_TOKENS, fallback.mutatingTokens());
        assertFalse(fallback.isReadOnly("pods_delete"));
    }

    @Test
    void defaultTokenSetIsNonEmpty() {
        Set<String> tokens = policy.mutatingTokens();
        assertTrue(tokens.contains("delete"));
        assertTrue(tokens.contains("create"));
        assertTrue(tokens.contains("patch"));
    }
}
