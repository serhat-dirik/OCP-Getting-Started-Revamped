package com.parasol.claims.legacy.config;

import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.util.Properties;

/*
 * Loads persistence.properties from the classpath. Two deliberate legacy anti-patterns MTA flags:
 *
 *  1. AUDIT_LOG_PATH — a HARDCODED absolute host filesystem path. On OpenShift the container
 *     filesystem is ephemeral + read-only-by-default and pods run as a random non-root UID, so a
 *     hardcoded /opt/... write path breaks (cloud-readiness: "file system" + statelessness).
 *  2. System.out.println for audit logging instead of a real logging framework.
 */
public class ApplicationConfiguration {

    // ISSUE (MTA cloud-readiness / file system): hardcoded host path — not writable in a container.
    private static final String AUDIT_LOG_PATH = "/opt/parasol/logs/claims-audit.log";

    private final Properties properties = new Properties();

    public ApplicationConfiguration() {
        try (InputStream in = getClass().getClassLoader().getResourceAsStream("persistence.properties")) {
            if (in != null) {
                properties.load(in);
            }
        } catch (IOException e) {
            // ISSUE (MTA): swallowed exception + console logging, no observability.
            System.out.println("Could not load persistence.properties: " + e.getMessage());
        }
    }

    public String getProperty(String key) {
        return properties.getProperty(key);
    }

    /*
     * Writes an audit line to the hardcoded filesystem path — a portability blocker for containers.
     */
    public void audit(String message) {
        try (FileWriter w = new FileWriter(AUDIT_LOG_PATH, true)) {
            w.write(message + System.lineSeparator());
        } catch (IOException e) {
            System.out.println("Audit write failed to " + AUDIT_LOG_PATH + ": " + e.getMessage());
        }
    }
}
