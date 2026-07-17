# ADR-0007 — Networking module: no MetalLB; Gateway exposure verified in-cluster

Status: accepted (closes decision D-networking-dev-devops-5, deferred from the module build)
Date: 2026-07-18

## Context

The Networking for Dev & DevOps module teaches Gateway API end to end. On a bare-metal cluster a
`LoadBalancer` Service (and therefore a Gateway's external address) never provisions — there is no
cloud provider to hand out an IP. The module build left the exposure question open as
D-networking-dev-devops-5: install MetalLB to provide real external IPs, or verify the Gateway data
path from inside the cluster. The shipped lab already implements the in-cluster-verify path
(`gitops/entry-states/networking-dev-devops/`, see the solve-endstate notes); this ADR makes that
the settled decision rather than a workaround.

## Decision

**Descope MetalLB permanently; in-cluster verification is the design, not a fallback.**

1. **Non-invasive hard rule.** The workshop must drop onto an org's existing cluster without
   changing its characteristics. MetalLB is a cluster-wide network announcer (L2/BGP speakers +
   address pools) — it alters how the cluster's network behaves and claims address space the org
   owns. Same grounds on which the IngressController console-embed patch was rejected.
2. **The lesson survives intact.** The teaching target is the Gateway API resource model and the
   routing data path — both fully exercised by driving traffic at the Gateway from inside the
   cluster. The only thing MetalLB would add is an externally routable IP, which is environment
   plumbing, not curriculum.
3. **Real clusters solve this themselves.** On cloud clusters the provider issues LoadBalancer IPs;
   on serious bare-metal estates the platform team has already chosen its LB story. The lab text
   says exactly that, so attendees leave knowing what changes outside the workshop.

## Consequences

- No `metallb` component enters `platform-portfolio/`; the install stays adoption-safe on clusters
  that already run MetalLB (we never touch it either way).
- The lab's expected outputs show in-cluster curl verification; `EXTERNAL-IP <pending>` on bare
  metal is explained in-line as expected, not an error.
- If a future variant genuinely needs external exposure (e.g. a public-demo cluster), that is a
  cluster-provisioning choice made outside the workshop's install, documented in the SA guide —
  never a workshop-installed operator.
