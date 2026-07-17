# Service Mesh 3 & Advanced Gateways

## Slide: One slow service shouldn't take down the site

- Parasol's chain: web → claims → fraud-scoring
- Fraud hangs → claims threads pile up → web stalls → outage
- Every link needs the same things: encrypt, see, route, retry, authorize
- Without a mesh, that's app code — per team, per language, per bug
- A mesh moves it into a proxy beside every workload

Notes: Open on the cascading-failure story, the classic mesh entry point. Parasol's application is a chain — the web tier calls the claims API, and claims calls a fraud-scoring service before it approves a payout. When one link gets slow, the callers pile up waiting and a single sluggish service cascades into a site-wide outage. Every link needs the same five things: the traffic should be encrypted, you should be able to see it, a bad release should be shiftable without a redeploy, a slow dependency should fail fast, and only the right caller should get through. Without a mesh, every one of those is application code — each team wires TLS, adds a metrics library, writes retry loops, re-implements auth, differently and with different bugs. A service mesh moves all of it out of the app and into a proxy that sits beside each workload. The app keeps making plain HTTP calls; the proxy encrypts, measures, routes, retries, and authorizes them.
Visual: A three-node chain (web → claims → fraud) with a red "hang" on the fraud node and back-pressure arrows piling up on claims and web; a side caption "one slow service, whole-site outage."

## Slide: Data plane + control plane

- Data plane: a sidecar proxy (Envoy) injected into every meshed pod
- All pod traffic transparently redirected through its proxy
- Control plane: istiod — compiles your CRs, pushes config + identity certs
- istiod is NOT in the request path (traffic survives its restart)
- OSSM3 injects a NATIVE sidecar: an always-on init container

Notes: Two halves, and the split is the whole mental model. The data plane is the fleet of sidecar proxies — one Envoy proxy injected into every meshed pod, with all of the pod's inbound and outbound traffic transparently redirected through it. This is where encryption, routing, retries, and access checks actually happen. On OpenShift Service Mesh 3 the proxy is injected as a native sidecar — a Kubernetes init container with an always-on restart policy, so it starts before your app and shuts down after it, closing the startup and shutdown gaps older sidecars had. The control plane is istiod, in the istio-system namespace: it watches your Kubernetes resources and the mesh custom resources you create, compiles them into proxy configuration, and pushes that config plus a short-lived identity certificate to every sidecar. It is not in the request path — if istiod restarts, traffic keeps flowing on the last config the proxies received. You configure the mesh by creating custom resources — VirtualService, DestinationRule, AuthorizationPolicy, PeerAuthentication — and istiod turns them into proxy behavior. You never edit a proxy directly.
Visual: Reuse concept diagram service-mesh-advanced-gateways-...-01-mesh-architecture.svg — blue control plane (istiod + Kiali) pushing config/certs down to amber sidecar proxies wrapping green app containers, with an un-meshed red client outside.

## Slide: Enroll once, get three things free

- Add one label (`sidecar.istio.io/inject: "true"`) → proxy appears
- Namespace tenant enrolls PER WORKLOAD (namespace label = cluster-admin)
- Mutual TLS between meshed workloads — automatic, identity-bound (SPIFFE)
- A live service graph + golden signals — no app instrumentation
- A control point: route/secure/slow/retry by applying a resource

Notes: Enrolling a workload — adding one label and letting it restart — buys three things with no application change. First, mutual TLS between meshed workloads: each sidecar gets an identity certificate from istiod encoding a SPIFFE identity of the form spiffe://cluster.local/ns/namespace/sa/serviceaccount, and when two meshed pods talk, their proxies authenticate each other and encrypt the connection automatically. Second, a service graph and golden signals: because every request passes through a proxy, the mesh emits consistent telemetry — rate, errors, latency — for all traffic, without instrumenting the app, and Kiali renders it. Third, a control point: once traffic flows through the proxies, you change its behavior by applying a resource, not by shipping code. One important nuance for OpenShift: a namespace tenant can't label the namespace itself (that's a cluster-scoped edit), so you enroll per workload with the injection label on the pod template — finer-grained anyway. And by default mutual TLS is PERMISSIVE (meshed-to-meshed encrypted, but plaintext from outside still accepted); flipping a PeerAuthentication to STRICT makes the proxy refuse plaintext, which is exactly how you prove the encryption is real.
Visual: A pod going from one box to two (app + proxy), with three payoff chips flying out: a padlock (mTLS), a graph icon (Kiali), and a sliders icon (control) — plus a small "per-workload label, not namespace" callout.

