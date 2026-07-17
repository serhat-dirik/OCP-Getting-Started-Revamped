# Networking for Dev & DevOps

## Slide: From a flat network to a controlled one

- Parasol's claims app: web → API → database
- Default network is flat and open
- Any pod can reach any pod, any port
- Nothing is reachable from outside — yet
- The network is a control plane you configure

Notes: Open on the concrete situation. Parasol's claims application is three tiers — a web front end, a claims API, and a Postgres database — sitting on a flat, open network where any pod can reach any other on any port, and nothing is reachable from outside at all. The whole module is how OpenShift turns that network into a control plane: you choose exactly what becomes public (north-south) and you let only the right pods talk to each other (east-west). Same cluster, same app — but by the end the database answers only the API, the front end is the only door in, and none of it is a firewall appliance.
Visual: A three-tier app box (web/API/db) with "everything talks to everything" arrows in grey, inside a cluster frame with no external door — the "before" picture.

## Slide: Two directions of traffic

- North-south: crossing the cluster boundary
- Controlled by what you EXPOSE (Route / Gateway)
- East-west: pod-to-pod inside the cluster
- Controlled by who may TALK (NetworkPolicy / UDN)
- Every tool is one direction or the other

Notes: Every conversation runs in one of two directions, and OpenShift gives you a different tool for each. North-south is traffic crossing the cluster boundary — a browser reaching your front end — and you control it by choosing what to expose; most workloads should never be reachable from outside. East-west is traffic between pods inside the cluster — web calling API, API querying database — and by default it's wide open, so you control it by writing policy or giving a namespace its own network. Knowing which direction you need is half the battle: north-south is a Route or Gateway, east-west is a NetworkPolicy or UDN.
Visual: Reuse concept diagram networking-dev-devops-...-01-traffic-directions.svg — outside→web (north-south, exposure) and web→api→db (east-west, policy).

## Slide: A mental model of the network

- Service: stable name + virtual IP
- Endpoints: the actual pod IPs (via label selector)
- Data plane (OVN-K): programs every node, enforces policy
- Route: tells the router to accept outside traffic
- The #1 bug: a selector that matches no pods

Notes: You don't need OVN-Kubernetes internals — you need one chain. A Service is a stable name and virtual IP for a set of pods; behind it are endpoints, the real pod IPs kept in step with a label selector; the data plane programs every node so a packet reaches a healthy endpoint, and that's where NetworkPolicy is enforced — as flow rules, not a sidecar; and a Route tells the ingress router to accept outside traffic for a hostname. The single most common "networking bug" in the field isn't a firewall — it's a Service whose selector matches no pods: the Service is green, DNS resolves, and every connection fails. Attendees break exactly that on purpose in the lab.
Visual: A left-to-right chain: Service (name/VIP) → Endpoints (pod IPs, selector) → data plane (node flow rules) → Route (router), with a red callout "selector typo → endpoints <none> → all connections fail."

## Slide: North-south — the exposure decision tree

- ClusterIP (default) — in-cluster only, most workloads
- NodePort — a port on every node, learn once
- LoadBalancer — needs a provider, else <pending>
- Route — the workhorse: external, wildcard DNS, edge TLS
- Gateway API — the strategic direction (GA)

Notes: There's a decision tree for "make this reachable," and each rung exists for a reason — stop at the first that fits. ClusterIP is the default and where most workloads stay. NodePort opens the same port on every node — understand it once, reach for it almost never. LoadBalancer asks the platform for an external IP, which only appears if a provider answers — on this bare-metal cluster with no provider it hangs at <pending>, which is the lesson: LoadBalancer is a promise the platform has to be able to keep. Route is the deterministic path — wildcard DNS, edge TLS, no provider — and it's what you actually run. The Gateway API (GatewayClass → Gateway → HTTPRoute, weighted splits) is the portable successor and the strategic direction, GA on OpenShift.
Visual: Reuse concept diagram networking-dev-devops-...-02-exposure-tree.svg — the branching tree from ClusterIP through Route/Gateway, with LoadBalancer flagged "<pending> on bare metal."

## Slide: The honest L4 boundary

- Routes + today's Gateway API: HTTP(S)/SNI-centric
- Route by hostname/path; TLS by SNI
- No raw TCP / UDP / TLS-passthrough
- That's the service mesh's job (a later module)
- Know the boundary — don't fight the Route

