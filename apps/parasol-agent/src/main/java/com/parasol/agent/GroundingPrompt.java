package com.parasol.agent;

import java.util.Optional;

import org.eclipse.microprofile.config.ConfigProvider;

import io.quarkiverse.langchain4j.runtime.aiservice.SystemMessageProvider;

/**
 * The agent's <strong>grounding</strong> - its system prompt and tool-choice guidance - as
 * <em>configuration</em> rather than a string baked into the image.
 *
 * <p>WHY. Whether an agent calls a tool or answers from the model's own weights is decided almost
 * entirely by this text. Compiled into an annotation it is a code change, a rebuild and a redeploy
 * away from being tuned; read from config it is an ordinary ConfigMap edit plus a rollout - which is
 * what "grounding is engineered" actually looks like in operations, and what the Agentic AI module
 * asks attendees to do.
 *
 * <p>WIRING. {@code parasol.agent.grounding-prompt} - i.e. the {@code PARASOL_AGENT_GROUNDING_PROMPT}
 * environment variable, which the workshop feeds from the {@code parasol-agent-grounding} ConfigMap,
 * exactly as {@code GENAI_MODEL} comes from {@code maas-config}. No new mechanism: the same
 * externalized-config idiom the rest of this service already uses.
 *
 * <p>NOT A CDI BEAN, AND THAT IS NOT AN OVERSIGHT. {@code @RegisterAiService(systemMessageProviderSupplier =
 * GroundingPrompt.class)} is honoured by {@code AiServicesRecorder}, which does
 * {@code loadClass(name).getConstructor().newInstance()} - a plain reflective no-arg construction, not
 * a container lookup. So this class must keep a public no-arg constructor and must not rely on
 * injection; it reads config through {@link ConfigProvider} instead. (Checked against the extension's
 * own bytecode at quarkus-langchain4j 1.10.0 rather than assumed: an earlier draft of this class used
 * {@code BeanIfExistsSystemMessageProviderSupplier} with an {@code @ApplicationScoped} provider, and
 * the build silently produced no provider bean at all - the marker class's own
 * {@code getSystemMessage} throws {@code UnsupportedOperationException("should never be called")}.)
 *
 * <p>FALLBACK. If the property is absent or blank the built-in {@link #DEFAULT_PROMPT} applies, so the
 * image is <em>correct on its own</em> - {@code quarkus dev} and a bare {@code podman run} ground
 * properly with no ConfigMap in sight. A deployment that supplies a weaker prompt is making a
 * deliberate choice, and {@code GET /agent/info} reports which of the two is live.
 *
 * <p>The value is read once, at construction: an environment variable cannot change under a running
 * pod, so a ConfigMap edit takes effect on the next rollout. That is the honest behaviour of
 * env-backed config, and the lab says so rather than hiding it.
 */
public class GroundingPrompt implements SystemMessageProvider {

    /** The config property, and by MicroProfile mapping the {@code PARASOL_AGENT_GROUNDING_PROMPT} env var. */
    public static final String PROPERTY = "parasol.agent.grounding-prompt";

    /**
     * The grounding this service ships with - strong on purpose. It tells the model it has tools,
     * which kind of question needs which tool, and to refuse to invent what a tool did not return.
     */
    static final String DEFAULT_PROMPT = """
            You are the Parasol Insurance claims assistant. You help staff answer questions about
            insurance claims and Parasol's policies.

            You have tools. USE THEM instead of guessing:
            - To answer anything about a specific claim (its status, amount, adjuster, type, or
              history), call the claims tools. Claim numbers look like CLM-1001.
            - To answer anything about coverage, deductibles, required documents, claim workflow,
              service levels, or payout timing, call search_policies and base your answer only on
              the policy passages it returns. Cite the policy id (e.g. POL-AUTO-01) you relied on.

            Rules:
            - Never invent claim details or policy terms. If a tool says a claim was not found, or a
              search returns nothing relevant, say so plainly rather than guessing.
            - Be concise: a few sentences. Give the specific figures the tools return.
            - If a question needs both a claim fact and a policy rule, call both kinds of tool.
            """;

    private final String prompt;
    private final boolean fromConfig;

    /** Reflectively invoked by LangChain4j, and used directly by {@link AgentResource}. */
    public GroundingPrompt() {
        this(ConfigProvider.getConfig().getOptionalValue(PROPERTY, String.class));
    }

    /** Test seam: the same resolution with the configured value handed in. */
    GroundingPrompt(Optional<String> configured) {
        Optional<String> usable = configured.filter(p -> !p.isBlank());
        this.fromConfig = usable.isPresent();
        this.prompt = usable.orElse(DEFAULT_PROMPT);
    }

    /** The grounding actually in force for this pod. */
    public String text() {
        return prompt;
    }

    /** Where {@link #text()} came from - reported by {@code GET /agent/info}, never guessed at. */
    public String source() {
        return fromConfig ? "config (" + PROPERTY + ")" : "built-in default";
    }

    /** The LangChain4j hook: the system message handed to the model on every {@code ask}. */
    @Override
    public Optional<String> getSystemMessage(Object memoryId) {
        return Optional.of(prompt);
    }
}
