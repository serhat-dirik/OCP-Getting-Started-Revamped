# ADR-0003: M16 default mesh mode — sidecar; ambient as concept + optional exercise

Date: 2026-07-08 · Status: accepted · Owner: PM (spike by research-analyst)

## Context

OSSM 3.3 is current (Istio 1.28); ambient is GA since OSSM 3.2. Ambient cuts >90% memory / >50% CPU vs sidecars — but every L7 lesson M16 teaches (traffic shifting, fault injection, retries/circuit breaking, L7 AuthorizationPolicy) requires a per-namespace **waypoint** proxy in ambient, and mixed sidecar/ambient traffic silently bypasses waypoint L7 policy — a footgun on a shared 30-user teaching cluster. The advanced-ingress trio (HTTPS-terminate / raw-TCP / TLS-passthrough + EnvoyFilter rate limiting, from `serhat-dirik/ossm-gateway-demo`, verified on OSSM 3.3.3) rides the ingress gateway and is identical under either mode. Cluster fact confirmed: experimental L4 Gateway API CRDs (TCPRoute/TLSRoute) are admission-blocked on OpenShift — Istio Gateway/VirtualService is the supported L4/passthrough path.

## Decision

M16's graded path runs **sidecar mode** (replicas=1 per service to bound ~120 proxies). Ambient is taught as a first-class concept (tradeoff + resource story) plus **one optional exercise**: label the namespace `istio.io/dataplane-mode=ambient`, observe ztunnel L4 mTLS in Kiali, add one waypoint to restore an L7 policy — landing "L7 costs a waypoint" honestly.

## Consequences

- All module objectives work with zero extra CRs; matches the verified demo repo; lowest fragility.
- Revisit trigger: if the shared cluster's resource budget can't absorb sidecars ×30, flip default to ambient+waypoints (exercise design already written for both).
