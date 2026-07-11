# component: rhdh

Red Hat Developer Hub (RHDH / Backstage) — the developer portal for **M11 Developer Hub & Golden
Paths [ADS]**. A single shared instance: the software catalog + the golden-path Software Template are
browsed and run by every attendee.

## What's in here

| File | Why |
|---|---|
| `namespace.yaml` | `rhdh` — the Backstage CR, config, bundled PostgreSQL, and route live here |
| `app-config.yaml` | `app-config-rhdh` ConfigMap — guest auth, the Gitea integration, and the Parasol catalog locations, appended to the operator's base app-config |
| `dynamic-plugins.yaml` | `dynamic-plugins-rhdh` ConfigMap — the default plugin set **plus** the Gitea scaffolder module (external dynamic plugin) |
| `backstage.yaml` | the `developer-hub` Backstage CR (`rhdh.redhat.com/v1alpha4`), wiring the two ConfigMaps + the `rhdh-gitea` secret + the route |

The RHDH **operator** is a separate component (`components/rhdh-operator`), installed at wave 0 of the
portal stack; this component (wave 1) is the instance.

## Auth: guest sign-in (verified live)

Guest sign-in is the workshop default — the simplest honest choice: no per-attendee login friction, all
attendees read the shared catalog and run the template. It needs
`auth.providers.guest.dangerouslyAllowOutsideDevelopment: true` because the RHDH image runs
`NODE_ENV=production` (the guest provider refuses to start otherwise). Verified live 2026-07-11: guest
token issues, catalog + scaffolder APIs work.

**Hardening path (documented, not wired):** OpenShift OAuth sign-in — attendees are OpenShift HTPasswd
users, so `auth.providers.<oidc/oauth2Proxy>` against the cluster OAuth server maps them to Backstage
identities. Deferred: guest is sufficient for the catalog-browse + scaffold flow and far more robust for
a short workshop. Do **not** reuse the cluster's `rhbk` `sso` realm (attendees aren't in it; it backs
cluster login).

## Gitea: in-cluster service address (no host injection)

Both the catalog reader and the scaffolder (`publish:gitea`) address Gitea by its **in-cluster service
URL** `gitea.gitea.svc:3000` — stable on any cluster, so this component needs **no per-cluster domain
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
namespace) — the M11 entry state gives each attendee a `<user>-svcs` org; and its `repoContentsUrl`
output omits the branch, so the golden-path template registers with an explicit `catalogInfoUrl`.

## Developer Lightspeed is ON by default

RHDH 1.10.2 enables the **Developer Lightspeed** flavour by default (operator-level
`rhdh-flavour-lightspeed-config`, not a dynamic-plugin toggle) — it adds a `lightspeed-core` sidecar +
an `init-rag-data` init container. It **degrades gracefully** with no model wired (the assistant is
present but has no inference) and does not block the portal. Kept on (ample headroom); the M11
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

Created **before** the Backstage CR reconciles (the pod will not start without it). In this workshop the
credentials are the Gitea admin account the operator generates, so the workshop bootstrap discovers them
and creates the secret:

```bash
GITEA_NS=gitea
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
# guest token, then catalog + actions:
TOKEN=$(curl -ks "https://${RT}/api/auth/guest/refresh" | python3 -c 'import sys,json;print(json.load(sys.stdin)["backstageIdentity"]["token"])')
curl -ks -H "Authorization: Bearer $TOKEN" "https://${RT}/api/catalog/entities?limit=400"   # parasol-* components
curl -ks -H "Authorization: Bearer $TOKEN" "https://${RT}/api/scaffolder/v2/actions"        # publish:gitea present
```
