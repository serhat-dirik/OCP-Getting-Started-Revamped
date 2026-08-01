# M10 media manifest — GitOps at Scale & Progressive Delivery

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console/Argo theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: …` line — replace with the `image::` (screenshot) or the SVG
`image::` (diagram) when the asset lands.

**Why this module's screenshots matter.** This module is a **terminal + UI** module. The **ApplicationSet
is created from the terminal with the served `argocd` CLI** — Argo CD 3.4 has *no ApplicationSet
screen* in its web UI (neither create nor read), which G3 confirmed live; the CLI is the interface.
The **canary is watched from the terminal too** — the Argo CD *Rollout view* (the richer, animated
canary visualization) is **enabled** on this instance (`spec.server.enableRolloutsUI`, `d622a6f`) but
**does not render**: its assets 404 through every route/localhost convention tried, with no
extension-registration line in any log, which reads as a packaging gap in the downstream GitOps
extensions image for this CSV rather than something this workshop's config can fix. If a later GitOps
release closes that gap, screenshots 4–5 below can be re-shot from that view; until then they are
captured as described in their rows (terminal watch-loop output, paired with the console's Pods view
for the replica-split visual). The build performed the real attendee CLI flow (download + token +
`appset create` + `app list`, plus the `PermissionDenied` a neighbour's project returns) and verified
every **workload outcome** from the terminal (the generated Rollout, the wave-ordered migration Job,
the canary steps, the failed `AnalysisRun`, route 200) — but the **browser views were not
screen-captured** (no browser in the build environment). Capture them in the media pass.

> **Note on `01-appset-created`:** the money shot is the **terminal** right after `~/argocd appset
> create` + `~/argocd app list -p proj-{user}` (the "created" line + the three generated apps) — *not*
> a UI create form, which does not exist in Argo 3.4. The three-app cards in the Argo CD **Applications**
> view (`02`) are the UI counterpart (the ApplicationSet detail/read view also does not exist in 3.4).

> **Row 4 was two screenshots wearing one filename** (fixed 2026-08-01). The old row 4 asked for the
> terminal watch loop *and* "a second shot of the console's Workloads → Pods view at the same moment",
> both under `gitops-at-scale-04-canary-progressing.png`. One file cannot hold two views, and the pair
> is not equally reachable: **4a** is a terminal shot and needs no login, while **4b** needs a console
> OAuth session. They are now separate rows so the blocked one cannot hold the reachable one hostage.
> They must still be shot at the **same instant** to mean anything — that is the one genuinely
> human-timed capture in this module.

## Capturing the terminal rows (1, 4a, 5) — the mechanism, established 2026-08-01

**The Showroom ttyd terminal is reachable anonymously and IS drivable**, which is worth stating plainly
because it was assumed otherwise. Measured on this cluster:

* `https://showroom-{user}.<domain>/tty-top/` returns **200 with no auth**, and the shell it hands you is
  already the attendee — typing `oc whoami` returned `user4`.
* Playwright **can** type into it: click `.xterm-screen`, then `page.keyboard.type("…\n")`. The keystrokes
  reach the real shell and the real output renders.
* **`capture.py`'s safety model does not survive the trip**, and this is the part that matters. xterm.js
  paints to a canvas, so `document.body.innerText` is the **empty string** — `wait_all_text`,
  `forbid_text` and `require_in_frame` are all silently blind here and a job would happily shoot a
  half-rendered or wrong screen. **Do not point a plain `capture.py` job at ttyd.**
* The way to keep the assertions honest: ttyd exposes the terminal object as **`window.term`**, and its
  scrollback is readable —

  ```js
  const b = window.term.buffer.active;
  [...Array(b.length).keys()].map(i => b.getLine(i).translateToString(true)).join("\n")
  ```

  Assert against **that string**, not against `innerText`. Verified live: it returned the login banner
  and every command's output.

What is still missing for these three rows is therefore **not the input mechanism** — it is the **lab
state**. Row 1 needs exercise 1 actually performed (argocd CLI download + token + `appset create`); rows
4a and 5 need a canary caught mid-flight and then caught again at the abort. A capture script for these
must drive the lab itself, in one session, the way `capture_m12_sequence.py` drives the console.

**These terminal frames are dark, and that is correct** — it is the attendee's real terminal, not an app
whose theme we pin. The "all images are light" rule is about product UIs (console, Argo, Developer Hub,
Gitea), which render dark on a fresh profile unless `color_scheme="light"` is set explicitly.

