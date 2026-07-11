# M11 build note — Developer Hub & Golden Paths

Date: 2026-07-09 · Author: research-analyst R4b · Spec: 02-MODULE-SPECS §M11 (lines 141-150) · Entitlement: **[ADS]** (RHADS — RHDH + Developer Lightspeed)
Method: live cluster `ocp-ws-revamped` — OLM packagemanifests, CRD/CSV/OAuth/Keycloak inspection; docs.redhat.com (RHDH 1.7/1.9 auth, sizing, Lightspeed, templates); versions.yaml re-confirmed live.

## Verified versions

| Product | Version | Channel | Install mode | Source | Date |
|---|---|---|---|---|---|
| Red Hat Developer Hub (RHDH) | 1.10.2 | **fast** (=`fast-1.10`) | AllNamespaces | packagemanifest `rhdh` (live); versions.yaml | 2026-07-09 |
| Backstage CR | `rhdh.redhat.com/v1alpha4` (also `v1alpha5` served) | — | — | CSV owned CRDs (live) | 2026-07-09 |
| Developer Lightspeed for RHDH | ships w/ 1.9+ (dynamic plugin) | — | plugin + 2 sidecars | docs.redhat.com RHDH 1.9 | 2026-07-09 |
| Red Hat build of Keycloak (rhbk) | catalog **26.6.4-opr.1** (`stable-v26.6`); **live IdP instance 26.4.13** | — | — | packagemanifest + live `Keycloak/keycloak` | 2026-07-09 |
| Gitea (in-cluster) | operator v2.1.0 | — | — | live CSV; versions.yaml | 2026-07-09 |

Cluster reality (verified live 2026-07-09):

- **Workshop attendees are HTPasswd users.** `oauth/cluster` has two IdPs: `rhbk` (OpenID — backs `admin`) and **`workshop-users` (HTPasswd)** → `user1..user8` identities `workshop-users:userN`; group `workshop-attendees` = user1..8. **user1..8 are NOT in the rhbk `sso` realm** (which holds only client `idp-4-ocp`).
- **Cluster IdP rhbk** = `Keycloak/keycloak` (`k8s.keycloak.org/v2alpha1`, ns `keycloak`, 1 instance, postgres, route `sso.apps.cluster-example...`), realm import `sso`. **Reusing this realm for RHDH is NOT sane** — attendees aren't in it and it backs cluster login (do not co-opt).
- **`Backstage` CR** is deliberately minimal by default (alm-example = name+labels only). Real config = `spec.application.appConfig.configMaps[]`, `spec.application.dynamicPluginsConfigMapName`, `spec.application.extraEnvs`, `spec.application.extraFiles` (docs.redhat.com RHDH configuring). RHDH operator deploys a **bundled local PostgreSQL** by default (no separate DB component needed at workshop scale).
- **Developer Lightspeed for RHDH** = dynamic plugin added to the `dynamic-plugins-rhdh` ConfigMap + **two sidecars** (Lightspeed Core Service + Llama Stack); inference endpoint is MaaS-wireable (docs.redhat.com RHDH 1.9 "Interacting with Developer Lightspeed").
- **Gitea** present (`gitea-operator.v2.1.0`); org `parasol`, per-user forks are the convention. GitHub/GitLab are RHDH first-class; **Gitea needs `integrations.gitea` + the community `publish:gitea` scaffolder module** (backstage `scaffolder-backend-module-gitea`).
- **Capacity**: ~44 CPU / ~72Gi free on workers (as M08) — comfortably fits one shared RHDH.

## Spec deltas

- **Auth** — spec is agnostic; grounded answer: **RHDH → OpenShift OAuth** (attendees are htpasswd OpenShift users), **not** the rhbk `sso` realm. Realm reuse would require adding attendees to a realm that backs cluster login — rejected.
- **Backstage CR version** — older docs/mining use `rhdh.redhat.com/v1alpha3`; the 1.10 operator serves **`v1alpha4`/`v1alpha5`**. Author `v1alpha4`.
- **"[ADS]"** = RHADS; RHDH + Developer Lightspeed are the developer-experience half of the same suite as M08 (developers.redhat.com RHADS overview). Consistent tagging across M08/M11.
- **Gitea scaffolder is not first-class** — golden-path *publish* to Gitea needs the community `publish:gitea` action loaded as a dynamic plugin; supported status in RHDH 1.10 is unconfirmed → `TODO(verify-on-cluster)`, with generic-`url` catalog registration as the robust fallback.
- **Developer Lightspeed adds real weight** (2 sidecars + MaaS dependency) — treat as an optional section that degrades gracefully (mirror M01 Lightspeed 403 handling), not a hard requirement.

## Approach recommendations (≤5)

