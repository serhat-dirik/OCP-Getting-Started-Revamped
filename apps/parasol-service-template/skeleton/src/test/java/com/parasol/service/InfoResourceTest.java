package com.parasol.service;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.hamcrest.Matchers.notNullValue;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

/** Build-time smoke over the starter endpoint and the readiness probe. */
@QuarkusTest
class InfoResourceTest {

    @Test
    void infoReturnsServiceName() {
        given()
                .when().get("/api/info")
                .then()
                .statusCode(200)
                .body("service", notNullValue())
                .body("status", is("ready"));
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
