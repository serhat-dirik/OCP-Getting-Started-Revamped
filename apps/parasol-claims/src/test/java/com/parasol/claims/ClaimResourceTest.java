package com.parasol.claims;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.greaterThanOrEqualTo;
import static org.hamcrest.Matchers.is;
import static org.hamcrest.Matchers.notNullValue;
import static org.hamcrest.Matchers.startsWith;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;

import io.quarkus.hibernate.orm.panache.Panache;
import io.quarkus.narayana.jta.QuarkusTransaction;
import io.quarkus.test.junit.QuarkusTest;

/**
 * Build-time smoke tests over the seeded API and the readiness probe, run against
 * in-memory H2 (no PostgreSQL needed). Feeds the CI "apps" job so a broken claims
 * service fails the pipeline, not the lab.
 *
 * <p>Assertions are order-independent: the create test adds a row, so list checks
 * assert "at least 30" plus exact seeded values rather than a brittle exact count.
 */
@QuarkusTest
class ClaimResourceTest {

    @Test
    void listReturnsSeededClaimsSortedByNumber() {
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .header("X-Total-Count", notNullValue())
                .body("size()", greaterThanOrEqualTo(30))
                .body("[0].claimNumber", is("CLM-1001"))
                .body("[0].claimant", is("Alice Nguyen"))
                .body("[0].type", is("auto"))
                .body("[0].status", is("UnderReview"));
    }

    @Test
    void pagingReturnsRequestedSlice() {
        given()
                .when().get("/api/claims?page=0&size=5")
                .then()
                .statusCode(200)
                .header("X-Total-Count", notNullValue())
                .body("size()", is(5))
                .body("[0].claimNumber", is("CLM-1001"))
                .body("[4].claimNumber", is("CLM-1005"));
    }

    @Test
    void getByNumberReturnsOneClaim() {
        given()
                .when().get("/api/claims/CLM-1005")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1005"))
                .body("claimant", is("Sofia Alvarez"))
                .body("type", is("life"))
                .body("status", is("Approved"))
                .body("adjuster", is("David Okonkwo"));
    }

    /**
     * CLM-0000 is the canonical "never exists" probe — it is below the seed range and the
     * sequence only counts up, so no created claim can ever take it. (The M11 load generator
     * uses the same number for its steady 404 beat.) Do NOT use a high number like CLM-9999
     * here: creates really do reach five digits under sustained load, and the numbering
     * regression test below deliberately walks the sequence across that boundary.
     */
    @Test
    void getUnknownClaimReturns404() {
        given()
                .when().get("/api/claims/CLM-0000")
                .then()
                .statusCode(404);
    }

