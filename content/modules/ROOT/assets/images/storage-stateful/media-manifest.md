# M05 media manifest — Storage & Stateful Apps

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

This module is **CLI-first** — the console is not the content, so the mandatory recording is a
**terminal cast** of the demo arc, and screenshots are optional enrichment. All lab mechanics
and every expected-output block were captured on-cluster (OCP 4.21 / ODF external Ceph,
2026-07-09); the diagram SVG exports below are already rendered and committed (2026-07-26, label fix
+ platform-accretion diagram 2026-07-28) — the mandatory terminal cast and the optional screenshots
remain the deferred media pass.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `storage-stateful-01-storage-chain.svg` | concept.adoc Mermaid "storage abstraction chain" — `examples/diagrams/storage-stateful/01-storage-chain.mmd` | Pod → PVC (namespace) → PV (cluster) → StorageClass → Ceph backend; the module's anchor diagram, reused on slide 2. **Owner review M05-1: was too small.** The Mermaid source is now a vertical (`TB`) chain with concise 2-line labels (interim legibility fix); export the SVG **large** and lightbox-enabled (see Lightbox note below). |
| `storage-stateful-02-sts-vs-deployment.svg` | concept.adoc Mermaid "StatefulSet vs Deployment" — `examples/diagrams/storage-stateful/02-sts-vs-deployment.mmd` | left: Deployment (one Service, interchangeable Pods); right: StatefulSet (headless Service, pg-sts-0/1 each with its own PVC); reused on slide 5 |
| `storage-stateful-03-platform-accretion-v5.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/storage-stateful/03-platform-accretion-v5.mmd` | **master accretion diagram**, M05 layer (persistent claims DB + StatefulSet) highlighted on the M01–M04 base |
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
| 1 | `storage-stateful-01-pvc-bound.png` | ✅ CAPTURED 2026-08-01. Proves the claim actually bound to real storage and shows the whole chain in one frame: `claims-db-data` with a `Bound` badge, Requested capacity 2 GiB, Capacity 2 GiB, **Used 45.69 MiB** (the database's real footprint, so the volume is not merely bound but written to), Access modes `ReadWriteOnce`, Volume mode `Filesystem`, and StorageClass `ocs-external-storagecluster-ceph-rbd` as a link. It is the PVC **detail** page, not the PersistentVolumeClaims **list** page this row asked for — the detail page is strictly the better frame here because it is the exact view exercise 5's Console tab walks through field by field, and it carries Status, Capacity, Used, Access modes, Volume mode and the StorageClass link that the list page does not. **Embed point moved from ex. 3 to ex. 5** for that reason: ex. 3 does reach `Bound`, but shows it as the `oc get pvc` table its expected output already prints, and `Used` is only meaningful after the ex. 3–4 claims are on the volume. The frame also confirms the ex. 5 grounding comment in `lab.adoc`: there is **no link to the backing PersistentVolume** anywhere on this page. — historical note kept below for the staging recipe: **the missing-PVC problem is solved; the blocker was a console session.** The 2026-07-30 note below was right that the PVC had been evicted, but treated that as the end of the story. It is staging, and staging is written: `tools/media/jobs-first-block.yaml` runs `ws start` + `ws solve storage-stateful --user user2` in the job's own `pre_sh`, so the PVC exists at shoot time — and that job is deliberately **LAST in the file**, because `ws start storage-stateful` purges `{user}-dev` and evicts `config-multienv`, whose five shots come first (both directions declared in `gitops/entry-states/*/ws-meta.yaml`). The wait asserts `Bound`, not just the PVC name: the name alone passes on a `Pending` PVC, which is precisely the state the lab contrasts against. What is missing is one human OAuth hop — the cached console session answers HTTP 401, and the password-free attendee cockpit does not carry a console session (its *OCP Console* tab is an external link, and the console refuses the iframe with `X-Frame-Options`). Console → Storage → PersistentVolumeClaims → `claims-db-data` detail page = `Bound`, 2Gi, its StorageClass | Circle: Status `Bound`, Capacity, StorageClass link | **lab.adoc ex. 5** (optional; moved from ex. 3 — see the Status cell) |
| 2 | `storage-stateful-02-storageclass.png` | ✅ CAPTURED 2026-07-30 — Console → Storage → StorageClasses, the default class detail (`/k8s/cluster/storageclasses/ocs-external-storagecluster-ceph-rbd`) | Circle: `Default class` = `True`, `Volume binding mode` = `WaitForFirstConsumer`, `Provisioner` = `openshift-storage.rbd.csi.ceph.com`. **Correction: this console build's StorageClass details page does not render an "Allow volume expansion" field at all** — the row above's original Annotate note is wrong; the field simply is not on screen (checked the full rendered page, nothing scrolled off). Drop that circle from the caption. | lab.adoc ex. 5 (optional) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (the console): the PVC list Status/Capacity/StorageClass
columns; the StorageClass detail page fields (provisioner `openshift-storage.rbd.csi.ceph.com`, binding
`WaitForFirstConsumer`, expansion allowed). These are enrichment only — no lab step depends on a screenshot.
**Update 2026-07-30:** row 2's detail page shows Name, Labels, Annotations, Provisioner, Created at,
Owner, Reclaim policy, Default class, Volume binding mode — **no "Allow volume expansion" field
renders anywhere on this page** on this console build, so "expansion allowed" is not confirmable from
this view (the CLI (`oc get sc … -o jsonpath='{.allowVolumeExpansion}'`) remains authoritative for
that fact). Row 1 (`claims-db-data` PVC) is currently unreachable: `storage-stateful` and
`observability-health-scale` both own `{user}-dev` and are mutual `conflictsWith` entries
(`gitops/entry-states/*/ws-meta.yaml`); a later `ws solve observability-health-scale` evicted
storage-stateful and purged its StatefulSet/PVC (`oc get pvc,statefulset -n user1-dev` → no
resources). Needs a fresh `ws solve storage-stateful` to re-shoot.
**Update 2026-08-01:** that re-shoot happened — row 1 is captured and embedded, so the "currently
unreachable" sentence above is history, not status. The eviction hazard it describes is still real:
this row must be staged and shot **after** any `config-multienv` work in the same `{user}-dev`
namespace, per the `conflictsWith` entries in `gitops/entry-states/*/ws-meta.yaml`.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 8-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
