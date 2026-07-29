package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.Map;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.QuarkusTestProfile;
import io.quarkus.test.junit.TestProfile;

/**
 * The only test that actually exercises {@link ClaimNumberSequence}'s positioning arithmetic, and
 * the reason it needs its own fixture: on the shipped seeded path {@code import.sql} creates
 * {@code claim_number_seq} itself, so the startup path finds it present and computes a start value
 * it never uses. Here the seed script creates no sequence, so the number the first create returns
 * IS the computed one.
 *
 * <p>It also pins the two shapes that must not throw. A claim number is data, and a real database
 * can hold a row that does not match {@code CLM-<integer>} — migrated legacy keys are the obvious
 * case. Those rows are skipped when picking the maximum; they never fail the boot, and they never
 * become the maximum. The fixture holds one of each ({@code CLM-legacy-7}, {@code LEGACY-99999}),
 * both numerically "larger" than the real maximum if anyone were tempted to sort them as strings.
 */
@QuarkusTest
@TestProfile(ClaimNumberingMixedDataTest.MixedClaimNumbersProfile.class)
class ClaimNumberingMixedDataTest {

    /** Loads the mixed fixture instead of the shipped seed — and, crucially, no sequence with it. */
    public static class MixedClaimNumbersProfile implements QuarkusTestProfile {
        @Override
        public Map<String, String> getConfigOverrides() {
            return Map.of(
                    "quarkus.hibernate-orm.sql-load-script", "mixed-claim-numbers.sql",
                    "quarkus.datasource.jdbc.url", "jdbc:h2:mem:claims-mixed;DB_CLOSE_DELAY=-1");
        }
    }

    @Test
    void numberingStartsPastTheHighestParseableClaimNumber() {
        // CLM-2048 is the highest that parses. CLM-legacy-7 and LEGACY-99999 are ignored, not
        // thrown on — and had they been treated as numbers, or sorted as strings, the answer
        // would not be 2049.
        assertEquals("CLM-2049", createClaim());
        assertEquals("CLM-2050", createClaim());
    }

    private static String createClaim() {
        return given()
                .contentType("application/json")
                .body("{\"claimant\":\"Mixed Numbering Probe\",\"type\":\"auto\",\"amount\":100.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .extract().path("claimNumber");
    }
}
