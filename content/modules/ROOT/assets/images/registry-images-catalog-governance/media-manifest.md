# M17 media manifest — Registry, Images & Catalog Governance

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is dual-path but registry/ImageStream/governance work is
API-centric, so the mandatory recording is a **terminal cast** of the demo arc; screenshots are optional
enrichment for the Console tabs. All lab mechanics and every expected-output block were captured
on-cluster (OCP 4.21.22, Kubernetes 1.34, 2026-07-13 as user3); the diagram SVG exports below are
already rendered and committed (2026-07-26, label fix 2026-07-28) — the mandatory terminal cast and
the optional screenshots remain the deferred media pass. Every screenshot needs alt text (what it
shows + what to notice). Embed points are
marked in the `.adoc` files with a commented `// media-pass:` line — replace with the `image::…` when the
asset lands.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `registry-images-catalog-governance-01-two-supply-chains.svg` | concept.adoc Mermaid "two supply chains on one page" — `examples/diagrams/registry-images-catalog-governance/01-two-supply-chains.mmd` | external registries → **governance** (allowed-registries / IDMS-ITMS) → internal registry (svc:5000 + PVC + pruner) → **ImageStream** (immutable digest · scheduled · Local) → workload; **catalog supply** branch (OperatorHub sources · samples operator · ConsoleSample · namespaced Template · devfiles) → Developer Catalog. red = outside trust boundary, amber = platform governance, green = attendee hands-on. The module's spine — reused on slide 2 |
| `registry-images-catalog-governance-02-immutable-promote.svg` | concept.adoc "why an ImageStream still matters" | a moving tag `prod` pinned to an immutable `sha256`; `1.0` and `prod` arrows converging on the SAME digest box; a side note "re-push `1.0` upstream → `prod` still points at the promoted digest". The promotion-by-digest idea — reused on slide 3 |
| `registry-images-catalog-governance-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/registry-images-catalog-governance/03-what-you-built.mmd` | green = your namespaced work (promote · scheduled import · Template · pull secret); amber = cluster-wide governance you read (allowed-registries/IDMS-ITMS · nightly pruner · samples operator/ConsoleSample); blue = the internal registry + Developer Catalog they meet at |

Shared legend across the diagrams: registry cylinder, ImageStream box, immutable-digest badge, the
amber governance shield, catalog tile — same palette as M01–M16 (Red Hat-neutral, no vendor-logo soup).
Do **not** print product version numbers on the diagrams (IDMS/ITMS described as current, ICSP only as
the deprecated predecessor — matches the attribute + ban policy). Do **not** print the real cluster's
node names or a real private-registry host — use the sample `registry.parasol.example.com` placeholder
and generic `user3-dev`.

## Recordings

