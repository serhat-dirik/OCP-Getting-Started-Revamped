package com.parasol.claims;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
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

    /** Allowed lines of business — POST is rejected with 400 for anything else. */
    static final Set<String> TYPES = Set.of("auto", "home", "life");

    /** Allowed workflow states — the status update is rejected with 400 for anything else. */
    static final Set<String> STATUSES = Set.of("Submitted", "UnderReview", "Approved", "Denied");

    private static final int DEFAULT_PAGE_SIZE = 20;
    private static final int MAX_PAGE_SIZE = 100;

    /** Micrometer registry for the custom business metric (curriculum: M11). */
    @Inject
    MeterRegistry registry;

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
     * the server assigns the next claim number (CLM-1031, CLM-1032, ...) and opens it in
     * the {@code Submitted} state with an {@code Unassigned} adjuster.
     */
    @POST
    @Transactional
    public Response create(NewClaim input) {
        if (input == null || isBlank(input.claimant()) || !TYPES.contains(input.type())) {
            return badRequest("claimant is required and type must be one of " + TYPES);
        }
        Claim claim = new Claim();
        claim.claimNumber = nextClaimNumber();
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
        if (update == null || !STATUSES.contains(update.status())) {
            return badRequest("status must be one of " + STATUSES);
        }
        Claim claim = Claim.findById(claimNumber);
        if (claim == null) {
            return notFound(claimNumber);
        }
        claim.status = update.status();
        return Response.ok(claim).build();
    }

    /** Next claim number = highest existing suffix + 1 (first created claim is CLM-1031). */
    private static String nextClaimNumber() {
        Claim last = Claim.find("order by claimNumber desc").firstResult();
        int next = 1001;
        if (last != null) {
            try {
                next = Integer.parseInt(last.claimNumber.substring("CLM-".length())) + 1;
            } catch (NumberFormatException e) {
                next = (int) (Claim.count() + 1001);
            }
        }
        return "CLM-" + next;
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
