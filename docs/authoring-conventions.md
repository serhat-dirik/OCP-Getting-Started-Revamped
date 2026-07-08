# Authoring conventions — workshop content

How the Antora/Showroom content under `content/` is written and built. This is the
scaffold-level reference; the full **module page template** (concept / lab / wrapup /
instructor / troubleshooting) lands with the M01 build. Rules here implement
`04-STYLE-GUIDE.md` and `01-ARCHITECTURE.md` §2; Vale + yamllint + shellcheck enforce
the automatable ones in CI.

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
environment-facing link from an attribute, opening in a new tab and deep-linking the exact
view where possible:

```asciidoc
Open the {ocp_console_url}[web console^] and switch to the *Developer* perspective.
Your username is `{user}`.
```

Available environment attributes (dev defaults in `content/antora.yml`, overridden at
deploy time): `{user}`, `{password}`, `{ocp_console_url}`, `{cluster_domain}`,
`{gitea_url}`, `{devspaces_url}`, `{rhdh_url}`, `{maas_endpoint}`.

## Product versions — generated attributes

Product versions come from `versions.yaml` (the single source of truth) through generated
attributes — never typed literally:

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
  ships at least one diagram (`04-STYLE-GUIDE §4`):

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
