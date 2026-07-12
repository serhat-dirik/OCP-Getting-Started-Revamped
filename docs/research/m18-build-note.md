# M18 build note — Service Mesh 3 & Advanced Gateways Zero-to-Hero

Date: 2026-07-12 · Author: research-analyst · Spec: `Project-Shared/instructions/02-MODULE-SPECS.md` §M18 · Entitlement: **[OCP]** (OSSM, Kiali, Tempo, OTel, Gateway API all included with OpenShift).

Method: READ-ONLY live build cluster `ocp-ws-revamped` (OCP 4.21.22 / k8s 1.34.8) — `oc get packagemanifest/csv/crd/nodes/gatewayclass` only, no mutations, user5 untouched. docs.redhat.com returned HTTP 403 on direct fetch (bot-block) → product facts verified via live packagemanifests + Red Hat blogs + repo manifests. Repo inspection: `apps/`, `gitops/entry-states/`, `platform-portfolio/`, `CREDITS.md`; `OldContent/repos/ossm-gateway-demo` (Serhat, Apache-2.0) and `parasol-insurance-manifests`. **`versions.yaml` drift applied by coordinator 2026-07-12** (pin `stable-3.3`, add `kiali` block, `istio_version`) + `gen-attributes.sh`.

## Verified versions

| Product / API | Version / status | Group·Kind | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 (k8s 1.34.8) | stable-4.21 | `oc version` (live) | 2026-07-12 |
| **OSSM operator (Sail)** | **v3.3.5 pinned** on `stable-3.3` (`stable` drifted to v3.4.0) | package `servicemeshoperator3` | live packagemanifest; versions.yaml | 2026-07-12 |
| OSSM channels | `stable`→v3.4.0 · `stable-3.3`→**v3.3.5** · `stable-3.2`→v3.2.7 · `stable-3.1`→v3.1.10 · `stable-3.0`→v3.0.13 · `candidates`→v3.0.0-tp.2 (avoid) | — | live | 2026-07-12 |
| OSSM validated pin | **v3.3.5 = Istio 1.28.6** (channel `stable-3.3`) | — | ossm-gateway-demo README; ADR-0003 | 2026-07-12 |
| Istio control plane CR | `sailoperator.io/v1` · **Istio** (`name: default`, `spec.namespace: istio-system`, `updateStrategy.type: InPlace`, `spec.version: v1.28.6`) | sailoperator.io/v1·Istio | ossm-gateway-demo `deploy/00-mesh/istio.yaml`; redhat.com/blog | 2026-07-12 |
| Istio CNI CR | `sailoperator.io/v1` · **IstioCNI** (`spec.namespace: istio-cni`) | sailoperator.io/v1·IstioCNI | `…/istiocni.yaml` | 2026-07-12 |
| Ambient CR (ztunnel) | `sailoperator.io/v1` · **ZTunnel** (HBONE mTLS :15008) | sailoperator.io/v1·ZTunnel | redhat.com/blog OSSM 3.2 ambient | 2026-07-12 |
| Upgrade CRs | **IstioRevision** + **IstioRevisionTag** | sailoperator.io/v1 | redhat.com/blog; sail-operator | 2026-07-12 |
| **Kiali operator** | `stable`→**kiali-operator.v2.27.1** | package `kiali-ossm` | live packagemanifest | 2026-07-12 |
| Kiali CR | Kind **Kiali** — apiVersion `kiali.io/v1alpha1` **UNVERIFIED** (confirm at build) | kiali.io/v1alpha1·Kiali | not verified (403) | 2026-07-12 |
| Istio ingress/L7 CRs | `networking.istio.io/v1` · **Gateway** + **VirtualService** (GA) | networking.istio.io/v1 | ossm-gateway-demo `deploy/{20,30}` | 2026-07-12 |
| Rate-limit CR | `networking.istio.io/v1alpha3` · **EnvoyFilter** (local_ratelimit → 429) | networking.istio.io/v1alpha3 | `demo/demo-04-rate-limit.sh` | 2026-07-12 |
| Mesh authz CR | `security.istio.io/v1` · **AuthorizationPolicy** | security.istio.io/v1 | parasol-insurance-manifests `authorizationpolicy.yaml` | 2026-07-12 |
| Ambient waypoint | `gateway.networking.k8s.io/v1` **Gateway** (`gatewayClassName: istio-waypoint`) | gateway.networking.k8s.io/v1 | parasol-insurance-manifests `waypoint.yaml` | 2026-07-12 |
| Tempo operator | **v0.21.0-2** INSTALLED (AllNamespaces, Succeeded) | tempo.grafana.com/v1alpha1 | live csv | 2026-07-12 |
| OpenTelemetry operator | **v0.152.0-1** INSTALLED | opentelemetry.io | live csv | 2026-07-12 |
| Gateway API (standard) | bundle **v1.3.0**, `gateway.networking.k8s.io/v1`, GA; CRDs present; **no GatewayClass created** | — | live CRDs + `oc get gatewayclass` (none) | 2026-07-12 |
| Gateway API experimental | **TCPRoute/TLSRoute/UDPRoute BLOCKED** by VAP `openshift-ingress-operator-gatewayapi-crd-admission` | — | live (absent) | 2026-07-12 |

