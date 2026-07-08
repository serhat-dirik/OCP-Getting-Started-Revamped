# M01 media manifest — Platform Orientation & First App

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Constrained-environment note: the module was built without browser access. Diagrams ship
inline as Mermaid (they satisfy the ≥1-diagram requirement today); the SVG exports and the
console screenshots below are the deferred media pass.

## Screenshots (console views — the view IS the content)

| # | Filename | Console view | Annotate | Embed point |
|---|----------|--------------|----------|-------------|
| 1 | `m01-platform-orientation-01-topology-3pods.png` | Topology, project `user1-dev`, `parasol-web` scaled to 3 | Circle the Pod donut showing 3/3; the node title; the Open-URL arrow | lab.adoc ex. 3 (scale) |
| 2 | `m01-platform-orientation-02-deploy-image-dialog.png` | **+Add → Container images** form with the registry reference pasted | Circle: the internal-registry image field, auto-filled Name, Resource type = Deployment, Target port 8080 | lab.adoc ex. 2 (Console tab) |
| 3 | `m01-platform-orientation-03-lightspeed-answer.png` | OpenShift Lightspeed panel after asking "Why is my pod restarting?" | Circle: masthead Lightspeed button; the bulleted causes; the suggested `oc` commands | lab.adoc ex. 7 |
| 4 | `m01-platform-orientation-04-unified-console-landmarks.png` | Unified console home, project `user1-dev` selected | Circle (1) project selector, (2) +Add, (3) Topology, (4) masthead terminal icon, (5) Lightspeed button | lab.adoc ex. 1 |

While shooting, resolve every `[CAPTURE-VERIFY]` note in `lab.adoc` (exact 4.21 labels:
+Add tile name, internal-registry radio, Resource type options, Create-Route location,
Pod-donut controls, Lightspeed entry point). Report any label that differs from the text.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m01-platform-orientation-01-desired-state.svg` | concept.adoc Mermaid "desired state / reconcile loop" | shared legend (pod, deployment, service, human) |
| `m01-platform-orientation-02-platform-accretion-v1.svg` | concept.adoc Mermaid platform diagram | **master accretion diagram**, M01 layer in red; later modules highlight their own layer on this base |
| `m01-platform-orientation-03-what-you-built.svg` | wrapup.adoc Mermaid recap | green = objects the attendee created |

## Recordings

### Terminal cast — the six-command recap (`m01-platform-orientation-demo.cast`)
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

### Screen capture — kill-a-Pod self-heal (`m01-platform-orientation-selfheal.gif`, < 90 s)
Playwright/console capture: Topology with 3 Pods, delete one Pod from a side terminal,
capture the donut losing and regaining a segment. This is the module's signature moment;
embed near lab.adoc exercise 3.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 12-min
arc). Shot list = the Show: lines; narration = the Say: lines. Record in Phase 6.
