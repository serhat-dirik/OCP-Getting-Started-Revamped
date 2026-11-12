# component: rhdh

Red Hat Developer Hub (RHDH / Backstage) — the developer portal for **M12 Developer Hub & Golden
Paths [ADS]**. A single shared instance: the software catalog + the golden-path Software Template are
browsed and run by every attendee.

## What's in here

| File | Why |
|---|---|
| `namespace.yaml` | `rhdh` — the Backstage CR, config, bundled PostgreSQL, and route live here |
| `app-config.yaml` | `app-config-rhdh` ConfigMap — guest auth (default), redirect sign-in flow, the Gitea integration, and the Parasol catalog locations, appended to the operator's base app-config |
| `dynamic-plugins.yaml` | `dynamic-plugins-rhdh` ConfigMap — the default plugin set **plus** the Gitea scaffolder module (external dynamic plugin) and the bundled Keycloak catalog module (inert until configured) |
| `backstage.yaml` | the `developer-hub` Backstage CR (`rhdh.redhat.com/v1alpha4`), wiring the two ConfigMaps + the `rhdh-gitea` secret + the optional `rhdh-auth` secret + the route |

The RHDH **operator** is a separate component (`components/rhdh-operator`), installed at wave 0 of the
portal stack; this component (wave 1) is the instance.

## Auth: guest by default, any provider through the optional `rhdh-auth` Secret

**No parameters → guest sign-in**, the simplest honest default: one click, everyone reads the catalog
and runs templates. It needs `auth.providers.guest.dangerouslyAllowOutsideDevelopment: true` because
the RHDH image runs `NODE_ENV=production` (the guest provider refuses to start otherwise).

**Real identities → the optional Secret `rhdh/rhdh-auth`.** `backstage.yaml` adds it to the backend
container with `envFrom … optional: true` (a `spec.deployment.patch`, because `extraEnvs` cannot point
at an optional Secret). Every key becomes an env var, and Backstage reads `APP_CONFIG_<path>` env vars
as config overrides (JSON values are parsed), so the Secret can switch sign-in without touching git.
OIDC against a Keycloak realm, for example:

| Key | Value |
|---|---|
| `APP_CONFIG_auth_environment` | `production` — the sign-in page stops offering Guest |
| `APP_CONFIG_signInPage` | `oidc` — the only provider on the sign-in page |
| `APP_CONFIG_auth_providers_oidc` | `{"production":{"metadataUrl":"<issuer>/.well-known/openid-configuration","clientId":"…","clientSecret":"…","prompt":"auto","signIn":{"resolvers":[{"resolver":"preferredUsernameMatchingUserEntityName","dangerouslyAllowSignInWithoutUserInCatalog":true}]}}}` |
| `APP_CONFIG_catalog_providers_keycloakOrg` | optional: `{"default":{"baseUrl":"<keycloak>","realm":"…","loginRealm":"…","clientId":"…","clientSecret":"…","schedule":{"frequency":{"minutes":10},"timeout":{"minutes":3}}}}` — imports the realm's users and groups as catalog entities (the client's service account needs realm-management `query-users`, `view-users`, `query-groups`) |

The Keycloak client's redirect URI is `https://<rhdh route>/api/auth/oidc/handler/frame`. The pod reads
env at start: after creating or changing the Secret, delete the `backstage-developer-hub` pod.
`enableExperimentalRedirectFlow: true` (always on) makes sign-in navigate the page instead of opening a
popup, so it works inside an iframe. The guest provider stays enabled for API tokens
(`/api/auth/guest/refresh`) even when the sign-in page no longer shows it.

The workshop layer supplies this Secret from the cluster's Keycloak realm
(`gitops/workshop-config/templates/devhub-sso-client.yaml`); the portfolio itself never needs it.

## Gitea: in-cluster service address (no host injection)

