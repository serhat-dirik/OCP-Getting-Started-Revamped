# M20 media manifest — Eventing Deep-Dive & Serverless Workflows

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
This module's **marquee visual is the event-display UI showing a received CloudEvent envelope** — the
`showcase` consumer's own web page rendering `☁️ cloudevents.Event` with its context attributes and the
claim `Data`, and the **dead-letter sink page showing a dead event stamped `knativeerrorcode: 404`**. No
static diagram conveys "the consumer genuinely received and displayed this event," so the event-display and
dead-letter screenshots are the priority of the media pass. All lab mechanics and every expected-output
block were captured on-cluster (OCP 4.21.22, Kubernetes 1.34, OpenShift Serverless Eventing 1.37.1 / Knative
Eventing 1.17, 2026-07-13 in namespace user7-dev); the diagram SVG exports and the console/event-display
screenshots are the deferred media pass. Every screenshot needs alt text (what it shows + what to notice).
Embed points are marked in the `.adoc` files with a commented `// media-pass:` (diagrams) or
`// [CAPTURE-VERIFY]` (console) line — replace with the `image::…` when the asset lands. **Do not shoot
yet** — this is the spec; capture in the media phase.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m20-eventing-deep-dive-01-eventing-model.svg` | concept.adoc Mermaid "The four primitives" | amber seeded PingSource + a "you: POST" actor both feeding a blue in-memory Broker; three green triggers (catch-all, filter `type`, filter `claimpriority`) to the light-blue `claims-consumer`; a dashed "on repeated failure" edge to `claims-dlq`. The module's spine — reused on slide 2 |
| `m20-eventing-deep-dive-02-retries-dlq.svg` | concept.adoc delivery NOTE + slide 5 | a trigger→consumer edge with the consumer marked **broken**; the event bouncing through attempt 0 + retries at **1s/2s/4s** (~8s), then a fat arrow to the dead-letter sink showing a dead-event card with **`knativeerrorcode: 404`** and `knativeerrordest` highlighted. The "not dropped — dead-lettered, with why" visual |
| `m20-eventing-deep-dive-03-what-you-built.svg` | wrapup.adoc Mermaid recap | amber seeded source; blue in-memory broker; the three green triggers (incl. the filtered + retry/DLQ `claims-fraud-review`); light-blue `claims-consumer` + `claims-dlq` dead-letter sink |

Shared legend across the diagrams: the Broker hub, the Trigger-with-filter chip, the CloudEvents envelope
card (type/source/id + extension attr), the scale-to-zero consumer, the dead-letter sink — Red Hat-neutral
palette, no vendor-logo soup. Do **not** print the OpenShift Serverless / Knative version numbers on the
diagrams (prose carries the version via the attribute). Do **not** print the real cluster domain or node
names — use `{user}-dev` and a generic `apps.example.com`.

## Screenshots — the event-display UI (MARQUEE) + OpenShift console, Eventing

Capture in the OCP 4.21 **unified** console (no Developer/Administrator perspective switch) and in the
consumer's **event-display** web page, signed in as the sample user, project scoped to the user's
`{user}-dev`. The event-display page needs an event **just delivered** (drive one per the lab before the shot).

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `m20-eventing-deep-dive-01-event-display-envelope.png` | The `claims-consumer` **event-display** page showing a received `☁️ cloudevents.Event` — `type: com.parasol.claim.submitted`, `source`, `id`, `Validation: valid`, and the claim `Data` | Circle: the **context attributes** + `Validation: valid` — "the consumer genuinely received and displayed this" | lab.adoc ex. 2 (consumer-as-processor beat) — **the marquee** |
| 2 | `m20-eventing-deep-dive-02-dead-letter-event.png` | The `claims-dlq` **event-display** page showing a dead-lettered event with the **`knativeerrorcode: 404`** and `knativeerrordest` extension attributes | Circle: **`knativeerrorcode: 404`** + `knativeerrordest` — "not dropped; dead-lettered with why" | lab.adoc ex. 5 (retries + dead-letter beat) — **the second marquee** |
| 3 | `m20-eventing-deep-dive-03-eventing-triggers.png` | Console → **Serverless → Eventing**, the `default` Broker with the three Triggers (`claims-events`, `claims-fraud-review`, `claims-audit`) and their filters, and the `claim-ticker` PingSource | Circle: the two **filtered** Triggers' filter attributes (`type`, `claimpriority`) | lab.adoc ex. 4 (attribute-filtering beat) |
| 4 | `m20-eventing-deep-dive-04-trigger-filter-edit.png` | Console → **Serverless → Eventing → Trigger** editor (or +Add → Import YAML) showing a Trigger's `filter.attributes` and a `delivery` block with `deadLetterSink` | Circle: the **`deadLetterSink`** + `retry` fields | lab.adoc ex. 5 (delivery-spec beat) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console) — these confirm the Console
click-paths written with the `[tabs]` Console tabs in `lab.adoc` (the CLI tabs are authoritative):

1. **Console → Serverless → Eventing** lists the `default` Broker, the three Triggers with their filters, and the `claim-ticker` PingSource (ex. 1, 4).
2. **Console → Serverless → Eventing → Create → Trigger** exposes a **filter attribute** key/value and a **subscriber** picker (ex. 4).
3. **Console → Serverless → Eventing → Trigger → YAML** (or **+Add → Import YAML**) accepts the `delivery` block (`retry`, `backoffPolicy`, `deadLetterSink`) (ex. 5).
4. The consumer's **event-display page** (`ksvc.status.url`) renders the received CloudEvent envelope, and the `claims-dlq` page renders the dead event with `knativeerror*` attributes (ex. 2, 5) — the product UI, single-path.

## Recordings

### Terminal + browser cast — route → filter → break → dead-letter (`m20-eventing-deep-dive-demo.cast`, ~12 min, MANDATORY)
Asciinema cast (or screen capture with the event-display page visible) of the demo-arc happy path, recorded
in the Showroom terminal as the sample user (drive it straight from the demo-flavor Say/Show/Do blocks in
`lab.adoc`), with the `claims-consumer` and `claims-dlq` **event-display pages** on screen beside the terminal:

1. a `curl` POST of a claim to the **Broker** returning `202` → the consumer page rendering a new `☁️ cloudevents.Event` (the consumer **wakes from zero** to display it — hold on the ~14s wake if you let it settle first);
2. two POSTs — a `claim.submitted` and a `claim.rejected` — the fraud-review filter **dropping** the rejected one (`202` but no delivery on that path);
3. `[the money moment]` re-apply the trigger with the `/process` path → a POST that takes **~8s** (retries) → the **`claims-dlq` page showing the dead event** with **`knativeerrorcode: 404`** (say why — the consumer 404s the path; the event wasn't lost, it was dead-lettered).

Step 1 (the displayed envelope on a woken consumer) and step 3 (the dead event with its error code) are the
module's signature moments; embed near lab.adoc exercises 2 and 5 and the demo arc. Keep the event-display
pages large and legible — the rendered envelope and the `knativeerrorcode` are the whole visual. Everything in
the cast runs against the shared Serverless Eventing control plane and only mutates the sample user's
`{user}-dev` namespace. **Redact the cluster domain** in any visible URL (`apps.example.com`).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the 12-min arc).
Shot list = the Show: lines (the event-display pages for beats 1 and 3, the terminal for the filter counts);
narration = the Say: lines.
The one line that must land in the narration: *"eight seconds — one try plus three retries — and the event
wasn't dropped, it was dead-lettered to a separate sink, stamped `knativeerrorcode: 404` and the destination
that kept failing. No event silently lost, and a record of exactly why."*
