# parasol-claims

The Parasol Insurance **core claims service**: a Quarkus REST API over PostgreSQL that owns the
`CLM-1001`–`CLM-1030` claims. Nearly every module of the workshop acts on this service.

| Method + path | Purpose |
|---|---|
| `GET /` | Service landing page (JSON); never touches the database |
| `GET /api/claims` | List claims (`?page=`, `?size=`) |
| `GET /api/claims/{claimNumber}` | One claim, or 404 |
| `GET /api/claims/{claimNumber}/history` | A claim's audit timeline |
| `POST /api/claims` | Create a claim |
| `PUT /api/claims/{claimNumber}/status` | Advance a claim's workflow status |
| `GET /q/health/live` · `/q/health/ready` | Liveness and readiness probes |
| `GET /q/metrics` | Prometheus metrics |

The repository's `README.md` covers the data model, configuration and how to run it locally.
