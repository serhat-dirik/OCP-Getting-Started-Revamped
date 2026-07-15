# Authoring conventions — workshop content

How the Antora/Showroom content under `content/` is written and built. This is the
scaffold-level reference; the full **module page template** (concept / lab / wrapup /
instructor / troubleshooting) lands with the M01 build. Rules here implement
`04-STYLE-GUIDE.md` and `01-ARCHITECTURE.md` §2; Vale + yamllint + shellcheck enforce
the automatable ones in CI.

## Course-wide content standards (CC-1…CC-5)

Five editorial standards apply to **every** module, from the owner's hands-on Foundations
review (2026-07). They are the reading-experience contract every module-builder inherits;
sweep them whenever a module reaches Definition of Done and when auditing the catalog. Vale
covers some mechanically (noted per rule); the rest are reviewer-checked.

### CC-1 — No version anchoring in prose

Don't write product version numbers into prose — not "Dev Spaces 3.29.0", not "the 4.21.22
unified console". Name the product plainly ("Dev Spaces", "the OpenShift console"). When a
version genuinely changes what the reader does, pull it from a `{<key>_version}` attribute
(see [Product versions](#product-versions--generated-attributes)), never a typed literal.

*Why:* prose version anchors rot within a release, add nothing the reader can act on, and
fork the truth away from `versions.yaml`. *Sweep:* grep prose for `\b\d+\.\d+(\.\d+)?\b`
outside `source`/`texinfo` blocks and attribute definitions; most hits are anchors to remove.

### CC-2 — Credits live only in `CREDITS.md`

All attribution lives in the repo-level `CREDITS.md` (with the README pointer). **No module
page carries a Credits or Attribution section** — not concept, lab, wrapup, instructor, or
troubleshooting. When a module reuses a source, add a row to `CREDITS.md`; never a per-module
credits block.

*Why:* (owner decision, 2026-07-14) credit is a project-level acknowledgement, not per-module
chrome — consolidating keeps it complete, consistent, and out of the attendee's reading flow.
*Sweep:* grep module pages for `^==* *Credits`/`Attribution`/`Acknowledge` headings — there
should be zero.

### CC-3 — Terminal-output hygiene

Command blocks produce clean output. Every `echo` ends its line with a newline (no trailing
`-n`; add a closing `echo` after a multi-line print if the last line would otherwise glue to
the prompt). No ragged, run-together output in a captured block.

*Why:* attendees copy-run these; no-newline or ragged output reads as broken and erodes trust
in the lab — a false "this is wrong" costs you every real signal after it. *Sweep:* flag
`echo -n` and `printf` without a trailing `\n` inside `role=execute` blocks.

### CC-4 — External links open in a new tab

Every link that leaves the guide — console, Gitea, Dev Spaces factory/workspace, Argo CD,
`docs.redhat.com`, `developers.redhat.com` — uses Antora's new-window flag: the trailing `^`
inside the macro, `{ocp_console_url}[web console^]`, `https://developers.redhat.com/…[Podman
Desktop^]`. An external link must never replace the instruction window.

*Why:* a factory/workspace URL that hijacks the current tab drops the attendee out of the lab
and loses their place. *Sweep:* flag external `link:`/`url[text]` macros whose bracket text
lacks a `^`.

### CC-5 — Diagram legibility (size + lightbox)

Every diagram is readable in-flow and enlargeable. Author/export at a size where labels are
legible without zooming, and make it click-to-enlarge (lightbox). A diagram nobody can read
is decoration, not documentation.

*How:* the lightbox helper ships via `content/supplemental-ui` — remember `ui.supplemental_files`
must be a **single bare directory string** (a list or a `./`-prefix silently injects nothing);
verify the CSS/JS in the **served** page, not just the repo. Mermaid sizing and the tab-overlap
fix live in the supplemental head-styles. Export image diagrams large enough that the lightbox
has real resolution to show.

## Build & preview

One Antora component (`modules`, versionless) renders three ways from the same source,
differing only in `asciidoc.attributes`, `site.title`, and `output.dir`:

| Playbook | Flavor | Output |
|---|---|---|
| `content/site-workshop.yml` | attendee guide (default) | `www/workshop` |
| `content/site-demo.yml` | SA presenter guide (`demo: true`) | `www/demo` |
| `content/site-instructor.yml` | internal runbook (`instructor: true`) | `www/instructor` |

```sh
npm install            # once — installs pinned Antora + extensions
npm run build          # all three flavors
npm run build:workshop # one flavor
utilities/lab-serve    # build workshop + serve http://localhost:8080
```

> **Always build from inside `content/`.** Antora resolves the local content-source
> `url: ..` relative to the invocation directory, so it must point at the repo root
> from `content/`. The npm scripts and `utilities/lab-serve` do this for you; a bare
> `npx antora content/site-workshop.yml` from the repo root will **not** resolve. Prefer
> `npm run build:*`.

## One source, three renderings

Wrap flavor-specific content in conditionals keyed off the flavor attribute:

```asciidoc
ifdef::workshop[]
Hands-on exercise steps and checkpoints.
endif::workshop[]

ifdef::demo[]
[TIME 3m]
Say:: One or two spoken sentences, verbatim-usable.
Show:: What is on screen (window, view, zoom target).
Do:: Exact click path / command.
endif::demo[]

ifdef::instructor[]
Timing, pre-flight checks, top questions, watch-outs.
endif::instructor[]
```

The `workshop` attribute is unset in the workshop playbook, so use `ifndef::demo,instructor[]`
for content that should appear only in the attendee guide, or just author it unconditionally
(it shows in all three).

## Runnable commands — `role=execute`

Every command an attendee runs uses `[source,sh,role=execute]` so it is click-to-run in
the Showroom terminal (copy-enabled everywhere else):

```asciidoc
[source,sh,role=execute]
----
oc get pods -n parasol
----
```

Use `oc`, never `kubectl` (Vale flags it). Show expected output in a separate block, and
collapse it when longer than five lines:

```asciidoc
[source,texinfo,subs="attributes"]
----
NAME             READY   STATUS
parasol-web-...  1/1     Running
----
```

`subs="attributes"` interpolates `{...}` inside a literal block.

## Links & environment values — attributes only

Never hardcode a cluster URL, user, or password (Vale error `HardcodedURL`). Build every
environment-facing link from an attribute, opening in a new tab (the `^` flag — CC-4) and
deep-linking the exact view where possible:

```asciidoc
Open the {ocp_console_url}[web console^] and switch to the *Developer* perspective.
Your username is `{user}`.
```

Available environment attributes (dev defaults in `content/antora.yml`, overridden at
deploy time): `{user}`, `{password}`, `{ocp_console_url}`, `{cluster_domain}`,
`{gitea_url}`, `{devspaces_url}`, `{rhdh_url}`, `{maas_endpoint}`.

## Product versions — generated attributes

Product versions come from `versions.yaml` (the single source of truth) through generated
attributes — never typed literally, and never anchored in prose where the version doesn't
change what the reader does (CC-1):

```asciidoc
\include::partial$version-attributes.adoc[]

This lab targets OpenShift GitOps {gitops_version} on OpenShift {ocp_version}.
```

Regenerate after editing `versions.yaml` (CI fails on drift):

```sh
tools/gen-attributes.sh          # rewrite content/modules/ROOT/partials/version-attributes.adoc
tools/gen-attributes.sh --check  # what CI runs
```

Attribute names are `<key>_version` for every product entry in `versions.yaml`
(`ocp_version`, `pipelines_version`, `rhbk_version`, …).

## Reusable partials

- **`partial$prereq-ws-start.adoc`** — the standard "materialize this module" box at the
  top of every `lab.adoc`. Set `:module-id:` first:

  ```asciidoc
  :module-id: m07
  \include::partial$prereq-ws-start.adoc[]
  ```

- **`partial$instructor-demo.adoc`** — the `[INSTRUCTOR-DEMO]` callout for instructor-performed
  segments (renders in all flavors). Set the body first:

  ```asciidoc
  :demo-title: The cluster blocks an unsigned image
  :demo-body: The instructor pushes an unsigned build; admission refuses it on screen.
  \include::partial$instructor-demo.adoc[]
  ```

  For multi-paragraph segments, author a `[NOTE,role=instructor-demo]` block directly instead.

## Diagrams (Mermaid) & dual-path tabs

Two Antora extensions are enabled in every playbook:

- **Mermaid** (`@sntke/antora-mermaid-extension`) — inline diagrams. Every concept section
  ships at least one diagram (`04-STYLE-GUIDE §4`), sized and lightboxed per CC-5:

  ```asciidoc
  [mermaid]
  ....
  graph LR; web --> claims --> db[(Postgres)]
  ....
  ```

- **Tabs** (`@andrew-jones/antora-tabs-extension`) — console-vs-CLI dual paths in M01–M04:

  ```asciidoc
  [tabs]
  ====
  Console::
  +
  --
  Steps in the web console.
  --
  CLI::
  +
  --
  [source,sh,role=execute]
  ----
  oc apply -f app.yaml
  ----
  --
  ====
  ```

## Per-flavor navigation

`content/antora.yml` currently references `nav-workshop.adoc` for all flavors while the three
navs (`nav-workshop.adoc`, `nav-demo.adoc`, `nav-instructor.adoc`) are identical. Antora
resolves navigation at the component level, not per-playbook, so when the demo/instructor navs
diverge, wire them by listing all three in `content/antora.yml` and guarding each file's body:

```asciidoc
// nav-demo.adoc
ifdef::demo[]
* xref:index.adoc[Welcome & Demo Paths]
// … demo entries …
endif::demo[]
```

so exactly one renders per flavor. Modules register themselves in the nav as they are built,
grouped under the four blocks (A Foundations / B Delivery & Trust / C Platform & Tenancy /
D Advanced Electives).

## Linting (enforced in CI)

- **Vale** (`.vale/styles/Workshop/`) — banned terminology (`DeploymentConfig`, `RH-SSO`,
  `master node`, marketing language, …) as errors; `kubectl` and hardcoded cluster URLs
  flagged. See `04-STYLE-GUIDE §5`.
- **yamllint** (`.yamllint.yaml`), **shellcheck** — repo YAML and shell scripts.
- **content-build** — all three flavors build with warnings-as-errors; broken xrefs/includes fail.

## Module page skeleton (pointer)

Each module is one directory `content/modules/ROOT/pages/mNN-<slug>/` with
`concept.adoc`, `lab.adoc`, `wrapup.adoc`, `instructor.adoc`, `troubleshooting.adoc`
(`04-STYLE-GUIDE §2`). The full authored template arrives with M01.
