# M03 media manifest — Dev Spaces & the Inner Loop

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console/IDE theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Constrained-environment note: the module was built by driving the **DevWorkspace API and
`oc exec` into the workspace pod** (the browser IDE could not be driven headlessly). All lab
mechanics are cluster-grounded; the browser-IDE screenshots below and the SVG diagram exports
are the deferred media pass. While shooting, resolve every `[CAPTURE-VERIFY]` note in
`lab.adoc` and `concept.adoc`/demo blocks, and report any label that differs from the text.

## Screenshots (IDE + console views — the view IS the content)

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `m03-devspaces-inner-loop-01-workspace-loaded.png` | che-code editor after the factory URL, project `parasol-claims` in the Explorer, integrated terminal open | Circle: the Explorer tree, the `devfile.yaml`, the terminal with `java -version` = openjdk 21 | lab.adoc ex. 1 |
| 2 | `m03-devspaces-inner-loop-02-debug-5005.png` | che-code paused on a breakpoint in `ClaimResource.list`, debug toolbar visible | Circle: the breakpoint dot, the paused line, the Variables panel, the Attach-to-5005 config | lab.adoc ex. 6 |
| 3 | `m03-devspaces-inner-loop-03-devfile-endpoints.png` | After adding the Redis component and restarting from the devfile: the Endpoints view listing the new internal `redis` endpoint, terminal `redis-cli ping` = PONG | Circle: the `cache` container / redis endpoint; the PONG | lab.adoc ex. 4 |
| 4 | `m03-devspaces-inner-loop-04-topology-open-in-devspaces.png` | Console Topology in `user1-dev`, `parasol-claims` node side panel with the "Edit source code" / Open-in-Dev-Spaces link | Circle: the node, the Dev Spaces link (the one-click moment) | demo block 1 / lab.adoc ex. 1 |

`[CAPTURE-VERIFY]` labels to confirm while shooting (Dev Spaces {devspaces_version} / OCP {ocp_version}):
factory URL provisioning + editor load; `java -version` = 21 in the terminal; the
command-palette entry **Restart Workspace from Local Devfile**; the Endpoints view after the
Redis add; the Attach-to-5005 launch config and a breakpoint halting a `/api/claims` request;
the Topology **Open in Dev Spaces** / edit-source link.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m03-devspaces-inner-loop-01-inner-outer-loop.svg` | concept.adoc Mermaid "inner vs outer loop" | red inner loop hands off via git push to the grey outer loop; reuse across the delivery block |
| `m03-devspaces-inner-loop-02-workspace-gateway-services.svg` | concept.adoc Mermaid "workspace ↔ gateway ↔ services" | shared legend (browser, gateway, container, DB, namespace box); the "IDE is in the cluster" picture |
| `m03-devspaces-inner-loop-03-platform-accretion-v3.svg` | concept.adoc TODO(media) | **master accretion diagram**, M03 layer (Dev Spaces workspace) highlighted on the M01/M02 base |
| `m03-devspaces-inner-loop-04-what-you-built.svg` | wrapup.adoc Mermaid recap | green = what the attendee ran (workspace → dev mode → hot reload → push) |

## Recordings

### Silent screen capture — one-click to a live change (`m03-devspaces-inner-loop-demo.mp4`, < 90 s)
Playwright/console capture of the demo happy path: Topology in `user1-dev` → click **Open in Dev
Spaces** on the `parasol-claims` node → workspace loads → in the workspace terminal, start dev
mode wired to the DB → edit the `/ping` endpoint, save → hit it and show the **Live reload** line
landing (~2 s) with the new response. This is the module's signature moment; embed near lab.adoc
exercise 3 and the demo arc. Warm the workspace first so there is no cold-pull dead air.

### Narrated video — Android in Dev Spaces showcase (`m03-devspaces-inner-loop-showcase-android.mp4`, 3–5 min)
The closer. Recorded narrated walkthrough (Phase 6): a full Android app developed in Dev Spaces —
same one-click browser IDE — building against an on-cluster Android device whose screen streams
into a browser tab. Source material and patterns adapted from `serhat-dirik/devspaces-android-sample-app`
(credit per D18). Embed in lab.adoc exercise 7 and as the demo-arc closer. Hosting decision
(unlisted video vs repo release) is a "For Serhat" item.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 8–10 min arc).
Shot list = the Show: lines; narration = the Say: lines. Record in Phase 6 alongside the showcase.
