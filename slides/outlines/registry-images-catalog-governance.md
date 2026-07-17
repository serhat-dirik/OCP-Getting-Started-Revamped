# Registry, Images & Catalog Governance

## Slide: The layer underneath the shiny catalog

- The Developer Catalog didn't appear by magic
- A platform team curated every entry
- …and decided which registries images may come from
- Two supply chains: image supply + catalog supply
- An image reference is a promise — make it provable

Notes: Open on the connection to the Build & Deliver module. The shiny developer catalog — the builder images, the one-click samples, the operators — did not appear by magic: a platform team curated every entry and decided which registries an image may even come from. This module is the layer underneath that catalog: how the internal registry stores your images, why an ImageStream is still worth using, and how platform engineers govern where images come from and what developers can run and offer. Everything here is one of two supply chains that meet at the developer — the image supply decides which bits run, the catalog supply decides what a developer can pick from — and a platform team governs both. The through-line for the whole module: an image reference is a promise, and this layer is how you make it provable.
Visual: A "before/after" split — left: a lone `prod` tag floating over a registry with a question mark ("is this the image we tested?"); right: the same tag pinned to an immutable sha256, inside a governed supply chain with an amber "policy" gate.

## Slide: Two supply chains on one page

- Image supply: external → governance → registry → ImageStream → workload
- Catalog supply: OperatorHub sources · samples · ConsoleSample · Template · devfiles
- Red = outside your trust boundary
- Amber = platform governance controls
- Green = what you drive hands-on

Notes: This is the module's map. The image supply flows left to right: external registries, through the governance controls (allowed registries, import restrictions, IDMS/ITMS mirroring), into the internal registry (an in-cluster Service on :5000, backed by one volume, pruned nightly), tracked by an ImageStream (immutable digest, scheduled import, referencePolicy Local), out to your workload. The catalog supply is the bottom branch: OperatorHub sources and CatalogSources, the samples operator, cluster ConsoleSamples, your own namespaced Templates, and devfiles — all feeding the Developer Catalog. Red boxes are outside your trust boundary; amber boxes are the governance controls a platform team sets; green boxes are what you work with hands-on. You'll drive the green boxes in the lab and read the amber ones, because creating them is cluster-wide — the instructor's segment.
Visual: Reuse concept diagram registry-images-catalog-governance-...-01-two-supply-chains.svg — the left-to-right image supply with an amber governance gate, and the bottom catalog-supply branch converging on the Developer Catalog.

## Slide: Why an ImageStream still matters

- Pins a moving tag to an immutable sha256 digest
- Promote = pointer to exact bits, not a rebuild
- prod and 1.0 resolve to the SAME digest (provable)
- Scheduled import: re-pull a base image on its own
- referencePolicy Local: registry pull-through cache

Notes: A container reference like parasol-claims:prod is a moving target — whoever pushes that tag next changes what it points to. An ImageStream is OpenShift's answer: a stable in-cluster name that records the immutable digest behind each tag. Three properties earn it a place. It pins a tag to a digest — content-addressed, can never point at different bits — so "promote 1.0 to prod" becomes a pointer to an exact image; in the lab you prove prod and 1.0 share one sha256. It can re-import on a schedule — mark a tag scheduled and OpenShift re-checks the source and pulls the new digest when upstream moves, a base image that stays current without a human watching. And referencePolicy Local turns it into a pull-through cache — workloads pull from the internal registry, which fetches and caches the bits once. That last one is how the seeded parasol-claims stream works. ImageStreams also drive triggers — a Deployment can redeploy when the digest changes.
Visual: Reuse concept diagram registry-images-catalog-governance-...-02-immutable-promote.svg — two tag arrows (1.0, prod) converging on one immutable sha256 box, with a "re-push upstream → prod unmoved" side note.

## Slide: The trust boundary — where images may come from

- Two questions: is it signed? (Trusted Software Supply Chain) — may it come from here? (Registry, Images & Catalog Governance)
- allowedRegistriesForImport — instant, admission-level
- registrySources — node-enforced, reboots the pool
- IDMS / ITMS — mirror for disconnected installs
- ICSP is the deprecated predecessor (migrate to IDMS)

Notes: Two different questions decide whether an image runs, and they're complementary. "Is this image trusted?" — is it signed? — is the sigstore signature admission from the Trusted Supply Chain module, a different axis. "May images come from this registry at all?" is this module's boundary, set cluster-wide on the Image config object. allowedRegistriesForImport limits which registries a normal user may import from — instant, admission-level, no node change. registrySources.allowedRegistries governs what any pod or build may pull, enforced by the container runtime on every node — heavy, because changing it re-renders every node and rolls the pool. IDMS (ImageDigestMirrorSet) and ITMS (ImageTagMirrorSet) redirect pulls to a mirror — the heart of disconnected installs, also re-rendered onto every node. That blast-radius difference is why the lab reads these rather than sets them, and why the instructor can safely toggle only allowedRegistriesForImport live. The older ImageContentSourcePolicy is deprecated since 4.13 — convert it to IDMS with oc adm migrate icsp.
Visual: A three-tier "blast radius" ladder — allowedRegistriesForImport (instant, green) → registrySources (node reboot, amber) → IDMS/ITMS (every node, disconnected, red) — with a side arrow to Trusted Software Supply Chain "signatures = the other axis."

