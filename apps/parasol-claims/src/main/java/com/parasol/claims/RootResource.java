package com.parasol.claims;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * Landing endpoint at the service root ({@code GET /}).
 *
 * <p>Two jobs, both deliberately tiny and database-free:
 *
 * <ol>
 *   <li><strong>A meaningful, browseable root.</strong> Clicking the Route in the
 *       OpenShift console lands here and gets a real answer — what this service is
 *       and where its API and health/metrics live — instead of a bare 404. Never
 *       touches the datasource, so it stays a valid liveness/readiness target even
 *       when the database is down or (see below) switched off entirely.</li>
 *   <li><strong>Site self-identification for cross-site failover (curriculum: M21).</strong>
 *       When the {@code SITE} environment variable is set (e.g. {@code A} or {@code B}),
 *       the body carries a compact {@code "site":"<SITE>"} marker. M21's failover client
 *       hits this root once a second and greps the body for that marker to log which
 *       site served each request; the readiness/liveness probes hit this same {@code /}.
 *       The marker is omitted for the normal single-site modules (M02–M20) where
 *       {@code SITE} is unset.</li>
 * </ol>
 *
 * <p><strong>Running this service without a database (M21 drop-in).</strong> Because
 * this root never queries the database, the whole app can serve {@code /} with the
 * datasource switched off — set {@code QUARKUS_DATASOURCE_ACTIVE=false} and
 * {@code QUARKUS_HIBERNATE_ORM_ACTIVE=false} and no PostgreSQL is contacted at boot.
 * That lets M21 run the <em>real</em> {@code parasol-claims} image as its per-site
 * responder (the {@code /api/claims} data endpoints are inactive in that mode, which
 * M21 does not use). The default configuration is unchanged: with a datasource URL
 * set, the datasource is active and the full API is served as before.
 */
@Path("/")
@Produces(MediaType.APPLICATION_JSON)
public class RootResource {

    @ConfigProperty(name = "quarkus.application.name", defaultValue = "parasol-claims")
    String appName;

    /** Set only where a deployment declares an origin site (M21 failover); absent otherwise. */
    @ConfigProperty(name = "SITE")
    Optional<String> site;

    @GET
    public Map<String, Object> root() {
        // LinkedHashMap: stable, readable field order in the JSON a browser renders.
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", appName);
        body.put("description", "Parasol Insurance claims service (REST + PostgreSQL, Quarkus)");
        // Compact "site":"<SITE>" marker for the M21 cross-site failover client — present
        // only when SITE is set, so single-site modules get a clean, marker-free landing.
        site.filter(value -> !value.isBlank()).ifPresent(value -> body.put("site", value));
        body.put("links", Map.of(
                "claims", "/api/claims",
                "health", "/q/health",
                "metrics", "/q/metrics"));
        return body;
    }
}
