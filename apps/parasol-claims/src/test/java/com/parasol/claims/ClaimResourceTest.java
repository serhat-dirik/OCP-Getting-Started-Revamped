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
import io.restassured.response.Response;

/**
 * Build-time smoke tests over the seeded API and the readiness probe, run against
 * in-memory H2 (no PostgreSQL needed). Run by the {@code apps-test} workflow
 * ({@code .github/workflows/apps-test.yml}) on every change under {@code apps/}, so a
 * broken claims service fails the pipeline, not the lab.
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

    /**
     * The shipped data must obey the rule the shipped API enforces.
     *
     * <p>{@code updateStatus} refuses to approve a claim whose adjuster is {@code Unassigned}, so
     * a seed row that is BOTH {@code Approved} and {@code Unassigned} would be a state the
     * service can no longer produce — the database contradicting its own API, and a claim no lab
     * could explain. All 11 approved seeds name a real adjuster today; this keeps it that way if
     * someone edits {@code import.sql} for another module. It reads the live list rather than the
     * file, so it also covers rows any other test created.
     */
    @Test
    void noSeededClaimIsApprovedWithoutAnAdjuster() {
        List<String> approvedButUnowned = given()
                .when().get("/api/claims")
                .then()
                .statusCode(200)
                .extract()
                .path("findAll { it.status == 'Approved' && it.adjuster == 'Unassigned' }.claimNumber");

        assertEquals(List.of(), approvedButUnowned,
                "import.sql seeds a claim that is Approved while Unassigned - the API itself "
                        + "would refuse to put it in that state (409). Give it an adjuster, or "
                        + "leave it Submitted.");
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
     * sequence only counts up, so no created claim can ever take it. (The observability
     * module's load generator uses the same number for its steady 404 beat.) Do NOT use a
     * high number like CLM-9999 here: creates really do reach five digits under sustained
     * load, and the numbering regression test below deliberately walks the sequence across
     * that boundary.
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
                .statusCode(400)
                // The body has to name the field AND the accepted values, or the attendee has
                // nothing to correct against but the lab's own JSON.
                .body("error", containsString("'type'"))
                .body("error", containsString("auto"))
                .body("error", containsString("boat"));
    }

    /**
     * Regression (measured live on a workshop cluster 2026-07-29): a POST that omits {@code type}
     * returned <strong>500</strong> with a raw
     * {@code java.lang.NullPointerException at ImmutableCollections$SetN.contains}, not the 400 the
     * guard plainly intends. {@code TYPES} was a {@code Set.of(...)}, and {@code Set.of} rejects a
     * null argument to {@code contains} by throwing rather than answering false — so the validation
     * blew up inside its own condition, before it could ever reach its own error path.
     */
    @Test
    void createWithoutTypeReturns400NamingTheField() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"No Type At All\"}")
                .when().post("/api/claims")
                .then()
                .statusCode(400)
                .body("error", containsString("'type'"))
                .body("error", containsString("auto"))
                .body("error", containsString("home"))
                .body("error", containsString("life"));
    }

    /**
     * The way an attendee actually hits the case above: the field name is {@code type}, and it
     * appears in exactly two places in the whole workshop (the lab's JSON and the app README), so
     * a plausible-looking {@code claimType} is an easy typo. Quarkus/Jackson ignores unknown
     * properties by default, so the misspelled field is silently dropped and {@code type} arrives
     * null — indistinguishable, to the resource, from omitting it. The response must still be a
     * 400 that names the field the server actually wants.
     */
    @Test
    void createWithMisspelledTypeFieldReturns400NamingTheRealField() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Typo Tester\",\"claimType\":\"auto\",\"amount\":100.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(400)
                .body("error", containsString("'type'"));
    }

    @Test
    void createWithoutClaimantReturns400NamingTheField() {
        given()
                .contentType("application/json")
                .body("{\"type\":\"auto\"}")
                .when().post("/api/claims")
                .then()
                .statusCode(400)
                .body("error", containsString("'claimant'"));
    }

    /**
     * The same defect, one endpoint over: {@code STATUSES} was a {@code Set.of(...)} too, so a
     * status update whose {@code status} field is missing or misspelled threw the identical NPE
     * inside the identical guard.
     */
    @Test
    void updateStatusWithoutStatusFieldReturns400NamingTheField() {
        given()
                .contentType("application/json")
                .body("{\"state\":\"Approved\"}")
                .when().put("/api/claims/CLM-1006/status")
                .then()
                .statusCode(400)
                .body("error", containsString("'status'"))
                .body("error", containsString("Approved"));
    }

    /**
     * The accepted values are rendered straight into a message an attendee reads, so their order
     * must not move. {@code Set.of} iterates in an order derived from a per-JVM random SALT, which
     * means the identical mistake printed a different list on every restart — and no captured
     * output in the docs could ever be trusted. Both sets are ordered now: {@code TYPES}
     * alphabetically, {@code STATUSES} in workflow order, which is the more useful reading.
     */
    @Test
    void errorMessagesListAcceptedValuesInAStableOrder() {
        given()
                .contentType("application/json")
                .body("{\"claimant\":\"Order Probe\",\"type\":\"boat\"}")
                .when().post("/api/claims")
                .then()
                .statusCode(400)
                .body("error", containsString("[auto, home, life]"));
        given()
                .contentType("application/json")
                .body("{\"status\":\"Frozen\"}")
                .when().put("/api/claims/CLM-1007/status")
                .then()
                .statusCode(400)
                .body("error", containsString("[Submitted, UnderReview, Approved, Denied]"));
    }

    /**
     * The happy path for the approval rule, and deliberately NOT on a Submitted claim.
     *
     * <p>It used to approve {@code CLM-1003}, which the seed opens {@code Submitted} with
     * {@code adjuster=Unassigned} — so the moment {@code updateStatus} started enforcing
     * Parasol's adjuster rule, this test was asking the service to break it and failing on the
     * 409. {@code CLM-1019} is seeded {@code UnderReview} under Rebecca Torres, so approving it
     * is a legal move that no other test in this class reads back.
     *
     * <p>This one carries no toggle: it is the permanent proof that a properly assigned claim
     * still approves, and it stays green whichever way the break-fix toggle below is set.
     */
    @Test
    void updateStatusAdvancesClaim() {
        given()
                .contentType("application/json")
                .body("{\"status\":\"Approved\"}")
                .when().put("/api/claims/CLM-1019/status")
                .then()
                .statusCode(200)
                .body("claimNumber", is("CLM-1019"))
                .body("status", is("Approved"))
                .body("adjuster", is("Rebecca Torres"));
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
     * securing-apps-keycloak regression guard: quarkus-oidc is on the classpath but the
     * tenant is DISABLED by default, so the API must stay anonymous - no token, still 200.
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

    /** The observability-health-scale N+1 endpoint returns the seeded timeline, oldest event first. */
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
     * the service runs at more than one replica, which several modules do (the observability
     * module's HPA scales parasol-claims to min=2, and other modules run it at 3). This test
     * drives the race in one JVM; it cannot reproduce the cross-pod case, but the sequence is
     * what makes both safe, because {@code nextval} is atomic in the database rather than in
     * any one process.
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

    /** POST the exact payload the observability load generator sends, and return the assigned number. */
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
     * The Parasol adjuster rule from the other side: the service must REFUSE to approve a claim
     * nobody owns, and must not half-apply the change.
     *
     * <p>This test carries no toggle and is never edited by a lab. It is what keeps the rule
     * honest: the break-fix test below approves a claim that HAS an adjuster in its shipped
     * state, so without this one, deleting the guard out of {@code ClaimResource.updateStatus}
     * would leave the whole suite green. It also pins the rule's SCOPE — an unassigned claim is
     * still free to move to {@code UnderReview} or {@code Denied}; only {@code Approved} is
     * guarded.
     */
    @Test
    void approvingAnUnassignedClaimIsRefused() {
        String claimNumber = given()
                .contentType("application/json")
                .body("{\"claimant\":\"Nobody Owns This\",\"type\":\"home\",\"amount\":4400.00}")
                .when().post("/api/claims")
                .then()
                .statusCode(201)
                .body("adjuster", is("Unassigned"))
                .extract().path("claimNumber");

        // 409, not 400: the body is valid, the CLAIM is not in a state that permits it.
        given()
                .contentType("application/json")
                .body("{\"status\":\"Approved\"}")
                .when().put("/api/claims/" + claimNumber + "/status")
                .then()
                .statusCode(409)
                .body("error", containsString(claimNumber))
                .body("error", containsString("Unassigned"));

        // Refused means refused — nothing was persisted.
        given()
                .when().get("/api/claims/" + claimNumber)
                .then()
                .statusCode(200)
                .body("status", is("Submitted"));

        // Scope: the same unassigned claim may still be reviewed, and may still be denied.
        given()
                .contentType("application/json")
                .body("{\"status\":\"UnderReview\"}")
                .when().put("/api/claims/" + claimNumber + "/status")
                .then()
                .statusCode(200)
                .body("status", is("UnderReview"));
        given()
                .contentType("application/json")
                .body("{\"status\":\"Denied\"}")
                .when().put("/api/claims/" + claimNumber + "/status")
                .then()
                .statusCode(200)
                .body("status", is("Denied"));
    }

    /**
     * The same rule as the test above, wired as the Pipelines Fundamentals break-fix device.
     *
     * <p>It is a real test of a real rule — {@code ClaimResource.updateStatus} enforces it — and
     * the toggle decides which side of the rule this test drives:
     *
     * <ul>
     *   <li>{@code true} (as shipped): the claim is opened WITH an adjuster, the service accepts
     *       the approval with 200, and the test is green.</li>
     *   <li>{@code false}: the claim is opened with no adjuster, the service refuses the
     *       approval with 409, and the assertion below fails saying exactly that.</li>
     * </ul>
     *
     * <p>Do not remove or rename the toggle, and keep its declaration on one line: the module's
     * lab tells attendees to find {@code assignAdjusterBeforeApproval} in this file and edit that
     * line, and quotes the resulting failure message verbatim. See "Intentional flaws" in the
     * app README.
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

        // Ask the service to approve it and keep WHATEVER it answered - the status code included,
        // because a refusal is the rule working, not a transport problem.
        Response approval = given()
                .contentType("application/json")
                .body("{\"status\":\"Approved\"}")
                .when().put("/api/claims/" + claimNumber + "/status")
                .then()
                .extract().response();

        assertEquals(200, approval.statusCode(),
                "Parasol rule enforced: the API refused to approve claim " + claimNumber
                        + " while its adjuster was Unassigned - an adjuster must own a claim "
                        + "before it can be approved. PUT /api/claims/" + claimNumber
                        + "/status answered " + approval.statusCode() + " " + approval.asString());
        assertEquals("Approved", approval.path("status"),
                "claim " + claimNumber + " did not come back Approved");
        assertNotEquals("Unassigned", approval.path("adjuster"),
                "claim " + claimNumber + " was Approved while still Unassigned");
    }
}
