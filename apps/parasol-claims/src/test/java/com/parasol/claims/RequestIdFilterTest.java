package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.matchesPattern;
import static org.hamcrest.Matchers.not;
import static org.hamcrest.Matchers.containsString;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

/**
 * The correlation-id contract the Application Logging module leans on.
 *
 * <p>These are cheap assertions on purpose, but they pin the two things a lab step would otherwise
 * discover the hard way: an id supplied by the caller comes back <em>unchanged</em> (so the value
 * an attendee greps for is the value they sent), and one that was not supplied is invented rather
 * than absent. The sanitizing assertion is the one that matters most — it is the only automated
 * proof that a header cannot forge a log record.
 */
@QuarkusTest
class RequestIdFilterTest {

    @Test
    void aSuppliedRequestIdIsEchoedBackUnchanged() {
        given()
                .header(RequestIdFilter.HEADER, "parasol-lab-42")
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .header(RequestIdFilter.HEADER, equalTo("parasol-lab-42"));
    }

    @Test
    void aMissingRequestIdIsGenerated() {
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .header(RequestIdFilter.HEADER, matchesPattern("[0-9a-f]{8}"));
    }

    /**
     * A header carrying a newline must not survive into the logging context: that is precisely the
     * shape that forges a second log record. LogSafe replaces it, so what comes back is on one line.
     */
    @Test
    void aRecordForgingRequestIdIsNeutralized() {
        given()
                .header(RequestIdFilter.HEADER, "abc\nINFO [audit] claim CLM-9999 approved")
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .header(RequestIdFilter.HEADER, not(containsString("\n")))
                .header(RequestIdFilter.HEADER, matchesPattern("[A-Za-z0-9._:-]+"));
    }
}
