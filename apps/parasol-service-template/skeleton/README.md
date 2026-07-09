# ${{ values.name }}

A Parasol Insurance service scaffolded from the **golden-path template** — a
minimal Quarkus 3.33 / Java 21 service that already has the paved-road wiring:
health probes, Prometheus metrics, OpenTelemetry tracing, a UBI9 Containerfile,
a Dev Spaces `devfile.yaml`, and a Backstage `catalog-info.yaml`.

## Endpoints

| Method + path        | Purpose                                   |
|----------------------|-------------------------------------------|
| `GET /api/info`      | Starter endpoint — `{ service, status }`  |
| `GET /q/health/live` | Liveness probe (SmallRye Health)          |
| `GET /q/health/ready`| Readiness probe (SmallRye Health)         |
| `GET /q/metrics`     | Prometheus metrics (Micrometer)           |

Replace `InfoResource` with your real API.

## Local development

```bash
./mvnw quarkus:dev
curl -s localhost:8080/api/info
./mvnw -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar
```

## Building the image in-cluster

```bash
oc new-build --strategy=docker --binary --name=${{ values.name }} -n <your-namespace>
oc start-build ${{ values.name }} --from-dir=. --follow -n <your-namespace>
```

## Tech

- **Quarkus 3.33 LTS** (`quarkus.platform.version = 3.33.2.1`), **Java 21**, `fast-jar`.
- Health, metrics, and tracing are **on by default** — Parasol convention.
- UBI9 multi-stage `Containerfile` (`ubi9/openjdk-21:1.23`), runs as non-root USER 185.
