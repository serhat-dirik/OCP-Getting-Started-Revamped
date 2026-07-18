# stacks/resilience — M22 Resilience, Multi-Cluster & DR

app-of-apps installed with `--stacks resilience`. Two children:

| App | Entitlement | Default | Purpose |
|---|---|---|---|
| `pp-oadp` (`components/oadp`) | `[OCP]` | **on** | OADP/Velero + in-cluster NooBaa S3 → backup / restore an app namespace incl. PVC data |
| `pp-service-interconnect` (`components/service-interconnect`) | `[ADD-ON]` | **off (commented out)** | Skupper v2 → cross-site L7 connectivity for M22's optional section |

## Enable the RHSI add-on

Only on a cluster whose catalog offers Skupper **v2** (channel `stable-2`):

```
oc get packagemanifest skupper-operator -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' | grep stable-2
```

If present, uncomment `- apps/service-interconnect.yaml` in `kustomization.yaml`. If absent (e.g. Cluster 2
/ km7vw, which tops out at `stable-1.9`), leave it off — OADP-only resilience is fully functional.

## Prerequisites

- **ODF / MCG (NooBaa)** for the in-cluster S3 backup target (`components/oadp` README).
- Synthetic node labels `workshop.redhat.com/zone={a,b,c}` for the M22 chaos-drill zone-spread narrative
  are applied by `bootstrap/install.sh` (workshop substrate, not the portfolio).

## Bootstrap wiring

`bootstrap/install.sh` appends `resilience` to the installed stacks when `resilience: true` in `vars.yaml`
(opt-in, like `auth`). The workshop layer then adds per-user `{user}-resilience` / `{user}-site-b`
namespaces (`gitops/workshop-config/templates/per-user-resilience.yaml`) and the M22 entry state.