### Terminal cast — promote by digest → allowed-registries block → scheduled import → namespaced Template (`registry-images-catalog-governance-demo.cast`, ~10 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as `user3` (drive it
straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`):

1. the seeded `parasol-claims:1.0` stream → `oc tag` promote → **`prod` and `1.0` resolve to the identical `sha256`** (**hold on the two matching digest lines** — the money moment);
2. **[demo-cluster only]** set `allowedRegistriesForImport` → a `docker.io` import **refused** by admission → revert → the same import **allowed** (**capture the exact Forbidden string here** — it was NOT applied on the shared build cluster);
3. `oc import-image … --scheduled` → **`scheduled=true`** on the `ext-ubi` stream;
4. apply a namespaced `Template` → it lists as a catalog entry in **one** project only (the closer).

Step 1 (the identical digests) and step 2 (the policy block-and-revert) are the module's signature
moments; embed near lab.adoc exercises 2 and 6 and the demo arc. Keep the font large — the digests and
the denial line are the whole visual. **The allowed-registries beat mutates a cluster singleton — record
it on a disposable cluster, never a shared workshop cluster mid-session.**

## Screenshots (optional — Console tabs get visual support; CLI is the source of truth)
> **Media-pass status, 2026-08-01.** The console rows in this module could not be shot: the OpenShift
> console sits behind OpenShift OAuth, the cached capture session in `shot-profile.session.json` had
> expired (a probe came back as a 25 KB PNG of the IdP chooser — conventions §4 exactly), and
> establishing a new one needs a human to type a password, which that lane is barred from doing.
> What the lane did instead: it **staged and proved every cluster state these shots need** on
> `user7` and wrote them into `tools/media/jobs-m14-m19-console.yaml` with the staging scripts
> (`tools/media/stage-m1*.sh`). One login window now runs the whole block. Per-row status below.


| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `registry-images-catalog-governance-01-imagestream-detail.png` | ✅ CAPTURED 2026-08-01 as **user7** in `user7-dev`, verified by opening the PNG. Frame shows Image count 1 and a one-row Tags table: `parasol-claims:1.0`, its From reference, and the resolved `sha256:ca759845…`. The whole Tags table is inside the frame at 1600x1200 with no scrolling needed — that is only true while the stream has ONE tag; see row 2 for what happened when a second one arrived. | Circle: the `1.0` tag and its resolved `sha256` digest | lab.adoc ex. 1 Console tab |
| 2 | `registry-images-catalog-governance-02-imagestream-two-tags.png` | ✅ CAPTURED 2026-08-01 as **user7**, on the SECOND attempt, and the first attempt is the lesson. The run reported `OK 112 KB` and every gate passed — including `require_in_frame: [prod]` — but the `prod` row was SLICED by the bottom edge: its name read `parasol-` and its digest was cut mid-string, so the two-identical-digests comparison this row exists for was unreadable. `require_in_frame` measures where a box STARTS, not that the box is whole, so a row straddling the edge passes it. Fixed with `scroll_to_text: "Tags"` in the job, which centres the section and puts both rows fully in the picture. The good frame shows Image count 2, `parasol-claims:1.0` and `parasol-claims:prod`, both Identifier cells reading `sha256:ca759845d26c3d92402269100f9e16accbfa0fe951e54e9afd4df7ee9012dc80`. | Circle: both tags pointing at the same `sha256` | lab.adoc ex. 2 Console tab |
| 3 | `registry-images-catalog-governance-03-developer-catalog-template.png` | ✅ CAPTURED 2026-08-01 as **user7**, and it GROUNDS the type-filter question this row was unsure about: `?catalogType=Template` really does pre-apply the filter — the breadcrumb reads *Software Catalog → Templates* and the page is headed **Templates**, with a left rail of All items / CI/CD / Database / Databases / Languages / Middleware / Other. Filtered to `Parasol`, it returns **2 items**: *Parasol Claims Quickstart* and *Parasol PostgreSQL (ephemeral)*, both badged Templates and *Provided by Parasol Insurance*. Worth knowing before an attendee asks why they see two — the lab's prose names only the Quickstart. | Circle: the custom tile (present only in `{user}-dev`) | lab.adoc ex. 5 Console tab |
| 4 | `registry-images-catalog-governance-04-cluster-image-config.png` | ✅ CAPTURED 2026-08-01 as **user7**, on the THIRD attempt, and both failures are worth keeping. (1) The first frame passed every gate and was still wrong: the console renders this object WITH its `managedFields`, which mentions nearly every real field name as `'f:<name>'`, so the wait on `internalRegistryHostname` and `require_in_frame` (which matches the FIRST text node with `includes()`) both landed on a managedFields line at line 33 — a valid 154 KB PNG of apiVersion, kind and a screenful of managedFields, with the subject below the fold. Assertions now name VALUES (`Legacy`, the registry hostname), which managedFields never carries. (2) The second attempt then timed out on `Legacy` against a healthy page: the YAML editor is CodeMirror and renders only the lines near its own viewport, so at height 1100 the document stopped at line ~33 and `status:` was not in the DOM to be waited on OR scrolled to. Raising the browser viewport to 1600 makes the editor pane taller, which makes CodeMirror render all 50 lines. Also grounded on the way past: the **Details tab is useless for this row** — it carries only Name / Labels / Annotations / Created at / Owner, no registry fields at all. The good frame shows the whole object: `spec: {}` at line 46, then `status:` with `imageStreamImportMode: Legacy` and `internalRegistryHostname: image-registry.openshift-image-registry.svc:5000`. | Circle: `allowedRegistriesForImport` (empty = open) | lab.adoc ex. 6 (governance read) |

**Animated gif (PREFERRED for the promote-by-digest story):**
`registry-images-catalog-governance-05-promote-by-digest.gif` (<20 s, silent) — quick cuts:
`parasol-claims` with one `1.0` tag → `oc tag` → **two tags, identical `sha256`** side by side. The
matching-digest reveal is the payoff; hold the two `dockerImageReference` lines together.

`[CAPTURE-VERIFY]` labels to confirm while shooting (the unified console — no perspective
switch); these confirm the Console-tab click-paths written with `[CAPTURE-VERIFY]` in `lab.adoc`
(the CLI tabs are authoritative):

1. **Builds → ImageStreams → `parasol-claims`** shows the tag + resolved `sha256` (ex. 1), and *Actions → Edit ImageStream (YAML)* exposes `spec.tags` for the promote (ex. 2).
2. **Builds → ImageStreams → Create ImageStream (YAML view)** accepts `importPolicy.scheduled` (ex. 3).
3. **Workloads → Deployments → Create (YAML view)** accepts `spec.template.spec.imagePullSecrets` (ex. 4).
4. **Ecosystem → Software Catalog** (filter *Template*, sub-filter unverified) surfaces the namespaced **Parasol Claims Quickstart** and its *Instantiate Template* form (ex. 5).
5. **Administration → Cluster Settings → Configuration → Image** surfaces the `allowedRegistriesForImport` / `registrySources` fields the governance read + instructor demo reference (ex. 6).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the 10-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"same `sha256` on both — production runs the image we
tested, and I can prove it."*
