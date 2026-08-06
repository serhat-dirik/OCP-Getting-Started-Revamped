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
 *   <li><strong>Optional origin-site self-identification.</strong> When the {@code SITE}
 *       environment variable is set (e.g. {@code A} or {@code B}), the body carries a compact
 *       {@code "site":"<SITE>"} marker — the same wire contract {@code parasol-notifications}
 *       implements — so a site-aware deployment can say which instance served a request. The
 *       marker is omitted when {@code SITE} is unset, which is <em>every</em> deployment of this
 *       image in the workshop today: nothing under {@code gitops/} or in any lab currently sets
 *       {@code SITE} on a parasol-claims container (enumerated 2026-08-06 over every
 *       {@code name: SITE} in the tree). It was written for resilience-multicluster-dr, which
 *       now runs an inline Node responder as its per-site service rather than this image; the
 *       only live {@code SITE} setter left is on parasol-notifications, in
 *       packaging-distributing. The compact format stays pinned by {@code RootResourceSiteTest}
 *       — see that test for why a guard without a current consumer is still worth keeping.</li>
 * </ol>
 *
 * <p><strong>Running this service without a database.</strong> Because this root never queries
 * the database, the whole app can serve {@code /} with the datasource switched off — set
 * {@code QUARKUS_DATASOURCE_ACTIVE=false} and {@code QUARKUS_HIBERNATE_ORM_ACTIVE=false} and no
 * PostgreSQL is contacted at boot (the {@code /api/claims} data endpoints are inactive in that
 * mode). Two module worlds ship the <em>real</em> image that way — neither of them the
 * resilience one: ai-assisted-development seeds it as its diagnosis target so the only fault in
 * that lab is a wrong readiness path rather than a missing {@code parasol-db}, and
 * app-modernization deploys the modernized service DB-inactive, both in the attendee's own lab
 * step and in the {@code ws solve} end state. The default configuration is unchanged: with a
 * datasource URL set, the datasource is active and the full API is served as before.
 */
@Path("/")
@Produces(MediaType.APPLICATION_JSON)
public class RootResource {

    @ConfigProperty(name = "quarkus.application.name", defaultValue = "parasol-claims")
    String appName;

    /** Set only where a deployment declares an origin site; unset on every workshop deployment today. */
    @ConfigProperty(name = "SITE")
    Optional<String> site;

    @GET
    public Map<String, Object> root() {
        // LinkedHashMap: stable, readable field order in the JSON a browser renders.
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", appName);
        body.put("description", "Parasol Insurance claims service (REST + PostgreSQL, Quarkus)");
        // Compact "site":"<SITE>" marker — present only when SITE is set, which no workshop
        // deployment does today, so every current landing is the clean single-site one.
        site.filter(value -> !value.isBlank()).ifPresent(value -> body.put("site", value));
        body.put("links", Map.of(
                "claims", "/api/claims",
                "health", "/q/health",
                "metrics", "/q/metrics"));
        return body;
    }
}
