# M26 media manifest — Packaging & Distributing Your App

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).

**Scope note (2026-07-28).** This manifest was created to cover the module's *diagrams*, which
existed as `.mmd` sources and rendered SVGs while no manifest listed them — so the reconciliation
in `tools/media/README.md` reported them as orphans. The recordings / screenshots / narration
sections that other modules' manifests carry are **not yet specified for this module**; that is a
known gap, not an assertion that none are wanted. Do not read the absence of those sections as
"this module needs no screenshots."

Every screenshot needs alt text (what it shows + what to notice). Embed points are marked in the
`.adoc` files with a commented `// media-pass:` line — replace with the `image::…` when the asset
lands.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `packaging-distributing-01-spectrum.svg` | concept.adoc Mermaid "the packaging spectrum" — `examples/diagrams/packaging-distributing/01-spectrum.mmd` | raw manifests → Template → Kustomize → Helm → Operator, as one axis: **how much day-2 responsibility is encoded in the package**. The framing the whole module hangs on — it is a spectrum, not a ranking |
| `packaging-distributing-02-olm-anatomy.svg` | concept.adoc Mermaid "what OLM actually does" — `examples/diagrams/packaging-distributing/02-olm-anatomy.mmd` | CatalogSource → PackageManifest → Subscription (you pick a channel) → InstallPlan (Automatic or Manual approval) → CSV. The chain to walk when an operator install is stuck |
| `packaging-distributing-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/packaging-distributing/03-what-you-built.mmd` | the Helm arc you actually ran: `helm create` → values + templates → install → upgrade → **break** → rollback → test |
