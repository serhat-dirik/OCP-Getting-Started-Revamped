package com.parasol.mcpcli;

import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;

import org.jboss.logging.Logger;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Records every MCP tool the model calls during one run, so the CLI can print the full
 * <strong>tool-call trace</strong> (name + arguments + result). That auditable trace is the point
 * of M24: "watch the tool calls; verify its claims yourself."
 *
 * <p>It is a {@link ChatModelListener}. quarkus-langchain4j auto-registers every
 * {@code ChatModelListener} CDI bean around the model, so the injected {@code ChatModel} fires this
 * on each model round-trip - exactly how {@code parasol-agent}'s recorder is wired in M23. We use a
 * listener (not LangChain4j's {@code Result.toolExecutions()}) because that API only reports local
 * {@code @Tool} beans, never MCP tools.
 *
 * <p>Capturing the <em>result</em> as well as the request takes two callbacks, because LangChain4j
 * runs a loop - the model asks for a tool, the tool executes, then the result is fed back on the
 * <em>next</em> request:
 * <ul>
 *   <li>{@link #onResponse} sees the {@link AiMessage}'s tool-execution requests (id + name +
 *       arguments) and records each as a pending call, in order.</li>
 *   <li>{@link #onRequest} of the following round-trip carries the {@link ToolExecutionResultMessage}s;
 *       we pair each back to its pending call by tool-call id (falling back to tool name) and fill in
 *       the result.</li>
 * </ul>
 *
 * <p>Application-scoped and single-shot: the CLI runs one prompt per process. {@link #reset()} is
 * provided for cleanliness and tests. All state access is synchronized because the model callbacks
 * may land on a worker thread.
 */
@ApplicationScoped
public class ToolCallTracer implements ChatModelListener {

    private static final Logger LOG = Logger.getLogger(ToolCallTracer.class);

    /** Mutable holder: the request fields are fixed at record time; the result arrives later. */
    private static final class Entry {
        final String id;
        final String name;
        final String arguments;
        String result;

        Entry(String id, String name, String arguments) {
            this.id = id;
            this.name = name;
            this.arguments = arguments;
        }
    }

    private final List<Entry> entries = new ArrayList<>();
    // Result messages already consumed, by identity. onRequest re-sees the whole (growing) message
    // history every round-trip, so without this a result paired in an earlier step would be re-seen
    // and double-counted once its request entry is already resolved.
    private final Set<ChatMessage> seenResults = Collections.newSetFromMap(new IdentityHashMap<>());

    @Override
    public synchronized void onResponse(ChatModelResponseContext ctx) {
        AiMessage aiMessage = ctx.chatResponse() == null ? null : ctx.chatResponse().aiMessage();
        if (aiMessage == null || !aiMessage.hasToolExecutionRequests()) {
            return;
        }
        for (ToolExecutionRequest request : aiMessage.toolExecutionRequests()) {
            entries.add(new Entry(request.id(), request.name(), request.arguments()));
        }
    }

    @Override
    public synchronized void onRequest(ChatModelRequestContext ctx) {
        if (ctx.chatRequest() == null) {
            return;
        }
        for (ChatMessage message : ctx.chatRequest().messages()) {
            // seenResults.add(..) is true only the first time we encounter this exact result message.
            if (message instanceof ToolExecutionResultMessage result && seenResults.add(result)) {
                pair(result);
            }
        }
    }

    /** Pair a returned result to the earliest still-open call with a matching id (or name). */
    private void pair(ToolExecutionResultMessage result) {
        Entry match = findOpen(result.id(), result.toolName());
        if (match != null) {
            match.result = result.text();
        } else {
            // No open request to attach to - a provider that returns a result we never saw
            // requested. Record it so the trace is never silently incomplete.
            LOG.debugf("Tool result with no matching request (id=%s, tool=%s)", result.id(), result.toolName());
            Entry orphan = new Entry(result.id(), result.toolName(), null);
            orphan.result = result.text();
            entries.add(orphan);
        }
    }

    private Entry findOpen(String id, String toolName) {
        // Prefer an exact id match; ids are unique per tool call when the provider supplies them.
        if (id != null && !id.isBlank()) {
            for (Entry e : entries) {
                if (e.result == null && id.equals(e.id)) {
                    return e;
                }
            }
        }
        // Fall back to the earliest open call with the same tool name (providers that omit ids).
        if (toolName != null) {
            for (Entry e : entries) {
                if (e.result == null && toolName.equals(e.name)) {
                    return e;
                }
            }
        }
        return null;
    }

    /** The tool calls this run made, in the order the model asked for them. */
    public synchronized List<ToolCall> trace() {
        List<ToolCall> out = new ArrayList<>(entries.size());
        for (Entry e : entries) {
            out.add(new ToolCall(e.name, e.arguments, e.result));
        }
        return List.copyOf(out);
    }

    /** Clear the trace (single-shot CLI runs once; used for reuse and tests). */
    public synchronized void reset() {
        entries.clear();
        seenResults.clear();
    }
}
