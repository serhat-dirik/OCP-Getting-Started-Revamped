# Parasol Legacy Claims

A **deliberately legacy** Parasol Insurance claims REST service — the modernization *target* for
**M22 — Application Modernization (MTA + AI)**. Attendees run MTA 8 analysis against it, triage the
report, fix issues (with Developer Lightspeed for MTA where entitled), then containerize and deploy
the modernized service to OpenShift.

It is **Spring MVC on Tomcat / JBoss Web Server** (servlet-era WAR), **JDK 8** — an `[OCP]`-entitled
stack. It is intentionally **not** JBoss EAP/JMS (Decision D16: Tomcat/JWS, no middleware).

## Deliberate issues (what MTA should flag)

| # | Where | Anti-pattern | MTA target(s) |
|---|-------|--------------|---------------|
| 1 | `pom.xml` (`java.version 1.8`) | Pinned to Java 8 | openjdk, cloud-readiness |
| 2 | `persistence.properties` | Hardcoded database **IP address** | cloud-readiness |
| 3 | `persistence.properties` / `pom.xml` | Proprietary **Oracle** driver + `OracleDialect` | cloud-readiness |
| 4 | `persistence.properties` | **Plaintext credentials** in a versioned file | cloud-readiness |
| 5 | `persistence.properties` | Hibernate `create-drop` (data-destructive) | cloud-readiness |
| 6 | `ApplicationConfiguration.java` | Hardcoded **filesystem path** for audit log | cloud-readiness, containerization |
| 7 | `ClaimsAppInitializer.java` / `pom.xml` | Servlet-era **WAR** + `javax.servlet` | containerization |
| 8 | `Claim.java` | `javax.persistence` (pre-Jakarta) | openjdk, cloud-readiness |

## Provenance

Adapted (re-themed to Parasol claims) from the Apache-2.0 **Konveyor `customers-tomcat-legacy`**
demo used in the Red Hat Modern Application Development workshop (`rh-mad-workshop`). Structure,
the hardcoded-config anti-patterns, and the assess→analyze→refactor→deploy arc are ported; the
domain model is Parasol. Credit belongs in the module wrap-up + `CREDITS.md` (Decision D18) — a
follow-up for the M22 content builder.

## Build

```bash
mvn -B -DskipTests package   # produces target/parasol-legacy-claims.war
```

MTA analyzes the **source** (this Git repo) — you do not need to build or run it to assess it.
