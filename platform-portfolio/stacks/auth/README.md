# stack: auth

The platform backend for **M13 — Securing Apps with Keycloak `[OCP]`**. Installs a workshop-owned
**Red Hat build of Keycloak** (RHBK 26.6) instance as an Argo CD app-of-apps: its own operator, a
Keycloak CR, and a PostgreSQL. Workshop-agnostic — no users, no per-user realms, no cluster domain
baked in. Per-attendee `realm-{user}` imports are the **workshop layer's** job
(`gitops/workshop-config/templates/per-user-sso-realm.yaml`), seeded on top.

```bash
./argocd-bootstrap/install.sh --stacks auth
# with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,auth
# via the workshop bootstrap: set `auth: true` in bootstrap/vars.yaml (adds the stack AND seeds realms)
```

## What it installs

| Component | Operator (channel) | Config | Stack wave |
|---|---|---|---|
| `keycloak-operator` | `rhbk-operator` (`stable-v26.6` = v26.6.4-opr.1) | **OwnNamespace** OperatorGroup scoped to `sso-workshop` | 0 |
| `keycloak` | — (uses the operator) | `Keycloak` CR `sso-workshop` (1 instance, `k8s.keycloak.org/v2beta1`) + PostgreSQL 15 (PVC) + an edge Route | 1 |

Wave-serialized: the operator (wave 0) registers the `keycloaks`/`keycloakrealmimports` CRDs before the
instance (wave 1) applies the CR.

## Coexists with the cluster login IdP — never touches it

This cluster (and many RHDP/managed clusters) already runs an RHBK as the **console/admin login IdP**
in namespace `keycloak`. That instance is **READ-ONLY** and this stack leaves it strictly alone:

- **`rhbk-operator` supports only OwnNamespace/SingleNamespace** (verified live: `AllNamespaces=false`),
  so a workshop Keycloak in another namespace *requires* its own operator instance. Ours is scoped to
  `sso-workshop`; the login-IdP operator stays scoped to `keycloak`. Two independent installs, by design.
- The `keycloaks`/`keycloakrealmimports` CRDs are cluster-scoped and shared. Installing the newer 26.6
  operator **adds** a `v2beta1` served version *additively* (v2alpha1 still served + stored). Proven
  non-disruptive live: the login IdP `keycloak/keycloak` held `Ready=True HasErrors=False` and its `sso`
  realm import held `Done=True` throughout install + realm seeding.
- A dedicated namespace also sidesteps the FSC `TooManyOperatorGroups` collision (§5.4): the operator
  cannot pre-exist in a namespace this stack creates.

## Domain-free by design (replicable on any cluster)

The Keycloak CR sets **`hostname.strict: false` + `proxy.headers: xforwarded`** and disables the
operator's wildcard ingress; a **host-less edge `Route`** lets OpenShift auto-assign
`keycloak-sso-workshop.<ingress-domain>`. Keycloak resolves its issuer from the router's X-Forwarded
headers, so no cluster domain is hardcoded and tokens are issued for whatever domain the cluster has.
Edge TLS uses the cluster's default ingress certificate (Let's Encrypt on RHDP — publicly trusted, so
Quarkus/Java clients need no truststore config).

## Per-user realms are the workshop layer's job (and are import-once)

`realm-{user}` imports live in `gitops/workshop-config` (gated on `sso.enabled`), NOT here — the
portfolio stays workshop-agnostic (hard rule 2). Each realm ships the Parasol clients (public `parasol-web`
+ PKCE, bearer `parasol-claims`, bearer `parasol-fraud`, client-credentials `parasol-batch`), the
`claims-adjuster` role, and `adjuster`/`viewer` demo users.

> **Gotcha — KeycloakRealmImport is import-once** (verified live): the operator runs the import Job once
> and **skips a realm that already exists**; a changed CR does NOT re-import. Realms are therefore seeded
> complete + stable and survive `ws reset`. To genuinely change a seeded realm you must delete the realm
> (admin API) AND the import CR+Job, then re-apply. A `ws sso-reimport` helper is a tracked follow-up.

## Scope boundary — app login only

This stack backs the **application** login scenario (attendees protect the Parasol app with OIDC +
bearer tokens). It deliberately does **not** wire the OpenShift **console** OAuth to this Keycloak —
that is a cluster-OAuth change parked as a project-owner decision (the `[INSTRUCTOR-DEMO]` IdP-tie in
M13 references the existing `keycloak/sso` IdP read-only).

## Footprint (live, ocp-ws-revamped 2026-07-11, idle)

| Pod | notes |
|---|---|
| `sso-workshop-0` (Keycloak) | 1 instance; ~1 CPU burst at boot, settles low |
| `keycloak-db` (PostgreSQL 15) | 10Gi PVC on the default StorageClass |
| `rhbk-operator` | one per workshop instance (separate from the login-IdP operator) |

## Verify

```bash
oc get applications -n openshift-gitops | grep -E 'pp-keycloak'          # Synced/Healthy
oc get csv -n sso-workshop | grep rhbk                                   # Succeeded (v26.6.4)
oc get keycloak sso-workshop -n sso-workshop \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'    # True
KC=$(oc get route keycloak -n sso-workshop -o jsonpath='{.spec.host}')
curl -s "https://${KC}/realms/master/.well-known/openid-configuration" | head -c 80   # issuer JSON
# non-disruption: the login IdP must still be Ready
oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'  # True
```

## Uninstall

Delete the stack Applications (`oc delete application pp-keycloak pp-keycloak-operator -n
openshift-gitops`) — prune removes the components and the `sso-workshop` namespace. The cluster login
IdP in `keycloak` is untouched. (Per-user realms live in the workshop layer; remove them there.)
