# M09 media manifest — GitOps Fundamentals

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console/Argo theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: …` line — replace with the `image::` (screenshot) or the SVG
`image::` (diagram) when the asset lands.

**Why this module's screenshots are HIGH priority (not enrichment).** M09 is a **UI-driven**
module: the attendee creates and syncs Argo CD Applications in the **Argo CD web UI**, which they
cannot do from the terminal (an `oc apply` of an Application is denied by design). The build was
performed by driving the Argo CD control plane the way the UI does (server-side create/sync/refresh
as user7) and verifying every **workload outcome** from the terminal (replica counts, drift,
revert, the `tracking-id` annotation, Route 200) — but the **Argo CD UI views themselves were not
screen-captured** (no browser in the build environment). Unlike M07 (where the CLI output is the
load-bearing evidence), here the **UI screenshots carry steps the text can only describe**. Capture
them in the media pass; the New App form and the drift-diff are the two that most need a picture.

## Screenshots (Argo CD / Gitea UI views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `gitops-fundamentals-01-argo-login.png` | ✅ CAPTURED 2026-07-26| **Argo CD login page** (student instance) | the **LOG IN VIA OPENSHIFT** button (Dex + OpenShift OAuth) — NOT the local admin username/password box | lab.adoc ex. 2 (after the `oc apply` denial) |
| 2 | `gitops-fundamentals-02-new-app-form.png` | ❌ RE-CAPTURE| **Argo CD → + NEW APP** panel filled in | Application Name `claims-dev-user1`, Project `proj-user1`, Sync Policy **Manual**, Repo `…/user1/claims-config.git`, Revision `main`, Path `overlays/dev`, Namespace `user1-dev` (RE-CAPTURE: captured scrolled past the GENERAL section — Application Name, Project and Sync Policy are off-screen.) bespoke — the NEW APP panel only exists mid-creation and cannot be reached by URL, so this needs an interactive capture, not a jobs-file entry. | lab.adoc ex. 2 (the New App form — the core action of the module) |
| 3 | `gitops-fundamentals-03-app-outofsync-missing.png` | ✅ CAPTURED 2026-07-26| **claims-dev app card/tree immediately after CREATE** | status **Missing + OutOfSync**; the 7 resources present but greyed out (not yet applied — Manual sync) | lab.adoc ex. 2 (before Sync) |
| 4 | `gitops-fundamentals-04-app-synced-healthy.png` | ✅ CAPTURED 2026-07-26| **claims-dev tree fully green after Sync** | **Synced + Healthy**, all 7 resources with green health, both Deployments Healthy — the "it worked" payoff | lab.adoc ex. 2 (after Sync) |
| 5 | `gitops-fundamentals-05-drift-diff.png` | ✅ CAPTURED 2026-07-26| **App OutOfSync with the Deployment DIFF panel open** | `replicas: 3` (live) vs `replicas: 1` (desired/Git), red/green — the module's signature visual | lab.adoc ex. 3 (drift) |
| 6 | `gitops-fundamentals-06-enable-selfheal.png` | ✅ CAPTURED 2026-07-26| **App Details → Sync Policy** | **AUTO-SYNC** enabled and **SELF HEAL** enabled | lab.adoc ex. 3 (enable self-heal) |
| 7 | `gitops-fundamentals-07-gitea-edit-overlay.png` | ❌ RE-CAPTURE| **Gitea editor on `overlays/stage/kustomization.yaml`** | `count: 2` changed to `count: 3`, the Commit Changes panel (RE-CAPTURE: the editor and `count: 3` are correct but the Commit Changes panel is below the fold and absent from the frame.) | lab.adoc ex. 4 (git edit) |
| 8 | `gitops-fundamentals-08-stage-gitdriven-diff.png` | ✅ CAPTURED 2026-07-26| **claims-stage OutOfSync after the git edit, DIFF open** | desired `replicas: 3` vs live `replicas: 2`, and the new commit as the target revision — "the change came from Git" Audit caveat: the replicas 2→3 diff is correct and load-bearing, but the open Diff modal covers the app header, so the "new commit as target revision" evidence this row also asks for is not visible in the image. | lab.adoc ex. 4 (after Refresh) |

### Rows 2 and 7 — attempted 2026-08-01, blocked on a browser session (not on cluster state)

Both re-shoots were in scope for the 2026-08-01 media pass and both are still open, for the same
single reason as `gitops-at-scale` rows 1–3: **no authenticated browser session exists for this
cluster and this pass had no way to create one.** Row 2 is the Argo CD *NEW APP* panel (OpenShift
OAuth, then the `workshop-users` IdP's username/password form — and a console session does not carry
to it); row 7 is the Gitea *editor*, which needs a signed-in Gitea session before the pencil icon
does anything. Checked cookie by cookie: the session files under `tools/media/` that carry this
cluster's host hold only `login-state` and `csrf-token`, with no `openshift-session-token-*` — a
visit, not a session. Establishing one means a human at `login.py`'s headed window, which is the
documented workflow and cannot be automated.

Nothing else stands in the way. Row 2 stays *bespoke* (the NEW APP panel exists only mid-creation and
has no URL, so it needs an interactive driver, not a jobs-file entry); row 7 is a plain
`capture.py` job against the Gitea edit URL once a session exists — and note what made it a
re-capture in the first place: the *Commit Changes* panel is below the fold, so it needs a taller
`viewport` or a `scroll_to_text`, never a relaxed `require_in_frame`.

Screenshots **2 (New App form)** and **5 (drift diff)** are the two the text most needs a picture
for; capture those first. All embed points are `// media-pass:` comments, so the page reads
correctly without them — but this module benefits more from its screenshots than any CLI module,
because the UI *is* the interface being taught.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `gitops-fundamentals-01-push-vs-pull.svg` | concept.adoc Mermaid "push vs pull" — `examples/diagrams/gitops-fundamentals/01-push-vs-pull.mmd` | two panels: CI pushes into a namespace (blue) vs a controller in the cluster pulling from Git and reconciling (green). The core mental model |
| `gitops-fundamentals-02-reconcile-loop.svg` | concept.adoc Mermaid "reconcile loop" — `examples/diagrams/gitops-fundamentals/02-reconcile-loop.mmd` | Git (desired) → Application → reconcile diff → Synced/Healthy or OutOfSync → Sync back to live. Colour desired/live green, the Application/reconcile amber |
| `gitops-fundamentals-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/gitops-fundamentals/03-what-you-built.mmd` | edit Git → Application → user-dev/stage; the drift/self-heal correction arrow highlighted |
| `gitops-fundamentals-04-platform-accretion.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/gitops-fundamentals/04-platform-accretion.mmd` | reuse the platform base; light up the GitOps reconcile layer (accretion pattern) |

