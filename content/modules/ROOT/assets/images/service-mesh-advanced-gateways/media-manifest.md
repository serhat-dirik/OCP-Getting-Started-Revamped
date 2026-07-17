# M18 media manifest — Service Mesh 3 & Advanced Gateways

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
This module's **marquee visual is the Kiali service graph** — a screenshot no CLI output can replace — so
the Kiali captures below are the priority of the media pass. All lab mechanics and every expected-output
block were captured on-cluster (OCP 4.21.22, Kubernetes 1.34, OpenShift Service Mesh 3.3.5 / Istio v1.28.6,
2026-07-13 as user4); the diagram SVG exports and the Kiali/console screenshots are the deferred media pass.
Every screenshot needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc`
files with a commented `// media-pass:` (diagrams) or `// [CAPTURE-VERIFY]` (console/Kiali) line — replace
with the `image::…` when the asset lands. **Do not shoot yet** — this is the spec; capture in the media phase.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `service-mesh-advanced-gateways-01-mesh-architecture.svg` | concept.adoc Mermaid "The data plane and the control plane" | blue **control plane** (istiod + Kiali in istio-system) pushing config + mTLS certs DOWN to amber **sidecar proxies** wrapping green app containers (web/claims/fraud) in `{user}-mesh`; solid mTLS edges between meshed pods; a red **un-meshed demo-client** with a dashed "plaintext (blocked under STRICT)" edge. The module's spine — reused on slide 2 |
| `service-mesh-advanced-gateways-02-traffic-split.svg` | lab.adoc ex. 4 + slide 5 | claims' sidecar fanning to a fat **90%** arrow (v1 subset) and a thin **10%** arrow (v2 subset), with an `x-parasol-test:true` header-tagged request on a dedicated line straight to v2; a "read from `istio_requests_total`" telemetry chip. The weighted/header routing idea |
| `service-mesh-advanced-gateways-03-what-you-built.svg` | wrapup.adoc Mermaid recap | green = meshed workloads (web/claims/fraud v1+v2); amber = the mesh policy applied (VirtualService · DestinationRule · AuthorizationPolicy · Gateway); blue = the un-meshed claims-db; mTLS + authz edges claims→fraud |

Shared legend across the diagrams: control-plane box, sidecar-proxy ring, mTLS padlock edge, the amber
policy card, the SPIFFE-identity badge — Red Hat-neutral palette, no vendor-logo soup. Do **not** print the
Istio/OSSM version numbers on the diagrams (prose carries them via attributes + captured output). Do **not**
print the real cluster domain or node names — use `{user}-mesh` and generic hostnames.

## Screenshots — Kiali (MARQUEE; product UI, single-path, `[CAPTURE-VERIFY]`)

Kiali has no OpenShift-console equivalent, so these are the module's signature visuals. Capture in Kiali
2.27.1, signed in as the sample user, namespace scoped to the user's `{user}-mesh`. **The graph needs
traffic first** — run the exercise-3 traffic-generation before each shot.

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `service-mesh-advanced-gateways-01-kiali-graph-mtls.png` | Kiali → Traffic Graph → `{user}-mesh`, after exercise-3 traffic: nodes `parasol-web`/`parasol-claims`/`parasol-fraud` with traffic-driven edges | Circle: an edge's **mutual-TLS padlock** icon + the request-rate label | lab.adoc ex. 3 (the "graph lights up" beat) — **the marquee** |
| 2 | `service-mesh-advanced-gateways-02-kiali-versioned-split.png` | Kiali → Traffic Graph with **versioned** app grouping, after exercise-4 traffic: `parasol-fraud` split into `v1` and `v2` workloads | Circle: the **90% vs 10%** edge thickness / percentages to v1 vs v2 | lab.adoc ex. 4 (the weighted-split beat) |
| 3 | `service-mesh-advanced-gateways-03-kiali-health-red.png` | Kiali → Traffic Graph during the exercise-6 authz deny (or exercise-5 fault): a **red/failing** edge into fraud | Circle: the red edge + the health badge flipping from green | lab.adoc ex. 5–6 (resilience / authz — "you can SEE the failure") |

