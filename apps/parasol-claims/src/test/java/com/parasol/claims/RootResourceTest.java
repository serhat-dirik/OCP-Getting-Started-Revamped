package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.hamcrest.Matchers.notNullValue;
import static org.hamcrest.Matchers.nullValue;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

/**
 * Build-time smoke over the {@code GET /} landing. Runs against in-memory H2 like
 * the rest of the suite, but the root never touches the datasource, so these
 * assertions hold with or without a database.
 */
@QuarkusTest
class RootResourceTest {

    @Test
    void rootIsAMeaningfulBrowseableLanding() {
        given()
                .when().get("/")
                .then()
                .statusCode(200)
                .body("service", is("parasol-claims"))
                .body("description", notNullValue())
                .body("links.claims", is("/api/claims"))
                .body("links.health", is("/q/health"))
                .body("links.metrics", is("/q/metrics"));
    }

    /** With SITE unset (the single-site default for M02–M20) the marker is absent. */
    @Test
    void rootOmitsSiteMarkerWhenSiteUnset() {
        given()
                .when().get("/")
                .then()
                .statusCode(200)
                .body("site", nullValue());
    }
}
