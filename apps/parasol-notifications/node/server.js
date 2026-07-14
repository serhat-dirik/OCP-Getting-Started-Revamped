// Parasol Insurance - notifications service (Node, zero dependencies).
//
// Deliberately tiny: the Node plug-and-play counterpart to the Python/FastAPI
// version in ../python. Uses only the Node standard library so the S2I nodejs
// build needs no npm registry access (nothing to install).
//
//   GET  /                   -> service landing (what this is + links); carries
//                               a compact "site":"<SITE>" marker when SITE is set
//   GET  /health             -> { "status": "UP" }
//   GET  /api/notifications  -> every notification recorded since startup
//   POST /api/notify         -> record { claimNumber, message }, returns it (201)
//
// The store is in-memory and resets on restart - this is a demo notifier, not a
// durable queue (that honest limitation is called out in the README).

const http = require("http");

// Optional origin-site marker (set by env). Present in / responses when non-empty,
// so a site-aware deployment can self-identify; absent for the single-site default.
const site = process.env.SITE;

const notifications = [];

// The GET / landing: a real, browseable answer instead of a 404 at the root.
function landing() {
  const body = {
    service: "parasol-notifications",
    description: "Parasol Insurance notifications service (in-memory demo notifier)",
    runtime: "node",
  };
  // Compact "site":"<SITE>" (JSON.stringify emits no spaces) when a site is declared.
  if (site && site.trim() !== "") body.site = site.trim();
  body.links = { notifications: "/api/notifications", notify: "/api/notify", health: "/health" };
  return body;
}

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

function handleNotify(req, res) {
  let raw = "";
  req.on("data", (chunk) => {
    raw += chunk;
  });
  req.on("end", () => {
    let parsed;
    try {
      parsed = raw ? JSON.parse(raw) : {};
    } catch {
      return send(res, 400, { error: "invalid JSON body" });
    }
    const { claimNumber, message } = parsed;
    if (!claimNumber || !message) {
      return send(res, 400, { error: "claimNumber and message are required" });
    }
    const notification = { claimNumber, message, sentAt: new Date().toISOString() };
    notifications.push(notification);
    console.log(`[notify] ${claimNumber}: ${message}`);
    send(res, 201, notification);
  });
}

const server = http.createServer((req, res) => {
  const { method, url } = req;

  if (method === "GET" && url === "/") {
    return send(res, 200, landing());
  }
  if (method === "GET" && url === "/health") {
    return send(res, 200, { status: "UP" });
  }
  if (method === "GET" && url === "/api/notifications") {
    return send(res, 200, notifications);
  }
  if (method === "POST" && url === "/api/notify") {
    return handleNotify(req, res);
  }
  send(res, 404, { error: "not found" });
});

const port = process.env.PORT || 8080;
server.listen(port, "0.0.0.0", () => {
  console.log(`parasol-notifications (node) listening on :${port}${site ? ` (site ${site})` : ""}`);
});

// Exit promptly on SIGTERM (a rollout or `oc scale` to 0): stop accepting new
// connections, then exit as soon as in-flight requests drain - so a scaled-down
// pod dies crisply within its terminationGracePeriodSeconds.
process.on("SIGTERM", () => {
  server.close(() => process.exit(0));
});