Both the catalog reader and the scaffolder (`publish:gitea`) address Gitea by its **in-cluster service
URL** `gitea.ogsr-gitea.svc:3000` — stable on any cluster, so this component needs **no per-cluster domain
injection** (RHDH's backend, Dev Spaces, and the workshop terminal all reach it in-cluster). Verified
live 2026-07-11: catalog loads and the golden-path template publishes + registers end to end via the
service URL.

**Trade-off:** "view source" / scaffolded-repo links render as in-cluster URLs (not browser-clickable).
To make them browser-friendly, add a second `integrations.gitea` entry on the external route host,
discovered at runtime (a small hook) — tracked as an enhancement, not required for the lab flow.

## The Gitea scaffolder plugin (publish:gitea)

`publish:gitea` is **not bundled** in the RHDH 1.10.2 image. It is a **first-party**
`@backstage/plugin-scaffolder-backend-module-gitea` core module, installed here as an external dynamic
plugin (integrity-pinned) — **v0.2.19**, version-matched to the image (`@backstage/plugin-scaffolder-node
^0.13.0` vs the image's 0.13.1; 0.2.20+ need ^0.13.2+). Re-pin on RHDH upgrades. Verified live: loads
clean, `publish:gitea` runs. Note: the module publishes into a Gitea **organization** (it rejects a user
namespace) — the M12 entry state gives each attendee a `<user>-svcs` org; and its `repoContentsUrl`
output omits the branch, so the golden-path template registers with an explicit `catalogInfoUrl`.

## Developer Lightspeed is ON by default

RHDH 1.10.2 enables the **Developer Lightspeed** flavour by default (operator-level
`rhdh-flavour-lightspeed-config`, not a dynamic-plugin toggle) — it adds a `lightspeed-core` sidecar +
an `init-rag-data` init container. It **degrades gracefully** with no model wired (the assistant is
present but has no inference) and does not block the portal. Kept on (ample headroom); the M12
Lightspeed [ADS] section wires it to a MaaS endpoint. To slim the instance, disable the flavour at the
operator level.

## Secret contract — `rhdh-gitea`

The Gitea credentials the scaffolder + catalog reader use. Delivered as a contract, never in git.

| Field | Value |
|---|---|
| Namespace | `rhdh` |
| Name | `rhdh-gitea` (referenced by `backstage.yaml` `spec.application.extraEnvs.secrets`) |
| Key `GITEA_USERNAME` | a Gitea user that can create repos in the attendee orgs (the admin user works) |
| Key `GITEA_PASSWORD` | that user's password (or a token in the password field) |

Created **before** the Backstage CR reconciles (the pod will not start without it) and **refreshed on
every install** — both installers automate this (bootstrap/install.sh step 4b; helm/bootstrap's
ogsr-rhdh-gitea-secret hook Job), discovering the live values from the gitea CR. Create-or-refresh is
deliberate: the Gitea operator regenerates its admin password on reinstall, and a preserved secret
fossilizes into cohort-wide 401s (M12 G3, 2026-07-19). Manual equivalent:

```bash
GITEA_NS=ogsr-gitea
ADMIN_USER="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.spec.giteaAdminUser}')"
ADMIN_PASS="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.status.adminPassword}')"
oc create secret generic rhdh-gitea -n rhdh \
  --from-literal=GITEA_USERNAME="$ADMIN_USER" \
  --from-literal=GITEA_PASSWORD="$ADMIN_PASS"
```

## Footprint (live, ocp-ws-revamped 2026-07-11)

Single shared instance: Backstage backend + bundled PostgreSQL + the Developer Lightspeed sidecar.
Sized modestly; per-attendee isolation is each attendee's own Gitea org, not a per-user RHDH. See the
portal stack README for the measured numbers.

## Verify

```bash
oc get csv -n rhdh-operator | grep rhdh                          # operator Succeeded
oc get backstage developer-hub -n rhdh                           # Deployed
oc get pods -n rhdh                                              # backstage + psql Running
RT=$(oc get route backstage-developer-hub -n rhdh -o jsonpath='{.spec.host}')
curl -ks -o /dev/null -w '%{http_code}\n' "https://${RT}/"       # 200
# with rhdh-auth: the sign-in start redirects to the Keycloak realm with your client (302, Location …/protocol/openid-connect/auth?…client_id=…)
curl -ks -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://${RT}/api/auth/oidc/start?env=production&flow=redirect&redirectUrl=https://${RT}/"
# guest token (API only when rhdh-auth is set), then catalog + actions:
TOKEN=$(curl -ks "https://${RT}/api/auth/guest/refresh" | python3 -c 'import sys,json;print(json.load(sys.stdin)["backstageIdentity"]["token"])')
curl -ks -H "Authorization: Bearer $TOKEN" "https://${RT}/api/catalog/entities?limit=400"   # parasol-* components
curl -ks -H "Authorization: Bearer $TOKEN" "https://${RT}/api/scaffolder/v2/actions"        # publish:gitea present
```
