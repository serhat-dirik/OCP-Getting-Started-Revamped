# M02 media manifest — Ways to Build & Deliver Apps

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Media note: the module's build/template/end-state mechanics were verified from the CLI/API as
`user2`; the console screenshots below were then captured on the live 4.21 console during the
2026-07-10 browser-verification pass (see the Status column). Diagrams ship as a standalone
Mermaid `.mmd` under `examples/diagrams/build-deliver/` (never inline in the `.adoc`); the SVG
diagram exports remain the deferred media pass.

## Screenshots (console views — the view IS the content)

| # | Filename | Status | Console view | Notice | Embed point |
|---|----------|--------|--------------|--------|-------------|
| 1 | `build-deliver-01-import-from-git.png` | ✅ DONE 2026-07-10 | **Quick create (+) → Import from Git**, `user1/parasol-claims` pasted, **repository-unreachable** warning, Import Strategy = **Builder Image → Java 21** | the Git URL field; the "repository is unreachable / unable to detect the import strategy" warning; the manually-selected **Java 21** tile | lab.adoc ex. 1 (Console tab) |
| 2 | `build-deliver-02-catalog-postgres-tile.png` | ✅ DONE 2026-07-10 | **Ecosystem → Software Catalog → Databases**, the Parasol PostgreSQL tile | the "Parasol PostgreSQL (ephemeral)" tile; provider "Provided by Parasol Insurance"; the DATABASE / PARASOL / POSTGRESQL tags | lab.adoc ex. 4 (Console tab) |
| 3 | `build-deliver-03-buildconfig-to-imagestream.png` | ⬜ NOT CAPTURED | Topology `parasol-claims` node → **Resources**: the completed Build and the ImageStream tag | the `Complete` build; `parasol-claims:latest`; the "Source (S2I)" strategy | lab.adoc ex. 1 (inspect) |
| 4 | `build-deliver-04-topology-built-and-wired.png` | ✅ DONE 2026-07-10 | Topology, project `user1-dev`, claims + claims-db + notifications all healthy | the `parasol-claims`→`claims-db` connection; the Open-URL arrow on claims | lab.adoc ex. 5 (end state) |

**#3 `build-deliver-03-buildconfig-to-imagestream.png` remains uncaptured** — the 2026-07-10
browser pass prioritized the two load-bearing shots (#1 the import reality, #2 the catalog) plus
the #4 end-state; the BuildConfig→ImageStream inspection (#3) is enrichment for an inline CLI step
and is deferred to the next media pass. It has no `// media-pass:` embed comment in `lab.adoc`
(no embed point), so its absence breaks nothing.

**4.21 console reality confirmed during the pass (corrections applied to `lab.adoc`):**

- **Import from Git does NOT auto-detect the builder.** The console backend cannot reach the
  in-cluster Gitea host, so it shows "the repository is unreachable" and "Unable to detect the
  import strategy"; the attendee selects *Import Strategy → Builder Image → **Java 21*** (a
  separate tile from "Java") and types the Name by hand. Added a troubleshooting entry and an
  honest lab NOTE; flagged as a candidate platform fix.
- **Builder tile label is "Java 21"** (info text: "Java 21 (UBI 9, S2I) … from source on UBI 9"),
  not "Java 21 (UBI 9)".
- **Dockerfile import strategy** — the *Dockerfile path* field renders **empty** and accepts
  `Containerfile`. Confirmed.
- **Context dir** under *Show advanced Git options* (Git reference / Context dir / Source Secret).
  Confirmed.
- **Catalog is renamed "Software Catalog"** (nav: **Ecosystem → Software Catalog**), Databases
  category, Type filter Templates/Helm Charts; the button is **Instantiate Template**; the form
  shows **display names** ("Database name", "PostgreSQL database name", …), not raw param names.
- **Deployment → Environment** — the all-keys control is the **"All values from existing
  ConfigMaps or Secrets (envFrom)"** section (equivalent to `--from=secret/claims-db`); a per-key
  "Add from ConfigMap or Secret" control also exists in the Single-values section.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `build-deliver-01-build-spectrum.svg` | concept.adoc Mermaid "build spectrum decision tree" — `examples/diagrams/build-deliver/01-build-spectrum.mmd` | the module's key diagram: image? / source? / need control? / workflow? |
| `build-deliver-02-platform-accretion-v2.svg` | (new) master accretion diagram, **build layer** highlighted | reuse the M01 platform base; light up the build/registry layer in red (accretion pattern) |
| `build-deliver-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/build-deliver/03-what-you-built.mmd` | green = objects the attendee created (source→S2I→image→Deployment + DB + Secret + Route) |

## Recordings

### Terminal cast — source to running app, S2I (`build-deliver-demo.cast`)
Record with asciinema as **user1** in `user1-dev` (reset first: `ws reset m02`). Exact sequence
(the claims build takes ~4 min — trim the wait in post, or narrate the trusted-content beat over it):

```sh
# (record from here)
oc project user1-dev
GITEA=$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}')   # or paste your Gitea host
# 1. deploy the database from the Parasol catalog template
oc process openshift//parasol-postgresql-ephemeral -p APP_NAME=claims-db | oc apply -f -
oc rollout status deployment/claims-db
# 2. build the claims service from source with S2I (Java 21 builder)
oc new-app java-21~https://$GITEA/user1/parasol-claims.git --name=parasol-claims
oc logs -f bc/parasol-claims        # ... BUILD SUCCESS / Push successful
# 3. wire the app to its database, publish it
oc set env deployment/parasol-claims --from=secret/claims-db
oc rollout status deployment/parasol-claims
oc expose service/parasol-claims
curl -s http://parasol-claims-user1-dev.$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')/api/claims | head -c 200
# (stop recording)
```
Target length < 2 min after trimming the build wait. Embed with asciinema-player on lab.adoc (near exercise 1 or 5).

### Screen capture — import-from-Git to Topology (`build-deliver-import.gif`, < 90 s)
Playwright/console capture: **Quick create (+) → Import from Git**, paste `user1/parasol-claims`,
dismiss the **repository-unreachable** warning, pick **Import Strategy → Builder Image → Java 21**,
type the Name, Create, and land in Topology with the build starting. This is the console-heavy
"source in, app out" moment; embed near lab.adoc exercise 1. Silent (no narration).

## Narration script

Generated in the Phase-6 media wave from the demo-flavor Say/Show/Do blocks in `lab.adoc`
(the `ifdef::demo[]` arc: import → catalog tour → trusted-content contrast → running app).
Shot list = the Show/Do lines; narration = the Say lines.
