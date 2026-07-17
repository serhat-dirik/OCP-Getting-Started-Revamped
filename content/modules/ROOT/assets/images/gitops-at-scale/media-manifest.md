# M10 media manifest — GitOps at Scale & Progressive Delivery

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console/Argo theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: …` line — replace with the `image::` (screenshot) or the SVG
`image::` (diagram) when the asset lands.

**Why this module's screenshots matter.** M10 is a **terminal + UI** module. The **ApplicationSet is
created from the terminal with the served `argocd` CLI** — Argo CD 3.4 has *no ApplicationSet screen*
in its web UI (neither create nor read), which G3 confirmed live; the CLI is the interface. The
**canary is watched in the Argo CD Rollout view** (that view *does* exist). The build performed the
real attendee CLI flow (download + token + `appset create` + `app list`, plus the `PermissionDenied`
a neighbour's project returns) and verified every **workload outcome** from the terminal (the
generated Rollout, the wave-ordered migration Job, the canary steps, the failed `AnalysisRun`, route
200) — but the **browser views were not screen-captured** (no browser in the build environment).
Capture them in the media pass.

> **Note on `01-appset-created`:** the money shot is the **terminal** right after `~/argocd appset
> create` + `~/argocd app list -p proj-{user}` (the "created" line + the three generated apps) — *not*
> a UI create form, which does not exist in Argo 3.4. The three-app cards in the Argo CD **Applications**
> view (`02`) are the UI counterpart (the ApplicationSet detail/read view also does not exist in 3.4).

## Screenshots (terminal + Argo CD Rollout / Gitea UI views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `gitops-at-scale-01-appset-created.png` | ⬜ NOT CAPTURED — **HIGH** | **Terminal** after `~/argocd appset create` + `~/argocd app list -p proj-user1` | the `ApplicationSet 'claims-user1' created` line and the three generated apps (dev/stage Synced, prod Progressing on the `rollouts` path) | lab.adoc ex. 1 (create the ApplicationSet) |
| 2 | `gitops-at-scale-02-three-app-cards.png` | ⬜ NOT CAPTURED — **HIGH** | **Argo CD Applications view** (the appset detail/read view does NOT exist in 3.4) | the THREE generated app cards `claims-dev/stage/prod-user1`, all Synced/Healthy — dev/stage adopted, prod new | lab.adoc ex. 1 (after create) |
| 3 | `gitops-at-scale-03-gitea-image-bump.png` | ⬜ NOT CAPTURED | **Gitea editor on `rollouts/claims-rollout.yaml`** | the image tag changed `1.0` → `1.1`, the Commit Changes panel | lab.adoc ex. 3 (ship a new version) |
| 4 | `gitops-at-scale-04-canary-progressing.png` | ⬜ NOT CAPTURED — **HIGH** | **Argo CD Rollout view, mid-canary** | revision 2 (canary, 1.1) alongside revision 1 (stable, 1.0), SetWeight 25 or 50, the analysis step running — the module's signature visual | lab.adoc ex. 3 (watch the canary) |
| 5 | `gitops-at-scale-05-canary-aborted.png` | ⬜ NOT CAPTURED — **HIGH** | **Argo CD Rollout view, aborted** | the Rollout Degraded/aborted at the analysis step, the failed AnalysisRun, stable still serving — the payoff | lab.adoc ex. 4 (the auto-rollback) |

## Diagrams (SVG in-repo; source of truth is the inline Mermaid in the `.adoc`)

The concept/wrap-up pages ship inline Mermaid (editable-source rule satisfied by construction).
Export these to SVG next to their `.adoc` for the slide deck and richer rendering; keep the Mermaid
as the editable source (do not delete it).

| # | Filename | Status | Source (inline Mermaid in) | Shows |
|---|----------|--------|-----------------------------|-------|
| 1 | `gitops-at-scale-01-appset.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | hand-made-per-env vs one ApplicationSet (generator → template → 3 apps) |
| 2 | `gitops-at-scale-02-sync-waves.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | db (wave 0) → migration hook (wave 1) → app Rollout (wave 2) |
| 3 | `gitops-at-scale-03-canary-analysis.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | canary 25→50 → analysis → pass (100%) / fail (roll back to stable) |
| 4 | `gitops-at-scale-04-platform-accretion.svg` | ⬜ NOT CAPTURED (shared) | concept.adoc (pointer) | the cross-module Parasol platform diagram with the M10 layer (ApplicationSets + Rollouts) highlighted |
| 5 | `gitops-at-scale-05-what-you-built.svg` | ⬜ NOT CAPTURED (export) | wrapup.adoc | ApplicationSet → 3 apps; prod canary with the pass/rollback fork highlighted |

## Recording (demo-arc happy path)

- `gitops-at-scale-demo.cast` (asciinema) OR `<90s` silent screen capture — ⬜ NOT CAPTURED.
  The canary + auto-rollback arc is the flagship: ship 1.1 (green canary), then `verdict=fail` + ship
  (abort + rollback), route 200 throughout. Console-heavy (the Argo Rollout view animates), so a
  short screen capture of the Rollout view during the abort is the highest-value clip.
