package com.parasol.fraud;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import io.quarkus.test.junit.QuarkusTest;

/**
 * Build-time smoke over the scoring endpoint and the readiness probe, plus the contract
 * tests that hold {@link FraudResource#scoreFor} to its documented [0,99] range.
 *
 * <p>Runs with the OIDC tenant DISABLED (the default), so these calls are anonymous:
 * that is the module-independence guarantee (every other module sees an unprotected
 * service). The scores asserted here are the deterministic values lab text references.
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

    // ---------------------------------------------------------------------------
    // Contract tests for the two properties FraudResource.scoreFor promises but is
    // easy to break: it is TOTAL (no input makes it throw) and its result is always
    // inside [0,99]. Both were violated by the original long-arithmetic version —
    // see the class javadoc on FraudResource for what went wrong and why the fix is
    // BigInteger rather than a wider primitive.
    // ---------------------------------------------------------------------------

    /**
     * The claim id is caller-controlled path input, so an id longer than any primitive
     * must still be scored, never turned into a server error. The numeric part here has
     * 20 digits — one more than {@code Long.MAX_VALUE} — which the original
     * {@code Long.parseLong} rejected with an unhandled NumberFormatException, i.e. HTTP 500.
     */
    @Test
    void oversizedClaimIdIsScoredNotAServerError() {
        int score = given()
                .when().get("/api/fraud/score/CLM-12345678901234567890")
                .then()
                .statusCode(200)
                .extract().path("score");
        assertScoreIsWithinContract("CLM-12345678901234567890", score);
    }

    /**
     * Regression pin for the signed-overflow defect. Every id below has a numeric part in
     * the window where {@code basis * 37} used to wrap a {@code long} negative; the worst
     * case, {@code CLM-249299106394725033}, scored <strong>-95</strong> and — because the
     * band check is only {@code score < 40} — was reported as risk <strong>"low"</strong>.
     * A negative fraud score sold as low risk is the most dangerous direction this service
     * can be wrong in, so it is pinned rather than left to a general range check.
     */
    @ParameterizedTest
    @ValueSource(strings = {
        "CLM-249299106394725033",  // scored -95 / "low" before the fix
        "CLM-249299106394725023",  // scored -65 / "low" before the fix
        "CLM-300000000000000000",  // scored -16 / "low" before the fix
        "CLM-400000000000000000"   // scored -16 / "low" before the fix
    })
    void scoreStaysInsideItsDocumentedRange(String claimId) {
        int score = given()
                .when().get("/api/fraud/score/" + claimId)
                .then()
                .statusCode(200)
                .extract().path("score");
        assertScoreIsWithinContract(claimId, score);
    }

    /**
     * Sweep the whole former overflow window at unit level — cheaper than 10 000 HTTP calls
     * and it proves the property holds for the range, not just the four pinned ids.
     */
    @Test
    void noClaimIdInTheFormerOverflowWindowEscapesTheRange() {
        for (long basis = 249_299_106_394_725_000L; basis < 249_299_106_394_735_000L; basis++) {
            assertScoreIsWithinContract("CLM-" + basis, FraudResource.scoreFor("CLM-" + basis));
        }
    }

    /** The javadoc contract: a score in [0,99], and a band that matches the documented cut-offs. */
    private static void assertScoreIsWithinContract(String claimId, int score) {
        assertTrue(score >= 0 && score <= 99,
                "score for " + claimId + " must be in [0,99] as FraudResource.scoreFor promises, but was " + score);
        assertEquals(score < 40 ? "low" : score < 70 ? "medium" : "high", FraudResource.riskBand(score),
                "risk band for " + claimId + " (score " + score + ") does not match the documented cut-offs");
    }
}
