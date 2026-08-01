# M01 media manifest — Platform Orientation & First App

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Media note: the console screenshots below were captured on the live 4.21 console during the
2026-07-10 browser-verification pass and are embedded in `lab.adoc` (see the Status column).
Diagrams ship as a standalone Mermaid `.mmd` under `examples/diagrams/platform-orientation/`
(never inline in the `.adoc`); the SVG diagram exports are already rendered and committed
(2026-07-26, label fix 2026-07-28).

**2026-08-01 media pass (attendee slot `user2`, shared build cluster) — what stopped it, measured
not assumed.** No console session could be established without a human, so no console shot was taken
anywhere in the m01–m07 block: the cached session in `tools/media/shot-profile.session.json` answers
**HTTP 401** to the console's own `users/~` proxy, and the attendee cockpit — which *is* password-free
— does **not** carry one either: its *OCP Console* tab is an external link to a different subdomain,
whose iframe the console refuses with `X-Frame-Options`. Injecting an API token as a session cookie
does not work (recorded in `capture.py`'s header). One human OAuth hop unblocks the block:
`tools/media/jobs-first-block.yaml` then shoots every capturable row unattended.

## Screenshots (console views — the view IS the content)

Screenshots **1, 3 and 4 are done and embedded**; **2 is the module's only outstanding row.** (This
paragraph said "screenshot 4 must be RE-SHOT" until 2026-08-01 — that was true when it was written
and stopped being true when row 4 was re-shot on 2026-07-29; the row itself records the re-shoot.
Corrected here rather than left to contradict the table two lines below it.)

| # | Filename | Status | Console view | Notice | Embed point |
|---|----------|--------|--------------|--------|-------------|
| 1 | `platform-orientation-01-topology-3pods.png` | ✅ DONE 2026-07-10 | Topology, project `user1-dev`, `parasol-web` scaled to 3 | the Pod donut showing 3/3; the node title; the Open-URL arrow | lab.adoc ex. 3 (scale) |
| 2 | `platform-orientation-02-deploy-image-dialog.png` | ❌ RE-CAPTURE (file on disk, **not embedded**) — this row read "✅ DONE 2026-07-10" until 2026-08-01, which contradicted `lab.adoc:187`'s own note that the committed file cannot be embedded until it is re-shot. Opened and read the PNG on 2026-08-01; the lab note is the correct side. What the frame actually shows: masthead and project selector on **`user5`/`user5-dev`** (a decommissioned slot), the registry path **`…/parasol-images/parasol-web:1.0`** — the pre-`ogsr-` prefix namespace, so it contradicts `lab.adoc:53/177/200`, which say `ogsr-parasol-images` — and the form **cropped just below *Application name***, so *Name*, *Resource type* and *Advanced options* (the fields the surrounding step is about) are off-frame entirely. **Not capturable by the harness:** `capture.py` has no generic form-fill (only `filter_text`, which types into a list's filter box), and this shot must show the *Image name from external registry* field filled and green-**Validated** — i.e. a human typing into `/deploy-image?ns={user}-dev`. Parked with that reason in `tools/media/jobs-first-block.yaml`. | **Quick create (+) → Container images** form, registry reference pasted and **Validated** | the *Image name from external registry* field, the green *Validated*, the auto-filled Name, Resource type = Deployment; Target port and *Create a route* live under *Advanced options* | lab.adoc ex. 2 (Console tab) |
| 3 | `platform-orientation-03-lightspeed-answer.png` | ✅ DONE 2026-07-10 | OpenShift Lightspeed panel after asking "Why is my pod restarting?" | the Lightspeed **chat bubble at bottom-right**; the bulleted causes; the suggested `oc` commands; the doc citations | lab.adoc ex. 7 |
| 4 | `platform-orientation-04-unified-console-landmarks.png` | ✅ CAPTURED 2026-07-29 as `user1` on 4.22.5, 1600x1000 — re-shot per the owner review of 2026-07-14. Shows the topology canvas drawn with `parasol-claims` + `claims-db`, all four landmarks present. NOTE the first attempt this session passed every assert and was still unusable: the asserts named only nav text, so it photographed an empty canvas with a loading spinner seconds after `ws start` purged the namespace. The spec now asserts a workload name, which is the only thing that proves the panel actually drew. | Unified console, project `user1-dev` selected, on the CURRENT nav (with the Pipelines/GitOps/ACS plugins present) | (1) project selector on `user1-dev`, (2) masthead **Quick create (+)** menu, (3) Topology under **Workloads**, (4) Lightspeed **chat bubble (bottom-right)**; if the Developer perspective is enabled, include the perspective switcher at the top of the nav. The web-terminal masthead icon is **no longer a landmark** (the lab dropped that step). Historical: the shot this row previously carried was pulled 2026-07-28 for showing stale nav (no Pipelines/GitOps/ACS groups), taken as user5 on a decommissioned cluster; the 2026-07-29 re-shoot above supersedes it. | lab.adoc ex. 1 |

