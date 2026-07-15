package com.parasol.mcpcli;

/**
 * The agent's one capability: take a natural-language prompt and return an answer, calling MCP tools
 * as needed along the way.
 *
 * <p>Deliberately a plain interface (not {@code @RegisterAiService}). {@link AgentFactory} builds it
 * with LangChain4j's {@code AiServices} builder so the same construction path can be exercised in
 * unit tests with a mocked model and a fake MCP tool provider - which is how the tool-call
 * orchestration is proven off-cluster. The system message, the (read-only-filtered) MCP tool
 * provider, the chat memory, and the step cap are all supplied by the builder, keeping the model and
 * the tools fully swappable.
 */
public interface Assistant {

    /** Ask the agent; it decides which MCP tools to call and returns the final answer. */
    String chat(String prompt);
}
