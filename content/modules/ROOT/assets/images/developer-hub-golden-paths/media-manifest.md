# M11 media manifest — Developer Hub & Golden Paths

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
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
browser in the build environment).

**All six are now captured and embedded** (rows 4–6 on 2026-08-01, anonymously — see the section below).
Nothing in the screenshot table is outstanding; only the recording remains.

> **Note on the scaffold beat:** the money shot is the **template form + the three-step task page**
> (`04`, `05`) — a short form becoming a real repo + catalog entry. The `409` shot (`06`) is the
> deliberate break-and-fix and should show the failed *Publish* step and its error text.

## How rows 4–6 were captured — no login, and no cluster mutation

**Developer Hub needs no credential.** `app-config-rhdh` enables the Backstage **guest** provider
outside development (`auth.providers.guest.dangerouslyAllowOutsideDevelopment: true`), so the whole
sign-in is one click on **Enter** in the "Select a sign-in method" chooser. `capture.py`'s
`click_text: [Enter]` does it, and it is a no-op once a session exists, so a job works cold and warm.
Note that a *bare* `curl` to `/api/...` still returns **401** — the guest identity is minted by the
browser flow, so "the API 401s" is not evidence that the UI is locked.

* **Row 4** is the only one that needs TYPING, which `capture.py` cannot do — it navigates and waits.
  `tools/media/capture_rhdh_form.py` fills the three fields and shoots. It **never submits**: no Gitea
  repo, no catalog entry, no scaffolder task, so it is safe to re-run against any user's values without
  touching that user's slot. The fields have stable react-jsonschema-form ids (`#root_name`,
  `#root_orgName`, `#root_owner`) — use those, not the visible labels, which carry a non-breaking thin
  space before the required marker. Assert with `input_value()`, never a text wait: an `<input>`'s value
  is not part of `innerText`.
* **Rows 5 and 6** are plain URLs (`/create/tasks/<taskId>`) once the tasks exist —
  `tools/media/jobs-anon-surfaces.yaml`. **Task IDs are per-cluster**; enumerate them rather than
  guessing:

  ```sh
  TOKEN=$(curl -sk https://<rhdh>/api/auth/guest/refresh \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["backstageIdentity"]["token"])')
  curl -sk -H "Authorization: Bearer $TOKEN" https://<rhdh>/api/scaffolder/v2/tasks?limit=20
  ```

  then read `status` (`completed` / `failed`) and `spec.parameters` to pick the pair. Row 6's wait must
  be the **banner** text (`409 Conflict`, "The repository with the same name already exists.") — the
  string `Run completed with status: failed` exists only in the task's API event stream and is **never**
  rendered on the page, so waiting on it fails on a perfectly correct view.

Rows 4–6 all carry **user6**'s values because that is the attendee whose two real task runs are behind
rows 5 and 6 — form, run, and collision are then one coherent story rather than three unrelated users.

