# zero-trust-workload-identity-operator

The Zero Trust Workload Identity Manager operator (SPIRE/SPIFFE) and nothing else, so a cluster that
already runs it skips this component (`hack/adoption-skippable.snapshot`). The operands come from the
`workload-identity` component's hook.

## Why the channel is pinned to `stable-v1`

The portfolio's general rule is "no pinned channel" (README § Adding or changing a component), because
a version-numbered channel only exists in the catalog it was written against. This component pins one
anyway, deliberately:

- `stable-v1` is the package's **default** channel and the one the product docs install
  (openshift-docs `zero-trust-manager-install-cli`, enterprise-4.22). Pinning it changes nothing today.
- The `workload-identity` hook writes the operand CRs in the `operator.openshift.io/v1alpha1` shapes
  of the 1.x line (read on v1.1.3, 2026-11-13). A future default channel (`stable-v2`) may change those
  shapes. An unpinned Subscription would follow it on a fresh install, and the hook would write CRs the
  new operator rejects. Pinned, a move to v2 is a deliberate change made together with the hook.
- `trustDomain` and `clusterName` are immutable once set, so an unplanned major upgrade under a live
  SPIRE is the riskiest kind for this operator.

When the catalog drops `stable-v1`, the Subscription stops resolving, and that is a loud failure. Move
the channel and the hook together.

The catalog marks the package `disconnected: "false"`: this component needs a connected cluster.
