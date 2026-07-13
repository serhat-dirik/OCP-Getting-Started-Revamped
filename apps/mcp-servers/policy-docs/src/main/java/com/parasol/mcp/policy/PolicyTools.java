package com.parasol.mcp.policy;

import java.util.List;
import java.util.Optional;

import io.quarkiverse.mcp.server.Tool;
import io.quarkiverse.mcp.server.ToolArg;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The policy-docs MCP tools — RAG-style retrieval over the Parasol policy corpus (M23).
 *
 * <p>{@code search_policies} is the tool the agent calls to ground answers about coverage,
 * deductibles, documentation, SLAs and payout timing; it returns the matched passages so the
 * model quotes real policy text instead of hallucinating. {@code get_policy} and
 * {@code list_policies} let the agent (or a lab) pull a specific document or browse the catalog.
 */
@ApplicationScoped
public class PolicyTools {

    @Inject
    PolicyRetriever retriever;

    @Tool(name = "search_policies",
            description = "Search the Parasol Insurance policy documents for passages relevant to a "
                    + "question about coverage, deductibles, required documentation, claim workflow, "
                    + "service levels or payout timing. Returns the most relevant policy passages "
                    + "(with id, title and text) to ground the answer. Always call this before "
                    + "answering a policy question, and base the answer only on the returned passages.")
    public List<PolicyMatch> searchPolicies(
            @ToolArg(description = "The natural-language question or keywords to search for") String query,
            @ToolArg(description = "Maximum passages to return (default 3, max 8)", required = false)
            Integer maxResults) {
        return retriever.search(query, maxResults == null ? 3 : maxResults);
    }

    @Tool(name = "get_policy",
            description = "Fetch a single Parasol policy document in full by its id, e.g. POL-AUTO-01.")
    public String getPolicy(
            @ToolArg(description = "The policy document id, e.g. POL-HOME-01") String policyId) {
        Optional<PolicyDocument> doc = retriever.get(policyId);
        if (doc.isEmpty()) {
            return "No policy document found with id " + policyId + ".";
        }
        PolicyDocument d = doc.get();
        return d.id() + " - " + d.title() + " (" + d.category() + "):\n" + d.text();
    }

    @Tool(name = "list_policies",
            description = "List the available Parasol policy documents (id, title and category) so "
                    + "you know what coverage areas exist. Categories: auto, home, life, claims.")
    public List<PolicyRef> listPolicies() {
        return retriever.all().stream()
                .map(d -> new PolicyRef(d.id(), d.title(), d.category()))
                .toList();
    }

    /** Lightweight catalog entry (no body text) returned by {@code list_policies}. */
    public record PolicyRef(String id, String title, String category) {
    }
}
