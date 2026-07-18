# M19 media manifest — Serverless Zero-to-Hero

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module's **marquee visuals are the scale-to-zero moments** — the terminal cold start (a ~15 s first
request, then ~0.1 s warm) and the Topology view of a service at **0 pods** waking to **N** — which no
static diagram fully conveys, so the terminal cast and the Topology screenshots are the priority of the
media pass. All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22,
Kubernetes 1.34, OpenShift Serverless 1.37.1 / Knative Serving + Eventing, 2026-07-13 in namespace
user6-dev); the diagram SVG exports and the console/Topology screenshots are the deferred media pass.
Every screenshot needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc`
files with a commented `// media-pass:` (diagrams) or `// [CAPTURE-VERIFY]` (console) line — replace with
the `image::…` when the asset lands. **Do not shoot yet** — this is the spec; capture in the media phase.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `serverless-zero-to-hero-01-request-driven-compute.svg` | concept.adoc Mermaid "The revision model" — `examples/diagrams/serverless-zero-to-hero/01-request-driven-compute.mmd` | client → auto edge Route (Kourier) → the ksvc's Route/Configuration → two immutable Revisions (v1 #stable 80% / v2 #candidate 20%) → **KPA scaling 0..N on concurrency**; an amber side-panel for the eventing taste (PingSource → in-memory Broker → Trigger → back to the ksvc, "wakes from zero"). The module's spine — reused on slide 3 |
| `serverless-zero-to-hero-02-cold-start-timeline.svg` | concept.adoc cold-start NOTE + slide 4 | a single request hitting a **zero-pod** service: activator buffers → pod schedules → JVM boots → response, annotated **"~15 s cold"**, beside a second **"~0.1 s warm"** request; a callout "min-scale: 1 removes the cold start (gives up scale-to-zero)". The honest-tradeoff visual |
| `serverless-zero-to-hero-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/serverless-zero-to-hero/03-what-you-built.mmd` | green = the two revisions (v1 #stable / v2 #candidate · CC=2 · max-scale 3); blue = the Route + KPA Knative manages; amber = the eventing taste (PingSource → Broker → Trigger, "wakes on event → 404 (M20)") |

Shared legend across the diagrams: the ksvc boundary box, the auto-Route (edge/Kourier) chip, the immutable
-revision card, the KPA "0..N on concurrency" badge, the eventing source→broker→trigger row — Red Hat-neutral
palette, no vendor-logo soup. Do **not** print the OpenShift Serverless / Knative version numbers on the
diagrams (prose carries the version via the attribute). Do **not** print the real cluster domain or node
names — use `{user}-dev` and a generic `apps.example.com`.

## Screenshots — OpenShift console, Serverless (MARQUEE; the scale-to-zero picture)

Capture in the OCP 4.21 **unified** console (no Developer/Administrator perspective switch), signed in as the
sample user, project scoped to the user's `{user}-dev`. **Topology needs the traffic state first** — drive
(or stop) traffic per the note before each shot.

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `serverless-zero-to-hero-01-topology-scaled-to-zero.png` | Console → **Topology** (`{user}-dev`), the `parasol-claims` ksvc showing **0 pods** (dashed/hollow scale ring) while idle | Circle: the **0 pods** ring + the "scaled to zero" state | lab.adoc ex. 1 (the "holding zero pods" beat) — **the marquee** |
| 2 | `serverless-zero-to-hero-02-topology-scaled-up.png` | Console → Topology during the ex. 3 burst: the same ksvc showing **3/3 pods** (filled ring) | Circle: the pod ring filled to the **max-scale=3** ceiling | lab.adoc ex. 3 (autoscale-under-load beat) |
| 3 | `serverless-zero-to-hero-03-serverless-services-revisions.png` | Console → **Serverless → Services → parasol-claims**, the Revisions list showing **v1 (stable, 80%)** and **v2 (candidate, 20%)** | Circle: the **80% / 20%** per-revision traffic split | lab.adoc ex. 4 (traffic-split beat) |
| 4 | `serverless-zero-to-hero-04-serverless-eventing.png` | Console → **Serverless → Eventing**, the `default` Broker with the `claims-processor` Trigger and `claim-ticker` PingSource wired to the ksvc | Circle: the **Trigger → parasol-claims** subscriber edge | lab.adoc ex. 5 (eventing-taste beat) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console) — these confirm the Console
click-paths written with the `[tabs]` Console tabs in `lab.adoc` (the CLI tabs are authoritative):

1. **Console → Serverless → Services** lists the `parasol-claims` ksvc with its URL and revisions (ex. 1, 4).
2. **Console → Topology** renders the ksvc scale ring (0 pods idle; fills under load) (ex. 1, 3).
3. **Console → Serverless → Services → YAML** accepts the revision-name + `containerConcurrency` + `traffic` edits (ex. 3, 4).
4. **Console → Serverless → Eventing** (and **+Add → Import YAML**) create/list the Broker, Trigger, and PingSource (ex. 5).

## Recordings

### Terminal cast — cold start → autoscale → split → rollback → eventing (`serverless-zero-to-hero-demo.cast`, ~10 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as the sample user (drive it
straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`), with a second pane running
`oc get pods -n $NS -l serving.knative.dev/service=parasol-claims -w`:

1. no pods → a `curl` that **hangs ~15 s** and returns `200`, then a warm `curl` in **~0.1 s** (**hold on the 15 s cold start** — the money moment);
2. a 12-loop burst → the pod count climbs **0 → 2 → 3** and holds at the ceiling, then **melts back to 0** when the load stops;
3. an 80/20 tag split read from `kn revision list`, then a **one-line rollback** to 100% stable and back;
4. `[closer]` `kn broker create` + a `Trigger` + a `PingSource` → the ksvc **wakes on an event** and returns an honest **`404`** (say why — the app has no handler; that's M20).

Step 1 (the cold start) and step 2 (0→3→0 on the pod-watch pane) are the module's signature terminal
moments; embed near lab.adoc exercises 2 and 3 and the demo arc. Keep the font large and the pod-watch pane
visible — the hanging first request and the pod count climbing/vanishing are the whole visual. Everything in
the cast runs against the shared Serverless control plane and only mutates the sample user's `{user}-dev`
namespace. **Redact the cluster domain** in the URL (`apps.example.com`).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the 10-min arc).
Shot list = the Show: lines (the pod-watch pane for beats 1–2, the terminal for the split/rollback);
narration = the Say: lines.
The one line that must land in the narration: *"fifteen seconds cold, a tenth of a second warm — that 15
seconds is the honest cost of scale-to-zero, and if a path can't take it, I set a warm floor with min-scale.
Nothing hidden."*
