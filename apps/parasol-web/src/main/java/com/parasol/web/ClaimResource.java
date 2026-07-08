package com.parasol.web;

import java.util.List;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * Read-only claims summary endpoint that backs the portal landing page.
 *
 * <p>{@code GET /api/claims} returns a fixed, deterministic set of five seeded
 * claims (CLM-1001..CLM-1005). The values are intentionally stable so workshop
 * lab text can reference exact IDs, amounts, and statuses.
 */
@Path("/api/claims")
public class ClaimResource {

    // Fixed seed data — do NOT randomize. Module labs assert on these exact values.
    private static final List<Claim> CLAIMS = List.of(
            new Claim("CLM-1001", "Alice Nguyen",  "Auto",     "Under Review",  4200.00, "2026-05-14"),
            new Claim("CLM-1002", "Marcus Feld",   "Home",     "Approved",     12850.00, "2026-05-09"),
            new Claim("CLM-1003", "Priya Raman",   "Auto",     "Open",          1975.50, "2026-06-01"),
            new Claim("CLM-1004", "Tom Becker",    "Property", "Denied",        8400.00, "2026-04-22"),
            new Claim("CLM-1005", "Sofia Alvarez", "Home",     "Closed",        3120.75, "2026-03-30"));

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public List<Claim> list() {
        return CLAIMS;
    }
}