## Screenshots (terminal + Argo CD Applications / Gitea UI views, plus console Pods views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `gitops-at-scale-01-appset-created.png` | ⬜ NOT CAPTURED — **HIGH** | **Terminal** after `~/argocd appset create` + `~/argocd app list -p proj-user1` | the `ApplicationSet 'claims-user1' created` line and the three generated apps (dev/stage Synced, prod Progressing on the `rollouts` path) | lab.adoc ex. 1 (create the ApplicationSet) |
| 2 | `gitops-at-scale-02-three-app-cards.png` | ⬜ NOT CAPTURED — **HIGH** | **Argo CD Applications view** (the appset detail/read view does NOT exist in 3.4) | the THREE generated app cards `claims-dev/stage/prod-user1`, all Synced/Healthy — dev/stage adopted, prod new | lab.adoc ex. 1 (after create) |
| 3 | `gitops-at-scale-03-gitea-image-bump.png` | ⬜ NOT CAPTURED | **Gitea editor on `rollouts/claims-rollout.yaml`** | the image tag changed `1.0` → `1.1`, the Commit Changes panel | lab.adoc ex. 3 (ship a new version) |
| 4a | `gitops-at-scale-04-canary-progressing.png` | ✅ **CAPTURED + EMBEDDED 2026-08-01** (as user4, anonymously through the ttyd terminal) | **Terminal**, the ex. 3 watch loop run to completion (the Argo CD Rollout view does not render on this cluster — extension enabled, assets 404; see the module note above) | the whole progression: step 0/5 `canary-pods:1/4 analysis:none` → 1/5 `Paused` → 2/5 `canary-pods:2/4` → 3/5 `analysis:Running` → 4/5 `canary-pods:4/4 analysis:Successful` → 5/5 `Healthy` + `✔ promoted to 100%`. **Shot to completion rather than frozen at step 3/5**, which the row originally asked for: a click-to-run block echoes ~20 lines of its own source before it runs, so an early shot leaves the progression as a sliver at the bottom of a frame that is two-thirds source. Letting the loop finish pushes the echo off the top — and `canary-pods:2/4` / `analysis:Running` are still in frame, now with the steps either side of them | lab.adoc ex. 3, after the expected-output block |
| 4b | `gitops-at-scale-04b-canary-pods-split.png` | ⬜ NOT CAPTURED — **HIGH · BLOCKED (console session)** | **Console → Workloads → Pods**, Project `{user}-prod`, at the *same instant* as 4a | the 2-stable / 2-canary replica split — the same moment 4a shows on the CLI, seen as running Pods | lab.adoc ex. 3 (watch the canary) |
| 5 | `gitops-at-scale-05-canary-aborted.png` | ✅ **CAPTURED + EMBEDDED 2026-08-01** (as user4, anonymously through the ttyd terminal) | **Terminal**, at the abort (the Argo CD Rollout view does not render on this cluster — same gap as row 4) | the ex. 4 watch loop printing `rollout: Degraded   analysis: Failed` and `✖ canary aborted — analysis failed`, then the Rollout's own `RolloutAborted: … Metric "canary-health" assessed Failed due to failed (1) > failureLimit (0)` status message, then `prod health through the abort: 200` — all three pieces of the payoff in one frame, which is why it is embedded further down the page than the marker sat | lab.adoc ex. 4, after the "prod health through the abort" block |

## How rows 4a and 5 were captured — and the two traps that nearly shipped a wrong frame

Driver: `tools/media/capture_m11_canary.py` (`--step 4a` / `--step 5`). Both rows were shot through
`https://showroom-user4.<domain>/tty-top/`, anonymously, with no login of any kind, on 2026-08-01.

**The canary was triggered by patching the Rollout's image, not by editing Git.** The lab's trigger
is a Gitea commit, which needs a signed-in Gitea session; this pass had none (see the blocked-rows
section below). Patching the image directly is the mechanism this module's own DEMO flavor uses and
the one `ws solve` is built around — the solve-state prod Application carries `selfHeal: false`
*precisely* so a canary can be driven by hand without Argo reverting it (header of
`gitops/entry-states/gitops-at-scale/templates/solve-endstate.yaml`). The Rollout, its steps, the
`AnalysisRun` and every line in both frames are therefore genuine; only the thing that set the new
image differs, and neither frame shows it — the screen is cleared after the patch. Use `--type json`
for that patch, never `--type merge`: a Rollout is a CRD, so a merge patch REPLACES the whole
containers array and takes the env, ports and probes with it.

**Trap 1 — the assertion matched the loop's own source.** A click-to-run block reaches the tty in
one write and bash echoes the entire multi-line construct back (with `>` continuations) before
running any of it. That echo contains the loop's `echo "  ✔ promoted to 100%"` source, so a naive
substring search over `window.term`'s scrollback fires *immediately*. The first 4a attempt shot at
`analysis:Running` while reporting it had seen `promoted to 100%`. The driver now filters the buffer
down to lines the shell actually PRINTED (a timestamped status line, or a verdict standing alone)
before asserting anything.