Notes: A credibility slide. Routes and today's OpenShift Gateway API are HTTP(S)/SNI-centric — they route by hostname and path and terminate or pass TLS by SNI. They do not expose raw TCP, UDP, or TLS-passthrough for arbitrary protocols; on this cluster the experimental TCPRoute/TLSRoute/UDPRoute APIs are deliberately not installed. When you need L4 ingress — a database port, a custom protocol, gRPC with passthrough — that's the service mesh, covered in the advanced module. Knowing this boundary keeps teams from fighting a Route to do something it was never designed for.
Visual: A split card: left "Route / Gateway API → HTTP(S), SNI, hostname/path" (green); right "raw TCP / UDP / passthrough → service mesh" (amber), arrow pointing to the later module.

## Slide: East-west — default-deny, then precise allows

- Default is allow-all between pods
- Step 1: default-deny the namespace
- Step 2: re-open only the flows the app needs
- db only from api; api only from web
- The gotcha: default-deny eats DNS too

Notes: Inside the cluster the default is allow-all, so a three-tier app's database will happily accept a connection from anything. The pattern to fix it is always the same: apply a default-deny so nothing may talk, then re-open only the flows the app genuinely needs — the database accepts 5432 only from the API, the API accepts 8080 only from the web tier. It's per-pod and per-port, expressed as labels, enforced in the data plane, and the allows become the documentation of what may talk to what. One trap everyone hits: default-deny on egress also blocks DNS, so pods stop resolving names and the app looks broken for the wrong reason — the fix is a deliberate DNS egress allow that names the CoreDNS pods' actual port, not the Service's 53.
Visual: Two-panel before/after: left "default-deny (everything red)"; right "precise allows (web→api→db green, demo-client→db red)", footnote "+ allow DNS egress (CoreDNS port, not 53)".

## Slide: UserDefinedNetwork — isolation without policy

- Primary UDN: a namespace's OWN pod network
- Native isolation — no NetworkPolicy at all
- Layer 2 segment (e.g. 10.20.0.0/16 on ovn-udn1)
- Must exist BEFORE the namespace's first pod
- UDN for whole-namespace; netpol for selective flows

Notes: Sometimes you want a whole namespace isolated and you want it for free. A Primary UserDefinedNetwork gives its namespace its own pod network — a separate Layer 2 segment — so its pods are isolated from every other namespace natively, with no NetworkPolicy at all. It's GA on OpenShift. The trade-off is a hard rule: a Primary UDN must exist before the namespace's first pod (you can't convert a populated namespace), so it's the platform team's decision at creation time — exactly how the workshop's partner namespace was built. Reach for a UDN when isolation is a property of the whole namespace; reach for NetworkPolicy when you need selective flows within or across namespaces. The service mesh is the third layer on top, adding workload identity — a later module.
Visual: Two namespace boxes — "app (NetworkPolicy: 7 rules)" and "partner (UDN: 0 rules, ovn-udn1 / 10.20.0.0/16)" — with a solid wall between them labelled "native, no policy."

## Slide: What you'll do — and map to your org

- Trace a packet; break a selector and fix it
- Expose the front end with an edge Route
- default-deny → precise allows → prove isolation
- Meet a namespace isolated natively by a UDN
- If a debug pod landed in prod, what could it reach?

Notes: Set expectations for the hands-on, all in the attendee's own claims-app namespace, then land the transfer. You trace a packet and break a Service selector to feel the #1 bug; expose the front end with an edge Route and see NodePort and LoadBalancer honestly (the latter stuck at <pending>); apply default-deny, watch the app and DNS break, re-open only what's needed, and prove a debug pod is now blocked from the database while the API still gets through; then meet a partner namespace isolated natively by a UDN with zero policy. Take the questions back: if someone deployed a debug pod in your most sensitive namespace right now, what could it reach — and could you produce, from policy alone, the list of flows your app is actually allowed? And stay honest about restraint: don't hand-write netpols where a UDN fits, don't fight a Route to do L4, don't reach for LoadBalancer when a Route will do, and never default-deny without the DNS allow.
Visual: Numbered arc strip: trace/break-fix → Route → default-deny/allow/prove → UDN reveal; footnote pointer to the Service Mesh module for the mTLS/L7/L4 layer.
