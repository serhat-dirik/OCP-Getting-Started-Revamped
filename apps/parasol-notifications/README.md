# parasol-notifications

Parasol Insurance **notifications service** — the M02 *polyglot moment*. Two
implementations with an **identical API**, so an attendee picks a runtime and gets
the same behaviour:

- **`node/`** — Node standard library only, **zero dependencies** (the S2I nodejs
  build needs no npm registry access).
- **`python/`** — FastAPI + uvicorn.

Deliberately tiny — small enough to read in a couple of minutes.

## Endpoints

| Method + path            | Purpose                                                                 |
|--------------------------|-------------------------------------------------------------------------|
| `GET /`                  | Service landing (JSON: what this is + links); carries a compact `"site":"<SITE>"` marker when `SITE` is set |
| `GET /health`            | Health check → `{"status":"UP"}`                                        |
| `GET /api/notifications` | Every notification recorded since startup                               |
| `POST /api/notify`       | Record `{claimNumber, message}` → returns it (201); 400 if either is missing |

## Site awareness

`GET /` returns a small JSON landing so clicking the Route in the console shows
something real instead of a 404. When the `SITE` env var is set, the body also
carries a compact `"site":"<SITE>"` marker (matching the `parasol-claims`
convention):

```bash
$ SITE=A curl -s localhost:8080/
{"service":"parasol-notifications","description":"...","runtime":"node","site":"A","links":{...}}
```

## Honest limitation

The store is **in-memory and resets on restart** — this is a demo notifier, not a
durable queue. Persisting notifications (a database or a real broker) is out of
scope for the sample.

## Run locally

```bash
# Node:
cd node && node server.js
# Python:
cd python && pip install -r requirements.txt && uvicorn app:app --host 0.0.0.0 --port 8080

curl -s localhost:8080/ | jq
curl -s localhost:8080/api/notifications | jq
curl -s -XPOST localhost:8080/api/notify -H content-type:application/json \
  -d '{"claimNumber":"CLM-1001","message":"Adjuster assigned"}' | jq
```

Both are built on the cluster via the S2I nodejs / python builder images (M02
import-from-Git). Port **8080**; runs under OpenShift's restricted-v2 SCC.
