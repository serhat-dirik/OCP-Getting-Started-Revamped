package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.greaterThanOrEqualTo;
import static org.hamcrest.Matchers.is;
import static org.hamcrest.Matchers.notNullValue;
import static org.hamcrest.Matchers.startsWith;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

/**
 * Build-time smoke tests over the seeded API and the readiness probe, run against
 * in-memory H2 (no PostgreSQL needed). Feeds the CI "apps" job so a broken claims
 * service fails the pipeline, not the lab.
 *
 * <p>Assertions are order-independent: the create test adds a row, so list checks
 * assert "at least 30" plus exact seeded values rather than a brittle exact count.
 */
@QuarkusTest
class ClaimResourceTest {

    @Test
    void listReturnsSeededClaimsSortedByNumber() {
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .header("X-Total-Count", notNullValue())
                .body("size()", greaterThanOrEqualTo(30))
                .body("[0].claimNumber", is("CLM-1001"))
                .body("[0].claimant", is("Alice Nguyen"))
                .body("[0].type", is("auto"))
                .body("[0].status", is("UnderReview"));
    }

    @Test
    void pagingReturnsRequestedSlice() {
        given()
                .when().get("/api/claims?page=0&size=5")
                .then()
                .statusCode(200)
                .header("X-Total-Count", notNullValue())
                .body("size()", is(5))
                .body("[0].claimNumber", is("CLM-1001"))
                .body("[4].claimNumber", is("CLM-1005"));
    }

    @Test
    void getByNumberReturnsOneClaim() {
        given()
                .when().get("/api/claims/CLM-1005")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1005"))
                .body("claimant", is("Sofia Alvarez"))
                .body("type", is("life"))
                .body("status", is("Approved"))
                .body("adjuster", is("David Okonkwo"));
    }

    @Test
    void getUnknownClaimReturns404() {
        given()
                .when().get("/api/claims/CLM-9999")
                .then()
                .statusCode(404);
    }

    @Test
    void createAssignsNumberAndOpensSubmitted() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Test Claimant\",\"type\":\"auto\",\"amount\":1234.56,\"incidentDate\":\"2026-07-01\"}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .body("claimNumber", startsWith("CLM-"))
                .body("status", is("Submitted"))
                .body("adjuster", is("Unassigned"));
    }

    @Test
    void createRejectsUnknownType() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Bad Type\",\"type\":\"boat\"}")
                .when().post("/api/claims")
                .then()
                .statusCode(400);
    }

    @Test
    void updateStatusAdvancesClaim() {
        given()
                .contentType("application/json")
                .body("{\"status\":\"Approved\"}")
                .when().put("/api/claims/CLM-1003/status")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1003"))
                .body("status", is("Approved"));
    }

    @Test
    void updateStatusRejectsUnknownValue() {
        given()
                .contentType("application/json")
                .body("{\"status\":\"Frozen\"}")
                .when().put("/api/claims/CLM-1004/status")
                .then()
                .statusCode(400);
    }

    @Test
    void readinessProbeIsUp() {
        given()
                .when().get("/q/health/ready")
                .then()
                .statusCode(200)
                .body("status", is("UP"));
    }

    /**
     * M29 regression guard: quarkus-oidc is on the classpath but the tenant is
     * DISABLED by default, so the API must stay anonymous - no token, still 200.
     * If someone flips tenant-enabled=true in the shipped config, this fails.
     */
    @Test
    void apiIsAnonymousByDefault() {
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200);
        given()
                .when().get("/api/claims/CLM-1001")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1001"));
    }

    /** The M11 N+1 endpoint returns the seeded timeline, oldest event first. */
    @Test
    void historyReturnsSeededTimeline() {
        given()
                .when().get("/api/claims/CLM-1001/history")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1001"))
                .body("claimant", is("Alice Nguyen"))
                .body("events.size()", is(5))
                .body("events[0].eventType", is("Submitted"))
                .body("events[4].eventType", is("UnderReview"));
    }

    @Test
    void historyForUnknownClaimReturns404() {
        given()
                .when().get("/api/claims/CLM-9999/history")
                .then()
                .statusCode(404);
    }

    /** Creating a claim increments the custom Micrometer counter (claims_created_total). */
    @Test
    void createIncrementsClaimsCreatedCounter() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Metric Probe\",\"type\":\"home\",\"amount\":100.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(201);
        given()
                .when().get("/q/metrics")
                .then()
                .statusCode(200)
                .body(containsString("claims_created_total"));
    }
}
