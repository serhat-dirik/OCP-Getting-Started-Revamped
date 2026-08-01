# M16 media manifest — Deployment Targets & Scheduling

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is dual-path but scheduling is YAML/CLI-centric, so the
mandatory recording is a **terminal cast** of the demo arc; screenshots are optional enrichment for the
Console tabs. All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22,
Kubernetes 1.34, 2026-07-13 as user2); the diagram SVG exports below are already rendered and committed
(2026-07-26, label-space fix 2026-07-28) — the mandatory terminal cast and the optional screenshots
remain the deferred media pass. Every
screenshot needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc`
files with a commented `// media-pass:` line — replace with the `image::…` when the asset lands.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `deployment-targets-scheduling-01-scheduler-pipeline.svg` | concept.adoc Mermaid "the scheduler in one mental model" — `examples/diagrams/deployment-targets-scheduling/01-scheduler-pipeline.mmd` | Pending pod (requests/tolerations/selectors) → **FILTER** → **SCORE** → **BIND**; red branch **0 survive → Pending + FailedScheduling**; the mental-model spine — reused on slide 2 |
| `deployment-targets-scheduling-02-seek-vs-repel.svg` | concept.adoc Mermaid "who seeks, who repels" — `examples/diagrams/deployment-targets-scheduling/02-seek-vs-repel.mmd` | left **affinity/nodeSelector attracts** (pod → labelled node); right **taint repels**, **toleration only permits** (permitted-but-not-attracted); the module's central distinction — reused on slide 3 |
| `deployment-targets-scheduling-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/deployment-targets-scheduling/03-what-you-built.mmd` | app tier **spread** (anti-affinity, distinct nodes) + **dedicated batch pool** (toleration+selector) + **PDB guard**; green = spread app, amber = pool, blue = the PDB |
| `deployment-targets-scheduling-04-reseed-on-boot.svg` | concept.adoc Mermaid "the other half of zero-downtime" — `examples/diagrams/deployment-targets-scheduling/04-reseed-on-boot.mmd` | shared PostgreSQL; the OLD pod serving (INSERT committed) while the NEW pod boots **drop-and-create** and reseeds → the client's new claim **silently discarded, no error**; red = the booting pod's reseed, blue = shared db, green = still-serving old pod; the data-plane-at-startup fault the re-diagnosis surfaced (2026-07-16) |

Shared legend across the diagrams: node box, taint shield, toleration key, affinity/anti-affinity
arrows, PDB guard badge — same palette as M01–M15 (Red Hat-neutral, no vendor-logo soup). Do **not**
print product version numbers on the diagrams (native sidecar is described as GA, not by number — matches
the attribute policy). Do **not** print the real cluster's node names — use generic `worker-N` /
`control-plane-N`.

## Recordings

### Terminal cast — dedicated pool break-fix → zero-downtime roll → PDB block (`deployment-targets-scheduling-demo.cast`, ~10 min, MANDATORY)
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
> **Media-pass status, 2026-08-01.** The console rows in this module could not be shot: the OpenShift
> console sits behind OpenShift OAuth, the cached capture session in `shot-profile.session.json` had
> expired (a probe came back as a 25 KB PNG of the IdP chooser — conventions §4 exactly), and
> establishing a new one needs a human to type a password, which that lane is barred from doing.
> What the lane did instead: it **staged and proved every cluster state these shots need** on
> `user7` and wrote them into `tools/media/jobs-m14-m19-console.yaml` with the staging scripts
> (`tools/media/stage-m1*.sh`). One login window now runs the whole block. Per-row status below.


| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `deployment-targets-scheduling-01-pods-by-node.png` | ✅ CAPTURED 2026-08-01 as **user7**, but NOT by a jobs row — by `tools/media/capture_m17_pods_by_node.py`, and the reason is a finding this module's own `[CAPTURE-VERIFY]` markers at lab.adoc:168/:176 were asking about. **The console's Pods list has no Node column at all by default.** Grounded: the defaults are Name, Status, Ready, Restarts, Owner, Memory, CPU, Created. The job version of this row failed with `never saw 'Node'` against a namespace that was in exactly the right state — the state was never the problem. Adding the column is three interactions (icon-only *Column management* → tick **Node** → *Save*) and `capture.py` can express none of them, so the shot follows the directory's existing bespoke-script pattern. The script asserts the spread from the RENDERED table, not the API. Two things to know: the column preference PERSISTS for that attendee slot (which is what the lab tells them to do anyway), and the frame shows **three** parasol-claims replicas because it was taken after the anti-affinity staging scaled up — the alt text says so out loud rather than letting the picture contradict the prose's *two*. | Circle: the scattered Node values — two `parasol-claims` on different nodes, `statement-batch` on a general node | lab.adoc ex. 1 Console tab |
| 2 | `deployment-targets-scheduling-02-edit-deployment-affinity.png` | ✅ CAPTURED 2026-08-01 as **user7**, at viewport height **2400**, and the height is the whole story. At 1100 the job failed with `never saw 'podAntiAffinity'` against a Deployment that provably carried the rule. The console's YAML editor VIRTUALIZES — only lines near its own viewport are in the DOM — so the block did not exist to be waited on, and `scroll_to_text` could not have rescued it either (it searches the DOM too). Binary-searched with the page open: 1100 no, 1800 no, 2000 no, 2200 no, 2400 yes. The frame is worth the height: the console folds `managedFields` into one line, so the document runs 1-14 then jumps to 170, and the entire workload spec — resources, both probes, env, the affinity block at 235-241, strategy — lands in a single picture. | Circle: `requiredDuringSchedulingIgnoredDuringExecution` + `topologyKey: kubernetes.io/hostname` | lab.adoc ex. 2 Console tab |
| 3 | `deployment-targets-scheduling-03-batch-pending.png` | ⛔ NOT CAPTURABLE on a sub-floor cluster (2026-08-01) — needs the batch-pool node to carry the `NoSchedule` taint, which bootstrap applies only at 3+ workers. the capture cluster had 2 real workers, so the pool is labelled and deliberately untainted, the nodeSelector-only patch schedules cleanly, and there is no Pending pod to photograph. Not a content bug — the lab's own IMPORTANT block says so. Shoot on a 3+-worker cluster. Console → Workloads → Pods → the `statement-batch` pod `Pending`, its Events showing the untolerated-taint `FailedScheduling` | Circle: the `FailedScheduling` event text "untolerated taint" | lab.adoc ex. 4 Console tab |
| 4 | `deployment-targets-scheduling-04-pdb-allowed-disruptions.png` | ✅ CAPTURED 2026-08-01 as **user7**. Both of this row's corrections held up in the frame: the column really is sentence-case **Allowed disruptions** (the CLI's upper-case form is not on the page), and it really does read **2** — `stage-m17-scheduling.sh` scales to three healthy replicas and polls `status.disruptionsAllowed` until it settles, so the picture agrees with the expected output printed directly above it. Also in frame: Selector `app=parasol-claims` and Availability `Min available 1`, which together explain the 2 without a caption. | Circle: `ALLOWED DISRUPTIONS = 2` (3 healthy − minAvailable 1) | lab.adoc ex. 5 Console tab |

**Animated gif (PREFERRED for the break-and-fix story):**
`deployment-targets-scheduling-05-pin-to-pool.gif` (<30 s, silent) — quick cuts:
`statement-batch` on a general node → add `nodeSelector` → **Pending** (untolerated taint) → add
toleration → **Running on the pool node**. The Pending→snap transition is the payoff; hold the two
`-o wide` frames side by side.

`[CAPTURE-VERIFY]` labels to confirm while shooting (the unified console — no perspective
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
