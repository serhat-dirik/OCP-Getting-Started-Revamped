# M15 build note — Networking for Dev & DevOps

Date: 2026-07-12 · Author: research-analyst · Spec: 02-MODULE-SPECS §M15 (lines 190-199)
Method: READ-ONLY live build cluster `ocp-ws-revamped` (OCP 4.21.22 / k8s 1.34.8, OVN-Kubernetes) — CRDs, feature gates, `oc explain`/raw CRD schema, cert-manager install state, ingress/egress config, node/platform facts (a concurrent G4 audit was running; no mutations, user5 untouched). Repo inspection (apps + entry-states + platform-portfolio). Sources: live cluster + docs.redhat.com / docs.okd.io 4.20-4.21 + the `ossm-gateway-demo` (Serhat, Apache-2.0) and `App Connectivity Workshop.pdf` under `OldContent/`. `versions.yaml` `cert_manager` re-verified live; net-new networking versions proposed in the appendix (versions.yaml left untouched — see appendix).

## Verified versions

| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-12 |
| OVN-Kubernetes (default CNI) | k8s 1.34.8 | n/a (core) | `network.config/cluster` `networkType=OVNKubernetes` (live) | 2026-07-12 |
| Gateway API — standard CRDs | bundle **v1.3.0**, group `gateway.networking.k8s.io` **v1** (+`v1beta1`) | ingress-operator managed (`GatewayAPIWithoutOLM` gate) | live CRD `bundle-version` annotation + `featuregate/cluster`; docs.okd.io/4.21 ingress-gateway-api | 2026-07-12 |
| OpenShift Gateway controller | controllerName `openshift.io/gateway-controller/v1` | n/a (no GatewayClass created yet) | live (`oc get gatewayclass` = none); openshift/enhancements ingress/gateway-api-with-cluster-ingress-operator | 2026-07-12 |
| UserDefinedNetwork / ClusterUserDefinedNetwork | **v1 (GA)** | `NetworkSegmentation` gate (default-on) | live CRDs `k8s.ovn.org` v1 + raw schema; docs.redhat.com 4.20 multiple_networks/primary-networks | 2026-07-12 |
| NetworkPolicy (+ AdminNetworkPolicy/BANP) | netpol core; ANP/BANP **v1alpha1** | `AdminNetworkPolicy` gate (default-on) | live CRDs `policy.networking.k8s.io` | 2026-07-12 |
| cert-manager Operator for Red Hat OpenShift | **1.20.0** | stable-v1 | packagemanifest + live CSV (**phase=Failed**, see deltas); versions.yaml `cert_manager` | 2026-07-12 |
| Egress IP / EgressFirewall | `k8s.ovn.org` `egressips`/`egressfirewalls` | core OVN-K | live CRDs (no instances, no egress-assignable nodes) | 2026-07-12 |
| IngressController sharding | `operator.openshift.io/v1` IngressController | core | live `ingresscontroller/default` (HostNetwork, replicas=6) | 2026-07-12 |

Entitlement: **all `[OCP]`** — networking is core OpenShift; cert-manager Operator is `[OCP]` (D16 table). Nothing in M15 needs `[ADS]`/`[ADD-ON]`.

Cluster reality (verified live 2026-07-12, read-only) — the load-bearing environment facts:

