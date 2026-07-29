# parasol-claims

The Parasol Insurance **core claims service**: a Quarkus REST API over PostgreSQL
that owns the full `CLM-1001..CLM-1030` dataset. It is the star of the inner-loop,
pipeline, GitOps, supply-chain, observability, and security modules (M02-M11, M29).
Small enough to read in ten minutes: two entities, one resource class.

## Endpoints

| Method + path                          | Purpose                                                        |
|----------------------------------------|----------------------------------------------------------------|
| `GET /`                                | Service landing (JSON: what this is + links to API/health); carries a compact `"site":"<SITE>"` marker when `SITE` is set. Database-free, so it doubles as a probe target |
| `GET /api/claims`                      | List claims (optional `?page=` & `?size=`); `X-Total-Count` header |
| `GET /api/claims/{claimNumber}`        | One claim by its number, or 404                                |
| `GET /api/claims/{claimNumber}/history`| A claim's audit timeline (**deliberate N+1** — see below)      |
| `POST /api/claims`                     | Create a claim (server assigns the next number)               |
| `PUT /api/claims/{claimNumber}/status` | Advance a claim's workflow status                             |
| `GET /q/health/live` · `/q/health/ready` | Liveness / readiness probes (SmallRye Health)               |
| `GET /q/metrics`                       | Prometheus metrics (Micrometer), incl. `claims_created_total` |

The 30 seeded claims (`CLM-1001..CLM-1030`) and the `claim_event` timeline are
deterministic so lab text can reference exact values.

### Request bodies

The two write endpoints are the only place field names matter, and unknown properties are
**ignored** (Quarkus/Jackson default), so a misspelled field looks exactly like a missing one.
Spelling these out here because until 2026-07-29 they appeared nowhere but the lab's own JSON:

```jsonc
// POST /api/claims
{
  "claimant":     "Alice Nguyen",   // required, non-blank
  "type":         "auto",           // required, one of: auto | home | life
  "amount":       1234.56,          // optional, defaults to 0
  "incidentDate": "2026-07-01",     // optional, defaults to today
  "adjuster":     "Rebecca Torres"  // optional, defaults to "Unassigned"
}

// PUT /api/claims/{claimNumber}/status
{ "status": "Approved" }            // required, one of: Submitted | UnderReview | Approved | Denied
```

Every rejection is a **400** naming the single field it rejected and listing the accepted
values — never a 500. (It used to be a 500: the guard called `contains()` on a `Set.of`, which
throws on a null argument instead of returning false, so omitting `type` blew the validation up
inside its own condition. Regression tests: `ClaimResourceTest#createWithoutTypeReturns400…`
and siblings.)

## Claim numbering

`POST /api/claims` assigns the number itself, from the **`claim_number_seq` database
sequence**. Where the numbering starts depends on what the database already holds, and both
answers are contractual:

| Database the app boots against | First created claim | Who runs that way |
|--------------------------------|---------------------|-------------------|
| The 30 deterministic seeds     | `CLM-1031`          | every module on the shipped `drop-and-create` config |
| Empty                          | `CLM-1001`          | `storage-stateful` (`…STRATEGY=update`, nothing seeded) |

This **must** stay a sequence. `nextval` is atomic, so two concurrent requests — and,
crucially, two concurrent **replicas** — can never be handed the same number. Several
modules run this service at more than one replica (M11's HPA scales it to `min=2`, others
run it at 3), which makes any "read the highest number, add one" scheme wrong by
construction: both pods read the same maximum and both try to insert it.

Two consequences worth knowing before tidying this up:

- **Gaps are normal.** Sequence values are not rolled back, so a rejected or failed create
  burns a number. That is the correct trade for a primary key.
- **Numbers are never reused** while a database lives. Deleting a claim does not free its
  number. (A `drop-and-create` boot resets the whole database, data and counter together —
  that is what keeps `CLM-1031` deterministic.)

### Two places create the sequence, and both are needed

`ClaimNumberSequence` creates it on `StartupEvent`, `import.sql` creates it in the seed
script, and neither is redundant:

- **`ClaimNumberSequence` guarantees it EXISTS**, under every schema-management strategy.
  Quarkus runs `sql-load-script` only under `drop-and-create`/`create`, so on the `update`
  and `none` paths `import.sql` never executes. It creates the sequence positioned one past
  the highest `CLM-<integer>` already stored (values that do not parse that way are ignored),
  which is what produces both rows of the table above.
- **`import.sql` RESETS it**, together with the data, on every `drop-and-create` boot.
  Hibernate drops the tables it manages and never touches a sequence that is not in the
  entity model, so without those two lines a reseeded database keeps counting from wherever
  it was. Measured: sequence pushed to 5000, app rebooted — with the lines, the reseeded
  database hands out `CLM-1031`; without them, `CLM-5001`.

The startup path deliberately **never repositions a sequence that already exists**, and its
create-and-position is a *single* `create sequence if not exists … start with N` statement.
Both properties are about replicas: a pod booting while another is already serving must not
be able to rewind a live sequence (that would re-issue numbers that are already committed
rows), and there must be no window where the sequence exists but is positioned wrongly. If
two replicas issue the `CREATE` in the same instant, `IF NOT EXISTS` is a check rather than a
lock and PostgreSQL may fail the loser — harmless, since the winner created exactly the same
object, so the initializer logs it and the pod carries on rather than crash-looping.

