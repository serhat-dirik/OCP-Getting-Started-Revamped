package com.parasol.mcp.policy;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;

/**
 * Deterministic component tests for the policy-docs retrieval tools. The corpus is fixed and
 * scoring is a transparent term-frequency count, so the top hit for a given query is stable and
 * can be asserted exactly - the property the "grounded vs ungrounded" demo relies on.
 */
@QuarkusTest
class PolicyToolsTest {

    @Inject
    PolicyTools tools;

    @Test
    void searchRanksTheAutoDeductibleDocFirst() {
        List<PolicyMatch> hits = tools.searchPolicies("What is the deductible for an auto claim?", 3);
        assertFalse(hits.isEmpty());
        assertEquals("POL-AUTO-01", hits.get(0).id());
        assertTrue(hits.get(0).text().contains("500"), hits.get(0).text());
        // scores are monotonically non-increasing (best match first).
        for (int i = 1; i < hits.size(); i++) {
            assertTrue(hits.get(i - 1).score() >= hits.get(i).score());
        }
    }

    @Test
    void searchFindsTheOnlyFloodMention() {
        List<PolicyMatch> hits = tools.searchPolicies("is flood damage covered", 3);
        assertFalse(hits.isEmpty());
        assertEquals("POL-HOME-01", hits.get(0).id());
        assertTrue(hits.get(0).text().toLowerCase().contains("rider"));
    }

    @Test
    void searchGroundsPayoutTimingInTheClaimsSlaDoc() {
        List<PolicyMatch> hits = tools.searchPolicies("how long until payment after approval", 3);
        assertFalse(hits.isEmpty());
        assertEquals("POL-CLAIM-03", hits.get(0).id());
        assertTrue(hits.get(0).text().contains("5 business days"));
    }

    @Test
    void maxResultsIsHonoured() {
        assertEquals(1, tools.searchPolicies("claim coverage deductible policy", 1).size());
        assertTrue(tools.searchPolicies("claim coverage deductible policy", 8).size() <= 8);
    }

    @Test
    void queryWithoutContentWordsReturnsNothing() {
        // All-stopword query -> no meaningful terms -> no matches (honest "no grounding").
        assertTrue(tools.searchPolicies("what is the", 3).isEmpty());
        assertTrue(tools.searchPolicies("   ", 3).isEmpty());
    }

    @Test
    void getPolicyReturnsFullDocumentOrNotFound() {
        assertTrue(tools.getPolicy("POL-LIFE-01").contains("beneficiary"));
        assertTrue(tools.getPolicy("pol-life-01").contains("beneficiary")); // case-insensitive id
        assertTrue(tools.getPolicy("POL-DOES-NOT-EXIST").startsWith("No policy document found"));
    }

    @Test
    void listPoliciesReturnsTheWholeCatalog() {
        List<PolicyTools.PolicyRef> catalog = tools.listPolicies();
        assertEquals(8, catalog.size());
        assertTrue(catalog.stream().anyMatch(r -> r.id().equals("POL-CLAIM-01")));
    }

    @Test
    void readinessProbeIsUp() {
        given().when().get("/q/health/ready")
                .then().statusCode(200).body("status", is("UP"));
    }
}
