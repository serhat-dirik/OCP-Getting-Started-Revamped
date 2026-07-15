package com.parasol.mcpcli;

import java.util.List;
import java.util.Optional;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import dev.langchain4j.mcp.McpToolProvider;
import dev.langchain4j.mcp.client.McpClient;
import dev.langchain4j.memory.chat.MessageWindowChatMemory;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.service.AiServices;
import dev.langchain4j.service.tool.ToolProvider;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;

/**
 * Assembles the {@link Assistant} from the same env-driven pieces {@code parasol-agent} uses in M23,
 * only re-pointed from the claims MCP servers to the platform MCP server:
 *
 * <ul>
 *   <li>the injected {@link ChatModel} - the quarkus-langchain4j OpenAI bean configured by
 *       {@code quarkus.langchain4j.openai.*} ({@code GENAI_ENDPOINT/API_KEY/MODEL}). Being the model
 *       bean, it already has {@link ToolCallTracer} (a {@code ChatModelListener}) attached, so every
 *       tool call is traced;</li>
 *   <li>the injected MCP {@link McpClient}(s) - built from {@code quarkus.langchain4j.mcp.*}
 *       ({@code MCP_SERVER_URL}) - wrapped into a LangChain4j {@link McpToolProvider};</li>
 *   <li>a {@link ReadOnlyToolFilter} in front of that provider when read-only mode is on (the
 *       default), so mutating tools are never offered to the model.</li>
 * </ul>
 *
 * <p>The service is built programmatically (rather than with {@code @RegisterAiService}) precisely so
 * that this construction path is unit-testable: the tests build the same {@code AiServices} with a
 * scripted model and a fake tool provider to prove the orchestration and the trace off-cluster.
 */
@ApplicationScoped
public class AgentFactory {

    /**
     * Imperative, tool-forcing, server-neutral instructions. Imperative phrasing + temperature 0
     * (see application.properties) keep tool-calling deterministic across models - M23 showed the
     * same model calls a tool or not depending on terse-vs-imperative wording.
     */
    static final String SYSTEM_MESSAGE = """
            You are a careful platform operations assistant. You help an engineer inspect and operate
            an OpenShift/Kubernetes cluster THROUGH the tools a Model Context Protocol (MCP) server
            gives you. You have no other access to the cluster.

            Use the tools - do not guess:
            - To learn anything about the cluster (pods, deployments, services, events, logs, resource
              definitions), CALL the appropriate read tool and base your answer only on what it returns.
            - Diagnose before you change anything: gather evidence with read-only tools first, then
              explain the most likely cause in one or two sentences, citing the specific values the
              tools returned.
            - Only if you have been given a tool that changes cluster state, and the task clearly calls
              for it, make the smallest change that fixes the problem, then verify with a read tool.

            Rules:
            - Never invent resource names, statuses, or field values. If a tool returns nothing or an
              error, say so plainly.
            - Stay in the namespace you were asked about. If a tool call is denied (for example by
              RBAC), report the denial - do not try to work around it.
            - Be concise and specific: give the exact names, statuses, and fields the tools returned.
            """;

    @Inject
    ChatModel chatModel;

    @Inject
    @Any
    Instance<McpClient> mcpClients;

    @ConfigProperty(name = "mcp-agent.max-steps", defaultValue = "10")
    int maxSteps;

    @ConfigProperty(name = "mcp-agent.memory-window-messages", defaultValue = "40")
    int memoryWindowMessages;

    // Optional<String>, not String: the property defaults to an empty value (blank = use the built-in
    // verb list), and SmallRye Config's String converter rejects empty values - Optional maps them to
    // empty cleanly.
    @ConfigProperty(name = "mcp-agent.mutating-tokens")
    Optional<String> mutatingTokensOverride;

    /**
     * Build the agent for one run. {@code readOnly} is passed in so the CLI flag can override the
     * configured default.
     */
    public BuiltAgent create(boolean readOnly) {
        List<McpClient> clients = mcpClients.stream().toList();
        ToolProvider mcpProvider = McpToolProvider.builder()
                .mcpClients(clients)
                .failIfOneServerFails(false)
                .build();

        ReadOnlyToolFilter filter = null;
        ToolProvider effectiveProvider = mcpProvider;
        if (readOnly) {
            filter = new ReadOnlyToolFilter(mcpProvider, ReadOnlyToolPolicy.fromTokens(mutatingTokensOverride.orElse("")));
            effectiveProvider = filter;
        }

        Assistant assistant = AiServices.builder(Assistant.class)
                .chatModel(chatModel)
                .toolProvider(effectiveProvider)
                .systemMessage(SYSTEM_MESSAGE)
                .chatMemory(MessageWindowChatMemory.withMaxMessages(memoryWindowMessages))
                .maxSequentialToolsInvocations(maxSteps)
                .build();

        return new BuiltAgent(assistant, filter, readOnly, clients.size());
    }

    /**
     * A built agent plus what the CLI needs to report about it: the read-only {@code filter} (null
     * when writes are allowed) so the command can list the tools it hid, whether it is read-only, and
     * how many MCP servers were wired.
     */
    public record BuiltAgent(Assistant assistant, ReadOnlyToolFilter filter, boolean readOnly, int mcpServerCount) {
    }
}
