# M07 media manifest — Pipelines Fundamentals & Task Libraries

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: …` line — replace with the `image::` (screenshot) or the SVG
`image::` (diagram) when the asset lands.

Media note: the module's pipeline mechanics — the anatomy run (12m54s, image 391 MB), the
task-library resolver refs, the break-fix RED/GREEN, and the live PaC git-push fire — were all
performed and captured from the CLI/API as `user6` on 2026-07-10. The console screenshots and the
SVG diagram exports below are the **deferred media pass** (no screenshots captured yet — the build
was CLI-driven). Diagrams ship as a standalone Mermaid `.mmd` under
`examples/diagrams/pipelines-fundamentals/` (never inline in the `.adoc`); the SVG exports
replace/augment them in the pass.

## Screenshots (console/UI views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `pipelines-fundamentals-01-pipelinerun-graph.png` | ⬜ NOT CAPTURED | **Pipelines → PipelineRuns → (your run)** — the 5-Task graph (fetch-source → unit-test → build-image → image-report → deploy) | the visual DAG; a green run; the `image-within-budget` result in the details pane | lab.adoc ex. 1 / challenge (console view of the run) |
| 2 | `pipelines-fundamentals-02-gitea-webhook.png` | ⬜ NOT CAPTURED | **Gitea → fork → Settings → Webhooks → Add Webhook (Gitea type)** | Target URL = the `pipelines-as-code-controller` route; POST Content Type `application/json`; the secret filled in; **Push Events** selected | lab.adoc ex. 4 (`// media-pass:` marker after "Add Webhook") |
| 3 | `pipelines-fundamentals-03-pipelinerun-failed.png` | ⬜ NOT CAPTURED | **Pipelines → PipelineRuns** — the RED break-fix run: `unit-test` failed, `build-image`/`image-report`/`deploy` **Skipped** | the failed `unit-test` node and the three *Skipped* downstream nodes — the gate, visually | lab.adoc ex. 3 (optional; the log message is the load-bearing artifact and is shown inline) |

Screenshots 1 and 3 are **enrichment** — the lab's load-bearing evidence is CLI output (`tkn
pipelinerun describe`, the `Parasol rule violated` log line), shown inline. Screenshot **2 (the Gitea
webhook form) is the most useful capture**, since exercise 4's webhook fields are fiddly; prioritize
it in the pass. None is required for the page to read correctly (all embed points are `// media-pass:`
comments, so their absence breaks nothing).

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `pipelines-fundamentals-01-anatomy-and-layers.svg` | concept.adoc Mermaid "anatomy + three reuse layers" — `examples/diagrams/pipelines-fundamentals/01-anatomy-and-layers.mmd` | the module's key diagram: catalog (openshift-pipelines) → org library (parasol-tasks) → app Pipeline, each Task wired by `resolver: cluster`. Colour the three layers distinctly (blue / amber / green) |
| `pipelines-fundamentals-02-pac-flow.svg` | concept.adoc Mermaid "PaC flow" | push → Gitea webhook → PaC controller → new PipelineRun; small and linear |
| `pipelines-fundamentals-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/pipelines-fundamentals/03-what-you-built.mmd` | the happy path green; the "red test stops here" branch red (the gate) |
| `pipelines-fundamentals-04-platform-accretion.svg` | (new) master accretion diagram, **pipelines/CI layer** highlighted | reuse the platform base; light up the pipelines + task-library layer in red (accretion pattern) |

## Recordings

### Terminal cast — anatomy run + results (`pipelines-fundamentals-demo.cast`)
Record with asciinema as **user1** in `user1-cicd` (reset first: `ws reset m07 --user user1`, and
pre-warm the Maven cache with one `ws solve` so the recorded run is the ~7-min warm path, not the
~13-min cold one; trim the build wait in post). Exact sequence:

```sh
# (record from here) — NS=user1-cicd
NS=user1-cicd
tkn pipeline describe parasol-claims-build-test-deploy -n $NS     # anatomy: params/workspaces/results/tasks
oc create -n $NS -f - <<'EOF'
# (the ad-hoc PipelineRun from lab.adoc exercise 1: PVC workspace + taskRunSpecs memory)
EOF
tkn pipelinerun logs --last -f -n $NS                              # ... unit-test, build, deploy
tkn pipelinerun describe --last -n $NS | sed -n '/Results/,/^$/p'  # image-size-mb=391, within-budget=true
# (stop recording)
```
Target length < 2 min after trimming the build wait. Embed with asciinema-player on lab.adoc (near exercise 1).

### Screen capture — the PaC git-push fire (`pipelines-fundamentals-pac.gif`, < 90 s)
Playwright/console capture: edit `README.md` in the Gitea fork and **Commit Changes**, then cut to
the console **Pipelines → PipelineRuns** where a `parasol-claims-pull-request-…` run appears *on its
own* within ~5 s and starts building. This is the "push → pipeline fires" moment; embed near lab.adoc
exercise 4. Silent (no narration).

## Narration script

Generated in the Phase-6 media wave from the demo-flavor Say/Show/Do blocks in `lab.adoc`
(the `ifdef::demo[]` arc: finished run + results → the maven-library gap → live break (red) → live fix
(green)). Shot list = the Show/Do lines; narration = the Say lines.