## Slide: The catalog supply — what developers can run and offer

- OperatorHub sources + CatalogSources (trim / add)
- Samples operator: skip a sample (never Removed)
- ConsoleSample: a cluster-wide blessed starter
- Namespaced Template: YOUR catalog entry, your ns only
- Devfiles: community + private (Dev Spaces, Dev Spaces & the Inner Loop)

Notes: The Developer Catalog you browsed is fed from several sources, each a governance lever. OperatorHub's operators come from catalog sources — the default four (Red Hat, Certified, Community, Marketplace) can be trimmed, and an org can add its own CatalogSource (this cluster has one curated internal catalog alongside the defaults). The builder images and quickstart templates are managed by the samples operator — 60 image streams and 51 templates on this cluster — and a platform team can skip an individual sample with skippedImagestreams/skippedTemplates, a scalpel, never the all-or-nothing managementState Removed which would delete every sample. A ConsoleSample is a cluster-scoped object that publishes a blessed starter. A namespaced Template is the one catalog lever you control — a Template in your own project appears in your Developer Catalog and nobody else's, self-service with no cluster-admin; you publish one in the lab. Devfiles come from a devfile registry (community, plus a private one that's a Dev Spaces/CheCluster config — the workspaces module). The through-line: the platform team decides what developers can run and offer.
Visual: A catalog "feed" diagram — five inputs (OperatorHub sources, samples operator, ConsoleSample, namespaced Template, devfiles) flowing into one Developer Catalog tile grid; the namespaced Template input tagged "your project only."

## Slide: Who runs what — and the honest operational note

- Hands-on (your namespace): promote, import, pull secret, Template, read
- Instructor demo (cluster-wide): allowed-registries, mirroring, samples, ConsoleSample
- allowedRegistriesForImport is instant — safe to toggle
- registrySources / IDMS-ITMS reboot every node — talk-through
- Nightly pruner: keep unreferenced images referenced

Notes: Because so much of this surface is a cluster singleton, the module splits cleanly. Hands-on, in your own namespace and non-disruptive: tour the registry and the parasol-claims stream, tag/promote, scheduled import, link a pull secret, publish a namespaced Template, and read the governance objects through the read-only platform-observer role. Instructor demo, cluster-wide: blocking imports with allowedRegistriesForImport (instant, live), registrySources plus IDMS/ITMS mirroring (talk-through — they reboot nodes), disabling a stock sample, and adding a ConsoleSample. The honest operational notes to carry: allowedRegistriesForImport is the only cluster-wide control safe to toggle live (admission-level, no reboot); registrySources and mirroring re-render every node and roll the pool, so never live mid-event. And the registry is one volume with a nightly pruner (daily, keep 3 revisions) — on a multi-day cluster, keep the images you use referenced by a running workload so they aren't pruned overnight.
Visual: A two-column "who runs what" table — left green "you (namespaced)", right amber "instructor (cluster-wide)" — with a small clock icon on the pruner row and a "reboots nodes" warning icon on the registrySources/IDMS row.

## Slide: What you'll do — and map to your org

- Tour the registry; promote 1.0 → prod by digest
- Scheduled import + read a real import failure
- Wire a pull secret; publish a namespaced Template
- Read the governance surface (allowed-registries, pruner, catalog)
- When you "promote to prod," can you prove it's what you tested?

Notes: Set expectations for the hands-on, all in the attendee's own claims namespace, then land the transfer. You tour the internal registry and the seeded parasol-claims stream, reading its immutable digest and Local pull-through; promote 1.0 to prod and prove the two names share a sha256; make an external base image stay current with a scheduled import and read a real import failure — "name unknown: Repo not found" — instead of guessing; wire a pull secret to a workload two ways (ServiceAccount link and pod-level imagePullSecrets); publish a namespaced Template that appears in your catalog alone and deploy from it; and read the cluster-wide governance surface — where images may come from, what's pruned, what the catalog offers. Take the questions back: when you "promote to prod," can you prove by digest it's the image you tested? Where can images in your cluster come from, and who decided? And who curates your catalog — is the blessed starter actually in it, or is it just whatever shipped?
Visual: Numbered arc strip: tour → promote-by-digest → scheduled import (break-fix) → pull secret → namespaced Template → read governance; footnote pointers to Trusted Software Supply Chain (signatures) and Ways to Build & Deliver Apps (the catalog this governs).
