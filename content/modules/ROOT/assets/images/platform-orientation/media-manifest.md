# M01 media manifest — Platform Orientation & First App

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Media note: the console screenshots below were captured on the live 4.21 console during the
2026-07-10 browser-verification pass and are embedded in `lab.adoc` (see the Status column).
Diagrams ship inline as Mermaid (they satisfy the ≥1-diagram requirement today); the SVG diagram
exports remain the deferred media pass.

## Screenshots (console views — the view IS the content)

Screenshots 1–3 were **captured on the live console (2026-07-10)** during the browser-verification
pass and are embedded in `lab.adoc`. **Screenshot 4 must be RE-SHOT** (owner review 2026-07-14):
the committed file was taken as `user5` and predates the Pipelines/GitOps/ACS console plugins and
the newly-enabled Developer perspective, so the nav it shows is stale.

| # | Filename | Status | Console view | Notice | Embed point |
|---|----------|--------|--------------|--------|-------------|
| 1 | `platform-orientation-01-topology-3pods.png` | ✅ DONE 2026-07-10 | Topology, project `user1-dev`, `parasol-web` scaled to 3 | the Pod donut showing 3/3; the node title; the Open-URL arrow | lab.adoc ex. 3 (scale) |
| 2 | `platform-orientation-02-deploy-image-dialog.png` | ✅ DONE 2026-07-10 | **Quick create (+) → Container images** form, registry reference pasted and **Validated** | the *Image name from external registry* field, the green *Validated*, the auto-filled Name, Resource type = Deployment; Target port and *Create a route* live under *Advanced options* | lab.adoc ex. 2 (Console tab) |
| 3 | `platform-orientation-03-lightspeed-answer.png` | ✅ DONE 2026-07-10 | OpenShift Lightspeed panel after asking "Why is my pod restarting?" | the Lightspeed **chat bubble at bottom-right**; the bulleted causes; the suggested `oc` commands; the doc citations | lab.adoc ex. 7 |
| 4 | `platform-orientation-04-unified-console-landmarks.png` | ⚠️ RE-SHOOT as `user1` (owner review 2026-07-14) | Unified console, project `user1-dev` selected, on the CURRENT nav (with the Pipelines/GitOps/ACS plugins present) | (1) project selector on `user1-dev`, (2) masthead **Quick create (+)** menu, (3) Topology under **Workloads**, (4) Lightspeed **chat bubble (bottom-right)**; if the Developer perspective is enabled, include the perspective switcher at the top of the nav. The web-terminal masthead icon is **no longer a landmark** (the lab dropped that step). | lab.adoc ex. 1 |

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

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `platform-orientation-01-desired-state.svg` | concept.adoc Mermaid "desired state / reconcile loop" | shared legend (pod, deployment, service, human) |
| `platform-orientation-02-platform-accretion-v1.svg` | concept.adoc Mermaid platform diagram | **master accretion diagram**, M01 layer in red; later modules highlight their own layer on this base |
| `platform-orientation-03-what-you-built.svg` | wrapup.adoc Mermaid recap | green = objects the attendee created |

## Recordings

### Terminal cast — the six-command recap (`platform-orientation-demo.cast`)
Record with asciinema as **user1** in `user1-dev` (reset first: `ws reset m01`). Exact sequence:

```sh
# (record from here)
oc project user1-dev
oc new-app --image=image-registry.openshift-image-registry.svc:5000/parasol-images/parasol-web:1.0 --name=parasol-web
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
