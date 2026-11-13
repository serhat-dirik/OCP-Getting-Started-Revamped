# stacks/resilience — Resilience, Multi-Cluster & DR

App-of-apps installed with `--stacks resilience`. One child:

| App | Entitlement | Purpose |
|---|---|---|
| `pp-service-interconnect` (`components/service-interconnect`) | `[ADD-ON]` | Skupper v2: cross-site L7 connectivity for the module's optional section |

OADP (backup and restore) moved to its own `backup` stack on 2026-11-13 — no module uses it, and its ODF
prerequisite held `pp-oadp` Missing on every cluster without ODF. See `stacks/backup/README.md`.

## Prerequisites

- A catalog that offers Skupper **v2** (channel `stable-2` from `redhat-operators`):

  ```
  oc get packagemanifests -n openshift-marketplace --field-selector=metadata.name=skupper-operator \
    -o json | jq -r '.items[]|select(.status.catalogSource=="redhat-operators").status.channels[].name' | grep stable-2
  ```

  Without it (e.g. a catalog that tops out at `stable-1.9`), don't install this stack. The module's core
  labs run over the `mesh` stack and need nothing here.
- Synthetic node labels `workshop.redhat.com/zone={a,b,c}` for the chaos-drill zone-spread narrative are
  applied by `bootstrap/install.sh` (workshop substrate, not the portfolio).

## Bootstrap wiring

`bootstrap/install.sh` adds `resilience` when an enabled module lists it in `modules.yaml`
(resilience-multicluster-dr does), or when `resilience: true` is set in `vars.yaml`. The workshop layer then
adds per-user `{user}-resilience` / `{user}-site-b` namespaces
(`gitops/workshop-config/templates/per-user-resilience.yaml`) and the module's entry state.