## Slide: OSSM 3 is upstream Istio — the 2.x question

- Service Mesh 3 = upstream Istio, managed by the Sail operator
- The 2.x control-plane and member-roll CRs are GONE
- 3.x: the standard `Istio` CR + discovery/injection labels
- Migration message: "your Istio knowledge transfers directly"
- On this cluster: Istio v1.28.6, reported by the `Istio` resource

Notes: OpenShift Service Mesh 3 is upstream Istio, packaged and lifecycle-managed by the Sail operator — that's the single biggest change from the 2.x line, and it's the first thing a migrating customer asks about. In 2.x you configured the control plane through a dedicated Red Hat control-plane custom resource and declared mesh membership through a separate member-roll object; those two resources do not exist in 3.x. In 3.x the control plane is upstream Istio's own Istio resource, managed by Sail, and membership is by the discovery and injection labels you use in the lab — standard Istio, the same VirtualService, DestinationRule, Gateway, and AuthorizationPolicy the whole ecosystem uses. The practical migration message: the 2.x control-plane and member-roll CRs are gone, it's upstream Istio now on the Sail operator, so your Istio knowledge transfers directly. On this cluster the control plane reports itself as Istio v1.28.6, read straight off the Istio resource. (The two 2.x resource names are on the workshop's banned-terms list precisely because they're deprecated — never present them as a current path.)
Visual: A before/after: left "2.x — Red Hat control-plane CR + member-roll" struck through; right "3.x — Sail operator + standard `Istio` CR + injection labels," with an "upstream Istio v1.28.6" badge.

## Slide: Shift traffic between versions

- DestinationRule = named subsets (v1, v2 pools)
- VirtualService = the route: 90/10 weighted split + header rule
- `x-parasol-test: true` → straight to v2 (pin test users)
- Routing follows the CALLER's sidecar (drive from a meshed pod)
- Read the split from mesh telemetry (identical bodies here)

