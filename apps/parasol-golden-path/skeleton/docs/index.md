# ${{ values.name }}

A Parasol Insurance service created from the **golden path** template. It starts as a small
Quarkus (Java 21) service and already carries everything it needs to reach production: tests,
an image scan, an SBOM, a keyless signature, a Conforma check and GitOps promotion.

## Endpoints

| Method + path         | Purpose                         |
|-----------------------|---------------------------------|
| `GET /api/info`       | Starter endpoint                |
| `GET /q/health/live`  | Liveness probe                  |
| `GET /q/health/ready` | Readiness probe                 |
| `GET /q/metrics`      | Prometheus metrics              |

## Where things are

| What | Where |
|---|---|
| Code | this repository |
| Deployment and CI configuration | `${{ values.name }}-gitops` (`ci/`, `overlays/dev`, `overlays/stage`, `overlays/prod`) |
| Environments | `${{ values.user }}-dev`, `${{ values.user }}-stage`, `${{ values.user }}-prod` |
| Pipelines and images | `${{ values.user }}-cicd` |

These pages live in `docs/` next to the code; change them with a commit like any other file.
