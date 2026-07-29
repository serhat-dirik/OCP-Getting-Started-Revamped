package com.parasol.claims;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import io.micrometer.core.instrument.MeterRegistry;
import io.quarkus.hibernate.orm.panache.Panache;
import io.quarkus.hibernate.orm.panache.PanacheQuery;
import io.quarkus.panache.common.Page;
import io.quarkus.panache.common.Sort;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * REST surface for Parasol claims.
 *
 * <pre>
 *   GET  /api/claims                     list claims (optional ?page= &amp; ?size= paging)
 *   GET  /api/claims/{claimNumber}        one claim by its number
 *   POST /api/claims                      create a claim (server assigns the next number)
 *   PUT  /api/claims/{claimNumber}/status advance a claim's workflow status
 * </pre>
 *
 * Kept deliberately small (one resource class) so it reads in a few minutes.
 */
@Path("/api/claims")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class ClaimResource {

    /** Allowed lines of business — POST is rejected with 400 for anything else. Alphabetical. */
    static final Set<String> TYPES = ordered("auto", "home", "life");

    /** Allowed workflow states — the status update is rejected with 400 for anything else. */
    static final Set<String> STATUSES = ordered("Submitted", "UnderReview", "Approved", "Denied");

    /**
     * An unmodifiable set that iterates in declaration order — deliberately NOT {@code Set.of}.
     *
     * <p>Both sets above are rendered verbatim into the 400 bodies below, which are read by an
     * attendee trying to correct a request. {@code Set.of} iterates in an order derived from a
     * per-JVM random SALT, so the same mistake printed {@code [auto, life, home]} on one restart
     * and something else on the next — no captured output in the docs could be trusted, and any
     * test asserting the message text would be flaky. Declaration order also lets STATUSES read as
     * the workflow it is (Submitted → UnderReview → Approved/Denied) rather than as noise.
     *
     * <p>Secondary, and the reason this was found: {@code Set.of(...).contains(null)} <em>throws</em>
     * NullPointerException instead of answering false, so a validation guard written as
     * {@code !TYPES.contains(input.type())} blew up inside its own condition whenever the field was
     * absent. A HashSet-family set answers false. The guards below null-check explicitly anyway —
     * correctness there must not depend on which Set implementation someone picks later.
     */
    private static Set<String> ordered(String... values) {
        return Collections.unmodifiableSet(new LinkedHashSet<>(Arrays.asList(values)));
    }

    private static final int DEFAULT_PAGE_SIZE = 20;
    private static final int MAX_PAGE_SIZE = 100;

    /** Micrometer registry for the custom business metric (curriculum: M11). */
    @Inject
    MeterRegistry registry;

    /** Hands out claim numbers from the database sequence it also creates at startup. */
    @Inject
    ClaimNumberSequence claimNumbers;

    /**
     * List claims, sorted by claim number. Returns every claim by default so lab text and
     * dashboards see all 30 seeds; pass {@code ?page=N&size=M} to page through them. The
     * total is always returned in the {@code X-Total-Count} header.
     */
    @GET
    public Response list(@QueryParam("page") Integer page, @QueryParam("size") Integer size) {
        PanacheQuery<Claim> query = Claim.findAll(Sort.by("claimNumber"));
        long total = query.count();

        List<Claim> claims;
        if (page == null && size == null) {
            claims = query.list();
        } else {
            int pageIndex = page == null ? 0 : Math.max(page, 0);
            int pageSize = size == null ? DEFAULT_PAGE_SIZE : Math.min(Math.max(size, 1), MAX_PAGE_SIZE);
            claims = query.page(Page.of(pageIndex, pageSize)).list();
        }
        return Response.ok(claims).header("X-Total-Count", total).build();
    }

    /** Fetch a single claim by its business number, or 404. */
    @GET
    @Path("/{claimNumber}")
    public Response get(@PathParam("claimNumber") String claimNumber) {
        Claim claim = Claim.findById(claimNumber);
        if (claim == null) {
            return notFound(claimNumber);
        }
        return Response.ok(claim).build();
    }

    /**
     * A claim's audit timeline.
     *
     * <p><strong>Deliberate N+1 query pattern (curriculum: M11).</strong> This method
     * first runs ONE query to fetch the ids of the claim's events, then loads each
     * event individually by primary key in a loop — so a claim with N events costs
     * {@code 1 + N} SELECTs. Every {@code findById} shows as its own JDBC span in the
     * M11 trace, which is how attendees spot the anti-pattern. The one-line fix (a
     * single {@code ClaimEvent.list("claimNumber", Sort.by("createdAt"), claimNumber)})
     * is left for the lab — do NOT "optimize" it here, the slowness is the lesson.
     */
    @GET
    @Path("/{claimNumber}/history")
    public Response history(@PathParam("claimNumber") String claimNumber) {
        Claim claim = Claim.findById(claimNumber);
        if (claim == null) {
            return notFound(claimNumber);
        }

        // Query #1: just the ids of this claim's events, oldest first.
        List<Long> eventIds = Panache.getEntityManager()
                .createQuery("select e.id from ClaimEvent e where e.claimNumber = ?1 order by e.createdAt", Long.class)
                .setParameter(1, claimNumber)
                .getResultList();

        // Queries #2..N+1: load each event on its own — one SELECT per row (the N+1).
        List<ClaimEvent> events = new ArrayList<>();
        for (Long id : eventIds) {
            events.add(ClaimEvent.findById(id));
        }

        return Response.ok(new ClaimHistory(claim.claimNumber, claim.claimant, claim.status, events)).build();
    }

    /**
     * Create a claim. The caller supplies the claimant, type, amount and incident date;
     * the server assigns the next claim number and opens it in the {@code Submitted} state
     * with an {@code Unassigned} adjuster.
     *
     * <p>The number comes from the {@code claim_number_seq} database sequence — never from
     * "the highest number I can see, plus one", which two replicas lose the race on. Where the
     * numbering starts depends on what the database already holds: {@code CLM-1031} on the
     * 30-claim seeded database most modules run, {@code CLM-1001} on the empty one the storage
     * module starts from. See {@link ClaimNumberSequence}.
     */
    @POST
    @Transactional
    public Response create(NewClaim input) {
        // One check per field, each naming the field it rejected. The old single combined guard
        // answered three different mistakes with one message that named none of them — and it
        // never ran at all when 'type' was absent, because the set lookup threw first (see
        // ordered()). Null is checked BEFORE the lookup so the order of operations is the fix,
        // not the collection type.
        if (input == null) {
            return badRequest("a JSON request body is required, with at least 'claimant' and "
                    + "'type' (one of " + TYPES + ")");
        }
        if (isBlank(input.claimant())) {
            return badRequest("field 'claimant' is required");
        }
        if (isBlank(input.type())) {
            // The common way in: 'type' appears in only two places in the whole workshop (the
            // lab's JSON and this app's README), so a near-miss like "claimType" is easy — and
            // Jackson drops unknown properties silently, leaving 'type' null. Say so, or the
            // attendee stares at a body that plainly contains a type.
            return badRequest("field 'type' is required and must be one of " + TYPES
                    + "; any other field name in the body is ignored");
        }
        if (!TYPES.contains(input.type())) {
            return badRequest("field 'type' must be one of " + TYPES + ", not '" + input.type() + "'");
        }
        Claim claim = new Claim();
        claim.claimNumber = claimNumbers.next();
        claim.claimant = input.claimant();
        claim.type = input.type();
        claim.amount = input.amount() == null ? BigDecimal.ZERO : input.amount();
        claim.incidentDate = input.incidentDate() == null ? LocalDate.now() : input.incidentDate();
        claim.adjuster = isBlank(input.adjuster()) ? "Unassigned" : input.adjuster();
        claim.status = "Submitted";
        claim.persist();
        // Custom business metric (curriculum: M11). Micrometer appends _total to
        // counters, so this is scraped at /q/metrics as claims_created_total.
        registry.counter("claims_created").increment();
        return Response.status(Response.Status.CREATED).entity(claim).build();
    }

    /** Advance a claim to a new workflow status (Submitted -> UnderReview -> Approved/Denied). */
    @PUT
    @Path("/{claimNumber}/status")
    @Transactional
    public Response updateStatus(@PathParam("claimNumber") String claimNumber, StatusUpdate update) {
        // Same shape, same fix as create() above: null before lookup, one message per mistake.
        if (update == null) {
            return badRequest("a JSON request body is required, with the field 'status' (one of "
                    + STATUSES + ")");
        }
        if (isBlank(update.status())) {
            return badRequest("field 'status' is required and must be one of " + STATUSES
                    + "; any other field name in the body is ignored");
        }
        if (!STATUSES.contains(update.status())) {
            return badRequest("field 'status' must be one of " + STATUSES + ", not '"
                    + update.status() + "'");
        }
        Claim claim = Claim.findById(claimNumber);
        if (claim == null) {
            return notFound(claimNumber);
        }
        claim.status = update.status();
        return Response.ok(claim).build();
    }

    private static Response notFound(String claimNumber) {
        return Response.status(Response.Status.NOT_FOUND)
                .entity(Map.of("error", "No claim with number " + claimNumber)).build();
    }

    private static Response badRequest(String message) {
        return Response.status(Response.Status.BAD_REQUEST).entity(Map.of("error", message)).build();
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    /** Request body for {@code POST /api/claims}. */
    public record NewClaim(String claimant, String type, BigDecimal amount, LocalDate incidentDate, String adjuster) {
    }

    /** Request body for {@code PUT /api/claims/{claimNumber}/status}. */
    public record StatusUpdate(String status) {
    }

    /** Response body for {@code GET /api/claims/{claimNumber}/history}. */
    public record ClaimHistory(String claimNumber, String claimant, String status, List<ClaimEvent> events) {
    }
}