**Animated gif (PREFERRED for the enroll→graph story):**
`service-mesh-advanced-gateways-04-graph-lights-up.gif` (<25 s, silent) — quick cuts: app pods `1/1 →
2/2` (a sidecar appears) → generate traffic → the Kiali graph **drawing itself** node by node with padlocks
appearing on the edges. The "mesh for free" reveal is the payoff.

## Screenshots — OpenShift console (optional; the CR-application dual-path tabs)

CLI is authoritative for every CR step; these give the Console tabs visual support. Confirm the OCP 4.21
unified-console click-paths while shooting (no perspective switch).

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 4 | `service-mesh-advanced-gateways-05-deployment-inject-label.png` | Console → Workloads → Deployments → `parasol-web` → YAML, the `sidecar.istio.io/inject: "true"` label under `spec.template.metadata.labels` | Circle: the injection label on the **pod template** | lab.adoc ex. 1 Console tab |
| 5 | `service-mesh-advanced-gateways-06-import-virtualservice.png` | Console → +Add → Import YAML with the `VirtualService` (90/10) pasted | Circle: the `weight: 90` / `weight: 10` route entries | lab.adoc ex. 4 Console tab |

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console; Kiali 2.27.1) — these
confirm the click-paths written with `[CAPTURE-VERIFY]` in `lab.adoc` (the CLI tabs are authoritative):

1. **Kiali → Traffic Graph** scopes to the signed-in user's `{user}-mesh` namespace, shows traffic-driven edges, per-edge mTLS padlocks, and version grouping (ex. 3–4).
2. **Console → Workloads → Deployments → YAML** accepts the `sidecar.istio.io/inject` pod-template label (ex. 1).
3. **Console → +Add → Import YAML** accepts the PeerAuthentication / DestinationRule / VirtualService / AuthorizationPolicy manifests (ex. 2, 4, 5, 6).
4. **Console → Networking → VirtualServices / DestinationRules** list the mesh CRs after apply (ex. 4–5).

## Recordings

### Terminal cast — enroll → mTLS → shift → fault → authz → gateway (`service-mesh-advanced-gateways-demo.cast`, ~15 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as the sample user (drive it
straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`):

1. enroll the three tiers → app pods go `1/1 → 2/2` (the native sidecar appears);
2. STRICT `PeerAuthentication` → the un-meshed client **refused** (`curl (56) Connection reset`), a meshed caller still `200` (**hold on the reset** — the mTLS proof);
3. deploy v2 + the weighted `VirtualService` → **~90/10 split read from `istio_requests_total`**;
4. inject a 5-second fault → the caller feels `HTTP 200 in 5.0s` (and the honest fault-vs-timeout note);
5. `AuthorizationPolicy` → `claims 200`, **`web 403 RBAC: access denied`** (**hold on the 403** — the identity beat);
6. `[encore]` raw-TCP through the Istio Gateway (`PARASOL-PARTNER-FEED-ACK`) → `EnvoyFilter` rate limit → **`200 200 200 200 200 429 …`**.

Steps 2 (the mTLS reset) and 5 (the authz 403) are the module's signature terminal moments; embed near
lab.adoc exercises 2 and 6 and the demo arc. Keep the font large — the `Connection reset`, the `403`, and
the `429` sequence are the whole visual. Everything in the cast runs against the shared control plane in
`istio-system` and only mutates the sample user's `{user}-mesh` namespace.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the 15-min arc).
Shot list = the Show: lines (Kiali graph for beats 1–2, terminal for beats 3–4); narration = the Say: lines.
Record alongside the terminal cast in the media phase.
The one line that must land in the narration: *"the web tier — a perfectly healthy pod — gets 403, not by
IP, not by namespace, but by cryptographic identity. That's 'only claims may call fraud,' enforced."*
