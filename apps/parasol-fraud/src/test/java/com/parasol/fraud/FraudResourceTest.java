package com.parasol.fraud;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

/**
 * Build-time smoke over the scoring endpoint and the readiness probe.
 *
 * <p>Runs with the OIDC tenant DISABLED (the default), so these calls are anonymous:
 * that is the module-independence guarantee (M01-M28 see an unprotected service). The
 * scores asserted here are the deterministic values lab text references.
 */
@QuarkusTest
class FraudResourceTest {

    @Test
    void scoreIsDeterministicAndAnonymous() {
        // CLM-1001 -> 1001 * 37 % 100 = 37 -> low. No token supplied: tenant disabled.
        given()
                .when().get("/api/fraud/score/CLM-1001")
                .then()
                .statusCode(200)
                .body("claimId", is("CLM-1001"))
                .body("score", is(37))
                .body("risk", is("low"));
    }

    @Test
    void highRiskClaimScoresHigh() {
        // CLM-1005 -> 1005 * 37 % 100 = 85 -> high.
        given()
                .when().get("/api/fraud/score/CLM-1005")
                .then()
                .statusCode(200)
                .body("score", is(85))
                .body("risk", is("high"));
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
