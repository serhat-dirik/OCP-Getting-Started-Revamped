# parasol-fraud

A tiny Quarkus **fraud-scoring service**. It exists to be the *audience* of a
token exchange in module **M29 (Securing Apps with Keycloak)**: `parasol-claims`
exchanges the caller's user token for a token scoped to `aud=fraud`, and this
**bearer-only** service enforces that audience — so a down-scoped token is
accepted and an attempt to escalate is rejected.

```
   parasol-web ──(user token)──► parasol-claims ──(exchanged aud=fraud token)──► parasol-fraud
                                                                                  enforces aud=fraud
```

You can read it in ten minutes: one resource class, a deterministic score, no
database.

## Endpoints

| Method + path                    | Purpose                                                    |
|----------------------------------|------------------------------------------------------------|
| `GET /api/fraud/score/{claimId}` | Deterministic fraud score (0-99) + risk band for a claim   |
| `GET /q/health/live`             | Liveness probe (SmallRye Health)                           |
| `GET /q/health/ready`            | Readiness probe (SmallRye Health)                          |
| `GET /q/metrics`                 | Prometheus metrics (Micrometer)                            |

The score is a pure function of the claim id, so lab text can reference exact
values:

```json
// GET /api/fraud/score/CLM-1001
{ "claimId": "CLM-1001", "score": 37, "risk": "low",  "model": "parasol-fraud-heuristic-v1" }
// GET /api/fraud/score/CLM-1005
{ "claimId": "CLM-1005", "score": 85, "risk": "high", "model": "parasol-fraud-heuristic-v1" }
```

## Security — unprotected by default (module independence)

Like every Parasol app, `parasol-fraud` ships with its OIDC tenant **disabled**
(`quarkus.oidc.tenant-enabled=false`), so for M01-M28 the endpoints are anonymous
and no auth server is contacted at boot.

### Enabling protection (M29)

M29 turns the service into a real bearer-only resource server, per user, via env
and one code edit:

```properties
# env on the Deployment (M29 entry state):
QUARKUS_OIDC_TENANT_ENABLED=true
QUARKUS_OIDC_AUTH_SERVER_URL=https://sso-workshop.<domain>/realms/realm-<user>
QUARKUS_OIDC_TOKEN_AUDIENCE=fraud        # accept ONLY tokens carrying aud=fraud
```

`quarkus.oidc.application-type=service` (already set) makes it bearer-only, and
`quarkus.oidc.roles.role-claim-path=realm_access/roles` (already set) maps
Keycloak realm roles so an in-lab `@RolesAllowed("claims-adjuster")` on
`FraudResource.score` matches. See `application.properties` for the staged config.

## Tech

- **Quarkus 3.33 LTS**, pinned in `pom.xml` as `quarkus.platform.version = 3.33.2.1`.
- **Java 21**, JVM mode, `fast-jar` packaging.
- Minimal extensions — each earns its place: `quarkus-rest-jackson` (the endpoint),
  `quarkus-oidc` (bearer-only auth, disabled by default), `quarkus-smallrye-health`,
  `quarkus-micrometer-registry-prometheus`, `quarkus-opentelemetry` (exporter off).

## Local development

```bash
# Live-reload dev mode:
./mvnw quarkus:dev
curl -s localhost:8080/api/fraud/score/CLM-1001   # {"claimId":"CLM-1001","score":37,"risk":"low",...}
curl -s localhost:8080/q/health/ready

# Package + run the fast-jar:
./mvnw -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar
```

OIDC Dev Services are disabled, so dev mode and `./mvnw test` never try to start a
Keycloak container — the workshop always points OIDC at the shared rhbk (M29).

## Building the image in-cluster

Built on the cluster (cluster-first policy). Binary build for the initial image:

```bash
oc new-build --strategy=docker --binary --name=parasol-fraud -n ogsr-parasol-images
oc start-build parasol-fraud --from-dir=apps/parasol-fraud --follow -n ogsr-parasol-images
oc tag ogsr-parasol-images/parasol-fraud:latest ogsr-parasol-images/parasol-fraud:1.0
```

`openshift/buildconfig.yaml` defines the Git-strategy `BuildConfig`
(`parasol-fraud-git`) for later CI-driven rebuilds (`contextDir apps/parasol-fraud`).

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` (build) →
  `ubi9/openjdk-21-runtime:1.23` (runtime).
- Runtime runs as numeric non-root **USER 185**, port **8080**; files are copied
  `--chown=185:0` and group-readable, so it runs under an arbitrary injected UID.

## Intentional flaws — do not fix

None. `parasol-fraud` is intentionally simple and correct. The deliberate
teachable flaws in this workshop live in other services (a seeded CVE dependency
on the `parasol-claims` `seed-vulnerable` branch for M07, the N+1 endpoint on
`parasol-claims` for M11, and the legacy anti-patterns in `parasol-legacy-claims`
for M21).
