package com.parasol.mcpcli;

import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentSkipListMap;

import org.jboss.logging.Logger;

import dev.langchain4j.agent.tool.ToolSpecification;
import dev.langchain4j.service.tool.ToolExecutor;
import dev.langchain4j.service.tool.ToolProvider;
import dev.langchain4j.service.tool.ToolProviderRequest;
import dev.langchain4j.service.tool.ToolProviderResult;

/**
 * A {@link ToolProvider} decorator that enforces the CLI's read-only-first posture by removing
 * mutating tools - both their spec <em>and</em> their executor - from what the model is offered.
 *
 * <p>It wraps any delegate provider (in production, the MCP {@code McpToolProvider}; in tests, a fake
 * one), asks it for the full tool set, then keeps only the tools {@link ReadOnlyToolPolicy} deems
 * read-only. Because the mutating tool's {@link ToolExecutor} is dropped as well as its
 * {@link ToolSpecification}, the model cannot see it in tool discovery <em>and</em> has no way to
 * execute it through this client - which is stronger than the discovery-only filtering that
 * CVE-2026-46519 showed was bypassable. It is still not the security boundary: RBAC on the
 * ServiceAccount is (see {@link ReadOnlyToolPolicy}).
 *
 * <p>Filtered-out tool names are recorded so the CLI can report the posture it applied
 * ("read-only: hid 4 mutating tools: pods_delete, ...").
 */
public class ReadOnlyToolFilter implements ToolProvider {

    private static final Logger LOG = Logger.getLogger(ReadOnlyToolFilter.class);

    private final ToolProvider delegate;
    private final ReadOnlyToolPolicy policy;
    // tool name -> the write verb it matched; sorted + concurrent for deterministic, thread-safe reporting.
    private final Map<String, String> filteredOut = new ConcurrentSkipListMap<>();

    public ReadOnlyToolFilter(ToolProvider delegate, ReadOnlyToolPolicy policy) {
        this.delegate = delegate;
        this.policy = policy;
    }

    @Override
    public ToolProviderResult provideTools(ToolProviderRequest request) {
        ToolProviderResult full = delegate.provideTools(request);
        if (full == null) {
            return null;
        }
        Map<ToolSpecification, ToolExecutor> tools = full.tools();
        if (tools == null || tools.isEmpty()) {
            return full;
        }
        ToolProviderResult.Builder kept = ToolProviderResult.builder();
        Set<String> keptImmediateReturn = new java.util.HashSet<>();
        for (Map.Entry<ToolSpecification, ToolExecutor> entry : tools.entrySet()) {
            String name = entry.getKey().name();
            policy.mutatingToken(name).ifPresentOrElse(
                    token -> {
                        filteredOut.put(name, token);
                        LOG.debugf("read-only: hiding mutating tool '%s' (matched '%s')", name, token);
                    },
                    () -> {
                        kept.add(entry.getKey(), entry.getValue());
                        if (full.immediateReturnToolNames().contains(name)) {
                            keptImmediateReturn.add(name);
                        }
                    });
        }
        if (!keptImmediateReturn.isEmpty()) {
            kept.immediateReturnToolNames(keptImmediateReturn);
        }
        return kept.build();
    }

    @Override
    public boolean isDynamic() {
        return delegate.isDynamic();
    }

    /** Tool names hidden by the read-only posture on the calls seen so far (name -> matched verb), sorted. */
    public Map<String, String> filteredOut() {
        return new TreeMap<>(filteredOut);
    }
}
