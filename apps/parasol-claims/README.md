# parasol-claims

The Parasol Insurance **core claims service**: a Quarkus REST API over PostgreSQL
that owns the full `CLM-1001..CLM-1030` dataset. It is the star of the inner-loop,
pipeline, GitOps, supply-chain, observability, and security modules (M02-M11, M29).
Small enough to read in ten minutes: two entities, one resource class.

## Endpoints

| Method + path                          | Purpose                                                        |
|----------------------------------------|----------------------------------------------------------------|
| `GET /api/claims`                      | List claims (optional `?page=` & `?size=`); `X-Total-Count` header |
| `GET /api/claims/{claimNumber}`        | One claim by its number, or 404                                |
| `GET /api/claims/{claimNumber}/history`| A claim's audit timeline (**deliberate N+1** — see below)      |
| `POST /api/claims`                     | Create a claim (server assigns the next number)               |
| `PUT /api/claims/{claimNumber}/status` | Advance a claim's workflow status                             |
| `GET /q/health/live` · `/q/health/ready` | Liveness / readiness probes (SmallRye Health)               |
| `GET /q/metrics`                       | Prometheus metrics (Micrometer), incl. `claims_created_total` |

The 30 seeded claims (`CLM-1001..CLM-1030`) and the `claim_event` timeline are
deterministic so lab text can reference exact values.

## Tech

- **Quarkus 3.33 LTS**, pinned as `quarkus.platform.version = 3.33.2.1`.
- **Java 21**, JVM mode, `fast-jar` packaging.
- Extensions, each earning its place: `quarkus-rest-jackson`,
  `quarkus-hibernate-orm-panache`, `quarkus-jdbc-postgresql`,
  `quarkus-smallrye-health`, `quarkus-micrometer-registry-prometheus`,
  `quarkus-opentelemetry` (exporter off by default), `quarkus-oidc` +
  `quarkus-oidc-client` (tenant **disabled** by default — see Security).
- **CycloneDX SBOM** on every build (`cyclonedx-maven-plugin`) — see Supply chain.
- Health, metrics, tracing, and externalized config are **on by default** — they
  are curriculum (M04/M11), not optional extras.

## Security — unprotected by default (module independence)

`quarkus-oidc` ships on the classpath but the tenant is **disabled**
(`quarkus.oidc.tenant-enabled=false`), so for M01-M28 the API is anonymous and no
auth server is contacted at boot. **M29** turns it into a bearer-only resource
server (per user, via env: `QUARKUS_OIDC_TENANT_ENABLED=true`,
`QUARKUS_OIDC_AUTH_SERVER_URL=...`, `QUARKUS_OIDC_CLIENT_ID/_CREDENTIALS_SECRET`)
and adds `@RolesAllowed("claims-adjuster")` on the guarded method.
`quarkus.oidc.roles.role-claim-path=realm_access/roles` is pre-set so the role
check matches Keycloak realm roles. `quarkus-oidc-client` is present for the M29
RFC 8693 token exchange (re-audience the user token to `aud=fraud` before calling
`parasol-fraud`).

## Supply chain — CycloneDX SBOM (M07)

`mvn package` (and the in-cluster Containerfile build) emits a CycloneDX 1.6 JSON
SBOM at **`target/parasol-claims-sbom.json`** describing every dependency. M07's
pipeline signs and attests it (`cosign attest --type cyclonedx`) and attendees
inspect it with `jq`.

## Local development

```bash
# Live-reload dev mode (Dev Services starts a throwaway PostgreSQL automatically):
./mvnw quarkus:dev
curl -s localhost:8080/api/claims | jq
curl -s localhost:8080/api/claims/CLM-1001/history | jq

# Package (also writes target/parasol-claims-sbom.json) + run the fast-jar:
./mvnw -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar
```

Pointing dev mode at the in-cluster PostgreSQL (export
`QUARKUS_DATASOURCE_JDBC_URL/_USERNAME/_PASSWORD`) is the M03 (Dev Spaces) story.
OIDC Dev Services are disabled, so dev mode and `./mvnw test` never start a
Keycloak container.

## Building the image in-cluster

Built on the cluster (cluster-first policy). Binary build, then an immutable tag:

```bash
oc start-build parasol-claims --from-dir=apps/parasol-claims --follow -n parasol-images
oc tag parasol-images/parasol-claims:latest parasol-images/parasol-claims:1.1
```

> Image tags are immutable per release. `1.0` is the M02-era image pinned by the
> Phase-2 entry states — **never overwrite it**. Builds carrying the M07/M11/M29
> app changes are tagged `1.1`. `openshift/buildconfig.yaml` defines the
> Git-strategy `BuildConfig` (`parasol-claims-git`) for later CI rebuilds.

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` (build) →
  `ubi9/openjdk-21-runtime:1.23` (runtime).
- Runtime runs as numeric non-root **USER 185**, port **8080**; files are copied
  `--chown=185:0` and group-readable, so it runs under an arbitrary injected UID.

## Intentional flaws — do not fix

Three deliberate teaching devices (two always-on flaws plus one green-by-default
break-fix toggle):

1. **N+1 query on `GET /api/claims/{claimNumber}/history`** (for **M11**
   observability). The endpoint fetches the claim's event ids in one query, then
   loads each event by primary key in a loop — `1 + N` SELECTs, one JDBC span per
   event in the trace. `CLM-1001` has 5 events (so 6 queries). The one-line fix
   (`ClaimEvent.list("claimNumber", Sort.by("createdAt"), claimNumber)`) is the
   M11 lab payoff — do **not** optimize it here.
2. **Seeded CVE dependency — on the `seed-vulnerable` branch only** (for **M07**
   trusted supply chain). The `main` branch is clean. The `seed-vulnerable`
   branch pins an older UBI9 base tag and a known-CVE `log4j-core` so the M07 ACS
   scan gate fails and the SBOM inspection finds it; see that branch's README.
3. **Toggleable failing test — green by default** (for **M07** pipelines
   break-fix). `ClaimResourceTest.approvingAClaimRequiresAnAssignedAdjuster()`
   encodes the Parasol rule that a claim cannot be Approved while still
   `Unassigned`, and **passes as shipped**. The M07 lab has attendees flip its
   one-line toggle in their fork (`assignAdjusterBeforeApproval = true` → `false`)
   so the pipeline's `unit-test` task goes red with a readable message, then revert
   to green. Do **not** remove or "simplify" it away — it is a workshop device.
