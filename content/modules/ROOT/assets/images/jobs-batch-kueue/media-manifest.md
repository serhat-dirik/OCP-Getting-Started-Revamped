# M06 media manifest — Jobs, Batch & Queued Workloads

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is not the content, so the mandatory recording is a
**terminal cast** of the demo arc, and screenshots are optional enrichment. All lab mechanics and
every expected-output block were captured on-cluster (OCP 4.21 / Red Hat build of Kueue 1.3.1,
2026-07-09 as user8); the diagram SVG exports below are all rendered (2026-07-26, label fix and
platform-accretion diagram 2026-07-28) — the recordings and optional screenshots are the remaining
media pass. Every screenshot needs alt text (what it shows + what to notice). Embed points are
marked in the `.adoc` files with a commented `// media-pass: image::…` line — uncomment when the
asset lands.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Status | Source | Notes |
|----------|--------|--------|-------|
| `jobs-batch-kueue-01-async-spectrum.svg` | ✅ RENDERED 2026-07-26 (label fix 2026-07-28) | concept.adoc Mermaid "async spectrum" — `examples/diagrams/jobs-batch-kueue/01-async-spectrum.mmd` | request-driven → event-driven → **batch** (highlighted); the framing diagram, reused on slide 2 |
| `jobs-batch-kueue-02-kueue-admission.svg` | ✅ RENDERED 2026-07-26 (label fix 2026-07-28) | concept.adoc Mermaid "admission flow" — `examples/diagrams/jobs-batch-kueue/02-kueue-admission.mmd` | Job (labelled) → LocalQueue → ClusterQueue quota → **admitted / pending / preempted**; the module's anchor diagram, reused on slide 5 |
| `jobs-batch-kueue-03-platform-accretion-v23.svg` | ✅ RENDERED 2026-07-28 | concept.adoc — `examples/diagrams/jobs-batch-kueue/03-platform-accretion-v23.mmd` | **master accretion diagram**, the M06 layer (batch tier + admission control) highlighted on the running Parasol platform |
| `jobs-batch-kueue-04-what-you-built.svg` | ✅ RENDERED 2026-07-26 (label fix 2026-07-28) | wrapup.adoc Mermaid recap — `examples/diagrams/jobs-batch-kueue/04-what-you-built.mmd` | Job/CronJob → LocalQueue → ClusterQueue (admitted / pending / preempted), with the AI inference job feeding the *same* LocalQueue (green = ran to completion; amber = queued/preempted) |

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

| # | Filename | Status | View | Annotate | Embed point |
|---|----------|--------|------|----------|-------------|
| 1 | `jobs-batch-kueue-01-workloads-admitted.png` | ✅ CAPTURED 2026-08-01, embedded at `lab.adoc` ex. 5 right after the `ADMITTED True/True/<none>/<none>/<none>` expected output. **Proves the queue is a queue, not a failure**: five Workloads, `job-batch-low-1` … `-5`, all on `user-queue`; the first two carry a ClusterQueue in *Reserved in* and `True` under *Admitted*, the other three a dash in both — held, not rejected. **And it settles the row's own open question: the `additionalPrinterColumns` DO render** on this console build (Queue / Reserved in / Admitted / Finished / Age are all present), so the shot is readable rather than six bare names. Enrichment only — no lab step depends on it. Historical note below kept for the staging recipe. — **staging solved and PROVEN; was blocked only on a console session** (2026-08-01). Three earlier passes found this namespace at rest (every Job Complete, one Workload Admitted+Finished) and recorded that as the blocker; the real gap was that nobody had written the staging. `tools/media/stage-jobs-batch-kueue.sh {user} queued` now does it, and was **run for real as `user2`**: it settled at exactly *2 admitted of 5 Workloads*, matching the lab's expected output. It waits on the `Admitted` condition, not a timer, and holds the low-priority Jobs on a longer `sleep` so the pattern cannot dissolve mid-shot. Two things found while writing it, both worth knowing: the served **storage version is `v1beta2`**, not the `v1beta1` this manifest's prose says (`oc get crd workloads.kueue.x-k8s.io`), so the console URL is `…/kueue.x-k8s.io~v1beta2~Workload`; and this is a *generic custom-resource list page*, so whether the `Admitted` column renders at all depends on the console honouring the CRD's `additionalPrinterColumns` (which the CRD does define: Queue / Reserved in / Admitted / Finished / Age). The job asserts `Admitted` **in frame** for exactly that reason — if the column is absent the job fails loudly instead of committing a picture of six bare names, and the row's premise is then the thing that is wrong. Enrichment only — no lab step depends on it. | Console → search `Workload` (kueue.x-k8s.io) in `{user}-batch`, the list showing 2 Admitted / 3 Pending | Circle: the two `Admitted=True` rows vs the three pending | lab.adoc ex. 5 (optional) |
| 2 | `jobs-batch-kueue-02-preempted-conditions.png` | ✅ CAPTURED 2026-08-01, embedded at `lab.adoc` ex. 5 right after the five-condition expected output. Proves the module's signature claim in the object's own words: the evicted Workload shows *Admitted* `False` and *Reserved in* empty at the top, and all five conditions below — `QuotaReserved=False (Pending)`, `Evicted=True (Preempted)`, `Admitted=False (NoReservation)`, `Preempted=True (InClusterQueue)`, `Requeued=True (Preempted)` — with the Preempted and Requeued messages both naming prioritization in the ClusterQueue. `Requeued=True` beside `Evicted=True` is the whole point: put back in line, not dropped. The victim's name in this frame is the one Kueue chose on the run it was shot on; a re-shoot will name a different Workload and that is expected. Historical note below kept for the staging recipe. — **staging solved and PROVEN; was blocked only on a console session** (2026-08-01). `stage-jobs-batch-kueue.sh {user} preempted` submits the one `batch-high` Job and then waits until a low Workload actually reports `Preempted=True` — run as `user2`, it produced the lab's five conditions verbatim (`Evicted=True (Preempted)`, `Admitted=False (NoReservation)`, `Preempted=True (InClusterQueue)`, `Requeued=True (Preempted)`). Which Workload gets evicted is Kueue's choice, so the job resolves the victim's name with `url_sh` rather than hardcoding it, and the conditions table sits below the fold — hence a 1600×1400 viewport plus `scroll_to_text`. | Console → the preempted Workload's Conditions (`Evicted`/`Preempted`/`Requeued`) | Circle: `Preempted: True` and `Requeued: True` | lab.adoc ex. 5 (optional) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (the cluster's current release): the Workload list
is reached via the top **search** box (no dedicated Kueue nav item observed on 4.21, 2026-07-09 —
reverify on the cluster's current release) — confirm `Workload` and `LocalQueue` resolve under
`kueue.x-k8s.io`; the Job list shows the Kueue-suspended jobs with `0` active while pending. These are
enrichment only — no lab step depends on a screenshot.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 10-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"the machinery that keeps a claims batch fair is the
machinery that keeps teams from fighting over GPUs — same object, same queue."*
