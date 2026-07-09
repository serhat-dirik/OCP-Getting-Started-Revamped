# M02 media manifest — Ways to Build & Deliver Apps

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// TODO(media): image::…` line — uncomment when the asset lands.

Constrained-environment note: the module was built and verified from the CLI/API (every
build, template, and end state was performed on the cluster as `user2`), but without a
browser. Diagrams ship inline as Mermaid (they satisfy the ≥1-diagram requirement today);
the SVG exports and the console screenshots below are the deferred media pass.

## Screenshots (console views — the view IS the content)

| # | Filename | Console view | Annotate | Embed point |
|---|----------|--------------|----------|-------------|
| 1 | `m02-build-deliver-01-import-from-git.png` | **+Add → Import from Git**, URL for `user1/parasol-claims` pasted, builder detected | Circle: the Git URL field; the detected **Java 21** builder tile; Target port 8080; Create | lab.adoc ex. 1 (Console tab) |
| 2 | `m02-build-deliver-02-catalog-postgres-tile.png` | **+Add → Developer Catalog → Database**, the Parasol PostgreSQL tile | Circle: the "Parasol PostgreSQL (ephemeral)" tile; provider "Parasol Insurance"; the database/parasol tags | lab.adoc ex. 4 (Console tab) |
| 3 | `m02-build-deliver-03-buildconfig-to-imagestream.png` | Topology `parasol-claims` node → **Resources**: the completed Build and the ImageStream tag | Circle: the `Complete` build; `parasol-claims:latest`; the "Source (S2I)" strategy | lab.adoc ex. 1 (inspect) |
| 4 | `m02-build-deliver-04-topology-built-and-wired.png` | Topology, project `user1-dev`, claims + claims-db + notifications all healthy | Circle: the `parasol-claims`→`claims-db` connection; the Open-URL arrow on claims | lab.adoc ex. 5 (end state) |

While shooting, resolve every `[CAPTURE-VERIFY]` note in `lab.adoc` and report any label that
differs from the text. The exact 4.21 labels to confirm:

- **Import-from-Git builder tile** for the workshop `java-21` stream — is it "Java 21 (UBI 9)"? Does import **auto-detect** it, or must the attendee pick it from the *Builder Image* dropdown? (CLI grounding: `oc new-app java-21~<git>` selects `openshift/java-21:latest`.)
- **Dockerfile import strategy** — the *Dockerfile path* field accepts `Containerfile`.
- **Context dir** field under advanced Git options (notifications `/node`).
- **Developer Catalog** filters ("Database"/"Template") and the Instantiate form fields (APP_NAME / POSTGRESQL_DATABASE / POSTGRESQL_USER / MEMORY_LIMIT).
- **Deployment → Environment** tab "Add from ConfigMap/Secret" control (wiring claims to `claims-db`).

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `m02-build-deliver-01-build-spectrum.svg` | concept.adoc Mermaid "build spectrum decision tree" | the module's key diagram: image? / source? / need control? / workflow? |
| `m02-build-deliver-02-platform-accretion-v2.svg` | (new) master accretion diagram, **build layer** highlighted | reuse the M01 platform base; light up the build/registry layer in red (accretion pattern) |
| `m02-build-deliver-03-what-you-built.svg` | wrapup.adoc Mermaid recap | green = objects the attendee created (source→S2I→image→Deployment + DB + Secret + Route) |

## Recordings

### Terminal cast — source to running app, S2I (`m02-build-deliver-demo.cast`)
Record with asciinema as **user1** in `user1-dev` (reset first: `ws reset m02`). Exact sequence
(the claims build takes ~4 min — trim the wait in post, or narrate the trusted-content beat over it):

```sh
# (record from here)
oc project user1-dev
GITEA=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}')   # or paste your Gitea host
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

### Screen capture — import-from-Git to Topology (`m02-build-deliver-import.gif`, < 90 s)
Playwright/console capture: **+Add → Import from Git**, paste `user1/parasol-claims`, confirm the
**Java 21** builder, Create, and land in Topology with the build starting. This is the console-heavy
"source in, app out" moment; embed near lab.adoc exercise 1. Silent (no narration).

## Narration script

Generated in the Phase-6 media wave from the demo-flavor Say/Show/Do blocks in `lab.adoc`
(the `ifdef::demo[]` arc: import → catalog tour → trusted-content contrast → running app).
Shot list = the Show/Do lines; narration = the Say lines.
