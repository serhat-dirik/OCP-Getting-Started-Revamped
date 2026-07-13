# stack: mta

The platform prerequisite for **M22 — Application Modernization (MTA + AI)**. Installs the shared,
cluster-wide **Migration Toolkit for Applications 8 (MTA)** — the `mta-operator` + a single **Tackle**
Hub — as an Argo CD app-of-apps. Everything here is a **single shared install** — never per-user;
per-user modernization state (`{user}-modernize` + the seeded `parasol-legacy-claims` repo + the MTA
Application entry) is the workshop layer / M22 entry state on top.

```bash
./argocd-bootstrap/install.sh --stacks mta
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,mta
```

## What it installs

| Component | Operator (channel) | Config CR | Wave |
|---|---|---|---|
| `mta` | `mta-operator` (`stable-v8.1` = v8.1.2) | `Tackle` (Hub/UI/assessment/analysis, openshift-mta) | 0 |

**Net-new like the mesh/serverless stacks.** MTA is not on a stock cluster. The community
`konveyor-operator` / `windup-operator` are **banned** (community-operators) — this uses the Red Hat
`redhat-operators` catalog. `mta-operator` is **OwnNamespace-only** (AllNamespaces unsupported —
verified live 2026-07-13), so the OperatorGroup targets `openshift-mta`.

## The Tackle Hub

One `Tackle` CR (`tackle.konveyor.io/v1alpha1`, name `tackle`) brings up the Hub: portfolio inventory,
questionnaire assessment, analysis (analyzer-lsp, YAML rules, `cloud-readiness`/`openshift`/
`containerization` targets), reports (issues, story points, hints), and the web console. The CR is
minimal (`feature_auth_required: false` = an open Hub, the simplest attendee on-ramp behind the
OpenShift route). MTA's per-user UI RBAC is weak, so tenancy is name-prefixed Applications + per-user
Git repos in the workshop layer, not MTA logins.

**Developer Lightspeed for MTA ([ADS]) is NOT configured on the Tackle CR** — verified live (v8.1.2)
that the CR carries no genAI provider/model fields. The AI refactor's LLM is wired in the VS Code
extension per workspace (MaaS endpoint/model + key), by the M22 entry state.

## Namespaces

| Namespace | Holds |
|---|---|
| `openshift-mta` | the mta-operator + the Tackle Hub: `mta-hub` + `mta-ui` pods, DB embedded on a PVC. No separate Postgres; no Keycloak pod while `feature_auth_required: false` (the RHBK operator installs as a dependency but runs no instance); the server-side Kai/AI solution server stays gated (`KaiSolutionServerReady=False`) until its API-keys Secret exists. Verified v8.1.2 on-cluster 2026-07-13 (no `pathfinder` — that was MTA 6). |

## The M22 entry-state seam (NOT installed here)

Workshop-agnostic by design. The **per-user** wiring lives in the workshop layer, on top of this
shared Hub:

- `gitops/workshop-config/templates/per-user-modernize.yaml` — the `{user}-modernize` namespace
  (quota/limits/RBAC).
- `gitops/entry-states/m22/` — the per-user `parasol-legacy-claims` Gitea fork (the migration target),
  the MaaS credentials for Developer Lightspeed, and the entry marker; `ws solve` deploys the
  modernized service.

## Verify

```bash
oc get applications -n openshift-gitops -l portfolio.redhat.com/component | grep mta
oc get csv -n openshift-mta | grep mta-operator          # Succeeded
oc get tackle tackle -n openshift-mta                     # reconciled
oc get pods -n openshift-mta                              # hub / ui / keycloak / postgres Running
oc get route -n openshift-mta                             # the MTA web console URL
```

> Verified against the live catalog on OCP 4.21.22 (2026-07-13, read-only `oc get packagemanifest`):
> default channel `stable-v8.1` → `mta-operator.v8.1.2`, OwnNamespace/SingleNamespace/MultiNamespace
> install modes (AllNamespaces unsupported), owned CRDs (Tackle/Addon/Extension/Schema/Task), and the
> Tackle `alm-example` (minimal `feature_auth_required`). Full install verification (operator Succeeded
> + the Tackle Hub UI/hub/keycloak/postgres pods Running) runs post-merge via Argo — see the M22 build
> report for why on-cluster install was merge-gated in the build session.
