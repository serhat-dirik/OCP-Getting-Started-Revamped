package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.Map;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.QuarkusTestProfile;
import io.quarkus.test.junit.TestProfile;

/**
 * The other half of the numbering contract: on the 30-claim seeded database that every module
 * except the storage one runs, the first created claim is {@code CLM-1031} — the next number
 * after the {@code CLM-1001..CLM-1030} seeds, never a collision with one of them.
 *
 * <p>This is a class of its own rather than another method in {@link ClaimResourceTest} because
 * the assertion is about the <em>first</em> create against a pristine seeded database, and the
 * sibling tests in that class create claims of their own in an order JUnit does not promise. Its
 * H2 database therefore also gets a name of its own: {@code DB_CLOSE_DELAY=-1} keeps an in-memory
 * H2 alive for the whole JVM, so sharing {@code mem:claims} would mean inheriting their rows.
 *
 * <p>Everything else is the shipped configuration — {@code drop-and-create} plus
 * {@code import.sql}, exactly what the image does with no environment overrides.
 */
@QuarkusTest
@TestProfile(ClaimNumberingSeededDbTest.SeededDatabaseProfile.class)
class ClaimNumberingSeededDbTest {

    /** The shipped defaults, on a database no other test class writes to. */
    public static class SeededDatabaseProfile implements QuarkusTestProfile {
        @Override
        public Map<String, String> getConfigOverrides() {
            return Map.of("quarkus.datasource.jdbc.url", "jdbc:h2:mem:claims-seeded;DB_CLOSE_DELAY=-1");
        }
    }

    @Test
    void seededDatabaseNumbersFromCLM1031() {
        // Precondition: the 30 deterministic seeds are loaded and CLM-1030 is the highest.
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .body("size()", is(30))
                .body("[29].claimNumber", is("CLM-1030"));

        assertEquals("CLM-1031", createClaim());
        assertEquals("CLM-1032", createClaim());
    }

    private static String createClaim() {
        return given()
                .contentType("application/json")
                .body("{\"claimant\":\"Seeded Numbering Probe\",\"type\":\"auto\",\"amount\":100.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .extract().path("claimNumber");
    }
}
