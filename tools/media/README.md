# Media capture harness

Repeatable console / product-UI screenshots for the workshop media pass. Output lands in
`content/modules/ROOT/assets/images/<slug>/`, which is where each module's
`media-manifest.md` expects it.

> **Policy vs. mechanics.** This file (and `RUNBOOK.md`) explain how the driver works. The
> *rules* — the privacy-guard blind spot that makes a manifest row the only gate, the
> cluster-domain-vs-credential line, why a state-dependent shot is one-shot, forcing light theme,
> and the unauthenticated `/static/locales/en/` label check — are in
> [`docs/media-capture-conventions.md`](../../docs/media-capture-conventions.md), because they
> apply to every capture (hand-shot screenshots, demo `.cast` recordings) and not just this
> harness. Read that file first; it is short.

> **Doing a capture run? Read [RUNBOOK.md](RUNBOOK.md) first.** This file explains how the harness
> works; the runbook is the order to execute in, what must be true before the login window opens,
> which blocks destroy which, and what is not capturable at all. The order is not optional — the
> shots are state-dependent and several pairs are the same object at opposite states.

## Why a driver, and not just `chrome --screenshot`

Both obvious approaches fail, and they fail *quietly* — which is why the media pass stalled
repeatedly with nobody noticing:

- **An agent's in-conversation browser screenshots are never files.** They are returned into
  the transcript and discarded. Nothing reaches `assets/images/`, so the manifests stay
  `⬜ NOT CAPTURED` while the work looks like it is progressing.
- **`chrome --headless --screenshot=x.png <url>` writes a file, but shoots too early.**
  Pointed at the Showroom cockpit it captured the Red Hat Demo Platform **splash screen** —
  a valid 13 KB PNG of a logo. The OpenShift console is the same kind of SPA and is worse:
  its detail pages register plugin-provided tabs *seconds after* `document.title` resolves.
  A naive shot of a Pipeline page catches three tabs when the settled page has five.

So every capture must wait on content that only exists once the page has settled. That needs
a real driver. `capture.py` is it.

## Setup

```bash
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python playwright pyyaml
```

Uses your installed Google Chrome (`channel="chrome"`), so there is no browser download.

## Authenticating — without handing over a password

`login.py` opens a **headed** window on a throwaway profile directory. A human logs in there,
and the session is exported to `<profile>.session.json`, which `capture.py` re-injects on every
later run — headless, unattended, no human present.

**The profile directory does not hold the login, and believing it does costs a re-login.**
Chrome only writes cookies that carry an expiry to its on-disk store. The console's session
cookie has none, so it lives in memory and dies with the browser. Measured 2026-07-30 on a
profile whose human login had just succeeded: `openshift-refresh-token` persisted with a
30-day expiry, while the session cookie and `csrf-token` showed `expires = NULL` — and the
next headless run got `401` and was bounced to `/oauth/authorize`. The refresh token alone is
**not** enough; the console demands the interactive hop again.

What carries the login across processes is Playwright's `storage_state`, which serializes
in-memory session cookies too (`expires = -1`). Both scripts write and read the same file, so
either one can establish the session and the other picks it up. A login therefore lasts as
long as the OAuth token, not as long as the window it was typed into.

`<profile>.session.json` holds a **live session token**: written `0600`, gitignored, and it
must never enter the tree — CI's privacy guard reads text and would fail the build on it.

Neither script reads, types, stores or transmits a password. The password goes from the human
into the real OpenShift login page and nowhere else. Both the profile directory and the session
file are disposable — delete them and log in again when the token expires.

```bash
.venv/bin/python login.py            # log in in the window that opens, then it exits
```

### Which identity provider — this one wastes an hour if you get it wrong

This cluster wires **two** identity providers, so OpenShift's login page shows a chooser, and
tools reached through OAuth inherit it. `partial$idp-choice.adoc` tells attendees to pick
**`workshop-users`**; `rhbk` secures the sample application and knows nothing about workshop
accounts.

