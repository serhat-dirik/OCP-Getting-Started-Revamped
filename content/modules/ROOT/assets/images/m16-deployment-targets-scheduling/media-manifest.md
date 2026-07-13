# M16 media manifest — Deployment Targets & Scheduling

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is dual-path but scheduling is YAML/CLI-centric, so the
mandatory recording is a **terminal cast** of the demo arc; screenshots are optional enrichment for the
Console tabs. All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22,
Kubernetes 1.34, 2026-07-13 as user2); the diagram SVG exports below are the deferred media pass. Every
screenshot needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc`
files with a commented `// media-pass:` line — replace with the `image::…` when the asset lands.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m16-deployment-targets-scheduling-01-scheduler-pipeline.svg` | concept.adoc Mermaid "the scheduler in one mental model" | Pending pod (requests/tolerations/selectors) → **FILTER** → **SCORE** → **BIND**; red branch **0 survive → Pending + FailedScheduling**; the mental-model spine — reused on slide 2 |
| `m16-deployment-targets-scheduling-02-seek-vs-repel.svg` | concept.adoc Mermaid "who seeks, who repels" | left **affinity/nodeSelector attracts** (pod → labelled node); right **taint repels**, **toleration only permits** (permitted-but-not-attracted); the module's central distinction — reused on slide 3 |
| `m16-deployment-targets-scheduling-03-what-you-built.svg` | wrapup.adoc Mermaid recap | app tier **spread** (anti-affinity, distinct nodes) + **dedicated batch pool** (toleration+selector) + **PDB guard**; green = spread app, amber = pool, blue = the PDB |

Shared legend across the diagrams: node box, taint shield, toleration key, affinity/anti-affinity
arrows, PDB guard badge — same palette as M01–M15 (Red Hat-neutral, no vendor-logo soup). Do **not**
print product version numbers on the diagrams (native sidecar is described as GA, not by number — matches
the attribute policy). Do **not** print the real cluster's node names — use generic `worker-N` /
`control-plane-N`.

## Recordings

### Terminal cast — dedicated pool break-fix → zero-downtime roll → PDB block (`m16-deployment-targets-scheduling-demo.cast`, ~10 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as `user2` (drive it
straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`):

1. the batch worker on a general node → add `nodeSelector` **alone** → **Pending** with `FailedScheduling` "untolerated taint" (**hold on this** — the money moment);
2. add the toleration → the batch pod **snaps** onto the dedicated pool node (`-o wide`);
3. harden the claims API (`maxUnavailable: 0` + `preStop` + grace) → rollout restart → `available=3/3` **flat** through the whole roll (**hold on the repeating 3/3**);
4. create the PDB → `ALLOWED DISRUPTIONS: 2` → exhaust the budget → an eviction **refused** with *"Cannot evict pod as it would violate the pod's disruption budget"* (the closer).

Step 1→2 (Pending on the taint, then snapping onto the pool) is the module's signature moment; embed
near lab.adoc exercise 4 and the demo arc. Keep the font large and `oc get pods -o wide` on screen — pod
placement is the whole visual. The `sleep 10` after the `nodeSelector` patch is intentional (let the
`Pending` register); don't cut it in the edit.

## Screenshots (optional — Console tabs get visual support; CLI is the source of truth)

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `m16-deployment-targets-scheduling-01-pods-by-node.png` | Console → Workloads → Pods (project `{user}-dev`), the **Node** column visible | Circle: the scattered Node values — two `parasol-claims` on different nodes, `statement-batch` on a general node | lab.adoc ex. 1 Console tab |
| 2 | `m16-deployment-targets-scheduling-02-edit-deployment-affinity.png` | Console → Workloads → Deployments → `parasol-claims` → Actions → Edit Deployment (YAML), `affinity.podAntiAffinity` in view | Circle: `requiredDuringSchedulingIgnoredDuringExecution` + `topologyKey: kubernetes.io/hostname` | lab.adoc ex. 2 Console tab |
| 3 | `m16-deployment-targets-scheduling-03-batch-pending.png` | Console → Workloads → Pods → the `statement-batch` pod `Pending`, its Events showing the untolerated-taint `FailedScheduling` | Circle: the `FailedScheduling` event text "untolerated taint" | lab.adoc ex. 4 Console tab |
| 4 | `m16-deployment-targets-scheduling-04-pdb-allowed-disruptions.png` | Console → Workloads → PodDisruptionBudgets → `parasol-claims`, the **ALLOWED DISRUPTIONS** column = 2 | Circle: `ALLOWED DISRUPTIONS = 2` (3 healthy − minAvailable 1) | lab.adoc ex. 5 Console tab |

**Animated gif (PREFERRED for the break-and-fix story):**
`m16-deployment-targets-scheduling-05-pin-to-pool.gif` (<30 s, silent) — quick cuts:
`statement-batch` on a general node → add `nodeSelector` → **Pending** (untolerated taint) → add
toleration → **Running on the pool node**. The Pending→snap transition is the payoff; hold the two
`-o wide` frames side by side.

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console — no perspective
switch); these confirm the Console-tab click-paths written with `[CAPTURE-VERIFY]` in `lab.adoc`
(the CLI tabs are authoritative):

1. **Workloads → Pods** shows a **Node** column in the project-scoped list (ex. 1).
2. **Workloads → Deployments → `parasol-claims` → Actions → Edit Deployment (YAML)** exposes `spec.template.spec.affinity` and (ex. 5) `spec.strategy` + the container `lifecycle` for the strategy/preStop edit (ex. 2, ex. 5).
3. **Workloads → Deployments → `statement-batch` → Actions → Edit Deployment (YAML)** exposes `spec.template.spec.tolerations` (ex. 4).
4. **Workloads → Pods → `statement-batch` (Pending) → Events** surfaces the `FailedScheduling` "untolerated taint" message (ex. 4).
5. **Workloads → PodDisruptionBudgets → Create** offers a *YAML view* (paste-and-create) and the list shows an **ALLOWED DISRUPTIONS** column (ex. 5).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the 10-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"a selector attracts, a taint repels, a toleration only
permits — a dedicated pool needs all three."*
