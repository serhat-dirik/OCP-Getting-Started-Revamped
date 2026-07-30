// Behavioural tests for the parasol-notifications Node service.
//
// This is a zero-dependency service on purpose (see ../server.js), so these tests use
// only Node's own test runner (node:test) and built-in fetch — no devDependency, no
// npm install, nothing that would put a lockfile on a service that deliberately has
// none. server.js is unmodified: it starts listening as soon as it is loaded (no
// require.main guard), so each describe block spawns it as a real child process on
// its own port and talks to it over real HTTP, the same way an attendee's curl would.
//
// These pin actual observed behaviour, not aspirational behaviour: the README calls
// the Node and Python services "identical API", but they are not quite - see the
// missing-field-vs-empty-string cases below, which capture the real (divergent)
// response each implementation gives today.

const { test, describe, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const path = require("node:path");

const SERVER_PATH = path.join(__dirname, "..", "server.js");

async function waitForHealth(base, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${base}/health`);
      if (res.ok) return;
    } catch (err) {
      lastErr = err;
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server at ${base} never became healthy: ${lastErr}`);
}

function startServer(port, env = {}) {
  return spawn(process.execPath, [SERVER_PATH], {
    env: { ...process.env, PORT: String(port), SITE: "", ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

describe("parasol-notifications (node) - default env, no SITE", () => {
  const PORT = 8391;
  const BASE = `http://127.0.0.1:${PORT}`;
  let child;

  before(async () => {
    child = startServer(PORT);
    await waitForHealth(BASE);
  });

  after(() => {
    child.kill("SIGTERM");
  });

  test("GET /health reports UP", async () => {
    const res = await fetch(`${BASE}/health`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: "UP" });
  });

  test("GET / returns a landing body with no site key when SITE is unset", async () => {
    const res = await fetch(`${BASE}/`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.service, "parasol-notifications");
    assert.equal(body.runtime, "node");
    assert.ok(!("site" in body), "site key must be absent when SITE is unset");
    assert.deepEqual(body.links, {
      notifications: "/api/notifications",
      notify: "/api/notify",
      health: "/health",
    });
  });

  test("GET /api/notifications starts empty", async () => {
    const res = await fetch(`${BASE}/api/notifications`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), []);
  });

  test("POST /api/notify with a missing field is rejected with 400 and a named error", async () => {
    const res = await fetch(`${BASE}/api/notify`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ claimNumber: "CLM-1" }),
    });
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), {
      error: "claimNumber and message are required",
    });
  });

  test("POST /api/notify with an empty-string claimNumber is rejected (falsy check)", async () => {
    // server.js uses `if (!claimNumber || !message)`, so "" is treated the same as
    // absent. This is a deliberate divergence from the Python implementation, which
    // accepts an empty string as a valid (if useless) claimNumber - see
    // ../../python/test_app.py's equivalent case.
    const res = await fetch(`${BASE}/api/notify`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ claimNumber: "", message: "hi" }),
    });
    assert.equal(res.status, 400);
  });

  test("POST /api/notify with invalid JSON returns 400", async () => {
    const res = await fetch(`${BASE}/api/notify`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{not valid json",
    });
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { error: "invalid JSON body" });
  });

  test("POST /api/notify records a notification, echoing it with a sentAt timestamp", async () => {
    const payload = { claimNumber: "CLM-9001", message: "Adjuster assigned" };
    const postRes = await fetch(`${BASE}/api/notify`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    assert.equal(postRes.status, 201);
    const created = await postRes.json();
    assert.equal(created.claimNumber, payload.claimNumber);
    assert.equal(created.message, payload.message);
    assert.ok(created.sentAt, "sentAt must be present");
    assert.ok(!Number.isNaN(Date.parse(created.sentAt)), "sentAt must be a parseable timestamp");
  });

  test("GET /api/notifications reflects a prior POST (in-memory persistence within the process)", async () => {
    const res = await fetch(`${BASE}/api/notifications`);
    const list = await res.json();
    assert.ok(
      list.some((n) => n.claimNumber === "CLM-9001" && n.message === "Adjuster assigned"),
      "the notification recorded by the previous POST must be listed",
    );
  });

  test("GET on an unknown route returns 404", async () => {
    const res = await fetch(`${BASE}/nope`);
    assert.equal(res.status, 404);
    assert.deepEqual(await res.json(), { error: "not found" });
  });
});

describe("parasol-notifications (node) - SITE set", () => {
  const PORT = 8392;
  const BASE = `http://127.0.0.1:${PORT}`;
  let child;

  before(async () => {
    child = startServer(PORT, { SITE: "A" });
    await waitForHealth(BASE);
  });

  after(() => {
    child.kill("SIGTERM");
  });

  test("GET / carries a compact site marker when SITE is set", async () => {
    const res = await fetch(`${BASE}/`);
    const body = await res.json();
    assert.equal(body.site, "A");
  });
});
