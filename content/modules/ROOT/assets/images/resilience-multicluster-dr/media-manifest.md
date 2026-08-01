# M21 media manifest — Resilience, Multi-Cluster & DR

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module's **marquee moment is the failover**: the client's live log flipping `SITE=A` → `SITE=B` — *every
line still `HTTP 200`* — the instant an entire site is scaled to zero, and back to `A` on recovery. No static
diagram conveys "the whole primary site vanished and the client never dropped a request," so the **live-log
failover capture is the priority of the media pass**. The **Service Interconnect two-site topology** is the
`[ADD-ON]` marquee.
All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22, OpenShift Service
Mesh 3.3.5 / Istio 1.28, Red Hat Service Interconnect 2.2.1 / Skupper v2, 2026-07-13 in namespaces
user1-client / user1-site-a / user1-site-b — the failover flip was measured across ~90 continuous requests
with zero errors). The diagram SVG exports are already rendered and committed (2026-07-26, label fix
2026-07-28) — the console/Service-Interconnect screenshots remain the deferred media pass. Every
screenshot needs alt text (what it shows + what to notice). Embed points are marked in the
`.adoc` files with a commented `// media-pass:` (diagrams) or `// [CAPTURE-VERIFY]` (console) line — replace
with the `image::…` when the asset lands. **Do not shoot those yet** — this is the spec; capture in the media phase.
**Redact the cluster domain** in every screenshot/URL (use `apps.example.com`); never show the live RHDP
cluster domain (privacy guard — the ingress Route and RHSI AccessGrant URLs carry it on-cluster).

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `resilience-multicluster-dr-01-resilience-ladder.svg` | concept.adoc Mermaid "The resilience ladder" — `examples/diagrams/resilience-multicluster-dr/01-resilience-ladder.mmd` | five rungs bottom-to-top (pod → node → zone → **SITE** → region); bottom three **green** (in-site resilience: replicas · PDB · spread · HPA), the SITE rung **amber** (cross-site failover: Service Mesh · RHSI — THIS lab), the region rung **blue** (platform DR net: OADP · GitOps — concept); each edge annotated with the mechanism that absorbs it. The module's spine — reused on slide 1 |
| `resilience-multicluster-dr-02-mesh-failover.svg` | concept.adoc Mermaid "Cross-site failover with Service Mesh" — `examples/diagrams/resilience-multicluster-dr/02-mesh-failover.mmd` | a client → an ingress Gateway ("pinned to site A's locality") → Site A (PRIMARY, solid bold "locality prefers A") and Site B (SECONDARY, dashed "on A failure: outlier ejects A, retries flip to B"); three CR chips ServiceEntry · DestinationRule · VirtualService. The centerpiece — slide 3 |
| `resilience-multicluster-dr-03-rhsi-van.svg` | concept.adoc Mermaid "RHSI VAN" `[ADD-ON]` — `examples/diagrams/resilience-multicluster-dr/03-rhsi-van.mmd` | left Site DC-A (claims client + Listener `claims-remote:8080`), center VAN cloud (mutual-TLS L7, Link = AccessGrant→AccessToken), right Site DC-B (Connector selector `app=parasol-claims` + a claims cylinder "SITE=B"); matched on routing key `claims-cross`. Slide 5 |
| `resilience-multicluster-dr-04-dr-safety-net.svg` | concept.adoc Mermaid "The platform's DR safety net" — `examples/diagrams/resilience-multicluster-dr/04-dr-safety-net.mmd` | top band "YOUR job (this lab)": in-site resilience → cross-site failover (mesh · RHSI); bottom band "PLATFORM's job (concept)": OADP restore data · GitOps re-materialize (M10) · ACM (mention); a dashed arrow "catastrophe beyond failover → the net". Slide 6 |
| `resilience-multicluster-dr-05-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/resilience-multicluster-dr/05-what-you-built.mmd` | the ladder as a recap: green in-site resiliency (pod/node); amber the failover rungs (mesh failover for a lost site, RHSI to link real DCs); blue "survives a site loss" + the platform DR net; each edge labeled with the mechanism |

Shared legend across the diagrams: the resilience-ladder rung, the stable-endpoint/gateway chip, the site
boxes (A green/primary, B amber/secondary), the Service-Mesh CR chips (ServiceEntry/DestinationRule/
VirtualService), the Skupper Site/Connector/Listener chips, the VAN cloud — Red Hat-neutral palette, no
vendor-logo soup. Do **not** print the product version numbers on the diagrams (prose carries the version via
the attribute). Do **not** print the real cluster domain or node names — use `{user}-client` / `{user}-site-a`
/ `{user}-site-b` and generic `…-cluster-example-N` node names.

## Screenshots — the failover payoff (MARQUEE) + OpenShift console

