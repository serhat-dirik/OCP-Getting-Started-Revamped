package com.parasol.mcp.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;

/**
 * Deterministic component tests for the claims-db MCP tool logic, run against the seeded
 * in-memory H2 (no external DB needed). Feeds the CI "apps" job. The tools are invoked
 * directly as a CDI bean - the assertions pin the exact seeded values the workshop cites.
 */
@QuarkusTest
class ClaimsToolsTest {

    @Inject
    ClaimsTools tools;

    @Test
    void getClaimReturnsGroundedFactForSeededClaim() {
        String answer = tools.getClaim("CLM-1001");
        assertTrue(answer.contains("CLM-1001"), answer);
        assertTrue(answer.contains("Alice Nguyen"), answer);
        assertTrue(answer.contains("UnderReview"), answer);
        assertTrue(answer.contains("4200.00"), answer);
        assertTrue(answer.contains("Rebecca Torres"), answer);
    }

    @Test
    void getClaimNormalizesBareNumberAndCase() {
        // A bare "1001" and a lower-case "clm-1001" must resolve to the same claim.
        assertTrue(tools.getClaim("1001").contains("Alice Nguyen"));
        assertTrue(tools.getClaim("clm-1001").contains("Alice Nguyen"));
    }

    @Test
    void getUnknownClaimReportsNotFound() {
        assertTrue(tools.getClaim("CLM-9999").startsWith("No claim found"));
    }

    @Test
    void listClaimsByStatusReturnsExactSeededSet() {
        List<ClaimView> approved = tools.listClaimsByStatus("Approved");
        // The seed has exactly 11 Approved claims; the first (sorted) is CLM-1002.
        assertEquals(11, approved.size());
        assertEquals("CLM-1002", approved.get(0).claimNumber());
        assertTrue(approved.stream().allMatch(c -> c.status().equals("Approved")));
        // amount is a pre-formatted plain string (deterministic JSON for the model).
        assertEquals("12850.00", approved.get(0).amount());
    }

    @Test
    void listClaimsByStatusIsCaseInsensitive() {
        assertEquals(11, tools.listClaimsByStatus("approved").size());
        assertEquals(11, tools.listClaimsByStatus("APPROVED").size());
    }

    @Test
    void listClaimsByUnknownStatusIsEmpty() {
        assertTrue(tools.listClaimsByStatus("Frozen").isEmpty());
    }

    @Test
    void getClaimHistoryReturnsSeededTimelineOldestFirst() {
        String history = tools.getClaimHistory("CLM-1001");
        assertTrue(history.contains("Timeline for claim CLM-1001"), history);
        assertTrue(history.contains("Submitted"), history);
        assertTrue(history.contains("AdjusterAssigned"), history);
        assertTrue(history.contains("Rebecca Torres"), history);
        // 5 seeded events -> 5 timeline lines.
        assertEquals(5, history.lines().filter(l -> l.startsWith("- ")).count());
    }

    @Test
    void getHistoryForUnknownClaimReportsNotFound() {
        assertTrue(tools.getClaimHistory("CLM-9999").startsWith("No claim found"));
    }

    @Test
    void readinessProbeIsUp() {
        given().when().get("/q/health/ready")
                .then().statusCode(200).body("status", is("UP"));
    }
}
