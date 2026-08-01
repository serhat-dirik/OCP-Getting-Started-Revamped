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

**2026-08-01, later the same day — the login happened and rows 1, 2, 3, 4 and 6 are shot and embedded.**
The two paragraphs above are kept as the record of why they were blocked, not as current status.
Row 5 (`…-05-three-envs.png`) is still open and still parked for the reason given in its own row: it is
a hand-assembled composite of three console captures, and `capture.py` writes one frame per job.
Row 3 was shot on its **fallback** view, not the view its row originally asked for — see that row.

| # | Filename | Status | View | Annotate | Embed point |
|---|----------|--------|------|----------|-------------|
| 1 | `config-multienv-01-crashloop-pod.png` | ✅ CAPTURED 2026-08-01, embedded at `lab.adoc` ex. 1 (after the `Caused by` prose, before the checkpoint). Proves the console tells the same story the CLI does: the pod's **Logs tab** carries `PSQLException: The connection attempt failed` and, beneath it, `java.net.UnknownHostException: wrong-db-host`. **The badge in frame reads `Error`, not `CrashLoopBackOff`** — it flickers with the restart cycle, so the alt text says Error and explains the alternation rather than claiming a word the picture does not show. The restart count is not on this page; the log line is, and the log line is what the exercise is about. | Topology/Pods in `{user}-dev` after the bad-config break: `parasol-claims` pod `CrashLoopBackOff`, restart count climbing; the Logs tab showing `UnknownHostException` | Circle: the CrashLoopBackOff badge, the restart count, the `Caused by:` line in Logs | lab.adoc ex. 1 |
| 2 | `config-multienv-02-configmap-secret.png` | ✅ CAPTURED 2026-08-01, embedded at `lab.adoc` ex. 3, immediately above row 6 as the first half of the plaintext-vs-masked pair. Proves the ConfigMap holds nothing sensitive and hides nothing: all five keys render with their values readable — `APP_ENV=dev`, `POSTGRESQL_DATABASE=parasol`, `POSTGRESQL_HOST=claims-db`, `POSTGRESQL_PORT=5432`, `QUARKUS_LOG_LEVEL=INFO`. (Row was split 2026-08-01 — the console renders a ConfigMap and a Secret on separate detail pages, so the Secret is row 6.) | Console: the `claims-config` ConfigMap Data view, plaintext keys/values | Circle: the ConfigMap keys | lab.adoc ex. 2–3 |
| 3 | `config-multienv-03-readiness-503.png` | ✅ CAPTURED 2026-08-01 **on the fallback view, and the row's original premise is the thing that was wrong.** Embedded at `lab.adoc` ex. 4, straight after the `Route: 503` block. Proves the cause rather than the symptom: the Pods list shows `claims-db` `Running 1/1` and, below it, `parasol-claims` `Running 0/1` with 0 restarts — Running but not Ready, which is why the Service has no endpoints. The **Service detail page was not usable**, exactly as the previous note feared: an unready pod still matches the Service's selector, so that page renders as though nothing were wrong. The Pods list was the documented fallback and it carries the `READY 0/1` that the whole exercise turns on. Note for a re-shoot: `claims-db` sorts **above** `parasol-claims`, not below. | The `parasol-claims` Service while readiness is broken: nothing behind the Service, Route returning 503 | Circle: the empty endpoints list; the 503 response | lab.adoc ex. 4 |
| 4 | `config-multienv-04-quota-replicafailure.png` | ✅ CAPTURED 2026-08-01, embedded at `lab.adoc` ex. 5 right after the `FailedCreate` expected output. Proves the platform refuses in writing and says exactly why: the Conditions table reads `Replica Failure / True / FailedCreate / pods "claims-hog-…" is forbidden: exceeded quota: workshop-quota, requested: requests.cpu=4, used: requests.cpu=200m, limited: requests.cpu=3` — matching the lab's expected output including the `200m` already used. **One frame covered both halves the row asked for**, so no second capture of the ResourceQuota page was needed: the Containers table above the Conditions shows the greedy `hog` container at `cpu: 4, memory: 256Mi`. The `ReplicaFailure` condition does sit far below the fold — the 1600×1400 viewport plus `scroll_to_text` is what put it in frame, and the Deployment's own title scrolled off the top as the price. | Console: the `claims-hog` Deployment with its `ReplicaFailure`/`exceeded quota` condition | Circle: the `exceeded quota: workshop-quota` message; the quota's requests.cpu used/hard | lab.adoc ex. 5 |
| 5 | `config-multienv-05-three-envs.png` | ⬜ NOT CAPTURED — **parked, and not on the login window's critical path.** This row is a hand-assembled composite of three separate console captures; `capture.py` writes one frame per job and no console page shows three namespaces. Staging is solved (`stage-config-multienv.sh {user} promote`), so it needs a person to take three shots and join them — or the row rewritten as three files. | Three Topology tiles side by side — `{user}-dev` (1 pod), `{user}-stage` (2 pods), `{user}-prod` (3 pods) — all `parasol-claims`. **Composite image: THREE separate console captures manually assembled — not a single screenshot.** | Circle: the differing replica counts; note "same image" | lab.adoc ex. 6 |
| 6 | `config-multienv-06-secret-masked.png` | ✅ CAPTURED 2026-08-01 (**new row 2026-08-01** — the half of old row 2 that needed its own frame), embedded at `lab.adoc` ex. 3 directly below row 2. Proves the module's honesty beat about Secrets: the key names `POSTGRESQL_USER` and `POSTGRESQL_PASSWORD` are in the clear, the values render as dots, and **"Reveal values" was never clicked** — masking is a console display choice sitting on top of base64, not encryption, which is what the commands beside it demonstrate. | Console: the `claims-creds` Secret detail page with **"Reveal values" left OFF** — masked form only; the job clicks nothing, because the page renders masked by default and toggling Reveal is exactly what the media-capture conventions rule 1 forbids. (The value behind the mask is in any case the lab's fabricated teaching credential `POSTGRESQL_PASSWORD=parasol`, not a real one.) | Circle: the Secret's key names and its masked display | lab.adoc ex. 2–3, beside row 2 |

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