**Trap 2 — `x` is not `✖`.** The first pass typed ASCII stand-ins for the lab's `✔` / `✖` / em
dashes, on the assumption that xterm would mangle them. It does not: verified live that both glyphs
render correctly. The frames now match the lab's own expected-output block character for character,
which is the whole point of putting a screenshot beside it.

**Reset between takes.** An aborted Rollout stays aborted (`.status.abort: true`) and reads
`Degraded` forever — a later `ws solve` will sit and time out waiting for it to go Healthy, which is
what happened here. Clear it the way the lab does, by shipping the *stable* tag again, before
re-staging anything.

## The four rows still open — all one blocker, and it is not a technical one

Rows **1**, **2**, **3** and **4b** are unresolved for exactly one reason: **no authenticated browser
session exists for this cluster, and this pass had no way to create one.**

* Every remaining surface sits behind a login — the OpenShift console and Argo CD behind OpenShift
  OAuth (and the `workshop-users` IdP presents a username/password *form*, which a console session
  does not carry — see `tools/media/README.md`), Gitea behind its own Sign In.
* The session files in `tools/media/` are for a *different* cluster. Checked cookie by cookie: the
  ones carrying this cluster's host hold only `login-state` and `csrf-token` — **no
  `openshift-session-token-*`** — i.e. a visit, not a session.
* Establishing one means a human typing a password into `login.py`'s headed window. That is the
  documented and intended workflow; it simply cannot be automated, and must not be faked.

Row **1** deserves its own line because it looks like a terminal row and therefore looks reachable.
It is not: `~/argocd appset create` needs `ARGOCD_AUTH_TOKEN`, and the only way the lab offers to
mint one is POSTing the attendee's workshop password to `/api/v1/session`. `argocd --core` is not a
way round it either — it talks to the Kubernetes API as you, and an attendee cannot write to
`ogsr-student-gitops`, which is the whole reason the lab reaches for the CLI in the first place.

**Once a session exists, all four are cheap.** Rows 2 and 4b are plain `capture.py` jobs against a
URL. Row 3 is a Gitea editor view. Row 1 needs the terminal driver above plus a token; the ttyd
mechanism it would use is already proven and in the tree.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

The concept/wrap-up pages `include::` their diagram source — a standalone `.mmd` under
`examples/diagrams/gitops-at-scale/` (path linked per row in the Source column below), never
inline Mermaid text in the `.adoc`. Export these to SVG next to their `.adoc` for the slide deck
and richer rendering; keep the `.mmd` as the editable master (do not delete it).

| # | Filename | Status | Page (Mermaid included in) | Shows |
|---|----------|--------|-----------------------------|-------|
| 1 | `gitops-at-scale-01-appset.svg` | ✅ RENDERED 2026-07-26| concept.adoc — `examples/diagrams/gitops-at-scale/01-appset.mmd` | hand-made-per-env vs one ApplicationSet (generator → template → 3 apps) |
| 2 | `gitops-at-scale-02-sync-waves.svg` | ✅ RENDERED 2026-07-26| concept.adoc — `examples/diagrams/gitops-at-scale/02-sync-waves.mmd` | db (wave 0) → migration hook (wave 1) → app Rollout (wave 2) |
| 3 | `gitops-at-scale-03-canary-analysis.svg` | ✅ RENDERED 2026-07-26| concept.adoc — `examples/diagrams/gitops-at-scale/03-canary-analysis.mmd` | canary 25→50 → analysis → pass (100%) / fail (roll back to stable) |
| 4 | `gitops-at-scale-04-platform-accretion.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/gitops-at-scale/04-platform-accretion.mmd` | concept.adoc (pointer) | the cross-module Parasol platform diagram with the M10 layer (ApplicationSets + Rollouts) highlighted |
| 5 | `gitops-at-scale-05-what-you-built.svg` | ✅ RENDERED 2026-07-26| wrapup.adoc — `examples/diagrams/gitops-at-scale/05-what-you-built.mmd` | ApplicationSet → 3 apps; prod canary with the pass/rollback fork highlighted |

## Recording (demo-arc happy path)

- `gitops-at-scale-demo.cast` (asciinema) OR `<90s` silent screen capture — ⬜ NOT CAPTURED.
  The canary + auto-rollback arc is the flagship: ship 1.1 (green canary), then `verdict=fail` + ship
  (abort + rollback), route 200 throughout. Terminal-heavy now (the Argo CD Rollout view does not
  render on this cluster — see the module note above), so an asciinema capture of the polling loop
  through the abort, ending on the `prod health through the abort: 200` line, is the highest-value
  clip.
