# Media capture harness

Repeatable console / product-UI screenshots for the workshop media pass. Output lands in
`content/modules/ROOT/assets/images/<slug>/`, which is where each module's
`media-manifest.md` expects it.

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
  - slug: observability-health-scale                   # module slug = output directory
    filename: observability-health-scale-04-alert-firing.png   # 04-STYLE-GUIDE §4 naming
    pre_sh: ./tools/media/stage-m12-alert.sh user1     # put the CLUSTER in the state (repo-root cwd)
    pre_wait_s: 90                                     # let the state settle before shooting
    url: https://console-openshift-console.{domain}/dev-monitoring/ns/user1-dev/alertrules
    wait_all_text: ["ParasolClaimsErrorRateHigh", "Firing"]   # object AND state, both required
    forbid_text: ["Access restricted"]                 # refuse to shoot a page that errored
    reshoot: false                                     # never overwrite an existing file
```

Four rules that matter:

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
4. **`reshoot` defaults to false and should usually stay there.** `capture.py` refuses to overwrite
   an existing screenshot without it, because these shots are state-dependent and a re-run captures
   whatever the lab looks like *now*. Set it only where the module's `media-manifest.md` says
   ❌ RE-CAPTURE, and say so in a comment beside the flag.

A job that cannot be captured at all takes `parked: "<the reason>"` instead of a URL. It is never
executed and the reason is printed — that is how a decision stays next to the job rather than in a
commit message nobody re-reads.

Dry-run any file with `--plan` (no browser, no cluster, no login):

```bash
.venv/bin/python capture.py --jobs jobs-console-sweep.yaml --domain apps.example.com --plan
```

`capture.py` flags any output under 20 KB as suspicious, because that is what a splash screen
or an error page weighs. It is a smoke alarm, not a correctness check — **look at the images**.

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

**Current state: 96 wanted, 84 rendered, 84 matched, 0 unlisted.** The only gap left is the
`platform-accretion` family below — one decision, not twelve chores.

### The one open question: `platform-accretion` (12 absent)

Twelve module manifests name a `<module>-NN-platform-accretion.svg`, and only two sources exist
(`platform-orientation/02-platform-accretion-v1.mmd`,
`observability-health-scale/04-platform-accretion.mmd`). The manifests describe them as *"the
master accretion diagram, M03 layer highlighted on the M01/M02 base"* — one cumulative picture of
the Parasol platform, re-rendered per module with a different layer lit up. That is deliberate, so
**it will never resolve by rendering**. It needs a call:

- author the twelve variants as real sources (explicit; twelve files to keep in step), or
- keep one source and teach the renderer a highlight parameter (one file; the renderer grows), or
- share a single image everywhere and drop the per-module framing.

Nothing is broken today — lab pages render Mermaid client-side. The gap only bites the slide reuse
the manifests promise.

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
