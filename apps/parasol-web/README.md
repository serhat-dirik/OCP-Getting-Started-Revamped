# parasol-web

The Parasol Insurance **claims-portal frontend**. A deliberately small Quarkus application
serving a landing page with a table of seeded claims. *Platform Orientation & First App* deploys
it from a prebuilt image to teach the deploy → scale → self-heal → expose loop.

```
                      ┌───────────────────────────────────────────┐
   browser ──HTTP──►  │  parasol-web (Quarkus, JVM fast-jar)      │
                      │                                           │
                      │  GET /                → index.html         │
                      │  GET /api/claims      → 5 seeded claims    │
                      │  GET /q/health/{live,ready}                │
                      │  GET /q/metrics                            │
                      └───────────────────────────────────────────┘
      No database, no backend service — the claims are seeded in-process.
```

## What it is, and what it is not

- **It is** a self-contained black box. The landing page calls one REST endpoint that returns a
  fixed set of five claims. That is the whole application, and it reads in ten minutes.
- **It is not** the real claims service. That is `parasol-claims` — database-backed, owning
  `CLM-1001`–`CLM-1030`. Keeping this one dependency-free is exactly what lets the first module
  deploy something with nothing else running on the cluster.

## Endpoints

| Method + path | Purpose |
|---|---|
| `GET /` | The claims-portal landing page (static) |
| `GET /api/claims` | Seeded claims as JSON — five items, `CLM-1001`–`CLM-1005` |
| `GET /q/health/live` · `/q/health/ready` | Liveness / readiness probes |
| `GET /q/health` | Aggregate health |
| `GET /q/metrics` | Prometheus metrics |

The payload is deterministic, so lab text can quote exact values:

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

- **Quarkus 3.33 LTS**, **Java 21**, JVM mode, `fast-jar` packaging.
- Three extensions, each earning its place: `quarkus-rest-jackson` (the endpoint, the JSON and
  the static resources), `quarkus-smallrye-health`, `quarkus-micrometer-registry-prometheus`.
- Health, metrics and externalized configuration are **on by default** — several modules teach by
  inspecting them, so they are curriculum rather than optional extras.

## Local development

```bash
./mvnw quarkus:dev                       # live reload; Dev UI at /q/dev/

# or package and run:
./mvnw -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar

curl -s localhost:8080/api/claims | jq
curl -s localhost:8080/q/health/ready
open http://localhost:8080/
```

This app has no external dependencies, so dev mode runs standalone. Running dev mode against
in-cluster services is the *Dev Spaces & the Inner Loop* story instead.

## How the image is built

GitOps builds it — there is no manual step. A BuildConfig and ImageStream in
`gitops/workshop-config/templates/parasol-images-build.yaml` clone this repository and push
`parasol-web:latest`. The `1.0` and `1.1` tags are aliases for `latest`, so every module that
pins either one resolves the image without a hand-run build.

```bash
# Rebuild after editing this app — moves latest and both aliases together:
oc start-build parasol-web -n ogsr-parasol-images --follow
```

The image the first module deploys:

```
image-registry.openshift-image-registry.svc:5000/ogsr-parasol-images/parasol-web:1.0
```

Attendees can pull it because of the `workshop-image-pullers` RoleBinding in
`gitops/workshop-config/templates/parasol-images-pull.yaml`, granted to every per-user
namespace's ServiceAccount group and to the `workshop-attendees` group, scoped to the
`ogsr-parasol-images` namespace.

## Container notes

- UBI9 multi-stage build: `ubi9/openjdk-21` for the build, `ubi9/openjdk-21-runtime` at runtime.
- Runs as numeric non-root **USER 185** on port **8080**.
- Files are copied `--chown=185:0` and group-readable, so the container runs unchanged under an
  arbitrary injected UID — which is what OpenShift's restricted security context does. Nothing is
  written outside `/tmp`.

## Intentional flaws — do not fix

None. This service is deliberately simple and correct.

The workshop's deliberate faults live elsewhere: a seeded vulnerable dependency on a
`parasol-claims` branch (*Trusted Software Supply Chain*), an N+1 query endpoint on
`parasol-claims` (*Observability, Health & Scale*), and the legacy patterns throughout
`parasol-legacy-claims` (*Application Modernization*).
