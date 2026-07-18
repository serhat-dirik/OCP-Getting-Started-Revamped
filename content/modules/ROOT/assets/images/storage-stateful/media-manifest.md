# M05 media manifest — Storage & Stateful Apps

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

This module is **CLI-first** — the console is not the content, so the mandatory recording is a
**terminal cast** of the demo arc, and screenshots are optional enrichment. All lab mechanics
and every expected-output block were captured on-cluster (OCP 4.21 / ODF external Ceph,
2026-07-09); the diagram SVG exports below are the deferred media pass.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `storage-stateful-01-storage-chain.svg` | concept.adoc Mermaid "storage abstraction chain" — `examples/diagrams/storage-stateful/01-storage-chain.mmd` | Pod → PVC (namespace) → PV (cluster) → StorageClass → Ceph backend; the module's anchor diagram, reused on slide 2. **Owner review M05-1: was too small.** The Mermaid source is now a vertical (`TB`) chain with concise 2-line labels (interim legibility fix); export the SVG **large** and lightbox-enabled (see Lightbox note below). |
| `storage-stateful-02-sts-vs-deployment.svg` | concept.adoc Mermaid "StatefulSet vs Deployment" — `examples/diagrams/storage-stateful/02-sts-vs-deployment.mmd` | left: Deployment (one Service, interchangeable Pods); right: StatefulSet (headless Service, pg-sts-0/1 each with its own PVC); reused on slide 5 |
| `storage-stateful-03-platform-accretion-v5.svg` | concept.adoc TODO(media) | **master accretion diagram**, M05 layer (persistent claims DB + StatefulSet) highlighted on the M01–M04 base |
| `storage-stateful-04-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/storage-stateful/04-what-you-built.mmd` | green = persistent (PVC, StatefulSet, per-Pod PVCs); red = the ephemeral trap that was removed |

Shared legend across all four: namespace box, Pod, volume/disk cylinder, StorageClass tag,
storage-backend cylinder — same palette as M01–M04 (Red Hat-neutral, no vendor-logo soup).

### Lightbox (click-to-enlarge) — shared fix SW-3 / CC-5

All four SVG exports must render at a legible size and open a **click-to-enlarge (lightbox)** view,
per the course-wide diagram-legibility fix (SW-3, a one-time supplemental-ui change). The storage-chain
diagram (`…-01-…`) was called out as too small in the owner review (**M05-1**): its Mermaid
source has been simplified to a vertical (`TB`) chain with concise labels as an interim fix, but the
committed SVG should still be exported larger and wrapped in the lightbox once the supplemental-ui lands.

## Recordings

### Terminal cast — data-loss → redemption (`storage-stateful-demo.cast`, ~8 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as `user1` in
`user1-dev` (drive it straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`):

1. seed three claims via `POST /api/claims`, show `x-total-count: 3`;
2. delete the `claims-db` Pod, restart the app, show the claims gone (`x-total-count: 0`) — the trap;
3. `oc set volume --add --overwrite --name data ... -t pvc` — swap emptyDir for a PVC; show `Pending` (WaitForFirstConsumer) → `Bound`; re-seed three claims;
4. delete the `claims-db` Pod again — show the claims **survive** (`x-total-count: 3`, no app restart).

This is the module's signature moment; embed near lab.adoc exercise 4 and the demo arc.
Keep it tight — the contrast between step 2 (lost) and step 4 (survived) is the whole point.
Warm the app first so there is no cold-boot dead air before seeding.

## Screenshots (optional — console views for enrichment; CLI is the source of truth)

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `storage-stateful-01-pvc-bound.png` | Console → Storage → PersistentVolumeClaims, `claims-db-data` = `Bound`, 2Gi, its StorageClass | Circle: Status `Bound`, Capacity, StorageClass link | lab.adoc ex. 3 (optional) |
| 2 | `storage-stateful-02-storageclass.png` | Console → Storage → StorageClasses, the default class detail (provisioner, binding mode, expansion) | Circle: the `default` badge, `WaitForFirstConsumer`, `Allow volume expansion` | lab.adoc ex. 5 (optional) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 console): the PVC list Status/Capacity/StorageClass
columns; the StorageClass detail page fields (provisioner `openshift-storage.rbd.csi.ceph.com`, binding
`WaitForFirstConsumer`, expansion allowed). These are enrichment only — no lab step depends on a screenshot.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 8-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
