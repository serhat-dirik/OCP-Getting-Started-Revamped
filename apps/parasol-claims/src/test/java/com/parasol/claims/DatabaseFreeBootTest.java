package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;

import java.util.Map;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.QuarkusTestProfile;
import io.quarkus.test.junit.TestProfile;

/**
 * Guards the DB-free drop-in mode: with {@code QUARKUS_DATASOURCE_ACTIVE=false} and
 * {@code QUARKUS_HIBERNATE_ORM_ACTIVE=false} this image must still boot and serve {@code GET /}
 * without contacting a database at all. Three entry states depend on it — M21's per-site
 * responder, the modernization module's deployed service, and the AI-assisted module's seeded
 * deployment — and in two of them a pod that crash-loops for a database reason would be mistaken
 * for the probe fault the lab is actually about.
 *
 * <p>It earns its place next to the numbering tests specifically because {@link
 * ClaimNumberSequence} added work at <em>startup</em>. Startup code that queries the database is
 * exactly what breaks this mode, silently and only in the modules that use it, so the skip is
 * pinned by a test rather than by a comment.
 */
@QuarkusTest
@TestProfile(DatabaseFreeBootTest.NoDatabaseProfile.class)
class DatabaseFreeBootTest {

    /** What the M21 / modernization Deployments set, spelled as Quarkus config keys. */
    public static class NoDatabaseProfile implements QuarkusTestProfile {
        @Override
        public Map<String, String> getConfigOverrides() {
            return Map.of(
                    "quarkus.datasource.active", "false",
                    "quarkus.hibernate-orm.active", "false");
        }
    }

    @Test
    void bootsAndServesTheLandingWithoutADatabase() {
        given()
                .when().get("/")
                .then()
                .statusCode(200)
                .body("service", is("parasol-claims"));
    }
}