Diagrams ship as a standalone Mermaid `.mmd` under `examples/diagrams/gitops-fundamentals/`
(never inline in the `.adoc`); the SVG exports replace/augment them in the pass. **Mermaid labels
are deliberately attribute-free** (the
diagram extension mangles `{attr}` subs) — keep the SVG exports generic (`user-dev`, not `{user}-dev`).

## Recordings

### Screen capture — the drift-revert (`gitops-fundamentals-drift-revert.mp4`, < 90 s)
The module's signature moment, and the best single artifact. Split-screen or cut between the
**terminal** and the **Argo CD UI**, as **user1** with `claims-dev-user1` already Synced/Healthy:

```
1. terminal: oc scale deployment/parasol-claims --replicas=3 -n user1-dev
2. Argo CD: press Refresh → app flips OutOfSync; open the Deployment DIFF (replicas 3 vs 1)
3. Argo CD: SYNC → SYNCHRONIZE → tree goes green
4. terminal: oc get deployment/parasol-claims -n user1-dev  (replicas back to 1)
```
Silent (no narration). This is the "console edit that would not stick" — embed near lab.adoc ex. 3.
Optionally a second, longer cut showing self-heal reverting on its own (~3 min — trim the wait).

### Terminal cast — the workload side (`gitops-fundamentals-demo.cast`, < 2 min)
Record with asciinema as **user1** in `user1-dev` (app already deployed via the UI or `ws solve`):
the `tracking-id` annotation proof, the drift `oc scale`, the "still 3" persistence, and (after a UI
Sync) the revert to 1 — the terminal half of exercise 3. Embed with asciinema-player near lab.adoc ex. 3.

## Narration script

Generated in the Phase-6 media wave from the demo-flavor Say/Show/Do blocks in `lab.adoc`
(the `ifdef::demo[]` arc: the GitOps-managed app → live drift → manual Sync revert → self-heal coda).
Shot list = the Show/Do lines; narration = the Say lines.
