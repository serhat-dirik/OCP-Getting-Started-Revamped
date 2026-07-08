"""Parasol Insurance - notifications service (Python / FastAPI).

The Python counterpart to the Node version in ../node - identical API, so M02
attendees can pick either runtime and get the same behaviour:

    GET  /health             -> {"status": "UP"}
    GET  /api/notifications  -> every notification recorded since startup
    POST /api/notify         -> record {claimNumber, message}, returns it (201)

The store is in-memory and resets on restart - this is a demo notifier, not a
durable queue (that honest limitation is called out in the README).
"""

import datetime
import os

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="parasol-notifications", version="1.0.0")

# In-memory store - resets on restart (no database in this sample).
notifications: list[dict] = []


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
