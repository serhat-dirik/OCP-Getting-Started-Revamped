/* Parasol Insurance - Claims Portal
   Fetches the seeded claims from GET /api/claims and fills the summary table.
   Vanilla JS, no dependencies. Data is rendered with textContent (never innerHTML)
   so values are always treated as text, never markup. */
(function () {
  "use strict";

  var STATUS_CLASS = {
    "Open": "status--open",
    "Under Review": "status--review",
    "Approved": "status--approved",
    "Denied": "status--denied",
    "Closed": "status--closed"
  };

  var usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

  function cell(text, cls) {
    var td = document.createElement("td");
    if (cls) { td.className = cls; }
    td.textContent = text;
    return td;
  }

  function statusCell(status) {
    var td = document.createElement("td");
    var badge = document.createElement("span");
    badge.className = "status " + (STATUS_CLASS[status] || "status--open");
    badge.textContent = status;
    td.appendChild(badge);
    return td;
  }

  function render(claims) {
    var body = document.getElementById("claims-body");
    body.textContent = "";

    claims.forEach(function (c) {
      var tr = document.createElement("tr");
      tr.appendChild(cell(c.id, "mono"));
      tr.appendChild(cell(c.policyholder));
      tr.appendChild(cell(c.type));
      tr.appendChild(statusCell(c.status));
      tr.appendChild(cell(usd.format(c.amount), "num"));
      tr.appendChild(cell(c.filedDate));
      body.appendChild(tr);
    });

    var count = document.getElementById("claims-count");
    count.textContent = claims.length + (claims.length === 1 ? " claim" : " claims");
  }

  function fail(message) {
    var body = document.getElementById("claims-body");
    body.textContent = "";
    var tr = document.createElement("tr");
    var td = document.createElement("td");
    td.colSpan = 6;
    td.className = "error";
    td.textContent = message;
    tr.appendChild(td);
    body.appendChild(tr);
  }

  fetch("/api/claims")
    .then(function (res) {
      if (!res.ok) { throw new Error("HTTP " + res.status); }
      return res.json();
    })
    .then(render)
    .catch(function (err) {
      fail("Could not load claims (" + err.message + ").");
    });
})();
