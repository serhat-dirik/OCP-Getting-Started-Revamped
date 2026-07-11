# stack: portal

The platform prerequisite for **M11 — Developer Hub & Golden Paths [ADS]**. Installs **Red Hat
Developer Hub (RHDH)** as an Argo CD app-of-apps: a single shared developer portal with the Parasol
software catalog and a golden-path Software Template that scaffolds a new microservice into the
attendee's Gitea org. One shared instance — never per-user; per-attendee isolation is each attendee's
own Gitea org (materialized by the M11 entry state).

```bash
./argocd-bootstrap/install.sh --stacks portal
# together with the dev-loop base (Gitea + pipelines live in core-devtools):
./argocd-bootstrap/install.sh --stacks core-devtools,portal
```

## What it installs

| Component | Operator (channel) | Config | Stack wave |
|---|---|---|---|
| `rhdh-operator` | `rhdh` (`fast` = v1.10.2) | AllNamespaces OperatorGroup (the only mode RHDH supports) | 0 |
| `rhdh` | — (uses the operator) | `Backstage` CR `developer-hub` (`rhdh.redhat.com/v1alpha4`) + guest auth + Gitea integration + Parasol catalog + the Gitea scaffolder dynamic plugin | 1 |

Wave-serialized: the operator (wave 0) registers the `backstages.rhdh.redhat.com` CRD before the
instance (wave 1) syncs. The instance app carries `SkipDryRunOnMissingResource=true` for the cold-start
race.

## Prerequisite: in-cluster Gitea

The portal reads its catalog from, and scaffolds into, the in-cluster **Gitea** (`gitea.gitea.svc:3000`,
the `core-devtools` stack). The `rhdh-gitea` secret (Gitea credentials) is a **contract** created before
the instance reconciles — see `components/rhdh/README.md`. In the workshop the credentials are the Gitea
admin account; the workshop bootstrap discovers them and creates the secret.

## How the pieces serve M11 (verified live 2026-07-11)

- **Catalog browse (LAB beat 1):** `catalog.locations` register the `parasol/*` repos' `catalog-info.yaml`
  (parasol-claims/-web/-notifications, their APIs, the `parasol-insurance` System) — served from the
  in-cluster Gitea, so no cluster domain is baked in.
- **Golden path (LAB beat 2):** the **"New Parasol microservice"** Software Template scaffolds a
  Quarkus/JDK-21 service and **publishes it to the attendee's Gitea org** via `publish:gitea`, then
  registers it in the catalog. Proven end to end live (repo + full skeleton pushed, Component registered).
- **publish:gitea** is not bundled in RHDH 1.10.2 — it is the first-party
  `@backstage/plugin-scaffolder-backend-module-gitea` installed as an external dynamic plugin (v0.2.19,
  version-matched). See `components/rhdh/README.md`.
- **Auth:** guest sign-in (simplest honest workshop auth); OpenShift OAuth is the documented hardening
  path.
- **Developer Lightspeed** ships **on by default** (operator flavour) and degrades gracefully without a
  model; the M11 [ADS] section wires it to MaaS.

## Footprint (live, ocp-ws-revamped 2026-07-11, idle)

| Pod | CPU | Memory |
|---|---|---|
| `backstage-developer-hub` (backend + Lightspeed sidecar) | ~27m | ~970Mi |
| `backstage-psql-developer-hub` (bundled PostgreSQL) | ~15m | ~280Mi |
| `rhdh-operator` | ~7m | ~150Mi |

Idle total ~50m CPU / ~1.4Gi; peaks during catalog refresh + scaffolds. Workers had ample headroom
(5–10% CPU, 20–48% memory). A single shared instance is the right shape — do not scale per-user. First
start takes a few minutes (the Lightspeed `init-rag-data` init container).

## The M11 entry-state seam (NOT installed here)

This stack is a shared platform. The **per-user** wiring is the M11 entry state
(`gitops/entry-states/m11/`, built separately) and layers on top: it gives each attendee a dedicated
`{user}-svcs` Gitea org to scaffold into and keeps it a clean slate across `ws reset`.

> Platform/workshop split note: the Parasol `catalog.locations` in `components/rhdh/app-config.yaml` are
> workshop-specific content. They are kept in the portal component for this pass (build-note scope);
> a clean follow-up moves them to a workshop-layer catalog registration so the portal component is fully
> workshop-agnostic. Flagged to the PM.

## Verify

```bash
oc get applications -n openshift-gitops | grep -E 'pp-portal|pp-rhdh'   # Synced/Healthy
oc get csv -n rhdh-operator | grep rhdh                                 # Succeeded
oc get backstage developer-hub -n rhdh                                  # Deployed
RT=$(oc get route backstage-developer-hub -n rhdh -o jsonpath='{.spec.host}')
curl -ks -o /dev/null -w '%{http_code}\n' "https://${RT}/"              # 200
```

## Uninstall

Delete the stack Applications (`oc delete application pp-rhdh pp-rhdh-operator -n openshift-gitops`) —
prune removes the components. The `rhdh-gitea` secret is left in place (recreate on reinstall).
