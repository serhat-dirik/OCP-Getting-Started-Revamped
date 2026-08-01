# M04 media manifest — Config, Secrets & Multi-Environment

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Constrained-environment note: the lab's CLI spine was built entirely from the **Showroom-terminal
`oc` commands** and is cluster-grounded. The 2026-07-11 dual-path retrofit added Console tabs whose
5 novel form/label references carry `[CAPTURE-VERIFY]` markers in `lab.adoc` — they map 1:1 onto
the screenshots below, so one browser pass confirms the labels and captures the shots together.
The screenshots are the console *alternatives* to the CLI spine. The SVG diagram exports are already
rendered and committed (2026-07-26, label fix + platform-accretion diagram 2026-07-28) — the
screenshots and recordings remain the deferred media pass.

## Screenshots (console views — the view IS the content)

**2026-08-01 media pass — staging SOLVED, shooting BLOCKED on one human login.** All five rows are the
same namespace at five moments of the same lab, which is why they had never been staged: they cannot
be reached in parallel or out of order. `tools/media/stage-config-multienv.sh <user> <phase>` now
drives them in sequence (`break` → `configured` → `readiness-broken` → `quota` → `promote`), with the
command bodies copied verbatim from `lab.adoc` exercises 1–6, and each phase *waits on the state the
shot is for* rather than on a timer (it refuses to return until the pod is genuinely
`CrashLoopBackOff`, until the Route genuinely answers `503`, until the `ReplicaFailure` condition
genuinely carries `exceeded quota`). **All five phases were run for real as `user2` on the build
cluster, 2026-08-01, end to end** — CrashLoopBackOff reached; ConfigMap + Secret wired and the Route
back to `200`; endpoints drained to a blank `ENDPOINTS` column with the Route at `503` (matching
`lab.adoc`'s expected output, deprecation warning and all); `claims-hog` refused with
`exceeded quota: workshop-quota, requested: requests.cpu=4, used: requests.cpu=300m, limited: 3`;
and the promotion landing 1/2/3 replicas across `{user}-dev`/`-stage`/`-prod` from an anonymous
clone of the attendee's `claims-config` fork. So the only unproven thing left in this module is the
photograph itself.

What could not be done: no console session exists and none can be created without a human typing a
password. Measured, not assumed — the cached session in `tools/media/shot-profile.session.json`
returns **HTTP 401** from the console's `users/~` proxy, and the password-free attendee cockpit does
not carry a console session (its *OCP Console* tab is an external link to another subdomain, and that
subdomain's iframe is refused by `X-Frame-Options`). `tools/media/jobs-first-block.yaml` holds all
five jobs, in order, ready to run the moment somebody completes one OAuth hop.

| # | Filename | Status | View | Annotate | Embed point |
|---|----------|--------|------|----------|-------------|
| 1 | `config-multienv-01-crashloop-pod.png` | ⬜ NOT CAPTURED — staged and job written; needs a console session. Note the target is the **pod's Logs tab** (`/k8s/ns/{user}-dev/pods/<newest>/logs`), not Topology: no single console frame carries the badge, the restart count *and* the log line, and the log line is the one this exercise is about. The pod name is generated, so the job resolves it with `url_sh`. | Topology/Pods in `{user}-dev` after the bad-config break: `parasol-claims` pod `CrashLoopBackOff`, restart count climbing; the Logs tab showing `UnknownHostException` | Circle: the CrashLoopBackOff badge, the restart count, the `Caused by:` line in Logs | lab.adoc ex. 1 |
| 2 | `config-multienv-02-configmap-secret.png` | ⬜ NOT CAPTURED — **row split, 2026-08-01.** One image cannot show two objects: the console renders a ConfigMap and a Secret on separate detail pages, and there is no composite step in the harness. This file is now the **ConfigMap** (`claims-config`) Data view; the Secret moves to row 6 below. | Console: the `claims-config` ConfigMap Data view, plaintext keys/values | Circle: the ConfigMap keys | lab.adoc ex. 2–3 |
| 3 | `config-multienv-03-readiness-503.png` | ⬜ NOT CAPTURED — needs a session, and it is the **weakest job in the set, flagged rather than glossed**: the cluster state is proven (phase `readiness-broken` refuses to hand over unless `curl` really returns 503) but the *page* is not. The job points at the **Service** detail page, and an unready pod still matches the Service's selector, so that page may render as if nothing is wrong. Whoever shoots it must look before committing; the job carries the fallback URLs to try in order (the `Endpoints` object the lab prints, the `EndpointSlice`, then the Pods list at `READY 0/1`). A browser shot of the router's generic "Application is not available" page was considered and rejected — the lab already prints `Route: 503` from `curl`, and the error page adds nothing. | The `parasol-claims` Service while readiness is broken: nothing behind the Service, Route returning 503 | Circle: the empty endpoints list; the 503 response | lab.adoc ex. 4 |
| 4 | `config-multienv-04-quota-replicafailure.png` | ⬜ NOT CAPTURED — staged; needs a session. The `ReplicaFailure` condition sits far below a 1000px fold on the Deployment page, so the job carries a 1600×1400 viewport **and** `scroll_to_text` — do not resolve a `require_in_frame` failure here by deleting the assertion, that message is the whole subject. | Console: the `claims-hog` Deployment with its `ReplicaFailure`/`exceeded quota` condition | Circle: the `exceeded quota: workshop-quota` message; the quota's requests.cpu used/hard | lab.adoc ex. 5 |
| 5 | `config-multienv-05-three-envs.png` | ⬜ NOT CAPTURED — **parked, and not on the login window's critical path.** This row is a hand-assembled composite of three separate console captures; `capture.py` writes one frame per job and no console page shows three namespaces. Staging is solved (`stage-config-multienv.sh {user} promote`), so it needs a person to take three shots and join them — or the row rewritten as three files. | Three Topology tiles side by side — `{user}-dev` (1 pod), `{user}-stage` (2 pods), `{user}-prod` (3 pods) — all `parasol-claims`. **Composite image: THREE separate console captures manually assembled — not a single screenshot.** | Circle: the differing replica counts; note "same image" | lab.adoc ex. 6 |
| 6 | `config-multienv-06-secret-masked.png` | ⬜ NOT CAPTURED — **new row 2026-08-01**, the half of old row 2 that needed its own frame. | Console: the `claims-creds` Secret detail page with **"Reveal values" left OFF** — masked form only; the job clicks nothing, because the page renders masked by default and toggling Reveal is exactly what `docs/media-capture-conventions.md` rule 1 forbids. (The value behind the mask is in any case the lab's fabricated teaching credential `POSTGRESQL_PASSWORD=parasol`, not a real one.) | Circle: the Secret's key names and its masked display | lab.adoc ex. 2–3, beside row 2 |

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `config-multienv-01-config-sources.svg` | concept.adoc Mermaid "config sources" — `examples/diagrams/config-multienv/01-config-sources.mmd` | one immutable image fed by env / ConfigMap / Secret / mounted file; shared legend |
| `config-multienv-02-readiness-gate.svg` | concept.adoc Mermaid "readiness gate" — `examples/diagrams/config-multienv/02-readiness-gate.mmd` | Route → passing pod; NOT → failing pod (503); the module's signature idea |
| `config-multienv-03-promotion-overlays.svg` | concept.adoc Mermaid "promotion overlays" — `examples/diagrams/config-multienv/03-promotion-overlays.mmd` | one base → dev/stage/prod overlays, same image digest into three namespaces |
| `config-multienv-04-platform-accretion-v4.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/config-multienv/04-platform-accretion-v4.mmd` | **master accretion diagram**, M04 layer (config + multi-env) highlighted on the M01–M03 base |
| `config-multienv-05-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/config-multienv/05-what-you-built.mmd` | green = what the attendee ran (ConfigMap + Secret + probes → promote to stage/prod) |

## Recordings

### Silent screen capture — the readiness gate (`config-multienv-demo.mp4`, < 90 s)
Playwright/console capture of the signature moment: break readiness on `parasol-claims` → the
Topology node drops out of rotation → `oc get endpoints` shows `<none>` → the Route returns 503 →
fix readiness → the pod returns to rotation and the Route is 200 again. This is the module's money
shot; embed near lab.adoc exercise 4 and the demo arc. Warm the app first so there is no cold-boot
dead air.

### Terminal cast — promote the same image (`config-multienv-promote.cast`, asciinema)
The promotion happy path from the Showroom terminal: `git clone` the config fork → `oc apply -k
overlays/stage` → `oc apply -k overlays/prod` → the three-line `for ns in ...` comparison showing
the **identical image digest** with different replicas/APP_ENV across dev/stage/prod. Embed near
lab.adoc exercise 6 and as the demo-arc closer.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 10–12 min arc).
Shot list = the Show: lines; narration = the Say: lines. Record in Phase 6.
