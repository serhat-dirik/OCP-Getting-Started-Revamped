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
 * M21 contract guard. When {@code SITE} is set, the {@code GET /} body must carry a
 * <em>compact</em> {@code "site":"<SITE>"} marker (no spaces around the colon),
 * because M21's cross-site failover client extracts the site letter from the body
 * with a {@code sed} regex over {@code "site":"A"} / {@code "site":"B"}. If anyone
 * turned on JSON pretty-printing, that grep would silently stop matching and the
 * failover demo would read {@code served-by-site=none}; this test fails first instead.
 */
@QuarkusTest
@TestProfile(RootResourceSiteTest.SiteAProfile.class)
class RootResourceSiteTest {

    /** Sets SITE=A the way the M21 site-a Deployment does, via config. */
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
                // The exact compact substring M21's sed greps for (no spaces).
                .body(containsString("\"site\":\"A\""));
    }
}
