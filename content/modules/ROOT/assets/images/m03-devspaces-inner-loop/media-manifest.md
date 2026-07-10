# M03 media manifest — Dev Spaces & the Inner Loop

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
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
| 1 | `m03-devspaces-inner-loop-01-workspace-loaded.png` | ✅ DONE 2026-07-10 | che-code editor after the factory URL, project `parasol-claims` in the Explorer, integrated terminal open | the Explorer tree, `devfile.yaml`, the terminal with `java -version` = openjdk 21 | lab.adoc ex. 1 |
| 2 | `m03-devspaces-inner-loop-02-debug-5005.png` | ⬜ NOT CAPTURED (blocked) | che-code paused on a breakpoint in `ClaimResource.list`, debug toolbar visible | the breakpoint dot, the paused line, the Variables panel | lab.adoc ex. 6 |
| 3 | `m03-devspaces-inner-loop-03-devfile-endpoints.png` | ⬜ NOT CAPTURED | Endpoints view listing the new internal `redis` endpoint after the devfile restart; terminal `redis-cli ping` = PONG | the `cache` container / redis endpoint; the PONG | lab.adoc ex. 4 (no embed comment) |
| 4 | `m03-devspaces-inner-loop-04-topology-open-in-devspaces.png` | ⚠ CAPTURED but UNUSED | Console Topology in `user1-dev`, `parasol-claims` node | the "Open in Dev Spaces" / edit-source link it was meant to show **does not exist** in 4.21 | none — not embedded |

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
exact; the ENDPOINTS view and `redis` endpoint exist after the Redis add; **no "Edit source code" /
Open-in-Dev-Spaces decorator exists** on the Topology node (only the Open-URL decorator); the
factory URL shows a **"Do you trust the authors of this repository?" → Continue** gate and creates
a **random-suffixed** workspace if one of the same name exists; **che-code ships no Java debug
tooling by default**, so the GUI Attach-to-5005 flow needs the recommended extensions (now shipped
in the fork) and the lab carries a `jdb` fallback.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m03-devspaces-inner-loop-01-inner-outer-loop.svg` | concept.adoc Mermaid "inner vs outer loop" | red inner loop hands off via git push to the grey outer loop; reuse across the delivery block |
| `m03-devspaces-inner-loop-02-workspace-gateway-services.svg` | concept.adoc Mermaid "workspace ↔ gateway ↔ services" | shared legend (browser, gateway, container, DB, namespace box); the "IDE is in the cluster" picture |
| `m03-devspaces-inner-loop-03-platform-accretion-v3.svg` | concept.adoc TODO(media) | **master accretion diagram**, M03 layer (Dev Spaces workspace) highlighted on the M01/M02 base |
| `m03-devspaces-inner-loop-04-what-you-built.svg` | wrapup.adoc Mermaid recap | green = what the attendee ran (workspace → dev mode → hot reload → push) |

## Recordings

### Silent screen capture — one-click to a live change (`m03-devspaces-inner-loop-demo.mp4`, < 90 s)
Playwright/console capture of the demo happy path: Topology in `user1-dev` (the running claims
app) → open the workspace from the **factory URL** (`{devspaces_url}/#<fork>`; there is no
"Open in Dev Spaces" link on the node in this console version) → workspace loads → in the
workspace terminal, start dev mode wired to the DB → edit the `/ping` endpoint, save → hit it and
show the **Live reload** line landing (~2 s) with the new response. This is the module's signature
moment; embed near lab.adoc exercise 3 and the demo arc. Warm the workspace first so there is no
cold-pull dead air.

### Narrated video — Android in Dev Spaces showcase (`m03-devspaces-inner-loop-showcase-android.mp4`, 3–5 min)
The closer. Recorded narrated walkthrough (Phase 6): a full Android app developed in Dev Spaces —
same one-click browser IDE — building against an on-cluster Android device whose screen streams
into a browser tab. Source material and patterns adapted from `serhat-dirik/devspaces-android-sample-app`
(credit per D18). Embed in lab.adoc exercise 7 and as the demo-arc closer. Hosting decision
(unlisted video vs repo release) is a "For Serhat" item.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 8–10 min arc).
Shot list = the Show: lines; narration = the Say: lines. Record in Phase 6 alongside the showcase.
