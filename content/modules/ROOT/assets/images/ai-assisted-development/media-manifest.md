# M25 media manifest — AI-Assisted Development on OpenShift

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
| `ai-assisted-development-01-mcp-sa-boundary.svg` | concept.adoc Mermaid "where the AI's authority actually comes from" — `examples/diagrams/ai-assisted-development/01-mcp-sa-boundary.mmd` | the security spine of the module: the assistant/CLI holds **no kubeconfig**, and every action lands as the **`mcp-agent` ServiceAccount** inside `{user}-dev`. The client's ambition is irrelevant — the SA's RBAC is the ceiling |
| `ai-assisted-development-02-two-phase-rbac.svg` | concept.adoc Mermaid "read-only first, then narrow write" — `examples/diagrams/ai-assisted-development/02-two-phase-rbac.mmd` | phase 1 = `view` (eyes: pods, events, logs — **no secrets, no writes, one namespace**), phase 2 = a deliberately narrow write grant. The "earn the verbs" progression the lab walks |
| `ai-assisted-development-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/ai-assisted-development/03-what-you-built.mmd` | the two halves side by side: read-only diagnosis of the broken app, and the scoped write that fixes it — with the tool-call trace as the audit surface |