Notes: Traffic shifting is two resources. A DestinationRule defines subsets — named pools by label, v1 and v2. A VirtualService is the route — here a 90/10 weighted split, plus a header rule that sends x-parasol-test:true straight to v2 so test users can opt into the new version while everyone else stays on v1. One thing that trips people up: a VirtualService weighted route is applied by the caller's sidecar, so you have to drive the traffic from a meshed workload for the split to apply (an un-meshed client bypasses it and gets even load-balancing). In the lab you send 200 requests from the meshed claims pod and read the actual distribution — about 185 to v1 and 15 to v2, the 90/10 you configured — from the mesh's own istio_requests_total telemetry, broken down by destination version. Why telemetry and not "count the responses"? Because in this lab v1 and v2 run the same image, so their bodies are identical; the routing is completely real, you just read it from the metric (which is also what colors Kiali's versioned graph). A genuinely distinct v2 would let you count responses too.
Visual: A weighted-split diagram: claims' sidecar fanning to a fat 90% arrow (v1) and a thin 10% arrow (v2), with a header-tagged request taking a dedicated line straight to v2; a small "read from istio_requests_total" telemetry chip.

## Slide: Resilience — and the honest limits

- Fault injection: simulate a slow/failing dependency
- Timeout + retries (VirtualService), circuit breaker (DestinationRule)
- Circuit breaker = eject a pod after N 5xx + cap connections
- Honest: Istio injects faults AHEAD of the router
- So an injected delay isn't clipped by that route's timeout

Notes: The mesh lets you both simulate failure and configure the defenses. Fault injection adds a delay or an abort to a route so you can test how a caller copes with a slow or failing dependency — in the lab, a 5-second delay on the fraud route, and you watch the caller feel every second of it: that's the cascading-failure trigger. The defenses are a request timeout and retries on the VirtualService, and a circuit breaker on the DestinationRule — outlier detection that ejects a fraud pod after three consecutive 5xx errors for thirty seconds, plus a connection-pool cap so a slow dependency can't exhaust the caller. Now the honest part, and it's a genuinely useful thing to teach: Istio applies fault injection in a filter that runs ahead of the router, so an injected delay (or abort) is not subject to that same route's timeout or retries — you'll set timeout 3s and watch the 5-second fault return a 200 after 5 seconds, not a timeout at 3. Fault injection tests the caller's coping; to see the timeout itself fire you need a genuinely slow upstream. The policy is real and applied (you confirm it in the proxy config); observing it trip live waits on a slower upstream. Don't oversell it.
Visual: A route with three guard icons (timeout, retry, circuit-breaker) and a fault "syringe" positioned BEFORE the router box — an arrow annotation "injected here, ahead of the timeout."

## Slide: Lock the call path to identity

- Under PERMISSIVE, any meshed workload can call fraud
- AuthorizationPolicy: ALLOW only `sa/parasol-claims`
- ALLOW list → implicit deny for everyone else
- Result: claims 200 · web tier 403 · un-meshed client 403
- Not by IP, not by namespace — by cryptographic identity

Notes: The strongest beat. The mesh decides who may call whom by workload identity, not network location. Right now, under PERMISSIVE mutual TLS, any meshed workload can reach fraud — you prove it by having the web tier call fraud and get a 200. Then you apply an AuthorizationPolicy on the fraud workload that ALLOWs only the claims identity — sa/parasol-claims, the SPIFFE name you read off the certificate earlier. An ALLOW rule creates an implicit deny for everyone else. Now test three callers: claims (the allowed identity, over mutual TLS) gets a 200; the web tier — a perfectly healthy pod with a different identity — gets 403 RBAC: access denied; and the un-meshed demo-client, with no mesh identity at all, is refused too. That's the difference from a NetworkPolicy: a network policy answers by location ("namespace A may reach namespace B"), while an AuthorizationPolicy answers by cryptographic identity ("only the claims workload, and nothing else, even from the same namespace"). "Only claims may call fraud," enforceable rather than aspirational — and violations are a 403 you can see.
Visual: Three arrows converging on the fraud service: a green check from claims (sa/parasol-claims), a red 403 from the web tier (sa/default), a red 403 from the un-meshed client — labelled "identity, not location."

## Slide: The honest L4 boundary — and what you'll do

- Routes / Gateway API: great for HTTP(S) ingress
- Raw TCP + TLS passthrough: Istio Gateway/VirtualService (today)
- Experimental L4 Gateway API (TCPRoute/TLSRoute): not available here
- Encore: serve a raw-TCP partner feed + EnvoyFilter rate limit (429)
- Map to org: is your east-west traffic provably encrypted and identity-gated?

Notes: Close on the ingress boundary and the transfer. Getting traffic into the mesh is the job of an ingress gateway. The honest boundary worth carrying to a customer: Routes and the newer Gateway API handle HTTP(S) ingress well — for most web traffic you don't need the mesh's gateway. But raw TCP and TLS passthrough by SNI are different: a Route can't route an arbitrary TCP protocol, and on supported OpenShift channels the experimental L4 Gateway API resources (TCPRoute, TLSRoute) aren't available — they were absent on this cluster. So when Parasol's legacy partner bureaus send claim feeds over raw TCP, the Istio ingress Gateway with a TCP or TLS-passthrough listener is the supported path. The decision guide: Gateway API or Routes for HTTP(S); Istio Gateway/VirtualService for raw-TCP and passthrough today. In the optional encore you build exactly that raw-TCP path and add a native gateway rate limit with an EnvoyFilter — hammer it, read the 429s — framed honestly as a platform capability, not a replacement for a full API-management product. Take the questions back to your org: is your east-west traffic provably mutual-TLS encrypted and gated by identity, or just assumed safe because it's "inside the cluster"? Can you canary 10% without a redeploy? Do you have an answer when a partner needs raw TCP?
Visual: A decision fork — "HTTP(S)? → Route / Gateway API" vs "raw TCP / SNI passthrough? → Istio Gateway/VirtualService" — with an "EnvoyFilter rate limit → 429" chip on the gateway path and a footnote pointer to Networking for Dev & DevOps (Routes / Gateway API) and Observability (tracing across the mesh).
