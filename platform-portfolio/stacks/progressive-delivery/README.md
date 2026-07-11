# stack: progressive-delivery

The platform prerequisite for **M10 — GitOps at Scale & Progressive Delivery [OCP]**. Provisions the
**cluster-scoped Argo Rollouts controller** (one `RolloutManager` per cluster — PM decision
2026-07-09; no other module claims Rollouts) as an Argo CD app-of-apps. Workshop-agnostic: any
OpenShift 4.20+ cluster on OpenShift GitOps 1.13+ gets a working Rollouts controller from this one
stack. Everything M10-specific (per-user prod overlays, ApplicationSets, analysis knobs) lives in the
workshop layer / entry states ON TOP — never here.

```bash
./argocd-bootstrap/install.sh --stacks progressive-delivery
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,progressive-delivery
```

## What it installs

| Component | Source | Config | Stack wave |
|---|---|---|---|
| `argo-rollouts` | — (ships WITH the GitOps operator; no separate Subscription) | `RolloutManager` (cluster-scoped) in `openshift-gitops` | 0 |

Argo Rollouts (`RolloutManager`/`Rollout`/`AnalysisTemplate` CRDs) is **GA since GitOps 1.13** and is
bundled with the already-installed OpenShift GitOps operator — this stack only creates the
`RolloutManager` CR, and the operator reconciles the controller Deployment + its cluster ClusterRoles.
The controller **image and version are defaulted by the operator** (`RELATED_IMAGE_ARGO_ROLLOUTS_IMAGE`)
so the operator upgrade path is never pinned.

## Two design decisions (verified live 2026-07-11)

1. **Why `openshift-gitops` and not a dedicated namespace.** A cluster-scoped `RolloutManager`
   (`namespaceScoped: false`) is **gated** by the operator: outside its default namespace it is
   rejected with `status: InvalidRolloutManagerNamespace` unless that namespace is added to the
   operator Subscription's `CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES` env. `openshift-gitops` (the
   operator's default instance namespace) is **implicitly allowed** — the same CR there goes
   `Available` with **no Subscription edit**. Placing the controller there keeps this component purely
   declarative and never touches the fable-owned `argocd-bootstrap` operator install. (A dedicated
   `argo-rollouts` namespace would force an operator-Subscription patch → operator pod restart on
   every cluster → an M10 concern leaking into the core bootstrap. Rejected.)

2. **No traffic/metric plugins (pod-ratio canary + job-provider analysis).** The `RolloutManager`
   ships with **no `spec.plugins`**. The core M10 lab teaches canary + blue-green + automated analysis
   + auto-rollback using **pod-ratio canary weighting** (Rollouts scales the canary/stable ReplicaSets
   to approximate `setWeight`) and a **job-provider `AnalysisTemplate`** — both fully self-contained.
   The OpenShift **Route traffic-router plugin** (real request-level `%` via `Route.alternateBackends`)
   is supported (GitOps 1.13+) but requires the controller to **download an external plugin binary**
   (`trafficManagement[].location` is an `http(s)://` URL) at start, plus `ignoreDifferences` on the
   Argo-managed Route — an internet dependency and out-of-sync noise that hurts "installs cleanly on
   ANY cluster." It is documented as an **optional enhancement**, not the default. See the
   `## Route traffic-plugin` note below to enable it.

## How it serves M10

- **ApplicationSets / sync-waves / promotion** need no controller — they are core Argo CD, already
  present via the student instance (ADR-0002). This stack is specifically the **Rollouts** half.
- **Canary + blue-green + automated analysis + auto-rollback (LAB):** the attendee converts the
  `{user}-prod` claims Deployment to a `Rollout` (canary steps 20/50/100 with an `AnalysisTemplate`),
  then deliberately ships a bad revision and watches the controller **auto-roll-back** at the failed
  analysis step. Served by this one cluster-scoped controller for every `{user}-prod`.

## Route traffic-plugin (optional enhancement — off by default)

To teach real request-level traffic splitting, add to `components/argo-rollouts/rollout-manager.yaml`:

```yaml
spec:
  plugins:
    trafficManagement:
      - name: argoproj-labs/openshift   # must match the plugin's own required name
        location: https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-openshift/releases/download/<vX.Y.Z>/rollout-trafficrouter-openshift-<os>-<arch>
        # sha256: <checksum>            # pin in production
```

Then the prod `Rollout` sets `spec.strategy.canary.trafficRouting.plugins.argoproj-labs/openshift`
with the managed `Route`, and the Argo Application ignores the plugin's writes:
`spec.ignoreDifferences: [{group: route.openshift.io, kind: Route, jsonPointers: [/spec/alternateBackends, /spec/to/weight]}]`.
**Verify the exact release coordinates + name at enable time** — this is the one internet-dependent
piece the default deliberately avoids.

## The M10 entry-state seam (NOT installed here)

This stack is workshop-agnostic. The **per-user** wiring is the M10 entry state
(`gitops/entry-states/m10/`) and layers on top: the M09 end state pre-materialized (claims
GitOps-managed in `{user}-dev`/`stage`), the `{user}/claims-config` fork extended with a `rollouts/`
source (Rollout + `AnalysisTemplate` + `ApplicationSet`), and a per-user analysis SA in `{user}-prod`.

## Verify

```bash
oc get rolloutmanager argo-rollouts -n openshift-gitops -o jsonpath='{.status.phase}{"\n"}'   # Available
oc get deploy argo-rollouts -n openshift-gitops                                                # 1/1
oc get clusterrole argo-rollouts                                                               # cluster-scoped RBAC exists
oc get application pp-argo-rollouts -n openshift-gitops                                         # Synced/Healthy
```

## Uninstall

Delete the stack Application (`oc delete application pp-argo-rollouts -n openshift-gitops`) — prune
removes the `RolloutManager`, and the operator garbage-collects the controller Deployment + its
ClusterRoles.
