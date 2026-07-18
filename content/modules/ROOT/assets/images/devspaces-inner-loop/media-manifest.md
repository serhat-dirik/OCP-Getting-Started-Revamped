# M03 media manifest — Dev Spaces & the Inner Loop

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console/IDE theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Media note: lab mechanics were built by driving the **DevWorkspace API and `oc exec` into the
workspace pod**; the browser-IDE was then walked live during the 2026-07-10 browser-verification
pass, which resolved every `[CAPTURE-VERIFY]` note in `lab.adoc` / `concept.adoc` / demo blocks.
See the Status column below (#1 captured; #2 blocked, #3 deferred, #4 captured-but-unused). The
SVG diagram exports remain the deferred media pass.

## Screenshots (IDE + console views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `devspaces-inner-loop-01-workspace-loaded.png` | ✅ DONE 2026-07-10 | che-code editor after the factory URL, project `parasol-claims` in the Explorer, integrated terminal open | the Explorer tree, `devfile.yaml`, the terminal with `java -version` = openjdk 21 | lab.adoc ex. 1 |
| 2 | `devspaces-inner-loop-02-debug-5005.png` | ⬜ NOT CAPTURED (blocked) | che-code paused on a breakpoint in `ClaimResource.list`, debug toolbar visible | the breakpoint dot, the paused line, the Variables panel | lab.adoc ex. 6 |
| 3 | `devspaces-inner-loop-03-devfile-endpoints.png` | ⬜ NOT CAPTURED | Endpoints view listing the new internal `valkey` endpoint after the devfile restart; terminal `valkey-cli ping` = PONG | the `cache` container / valkey endpoint; the PONG | lab.adoc ex. 4 (no embed comment) |
| 4 | `devspaces-inner-loop-04-topology-open-in-devspaces.png` | ⚠ CAPTURED but UNUSED | Console Topology in `user1-dev`, `parasol-claims` node | the "Open in Dev Spaces" / edit-source link it was meant to show **does not exist** in 4.21 | none — not embedded |

**Status notes (2026-07-10 browser pass):**

- **#1 workspace-loaded — DONE**, embedded at lab.adoc exercise 1.
- **#2 debug-5005 — NOT CAPTURED (blocked).** Default che-code {devspaces_version} ships no Java
  debug tooling, so the GUI breakpoint state could not be reached out of the box. The lab now
  ships `.vscode/extensions.json` + `launch.json` in `apps/parasol-claims/` and adds a guaranteed
  `jdb` terminal fallback; recapture this shot only on a cluster where the Java debugger extension
  installs. Its `// media-pass:` embed comment is intentionally left in `lab.adoc`.
- **#3 devfile-endpoints — NOT CAPTURED.** Deferred enrichment; the exercise-4 verification is the
  `PONG` from the devfile task plus the TCP probe, not a screenshot. No embed comment in `lab.adoc`.
- **#4 topology-open-in-devspaces — CAPTURED but NOT USED.** The file was shot, but the **"Open in
  Dev Spaces" / "Edit source code" link it was meant to show does not exist** on the Topology node
  in this console version (the Deployment lacks the git `vcs-uri` annotations that would create it).
  The demo and lab now open the workspace via the factory URL, so there is no embed point. Left on
  disk; do not embed. Replace with a genuine "running claims app in Topology" shot in a future pass
  if one is wanted.

**Dev Spaces {devspaces_version} / OCP {ocp_version} reality confirmed during the pass (corrections
applied to `lab.adoc`, `concept.adoc`, `instructor.adoc`, `troubleshooting.adoc`):** factory URL
provisioning + editor load and `java -version` = 21 confirmed; the command-palette entries **Dev
Spaces: Restart Workspace from Local Devfile** and **Dev Spaces: Restart Workspace** confirmed
exact; the ENDPOINTS view and `valkey` endpoint exist after the Valkey add; **no "Edit source code" /
Open-in-Dev-Spaces decorator exists** on the Topology node (only the Open-URL decorator); the
factory URL shows a **"Do you trust the authors of this repository?" → Continue** gate and creates
a **random-suffixed** workspace if one of the same name exists; **che-code ships no Java debug
tooling by default**, so the GUI Attach-to-5005 flow needs two extensions installed first, and the
lab carries a `jdb` fallback that always works.

**Extension registry — verified live 2026-07-10 (probed from inside the cluster):** this Dev Spaces
leaves `openVSXURL` unset, which selects the **embedded** Open VSX registry served by the
`plugin-registry` pod at `/openvsx`. Probed against
`http://plugin-registry.openshift-devspaces.svc:8080/openvsx/api/…`:

| Extension | Embedded registry |
|---|---|
| `redhat.java` (Language Support for Java) | **HTTP 200 — present** |
| `vscjava.vscode-java-debug` (Debugger for Java) | **HTTP 200 — present** |
| `vscjava.vscode-java-test` | HTTP 200 — present |
| `redhat.vscode-quarkus` | HTTP 200 — present |
| `vscjava.vscode-java-pack` (Extension Pack for Java) | **HTTP 404 — ABSENT** |

So the GUI debug path **does work here** — but only ever recommend the *individual* extensions.
The `vscode-java-pack` meta-extension is not in the embedded registry and would fail to install.
(`open-vsx.org` is separately reachable from the cluster, but the IDE does not query it.)

> ⚠ **The seed repo `parasol/parasol-claims` does NOT yet carry `.vscode/`.** The files exist in
> `apps/parasol-claims/` in this monorepo, but that repo is **not a mirror** — it is published
> imperatively (`docs/research/app-repo-publishing.md`), and a Gitea fork is a clone taken at fork
> time, so existing `{user}/parasol-claims` forks would not pick the files up even after a re-publish.
> Until the seed is refreshed (parked for the project owner — see `06-BACKLOG.md` "For the project owner"), the lab must
> not promise attendees a `.vscode/` prompt. It currently tells them to install the two extensions
> from the *Extensions* view, which works today.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `devspaces-inner-loop-01-inner-outer-loop.svg` | concept.adoc Mermaid "inner vs outer loop" — `examples/diagrams/devspaces-inner-loop/01-inner-outer-loop.mmd` | red inner loop hands off via git push to the grey outer loop; reuse across the delivery block. **Owner review M03-2: this diagram (the one after "currency is minutes to hours…") was too small.** The Mermaid source has been tightened to concise labels (`Edit → Build → Run → Observe`; `Pipeline · Image · GitOps · Prod`) as the interim legibility fix; export the SVG **~25% larger** and lightbox-enabled (see Lightbox note below). |
| `devspaces-inner-loop-02-workspace-gateway-services.svg` | concept.adoc Mermaid "workspace ↔ gateway ↔ services" — `examples/diagrams/devspaces-inner-loop/02-workspace-gateway-services.mmd` | shared legend (browser, gateway, container, DB, namespace box); the "IDE is in the cluster" picture |
| `devspaces-inner-loop-03-platform-accretion-v3.svg` | concept.adoc TODO(media) | **master accretion diagram**, M03 layer (Dev Spaces workspace) highlighted on the M01/M02 base |
| `devspaces-inner-loop-04-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/devspaces-inner-loop/04-what-you-built.mmd` | green = what the attendee ran (workspace → dev mode → hot reload → push) |

### Lightbox (click-to-enlarge) — shared fix SW-3 / CC-5

All four SVG exports must render at a legible size and open a **click-to-enlarge (lightbox)** view,
per the course-wide diagram-legibility fix (SW-3, a one-time supplemental-ui change). The inner-vs-outer-loop
diagram (`…-01-…`) was called out as too small in the owner review (**M03-2**): its Mermaid source has
been simplified to concise labels as an interim fix, but the committed SVG should still be exported **~25% larger**
and wrapped in the lightbox once the supplemental-ui lands.

## Recordings

### Silent screen capture — one-click to a live change (`devspaces-inner-loop-demo.mp4`, < 90 s)
Playwright/console capture of the demo happy path: Topology in `user1-dev` (the running claims
app) → open the workspace from the **factory URL** (`{devspaces_url}/#<fork>`; there is no
"Open in Dev Spaces" link on the node in this console version) → workspace loads → in the
workspace terminal, start dev mode wired to the DB → edit the `/ping` endpoint, save → hit it and
show the **Live reload** line landing (~2 s) with the new response. This is the module's signature
moment; embed near lab.adoc exercise 3 and the demo arc. Warm the workspace first so there is no
cold-pull dead air.

_(The Android-in-Dev-Spaces showcase video was removed in the owner review — M03-6. Exercise 7 is
now the hands-on "port-forward + ship a container" bridge to the outer loop; no video is needed for it.)_

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the ~8 min arc).
Shot list = the Show: lines; narration = the Say: lines. Record in Phase 6 alongside the silent screen capture.