1. **Single shared RHDH** (platform layer, `pp-portal`) with **OpenShift OAuth sign-in** so user1..8 log in with their console creds; keep RBAC light (all attendees read the shared Parasol catalog + run templates) — strict per-user catalog namespacing is overkill; document the trade-off.
2. **Register Parasol catalog via `catalog.locations` type `url`** pointing at raw Gitea `catalog-info.yaml` (works for any git host, avoids the Gitea-integration gap for catalog *read*); use `integrations.gitea` + `publish:gitea` only for the scaffolder *write*.
3. **Golden-path template** = a Backstage Software Template that scaffolds a **Quarkus JDK-21** service skeleton + PaC pipeline + Argo app + devfile into the **user's Gitea org**; verify `publish:gitea` loads, else fall back to `publish:git`/generic (`TODO(verify)`).
4. **Developer Lightspeed = optional [ADS] section** wired to the MaaS endpoint (`{maas_endpoint}`, `apitoken` secret — same contract as M01/M06); degrade to "unavailable" if the key expired, don't block the module.
5. **TechDocs = local builder** (in-Backstage, no external S3) to keep the module simple; note the external-builder option in wrap-up.

## Exercise arc (Parasol framing · 75 min: ~15 concept + ~55 hands-on)

Hook: *"A new engineer joins Parasol's claims team — day one, they need a service wired to pipeline, GitOps, and Dev Spaces without learning nine tools first."*

1. `[~10m]` **Browse the catalog** — find `parasol-claims` Component, its API, owner, docs, and its System; see the org map.
2. `[~15m]` **Run "New Parasol microservice" template** — fill a form → watch it create a **Gitea repo + PaC pipeline + Argo Application + Dev Spaces link** in the user's org.
3. `[~10m]` **Hands-free delivery** — change code in the scaffolded repo → PaC pipeline + Argo sync run without touching YAML ("modules 2-9 behind one button").
4. `[~10m]` **TechDocs** — edit docs-as-code; render in RHDH.
5. `[~10m]` **Developer Lightspeed** — ask about the component (optional/[ADS]).

Demo arc: template → running-governed-service in 10 min. When-not-to-use (wrap-up): IDP maintenance cost, template sprawl, golden-path-as-cage vs paved-road.

## NEW platform stack — `pp-portal` (stacks/portal/) — fully specified

- **`components/rhdh`** — `Subscription` (name/pkg `rhdh`, channel **`fast`** =v1.10.2, ns `rhdh-operator` or `openshift-operators`, source `redhat-operators`) + AllNamespaces `OperatorGroup`; `Backstage` CR `developer-hub` (`rhdh.redhat.com/v1alpha4`, ns `rhdh`) referencing:
  - ConfigMap **`app-config-rhdh`** — `app.baseUrl`/`backend.baseUrl` (RHDH route), `auth.providers` (OpenShift OAuth), `signInPage`, `integrations.gitea:[{host: gitea-gitea.apps..., baseUrl}]`, `catalog.locations:[{type: url, target: <raw gitea catalog-info URLs>}]`, `catalog.rules`. Exact `auth.providers.*` keys `TODO(verify-at-build)` (docs.redhat.com RHDH 1.9 auth; 403 on WebFetch).
  - ConfigMap **`dynamic-plugins-rhdh`** — enable: TechDocs, `scaffolder-backend-module-gitea` (`TODO(verify)` supported/community), Developer Lightspeed plugin (optional).
  - `spec.application.{appConfig.configMaps,dynamicPluginsConfigMapName,extraEnvs}` wire the above (live CSV fields).
  - Wave 2 CR, `SkipDryRunOnMissingResource=true`.
- **Secret contracts** (documented per component, never in git — like `components/openshift-lightspeed/README.md`): `rhdh-oauth` (OpenShift OAuth client — via `OAuthClient` CR or registered secret), `rhdh-gitea` (Gitea token for scaffolder publish), `rhdh-lightspeed` (MaaS `apitoken`, optional).
- **No separate Postgres component** — RHDH operator's bundled local DB suffices at workshop scale.
- **Footprint (shared, one instance; validate with `oc adm top`)**: Backstage ~1 CPU / 2Gi req, ~2 CPU / 2.5-3Gi limit; bundled Postgres ~0.5 CPU / 1Gi; **+Developer Lightspeed sidecars ~+1 CPU / +1.5-2Gi** → **~2.5-3.5 CPU / 5-6Gi total** (docs.redhat.com RHDH 1.9 sizing — exact table `TODO(verify)`). Single shared instance is the right shape; per-user isolation via each user's own Gitea org, not per-user RHDH.

## Entry-state requirements — `gitops/entry-states/m11/` (per-user, light)

