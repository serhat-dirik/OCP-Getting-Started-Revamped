package com.parasol.fraud;

import java.math.BigInteger;
import java.util.Map;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * Fraud-scoring surface for Parasol claims.
 *
 * <pre>
 *   GET /api/fraud/score/{claimId}   deterministic fraud score + risk band for a claim
 * </pre>
 *
 * <p>The score is a pure function of the claim id, so lab text can reference exact
 * values (e.g. {@code CLM-1001} always scores 37 / low). There is no model and no
 * database — this service exists to be the <em>audience</em> of a token exchange in the
 * securing-apps-keycloak module: parasol-claims exchanges the caller's user token for a
 * token scoped to {@code aud=parasol-fraud} (this service's Keycloak client id), and
 * this bearer-only service enforces that audience.
 *
 * <p>Security: the OIDC tenant is DISABLED by default (see application.properties), so
 * every endpoint is anonymous in every other module and this class carries no security
 * annotation. securing-apps-keycloak turns the tenant on and adds {@code aud} enforcement
 * + a role check (the in-lab edit) — see the README "Turning protection on".
 */
@Path("/api/fraud")
@Produces(MediaType.APPLICATION_JSON)
public class FraudResource {

    /** Spreads adjacent claim numbers across the bands — coprime with 100, so no score is unreachable. */
    private static final BigInteger MULTIPLIER = BigInteger.valueOf(37);

    /** Scores are published as two digits, so the score space is exactly [0,99]. */
    private static final BigInteger SCORE_MODULUS = BigInteger.valueOf(100);

    /**
     * Score a claim. Returns a deterministic pseudo-score in [0,99] and a risk band,
     * derived only from the claim id so results are stable and reproducible.
     *
     * <p>Note for securing-apps-keycloak: when the tenant is enabled this is the
     * audience-guarded call. To require a caller role as well, add
     * {@code @RolesAllowed("claims-adjuster")} here (works once
     * {@code quarkus.oidc.roles.role-claim-path=realm_access/roles} is set).
     */
    @GET
    @Path("/score/{claimId}")
    public Response score(@PathParam("claimId") String claimId) {
        if (claimId == null || claimId.isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "claimId is required")).build();
        }
        int score = scoreFor(claimId);
        return Response.ok(Map.of(
                "claimId", claimId,
                "score", score,
                "risk", riskBand(score),
                "model", "parasol-fraud-heuristic-v1")).build();
    }

    /**
     * Deterministic score in [0,99]. Uses the digits of the claim id when present
     * (so CLM-1001 -&gt; 1001 -&gt; 37), else a stable hash of the whole string. No
     * randomness, no clock — the same id always yields the same score.
     *
     * <p>The claim id is caller-controlled path input of unbounded length, so the digits are
     * reduced with {@link BigInteger} rather than parsed into a {@code long}. Same judgement
     * that makes claim amounts {@code BigDecimal} in parasol-claims: when a domain value can
     * outgrow a primitive, use exact arithmetic instead of hoping it will not. The {@code long}
     * version this replaces overflowed to a <em>negative</em> score, which {@link #riskBand}
     * then published as "low", and threw NumberFormatException — HTTP 500 — on a 20-digit id.
     *
     * <p>{@link BigInteger#mod} is the load-bearing call: unlike {@code %} it is never negative,
     * so [0,99] holds by construction. {@code Math.floorMod} is <em>not</em> an equivalent fix —
     * it would return an in-range but wrong number for an overflowed product, hiding the bug
     * instead of removing it. Both failure modes are pinned by tests in {@code FraudResourceTest};
     * the README has the full account.
     */
    static int scoreFor(String claimId) {
        String digits = claimId.replaceAll("\\D", "");
        BigInteger basis = digits.isEmpty()
                ? BigInteger.valueOf(Integer.toUnsignedLong(claimId.hashCode()))
                : new BigInteger(digits);
        return basis.multiply(MULTIPLIER).mod(SCORE_MODULUS).intValueExact();
    }

    /**
     * Map a score to a low/medium/high risk band.
     *
     * <p>Deliberately open at the bottom: it trusts {@link #scoreFor} to have already
     * guaranteed [0,99]. That trust is why the old overflow was invisible — an out-of-range
     * score fell through {@code score < 40} and was published as "low" instead of failing
     * loudly. Keep the guarantee in {@code scoreFor}, where it can be enforced exactly.
     */
    static String riskBand(int score) {
        if (score < 40) {
            return "low";
        }
        if (score < 70) {
            return "medium";
        }
        return "high";
    }
}