    @Test
    void createAssignsNumberAndOpensSubmitted() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Test Claimant\",\"type\":\"auto\",\"amount\":1234.56,\"incidentDate\":\"2026-07-01\"}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .body("claimNumber", startsWith("CLM-"))
                .body("status", is("Submitted"))
                .body("adjuster", is("Unassigned"));
    }

    @Test
    void createRejectsUnknownType() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Bad Type\",\"type\":\"boat\"}")
                .when().post("/api/claims")
                .then()
                .statusCode(400);
    }

    @Test
    void updateStatusAdvancesClaim() {
        given()
                .contentType("application/json")
                .body("{\"status\":\"Approved\"}")
                .when().put("/api/claims/CLM-1003/status")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1003"))
                .body("status", is("Approved"));
    }

    @Test
    void updateStatusRejectsUnknownValue() {
        given()
                .contentType("application/json")
                .body("{\"status\":\"Frozen\"}")
                .when().put("/api/claims/CLM-1004/status")
                .then()
                .statusCode(400);
    }

    @Test
    void readinessProbeIsUp() {
        given()
                .when().get("/q/health/ready")
                .then()
                .statusCode(200)
                .body("status", is("UP"));
    }

    /**
     * M29 regression guard: quarkus-oidc is on the classpath but the tenant is
     * DISABLED by default, so the API must stay anonymous - no token, still 200.
     * If someone flips tenant-enabled=true in the shipped config, this fails.
     */
    @Test
    void apiIsAnonymousByDefault() {
        given()
                .when().get("/api/claims")
                .then()
                .statusCode(200);
        given()
                .when().get("/api/claims/CLM-1001")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1001"));
    }

    /** The M11 N+1 endpoint returns the seeded timeline, oldest event first. */
    @Test
    void historyReturnsSeededTimeline() {
        given()
                .when().get("/api/claims/CLM-1001/history")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1001"))
                .body("claimant", is("Alice Nguyen"))
                .body("events.size()", is(5))
                .body("events[0].eventType", is("Submitted"))
                .body("events[4].eventType", is("UnderReview"));
    }

    @Test
    void historyForUnknownClaimReturns404() {
        given()
                .when().get("/api/claims/CLM-0000/history")
                .then()
                .statusCode(404);
    }

    /** Creating a claim increments the custom Micrometer counter (claims_created_total). */
    @Test
    void createIncrementsClaimsCreatedCounter() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Metric Probe\",\"type\":\"home\",\"amount\":100.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(201);
        given()
                .when().get("/q/metrics")
                .then()
                .statusCode(200)
                .body(containsString("claims_created_total"));
    }

    /**
     * Regression: claim numbering must not wedge when it crosses from four digits to five.
     *
     * <p>The original implementation asked the database for {@code order by claimNumber desc}
     * — a <em>string</em> sort — and added one to the suffix. That works while every number is
     * four digits, then breaks permanently: once CLM-10000 exists, "CLM-9999" still sorts
     * highest ('9' &gt; '1' at the fifth character), so every later create recomputes 10000 and
     * dies on the primary key. Measured live 2026-07-28: 8970 creates succeeded, then every
     * single one after that returned 500 — 1768 of them and counting.
     *
     * <p>This walks the sequence up to the boundary and creates straight through it. The third
     * create is the one that used to fail.
     */
    @Test
    void numberingCrossesTheFiveDigitBoundaryWithoutColliding() {
        restartClaimNumberSequenceAt(9999);
        try {
            assertEquals("CLM-9999", createLoadShapedClaim());
            assertEquals("CLM-10000", createLoadShapedClaim());
            // Under the old max+1 scheme this recomputed CLM-10000 and returned 500 forever.
            assertEquals("CLM-10001", createLoadShapedClaim());
        } finally {
            // Put the shared test database back in the four-digit world the other tests assume.
            // Five-digit numbers sort BEFORE CLM-1001 in the claim_number string ordering that
            // GET /api/claims uses, so leaving them behind would break the list/paging tests --
            // see the "known wart" note in README.md.
            deleteClaims("CLM-9999", "CLM-10000", "CLM-10001");
            restartClaimNumberSequenceAt(SAFE_SEQUENCE_RESTART);
        }
    }

    /**
     * Regression: concurrent creates must never be handed the same number.
     *
     * <p>Any "read the current max, add one" scheme loses this race — two callers read the same
     * max and both insert it. That is what makes the bug unfixable at the application level once
     * the service runs at more than one replica, which several modules do (the M11 HPA scales
     * parasol-claims to min=2, and other modules run it at 3). This test drives the race in one
     * JVM; it cannot reproduce the cross-pod case, but the sequence is what makes both safe,
     * because {@code nextval} is atomic in the database rather than in any one process.
     */
    @Test
    void concurrentCreatesGetDistinctNumbers() throws Exception {
        final int threads = 16;
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        try {
            CountDownLatch startLine = new CountDownLatch(1);
            List<Future<String>> results = new ArrayList<>();
            for (int i = 0; i < threads; i++) {
                results.add(pool.submit(() -> {
                    startLine.await();           // release them all at once
                    return createLoadShapedClaim();
                }));
            }
            startLine.countDown();

            Set<String> numbers = new HashSet<>();
            for (Future<String> result : results) {
                numbers.add(result.get(30, TimeUnit.SECONDS));
            }
            assertEquals(threads, numbers.size(),
                    "concurrent creates handed out a duplicate claim number: " + numbers);
        } finally {
            pool.shutdownNow();
        }
    }

    /** POST the exact payload the M11 load generator sends, and return the assigned number. */
    private static String createLoadShapedClaim() {
        return given()
                .contentType("application/json")
                .body("{\"claimant\":\"Load Generator\",\"type\":\"auto\",\"amount\":100.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .extract().path("claimNumber");
    }

    /**
     * Where the boundary test leaves the sequence: comfortably above the CLM-1030 seeds and
     * above anything the other create tests allocate, but still four digits.
     */
    private static final long SAFE_SEQUENCE_RESTART = 2000;

    /**
     * Fast-forward the sequence so a test can reach a boundary without 9000 inserts.
     *
     * <p>Uses {@code QuarkusTransaction} rather than {@code @Transactional}: this is called
     * from a test method on the same class, and self-invocation does not go through the CDI
     * interceptor that {@code @Transactional} relies on.
     */
    private static void restartClaimNumberSequenceAt(long value) {
        QuarkusTransaction.requiringNew().run(() -> Panache.getEntityManager()
                .createNativeQuery("alter sequence claim_number_seq restart with " + value)
                .executeUpdate());
    }

    /** Remove specific claims so a test that perturbs the numbering leaves no trace. */
    private static void deleteClaims(String... claimNumbers) {
        QuarkusTransaction.requiringNew().run(() -> {
            for (String claimNumber : claimNumbers) {
                Claim.delete("claimNumber", claimNumber);
            }
        });
    }

    /**
     * M07 break-fix device (Pipelines lab), not a real feature - it encodes the Parasol
     * rule that a claim cannot be Approved while still Unassigned. Flip the toggle below
     * (true -> false) to inject the bug; the unit-test task goes red, then revert for green.
     */
    @Test
    void approvingAClaimRequiresAnAssignedAdjuster() {
        // M07 lab: change this one line true -> false to break the build; revert to fix it.
        final boolean assignAdjusterBeforeApproval = true;

        // Open a claim. Toggle on -> it names an adjuster; toggle off -> it stays Unassigned.
        String claimNumber = given()
                .contentType("application/json")
                .body(assignAdjusterBeforeApproval
                        ? "{\"claimant\":\"Break-Fix Check\",\"type\":\"auto\",\"amount\":8200.00,\"adjuster\":\"Rebecca Torres\"}"
                        : "{\"claimant\":\"Break-Fix Check\",\"type\":\"auto\",\"amount\":8200.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .extract().path("claimNumber");

        // Approve it, then read back the adjuster the claim was approved under.
        String adjuster = given()
                .contentType("application/json")
                .body("{\"status\":\"Approved\"}")
                .when().put("/api/claims/" + claimNumber + "/status")
                .then()
                .statusCode(200)
                .body("status", is("Approved"))
                .extract().path("adjuster");

        assertNotEquals("Unassigned", adjuster,
                "Parasol rule violated: claim " + claimNumber + " was Approved while still "
                        + "Unassigned - an adjuster must own a claim before it can be approved");
    }
}
