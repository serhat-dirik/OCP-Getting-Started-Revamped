package com.parasol.service;

import java.util.Map;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * Starter endpoint for a scaffolded Parasol service.
 *
 * <pre>
 *   GET /api/info   -> { "service": "&lt;app name&gt;", "status": "ready" }
 * </pre>
 *
 * Replace this with your service's real API. Health (/q/health/*) and metrics
 * (/q/metrics) are already wired on by the golden-path template.
 */
@Path("/api/info")
@Produces(MediaType.APPLICATION_JSON)
public class InfoResource {

    @ConfigProperty(name = "quarkus.application.name")
    String appName;

    @GET
    public Map<String, String> info() {
        return Map.of("service", appName, "status", "ready");
    }
}
