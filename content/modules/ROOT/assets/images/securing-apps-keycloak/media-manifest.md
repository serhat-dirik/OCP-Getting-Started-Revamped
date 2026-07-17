# M13 media manifest — Securing Apps with Keycloak

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** (or any assigned attendee id) on the workshop cluster, default console theme,
annotate with numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a commented
`// media-pass: …` line — replace with the `image::` (screenshot) or the SVG `image::` (diagram)
when the asset lands. `.png` screenshots and `.svg` diagrams share the NN index space (distinguished
by extension), matching the M10/M12 convention.

**Why this module's screenshots are lighter than most.** M13 is deliberately **terminal + curl driven**:
the whole lab is `oc set env` / `curl` / token `decode`, and the outcomes are HTTP status codes, not
console views. The build performed and verified every beat from the terminal (the open API at 200, the
bearer matrix 401/200/403, the web-app `http`→400 break and the proxy-forwarding fix, the
client-credentials token, and the RFC 8693 exchange + the refused escalation) — there is no browser in
the build environment, so the few genuinely-visual moments are listed here for the media pass. The
**Console tabs** in the lab are the OpenShift Deployment *Environment* editor and *Import YAML* (dual-path
alternatives to `oc set env` / `oc apply`); each gets a screenshot below.

> **Signature visual:** the **Keycloak login page** (`06`) — the moment the protected web frontend bounces
> an anonymous visitor to your realm's login. It is the "we didn't build this" proof and the one still
> image the deck should carry from the browser. The **four-flows diagram** (`01`) is the signature concept
> visual.

## Screenshots / recordings

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 5 | `securing-apps-keycloak-05-claims-env.png` | ⬜ NOT CAPTURED | **Workloads → Deployments → parasol-claims → Environment** tab with the `QUARKUS_OIDC_*` vars entered | the Name/Value rows that enable bearer protection — the Console-tab equivalent of `oc set env` (grounds the Console tab of ex. 2; the same UI is reused for ex. 3 and the ex. 4 web env) | lab.adoc ex. 2 (Console tab) |
| 6 | `securing-apps-keycloak-06-keycloak-login.png` | ⬜ NOT CAPTURED — **HIGH (signature; prefer <30s GIF/MP4)** | the **Keycloak login page** for `realm-<user>`, reached by opening the protected `parasol-web` frontend unauthenticated | the realm-branded login form the app never had to build — record the browser redirect (app → Keycloak login → back into the app after signing in as `adjuster`/`parasol`) | lab.adoc ex. 4 (after the proxy-forwarding fix) |
| 8 | `securing-apps-keycloak-08-import-fraud.png` | ⬜ NOT CAPTURED — optional | **+ / Import YAML** editor with the `parasol-fraud` manifest pasted | the masthead `+` action and the paste-and-Create flow (grounds the Console tab of ex. 7) | lab.adoc ex. 7 (Console tab) |

## Diagrams (SVG in-repo; source of truth is the inline Mermaid in the `.adoc`)

The concept/wrap-up pages ship inline Mermaid (editable-source rule satisfied by construction).
Export these to SVG next to their `.adoc` for the slide deck and richer rendering; keep the Mermaid as
the editable source (do not delete it).

| # | Filename | Status | Source (inline Mermaid in) | Shows |
|---|----------|--------|-----------------------------|-------|
| 1 | `securing-apps-keycloak-01-four-flows.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | the four OIDC flows — auth-code+PKCE + bearer (human), client-credentials + token-exchange (machine) — and how the user token flows through them |
| 2 | `securing-apps-keycloak-02-realm-model.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | realm → clients / roles / users, with the four Parasol clients, `claims-adjuster`, and the `adjuster`/`viewer` users |
| 3 | `securing-apps-keycloak-03-build-vs-buy.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | "build it yourself" (a column of auth risk) vs "use the platform" (Keycloak, included with OpenShift) |
| 4 | `securing-apps-keycloak-04-security-layer.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | the identity/access layer (login / bearer API / machine identity / exchange) over the M01–M12 Parasol platform, fed by Keycloak |
| 7 | `securing-apps-keycloak-07-what-you-built.svg` | ⬜ NOT CAPTURED (export) | wrapup.adoc | Keycloak at center feeding web (login), claims (bearer+role), fraud (exchange), batch (client-creds) |

## Recording (demo-arc happy path)

- `securing-apps-keycloak-demo.cast` (asciinema) OR a `<90s` silent screen capture — ⬜ NOT CAPTURED.
  The flagship clip pairs the two beats that read best on screen: **flip the open API live** (one
  `oc set env`, then the same `curl` goes `200 → 401` no token / `200` adjuster / `403` viewer), and the
  **token-exchange encore** (user token 401 at fraud → exchanged token 200 → the `parasol-batch`
  escalation *refused*). Both are terminal beats, so an asciinema cast is the highest-value, lowest-effort
  asset; pair it with the `06` Keycloak-login browser clip for the human-facing moment.
