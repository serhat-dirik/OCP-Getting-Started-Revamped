# Media capture harness

Repeatable console / product-UI screenshots for the workshop media pass. Output lands in
`content/modules/ROOT/assets/images/<slug>/`, which is where each module's
`media-manifest.md` expects it.

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

`login.py` opens a **headed** window on a throwaway profile directory. A human logs in there;
the session cookie persists in that profile, and `capture.py` reuses it headlessly.

Neither script reads, types, stores or transmits a credential. The password goes from the
human into the real OpenShift login page and nowhere else. The profile directory is
disposable — delete it and log in again when the token expires.

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
  - slug: pipelines-fundamentals                      # module slug = output directory
    filename: pipelines-fundamentals-01-graph.png     # 04-STYLE-GUIDE §4 naming
    url: https://console-openshift-console.{domain}/k8s/ns/user1-cicd/...
    wait_text: "Tasks Completed"                      # text ONLY the settled page has
```

Two rules that matter:

1. **Never hardcode a cluster domain in the job file.** Write `{domain}`; it is substituted from
   `--domain` / `$OGSR_DOMAIN` at run time. This keeps the job files portable between clusters —
   it is not a privacy rule (see "Cluster domains in captured images" below for that).
2. **Pick `wait_text` that a half-rendered page does not have.** The console shell, its nav
   sidebar and `document.title` all arrive early. Wait on a plugin-rendered tab label, a table
   column header, or a status string — something from the part of the page you are shooting.

`capture.py` flags any output under 20 KB as suspicious, because that is what a splash screen
or an error page weighs. It is a smoke alarm, not a correctness check — **look at the images**.

## Cluster domains in captured images

Screenshots of Gitea, Argo CD, Routes and RHDH carry the cluster they were taken on — the URL is
often the field the reader needs. **That is accepted** for ephemeral RHDP clusters (owner
decision, 2026-07-26): they are destroyed after use, and blanking the field would damage the
teaching value.

What is still forbidden in an image: a visible token, password, or API key. **Look at the shot
before committing it** — CI cannot help here. The privacy guard runs `git grep`, which reads text
only, so anything rendered inside a PNG is invisible to it and the job stays green regardless.

## After capturing

Update the module's `media-manifest.md` row from `⬜ NOT CAPTURED` to captured, and replace the
`// media-pass: …` comment in the `.adoc` with the real `image::` macro plus alt text.
A captured file that nothing embeds is not done.

## Diagram sources vs manifests — the 2026-07-26 reconciliation

Rendering every source exposed a mismatch that was invisible while nothing was rendered:
manifests name **89** SVGs, sources yield **81**, and only **73** names match. That is three
separate situations, and only one is a defect. Re-run the comparison after any diagram change —
`render_diagrams.py --dry-run` lists what would be produced.

**1. The `platform-accretion` family is by design (11 of the 16 absent).** Only two sources exist
(`platform-orientation/02-platform-accretion-v1.mmd`,
`observability-health-scale/04-platform-accretion.mmd`), while eleven module manifests name a
variant. The manifests describe them as *"the master accretion diagram, M03 layer highlighted on
the M01/M02 base"* — one cumulative picture re-rendered per module with a different layer
emphasised. This will never resolve by rendering. It needs a call: author the variants as real
sources, teach the renderer a highlight parameter, or share one image. Nothing is broken today —
lab pages render Mermaid client-side; the gap only bites the slide reuse the manifests promise.

**2. Four genuinely missing sources.** `eventing-deep-dive-02-retries-dlq`,
`serverless-zero-to-hero-02-cold-start-timeline`,
`service-mesh-advanced-gateways-02-traffic-split`, `pipelines-fundamentals-02-pac-flow`. Check the
module's `concept.adoc` before authoring: if the page never carried that diagram, the manifest row
is stale and should go.

**3. One probable rename, and the interesting one.** The manifest wants
`pipelines-fundamentals-02-pac-flow.svg` ("push → Gitea webhook → PaC controller → new
PipelineRun"); what exists is `pipelines-fundamentals-02-pipeline-choices.svg`. Same module, same
number, different subject. The PaC flow is a real teaching beat in exercise 4, so if it was dropped
rather than renamed, the module lost something.

**4. Eight rendered files no manifest lists** — `ai-assisted-development` (3),
`packaging-distributing` (3), `networking-dev-devops-05-network-policy-layers`,
`pipelines-fundamentals-02-pipeline-choices`. Modules whose manifests predate the extraction.
Mechanical to add, but do it alongside the accretion decision so the row format matches.