> **Fixed 2026-07-28.** This was previously `max(claim_number) + 1` computed in
> application code via `order by claimNumber desc` — a *string* sort. It worked while every
> number had four digits, then broke permanently: once `CLM-10000` exists, `CLM-9999` still
> sorts highest (`'9' > '1'` at the fifth character), so every later create recomputed
> `10000` and died on the primary key. Measured in `user1-dev`: 8970 creates succeeded, then
> **every** create after that returned 500. `ClaimResourceTest` now pins both the
> four-to-five-digit boundary crossing and the concurrent-create case.
>
> **Followed up 2026-07-29.** That fix put the sequence *only* in `import.sql`, which meant it
> did not exist on the `update`/`none` paths — every `POST /api/claims` on `storage-stateful`
> would have returned 500 (`sequence claim_number_seq does not exist`) from the next image
> build onward, killing three of that module's exercises. Hence `ClaimNumberSequence` and the
> two numbering tests (`ClaimNumberingEmptyDbTest`, `ClaimNumberingSeededDbTest`).

### Known wart — list ordering past `CLM-9999`

`GET /api/claims` sorts by claim number as a **string**, so a five-digit number sorts
*before* `CLM-1001`. Nothing errors, but the first row of the list changes once numbering
passes `CLM-9999`. Reaching that takes roughly six hours of continuous load-generator
traffic, so a normal module run against a freshly materialized entry state never sees it,
and every lab that quotes `CLM-1001` as the first row stays correct. Left alone
deliberately: sorting on a cast of the numeric suffix would change the query behind the
single most-used endpoint in the workshop — a bigger risk than the cosmetic oddity it
fixes. If a namespace has been left under load overnight, re-materialize it (`ws start`)
rather than reading the list order as a defect.

## Site awareness & the M21 cross-site drop-in

`GET /` returns a small JSON landing so clicking the Route in the console shows
something real. When the `SITE` env var is set, the body also carries a **compact**
`"site":"<SITE>"` marker:

```bash
$ SITE=A curl -s localhost:8080/
{"service":"parasol-claims","description":"...","site":"A","links":{...}}
```

The root **never touches the database**, so it stays a valid liveness/readiness
target even with the datasource down, and the whole app can serve `/` **without a
PostgreSQL** when both `QUARKUS_DATASOURCE_ACTIVE=false` and
`QUARKUS_HIBERNATE_ORM_ACTIVE=false` are set (the `/api/claims` data endpoints are
inactive in that mode). That combination — a self-identifying site marker plus a
DB-free boot — lets **M21** run the *real* `parasol-claims` image as its per-site
failover responder. Its client greps this root once a second for `"site":"A"` vs
`"site":"B"`; `quarkus.shutdown.timeout=2S` keeps a scaled-to-zero pod dying crisply
so failover is quick. The default configuration (datasource URL set) is unchanged.

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

### Tests

`./mvnw test` — everything runs against in-memory H2, no PostgreSQL and no containers.
Five of the seven test classes carry a `@TestProfile`, so the suite boots the app more than
once; that is deliberate, and three details are load-bearing:

- **Each profile that writes claims uses its own H2 database name.** `DB_CLOSE_DELAY=-1`
  keeps an in-memory H2 alive for the whole JVM, so classes sharing `mem:claims` also share
  rows. The three `ClaimNumbering*Test` classes assert what the *first* create returns;
  folding any of them back into `ClaimResourceTest` (whose sibling tests create claims in an
  order JUnit does not promise) silently destroys the assertion.
- **`ClaimNumberingMixedDataTest` is the only test that exercises the startup positioning.**
  On the seeded path `import.sql` creates the sequence, so the computed start value is never
  used; that test's fixture creates no sequence, and holds deliberately unparseable claim
  numbers to pin that they are skipped rather than thrown on.
- **`DatabaseFreeBootTest` guards the datasource-inactive mode**, which is the mode M21 and
  the modernization modules run this image in. It is the test that fails if anyone adds
  startup work that touches the database unconditionally.

Each app restart wants a few hundred MB — a small container VM can OOM the surefire fork
partway through. Run the classes in batches (`-Dtest=…`) if that happens locally; it is a
memory limit, not a test failure.

## Building the image in-cluster

Built declaratively by GitOps, not a manual step: the `parasol-claims` BuildConfig +
ImageStream in `gitops/workshop-config/templates/parasol-images-build.yaml` (Argo CD
`workshop-config` Application) clones this repo and pushes `parasol-claims:latest`;
`1.0` and `1.1` are declared ImageStream tags aliasing `latest`, so every entry state
that pins either tag resolves without anyone having run a build by hand.

```bash
# Manual rebuild (e.g. after editing this app) — moves latest AND both aliases together:
oc start-build parasol-claims -n ogsr-parasol-images --follow
```

> Historically `1.0` and `1.1` were two hand-tagged, genuinely different binary
> builds (`1.0` frozen at the M02-era image, `1.1` carrying the later M07/M11/M29
> changes) — see git history before 2026-07-18 for the old manual recipe. The
> declarative build keeps `1.0`/`1.1` as a **naming** convention (which entry
> states pin which tag) rather than a content split: both aliases now track the
> same `latest` build (see the template's header comment for the full tradeoff).

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage build: `ubi9/openjdk-21:1.23` (build) →
  `ubi9/openjdk-21-runtime:1.23` (runtime).
- The repo ships the recipe under **both** names — `Dockerfile` and the
  vendor-neutral `Containerfile` — kept byte-for-byte identical. `Dockerfile`
  lets `oc new-app --strategy=docker <repo>` auto-detect it (M02 exercise 2);
  `Containerfile` is what the M07/M08 pipelines and the `ogsr-parasol-images` binary
  build reference. Edit one, edit both.
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
