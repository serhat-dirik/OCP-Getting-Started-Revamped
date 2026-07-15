package com.parasol.mcpcli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Set;
import java.util.stream.Collectors;

import org.junit.jupiter.api.Test;

import dev.langchain4j.agent.tool.ToolSpecification;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.service.tool.ToolProviderRequest;
import dev.langchain4j.service.tool.ToolProviderResult;

/**
 * Proves the read-only filter removes mutating tools - both spec and executor - from what a delegate
 * (mock MCP) provider offers, and reports what it hid. This is the client-side seatbelt; the test
 * also documents (in names) that RBAC is the real boundary.
 */
class ReadOnlyToolFilterTest {

    private ToolProviderRequest anyRequest() {
        return new ToolProviderRequest("memory-id", UserMessage.from("inspect the cluster"));
    }

    private Set<String> toolNames(ToolProviderResult result) {
        return result.tools().keySet().stream().map(ToolSpecification::name).collect(Collectors.toSet());
    }

    @Test
    void hidesMutatingToolsAndKeepsReadOnlyOnes() {
        FakeToolProvider mcp = new FakeToolProvider()
                .add("pods_list", "[]")
                .add("events_list", "[]")
                .add("pods_delete", "deleted")
                .add("resources_create_or_update", "applied");

        ReadOnlyToolFilter filter = new ReadOnlyToolFilter(mcp, new ReadOnlyToolPolicy());
        ToolProviderResult filtered = filter.provideTools(anyRequest());

        assertEquals(Set.of("pods_list", "events_list"), toolNames(filtered),
                "only read-only tools should survive the filter");
        assertFalse(toolNames(filtered).contains("pods_delete"));
        assertFalse(toolNames(filtered).contains("resources_create_or_update"));
    }

    @Test
    void recordsWhatItFilteredOut() {
        FakeToolProvider mcp = new FakeToolProvider()
                .add("pods_list", "[]")
                .add("pods_delete", "deleted")
                .add("scale_deployment", "scaled");

        ReadOnlyToolFilter filter = new ReadOnlyToolFilter(mcp, new ReadOnlyToolPolicy());
        filter.provideTools(anyRequest());

        assertEquals(Set.of("pods_delete", "scale_deployment"), filter.filteredOut().keySet());
        assertEquals("delete", filter.filteredOut().get("pods_delete"));
        assertEquals("scale", filter.filteredOut().get("scale_deployment"));
    }

    @Test
    void keepsEverythingWhenNothingIsMutating() {
        FakeToolProvider mcp = new FakeToolProvider().add("pods_list", "[]").add("resources_get", "{}");
        ReadOnlyToolFilter filter = new ReadOnlyToolFilter(mcp, new ReadOnlyToolPolicy());
        ToolProviderResult filtered = filter.provideTools(anyRequest());

        assertEquals(Set.of("pods_list", "resources_get"), toolNames(filtered));
        assertTrue(filter.filteredOut().isEmpty());
    }

    @Test
    void rawProviderOffersEverythingWhenWritesAreAllowed() {
        // The "allow-writes" path uses the delegate directly (no filter): all tools are offered, and
        // then RBAC - not the client - is what stops a disallowed write on the cluster.
        FakeToolProvider mcp = new FakeToolProvider().add("pods_list", "[]").add("pods_delete", "deleted");
        assertEquals(Set.of("pods_list", "pods_delete"), toolNames(mcp.provideTools(anyRequest())));
    }
}
