"""Behavioural tests for the parasol-notifications FastAPI service.

Uses FastAPI's TestClient (starlette + httpx under the hood) to drive the real app
object in-process - no server subprocess needed, unlike the Node counterpart, because
app.py's module-level code only builds the FastAPI app; it does not start listening
until `uvicorn.run(...)` in the `if __name__ == "__main__"` guard, which importing the
module for tests never triggers.

These pin the actual observed behaviour of THIS implementation - not the README's
"identical API" claim. Pydantic's own validation (422, `detail` list) fires before
app code runs, which is a real, deliberate-looking divergence from the Node service's
custom 400 + `{"error": ...}` body for the same missing-field case - see
../node/test/server.test.js's equivalent case for the contrast, and the empty-string
case below, where the two implementations disagree even on the status code.
"""

import pytest
from fastapi.testclient import TestClient

import app as app_module


@pytest.fixture()
def client():
    # Fresh state per test: the notifications list and SITE are module-level globals
    # that would otherwise leak between tests sharing the one imported app module.
    app_module.notifications.clear()
    app_module.SITE = None
    return TestClient(app_module.app)


def test_health_reports_up(client):
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json() == {"status": "UP"}


def test_landing_has_no_site_key_when_site_unset(client):
    res = client.get("/")
    assert res.status_code == 200
    body = res.json()
    assert body["service"] == "parasol-notifications"
    assert body["runtime"] == "python"
    assert "site" not in body
    assert body["links"] == {
        "notifications": "/api/notifications",
        "notify": "/api/notify",
        "health": "/health",
    }


def test_landing_carries_site_marker_when_site_set(client):
    app_module.SITE = "A"
    res = client.get("/")
    assert res.json()["site"] == "A"


def test_notifications_start_empty(client):
    res = client.get("/api/notifications")
    assert res.status_code == 200
    assert res.json() == []


def test_notify_missing_field_is_rejected_by_pydantic_with_422(client):
    # Divergence from Node: FastAPI/pydantic validates before the endpoint body runs,
    # so a missing required field is a 422 with a `detail` list, not the Node
    # service's custom 400 + {"error": "..."}.
    res = client.post("/api/notify", json={"claimNumber": "CLM-1"})
    assert res.status_code == 422
    assert res.json()["detail"][0]["loc"] == ["body", "message"]


def test_notify_accepts_empty_string_claim_number(client):
    # Divergence from Node: server.js's `!claimNumber` falsy check rejects "" with
    # 400; pydantic's plain `str` type has no such check, so this implementation
    # accepts and records an empty-string claimNumber. Pinning the real behaviour,
    # not the README's "identical API" aspiration.
    res = client.post("/api/notify", json={"claimNumber": "", "message": "hi"})
    assert res.status_code == 201
    assert res.json()["claimNumber"] == ""


def test_notify_records_and_lists_a_notification(client):
    payload = {"claimNumber": "CLM-9001", "message": "Adjuster assigned"}
    res = client.post("/api/notify", json=payload)
    assert res.status_code == 201
    created = res.json()
    assert created["claimNumber"] == payload["claimNumber"]
    assert created["message"] == payload["message"]
    assert created["sentAt"]

    listing = client.get("/api/notifications").json()
    assert any(
        n["claimNumber"] == "CLM-9001" and n["message"] == "Adjuster assigned"
        for n in listing
    )


def test_unknown_route_returns_404(client):
    res = client.get("/nope")
    assert res.status_code == 404