**4.21 console reality confirmed during the pass (corrections applied to `lab.adoc`):** there is
**no `+Add` nav item** — the deploy flows (Import YAML / Import from Git / Container images) live
in the masthead **Quick create (+)** menu; **Topology** sits under the **Workloads** nav group;
**Lightspeed is a floating chat bubble at bottom-right** (not a masthead button) whose drawer
auto-opens on first visit; the **Container images** tile label and *Deploy Image* form fields are
confirmed, with **Create a route** (default checked) under *Advanced options*; the Pod-donut
up/down controls and **Edit Pod count** action are confirmed. **There is no *Actions → Create
Route*** and the side-panel *Resources* tab has no Create-Route button — Routes are created from
**Networking → Routes → Create Route** (the CLI `oc expose` path is unchanged).

**2026-07 owner review — nav has since changed:** the Pipelines, GitOps and ACS console plugins are
now enabled (new nav groups appear under *Ecosystem* / *Core platform*), and the Developer
perspective is enabled on the workshop cluster (`consoles.operator.openshift.io/cluster`
`spec.customization.perspectives` carries `dev`/Enabled), so a perspective switcher shows at the top
of the nav. The landmarks re-shoot (screenshot 4) must reflect this current nav. The lab also
**dropped the web-terminal step**, so the masthead terminal icon is no longer called out.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `platform-orientation-01-desired-state.svg` | concept.adoc Mermaid "desired state / reconcile loop" — `examples/diagrams/platform-orientation/01-desired-state.mmd` | shared legend (pod, deployment, service, human) |
| `platform-orientation-02-platform-accretion-v1.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/platform-orientation/02-platform-accretion-v1.mmd` | **master accretion diagram**, M01 layer in red; later modules highlight their own layer on this base |
| `platform-orientation-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/platform-orientation/03-what-you-built.mmd` | green = objects the attendee created |

## Recordings

### Terminal cast — the six-command recap (`platform-orientation-demo.cast`)
Record with asciinema as **user1** in `user1-dev` (reset first: `ws reset m01`). Exact sequence:

```sh
# (record from here)
oc project user1-dev
oc new-app --image=image-registry.openshift-image-registry.svc:5000/ogsr-parasol-images/parasol-web:1.0 --name=parasol-web
oc rollout status deployment/parasol-web
oc scale deployment/parasol-web --replicas=3
oc get pods -o wide
oc delete pod "$(oc get pods -l deployment=parasol-web -o jsonpath='{.items[0].metadata.name}')"
sleep 3; oc get pods           # replacement already Running
oc expose service/parasol-web --port=8080
oc get route parasol-web
oc logs deployment/parasol-web --tail=6
# (stop recording)
```
Target length < 2 min. Embed with asciinema-player on lab.adoc (near exercise 6).

### Screen capture — kill-a-Pod self-heal (`platform-orientation-selfheal.gif`, < 90 s)
Playwright/console capture: Topology with 3 Pods, delete one Pod from a side terminal,
capture the donut losing and regaining a segment. This is the module's signature moment;
embed near lab.adoc exercise 3.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 12-min
arc). Shot list = the Show: lines; narration = the Say: lines. Record in Phase 6.
