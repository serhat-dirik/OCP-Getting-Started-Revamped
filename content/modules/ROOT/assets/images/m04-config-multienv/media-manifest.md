# M04 media manifest — Config, Secrets & Multi-Environment

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Constrained-environment note: the lab's CLI spine was built entirely from the **Showroom-terminal
`oc` commands** and is cluster-grounded. The 2026-07-11 dual-path retrofit added Console tabs whose
5 novel form/label references carry `[CAPTURE-VERIFY]` markers in `lab.adoc` — they map 1:1 onto
the screenshots below, so one browser pass confirms the labels and captures the shots together.
The screenshots are the console *alternatives* to the CLI spine plus the SVG diagram exports; both
remain the deferred media pass.

## Screenshots (console views — the view IS the content)

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `m04-config-multienv-01-crashloop-pod.png` | Topology/Pods in `user1-dev` after the bad-config break: `parasol-claims` pod `CrashLoopBackOff`, restart count climbing; the Logs tab showing `UnknownHostException` | Circle: the CrashLoopBackOff badge, the restart count, the `Caused by:` line in Logs | lab.adoc ex. 1 |
| 2 | `m04-config-multienv-02-configmap-secret.png` | Console: the `claims-config` ConfigMap (Data tab) and `claims-creds` Secret (with "Reveal values" showing base64→plaintext) | Circle: the ConfigMap keys; the Secret's base64 value and its revealed plaintext | lab.adoc ex. 2–3 |
| 3 | `m04-config-multienv-03-readiness-503.png` | The `parasol-claims` Service/Route while readiness is broken: empty Endpoints and the Route returning 503 (browser or console) | Circle: the empty endpoints list; the 503 response | lab.adoc ex. 4 |
| 4 | `m04-config-multienv-04-quota-replicafailure.png` | Console: the `claims-hog` Deployment with its `ReplicaFailure`/`exceeded quota` event, next to the namespace ResourceQuota view | Circle: the `exceeded quota: workshop-quota` event; the quota's requests.cpu used/hard | lab.adoc ex. 5 |
| 5 | `m04-config-multienv-05-three-envs.png` | Three Topology tiles side by side — `user1-dev` (1 pod), `user1-stage` (2 pods), `user1-prod` (3 pods) — all `parasol-claims` | Circle: the differing replica counts; note "same image" | lab.adoc ex. 6 |

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m04-config-multienv-01-config-sources.svg` | concept.adoc Mermaid "config sources" | one immutable image fed by env / ConfigMap / Secret / mounted file; shared legend |
| `m04-config-multienv-02-readiness-gate.svg` | concept.adoc Mermaid "readiness gate" | Route → passing pod; NOT → failing pod (503); the module's signature idea |
| `m04-config-multienv-03-promotion-overlays.svg` | concept.adoc Mermaid "promotion overlays" | one base → dev/stage/prod overlays, same image digest into three namespaces |
| `m04-config-multienv-04-platform-accretion-v4.svg` | concept.adoc TODO(media) | **master accretion diagram**, M04 layer (config + multi-env) highlighted on the M01–M03 base |
| `m04-config-multienv-05-what-you-built.svg` | wrapup.adoc Mermaid recap | green = what the attendee ran (ConfigMap + Secret + probes → promote to stage/prod) |

## Recordings

### Silent screen capture — the readiness gate (`m04-config-multienv-demo.mp4`, < 90 s)
Playwright/console capture of the signature moment: break readiness on `parasol-claims` → the
Topology node drops out of rotation → `oc get endpoints` shows `<none>` → the Route returns 503 →
fix readiness → the pod returns to rotation and the Route is 200 again. This is the module's money
shot; embed near lab.adoc exercise 4 and the demo arc. Warm the app first so there is no cold-boot
dead air.

### Terminal cast — promote the same image (`m04-config-multienv-promote.cast`, asciinema)
The promotion happy path from the Showroom terminal: `git clone` the config fork → `oc apply -k
overlays/stage` → `oc apply -k overlays/prod` → the three-line `for ns in ...` comparison showing
the **identical image digest** with different replicas/APP_ENV across dev/stage/prod. Embed near
lab.adoc exercise 6 and as the demo-arc closer.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 10–12 min arc).
Shot list = the Show: lines; narration = the Say: lines. Record in Phase 6.