- **Platform is `BareMetal`, not cloud.** `infrastructure/cluster` `status.platform=BareMetal`; ingress is **HostNetwork** routers (`ingresscontroller/default` replicas=6, one per node), `router-internal-default` is ClusterIP; `openshift-kni-infra` CoreDNS serves the VIP. **No cloud LoadBalancer and no MetalLB** (no `metallb`/`ipaddresspool` CRDs, zero `Service type=LoadBalancer` on the cluster). ⇒ **`Service type=LoadBalancer` stays `<pending>` here**, and the Gateway API's default LoadBalancer Service gets **no external address**. This reshapes the whole exposure/DNS story below.
- **Routes work fully & externally.** `*.apps.<cluster_domain>` resolves via the on-cluster CoreDNS/keepalived VIP; the entire workshop already rides it. The Route path is the deterministic external workhorse. New Gateway/shard domains, by contrast, each need their **own** wildcard DNS record (single-label wildcards don't nest under `*.apps`). External DNS zone is delegated to AWS Route53 (that is how the cluster's own Let's Encrypt wildcard is issued — see cert-manager below).
- **Gateway API is GA and present, but not yet activated.** Standard CRDs shipped and lifecycled by the ingress operator: `gatewayclasses`, `gateways`, `httproutes`, `grpcroutes`, `referencegrants` (all `v1`). Feature gates `GatewayAPI` + `GatewayAPIController` + `GatewayAPIWithoutOLM` are default-on. **No `GatewayClass`/`Gateway` exists yet** — creating a GatewayClass named `openshift-default` with controllerName `openshift.io/gateway-controller/v1` makes the ingress operator install a **lightweight Istio (Red Hat OpenShift Service Mesh 3-based)** deployment in `openshift-ingress`. **No OSSM 2.x is installed**, so there is **no Degraded-ingress conflict** (the documented failure mode). `HTTPRoute.spec.rules.backendRefs.weight` **is present (v1)** ⇒ weighted traffic splits are real at the API.
- **The honest L4 boundary is enforced by the platform, verified live.** Experimental CRDs `TCPRoute`/`TLSRoute`/`UDPRoute` are **absent**, and a `ValidatingAdmissionPolicy` **`openshift-ingress-operator-gatewayapi-crd-admission`** blocks anyone but the ingress operator from creating them (even cluster-admin). ⇒ raw-TCP / TLS-passthrough ingress via Gateway API is **not achievable on the supported channel** — that content belongs to M18 (Istio Gateway/VirtualService). This is exactly the spec's "Routes and today's OpenShift Gateway API are HTTP(S)/SNI-centric" line.
- **UDN/CUDN GA (`v1`); both Layer2 and Layer3 support `role: Primary`.** Raw CRD schema: `layer2.role` and `layer3.role` enums are **both** `[Primary, Secondary]` with Primary-only CEL-gated fields (`defaultGatewayIPs`, `infrastructureSubnets`, `joinSubnets`). ⚠️ The `oc explain userdefinednetwork.spec.layer2.role` **description text is stale** ("Allowed value is Secondary") — trust the enum/CEL, not the description. Primary UDN replaces the default pod network for its namespace (native isolation, no netpol needed). Constraints confirmed vs docs: the namespace must carry label **`k8s.ovn.org/primary-user-defined-network` at creation time** (cannot be added after), and the **UDN/CUDN must exist before any pods** — you cannot convert a populated namespace.
- **cert-manager 1.20.0 is installed and functionally working — but its operator CSV is `Failed`.** Pods `cert-manager`/`cainjector`/`webhook` all 1/1 Running; ClusterIssuer `letsencrypt-production-aws` `Ready=True`; the cluster's own `openshift-ingress`/`openshift-config` certs are cert-manager-issued (`Ready=True`). **However** `csv/cert-manager-operator.v1.20.0` phase = **Failed / `TooManyOperatorGroups`** — the `cert-manager-operator` namespace holds **two** OperatorGroups (`cert-manager-operator` + `cert-manager-operator-og`). Public ACME works (Let's Encrypt via a **Route53 DNS-01** solver), but production rate limits make per-user public certs unwise at event scale.
- **Egress not yet primed:** no node carries `k8s.ovn.org/egress-assignable`, no `EgressIP`/`EgressFirewall` objects. 6 nodes (3 control-plane+worker, 3 worker).
- **NetworkPolicy is proven in-cluster** (many platform namespaces run default-deny + allow, e.g. `openshift-catalogd`, `observability-workshop/otel-collector-networkpolicy`). ANP/BANP exist at `v1alpha1` (still-maturing API).
- **8 users** (user1-user8, ~50 user namespaces). Do **not** touch user5 (concurrent audit).
- **The 3-tier chain is NOT actually wired.** `apps/parasol-web` serves its **own** stub `GET /api/claims` (5 fixed claims, `com.parasol.web.ClaimResource`) and makes **no server-side call** to `parasol-claims`; `apps/parasol-claims` talks to Postgres service **`parasol-db:5432`** (`application.properties`). So today only `claims→db` is a real hop.