**Headline (spec-critical):** OSSM3 uses the **Sail operator** and `sailoperator.io/v1` CRs (**Istio, IstioCNI, ZTunnel, IstioRevision, IstioRevisionTag**). **SMCP/SMMR do not exist in 3.x** — the `Istio` CR replaces SMCP (zero `*.maistra.io` CRDs live). Satisfies the ban (CLAUDE.md rule 6). On the cluster today **nothing mesh is installed**; M18's operator + Kiali + control plane are **net-new**; Tempo + OTel already present for the tracing tie.

## Spec deltas

- **OSSM `stable` drifted 3.3.5 → 3.4.0** (fixed in versions.yaml: pinned `stable-3.3` = v3.3.5 / Istio 1.28.6 to match ADR-0003 + ossm-gateway-demo). 3.4.0's Istio version UNVERIFIED; revisit a bump after re-validating ambient + advanced-ingress.
- **Kiali added to versions.yaml** (was a listed Product with no block): `kiali-ossm` `stable` = v2.27.1.
- **ADR-0003 already settles the mesh-mode "build spike":** sidecar is the graded path (replicas=1 to bound ~120 proxies), ambient = concept + one optional exercise. The spec's "ambient vs sidecar must be settled" is done → **sidecar-default, ambient-optional**.
- **Entry-state chain "web→claims→fraud→db" is not actually wired app-to-app** (M15 found `parasol-web` returns stub data, no server-side claims call; no claims→fraud client). The mesh cascade / weighted-shift / authz beats have nothing to route until the HTTP chain is real. Shared app-work with M15.
- **"Header-based routing" + "fraud v2" need a distinguishable v2 image** (visible version marker) seeded by the entry state.
- **Advanced-ingress trio is single-tenant in the source demo** — re-homing per-user (`{user}-mesh` + a "legacy partner claim feed" TCP backend) on a shared control plane needs per-user Gateways/VirtualServices + unique host/SNI/ports.

## Approach recommendations

1. **Install GitOps-native** as net-new `platform-portfolio/components/service-mesh`: Subscriptions `servicemeshoperator3` (**pin `stable-3.3`**) + `kiali-ossm`, one shared `Istio` + `IstioCNI` (`istio-system`, InPlace, v1.28.6) + `Kiali` CR — re-express `ossm-gateway-demo/scripts/03-install.sh` as CRs (imperative install = defect).
2. **Sidecar-default per ADR-0003**; enroll each `{user}-mesh` via injection label; ambient = concept + one optional exercise (label `istio.io/dataplane-mode=ambient`, observe ztunnel L4 in Kiali, add one waypoint to restore L7 — "L7 costs a waypoint").
3. **In-cluster `demo-client` pod is the verification substrate** (adopt project-wide, like M15): one UDI pod per user (curl/openssl/jq/nc) drives mTLS checks, weighted-shift loops, cascade timing, raw-TCP/TLS-passthrough — no external LB/DNS (bare-metal has none).
4. **Split beats by path:** CR application = **dual-path `[tabs]` Console(Import YAML)::CLI(oc apply)**; Kiali graph / mTLS badges / Tempo traces = **single-path product UI** (OSSM3 ships no console mesh plugin).
5. **Net-new app + platform work:** wire web→claims→fraud (+ fraud v2 marker); prove M15 lightweight-Istio ↔ OSSM3 coexistence before build; add `gitops/entry-states/m18` (Helm, per-user enrollment + partner-TCP backend) + ws-meta.

## Mining results

- **`OldContent/repos/ossm-gateway-demo`** (Serhat, D18, Apache-2.0; tested May 2026 OCP 4.20.21 / OSSM 3.3.3 / Istio 1.28.6) → the load-bearing source for the advanced-ingress trio + rate limit + demo-client. TAKE re-implemented onto Parasol: four-listener single-gateway (`:443` HTTPS-terminate, `:9000/:9001` raw-TCP, `:9002` TLS-passthrough SNI); EnvoyFilter `local_ratelimit` token-bucket (5/60s → 429); the demo-client pod + idempotent `scripts/0{1..5}` + `tests/`. **Add a CREDITS.md line.**
- **`OldContent/repos/parasol-insurance-manifests/app/templates/`** (redhat-ads-tech, current) → real OSSM3 shapes on the actual Parasol app: `authorizationpolicy.yaml` (claims→fraud only), `waypoint.yaml` + `waypoint-podmonitor.yaml` (ambient). Canonical Parasol source — prefer over hand-rolled CRs.
- **`OpenShift Service Mesh 2.x - Workshop Presentation.pdf`** → narrative + lab-shape ONLY (cascading-failure story, one-concept-slide-per-CRD). **DISCARD ALL SM2 tech** (SMCP/SMMR, bundled Jaeger — banned).
- `service-mesh-workshop-{code,dashboard}` (RedHatGov 2022) → demo *story* only; all SM2 tech banned.
- `App Connectivity Workshop.pdf` → east-west traffic framing (netpol→UDN→mesh); M18 takes the east-west mesh layer (M15 owns north-south).
- `adv-app-platform-demo-showroom` M3 → Kiali/traffic console-screenshot reference.

