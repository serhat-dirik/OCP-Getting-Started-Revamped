# M13 build note — Securing Apps with Keycloak

Date: 2026-07-09 · Author: research-analyst R4c · Spec: 02-MODULE-SPECS §M13 (lines 163-171)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22) — read-only inspection of the existing rhbk install (Keycloak CR, KeycloakRealmImport, CSV, pods), rhbk-operator catalog channels, `oc explain keycloakrealmimport`; repo inspection (apps + entry-states + portfolio); docs.redhat.com + keycloak.org (token exchange); quarkus.io (OIDC). versions.yaml `rhbk` re-verified 2026-07-09.

## Verified versions

| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-09 |
| Red Hat build of Keycloak operator — **NEW-install target** | 26.6.4-opr.1 | stable-v26.6 | packagemanifest `rhbk-operator` (Red Hat); csv `rhbk-operator.v26.6.4-opr.1` (catalog head/default) | 2026-07-09 |
| Red Hat build of Keycloak — **installed cluster IdP** | 26.4.13-opr.1 | stable-v26.4 | live CSV in ns `keycloak` (read-only) | 2026-07-09 |
| Quarkus | 3.33.2.1 (3.33 LTS) | — | versions.yaml; `apps/parasol-*/pom.xml` | 2026-07-09 |

Cluster reality (verified live 2026-07-09, read-only):

- **The only rhbk on the cluster is the LOGIN IdP.** ns `keycloak`: `Keycloak` CR `keycloak` (`k8s.keycloak.org/v2alpha1`; `instances: 1`; db postgres `keycloak-pgsql`; hostname `sso.apps.cluster-example.sandbox.example.com`); `KeycloakRealmImport` `sso` (realm `sso`, client `idp-4-ocp`, realm roles `user`/`admin`); pods `keycloak-0` + `keycloak-pgsql-*` + `rhbk-operator-*` + completed `sso` import Job. Operator CSV `rhbk-operator.v26.4.13-opr.1`. **Treat READ-ONLY — it backs live logins.**
- **Catalog head for a NEW install:** `rhbk-operator` default channel `stable-v26.6` → `v26.6.4-opr.1`. CRDs `keycloaks` + `keycloakrealmimports` at `k8s.keycloak.org/v2alpha1`. `KeycloakRealmImport.spec` (`oc explain`): `keycloakCRName` (req), `realm` (RealmRepresentation, req), **`placeholders`** (map — ENV substitution, ideal for per-user redirect URIs), `resources`.
- **Standard token exchange is GA + default-on** (feature `token-exchange-standard`, RFC 8693) **since Keycloak 26.2** — both installed (26.4.13) and new (26.6.4) qualify, **no preview flag**. (keycloak.org/2025/05/standard-token-exchange-kc-26-2; docs.redhat.com RHBK 26.4 Securing Applications ch.12; access.redhat.com/articles/7119304). The M13 scenario (re-audience a user token for a fraud service, downscope-not-escalate) is exactly the supported internal-internal case; legacy v1 `token-exchange` (impersonation/external) stays preview and is not needed.
- **parasol-claims is unprotected** (`apps/parasol-claims/pom.xml`): `rest-jackson` + `hibernate-orm-panache` + `jdbc-postgresql`, **no `quarkus-oidc`** — matches the entry state. **parasol-web** (`apps/parasol-web/pom.xml`): `rest-jackson` only, no `quarkus-oidc`. Both Quarkus 3.33.2.1/JDK21.
- **Cross-namespace secret-copy pattern already exists** (`gitops/entry-states/m06/templates/maas-credentials.yaml`): a sync-hook Job + least-privilege RBAC copies one named secret between namespaces — reuse the shape to land a per-user OIDC client secret in `{user}-dev`.

## Spec deltas

- Entry state offers "shared RHBK with per-user realm seeded (or per-user instance — build-time decision by resources)." **Decision: do NOT reuse the login IdP** (it is production infra for the workshop). Stand up a **new, shared, workshop-owned rhbk** via a portfolio component with **per-user realms**; **per-user instances are cut** (8× Keycloak+Postgres is unjustified footprint).
- Entry state "parasol-web + claims API deployed **unprotected**" — true today. But wiring `quarkus-oidc` from a bare pom + rebuild inside a 90-min module is heavy; recommend shipping `quarkus-oidc` on both apps with the tenant **disabled** (`quarkus.oidc.tenant-enabled=false`) so M01-M12 stay unprotected (module independence) and M13 becomes a **config + annotation** exercise (app work below).
- Products line says "verify `token-exchange-standard` GA state at build" → **confirmed GA/default since 26.2**; the advanced exercise is lab-viable, not preview.
- `[INSTRUCTOR-DEMO]` "same Keycloak as cluster IdP (ties M14)": reference the existing `keycloak/keycloak` + `oauth/cluster` **read-only** — do not reconfigure.

## Approach recommendations

