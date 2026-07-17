# M21 media manifest — Resilience, Multi-Cluster & DR

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
This module's **marquee moment is the failover**: the client's live log flipping `SITE=A` → `SITE=B` — *every
line still `HTTP 200`* — the instant an entire site is scaled to zero, and back to `A` on recovery. No static
diagram conveys "the whole primary site vanished and the client never dropped a request," so the **live-log
failover capture is the priority of the media pass**. The **Service Interconnect two-site topology** is the
`[ADD-ON]` marquee.
All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22, OpenShift Service
Mesh 3.3.5 / Istio 1.28, Red Hat Service Interconnect 2.2.1 / Skupper v2, 2026-07-13 in namespaces
user1-client / user1-site-a / user1-site-b — the failover flip was measured across ~90 continuous requests
with zero errors). The diagram SVG exports and the console/Service-Interconnect screenshots are the deferred
media pass. Every screenshot needs alt text (what it shows + what to notice). Embed points are marked in the
`.adoc` files with a commented `// media-pass:` (diagrams) or `// [CAPTURE-VERIFY]` (console) line — replace
with the `image::…` when the asset lands. **Do not shoot yet** — this is the spec; capture in the media phase.
**Redact the cluster domain** in every screenshot/URL (use `apps.example.com`); never show the live RHDP
cluster domain (privacy guard — the ingress Route and RHSI AccessGrant URLs carry it on-cluster).

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `resilience-multicluster-dr-01-resilience-ladder.svg` | concept.adoc Mermaid "The resilience ladder" | five rungs bottom-to-top (pod → node → zone → **SITE** → region); bottom three **green** (in-site resilience: replicas · PDB · spread · HPA), the SITE rung **amber** (cross-site failover: Service Mesh · RHSI — THIS lab), the region rung **blue** (platform DR net: OADP · GitOps — concept); each edge annotated with the mechanism that absorbs it. The module's spine — reused on slide 1 |
| `resilience-multicluster-dr-02-mesh-failover.svg` | concept.adoc Mermaid "Cross-site failover with Service Mesh" | a client → an ingress Gateway ("pinned to site A's locality") → Site A (PRIMARY, solid bold "locality prefers A") and Site B (SECONDARY, dashed "on A failure: outlier ejects A, retries flip to B"); three CR chips ServiceEntry · DestinationRule · VirtualService. The centerpiece — slide 3 |
| `resilience-multicluster-dr-03-rhsi-van.svg` | concept.adoc Mermaid "RHSI VAN" `[ADD-ON]` | left Site DC-A (claims client + Listener `claims-remote:8080`), center VAN cloud (mutual-TLS L7, Link = AccessGrant→AccessToken), right Site DC-B (Connector selector `app=parasol-claims` + a claims cylinder "SITE=B"); matched on routing key `claims-cross`. Slide 5 |
| `resilience-multicluster-dr-04-dr-safety-net.svg` | concept.adoc Mermaid "The platform's DR safety net" | top band "YOUR job (this lab)": in-site resilience → cross-site failover (mesh · RHSI); bottom band "PLATFORM's job (concept)": OADP restore data · GitOps re-materialize (M10) · ACM (mention); a dashed arrow "catastrophe beyond failover → the net". Slide 6 |
| `resilience-multicluster-dr-05-what-you-built.svg` | wrapup.adoc Mermaid recap | the ladder as a recap: green in-site resiliency (pod/node); amber the failover rungs (mesh failover for a lost site, RHSI to link real DCs); blue "survives a site loss" + the platform DR net; each edge labeled with the mechanism |

Shared legend across the diagrams: the resilience-ladder rung, the stable-endpoint/gateway chip, the site
boxes (A green/primary, B amber/secondary), the Service-Mesh CR chips (ServiceEntry/DestinationRule/
VirtualService), the Skupper Site/Connector/Listener chips, the VAN cloud — Red Hat-neutral palette, no
vendor-logo soup. Do **not** print the product version numbers on the diagrams (prose carries the version via
the attribute). Do **not** print the real cluster domain or node names — use `{user}-client` / `{user}-site-a`
/ `{user}-site-b` and generic `…-cluster-example-N` node names.

## Screenshots — the failover payoff (MARQUEE) + OpenShift console