RHDH itself is shared platform (pp-portal), so the entry state is mostly Gitea seeding + catalog registration:

- Hook Jobs (m06 seed pattern): ensure the user's Gitea org has (a) the **golden-path template repo**, (b) `parasol-claims`/`parasol-web` forks each carrying **`catalog-info.yaml`**; register a per-user `catalog.location` (or rely on shared org-scan).
- No per-user RHDH namespace; scaffolder target = user's Gitea org + `{user}-dev`/`{user}-cicd` (workshop-layer ns).
- `ws-meta.yaml`: purge the user's scaffolded repos/apps on reset for idempotent re-runs (`TODO`: scaffolder idempotency per user — spec watchout).

## App requirements

- **`catalog-info.yaml`** for `parasol-claims`, `parasol-web`, `parasol-notifications` (Backstage `Component`/`API`/`System` entities, `spec.owner: parasol`, links to pipeline/Argo/Dev Spaces) — net-new, small.
- **Golden-path Software Template** (`parasol-service-template`): scaffolds a minimal **Quarkus 3.33 / JDK-21** service (pom `release=21`, UBI9 openjdk-21 Containerfile, health/metrics/OTel on — mirror `apps/parasol-claims` conventions) + PaC `.tekton/` + Argo `Application` + `devfile.yaml` (mirror `apps/parasol-claims/devfile.yaml`, JDK-21 pin). Net-new content/app work. Mine the *shape* of `rh-mad-workshop/coolstore-software-templates`.

## Mining results

- `adv-app-platform-demo-showroom` **M4** (Developer Hub + Software Catalog + Developer Lightspeed + self-service) → catalog + golden-path narrative, screenshot set, `.Section N` nav pattern (oldcontent-mining-index §4). License=none → ideas only.
- `rh-mad-workshop/coolstore-software-templates` + `mad-dev-guides-m7` → **RHDH Software Template shape** and per-module dev-guide structure (oldcontent-mining-index §2b, §3). Discard 3scale/RH-SSO.
- `redhat-ads-tech/parasol-insurance` → domain model for `catalog-info.yaml` entities (Claim/Email services) (oldcontent-mining-index §3).
- Tech: docs.redhat.com RHDH 1.7/1.9 (Authentication, Configuring, Sizing, Interacting-with-Developer-Lightspeed, About-Software-Templates); backstage `scaffolder-backend-module-gitea` README.

## Open risks & feasibility verdicts

- **LAB-VIABLE**: shared RHDH + catalog browse; OpenShift OAuth sign-in (exact keys `TODO`); TechDocs local; template scaffold **if** `publish:gitea` loads.
- **LAB-VIABLE-OPTIONAL**: Developer Lightspeed for RHDH (2 sidecars + MaaS) — degrade gracefully; or make it [INSTRUCTOR-DEMO].
- **CONTINGENT**: golden-path publish to Gitea depends on `publish:gitea` dynamic-plugin availability in RHDH 1.10 — **top build risk**; fallback = generic `publish:git`/`url`. Verify first.
- **CUT/KEEP-LIGHT**: strict per-user catalog RBAC namespacing (overkill; use shared read + per-user Gitea org).
- RHDH auth keys, sizing table, and gitea-plugin support are `TODO(verify-on-cluster)` (docs.redhat.com blocked WebFetch 403; confirm on cluster at build).
- Template idempotency per user across `ws reset` (spec watchout) — design scaffold + purge to be re-runnable.
- rhbk live instance is **26.4.13** (behind catalog 26.6.4) — irrelevant to RHDH (uses OpenShift OAuth) but note if any realm work is added later.

## Builder appendix — grounded config skeleton (live CRD fields 2026-07-09)

```yaml
apiVersion: rhdh.redhat.com/v1alpha4        # live: operator serves v1alpha4 + v1alpha5
kind: Backstage
metadata: {name: developer-hub, namespace: rhdh}
spec:
  application:
    appConfig: {configMaps: [{name: app-config-rhdh}]}
    dynamicPluginsConfigMapName: dynamic-plugins-rhdh
    extraEnvs: {secrets: [{name: rhdh-gitea}, {name: rhdh-lightspeed}]}   # secret contracts
# app-config-rhdh (ConfigMap) carries:
#   auth.providers.<openshift-oauth>  + signInPage        # TODO(verify exact keys, RHDH 1.9 auth doc)
#   integrations.gitea: [{host: gitea-gitea.apps.<domain>, baseUrl: https://...}]
#   catalog.locations: [{type: url, target: https://<gitea>/parasol/parasol-claims/raw/branch/main/catalog-info.yaml}]
# dynamic-plugins-rhdh (ConfigMap): techdocs, scaffolder-backend-module-gitea (TODO verify), developer-lightspeed (optional)
```
