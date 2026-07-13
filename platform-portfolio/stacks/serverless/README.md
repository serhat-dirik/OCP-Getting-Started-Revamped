# stack: serverless

The platform prerequisite for **M19 — Serverless Zero-to-Hero** (and **M20 — Eventing Deep-Dive**).
Installs the shared, cluster-wide **OpenShift Serverless** control plane — **Knative Serving** (request-
driven compute, scale-to-zero, Kourier ingress) and **Knative Eventing** (sources / brokers / triggers,
in-memory broker) — as an Argo CD app-of-apps. Everything here is a **single shared install** — never
per-user; the per-user `{user}-dev` claims-processor ksvc + eventing wiring is the M19 entry state on top.

```bash
./argocd-bootstrap/install.sh --stacks serverless
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,serverless
```

## What it installs

| Component | Operator (channel) | Config CRs | Wave |
|---|---|---|---|
| `serverless` | `serverless-operator` (`stable-1.37` = v1.37.1, Knative 1.17) | `KnativeServing` (knative-serving) + `KnativeEventing` (knative-eventing) | operator 0, CRs 1 |

The operator channel is **pinned to `stable-1.37`** (not bare `stable`, which floats to the newest minor
and will drift — the M18 OSSM lesson, commit `3302c14`). `versions.yaml` `serverless` is the source of
truth for the pin.

## Namespaces

| Namespace | Holds |
|---|---|
| `openshift-serverless` | the serverless-operator (AllNamespaces) |
| `knative-serving` | Knative Serving control plane (activator, autoscaler, controller, webhook, net-kourier) |
| `knative-eventing` | Knative Eventing control plane (controller, webhook, in-memory-channel + MT-broker) |
| `knative-serving-ingress` | **operator-created** — the per-ksvc edge OpenShift Routes (Kourier) |

## Routing (the load-bearing design point)

Knative **auto-creates the external edge-terminated OpenShift Route** for every ksvc (in
`knative-serving-ingress`, backed by Kourier); the browser URL is `ksvc.status.url` (HTTPS by default).
The project's standing "browser Routes must be `oc create route edge … --insecure-policy=Allow`" rule
(MEMORY `browser-routes-need-edge`) **does NOT apply to a ksvc** — hand-rolling a Route for a Knative
Service fights the operator. This is the one documented exception to the edge-route convention.

## Internal-registry images

`KnativeServing.spec.config.deployment.registries-skipping-tag-resolving` lists the OpenShift internal
registry (`image-registry.openshift-image-registry.svc:5000`) so ksvcs can deploy internal-registry
images by **tag**: Knative skips tag→digest resolution and the kubelet pulls at pod-start via the
namespace's image-puller grant. Cluster-agnostic (the internal-registry Service DNS is identical on
every OpenShift cluster).

## The M19 entry-state seam (NOT installed here)

Workshop-agnostic by design. The **per-user** wiring lives in the workshop layer, on top of this shared
control plane:

- `gitops/entry-states/m19/` — a scale-to-zero `parasol-claims` **ksvc** + ephemeral `claims-db` + a
  demo-client load pod in `{user}-dev`; `ws solve` adds a second revision + tag-based traffic split and
  the eventing taste (Broker → PingSource → Trigger → ksvc).
- `{user}-dev` (namespace, quota, limits, RBAC, image-puller grant) is workshop-config-owned — this
  stack never touches it (Rule 13).

None of that belongs in this portfolio stack — it is user-/story-specific and stays in the workshop layer.

## Footprint

Serving control plane (~5 pods) + Eventing control plane (~5 pods) + net-kourier (2 pods) + the operator.
ksvc workloads scale to **zero** when idle, so the per-attendee cost is only the active-request window.

## Verify

```bash
oc get applications -n openshift-gitops -l portfolio.redhat.com/component=serverless
oc get csv -n openshift-serverless | grep serverless-operator            # Succeeded
oc get knativeserving knative-serving -n knative-serving                 # Ready=True
oc get knativeeventing knative-eventing -n knative-eventing              # Ready=True
oc get pods -n knative-serving ; oc get pods -n knative-eventing         # control planes up
```

> Verified on install 2026-07-13 (OCP 4.21.22): `serverless-operator.v1.37.1` stood up live;
> `KnativeServing`/`KnativeEventing` reconciled `Ready`, and a `parasol-claims:1.1` ksvc from the
> internal registry went Ready with an auto-created edge Route in `knative-serving-ingress`.
