# Securing Apps with Keycloak

## Slide: The claims API answers anyone who can reach it

- Type the URL, get every claimant's name, amount, and adjuster — no login, no token
- Fine when "the network" was a locked server room
- A data breach when the network is a shared cluster + partner + mobile app
- This is the shape of most internal breaches: something got on the network, everything trusted it
- This module puts a front door on the Parasol apps — with a product you already own

Notes: Open on the open API. Show that reading every claim takes *nothing* — no credentials at all. That is not a strawman; it is how a huge share of real internal breaches actually work: one thing lands on the trusted network and everything on it answers. The module's job is to make the apps trust a *token they can validate* instead of a network location, using Red Hat build of Keycloak — the identity and SSO product that ships with OpenShift. The promise to the room: no password checks, no session store, no login page written by us.
Visual: A dark "claims API" tile spilling customer records to an anonymous stick-figure; a red "no auth" stamp.

## Slide: Authentication is not authorization

- **AuthN** — *who are you?* Proving identity (a login, a token)
- **AuthZ** — *what may you do?* Checking permission (a role, an ownership rule)
- A valid token answers only the first question
- `viewer` logs in perfectly — and must still be denied listing claims
- You will see it as two status codes: **401** = "who are you?" · **403** = "I know, and no"

Notes: The single most common security bug is confusing these two. Authentication proves identity; authorization checks permission. The Parasol `viewer` user has a correct password and a valid token — authentication succeeds — and must still be refused, because listing claims needs a role they lack. The lab makes this concrete as HTTP status codes: 401 Unauthorized means the API does not know who you are; 403 Forbidden means it knows exactly and the answer is no. Keep them straight and half of app security falls into place.
Visual: Two gates — gate 1 "AuthN: who are you?" (401 if no), gate 2 "AuthZ: what may you do?" (403 if no); a token passes gate 1 but stops at gate 2.

## Slide: Four flows — and when each applies

- **Auth-code + PKCE** — browser login; the app never sees the password (web frontend)
- **Bearer token** — caller presents a token; API validates + checks role (the API)
- **Client credentials** — a service authenticates as *itself* (the batch job)
- **Token exchange (RFC 8693)** — re-audience a user's token to call another service *on their behalf*
- Learn these four; resist the rest of OAuth

Notes: OAuth/OIDC define many flows; four cover almost every enterprise app and this module teaches exactly those. Auth-code + PKCE protects the browser app — the human logs in at Keycloak, the app gets a code it swaps for tokens, and PKCE (a one-time per-login secret) makes a stolen code useless. Bearer protects the API — every request carries a self-contained token the API validates against Keycloak's public keys, no session. Client credentials is for machines with no human. Token exchange is for one service calling another as the user, and its defining property — proven in the lab — is that it can downscope but never escalate.
Visual: Concept diagram securing-apps-keycloak-01-four-flows — human flows (auth-code, bearer) above, machine flows (client-creds, exchange) below, an arrow from the user token into the exchange.

## Slide: Realm, client, role, user — the whole model

- **Realm** — an isolated world of identity (this workshop: one realm per attendee)
- **Client** — an app that uses the realm (public = browser; confidential = backend)
- **Role** — a named permission; realm roles ride in the token under `realm_access.roles`
- **User** — a person who logs in (`adjuster` has the role; `viewer` has none)
- Get this vocabulary and Keycloak stops being mysterious

Notes: Keycloak's vocabulary is small. A realm is a self-contained world — its own users, roles, clients, keys, login page — and this workshop gives every attendee their own, the same isolation a platform team uses to separate business units. A client is an app talking to the realm; public clients (the browser) cannot keep a secret so they use PKCE, confidential clients (a backend) hold one. A role is a named permission that rides in the token — realm roles specifically under `realm_access.roles`, which is *where the app reads it*. Users are people; the two seeded users are the two sides of every authorization check.
Visual: Concept diagram securing-apps-keycloak-02-realm-model — realm containing clients / roles / users, with the four Parasol clients and two users as leaves.

## Slide: Don't build your own login page

