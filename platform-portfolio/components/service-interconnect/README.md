# components/service-interconnect — Red Hat Service Interconnect (Skupper v2)

Installs the **Skupper v2 operator** (`skupper-operator`, channel **`stable-2`**) — the L7 cross-site
connectivity layer for M22's optional `[ADD-ON]` section (link a service across namespaces/clusters
without a VPN or flat network). Entitlement `[ADD-ON]` (separate subscription); no `[OCP]` module depends
on it.

## Channel trap (do not get this wrong)

| Channel | Skupper | CRs | CLI |
|---|---|---|---|
| **`stable-2`** ✅ | **v2** | `skupper.io/v2alpha1` (Site/Listener/Connector/Link/AccessGrant/AccessToken) | `skupper system setup` |
| `stable`, `stable-1`, `stable-1.x` ❌ | v1 (legacy, v1.9.x) | v1 CRs | `skupper init` |

v1 and v2 CRs/CLI are **incompatible**. The `redhat-cop/gitops-catalog` overlay pins `stable` (v1) — do
**not** copy it. This component pins `stable-2`.

## Availability caveat (verified 2026-07-13)

Cluster 2 (km7vw) offers `skupper-operator` from the Red Hat catalog with channels only up to
`stable-1.9` — **no `stable-2`**. Sync this component **only** on a cluster whose packagemanifest lists
`stable-2`:

```
oc get packagemanifest skupper-operator -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' | grep stable-2
```

That is why `stacks/resilience` leaves this app **commented out** (opt-in) — OADP-only resilience installs
cleanly everywhere; RHSI is enabled where the catalog supports v2.
