# stack: mesh

The platform prerequisite for **M18 — Service Mesh 3 & Advanced Gateways**. Installs the shared,
cluster-wide **OpenShift Service Mesh 3 (OSSM3, Sail)** control plane + **Kiali** as an Argo CD
app-of-apps. Everything here is a **single shared install** — never per-user; per-user enrollment
(`{user}-mesh` namespaces + the meshed Parasol app) is the workshop layer / M18 entry state on top.

```bash
./argocd-bootstrap/install.sh --stacks mesh
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,mesh
```

## What it installs

| Component | Operator (channel) | Config CRs | Wave |
|---|---|---|---|
| `service-mesh` | `servicemeshoperator3` (`stable-3.3` = v3.3.5) | `Istio` (istiod, revision `default`, istio-system) + `IstioCNI` (istio-cni) | 0 |
| `kiali` | `kiali-ossm` (`stable` = v2.27.1) | `Kiali` (istio-system, OpenShift OAuth) | 1 |

**Sidecar-default per ADR-0003** — no `ZTunnel` (ambient is an M18 concept + optional exercise, not the
platform baseline). SMCP/SMMR do **not** exist in 3.x (Sail uses `sailoperator.io/v1` — ban-clean). The
Istio build is pinned via `spec.version` in `components/service-mesh/istio.yaml` (versions.yaml
`service_mesh.istio_version`).

## Coexistence with the OpenShift Gateway API (the load-bearing design point)

This cluster already runs an **ingress-operator-managed istiod** in `openshift-ingress` (revision
`openshift-gateway`, Istio 1.27.x) that backs the `openshift-default` GatewayClass (M15's `gateway-api`
component). OSSM3 installs a **second, independent** istiod (revision `default`, Istio 1.28.x) in
`istio-system`. They coexist cleanly — verified live 2026-07-13, before + after installing OSSM3:

- **Only OSSM 2.x conflicts with the Gateway API, never 3.x** (Red Hat docs + live check). The shared
  `*.istio.io` CRDs (previously `ingress.operator.openshift.io/owned=true`) are applied **server-side**,
  so after OSSM3 installs they carry **mixed ownership** (some `ManagedByOLM`, some `ManagedByCIO`) —
  both managers apply the identical Istio v1 schema, so there is no value conflict and no revert war.
- **Expected benign warning:** the `openshift-default` GatewayClass reports `CRDsReady=False` with
  message *"CRDs have mixed ownership"* once OSSM3 is installed. This is a **warning, not a failure** —
  the ingress `ClusterOperator` stays `Available=True / Degraded=False`, the GatewayClass stays
  `Accepted=True / ControllerInstalled=True`, and the ingress istiod never restarts (verified live: 0
  restarts across the OSSM3 install). The ingress operator is designed to *detect and warn* about this
  coexistence rather than error. Do not treat `CRDsReady=False` as a broken Gateway API on a
  mesh+gateway cluster.
- **No double sidecar injection.** The ingress injector webhook requires `istio-injection DoesNotExist`
  and matches only revision `openshift-gateway`; an OSSM3 mesh namespace labelled `istio-injection=enabled`
  is therefore never touched by it. Different namespace, different revision, different webhook.
- **Scoped discovery.** `meshConfig.discoverySelectors` restricts the OSSM3 istiod to namespaces labelled
  `istio-discovery=enabled` (the `{user}-mesh` namespaces, labelled at creation by the workshop layer), so
  the shared control plane never builds config for system / Gateway / other-tenant namespaces.

If you install this stack on a cluster **without** the Gateway API active, nothing changes — OSSM3 stands
alone. If OSSM **2.x** is present, the GatewayClass goes Degraded (remove one or the other).

## Namespaces

| Namespace | Holds |
|---|---|
| `openshift-service-mesh-operator` | the Sail operator (AllNamespaces) |
| `openshift-kiali-operator` | the Kiali operator (AllNamespaces) |
| `istio-system` | istiod (control plane) + the Kiali workload |
| `istio-cni` | the `istio-cni-node` DaemonSet (privileged PSA) |

## The M18 entry-state seam (NOT installed here)

Workshop-agnostic by design. The **per-user** wiring lives in the workshop layer, on top of this shared
control plane:

- `gitops/workshop-config/templates/per-user-mesh.yaml` — creates each `{user}-mesh` namespace (labelled
  `istio-discovery=enabled`, quota/limits/RBAC), the discovery-scoped tenant of the shared istiod.
- `gitops/entry-states/m18/` — the un-meshed `parasol-web -> claims -> fraud -> db` app, a demo-client
  pod, and a legacy-partner TCP backend in `{user}-mesh`; `ws solve` adds enrollment + traffic management.

None of that belongs in this portfolio stack — it is user-/story-specific and stays in the workshop layer.

## Footprint

istiod (1 pod) + istio-cni (DaemonSet, 1 pod/node) + Kiali (1 pod) + the two operators. On the 6-node
build cluster: ~1 CPU / ~1.5Gi steady-state for the control plane; the per-attendee cost is the sidecars
(replicas=1 per service bounds ~proxies, ADR-0003). Revisit trigger (ADR-0003): flip to ambient+waypoints
if the sidecar budget can't absorb ×30 users.

## Verify

```bash
oc get applications -n openshift-gitops -l portfolio.redhat.com/component | grep -E 'service-mesh|kiali'
oc get csv -A | grep -E 'servicemeshoperator3|kiali'          # operators Succeeded
oc get istio default                                          # Ready=True, revision default
oc get istiocni default                                       # Ready=True
oc get istiorevision                                          # default -> InUse/Healthy
oc get kiali kiali -n istio-system                            # Successful
# coexistence: the Gateway API istiod must STILL be healthy
oc get gatewayclass openshift-default -o jsonpath='{.status.conditions}'   # Accepted=True
oc -n openshift-ingress get deploy istiod-openshift-gateway                # 1/1
```

> Verified on install 2026-07-13 (OCP 4.21.22): OSSM3 `servicemeshoperator3.v3.3.5` + Kiali
> `kiali-operator.v2.27.1` stood up live; `Istio`/`IstioCNI` reconciled `Ready` and the ingress-operator
> Gateway API istiod stayed healthy (Accepted=True) throughout — see the M18 build report / commit message
> for the full before/after coexistence evidence.
