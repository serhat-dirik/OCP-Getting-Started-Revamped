# parasol-fraud

A tiny Quarkus **fraud-scoring service**. It exists to be the *audience* of a token exchange in
the **Securing Apps with Keycloak** module: `parasol-claims` exchanges the caller's user token
for one scoped to `aud=parasol-fraud`, and this **bearer-only** service enforces that audience — so a
correctly down-scoped token is accepted and an attempt to escalate is refused.

```
   parasol-web ──(user token)──► parasol-claims ──(exchanged aud=parasol-fraud token)──► parasol-fraud
                                                                                          enforces aud=parasol-fraud
```

You can read it in ten minutes: one resource class, a deterministic score, no database.

## Endpoints

| Method + path | Purpose |
|---|---|
| `GET /api/fraud/score/{claimId}` | Deterministic fraud score (0–99) and risk band for a claim |
| `GET /q/health/live` | Liveness probe |
| `GET /q/health/ready` | Readiness probe |
| `GET /q/metrics` | Prometheus metrics |

The score is a pure function of the claim ID, so lab text can quote exact values:

```json
// GET /api/fraud/score/CLM-1001
{ "claimId": "CLM-1001", "score": 37, "risk": "low",  "model": "parasol-fraud-heuristic-v1" }
// GET /api/fraud/score/CLM-1005
{ "claimId": "CLM-1005", "score": 85, "risk": "high", "model": "parasol-fraud-heuristic-v1" }
```

## Security — unprotected by default

Like every Parasol app, this one ships with its OIDC tenant **disabled**
(`quarkus.oidc.tenant-enabled=false`). In every module except *Securing Apps with Keycloak* the
endpoints are anonymous and no auth server is contacted at startup.

That is deliberate: modules are independent, so no module may assume another one already
configured authentication.

### Turning protection on

The *Securing Apps with Keycloak* module makes it a real bearer-only resource server, per
attendee, through environment variables:

```properties
QUARKUS_OIDC_TENANT_ENABLED=true
QUARKUS_OIDC_AUTH_SERVER_URL=https://sso-workshop.<domain>/realms/realm-<user>
QUARKUS_OIDC_TOKEN_AUDIENCE=parasol-fraud   # accept ONLY tokens carrying aud=parasol-fraud
```

Two settings are already in `application.properties` so the module does not have to teach them:
`quarkus.oidc.application-type=service` makes it bearer-only, and
`quarkus.oidc.roles.role-claim-path=realm_access/roles` maps Keycloak realm roles, so an in-lab
`@RolesAllowed("claims-adjuster")` on `FraudResource.score` matches.

## Tech

- **Quarkus 3.33 LTS**, pinned in `pom.xml`.
- **Java 21**, JVM mode, `fast-jar` packaging.
- Minimal extensions, each earning its place: `quarkus-rest-jackson`, `quarkus-oidc` (disabled
  by default), `quarkus-smallrye-health`, `quarkus-micrometer-registry-prometheus`,
  `quarkus-opentelemetry` (exporter off).

## Local development

```bash
./mvnw quarkus:dev
curl -s localhost:8080/api/fraud/score/CLM-1001
curl -s localhost:8080/q/health/ready

# or package and run:
./mvnw -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar
```

OIDC Dev Services are disabled, so dev mode and `./mvnw test` never start a Keycloak container.
The workshop always points OIDC at its shared Keycloak instead.

## How the image is built

GitOps builds it — there is no manual step. A BuildConfig and ImageStream in
`gitops/workshop-config/templates/parasol-images-build.yaml` clone this repository and push
`parasol-fraud:latest`. The `1.0` tag is an alias for `latest`, so the modules that pin `1.0`
resolve without anyone having run a build by hand.

```bash
# Rebuild after editing this app — moves latest and the 1.0 alias together:
oc start-build parasol-fraud -n ogsr-parasol-images --follow
```

## Container notes

- UBI9 multi-stage build: `ubi9/openjdk-21` for the build, `ubi9/openjdk-21-runtime` at runtime.
- Runs as numeric non-root **USER 185** on port **8080**. Files are copied `--chown=185:0` and
  group-readable, so it also runs under an arbitrary injected UID — which is what OpenShift's
  restricted security context does.

## Intentional flaws — do not fix

None. This service is deliberately simple and correct.

The workshop's deliberate faults live elsewhere: a seeded vulnerable dependency on the
`parasol-claims` `seed-vulnerable` branch (*Trusted Software Supply Chain*), an N+1 query
endpoint on `parasol-claims` (*Observability, Health & Scale*), and the legacy patterns
throughout `parasol-legacy-claims` (*Application Modernization*).
