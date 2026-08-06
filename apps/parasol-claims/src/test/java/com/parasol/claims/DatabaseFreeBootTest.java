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
 * without contacting a database at all. Two module worlds depend on it, and in BOTH a pod that
 * crash-looped for a database reason would be mistaken for the probe fault the lab is actually
 * about:
 *
 * <ul>
 *   <li><strong>ai-assisted-development</strong> — its seeded diagnosis target runs this image
 *       DB-free so the single deliberate fault is the wrong readiness path, not a missing
 *       {@code parasol-db}. Rendered at ENTRY, on every start, so this is the consumer that
 *       breaks first if the mode regresses.</li>
 *   <li><strong>app-modernization</strong> — the attendee deploys the modernized service
 *       DB-inactive by hand in the lab (the Console and CLI paths both spell the two variables
 *       out), and the {@code ws solve} end state renders the same pair.</li>
 * </ul>
 *
 * <p>resilience-multicluster-dr, which this mode was originally written for, no longer runs this
 * image at all — its per-site services are an inline Node responder, by that chart's own
 * deliberate choice. Counted 2026-08-06 by enumerating every {@code QUARKUS_DATASOURCE_ACTIVE}
 * and {@code quarkus.datasource.active} in the tree; re-count rather than trusting this list.
 *
 * <p>It earns its place next to the numbering tests specifically because {@link
 * ClaimNumberSequence} added work at <em>startup</em>. Startup code that queries the database is
 * exactly what breaks this mode, silently and only in the modules that use it, so the skip is
 * pinned by a test rather than by a comment.
 */
@QuarkusTest
@TestProfile(DatabaseFreeBootTest.NoDatabaseProfile.class)
class DatabaseFreeBootTest {

    /** What the ai-assisted-development / app-modernization Deployments set, as Quarkus config keys. */
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
