# parasol-web

The Parasol Insurance **claims-portal web frontend**. A deliberately small
Quarkus application that serves a clean landing page with a summary table of
seeded insurance claims. Module **M01 (Platform Orientation & First App)** deploys
it as a prebuilt image to teach the deploy → scale → self-heal → expose loop.

```
                      ┌──────────────────────────────────────────┐
   browser ──HTTP──►  │  parasol-web (Quarkus, JVM fast-jar)      │
                      │                                          │
                      │  GET /                → index.html (static)│
                      │  GET /api/claims      → 5 seeded claims    │
                      │  GET /q/health/{live,ready}  (SmallRye)    │
                      │  GET /q/metrics       (Micrometer/Prom)    │
                      └──────────────────────────────────────────┘
      No database, no backend service — the claims are seeded in-process.
```

> Architecture SVG and a quickstart screenshot are added with the M01 content
> wave (media is produced during module build per style-guide §4).

## What it is (and isn't)

- **Is:** a self-contained black box. The landing page (`index.html` + CSS + JS)
  calls one REST endpoint that returns a fixed set of five claims. That is the
  whole app. You can read it in ten minutes.
- **Isn't:** the real claims service. The stateful, database-backed
  `parasol-claims` service (CLM-1001..CLM-1030) arrives in M02 and later. Keeping
  `parasol-web` dependency-free is what lets M01 deploy it with nothing else running.

## Endpoints

| Method + path        | Purpose                                                        |
|----------------------|----------------------------------------------------------------|
| `GET /`              | Claims-portal landing page (static, from `META-INF/resources`) |
| `GET /api/claims`    | Seeded claims as JSON — 5 items, `CLM-1001`..`CLM-1005`         |
| `GET /q/health/live` | Liveness probe (SmallRye Health)                               |
| `GET /q/health/ready`| Readiness probe (SmallRye Health)                              |
| `GET /q/health`      | Aggregate health                                               |
| `GET /q/metrics`     | Prometheus metrics (Micrometer)                                |

The seeded `GET /api/claims` payload is deterministic so lab text can reference
exact values:

```json
[
  { "id": "CLM-1001", "policyholder": "Alice Nguyen",  "type": "Auto",     "status": "Under Review", "amount": 4200.0,  "filedDate": "2026-05-14" },
  { "id": "CLM-1002", "policyholder": "Marcus Feld",   "type": "Home",     "status": "Approved",     "amount": 12850.0, "filedDate": "2026-05-09" },
  { "id": "CLM-1003", "policyholder": "Priya Raman",   "type": "Auto",     "status": "Open",         "amount": 1975.5,  "filedDate": "2026-06-01" },
  { "id": "CLM-1004", "policyholder": "Tom Becker",    "type": "Property", "status": "Denied",       "amount": 8400.0,  "filedDate": "2026-04-22" },
  { "id": "CLM-1005", "policyholder": "Sofia Alvarez", "type": "Home",     "status": "Closed",       "amount": 3120.75, "filedDate": "2026-03-30" }
]
```

## Tech

- **Quarkus 3.33 LTS** (current long-term-support stream; recommended for
  production, maintained until 2027-03-25). Pinned in `pom.xml` as
  `quarkus.platform.version = 3.33.2.1`.
- **Java 21**, JVM mode, `fast-jar` packaging.
- Minimal extensions — each one earns its place:
  - `quarkus-rest-jackson` — the REST endpoint + JSON, and hosts static resources.
  - `quarkus-smallrye-health` — `/q/health/live` and `/q/health/ready`.
  - `quarkus-micrometer-registry-prometheus` — `/q/metrics`.
- Health, metrics, and externalized config are **on by default** — they are
  workshop curriculum (M01, M04, M11), not optional extras.

## Local development

```bash
# Live-reload dev mode (Dev UI at http://localhost:8080/q/dev/):
mvn quarkus:dev
#   ... or with the bundled wrapper:
./mvnw quarkus:dev

# Package the fast-jar and run it:
mvn -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar

# Then:
curl -s localhost:8080/api/claims | jq
curl -s localhost:8080/q/health/ready
open http://localhost:8080/
```

`mvn quarkus:dev` against in-cluster services is the M03 (Dev Spaces) story;
this app has no external dependencies, so dev mode runs standalone.

## Building the image in-cluster

`parasol-web` is built on the cluster (cluster-first policy — no laptop image
builds). Two supported paths:

### Binary build (used for the initial M01 image)

Source is streamed straight from this directory — no Git checkout needed:

```bash
oc new-build --strategy=docker --binary --name=parasol-web -n parasol-images
oc start-build parasol-web --from-dir=apps/parasol-web --follow -n parasol-images
oc tag parasol-images/parasol-web:latest parasol-images/parasol-web:1.0
```

### Git BuildConfig (for later CI-driven rebuilds)

`openshift/buildconfig.yaml` defines a Docker-strategy `BuildConfig`
(`parasol-web-git`) that builds from the public repo, `contextDir apps/parasol-web`.
It is **not** applied during M01 (the code must be committed and pushed first);
apply it once the repo is published to enable rebuilds from Git.

### Image reference M01 deploys

```
image-registry.openshift-image-registry.svc:5000/parasol-images/parasol-web:1.0
```

Workshop attendees pull it via the `system:image-puller` RoleBinding in
`openshift/image-puller-rb.yaml` (granted to group `workshop-attendees`,
scoped to the `parasol-images` namespace).

## Container notes (OpenShift restricted-v2)

- UBI9 multi-stage `Containerfile`: `ubi9/openjdk-21:1.23` (build) →
  `ubi9/openjdk-21-runtime:1.23` (runtime).
- Runtime runs as numeric non-root **USER 185**, port **8080**.
- Files are copied `--chown=185:0` and group-readable, so the container runs
  unchanged under an arbitrary injected UID (GID 0). Nothing is written outside
  `/tmp`.

## Intentional flaws — do not fix

None. `parasol-web` is intentionally simple and correct; the deliberate
teachable flaws in this workshop live in other services (e.g. a seeded CVE
dependency for M07, an N+1 endpoint for M11, and the legacy anti-patterns in
`parasol-legacy-claims` for M21).
