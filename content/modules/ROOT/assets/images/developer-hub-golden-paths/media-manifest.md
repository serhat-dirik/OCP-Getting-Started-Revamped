# M11 media manifest — Developer Hub & Golden Paths

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default Developer Hub theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: …` line — replace with the `image::` (screenshot) or the SVG
`image::` (diagram) when the asset lands.

**Why this module's screenshots matter.** M11 is a **portal UI** module. The **catalog tour** and the
**golden-path scaffold** happen in the Red Hat Developer Hub web UI, so those views *are* the content —
the same load-bearing status as m09's Argo UI shots. The build performed the real attendee flow through
the **API** (guest token + catalog queries, the scaffolder v2 task `fetch`→`publish:gitea`→`register`,
the duplicate-name `409`, the published Gitea repo, the in-cluster build, `oc new-app` + curl) and
verified **every outcome** from the terminal — but the **browser views were not screen-captured** (no
browser in the build environment). Capture them in the media pass; they are the module's signature
visuals.

> **Note on the scaffold beat:** the money shot is the **template form + the three-step task page**
> (`04`, `05`) — a short form becoming a real repo + catalog entry. The `409` shot (`06`) is the
> deliberate break-and-fix and should show the failed *Publish* step and its error text.

## Screenshots (Developer Hub UI + terminal — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `developer-hub-golden-paths-01-catalog-components.png` | ⬜ NOT CAPTURED — **HIGH** | **Developer Hub Catalog**, Kind=Component | parasol-claims / parasol-web / parasol-notifications with owner (parasol) and type columns — the org map | lab.adoc ex. 1 (tour the catalog) |
| 2 | `developer-hub-golden-paths-02-component-and-api.png` | ⬜ NOT CAPTURED — **HIGH** | **parasol-claims entity page** + the **parasol-claims-api** OpenAPI tab | About card: owner=parasol, system=parasol-insurance, provides parasol-claims-api; the OpenAPI definition rendering | lab.adoc ex. 1 (the claims Component + its API) |
| 3 | `developer-hub-golden-paths-03-create-templates.png` | ⬜ NOT CAPTURED | **Create page** | the "New Parasol microservice" template card (tags: recommended, quarkus, java, parasol) and its paved-road description | lab.adoc ex. 2 (Create → Choose) |
| 4 | `developer-hub-golden-paths-04-template-form.png` | ⬜ NOT CAPTURED — **HIGHEST** | **The template form, filled** | Name `parasol-policy`, Your Gitea organization `user1-svcs`, Owner `parasol` — the core action of the module | lab.adoc ex. 2 (fill the form) |
| 5 | `developer-hub-golden-paths-05-scaffold-steps.png` | ⬜ NOT CAPTURED — **HIGH** | **Scaffolder task page** | the three steps (fetch / publish / register) completed green, and the output links ("Open the new repository", "Open in the software catalog") | lab.adoc ex. 2 (watch the task) |
| 6 | `developer-hub-golden-paths-06-scaffold-409.png` | ⬜ NOT CAPTURED | **Scaffolder task, failed** | the *Publish to Gitea* step failed (red) with `409 … repository with the same name already exists` — the deliberate break | lab.adoc ex. 2 (break and fix) |

## Diagrams (SVG in-repo; source of truth is the inline Mermaid in the `.adoc`)

The concept/wrap-up pages ship inline Mermaid (editable-source rule satisfied by construction).
Export these to SVG next to their `.adoc` for the slide deck and richer rendering; keep the Mermaid
as the editable source (do not delete it).

| # | Filename | Status | Source (inline Mermaid in) | Shows |
|---|----------|--------|-----------------------------|-------|
| 1 | `developer-hub-golden-paths-01-catalog-model.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | System → Components + API, owned by a Group; provides/consumes relations |
| 2 | `developer-hub-golden-paths-02-golden-path-flow.svg` | ⬜ NOT CAPTURED (export) | concept.adoc | form → template → scaffold + publish + register → new repo + catalog entry |
| 3 | `developer-hub-golden-paths-04-platform-accretion.svg` | ⬜ NOT CAPTURED (shared) | concept.adoc (pointer) | the cross-module Parasol platform diagram with the M11 layer (portal + catalog + golden path packaging M02–M10) highlighted |
| 4 | `developer-hub-golden-paths-05-what-you-built.svg` | ⬜ NOT CAPTURED (export) | wrapup.adoc | form → template → repo + catalog + in-cluster build → running service |

## Recording (demo-arc happy path)

- `developer-hub-golden-paths-demo.cast` (asciinema) OR `<90s` silent screen capture — ⬜ NOT CAPTURED.
  The flagship clip is the **scaffold**: Create → New Parasol microservice → fill the form → the three
  steps run → the new Component appears in the catalog and the repo in Gitea. It is fast (~10–15s), so a
  short screen capture of the Create-to-catalog flow is the highest-value clip. Do **not** record the
  ~8–9 min in-cluster build.