Capture in the **unified** console (no Developer/Administrator perspective switch). The resilient-tier
views are the attendee's `{user}-site-a` project (**Workloads → Deployments**); the mesh CRs live in
`{user}-client` (**Networking → ServiceEntries / DestinationRules / VirtualServices**, or masthead **+**
(Quick create) → **Import YAML**); Service Interconnect is **Networking → Service Interconnect**.

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `resilience-multicluster-dr-01-failover-log-flip.png` | ✅ CAPTURED 2026-08-01 (cluster 2, user8, in the Showroom cockpit's ttyd terminal — the attendee's own shell). **A still, not the preferred gif** — and it holds up, because the whole story fits in one frame: `oc scale deploy/parasol-claims -n $SITEA --replicas=0` and its `scaled` confirmation on top, then `oc logs -f deploy/claims-client`, then **nine** consecutive `HTTP 200 served-by-site=A` lines followed by an unbroken run of `HTTP 200 served-by-site=B`. Measured flip: the last A at `23:19:05`, the first B at `23:19:06`. Site A was scaled back to 3 and traffic confirmed back on A afterwards. **NOTE the trap:** the first take was correct but framed into a mostly-black 875 px terminal; it was re-shot only after site A had been restored and the client log proven to read `A` again, so the flip in the committed image is a real one, not a re-crop of a stale state | Circle: the A→B flip line + a run of `200`s on both sides | lab.adoc ex. 2 (failover) — **the marquee** |
| 2 | `resilience-multicluster-dr-02-resilient-site.png` | ⬜ NOT CAPTURED 2026-08-01 — **blocked on console authentication** (see the note below). The state itself was live and correct throughout: `parasol-claims` **3/3**, PDB min-available **2** with 1 allowed disruption, HPA `cpu 4%/80%` min 3 / max 6 | Circle: **3 of 3** pods + the PDB "min available 2" | lab.adoc ex. 1 (inspect) |
| 3 | `resilience-multicluster-dr-03-service-interconnect-topology.png` | ⬜ NOT CAPTURED 2026-08-01 — **the console path does not exist on this cluster**, which this row already anticipated. Red Hat Service Interconnect **is** installed (`skupper-operator.v2.2.1-rh-1`, `*.skupper.io` CRDs present) but it registers **no console plugin**: `oc get consoleplugins` returns ten plugins, none of them Skupper/Service Interconnect, and the console operator's enabled list has no entry for one. So there is no **Networking → Service Interconnect** nav item to photograph here. Per this row's own fallback, the CLI (`oc get site/connector/listener/link`) is authoritative. A console login would not change this | — | lab.adoc ex. 3 (RHSI) `[ADD-ON]` |
| 4 | `resilience-multicluster-dr-04-mesh-failover-crs.png` | ⬜ NOT CAPTURED 2026-08-01 — **blocked on console authentication** (see the note below). Unlike row 3 this one is plugin-independent (Import YAML + the Networking list pages are stock console), so one human login makes it capturable | Circle: the three resources | lab.adoc ex. 2 (wire the routing) |

### Capture note, 2026-08-01

**Console rows are blocked on an OAuth session, nothing else.** A console session requires a human
to type a password into the OpenShift login page (`tools/media/login.py` exists for exactly that),
and the operator of this pass is barred from typing credentials anywhere. The cached
`tools/media/shot-profile.session.json` holds a valid session for a *different* cluster; for
cluster 2 it carries only an unfinished `login-state`, and a headless probe of that console
returned **401**. Rows 2 and 4 are one login away. Row 3 is not — see its cell.

**The terminal shot did not need one.** The Showroom cockpit proxies a `ttyd` terminal at
`<showroom-userN>/tty-top/` with no login, already running as the attendee (`oc whoami` → `user8`),
and Playwright can type into it and send Enter. `window.term` exposes the xterm buffer, so the
frame can be asserted (both `served-by-site=A` and `=B` present, no `HTTP 503`/`HTTP 000`) before
the shutter, and cropped to the rows the shell actually wrote.

**Domain hygiene:** this module's manifest header asks for the cluster domain to be redacted. No
redaction was needed — the captured frame references the namespaces only through the `$SITEA` and
`$CLIENT` shell variables, so no domain is rendered. (Note also that the standing owner decision of
2026-07-26 accepts ephemeral RHDP cluster domains inside captured images; credentials never.)

`[CAPTURE-VERIFY]` labels to confirm while shooting (the unified console) — these confirm the Console
click-paths written with the `[tabs]` Console tabs in `lab.adoc` (the CLI tabs are authoritative):

1. Masthead **+** (Quick create) → **Import YAML** (project `{user}-client`) accepts a multi-document paste of the `ServiceEntry` +
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
