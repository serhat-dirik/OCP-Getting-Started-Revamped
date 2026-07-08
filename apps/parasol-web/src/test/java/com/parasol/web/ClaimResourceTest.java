package com.parasol.web;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.is;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

/**
 * Build-time smoke test over the seeded endpoint and the readiness probe.
 * Feeds the CI "apps" job so a broken frontend fails the pipeline, not the lab.
 */
@QuarkusTest
class ClaimResourceTest {

    @Test
    void claimsEndpointReturnsFiveSeededClaims() {
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .body("$", hasSize(5))
                .body("[0].id", is("CLM-1001"))
                .body("[0].status", is("Under Review"))
                .body("[4].id", is("CLM-1005"));
    }

    @Test
    void readinessProbeIsUp() {
        given()
                .when().get("/q/health/ready")
                .then()
                .statusCode(200)
                .body("status", is("UP"));
    }
}
