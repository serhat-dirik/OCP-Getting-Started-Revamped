# M17 media manifest — Registry, Images & Catalog Governance

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is dual-path but registry/ImageStream/governance work is
API-centric, so the mandatory recording is a **terminal cast** of the demo arc; screenshots are optional
enrichment for the Console tabs. All lab mechanics and every expected-output block were captured
on-cluster (OCP 4.21.22, Kubernetes 1.34, 2026-07-13 as user3); the diagram SVG exports below are the
deferred media pass. Every screenshot needs alt text (what it shows + what to notice). Embed points are
marked in the `.adoc` files with a commented `// media-pass:` line — replace with the `image::…` when the
asset lands.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `registry-images-catalog-governance-01-two-supply-chains.svg` | concept.adoc Mermaid "two supply chains on one page" | external registries → **governance** (allowed-registries / IDMS-ITMS) → internal registry (svc:5000 + PVC + pruner) → **ImageStream** (immutable digest · scheduled · Local) → workload; **catalog supply** branch (OperatorHub sources · samples operator · ConsoleSample · namespaced Template · devfiles) → Developer Catalog. red = outside trust boundary, amber = platform governance, green = attendee hands-on. The module's spine — reused on slide 2 |
| `registry-images-catalog-governance-02-immutable-promote.svg` | concept.adoc "why an ImageStream still matters" | a moving tag `prod` pinned to an immutable `sha256`; `1.0` and `prod` arrows converging on the SAME digest box; a side note "re-push `1.0` upstream → `prod` still points at the promoted digest". The promotion-by-digest idea — reused on slide 3 |
| `registry-images-catalog-governance-03-what-you-built.svg` | wrapup.adoc Mermaid recap | green = your namespaced work (promote · scheduled import · Template · pull secret); amber = cluster-wide governance you read (allowed-registries/IDMS-ITMS · nightly pruner · samples operator/ConsoleSample); blue = the internal registry + Developer Catalog they meet at |

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

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `registry-images-catalog-governance-01-imagestream-detail.png` | Console → Builds → ImageStreams → `parasol-claims` (project `{user}-dev`), the tag + `sha256` visible | Circle: the `1.0` tag and its resolved `sha256` digest | lab.adoc ex. 1 Console tab |
| 2 | `registry-images-catalog-governance-02-imagestream-two-tags.png` | Console → Builds → ImageStreams → `parasol-claims` after the promote, showing `1.0` **and** `prod` | Circle: both tags pointing at the same `sha256` | lab.adoc ex. 2 Console tab |
| 3 | `registry-images-catalog-governance-03-developer-catalog-template.png` | Console → +Add → Developer Catalog filtered to *Template*, the **Parasol Claims Quickstart** tile | Circle: the custom tile (present only in `{user}-dev`) | lab.adoc ex. 5 Console tab |
| 4 | `registry-images-catalog-governance-04-cluster-image-config.png` | Console → Administration → Cluster Settings → Configuration → **Image**, the allowed-registries fields | Circle: `allowedRegistriesForImport` (empty = open) | lab.adoc ex. 6 (governance read) |

**Animated gif (PREFERRED for the promote-by-digest story):**
`registry-images-catalog-governance-05-promote-by-digest.gif` (<20 s, silent) — quick cuts:
`parasol-claims` with one `1.0` tag → `oc tag` → **two tags, identical `sha256`** side by side. The
matching-digest reveal is the payoff; hold the two `dockerImageReference` lines together.

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console — no perspective
switch); these confirm the Console-tab click-paths written with `[CAPTURE-VERIFY]` in `lab.adoc`
(the CLI tabs are authoritative):

1. **Builds → ImageStreams → `parasol-claims`** shows the tag + resolved `sha256` (ex. 1), and *Actions → Edit ImageStream (YAML)* exposes `spec.tags` for the promote (ex. 2).
2. **Builds → ImageStreams → Create ImageStream (YAML view)** accepts `importPolicy.scheduled` (ex. 3).
3. **Workloads → Deployments → Create (YAML view)** accepts `spec.template.spec.imagePullSecrets` (ex. 4).
4. **+Add → Developer Catalog** (filter *Template*) surfaces the namespaced **Parasol Claims Quickstart** and its *Instantiate Template* form (ex. 5).
5. **Administration → Cluster Settings → Configuration → Image** surfaces the `allowedRegistriesForImport` / `registrySources` fields the governance read + instructor demo reference (ex. 6).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo`, the 10-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"same `sha256` on both — production runs the image we
tested, and I can prove it."*
