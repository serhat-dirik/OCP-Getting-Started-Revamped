package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.is;

import java.util.Map;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.QuarkusTestProfile;
import io.quarkus.test.junit.TestProfile;

/**
 * Wire-format guard for the origin-site marker. When {@code SITE} is set, the {@code GET /} body
 * must carry a <em>compact</em> {@code "site":"<SITE>"} marker (no spaces around the colon),
 * because the consumer of that marker is a {@code sed} regex over {@code "site":"A"} /
 * {@code "site":"B"}, not a JSON parser. Turn on JSON pretty-printing and such a grep stops
 * matching silently — a failover readout would just say {@code served-by-site=none} with nothing
 * logged. This test fails first instead.
 *
 * <p><strong>This guard currently has no live consumer of THIS implementation, and is kept
 * deliberately.</strong> It was written for resilience-multicluster-dr, whose verify script still
 * runs exactly that {@code sed} — but that module now serves the marker from an inline Node
 * responder rather than from this image, and nothing in the workshop sets {@code SITE} on a
 * parasol-claims container any more (enumerated 2026-08-06). Two reasons it stays: the compact
 * format is a <em>shared</em> contract that {@code parasol-notifications} also implements and
 * that packaging-distributing does exercise live, and pointing a site-aware deployment back at
 * this image is a one-line env change that would otherwise regress unnoticed. Whether to retire
 * the {@code SITE} feature here altogether is an owner decision, not a test-hygiene one.
 */
@QuarkusTest
@TestProfile(RootResourceSiteTest.SiteAProfile.class)
class RootResourceSiteTest {

    /** Sets SITE=A the way a site-aware Deployment would, via config rather than a real env var. */
    public static class SiteAProfile implements QuarkusTestProfile {
        @Override
        public Map<String, String> getConfigOverrides() {
            return Map.of("SITE", "A");
        }
    }

    @Test
    void rootCarriesCompactSiteMarkerWhenSiteSet() {
        given()
                .when().get("/")
                .then()
                .statusCode(200)
                .body("service", is("parasol-claims"))
                .body("site", is("A"))
                // The exact compact substring a sed-based site reader greps for (no spaces).
                .body(containsString("\"site\":\"A\""));
    }
}