- Every hour building auth is an hour not on claims — and what you build is worse
- Password policies, MFA, lockout, federation, token issuance, audit — all solved
- Getting it slightly wrong (a weak reset flow, a missing check) *is* the breach
- Your job shrinks to *describing* who may do what, and pointing apps at it
- **The punchline: Red Hat build of Keycloak is included with your OpenShift subscription**

Notes: Authentication is a solved problem and a catastrophic one to get wrong — a weak reset flow or a missing token check is the whole breach. A dedicated identity provider gives you password policy, MFA, lockout, social/enterprise federation, token issuance, and audit, built and patched by people who do only this. Your job becomes configuration, not code. And the message for leadership: this ships with OpenShift. The same product backs the console login. A team treating "add login" as a procurement project is usually re-buying what the subscription already includes.
Visual: Concept diagram securing-apps-keycloak-03-build-vs-buy — a long "build it yourself" column of risk vs a single "included with OpenShift" tile.

## Slide: Bearer + role, live — 401 → 200 → 403

- One config change (no rebuild): the open API now demands a valid token
- `no token → 401` · `adjuster → 200` · `viewer → 403`
- Health probes stay 200 — protect the app, not its plumbing
- The role resolved from `realm_access.roles` — the one mapping that matters
- Authentication *and* authorization, on screen, in four minutes

Notes: This is the signature live beat. Turning on the OIDC tenant and a permission rule — a configuration change on an image that already carries the library, so no build — flips the same `curl` from 200 to 401 without a token, 200 for the adjuster, and 403 for the viewer. The `/q/*` health endpoints stay open because the permission was scoped to `/api/claims`. The role check matched `claims-adjuster` straight from `realm_access.roles` because the image maps it there — call that out, because forgetting that mapping is the classic "has the role, still gets 403" bug.
Visual: A terminal-style panel with three lines lighting up: `no token → 401` (red), `adjuster → 200` (green), `viewer → 403` (amber).

## Slide: Token exchange — delegate without escalating

- Claims must call fraud *as the adjuster* — but the user's token says `aud: parasol-claims`
- Standard exchange (RFC 8693): Keycloak re-audiences it to `aud: parasol-fraud`, same user
- Wrong-audience token → **401** at fraud; exchanged token → **200**
- Try to exchange toward a service claims can't reach → **refused**
- The rule: re-audience and downscope, **never escalate**

Notes: The encore and the subtle idea. A logged-in adjuster asks claims for a fraud score; claims must call fraud on the user's behalf, but the user's token is addressed to claims, not fraud. Standard token exchange hands Keycloak the user's token and gets back the *same user's* token re-audienced for fraud — `preferred_username` stays `adjuster`, `aud` becomes `parasol-fraud`. Fraud rejects the original (401) and accepts the exchanged one (200). Then the safety property: attempting to exchange toward a service the caller isn't permitted for is flatly refused. Exchange can narrow a user's reach, never widen it — which is what makes a chain of services auditable and provably safe.
Visual: user token (aud=claims) → [Keycloak exchange] → token (aud=fraud, still adjuster) → fraud 200; a second dashed arrow toward "batch" hitting a red REFUSED wall.

## Slide: What you built — and it was already yours

- A browser login (auth-code + PKCE), a bearer-protected API with a role check
- A machine identity for the batch job; the skill to read a token instead of guessing
- A delegation chain that can downscope but never escalate
- All on a Keycloak that ships with your subscription — and backs the console login too
- "Trusted network" is not a security model; a token you can validate is

Notes: Close by connecting it back. You put a front door on Parasol — web login, bearer API with roles, a machine identity, token-debugging fluency, and a delegation chain that cannot escalate — without writing authentication code, on a product included with OpenShift that also secures the platform's own login. The durable message: stop trusting the network and start trusting tokens you can validate, and stop re-buying (or worse, re-building) identity you already own. The bridge to what's next: the same identity provider wiring apps *and* the cluster is the multi-tenancy story.
Visual: Concept diagram securing-apps-keycloak-07-what-you-built — Keycloak at center feeding web (login), claims (bearer+role), fraud (exchange), batch (client-creds), all green.
