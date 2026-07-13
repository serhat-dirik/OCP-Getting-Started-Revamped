package com.parasol.mcp.claims;

import java.util.List;
import java.util.Optional;
import java.util.stream.Collectors;

import io.quarkiverse.mcp.server.Tool;
import io.quarkiverse.mcp.server.ToolArg;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The claims-db MCP tools - "your APIs, as tools" (M23).
 *
 * <p>Three read-only tools over the seeded CLM-1001..CLM-1030 dataset. Descriptions are
 * written FOR THE MODEL: they name the exact claim-number format and the valid statuses so a
 * temperature-0 agent calls them with the right arguments. Each tool returns either a compact
 * record (serialized to JSON) or a single grounded sentence the model can quote verbatim.
 */
@ApplicationScoped
public class ClaimsTools {

    @Inject
    ClaimsRepository repo;

    @Tool(name = "get_claim",
            description = "Look up a single Parasol Insurance claim by its claim number "
                    + "(for example CLM-1001). Returns the claimant, line of business (auto/home/life), "
                    + "workflow status, claimed amount in USD, assigned adjuster and incident date. "
                    + "Use this to answer questions about the status or details of a specific claim.")
    public String getClaim(
            @ToolArg(description = "The claim number, e.g. CLM-1001") String claimNumber) {
        Optional<ClaimView> claim = repo.find(claimNumber);
        if (claim.isEmpty()) {
            return "No claim found with number " + ClaimsRepository.normalize(claimNumber) + ".";
        }
        ClaimView c = claim.get();
        return String.format(
                "Claim %s: claimant %s, line of business %s, status %s, amount %s USD, "
                        + "adjuster %s, incident date %s.",
                c.claimNumber(), c.claimant(), c.type(), c.status(), c.amount(),
                c.adjuster(), c.incidentDate());
    }

    @Tool(name = "list_claims_by_status",
            description = "List the Parasol claims currently in a given workflow status. "
                    + "Valid statuses are exactly: Submitted, UnderReview, Approved, Denied. "
                    + "Returns each matching claim with its number, claimant, type, amount and adjuster.")
    public List<ClaimView> listClaimsByStatus(
            @ToolArg(description = "One of: Submitted, UnderReview, Approved, Denied") String status) {
        return repo.byStatus(status);
    }

    @Tool(name = "get_claim_history",
            description = "Return the audit timeline for a claim (submitted, adjuster assigned, "
                    + "documents requested/received, under review, approved/denied, payment issued), "
                    + "oldest event first. Use this when asked what has happened to a claim over time.")
    public String getClaimHistory(
            @ToolArg(description = "The claim number, e.g. CLM-1001") String claimNumber) {
        if (!repo.exists(claimNumber)) {
            return "No claim found with number " + ClaimsRepository.normalize(claimNumber) + ".";
        }
        List<ClaimEvent> events = repo.history(claimNumber);
        if (events.isEmpty()) {
            return "Claim " + ClaimsRepository.normalize(claimNumber)
                    + " exists but has no recorded timeline events.";
        }
        String lines = events.stream()
                .map(e -> String.format("- %s: %s (%s)", e.createdAt, e.eventType, e.note))
                .collect(Collectors.joining("\n"));
        return "Timeline for claim " + ClaimsRepository.normalize(claimNumber) + ":\n" + lines;
    }
}
