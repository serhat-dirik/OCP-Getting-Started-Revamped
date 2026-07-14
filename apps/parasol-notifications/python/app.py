"""Parasol Insurance - notifications service (Python / FastAPI).

The Python counterpart to the Node version in ../node - identical API, so M02
attendees can pick either runtime and get the same behaviour:

    GET  /                   -> service landing (what this is + links); carries a
                                compact "site":"<SITE>" marker when SITE is set
    GET  /health             -> {"status": "UP"}
    GET  /api/notifications  -> every notification recorded since startup
    POST /api/notify         -> record {claimNumber, message}, returns it (201)

The store is in-memory and resets on restart - this is a demo notifier, not a
durable queue (that honest limitation is called out in the README).

Uvicorn traps SIGTERM and shuts down gracefully by default, so a rollout or
`oc scale` to 0 drains in-flight requests and the pod exits promptly.
"""

import datetime
import os

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="parasol-notifications", version="1.0.0")

# Optional origin-site marker (set by env). Surfaced in GET / when non-empty, so a
# site-aware deployment can self-identify; absent for the single-site default.
SITE = os.environ.get("SITE")

# In-memory store - resets on restart (no database in this sample).
notifications: list[dict] = []


@app.get("/")
def root() -> dict:
    """A real, browseable landing instead of a 404 at the service root."""
    body = {
        "service": "parasol-notifications",
        "description": "Parasol Insurance notifications service (in-memory demo notifier)",
        "runtime": "python",
    }
    # FastAPI emits compact JSON, so this serializes as "site":"A" (no spaces).
    if SITE and SITE.strip():
        body["site"] = SITE.strip()
    body["links"] = {
        "notifications": "/api/notifications",
        "notify": "/api/notify",
        "health": "/health",
    }
    return body


class NotifyRequest(BaseModel):
    claimNumber: str
    message: str


@app.get("/health")
def health() -> dict:
    return {"status": "UP"}


@app.get("/api/notifications")
def list_notifications() -> list[dict]:
    return notifications


@app.post("/api/notify", status_code=201)
def notify(request: NotifyRequest) -> dict:
    notification = {
        "claimNumber": request.claimNumber,
        "message": request.message,
        "sentAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    notifications.append(notification)
    print(f"[notify] {request.claimNumber}: {request.message}", flush=True)
    return notification


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
