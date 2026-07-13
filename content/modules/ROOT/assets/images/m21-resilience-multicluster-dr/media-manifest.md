# M21 media manifest — Resilience, Multi-Cluster & DR

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
This module's **marquee moment is the restore proving the data survived** — the terminal (or console) showing
an *empty* `{user}-resilience` namespace, then the *same 25 seeded rows* back after the OADP restore — and the
**Service Interconnect two-site topology** for the `[ADD-ON]`. No static diagram conveys "the namespace was
destroyed and the exact data came back," so the delete→restore capture is the priority of the media pass.
All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22, Kubernetes 1.34,
OADP 1.5.7 / Velero 1.16, Red Hat Service Interconnect 2.2.1 / Skupper v2, 2026-07-13 in namespaces
user1-resilience / user1-site-b); the diagram SVG exports and the console/Service-Interconnect screenshots are
the deferred media pass. Every screenshot needs alt text (what it shows + what to notice). Embed points are
marked in the `.adoc` files with a commented `// media-pass:` (diagrams) or `// [CAPTURE-VERIFY]` (console)
line — replace with the `image::…` when the asset lands. **Do not shoot yet** — this is the spec; capture in
the media phase. **Redact the cluster domain** in every screenshot/URL (use `apps.example.com`); never show
the live RHDP cluster domain (privacy guard — the OADP/RHSI route + AccessGrant URLs carry it on-cluster).

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m21-resilience-multicluster-dr-01-resilience-ladder.svg` | concept.adoc Mermaid "The resilience ladder" | five rungs bottom-to-top (pod → node → zone → cluster → region); bottom three **green** (single-cluster resilience: replicas · PDB · spread · HPA), top two **amber** (DR: OADP · GitOps · RHSI); each edge annotated with the mechanism that absorbs it. The module's spine — reused on slide 1 |
| `m21-resilience-multicluster-dr-02-oadp-flow.svg` | concept.adoc Mermaid "OADP backup/restore" | app namespace (objects + PVC) → Velero → NooBaa object store, split "backed-up objects" + "DataUpload: PVC snapshot data"; solid arrows Backup-direction, dashed Restore-direction (Restore recreates objects; DataDownload repopulates a **fresh** PVC). Callout: "data now lives in the store — survives the namespace's deletion." Slide 3 |
| `m21-resilience-multicluster-dr-03-rhsi-van.svg` | concept.adoc Mermaid "RHSI VAN" `[ADD-ON]` | left Site claims-app (app + Listener `claims-db-siteb:5432`), center VAN cloud (mutual-TLS L7, Link = AccessGrant→AccessToken), right Site site-b (Connector selector `app=claims-db` + claims-db "SITE-B data"); matched on routing key `claims-db`. Slide 6 |
| `m21-resilience-multicluster-dr-04-what-you-built.svg` | wrapup.adoc Mermaid recap | the ladder as a recap: green single-cluster resilience absorbing pod/node/zone; amber OADP-restore for destroyed data and GitOps+OADP for a lost cluster; blue "recovered elsewhere"; each edge labeled with the mechanism |

Shared legend across the diagrams: the resilience-ladder rung, the object-store cylinder, the Data Mover
arrow (DataUpload/DataDownload), the Skupper Site/Connector/Listener chips, the VAN cloud — Red Hat-neutral
palette, no vendor-logo soup. Do **not** print the OADP / RHSI version numbers on the diagrams (prose carries
the version via the attribute). Do **not** print the real cluster domain or node names — use `{user}-resilience`,
`{user}-site-b`, and a generic `apps.example.com` / `…-cluster-example-N` node names.

## Screenshots — the restore payoff (MARQUEE) + OpenShift console

Capture in the OCP 4.21 **unified** console (no Developer/Administrator perspective switch). The OADP
Backup/Restore views are under **Operators → Installed Operators → OADP Operator** (project `openshift-adp`,
cluster-admin); the resilient-stack views are the attendee's `{user}-resilience` project; Service Interconnect
is **Networking → Service Interconnect**.

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `m21-resilience-multicluster-dr-01-restore-data-survived.png` | The Terminal (or a two-shot) showing the **empty** `{user}-resilience` namespace after the delete, then the **same 25 rows** (`CLAIMANT-0001 / home / 637` …) after the restore | Circle: the identical first rows before-and-after — "the namespace was empty; the data came back byte-for-byte" | lab.adoc ex. 4 (restore) — **the marquee** |
| 2 | `m21-resilience-multicluster-dr-02-oadp-backup-completed.png` | Console → **Operators → Installed Operators → OADP Operator** → **Backup** tab, `claims-backup-user1` **Completed** with its details (items, phase) | Circle: **Phase: Completed** + the namespace scope — "objects + PVC data, in the object store" | lab.adoc ex. 2 (backup) |
| 3 | `m21-resilience-multicluster-dr-03-service-interconnect-topology.png` | Console → **Networking → Service Interconnect** showing the **two-site** topology (`claims-app` ↔ `site-b`), the link, and the exposed `claims-db` | Circle: the **link between the two sites** + the exposed service — "the app reads the remote DB over this" | lab.adoc ex. 5 (RHSI) `[ADD-ON]` — **second marquee** |
| 4 | `m21-resilience-multicluster-dr-04-resilient-stack.png` | Console → **Workloads → Deployments** (project `{user}-resilience`) with `parasol-claims` **3/3**, plus its **HorizontalPodAutoscaler** and **PodDisruptionBudget** | Circle: **3 of 3** pods on **different nodes** + the PDB "min available 2" — "what absorbs a pod/node loss" | lab.adoc ex. 1 (inspect) |

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console) — these confirm the Console
click-paths written with the `[tabs]` Console tabs in `lab.adoc` (the CLI tabs are authoritative):

1. **Operators → Installed Operators → OADP Operator** (project `openshift-adp`) exposes a **Backup** tab and a **Restore** tab with **Create** buttons (ex. 2, 4), and accepts the `snapshotMoveData` / `restorePVs` fields (via the form or **+Add → Import YAML**).
2. **Workloads → Deployments** (project `{user}-resilience`) shows `parasol-claims` 3/3 and links to its **HorizontalPodAutoscaler** and **PodDisruptionBudget** (ex. 1).
3. **Networking → Service Interconnect** (the RHSI console plugin) lists the **Sites**, their **Connectors/Listeners**, and the **Link**, and draws the topology (ex. 5). If the plugin isn't installed, the CLI `oc get site/connector/listener/link` is authoritative — note that in the shot's caption.
4. The **delete** path — **Workloads → Deployments → ⋮ → Delete** and **Storage → PersistentVolumeClaims → ⋮ → Delete** — for the ex. 3 destroy (the CLI `oc delete all,pvc --all` is authoritative).

## Recordings

### Terminal cast — back up → delete → restore → data survives (+ RHSI flourish) (`m21-resilience-multicluster-dr-demo.cast`, ~12 min, MANDATORY)
Asciinema cast (or screen capture) of the demo-arc happy path, recorded in the Showroom terminal (with a
cluster-admin context for the Backup/Restore), driven straight from the demo-flavor Say/Show/Do blocks in
`lab.adoc`:

1. show the resilient stack + the 25 seeded rows, then a **Backup** completing with a `DataUpload` moving the PVC data to NooBaa;
2. `[the money moment]` `oc delete all,pvc --all` → the namespace **empty**, a query **failing** → a **Restore** completing with a `DataDownload` → the **same 25 rows back** (`CLAIMANT-0001 / home / 637`);
3. `[ADD-ON]` the RHSI VAN already linked → a `psql` from the app namespace returning the **remote** `SITE-B-CLAIMANT` rows through the local `claims-db-siteb` address.

Step 2 (the empty namespace → the exact data restored) is the module's signature moment; embed near lab.adoc
exercise 4 and the demo arc. Keep the before/after row output large and legible — the identical rows are the
whole visual. Everything in the cast runs against the shared OADP + Skupper operators and only mutates the
sample user's `{user}-resilience` / `{user}-site-b` namespaces. **Redact the cluster domain** in any visible
URL (`apps.example.com`), especially the RHSI `AccessGrant`/route URLs (they carry the live domain on-cluster).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the 12-min arc).
Shot list = the Show: lines (the row output before/after the restore for beats 1–2, the terminal for the RHSI
remote read in beat 3); narration = the Say: lines.
The one line that must land in the narration: *"the namespace was empty a minute ago — and the exact 25 rows
are back, byte-for-byte. That's the difference between resilience and disaster recovery: the copy lived in the
object store, and OADP brought the data back, not just the objects."*
