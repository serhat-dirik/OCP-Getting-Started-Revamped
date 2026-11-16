# parasol-web

The Parasol Insurance **claims-portal frontend**: a small Quarkus application that serves a
landing page with a table of claims. It has no database and no backend service; its claims are
seeded in the application, so it runs with nothing else on the cluster.

| Method + path | Purpose |
|---|---|
| `GET /` | The landing page |
| `GET /api/claims` | Five seeded claims |
| `GET /q/health/live` · `/q/health/ready` | Liveness and readiness probes |
| `GET /q/metrics` | Prometheus metrics |

The repository's `README.md` covers how to build and run it.