## Screenshots (Developer Hub UI + terminal — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `developer-hub-golden-paths-01-catalog-components.png` | ✅ CAPTURED 2026-07-26 · **EMBEDDED 2026-08-01** | **"My Org Catalog"**, Kind=Component | the table "All Components (3)" — parasol-claims / parasol-notifications / parasol-web, columns Name · System · Owner · Type · Lifecycle · Description. All three share system `parasol-insurance`, owner `parasol`, lifecycle `production`; Type differs (service/service/**website**). The blue **Self-service** button is visible above the table — the way in to row 3 | lab.adoc ex. 1 (tour the catalog) |
| 2 | `developer-hub-golden-paths-02-component-and-api.png` | ✅ CAPTURED 2026-07-26 (entity page; the API tab is not expanded)| **parasol-claims entity page** + the **parasol-claims-api** OpenAPI tab | About card: owner=parasol, system=parasol-insurance, provides parasol-claims-api; the OpenAPI definition rendering | lab.adoc ex. 1 (the claims Component + its API) |
| 3 | `developer-hub-golden-paths-03-create-templates.png` | ✅ CAPTURED 2026-07-26| **Self-service page** | the "New Parasol microservice" template card (tags: recommended, quarkus, java, parasol) and its paved-road description | lab.adoc ex. 2 (Self-service → Choose) |
| 4 | `developer-hub-golden-paths-04-template-form.png` | ✅ CAPTURED 2026-08-01 (**anonymous — guest sign-in, one click on "Enter"**) | **The template form, filled** — page titled *Self-service*, step 1 of 2 "Provide service details" | Name `parasol-policy-user6`, Your Gitea organization `user6-svcs`, Owner `parasol` (the default) — the core action of the module. Only three fields, and the only button forward is **Review** (there is no *Next*) | lab.adoc ex. 2 (fill the form) — **now embedded** |
| 5 | `developer-hub-golden-paths-05-scaffold-steps.png` | ✅ CAPTURED 2026-08-01 (guest) | **Scaffolder task page** `/create/tasks/<taskId>` | the three steps (fetch 1s / publish 2s / register 0s) green, the output links ("Open the new repository", "Open in the software catalog"), the *Scaffolded* output panel, and the live log showing git init → commit → push → catalog registration. The elapsed times are the story: ~3 seconds | lab.adoc ex. 2 (watch the task) — **now embedded** |
| 6 | `developer-hub-golden-paths-06-scaffold-409.png` | ✅ CAPTURED 2026-08-01 (guest) | **Scaffolder task, failed** `/create/tasks/<taskId>` | a red banner `Error: Unable to create repository, 409 Conflict … "The repository with the same name already exists."`, fetch green, *Publish to Gitea* red, *Register* greyed and never run, plus **Start Over** — the deliberate break | lab.adoc ex. 2 (break and fix) — **now embedded** |

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

The concept/wrap-up pages `include::` their diagram source — a standalone `.mmd` under
`examples/diagrams/developer-hub-golden-paths/` (path linked per row in the Source column below),
never inline Mermaid text in the `.adoc`. Export these to SVG next to their `.adoc` for the slide
deck and richer rendering; keep the `.mmd` as the editable master (do not delete it).

| # | Filename | Status | Page (Mermaid included in) | Shows |
|---|----------|--------|-----------------------------|-------|
| 1 | `developer-hub-golden-paths-01-catalog-model.svg` | ✅ RENDERED 2026-07-26| concept.adoc — `examples/diagrams/developer-hub-golden-paths/01-catalog-model.mmd` | System → Components + API, owned by a Group; provides/consumes relations |
| 2 | `developer-hub-golden-paths-02-golden-path-flow.svg` | ✅ RENDERED 2026-07-26| concept.adoc — `examples/diagrams/developer-hub-golden-paths/02-golden-path-flow.mmd` | form → template → scaffold + publish + register → new repo + catalog entry |
| 3 | `developer-hub-golden-paths-04-platform-accretion.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/developer-hub-golden-paths/04-platform-accretion.mmd` | concept.adoc (pointer) | the cross-module Parasol platform diagram with the M11 layer (portal + catalog + golden path packaging M02–M10) highlighted |
| 4 | `developer-hub-golden-paths-05-what-you-built.svg` | ✅ RENDERED 2026-07-26| wrapup.adoc — `examples/diagrams/developer-hub-golden-paths/05-what-you-built.mmd` | form → template → repo + catalog + in-cluster build → running service |

## Recording (demo-arc happy path)

- `developer-hub-golden-paths-demo.cast` (asciinema) OR `<90s` silent screen capture — ⬜ NOT CAPTURED.
  The flagship clip is the **scaffold**: Create → New Parasol microservice → fill the form → the three
  steps run → the new Component appears in the catalog and the repo in Gitea. It is fast (~10–15s), so a
  short screen capture of the Create-to-catalog flow is the highest-value clip. Do **not** record the
  ~8–9 min in-cluster build.
