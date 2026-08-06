package com.parasol.fraud;

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
     */
    static int scoreFor(String claimId) {
        long basis;
        String digits = claimId.replaceAll("\\D", "");
        if (!digits.isEmpty()) {
            basis = Long.parseLong(digits);
        } else {
            basis = Integer.toUnsignedLong(claimId.hashCode());
        }
        return (int) ((basis * 37) % 100);
    }

    /** Map a score to a low/medium/high risk band. */
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
