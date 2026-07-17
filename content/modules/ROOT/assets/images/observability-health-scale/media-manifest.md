# M12 media manifest — Observability, Health & Scale

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user2** (or any assigned attendee id) on the workshop cluster, default console theme,
annotate with numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a commented
`// media-pass: …` line — replace with the `image::` (screenshot) or the SVG `image::` (diagram)
when the asset lands. `.png` screenshots and `.svg` diagrams share the NN index space (distinguished
by extension), matching the M10 convention.

**Why this module's screenshots matter.** M12 is the most **console-driven** module in the block —
its home base is the console **Observe** section (Metrics, Alerting, Traces) plus **Topology** for
autoscaling. The build performed the entire lab from the terminal + API and verified every outcome
there (the `/q/metrics` golden signals, the PrometheusRule's *Inactive → Pending → Firing*
progression measured at ~77s/~195s, the `parasol-claims` traces in Tempo, the HPA's 2→4 scale event
at 221% CPU, and the PDB's eviction refusal), **but the console views were not screen-captured** (no
browser in the build environment). Capture them in the media pass — for M12 the console view *is* the
content, and two beats (the trace search and the HPA pod-ring growth) are **multi-click flows that
should be short GIFs/MP4s** per the project owner's 2026-07-11 directive.

> **Signature visual:** `04-alert-firing` — the `ParasolClaimsErrorRateHigh` rule turning **red** in
> *Observe → Alerting* while the database is down. It is the emotional peak of the module (a real page)
> and the one still image every deck/summary should carry.

## Screenshots / recordings (the console view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `observability-health-scale-01-observe-metrics.png` | ⬜ NOT CAPTURED — **HIGH** | **Observe → Metrics** with the `claims_created` rate (or the 404 error-rate) query | the PromQL text, the rising line graph, and that this is user-workload monitoring querying the attendee's namespace | lab.adoc ex. 1 (Console tab) |
| 2 | `observability-health-scale-02-observe-traces.png` | ⬜ NOT CAPTURED — **HIGH (prefer <30s GIF/MP4)** | **Observe → Traces** (COO distributed-tracing plugin) | the TraceQL `{ resource.service.name = "parasol-claims" }`, the trace list sorted by duration, one trace opened to its HTTP span (method/route/status/time) — record the search→open flow | lab.adoc ex. 4 |
| 3 | `observability-health-scale-03-topology-hpa-scale.png` | ⬜ NOT CAPTURED — **HIGH (prefer <30s GIF/MP4)** | **Topology**, `parasol-claims` under load | the pod ring growing from 2 to 4 as the HPA scales out — record ~25s of the burst so the ring visibly grows | lab.adoc ex. 5 (Console tab) |
| 4 | `observability-health-scale-04-alert-firing.png` | ⬜ NOT CAPTURED — **HIGH (signature)** | **Observe → Alerting**, rule **Firing** | `ParasolClaimsErrorRateHigh` red/Firing, severity warning, while `claims-db` is at 0 replicas — the module's money shot | lab.adoc ex. 3 (after the measured-timing note) |
| 5 | `observability-health-scale-05-observe-alerting-inactive.png` | ⬜ NOT CAPTURED | **Observe → Alerting → Alerting rules**, rule **Inactive** | the just-created `ParasolClaimsErrorRateHigh` armed-but-inactive at the healthy baseline (the "before" to #4's "after") | lab.adoc ex. 2 (Console tab) — **`// media-pass:` marker placed** |
| 6 | `observability-health-scale-06-import-yaml.png` | ⬜ OPTIONAL — **no embed marker** | **+ / Import YAML** dialog with the PrometheusRule (or PDB) pasted | the masthead `+` action and the paste-and-Create flow | **Intentionally not embedded** (2026-07-11): the `+` / Import YAML masthead flow is generic OpenShift UI already spelled out in the ex. 2 / ex. 6 Console-tab prose; a screenshot adds little over the signature alerting/topology beats. Capture only if a deck wants it — no `// media-pass:` marker in `lab.adoc`. |

## Diagrams (SVG in-repo; source of truth is the inline Mermaid in the `.adoc`)

The concept/wrap-up pages ship inline Mermaid (editable-source rule satisfied by construction).
Export these to SVG next to their `.adoc` for the slide deck and richer rendering; keep the Mermaid as
the editable source (do not delete it).

| # | Filename | Status | Source (inline Mermaid in) | Shows |
|---|----------|--------|-----------------------------|-------|
| 1 | `observability-health-scale-01-three-signals.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | one request fanning into metrics/logs/traces, each labeled with the question it answers |
| 2 | `observability-health-scale-02-servicemonitor-bridge.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | app `/q/metrics` → ServiceMonitor → user-workload monitoring → console + your PrometheusRule |
| 3 | `observability-health-scale-03-scaling-decision-tree.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | "what is the pressure?" → HPA (highlighted) / Serverless / KEDA / VPA |
| 4 | `observability-health-scale-04-platform-accretion.svg` | ⬜ NOT CAPTURED (shared) | concept.adoc | the observe-&-steer layer (metrics/traces/HPA/PDB) over the M01–M11 Parasol platform |
| 5 | `observability-health-scale-05-what-you-built.svg` | ⬜ NOT CAPTURED (export) | wrapup.adoc | the claims service with ServiceMonitor→UWM→alert, Tempo traces, HPA 2→4, and PDB, all green |

## Recording (demo-arc happy path)

- `observability-health-scale-demo.cast` (asciinema) OR a `<90s` silent screen capture — ⬜ NOT
  CAPTURED. The flagship clip pairs the two live beats: **break the database → the alert goes red in
  Observe → Alerting** (tee it up, cut the ~3-min wait), then **drive load → the Topology pod ring
  grows 2→4** in ~25s. Console-heavy and animated, so a short screen capture of those two moments is
  the highest-value asset for the deck and the demo flavor.