## Spec deltas

- **"3-tier claims app across `{user}-dev`" — the tiers aren't connected app-to-app.** parasol-web returns stub data and never calls parasol-claims (`apps/parasol-web/.../ClaimResource.java`). The netpol beat "api only from web" has **nothing to enforce** until parasol-web makes a server-side call to `http://parasol-claims:8080`. "db only from api" is already grounded (`parasol-claims`→`parasol-db:5432`). ⇒ **app work**: add a REST-client hop web→claims (below).
- **"choose exposure … ClusterIP/NodePort/LB/Route/Gateway API" — `LB` cannot be demonstrated as a working external LB here.** Bare-metal + no MetalLB ⇒ `type=LoadBalancer` stays `<pending>`. Reframe LB as a **decision-tree + honest negative** ("create it, watch it hang, understand why you need a provider"), not a working exposure.
- **"expose … via HTTPRoute on a shared Gateway" — real API, but external reachability is a platform gap.** The Gateway's default LoadBalancer Service has no address on this cluster, so browser-level access to HTTPRoutes is not out-of-box. The **objects reconcile and route correctly in-cluster**; verify via an in-cluster client (see recommendations). Not `[CAPTURE-VERIFY]` for the API (GA, present, weight field real) — the gap is purely LB/DNS provisioning.
- **"attach a cert-manager-issued cert" — prefer the Gateway-listener path; Route+cert-manager is Tech Preview.** cert-manager Certificate→Secret→Gateway `listeners[].tls.certificateRefs` is core/GA; cert-manager-managed **Route** certs are a **Technology Preview** feature of the Red Hat operator (docs.openshift.com 4.18 cert-manager-securing-routes). Also: no public ACME for per-user certs (rate limits) ⇒ use a **self-signed CA ClusterIssuer**, not `letsencrypt-production`.
- **"UDN for the partner namespace" resolves the "UDN + existing namespaces" watchout cleanly.** A Primary UDN **cannot** be applied to the already-populated `{user}-dev`. The spec's separate **partner** namespace is the mechanism: the entry state creates it fresh, labeled at creation, UDN before pods. netpol stays in `{user}-dev`; native UDN isolation is demonstrated in the partner ns.
- **cert-manager operator CSV `Failed` (TooManyOperatorGroups)** is a live platform defect M15 inherits — functional today, but blocks operator upgrade/reconcile. Must be reconciled before M15 depends on it.
- **`[INSTRUCTOR-DEMO]` egress IP + router sharding are harder on bare-metal.** Egress IP needs a labeled node + a free host-subnet IP; a second IngressController can't share HostNetwork ports 80/443 on the same nodes (needs dedicated nodes or NodePort publishing) and needs its own wildcard DNS record. Both stay instructor-demo; attendee "verify" is best done **in-cluster**.

## Approach recommendations

