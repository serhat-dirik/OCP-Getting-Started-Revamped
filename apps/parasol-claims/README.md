# parasol-claims

The Parasol Insurance **core claims service**: a Quarkus REST API over PostgreSQL owning the
`CLM-1001`–`CLM-1030` dataset. Nearly every module in the workshop acts on this service, so it
is the one worth reading first. Two entities and one resource class — about ten minutes.

## Endpoints

| Method + path | Purpose |
|---|---|
| `GET /` | Service landing page (JSON). Never touches the database, so it works as a probe target and as a site marker — see [Running without a database](#running-without-a-database) |
| `GET /api/claims` | List claims (`?page=`, `?size=`); returns an `X-Total-Count` header |
| `GET /api/claims/{claimNumber}` | One claim, or 404 |
| `GET /api/claims/{claimNumber}/history` | A claim's audit timeline — **deliberately inefficient**, see [Intentional flaws](#intentional-flaws--do-not-fix) |
| `POST /api/claims` | Create a claim (the server assigns the number) |
| `PUT /api/claims/{claimNumber}/status` | Advance a claim's workflow status |
| `GET /q/health/live` · `/q/health/ready` | Liveness / readiness probes |
| `GET /q/metrics` | Prometheus metrics, including `claims_created_total` |

The 30 seeded claims and their event timelines are deterministic, so lab text can quote exact
values.

### Request bodies

The two write endpoints are the only place field names matter. Unknown properties are silently
**ignored**, so a misspelled field behaves exactly like a missing one:

```jsonc
// POST /api/claims
{
  "claimant":     "Alice Nguyen",   // required, non-blank
  "type":         "auto",           // required: auto | home | life
  "amount":       1234.56,          // optional, defaults to 0
  "incidentDate": "2026-07-01",     // optional, defaults to today
  "adjuster":     "Rebecca Torres"  // optional, defaults to "Unassigned"
}

// PUT /api/claims/{claimNumber}/status
{ "status": "Approved" }            // required: Submitted | UnderReview | Approved | Denied
```

Every rejection is a **400** naming the one field it rejected and listing the accepted values —
never a 500.

## Claim numbering

`POST /api/claims` assigns the number from the **`claim_number_seq` database sequence**. Where
numbering starts depends on what the database already holds, and both answers are contractual:

| Database the app boots against | First created claim | Who runs that way |
|---|---|---|
| The 30 deterministic seeds | `CLM-1031` | Every module on the shipped `drop-and-create` config |
| Empty | `CLM-1001` | *Storage & Stateful Apps* (nothing seeded) |

**This must stay a sequence.** `nextval` is atomic, so two concurrent requests — and, more
importantly, two concurrent **replicas** — can never receive the same number. Several modules
run this service at two or three replicas, which makes any "read the highest number and add one"
scheme wrong by construction: both pods read the same maximum and both try to insert it.

Two consequences worth knowing before tidying this up:

- **Gaps are normal.** Sequence values are not rolled back, so a rejected create burns a number.
  That is the right trade for a primary key.
- **Numbers are never reused** while a database lives. Deleting a claim does not free its number.
  A `drop-and-create` boot resets data and counter together, which is what keeps `CLM-1031`
  deterministic.

### Two places create the sequence, and both are needed

`ClaimNumberSequence` creates it at startup and `import.sql` creates it in the seed script.
Neither is redundant:

- **`ClaimNumberSequence` guarantees it exists** under every schema-management strategy. Quarkus
  runs the seed script only under `drop-and-create`/`create`, so on the `update` and `none`
  paths `import.sql` never executes at all. It positions the sequence one past the highest
  `CLM-<integer>` already stored, ignoring values that do not parse that way — which is what
  produces both rows of the table above.
- **`import.sql` resets it** along with the data on every `drop-and-create` boot. Hibernate drops
  the tables it manages but never touches a sequence outside the entity model, so without those
  two lines a reseeded database keeps counting from wherever it had reached.

The startup path deliberately **never repositions a sequence that already exists**, and its
create-and-position is a single `create sequence if not exists … start with N`. Both properties
are about replicas: a pod booting while another is already serving must not rewind a live
sequence, and there must be no window where the sequence exists but is positioned wrongly. If
two replicas issue the `CREATE` simultaneously, `IF NOT EXISTS` is a check rather than a lock and
PostgreSQL may fail the loser — harmless, since the winner created exactly the same object, so
the initializer logs it and the pod carries on instead of crash-looping.

### Known wart — list ordering past `CLM-9999`

`GET /api/claims` sorts by claim number as a **string**, so a five-digit number sorts *before*
`CLM-1001`. Nothing errors, but the first row of the list changes once numbering passes
`CLM-9999`.

Reaching that takes roughly six hours of continuous load-generator traffic, so a normal module
run never sees it and every lab quoting `CLM-1001` as the first row stays correct. Left alone
deliberately — sorting on a cast of the numeric suffix would change the query behind the single
most-used endpoint in the workshop, which is a bigger risk than the oddity it fixes. If a
namespace has been left under load overnight, re-materialize it rather than reading the list
order as a defect.

## Running without a database

`GET /` returns a small JSON landing page, so clicking the Route in the console shows something
real. When the `SITE` environment variable is set, the body also carries a site marker:

```bash
$ SITE=A curl -s localhost:8080/
{"service":"parasol-claims","description":"...","site":"A","links":{...}}
```

The root never touches the database, so it stays a valid probe target even with the datasource
down — and the whole app can serve `/` with **no PostgreSQL at all** when both
`QUARKUS_DATASOURCE_ACTIVE=false` and `QUARKUS_HIBERNATE_ORM_ACTIVE=false` are set (the
`/api/claims` endpoints are inactive in that mode).

The database-free boot is what lets two modules ship the real image with no PostgreSQL beside
it: *AI-Assisted Development* seeds it as its diagnosis target (so the only fault in that lab is
a wrong readiness path, not a missing `parasol-db`), and *Application Modernization* deploys the
modernized service DB-inactive — both in the attendee's own lab step and in the `ws solve` end
state. The default configuration, with a datasource URL set, is unaffected.

The `SITE` marker, by contrast, has **no consumer at present**. It was written for *Resilience,
Multi-Cluster & DR*, which now runs a small inline Node responder as its per-site service rather
than this image; the only deployment in the workshop that sets `SITE` today sets it on
`parasol-notifications`, which implements the same wire contract independently. The marker and
its compact, un-prettified format stay covered by `RootResourceSiteTest`.

## Tech

- **Quarkus 3.33 LTS**, **Java 21**, JVM mode, `fast-jar` packaging.
- Extensions, each earning its place: `quarkus-rest-jackson`,
  `quarkus-hibernate-orm-panache`, `quarkus-jdbc-postgresql`, `quarkus-smallrye-health`,
  `quarkus-micrometer-registry-prometheus`, `quarkus-opentelemetry` (exporter off by default),
  `quarkus-oidc` and `quarkus-oidc-client` (tenant disabled by default — see below).
- A **CycloneDX SBOM** is emitted on every build.
- Health, metrics, tracing and externalized configuration are **on by default**. They are
  curriculum for *Config, Secrets & Multi-Environment* and *Observability, Health & Scale*, not
  optional extras.

## Security — unprotected by default

`quarkus-oidc` is on the classpath but the tenant is **disabled**, so in every module except
*Securing Apps with Keycloak* the API is anonymous and no auth server is contacted at startup.
That is deliberate: modules are independent, so none may assume another already configured
authentication.

*Securing Apps with Keycloak* turns it into a bearer-only resource server per attendee, through
environment variables (`QUARKUS_OIDC_TENANT_ENABLED`, `QUARKUS_OIDC_AUTH_SERVER_URL`, client ID
and secret) plus a `@RolesAllowed("claims-adjuster")` annotation on the guarded method.
`quarkus.oidc.roles.role-claim-path=realm_access/roles` is pre-set so the role check matches
Keycloak realm roles, and `quarkus-oidc-client` is present for that module's token exchange —
re-audiencing the user's token to `aud=fraud` before calling `parasol-fraud`.

## Supply chain

`mvn package`, and the in-cluster build, emit a CycloneDX 1.6 JSON SBOM at
`target/parasol-claims-sbom.json` describing every dependency. The *Trusted Software Supply
Chain* module signs and attests it, and attendees inspect it with `jq`.

## Local development

```bash
# Dev mode — Dev Services starts a throwaway PostgreSQL automatically:
./mvnw quarkus:dev
curl -s localhost:8080/api/claims | jq
curl -s localhost:8080/api/claims/CLM-1001/history | jq

# Package (also writes the SBOM) and run:
./mvnw -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar
```

Pointing dev mode at the in-cluster PostgreSQL — by exporting `QUARKUS_DATASOURCE_JDBC_URL`,
`_USERNAME` and `_PASSWORD` — is the *Dev Spaces & the Inner Loop* story. OIDC Dev Services are
disabled, so neither dev mode nor `./mvnw test` starts a Keycloak container.

### Tests

`./mvnw test` runs everything against in-memory H2 — no PostgreSQL, no containers.

Five of the seven test classes carry a `@TestProfile`, so the suite boots the app more than once.
That is deliberate, and three details are load-bearing:

- **Each profile that writes claims uses its own H2 database name.** An in-memory H2 stays alive
  for the whole JVM, so classes sharing a database name also share rows. The three
  `ClaimNumbering*Test` classes assert what the *first* create returns; folding any of them into
  `ClaimResourceTest` — whose sibling tests create claims in an order JUnit does not promise —
  silently destroys the assertion.
- **`ClaimNumberingMixedDataTest` is the only test exercising the startup positioning.** On the
  seeded path the seed script creates the sequence, so the computed start value is never used.
  That test's fixture creates no sequence and holds deliberately unparseable claim numbers, to
  pin that they are skipped rather than thrown on.
- **`DatabaseFreeBootTest` guards the datasource-inactive mode** described above. It is the test
  that fails if anyone adds startup work that touches the database unconditionally.

Each app restart wants a few hundred MB, so a small container VM can run the test fork out of
memory partway through. Run the classes in batches with `-Dtest=…` if that happens — it is a
memory limit, not a test failure.

## How the image is built

GitOps builds it — there is no manual step. A BuildConfig and ImageStream in
`gitops/workshop-config/templates/parasol-images-build.yaml` clone this repository and push
`parasol-claims:latest`. The `1.0` and `1.1` tags are aliases for `latest`, so every module that
pins either one resolves without a hand-run build. Which tag a module pins is a naming
convention; both track the same build.

```bash
# Rebuild after editing this app — moves latest and both aliases together:
oc start-build parasol-claims -n ogsr-parasol-images --follow
```

## Container notes

- UBI9 multi-stage build: `ubi9/openjdk-21` for the build, `ubi9/openjdk-21-runtime` at runtime.
- The recipe ships under **both** names — `Dockerfile` and the vendor-neutral `Containerfile` —
  kept byte-for-byte identical. `Dockerfile` is what `oc new-app --strategy=docker` auto-detects
  in *Ways to Build & Deliver Apps*; `Containerfile` is what the pipeline modules and the
  in-cluster build reference. **Edit one, edit both.**
- Runs as numeric non-root **USER 185** on port **8080**, with files copied `--chown=185:0` and
  group-readable, so it also runs under an arbitrary injected UID.

## Intentional flaws — do not fix

Three deliberate teaching devices: two always-on faults and one break-fix toggle that ships
green.

1. **N+1 query on `GET /api/claims/{claimNumber}/history`** — for *Observability, Health &
   Scale*. The endpoint fetches the claim's event IDs in one query, then loads each event by
   primary key in a loop: `1 + N` SELECTs, one JDBC span per event in the trace. `CLM-1001` has
   five events, so six queries. The one-line fix is that module's payoff — do **not** optimize
   it here.

2. **A seeded vulnerable dependency, on the `seed-vulnerable` branch only** — for *Trusted
   Software Supply Chain*. `main` is clean. That branch pins an older base image and a
   known-CVE `log4j-core` so the scan gate fails and the SBOM inspection finds it.

3. **A toggleable failing test, green as shipped** — for *Pipelines Fundamentals*.
   `ClaimResourceTest.approvingAClaimRequiresAnAssignedAdjuster()` encodes the Parasol rule that
   a claim cannot be approved while still unassigned, and **passes as shipped**. That module has
   attendees flip its one-line toggle in their own fork so the pipeline's test task goes red with
   a readable message, then revert it to green. Do **not** remove or "simplify" it away.