Capture in the OCP 4.21 **unified** console (no Developer/Administrator perspective switch). The resilient-tier
views are the attendee's `{user}-site-a` project (**Workloads → Deployments**); the mesh CRs live in
`{user}-client` (**Networking → ServiceEntries / DestinationRules / VirtualServices**, or **+Add → Import
YAML**); Service Interconnect is **Networking → Service Interconnect**.

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `resilience-multicluster-dr-01-failover-log-flip.png` | The Terminal tailing `oc logs -f deploy/claims-client` showing the moment it flips from `HTTP 200 served-by-site=A` to `HTTP 200 served-by-site=B` (with the `oc scale ... --replicas=0` visible above) | Circle: the A→B flip line + a run of `200`s on both sides — "the whole site A is gone; not one request dropped" | lab.adoc ex. 2 (failover) — **the marquee** (gif/mp4 preferred over a still — the flip is motion) |
| 2 | `resilience-multicluster-dr-02-resilient-site.png` | Console → **Workloads → Deployments** (project `{user}-site-a`) with `parasol-claims` **3/3**, plus its **HorizontalPodAutoscaler** and **PodDisruptionBudget** | Circle: **3 of 3** pods on **different nodes** + the PDB "min available 2" — "what absorbs a pod/node loss" | lab.adoc ex. 1 (inspect) |
| 3 | `resilience-multicluster-dr-03-service-interconnect-topology.png` | Console → **Networking → Service Interconnect** showing the **two-site** topology (`dc-a` ↔ `dc-b`), the link, and the exposed `claims` service | Circle: the **link between the two sites** + the exposed service — "DC-A reads DC-B's claims over this" | lab.adoc ex. 3 (RHSI) `[ADD-ON]` — **second marquee** |
| 4 | `resilience-multicluster-dr-04-mesh-failover-crs.png` | Console → **+Add → Import YAML** (project `{user}-client`) with the three failover CRs pasted, or the created **VirtualService**/**DestinationRule**/**ServiceEntry** list | Circle: the three resources — "one ServiceEntry (both sites), a locality/outlier DestinationRule, a retry VirtualService on the gateway" | lab.adoc ex. 2 (wire the routing) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console) — these confirm the Console
click-paths written with the `[tabs]` Console tabs in `lab.adoc` (the CLI tabs are authoritative):

1. **+Add → Import YAML** (project `{user}-client`) accepts a multi-document paste of the `ServiceEntry` +
   `DestinationRule` + `VirtualService` and creates all three (ex. 2). The created resources appear under
   **Networking → VirtualServices / DestinationRules / ServiceEntries**.
2. **Workloads → Deployments** (project `{user}-site-a`) shows `parasol-claims` 3/3 and links to its
   **HorizontalPodAutoscaler** and **PodDisruptionBudget** (ex. 1).
3. **Networking → Service Interconnect** (the RHSI console plugin) lists the **Sites**, their
   **Connectors/Listeners**, and the **Link**, and draws the two-site topology (ex. 3). If the plugin isn't
   installed, the CLI `oc get site/connector/listener/link` is authoritative — note that in the shot's caption.

## Recordings

### Terminal cast / screen capture — fail an entire site, the client never notices (`resilience-multicluster-dr-demo.cast`, ~8 min, MANDATORY)
Asciinema cast (or a silent screen capture — **the live log flip is motion, so a screen capture is preferred**)
of the demo-arc happy path, recorded in the Showroom terminal, driven straight from the demo-flavor Say/Show/Do
blocks in `lab.adoc`. Use a **split view**: a left pane tailing the client log, a right pane running the scale
commands.

1. show the resilient primary (`oc get deploy,pdb,hpa -n {user}-site-a`) and the left pane's client log steadily reading `served-by-site=A`;
2. `[the money moment]` `oc scale deploy/parasol-claims -n {user}-site-a --replicas=0` → the left log flips to `served-by-site=B` within a few seconds, **every line still `HTTP 200`**;
3. `oc scale ... --replicas=3` → the left log flips **back** to `served-by-site=A` after ~30 s (failback).

Optionally append the `[ADD-ON]` RHSI beat (the two Sites, the Link, and the cross-site read returning `SITE=B`
through the local `claims-remote` address). Step 2 (the whole site gone → the client kept getting `200`s) is the
module's signature moment; embed near lab.adoc exercise 2 and the demo arc. Keep the log pane large and legible
— the A→B flip with unbroken `200`s is the whole visual. Everything runs against the shared Service Mesh +
Skupper operators and only mutates the sample user's three namespaces. **Redact the cluster domain** in any
visible URL (`apps.example.com`), especially the RHSI `AccessGrant`/route URLs (they carry the live domain
on-cluster).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the ~11-min arc).
Shot list = the Show: lines (the client-log pane before/during/after the failover for beats 1–3, the terminal
for the RHSI remote read if appended); narration = the Say: lines.
The one line that must land in the narration: *"the entire primary site is gone — and the client didn't drop a
single request. It never changed its address; the mesh detected site A failing, ejected it, and retried onto
site B. That's automatic cross-site failover — three small resources, zero application code."*
