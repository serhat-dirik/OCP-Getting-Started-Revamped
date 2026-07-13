package com.parasol.mcp.claims;

/**
 * Flat, JSON-friendly projection of a {@link Claim} returned by the MCP tools.
 *
 * <p>Tools return this record (not the Panache entity) so the JSON the agent's model sees is
 * clean and stable: {@code amount} and {@code incidentDate} are pre-formatted strings, so the
 * tool output is byte-for-byte deterministic across runs (temperature-0 demos depend on it).
 */
public record ClaimView(
        String claimNumber,
        String claimant,
        String type,
        String status,
        String amount,
        String incidentDate,
        String adjuster) {

    static ClaimView of(Claim c) {
        return new ClaimView(
                c.claimNumber,
                c.claimant,
                c.type,
                c.status,
                c.amount == null ? null : c.amount.toPlainString(),
                c.incidentDate == null ? null : c.incidentDate.toString(),
                c.adjuster);
    }
}