## Open risks

- **M15 lightweight-Istio ↔ OSSM3 Sail coexistence UNVERIFIED and net-new-blocking.** M15 activates ingress-operator lightweight Istio in `openshift-ingress`; M18 installs OSSM3 (Sail) in `istio-system`. Two control planes on one cluster must be proven to coexist (distinct ns/scopes, no webhook/CRD collision) before build. `// TODO(verify-on-cluster)`.
- **OSSM 3.4.0 in `stable` vs 3.3.5-validated content** — portfolio must pin `stable-3.3`; `candidates` holds stale v3.0.0-tp.2 (never use).
- **×30 sidecar overhead on 6 nodes** (~120 proxies at replicas=1 per ADR-0003) — small sidecar requests, watch scheduling; ADR-0003 revisit trigger = flip to ambient+waypoints if budget can't absorb.
- **Shared control plane = cross-tenant reachability** — scope with `discoverySelectors` + default-deny AuthorizationPolicy per `{user}-mesh` (the spec's "namespace selectors!" watchout).
- **App-wiring gap is a hard prerequisite** — web→claims→fraud must be real HTTP hops with a distinguishable fraud v2.
- **EnvoyFilter is the `v1alpha3` escape hatch** (Envoy-internal, version-fragile) — frame as platform capability, not API management; re-verify typed_config against pinned Istio.
- **L4 Gateway API restriction** must be re-confirmed on pinned 4.21 at build (TCPRoute/TLSRoute/UDPRoute admission-blocked today).
- **docs.redhat.com 403** — Kiali CR apiVersion, OSSM install mode, and 3.4.0's Istio version UNVERIFIED; confirm on-cluster/docs at build.

## Builder/platform appendix

**Entry-state — `gitops/entry-states/m18/`** (per-user, net-new, Helm per ADR-0001): `{user}-mesh` ns enrolled for sidecar injection, seeded un-meshed `parasol-web→claims→fraud→db` (real HTTP hops) + `parasol-fraud` v2 marker; a `demo-client` UDI pod (no injection); a "legacy partner claim feed" TCP backend (re-implement ossm-gateway-demo's tcp-echo/tcp-reverse/tls-backend). **Shared** control plane (Istio+IstioCNI+Kiali in `istio-system`) installed by the portfolio stack, not the entry state. `ws solve` → per-user Gateway+VirtualService (90/10 v1/v2, header route), DestinationRule (timeout/retry/circuit-breaker/outlierDetection), AuthorizationPolicy (claims→fraud only), ingress Gateway (HTTPS/TCP/TLS-passthrough), EnvoyFilter rate limit. Tempo tie via `meshConfig.extensionProviders` → OTel → TempoMonolithic. `ws-meta.yaml`: conflictsWith same-ns modules; `ws reset` deletes `{user}-mesh` + unlabels.

**platform-portfolio (net-new `components/service-mesh`):** Subscription `servicemeshoperator3` (channel `stable-3.3`) + `kiali-ossm`; `Istio`(istio-system, InPlace, v1.28.6) + `IstioCNI`(istio-cni) + `Kiali`; `discoverySelectors` scoping which `{user}-mesh` istiod watches; confirm coexistence with M15's ingress-operator Istio; sequence after M15's `gateway-api` component.

**Lab arc (dual-path CLI|Console):** enroll ns (dual) → Kiali graph (single) → verify mTLS (dual+single) → shift 90/10 + header route (dual) → inject 5s delay → cascade → fix with timeout/retry/circuit-breaker (dual) → AuthorizationPolicy (dual) → trace across mesh via Tempo (single) → advanced-ingress trio (dual+CLI validate) → gateway rate limit (dual) → ambient optional (dual).

**Cross-module fit:** M15 owns Gateway API HTTP(S) + NetworkPolicy/UDN + the honest L4 boundary, hands raw-TCP/TLS-passthrough to M18. M12 owns Tempo/OTel; M18 consumes it. M09 references mesh traffic-splitting (pointer target, not re-teach).

### Relevant absolute paths
- Spec §M18: `Project-Shared/instructions/02-MODULE-SPECS.md`
- ADR: `docs/adr/0003-m16-mesh-mode-sidecar-default.md`
- Primary mine: `OldContent/repos/ossm-gateway-demo/` · Parasol shapes: `OldContent/repos/parasol-insurance-manifests/app/templates/`
- Apps: `apps/parasol-{web,claims,fraud,notifications}` · Template: `docs/research/m15-build-note.md`, `m17-build-note.md`

Sources:
- OpenShift Service Mesh 3.3 Release Notes (docs.redhat.com; 403 on fetch, confirmed via search)
- Introducing Red Hat OpenShift Service Mesh 3.0 / 3.2 ambient mode (redhat.com/blog)
- istio-ecosystem/sail-operator (github)
- Istio (Sail) Operator Bundle (catalog.redhat.com)
