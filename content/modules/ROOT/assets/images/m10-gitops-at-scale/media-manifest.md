# M10 media manifest — GitOps at Scale & Progressive Delivery

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console/Argo theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: …` line — replace with the `image::` (screenshot) or the SVG
`image::` (diagram) when the asset lands.

**Why this module's screenshots are HIGH priority (not enrichment).** M10 is a **UI + terminal**
module. The **ApplicationSet is created and the canary is watched in the Argo CD web UI**, and those
control-plane views carry steps the terminal cannot show (attendees cannot `oc apply` to the shared
Argo instance, and the terminal has no `argocd`/Rollouts plugin). The build was performed by driving
the Argo control plane the way the UI does (create/refresh the ApplicationSet + Applications as
admin, ship versions via the Gitea fork) and verifying every **workload outcome** from the terminal
(the generated Rollout, the wave-ordered migration Job, the canary steps, the failed `AnalysisRun`,
route 200) — but the **Argo CD UI views themselves were not screen-captured** (no browser in the
build environment). Capture them in the media pass.

> **⚠ One seam to confirm during capture (highest priority): `01-appset-create`.** The attendee
> terminal has no `argocd` CLI and no k8s write to `student-gitops`, so the **only** way to create an
> ApplicationSet is the Argo CD UI (under the per-user `applicationsets` RBAC on `proj-{user}`). The
> ApplicationSet's *adoption + generation* is proven on-cluster, but the **exact create affordance on
> Argo CD 3.4** was not clicked through in the build. When you capture `01-appset-create`, confirm the
> UI create flow end-to-end; if the version has no ApplicationSet-create affordance, flag it — the
> platform must add a CLI path to the Showroom terminal (do **not** hand attendees admin on
> `student-gitops`). Tracked as the module's top instructor watchout and a PM platform follow-up.

## Screenshots (Argo CD / Gitea UI views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `m10-gitops-at-scale-01-appset-create.png` | ⬜ NOT CAPTURED — **HIGHEST + CONFIRM FLOW** | **Argo CD → ApplicationSets → create**, `applicationset.yaml` (list generator, 3 env elements) pasted in | the list generator's three env elements, prod → `rollouts`; the create/submit control on Argo CD 3.4 | lab.adoc ex. 1 (create the ApplicationSet) |
| 2 | `m10-gitops-at-scale-02-appset-three-apps.png` | ⬜ NOT CAPTURED — **HIGH** | **ApplicationSet detail / Applications list** filtered to the user | ONE ApplicationSet owning THREE apps `claims-dev/stage/prod-user1`, all Synced/Healthy — dev/stage adopted, prod new | lab.adoc ex. 1 (after create) |
| 3 | `m10-gitops-at-scale-03-gitea-image-bump.png` | ⬜ NOT CAPTURED | **Gitea editor on `rollouts/claims-rollout.yaml`** | the image tag changed `1.0` → `1.1`, the Commit Changes panel | lab.adoc ex. 3 (ship a new version) |
| 4 | `m10-gitops-at-scale-04-canary-progressing.png` | ⬜ NOT CAPTURED — **HIGH** | **Argo CD Rollout view, mid-canary** | revision 2 (canary, 1.1) alongside revision 1 (stable, 1.0), SetWeight 25 or 50, the analysis step running — the module's signature visual | lab.adoc ex. 3 (watch the canary) |
| 5 | `m10-gitops-at-scale-05-canary-aborted.png` | ⬜ NOT CAPTURED — **HIGH** | **Argo CD Rollout view, aborted** | the Rollout Degraded/aborted at the analysis step, the failed AnalysisRun, stable still serving — the payoff | lab.adoc ex. 4 (the auto-rollback) |

## Diagrams (SVG in-repo; source of truth is the inline Mermaid in the `.adoc`)

The concept/wrap-up pages ship inline Mermaid (editable-source rule satisfied by construction).
Export these to SVG next to their `.adoc` for the slide deck and richer rendering; keep the Mermaid
as the editable source (do not delete it).

| # | Filename | Status | Source (inline Mermaid in) | Shows |
|---|----------|--------|-----------------------------|-------|
| 1 | `m10-gitops-at-scale-01-appset.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | hand-made-per-env vs one ApplicationSet (generator → template → 3 apps) |
| 2 | `m10-gitops-at-scale-02-sync-waves.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | db (wave 0) → migration hook (wave 1) → app Rollout (wave 2) |
| 3 | `m10-gitops-at-scale-03-canary-analysis.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | canary 25→50 → analysis → pass (100%) / fail (roll back to stable) |
| 4 | `m10-gitops-at-scale-04-platform-accretion.svg` | ⬜ NOT CAPTURED (shared) | concept.adoc (pointer) | the cross-module Parasol platform diagram with the M10 layer (ApplicationSets + Rollouts) highlighted |
| 5 | `m10-gitops-at-scale-05-what-you-built.svg` | ⬜ NOT CAPTURED (export) | wrapup.adoc | ApplicationSet → 3 apps; prod canary with the pass/rollback fork highlighted |

## Recording (demo-arc happy path)

- `m10-gitops-at-scale-demo.cast` (asciinema) OR `<90s` silent screen capture — ⬜ NOT CAPTURED.
  The canary + auto-rollback arc is the flagship: ship 1.1 (green canary), then `verdict=fail` + ship
  (abort + rollback), route 200 throughout. Console-heavy (the Argo Rollout view animates), so a
  short screen capture of the Rollout view during the abort is the highest-value clip.
