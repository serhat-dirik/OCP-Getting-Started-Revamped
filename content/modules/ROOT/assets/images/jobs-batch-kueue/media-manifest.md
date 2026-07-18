# M06 media manifest — Jobs, Batch & Queued Workloads

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is not the content, so the mandatory recording is a
**terminal cast** of the demo arc, and screenshots are optional enrichment. All lab mechanics and
every expected-output block were captured on-cluster (OCP 4.21 / Red Hat build of Kueue 1.3.1,
2026-07-09 as user8); the diagram SVG exports below are the deferred media pass. Every screenshot
needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: image::…` line — uncomment when the asset lands.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `jobs-batch-kueue-01-async-spectrum.svg` | concept.adoc Mermaid "async spectrum" — `examples/diagrams/jobs-batch-kueue/01-async-spectrum.mmd` | request-driven → event-driven → **batch** (highlighted); the framing diagram, reused on slide 2 |
| `jobs-batch-kueue-02-kueue-admission.svg` | concept.adoc Mermaid "admission flow" — `examples/diagrams/jobs-batch-kueue/02-kueue-admission.mmd` | Job (labelled) → LocalQueue → ClusterQueue quota → **admitted / pending / preempted**; the module's anchor diagram, reused on slide 5 |
| `jobs-batch-kueue-03-platform-accretion-v23.svg` | concept.adoc — media-pass pending (no inline Mermaid source; centrally maintained master diagram) | **master accretion diagram**, the M06 layer (batch tier + admission control) highlighted on the running Parasol platform |
| `jobs-batch-kueue-04-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/jobs-batch-kueue/04-what-you-built.mmd` | Job/CronJob → LocalQueue → ClusterQueue (admitted / pending / preempted), with the AI inference job feeding the *same* LocalQueue (green = ran to completion; amber = queued/preempted) |

Shared legend across all four: namespace box, Job/Pod, queue (LocalQueue/ClusterQueue) tag, quota
gauge, priority chevron — same palette as M01–M05 (Red Hat-neutral, no vendor-logo soup).

## Recordings

### Terminal cast — the queue, the preemption, the AI beat (`jobs-batch-kueue-demo.cast`, ~10 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as `user1` in
`user1-batch` (drive it straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`):

1. run the monthly-statement Job, watch it advance `0 → 3 → 6` in two waves;
2. submit five `batch-low` jobs, show **two admitted, three pending** in `oc get workloads`;
3. submit one `batch-high` job — show the **preemption**: a running low Workload flips to `Preempted`/`Requeued`, the high one is `Admitted` (this is the money shot — hold on it);
4. run the fraud-inference Job through the same LocalQueue; show the `fraud-risk:` verdicts and the `Admitted` Workload — "AI batch is just batch."

The preemption in step 3 is the module's signature moment; embed near lab.adoc exercise 5 and the
demo arc. Keep the low-priority jobs on a long `sleep` so they don't finish mid-cast and blur the
eviction. Warm the images first so there is no cold-pull dead air before the first wave.

## Screenshots (optional — console views for enrichment; CLI is the source of truth)

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `jobs-batch-kueue-01-workloads-admitted.png` | Console → search `Workload` (kueue.x-k8s.io) in `user1-batch`, the list showing 2 Admitted / 3 Pending | Circle: the two `Admitted=True` rows vs the three pending | lab.adoc ex. 5 (optional) |
| 2 | `jobs-batch-kueue-02-preempted-conditions.png` | Console → the preempted Workload's Conditions (`Evicted`/`Preempted`/`Requeued`) | Circle: `Preempted: True` and `Requeued: True` | lab.adoc ex. 5 (optional) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 console): the Workload list is reached
via the top **search** box (there is no dedicated Kueue nav item in 4.21) — confirm `Workload` and
`LocalQueue` resolve under `kueue.x-k8s.io`; the Job list shows the Kueue-suspended jobs with
`0` active while pending. These are enrichment only — no lab step depends on a screenshot.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 10-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"the machinery that keeps a claims batch fair is the
machinery that keeps teams from fighting over GPUs — same object, same queue."*