1. **Split the story by namespace:** netpol default-deny→precise-allow in `{user}-dev` (works on existing pods); native **Layer2 Primary UDN** isolation in a fresh, label-at-creation **`{user}-partner`** namespace (UDN before pods, sync-wave ordered by the entry state).
2. **Make the in-cluster demo-client pod the verification substrate** (adopt `ossm-gateway-demo`'s pattern): one curl/openssl/jq UDI pod per user drives Route, HTTPRoute (Host-header to the Gateway ClusterIP), netpol probes, and egress source-IP checks — deterministic regardless of the bare-metal LB gap.
3. **Teach exposure as a decision tree grounded in this cluster:** ClusterIP (default) → NodePort (create+inspect+curl node:port from the debug pod, "once, never again") → LoadBalancer (**create → Pending → why you need a provider**) → **Route** (the external workhorse) → **Gateway API/HTTPRoute + weighted split** (verified in-cluster; strategic direction).
4. **TLS via a self-signed CA ClusterIssuer** minted once by the platform → per-user cert into the Gateway listener `certificateRefs`; **show** the live `letsencrypt-production-aws` ClusterIssuer read-only as "how the cluster's real wildcard is issued (Route53 DNS-01)."
5. **Platform prerequisite work (net-new):** fix the duplicate cert-manager OperatorGroup; add a `gateway-api` portfolio component (GatewayClass `openshift-default` + one shared multi-tenant `Gateway` with `allowedRoutes` for `{user}-*` + wildcard cert); decide the Gateway's external publish (MetalLB or accept in-cluster verify); a `network-lab`/entry `m15` chart for the partner UDN, demo-client, and solve-state netpols/Route/HTTPRoute/cert.

## Mining results

- **`serhat-dirik/ossm-gateway-demo`** (D18, Apache-2.0, `OldContent/repos/ossm-gateway-demo`; tested May 2026 on 4.20/OSSM 3.3.3) — the load-bearing source for the **exposure decision tree**. TAKE: (a) the exact platform constraint narrative — standard GW-API CRDs shipped vs experimental `TCPRoute`/`TLSRoute`/`UDPRoute` blocked by the `openshift-ingress-operator-gatewayapi-crd-admission` VAP (README "Why this demo exists") → feeds M15's "why Routes/Gateway API are HTTP/SNI-only" and the L4 hand-off to M18; (b) the **in-cluster `demo-client` pattern** (Red Hat UDI pod, curl/openssl/jq — no port-forward, no external LB/DNS dependency) → adopt project-wide as M15's verification pod; (c) the `demo-02-one-ingress` "one Service, three protocols — and OCP Route can't do this" framing (use only the HTTP(S) half here; raw-TCP/passthrough is M18). Credit per D18 + `CREDITS.md`. **Do NOT port** the Istio Gateway/VirtualService L4 tech into M15 (M18 owns it).
- **`App Connectivity Workshop.pdf`** (`OldContent/`, `oldcontent-mining-index.md` §2a) — the **traffic-direction mental model**. TAKE: p.4 module map (**East↔West** vs **North↔South** traffic framing) → M15 concept's north-south exposure tree + east-west control layers (netpol→UDN→mesh); p.5-9 **accreting-architecture diagram** ("In the beginning…" 3-tier web→services→db, then layer on) → the master "Parasol platform" accretion diagram for M15's concept (style guide §4 endorses stealing this trick). **DISCARD** the product specifics — north-south here is **Routes/Gateway API**, not Connectivity Link (retired per D17); Service Interconnect/Service Mesh belong to M21/M18.
- **`adv-app-platform-demo-showroom` M3** (`oldcontent-mining-index.md` §4) — traffic-management/security beat is **mesh (OSSM/Kiali)**, not netpol/UDN/GW-API; use only as a console-screenshot reference. M15's netpol/UDN/Gateway-API substance is **fresh** (spec: "fresh for UDN/GwAPI").

## Open risks

- **cert-manager operator CSV `Failed` = `TooManyOperatorGroups`** (two OGs in `cert-manager-operator`: `cert-manager-operator` + `cert-manager-operator-og`). Delete the duplicate so exactly one remains; re-verify CSV `Succeeded` before M15's TLS beat. Root cause is likely the portfolio `cert-manager` component's `operatorgroup.yaml` colliding with a base/bootstrap-created OG — the component should **adopt** a pre-existing install (field-deployment "adopt operators" directive) rather than add a second OG. `// TODO(verify-on-cluster)` after fix.
- **Gateway external exposure on bare-metal** — the shared Gateway's LoadBalancer Service will be `<pending>`. Either add **MetalLB** (an `IPAddressPool` + `L2Advertisement`) so the Gateway (and the LB-Service exposure beat) gets a real address, or design the HTTPRoute exercise to **verify in-cluster** via the demo-client. `// TODO(verify-on-cluster)`: does the OpenShift Gateway API implementation support NodePort/HostNetwork publishing here, and does it auto-create a `dnsrecord` on this platform?
- **default-deny also blocks DNS.** The "app breaks; write allows" beat must include an **egress allow to `openshift-dns` (UDP/TCP 53)** or the fix looks broken for the wrong reason — bake it into the solve netpols and the troubleshooting page.
- **UDN entry-state ordering is unforgiving:** partner namespace must be created **with** the `k8s.ovn.org/primary-user-defined-network` label and the UDN reconciled **before** the first partner pod; `ws reset` must fully delete the namespace (label can't be toggled). Sync-wave the entry chart: labeled ns → UDN → pods.
- **Egress IP / router sharding feasibility (both `[INSTRUCTOR-DEMO]`)** — egress IP needs a labeled node + free host-subnet IP; a shard IngressController needs dedicated nodes or NodePort + its own wildcard DNS record in the delegated Route53 zone. Have EgressFirewall (deterministic, no cloud IP) as the attendee-runnable egress-control fallback; keep source-IP verification an in-cluster instructor demo. `// TODO(verify-on-cluster)`.
- **App wiring gap** (web→claims) is a hard prerequisite for the 3-tier netpol story — track as app-developer work, not content.
- **M15↔M18 Istio coexistence:** M15 activates the ingress-operator-managed lightweight Istio (for Gateway API); M18 installs OSSM 3 (Sail). Confirm the two control planes coexist (they target different namespaces/scopes) before M18 build. `// TODO(verify-on-cluster)`.

---

## Builder/platform appendix

### Decisions M15 surfaces (for the PM)

- **D-M15-1 (exposure runnability on this cluster):** external-runnable → **ClusterIP, Route**; in-cluster-verified → **NodePort, Gateway/HTTPRoute + weighted split**; concept/negative → **LoadBalancer** (Pending); `[INSTRUCTOR-DEMO]` → **egress IP, router sharding** (attendee verify in-cluster). Gateway API is **REAL/GA (v1.3.0)**, not capture-verify.
- **D-M15-2 (UDN):** **Layer2 Primary UDN** (or CUDN with a `namespaceSelector`) for `{user}-partner` — matches the spec's "L2 isolation," and Layer2 Primary is confirmed supported (enum/CEL).
- **D-M15-3 (TLS):** self-signed **CA ClusterIssuer** → per-user Certificate → Gateway listener `certificateRefs`; `letsencrypt-production-aws` shown read-only. Route+cert-manager stays out (Tech Preview).
- **D-M15-4 (netpol):** requires app work (web→claims REST hop) before "api only from web" is teachable.
- **D-M15-5 (platform prereq):** create GatewayClass `openshift-default` + one shared Gateway; reconcile cert-manager OG; decide MetalLB-vs-in-cluster-verify.

### Entry-state sketch (`gitops/entry-states/m15`, mirror `entry-states/m13` Helm shape)

- `{user}-dev`: `parasol-web` + `parasol-claims` + `parasol-db` (reuse m13 templates), **plus** a `parasol-claims` **v2** Deployment (visibly-distinct response for the weighted split), a **demo-client** pod (UDI: curl/openssl/jq), entry marker. Solve state adds: default-deny + allow netpols (incl. DNS egress), a Route, a shared-Gateway HTTPRoute (+weighted 90/10 v1/v2), a cert-manager Certificate→Secret→listener ref.
- `{user}-partner` (**created by the chart**, labeled `k8s.ovn.org/primary-user-defined-network` at creation): a **Layer2 Primary UserDefinedNetwork** + a small workload, sync-waved ns→UDN→pod. Demonstrates native isolation from `{user}-dev` with no netpol.
- `ws-meta.yaml`: declare partner-ns cleanup; `conflictsWith` any same-namespace module; `ws reset` deletes `{user}-partner` entirely.

### App work (app-developer)

- **Wire the 3-tier chain:** add a `@RestClient` (or MP Rest Client) to `parasol-web` that calls `http://parasol-claims:8080/api/claims` server-side (env `CLAIMS_API_URL`), so web→claims is real pod-to-pod traffic. Keep a graceful fallback to the stub so M01-M14 (which don't deploy claims alongside web) stay independent.
- **A distinguishable parasol-claims v2** (e.g. a `X-Claims-Version` header or a version field) so the weighted HTTPRoute split is observable from the demo-client curl loop. Image tags 1.0/1.1 already exist (m12/m13) — a v2 tag or a `VERSION` env is enough.

### Proposed `versions.yaml` additions (I did NOT edit `versions.yaml` — concurrent G4 audit; PM to apply)

```yaml
gateway_api:
  api: gateway.networking.k8s.io/v1        # +v1beta1 served
  bundle_version: "v1.3.0"                  # live CRD annotation on gateways.gateway.networking.k8s.io
  status: GA                                # GatewayAPI + GatewayAPIController + GatewayAPIWithoutOLM gates default-on (4.19+ GA)
  implementation: ingress-operator-managed lightweight Istio (OSSM3-based) in openshift-ingress
  gatewayclass: openshift-default           # controllerName openshift.io/gateway-controller/v1 (create to activate)
  standard_crds: [gatewayclasses, gateways, httproutes, grpcroutes, referencegrants]
  experimental_crds_blocked: [tcproutes, tlsroutes, udproutes]  # VAP openshift-ingress-operator-gatewayapi-crd-admission
  verified: 2026-07-12
  source: live CRDs + featuregate/cluster on ocp-ws-revamped; docs.okd.io/4.21 ingress-gateway-api
  entitlement: OCP
udn:
  api: k8s.ovn.org/v1                       # UserDefinedNetwork + ClusterUserDefinedNetwork
  status: GA                                # NetworkSegmentation gate default-on; primary UDN GA since OCP 4.18
  topologies: [Layer2, Layer3]              # both support role Primary (CRD enum/CEL; oc explain layer2 desc is stale)
  primary_ns_label: k8s.ovn.org/primary-user-defined-network   # must be set at namespace creation
  constraint: UDN/CUDN must exist before pods; cannot convert a populated namespace
  verified: 2026-07-12
  source: live CRD raw schema on ocp-ws-revamped; docs.redhat.com 4.20 multiple_networks/primary-networks
  entitlement: OCP
# cert_manager: bump verified -> 2026-07-12; ADD note: operator CSV v1.20.0 phase=Failed
#   (TooManyOperatorGroups: 2 OGs in ns cert-manager-operator) though pods Ready + issuers reconcile.
#   Public ACME works via Route53 DNS-01 (letsencrypt-production-aws Ready) but rate-limited ->
#   lab TLS uses a self-signed CA ClusterIssuer; Route+cert-manager is Tech Preview (prefer Gateway listener).
```

### Doc anchors (verify at build; cite the pinned doc-set)

- Gateway API on OpenShift: docs.okd.io/4.21 `.../ingress-gateway-api.html`; openshift/enhancements `ingress/gateway-api-with-cluster-ingress-operator.md`; docs.redhat.com 4.20 `network_apis`.
- UDN/CUDN: docs.redhat.com 4.20 `multiple_networks/primary-networks`; docs.okd.io/4.21 `.../about-user-defined-networks.html`.
- cert-manager Operator: docs.redhat.com 4.20 `security_and_compliance/cert-manager-operator-for-red-hat-openshift`; securing-routes (Tech Preview) docs.openshift.com 4.18 `.../cert-manager-securing-routes.html`.
- NetworkPolicy / egress IP / EgressFirewall / IngressController sharding: docs.redhat.com OCP 4.20-4.21 Networking (Network security, Configuring egress IPs, Ingress sharding).

### Timing (90 min workshop, indicative)

Service/endpoints map + break/fix selector ~12 · exposure (Route + HTTPRoute + weighted split + NodePort/LB honesty) ~25 · cert-manager TLS on the listener ~10 · default-deny → allow patterns + demo-client test ~20 · UDN partner-namespace isolation ~13 · `[INSTRUCTOR-DEMO]` sharding + egress IP ~10. Demo flavor (default-deny→allow + UDN) ~12 min.
