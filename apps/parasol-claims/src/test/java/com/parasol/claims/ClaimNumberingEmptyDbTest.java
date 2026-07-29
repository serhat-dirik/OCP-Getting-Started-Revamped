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
 * storage-stateful contract guard: on an EMPTY database the first three created claims are
 * {@code CLM-1001}, {@code CLM-1002}, {@code CLM-1003}.
 *
 * <p>That is not a nicety — the storage-stateful lab prints those three numbers as expected
 * output, then deletes the database Pod and has the attendee prove the same three numbers came
 * back from the PersistentVolumeClaim. If the app numbered from 1031 on an empty database, or
 * failed the create outright, three of that module's exercises would be dead.
 *
 * <p>The profile reproduces the entry state exactly: {@code schema-management.strategy=update}
 * (what {@code gitops/entry-states/storage-stateful/templates/parasol-claims.yaml} sets via
 * {@code QUARKUS_HIBERNATE_ORM_SCHEMA_MANAGEMENT_STRATEGY}) against a database that has never
 * been seeded. {@code sql-load-script} is deliberately left at its shipped value: Quarkus only
 * runs it under {@code drop-and-create}/{@code create}, so under {@code update} the schema is
 * created and the 30 seeds — and the {@code CREATE SEQUENCE} that used to live only in
 * {@code import.sql} — never load. The claim-numbering initializer is what has to cope.
 *
 * <p>The H2 URL is overridden to a database name of its own because {@code DB_CLOSE_DELAY=-1}
 * keeps an in-memory H2 alive for the whole JVM: sharing {@code mem:claims} with the other test
 * classes would hand this one their rows and it would not be testing an empty database at all.
 */
@QuarkusTest
@TestProfile(ClaimNumberingEmptyDbTest.EmptyDatabaseProfile.class)
class ClaimNumberingEmptyDbTest {

    /** The storage-stateful entry state: schema managed with `update`, nothing seeded. */
    public static class EmptyDatabaseProfile implements QuarkusTestProfile {
        @Override
        public Map<String, String> getConfigOverrides() {
            return Map.of(
                    "quarkus.hibernate-orm.schema-management.strategy", "update",
                    "quarkus.datasource.jdbc.url", "jdbc:h2:mem:claims-empty;DB_CLOSE_DELAY=-1");
        }
    }

    @Test
    void emptyDatabaseNumbersFromCLM1001() {
        // Precondition — and a check on the premise: under `update` the seed script must NOT run.
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .body("size()", is(0));

        assertEquals("CLM-1001", createClaim("Nadia Rahman", "auto", "3200"));
        assertEquals("CLM-1002", createClaim("Owen Fletcher", "home", "18750"));
        assertEquals("CLM-1003", createClaim("Priya Das", "life", "50000"));

        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .header("X-Total-Count", is("3"));
    }

    /** POST the exact three payloads storage-stateful's lab sends, and return the assigned number. */
    private static String createClaim(String claimant, String type, String amount) {
        return given()
                .contentType("application/json")
                .body("{\"claimant\":\"" + claimant + "\",\"type\":\"" + type + "\",\"amount\":" + amount + "}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .extract().path("claimNumber");
    }
}