The trap for capture: **a console session does NOT carry to `workshop-users`.** Logging into the
console (as the profile's initial login) and then opening Argo CD sends you through
`LOG IN VIA OPENSHIFT` → the IdP chooser → and `workshop-users` still presents a
username/password form. Measured 2026-07-26.

So if you need attendee-perspective shots of anything behind Dex/OAuth (Argo CD, Dev Spaces,
RHACS), log the profile in **through that tool, via `workshop-users`, as the attendee** — not
just into the console. One profile can hold both sessions; just do both logins.

### One capture process at a time

Chrome refuses to open a profile that another instance holds
(`Failed to create a ProcessSingleton for your profile directory`). Runs against the same
`--profile` must be serialised. If a run is killed mid-flight it can leave a stale lock:

```bash
rm -f <profile>/SingletonLock
```

Only do that once you have confirmed no capture is actually running.

## Capturing

```bash
export OGSR_DOMAIN=apps.cluster-<id>.<base-domain>
.venv/bin/python capture.py \
  --jobs jobs-pipelines-fundamentals.yaml \
  --profile /path/to/shot-profile
```

Public, password-free pages (the Showroom cockpit) need no profile:

```bash
.venv/bin/python capture.py --jobs jobs-showroom.yaml --no-auth
```

## Writing jobs

```yaml
jobs:
  - slug: observability-health-scale                   # module slug = output directory
    filename: observability-health-scale-04-alert-firing.png   # 04-STYLE-GUIDE §4 naming
    pre_sh: ./tools/media/stage-m12-alert.sh user1     # put the CLUSTER in the state (repo-root cwd)
    pre_wait_s: 90                                     # let the state settle before shooting
    url: https://console-openshift-console.{domain}/dev-monitoring/ns/user1-dev/alertrules
    wait_all_text: ["ParasolClaimsErrorRateHigh", "Firing"]   # object AND state, both required
    wait_all_field_values: ["QUARKUS_OIDC_TENANT_ENABLED"]    # for FORM views: <input value="…">
    forbid_text: ["Access restricted"]                 # refuse to shoot a page that errored
    require_in_frame: ["Firing"]                       # …and it must be IN THE PICTURE
    reshoot: false                                     # never overwrite an existing file
    allow_overlays: false                              # default: kill the tour modal + Lightspeed
```

Seven rules that matter:

1. **Never hardcode a cluster domain in the job file.** Write `{domain}`; it is substituted from
   `--domain` / `$OGSR_DOMAIN` at run time, in `url` and `url_sh` **only** — never in `pre_sh`, so
   a staging command must read hosts from the cluster (`oc get route …`). This keeps the job files
   portable — it is not a privacy rule (see "Cluster domains in captured images" below for that).
2. **Assert the view AND the state, with `wait_all_text`.** Every string in the list must be
   present. A single landmark that a list page and its detail pages both carry passes on the wrong
   screen — that is how eleven committed screenshots went wrong. `wait_text` (one string) still
   works and is fine where the string is genuinely unique to the settled page.
3. **Use `forbid_text` for pages that render their own errors.** A positive wait cannot see
   "Access restricted" or "No datapoints found": they arrive *beside* the heading it matched. Checked
   after the settle, before the shot, and fatal.
4. **Assert the FRAME with `require_in_frame`, not just the DOM.** Every wait above reads
   `document.body.innerText`, which includes text scrolled far out of view — so all of them pass on
   a perfect page whose subject is below the fold. `trusted-supply-chain-03` was committed that way:
   right page, `.sig` present, Tags table at y=1047 in a 1000px viewport. `require_in_frame`
   measures each string's box against the frame and is fatal. Fix a failure with a taller
   `viewport` or `scroll_to_text` — never by removing the assertion.
5. **On editable forms, use `wait_all_field_values`.** An `<input>`'s `value` is not part of
   innerText, so on views like Deployment → Environment a `wait_all_text` for a variable name can
   never pass, however correct the cluster is. If a wait fails on a page that is visibly showing the
   string, suspect the assertion before you re-stage anything.
6. **`reshoot` defaults to false and should usually stay there.** `capture.py` refuses to overwrite
   an existing screenshot without it, because these shots are state-dependent and a re-run captures
   whatever the lab looks like *now*. Set it only where the module's `media-manifest.md` says
   ❌ RE-CAPTURE, say so in a comment beside the flag — and take the flag back off once the good
   shot is on disk.

7. **Console overlays are dismissed for you, and their survival is fatal — do not switch this off.**
   The console paints two things *over* the page: the guided-tour modal ("Welcome to the new
   OpenShift experience!", `.co-tour-step-component`) and the OpenShift Lightspeed drawer, which
   **opens by itself on a profile's first visit** and fills 560×840 at x=1016 — the right third of a
   1600px frame. Rules 2–4 are all blind to them: `require_in_frame` measures the target's own box
   and, as its docstring concedes, "does not know whether something is painted on top". Measured
   2026-08-01 — `config-multienv-06-secret-masked` returned `OK 151 KB` with the modal lying across
   the Secret's Data section and the drawer over the right third. Every gate passed; the file was
   junk; only opening it caught that. `capture.py` now dismisses both (twice — they mount late) and
   **fails the job** if either survives. Set `allow_overlays: true` only when an overlay *is* the
   subject, as in the Lightspeed answer shot in `platform-orientation`.

A job that cannot be captured at all takes `parked: "<the reason>"` instead of a URL. It is never
executed and the reason is printed — that is how a decision stays next to the job rather than in a
commit message nobody re-reads.

Dry-run any file with `--plan` (no browser, no cluster, no login):

```bash
.venv/bin/python capture.py --jobs jobs-console-sweep.yaml --domain apps.example.com --plan
```

Retry one shot with `--only <filename fragment>`. Add `--no-pre` when the failure was on the
capture side rather than the cluster side — it skips every `pre_sh` and shoots the state as it is,
which matters because most `pre_sh` lines begin with `ws start` and that **purges the namespace**. A
retry that re-stages can destroy a good state and, on a loaded cluster, fail to rebuild it. Prove
the state yourself first (`oc get`, `oc set env --list`); with `--no-pre` nothing else will.
`url_sh` still runs — it resolves the target, it does not create it.

`capture.py` flags any output under 20 KB as suspicious, because that is what a splash screen
or an error page weighs. It is a smoke alarm, not a correctness check — **look at the images**.
Nothing in the harness can tell you a screenshot is *worth* keeping. `require_in_frame` narrows the
gap by proving the subject was in the picture, but the last gate is a person opening the PNG.

## Cluster domains in captured images

Screenshots of Gitea, Argo CD, Routes and RHDH carry the cluster they were taken on — the URL is
often the field the reader needs. **That is accepted** for ephemeral RHDP clusters (owner
decision, 2026-07-26): they are destroyed after use, and blanking the field would damage the
teaching value.

### Gitea renders in the machine's language

Gitea honours `Accept-Language`, so on a non-English machine its whole UI is translated and a
capture shows the wrong labels. Append `?lang=en-US` to **every** Gitea job URL — Playwright's
`locale` flag does not fix it, and the query param only holds for that browsing session (a later
context on the same profile reverted to the machine language). It is a cookie, not an account
setting.

What is still forbidden in an image: a visible token, password, or API key. **Look at the shot
before committing it** — CI cannot help here. The privacy guard runs `git grep`, which reads text
only, so anything rendered inside a PNG is invisible to it and the job stays green regardless.

## After capturing

Update the module's `media-manifest.md` row from `⬜ NOT CAPTURED` to captured, and replace the
`// media-pass: …` comment in the `.adoc` with the real `image::` macro plus alt text.
A captured file that nothing embeds is not done.

## Writing `.mmd` sources — two traps the renderer cannot warn you about

Both come from `htmlLabels: false`, which the SVG export needs (HTML labels become
`<foreignObject>`, which PowerPoint renders blank). Neither raises an error; both are only visible
if you **look at a raster of the output**.

**1. Label spaces were silently stripped — fixed in the renderer, 2026-07-28.** With HTML labels
off, mermaid emits each word as its own `<tspan>` carrying the separator as a *leading* space
(`<tspan>on</tspan><tspan> repeated</tspan>`). SVG's default `xml:space` strips leading whitespace
per chunk, so labels rendered `onrepeatedfailure`. It afflicted **all 81** committed diagrams
("every5min", "you:POSTaCloudEvent", "dead-lettersink") and nothing caught it: mermaid raises no
error, the SVG is well-formed, and the file size looks healthy. `preserve_label_spaces()` now adds
`xml:space="preserve"` to every `<text>`, and `spacing_is_broken()` fails the render if it ever
stops being applied. Note the live lab pages were never affected — the Antora sites set
`html_labels: true` — which is precisely why it survived: the surface everyone looks at was fine.

**2. HTML-only entities render literally; XML built-ins do not.** `&lt; &gt; &amp; &quot; &apos;`
are XML built-ins, so they survive into the SVG as proper escapes and display correctly (verified:
`networking-dev-devops/02-exposure-tree.mmd` renders `<pending>` exactly right). But `&nbsp;` — and
any other HTML-only entity — has no XML meaning and shows up **as the literal text `&nbsp;`**.
Mermaid's own `#lt;` form is decoded to the same XML escape, so it is equivalent, not safer. Use
literal Unicode instead (`—`, `·`, `→`); it renders correctly in both label modes.

## Diagram sources vs manifests — reconciled 2026-07-28

Re-run this after any diagram change; it is the only thing that compares the two sides:

```bash
# manifest names vs rendered SVGs vs .mmd sources
python3 - <<'EOF'
import pathlib, re
root = pathlib.Path("content/modules/ROOT")
wanted = set()
for m in (root/"assets/images").glob("*/media-manifest.md"):
    wanted |= set(re.findall(r"`([a-z0-9-]+\.svg)`", m.read_text()))
have = {p.name for p in (root/"assets/images").glob("*/*.svg")}
print(f"wanted {len(wanted)} | rendered {len(have)} | matched {len(wanted & have)}")
print("absent  :", sorted(wanted - have))
print("unlisted:", sorted(have - wanted))
EOF
```

**Current state: 96 wanted, 96 rendered, 96 matched, 0 unlisted.**

### `platform-accretion` (RESOLVED 2026-07-28)

This section used to describe an open question: twelve module manifests wanted a
`<module>-NN-platform-accretion.svg` and only two `.mmd` sources existed. Owner decision
2026-07-28 (commit `495590e`): author all twelve as real per-module sources rather than a shared
image or a renderer highlight parameter — explicit and readable, at the cost of keeping the grey
"platform you have already built" base in step across all twelve when it changes. All twelve now
exist, are rendered, and are reconciled into the manifests. What was still open after that commit
— actually *wiring the include into the page* — is closed by the decision below.

## DECISION (2026-07-31): every page diagram is live Mermaid; the SVGs are for slides, not pages

92 `// media-pass: …` notes across every module's `concept.adoc`/`wrapup.adoc` asked to
"replace/augment with SVG export `<slug>.svg`" once the export existed. The exports landed
2026-07-26 (label-space fix 2026-07-28, `ad61743`/`aa63622`) — but they were never wired in, and
the notes could never close on their own. Resolved as **decided-against**: pages keep the live
`[mermaid]` block; the note is deleted, not replaced with `image::`. Reasons, checked rather than
assumed:

- **The legibility problem the SVGs would have fixed is already fixed, live.** `ad61743`'s own
  message says why the SVGs exist: *"Browsers render \[mermaid] fine, PowerPoint does not"* — they
  were rendered for the **slide deck**, not the page. The page-legibility complaint (CC-5,
  diagrams reading too small, worst in the narrow cockpit panel) was root-caused and fixed
  separately in `content/supplemental-ui/partials/head-styles.hbs`: `.doc .imageblock .mermaid svg`
  is forced to scale to fill the column (`width:100% !important; max-width:900px`), which a static
  `image::` does not need and gains nothing from.
- **Lightbox already treats a live Mermaid SVG exactly like an `image::`.**
  `content/supplemental-ui/js/lightbox.js` opens the same full-window, click-to-enlarge overlay for
  `.doc .imageblock .mermaid svg` and `.doc .imageblock img` alike — the "worth converting to a
  static image so it can be enlarged" reason does not hold; both already can be.
- **Live Mermaid is the single source of truth; the SVG is a second copy that drifts.** Every page
  block is `include::example$diagrams/<mod>/NN-*.mmd[]` — the **same** `.mmd` the renderer reads to
  produce the SVG. Wiring in the SVG would mean every future edit to the `.mmd` has to remember to
  re-run `render_diagrams.py` and re-commit, with nothing in CI catching a miss (no
  `copy-drift-guard.py` pair covers `.mmd` → `.svg`). That class of drift already happened once —
  the `pipelines-fundamentals-02-pac-flow` incident this file documents below.
- **The SVGs are not orphaned assets — they are slide-deck source material.** Every row in every
  `media-manifest.md` diagram table says so explicitly (*"reused on slide N"*). Their consumer is
  the `sa-guides/outlines` → PPTX pipeline, not the Antora page. Do not delete them and do not wire
  them into pages; leave them exactly where they are, for exactly that job.

**What changed:** 76 of the 92 notes were in-scope pages (18 modules currently being edited by
other lanes — `build-deliver`, `gitops-at-scale`, `storage-stateful`,
`observability-health-scale` — were left alone; their 16 notes are the same decision, not yet
applied). Of the 76: 67 sat next to a diagram already live on the page and were simply deleted. The
other 9 (`config-multienv`, `developer-hub-golden-paths`, `multi-tenancy-workload-security`,
`gitops-fundamentals`, `pipelines-fundamentals`, `devspaces-inner-loop`, `networking-dev-devops`,
`jobs-batch-kueue`, `trusted-supply-chain`) were the `platform-accretion` notes: their `.mmd` source
and SVG both already existed (per the 2026-07-28 decision above) but no page ever `include::`d the
diagram — a bare comment, no live equivalent. `platform-orientation` and
`observability-health-scale` had already done this correctly (a `== The … layer over the Parasol
platform` section, two sentences, then the live include); the other 9 now follow the same pattern,
closing the last mechanical step of the 2026-07-28 decision rather than leaving nine bespoke
half-notes with no consistent rule.

**Consistency fix in the same pass:** `networking-dev-devops-05-network-policy-layers.svg` was the
only one of that module's five sibling diagrams with no `// media-pass:` marker — it already had a
live `[mermaid]` include and nothing pointing at the export, i.e. it was already in the end state
every other diagram is now in. No change needed there beyond the module's own platform-accretion
note (03) getting the same treatment as its siblings.

**Left for the owner:** the 16 notes in `build-deliver`, `gitops-at-scale`, `storage-stateful`,
`observability-health-scale` follow the identical pattern (confirmed while researching this) and
should get the identical treatment — delete the paired ones, wire the unpaired
`platform-accretion` ones as live Mermaid — once those lanes are done.

### What the earlier (2026-07-26) version of this section got wrong

Recorded because the reasoning failure is reusable, not just the facts:

- It called four sources *"genuinely missing."* They were **planned but never authored** — each had
  a live teaching beat in the page and a design brief in the manifest detailed enough to author
  from (`retry: 3`, `1s/2s/4s`, `knativeerrorcode: 404`). Three are now authored and embedded;
  a manifest row is a **brief**, not an inventory entry, so "wanted ≠ have" is backlog, not loss.
- It called `pipelines-fundamentals-02-pac-flow` a *"probable rename."* It was neither renamed nor
  dropped: `git log -S pac-flow -- content/` shows the string only ever existed in the manifest row
  and a `// media-pass:` marker. No such diagram was ever drawn. Slot 02 was later taken by
  `02-pipeline-choices`, which *is* authored — so the row was repointed at it. And the PaC flow is
  already drawn, inside `03-what-you-built.mmd` (`push → Gitea webhook → Pipelines-as-Code →
  PipelineRun`) — exactly what the row asked for.
- It said eight files belonged to *"modules whose manifests predate the extraction."*
  `ai-assisted-development` and `packaging-distributing` **had no manifest at all**. Both now have
  one, flagged as diagram-only.

The common error: inferring history from a filename mismatch instead of asking `git log -S`, and
assuming a shortfall meant something was lost rather than never built.