1. New **`keycloak` portfolio component + `auth` stack** (profile `core+auth`): Subscription `rhbk-operator` `stable-v26.6` + OperatorGroup (verify install mode — see risks) + a `Keycloak` CR (1 instance, own Postgres, hostname `sso-workshop.{cluster_domain}`) — one **shared** disposable workshop instance, separate from the login IdP.
2. Isolation = **one realm per user** via `KeycloakRealmImport realm-{user}` using `spec.placeholders` for per-user redirect URIs (`{user}-dev` routes). Recommend realm-per-user over shared-realm/per-user-client: cleaner blast radius + admin scoping, matches the watchout "per-user realm isolation."
3. Simplest teachable client shape: **parasol-web = confidential web-app client** (auth-code + PKCE, `quarkus.oidc.application-type=web-app`); **parasol-claims = bearer-only service** (`quarkus.oidc.application-type=service`); role `claims-adjuster` enforced with `@RolesAllowed` + **`quarkus.oidc.roles.role-claim-path=realm_access/roles`** (Keycloak realm roles are in `realm_access.roles`, not `groups`); a client-credentials client for the M06 batch service identity.
4. Advanced RFC 8693: claims exchanges the user token for a fraud-audience token via `quarkus-oidc-client` `grant.type=exchange` + `grant-options.exchange.audience=fraud` (or `rest-client-oidc-token-propagation` `exchange-token=true`); the fraud target enforces `aud` (`quarkus.oidc.token.audience`); an escalation attempt fails (downscope-only lesson). Target = a tiny new `parasol-fraud` bearer service **or** a second audience-scoped endpoint (app work below). (quarkus.io security-openid-connect-client-reference)
5. Entry state `m13` (Helm like `entry-states/m05`): `parasol-web` + `parasol-claims` + `claims-db` **unprotected** in `{user}-dev`; mint the per-user client secret in the chart, inject it into the realm import via `placeholders` **and** into a `{user}-dev` Secret for `quarkus.oidc.credentials.secret` (avoids reading back from Keycloak; fall back to the m06 secret-copy hook if reading the operator-materialized secret is preferred).

## Mining results

- **`serhat-dirik/kc-token-exchangeV2-demo`** (D18 reuse-with-credit; `OldContent/repos/kc-token-exchangeV2-demo`, last commit 2026-06-01) → the **standard token-exchange V2 flow**: subject token → exchanged audience token → downscope-not-escalate proof. Port the flow shape; re-verify against RHBK 26.6 + Quarkus 3.33; add a `CREDITS.md` entry. (`oldcontent-mining-index.md` §2b line 73)
- `redhat-ads-tech/parasol-insurance-secured-manifests` (`oldcontent-mining-index.md` §3) → secured/zero-trust deploy shapes (OIDC + AuthorizationPolicy) for reference only; **license=none → re-implement**, do not copy.
- `adv-app-platform` M3 (external secrets) → the client-secret-into-namespace narrative parallel. Spec's "don't build your own login page" economics framing = fresh.

## Open risks

- **rhbk-operator install mode:** installModes not captured (kueue was AllNamespaces; rhbk is historically OwnNamespace/SingleNamespace) — `TODO(verify-on-cluster)` before writing the OperatorGroup for the `keycloak` component.
- **Quarkus role mapping is a classic trap:** without `quarkus.oidc.roles.role-claim-path=realm_access/roles`, `@RolesAllowed("claims-adjuster")` won't match Keycloak realm roles (verified quarkus.io). Clock-skew classics (watchout) — keep token lifetimes generous in the realm.
- **Token-exchange plumbing:** the calling service needs `quarkus-oidc-client`; confirm `grant-options.exchange.*` keys against Quarkus 3.33 at build (quarkus.io). The fraud audience target must actually enforce `aud`, or the "escalation fails" lesson won't land.
- Per-user realm count (8 now → up to 30 at events) in one instance is fine, but redirect-URI templating + per-realm admin scoping need the `placeholders` mechanism (watchout).
- **Never touch** `oauth/cluster` or the `keycloak/sso` realm — the IdP-tie is a read-only `[INSTRUCTOR-DEMO]`.

## Builder/app appendix

- **App work (app-developer):** add `quarkus-oidc` to `parasol-web` (web-app) and `parasol-claims` (service), default `quarkus.oidc.tenant-enabled=false` (module independence). M13 sets `auth-server-url` / `client-id` / `credentials.secret` / `application-type` + `tenant-enabled=true` + `roles.role-claim-path=realm_access/roles`; add `@RolesAllowed("claims-adjuster")` on the guarded `ClaimResource` method (the in-lab edit). Add `quarkus-oidc-client` to `parasol-claims` for the exchange grant. New minimal **`parasol-fraud`** bearer service (`aud=fraud`) as the exchange target, or a second audience-scoped endpoint.
- **Platform (platform-engineer):** `platform-portfolio/components/keycloak` (Subscription + OperatorGroup + `Keycloak` CR + Postgres) → new `platform-portfolio/stacks/auth`; per-user `KeycloakRealmImport realm-{user}` live in the workshop layer / entry state.
- **Demo angle:** unprotected → full SSO with role deny/allow in 10 min; token-exchange chain as the encore. (spec Demo arc)
- **Timing (90 min):** realm tour + web OIDC ~20 · bearer API + roles ~25 · client-credentials ~10 · break/debug tokens ~10 · RFC 8693 advanced ~20 · IdP-tie demo ~5.
