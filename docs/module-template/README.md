# Module template — how to build a module

Extracted from the M01 vertical slice (2026-07-08). Copy `skeleton/` and follow the loop in 03-DEV-WORKFLOW §3: **perform the lab on the cluster first, write second**. Every command block shows output you actually captured; every timing is measured.

## The deliverable set (one module = all of these)

| Artifact | Path | Notes |
|---|---|---|
| Content (5 files) | `content/modules/ROOT/pages/mNN-<slug>/{concept,lab,wrapup,instructor,troubleshooting}.adoc` | skeletons in `skeleton/` |
| Demo flavor | `ifdef::demo[]` blocks inside concept/lab | `[demo-block]` + `[TIME Nm]` + Say/Show/Do, written after performing it once |
| Entry state | `gitops/entry-states/mNN/` (Helm chart + `ws-meta.yaml`) | compose, don't chain (ADR-0001); `solve:` value guards end-state templates |
| Verify script | `tools/verify/mNN.sh` | entry + end checks via `_lib.sh`; runnable as the attendee (no cross-ns reads) |
| Slides outline | `slides/outlines/mNN-<slug>.md` | 5–8 slides; validate with `tools/slides/build-deck.py` |
| Media manifest | `content/modules/ROOT/assets/images/mNN-<slug>/media-manifest.md` | every screenshot spec'd; asciinema script; embeds marked `// media-pass:` (never `TODO` — the media pass is a planned phase, not an open item; DoD's zero-TODO check must stay meaningful) |
| Nav entries | all three `nav-*.adoc` | workshop: concept+lab+wrapup · demo: concept+lab · instructor: concept+instructor+troubleshooting |

## Pattern-locking rules (M01 lessons — follow or your build breaks)

1. **Unified console.** OCP 4.19+ has no Developer/Administrator perspective switch (verified disabled on the build cluster). Never write "switch to the Developer perspective" — write unified-nav click paths (Topology and +Add live in the single nav).
2. **`[tabs]` nesting:** any `[%collapsible]`/`NOTE` block *inside* a tab must use a **5-`=` delimiter** (`=====`); same-length `====` collides and produces "unterminated open block".
3. **Attribute interpolation:** attributes do NOT interpolate inside mermaid `....` blocks or `[source]` blocks unless the block has `subs="attributes"`. Decide per block: real captured output = no subs (and generic values only); parameterized commands = `subs="attributes"`.
4. **Banned terms in output:** if real CLI output contains a banned term (e.g. the API's `DeploymentConfig is deprecated` warning), keep it ONLY inside the `[source]` block and reword all prose around it.
5. **Runnable blocks:** `[source,sh,role=execute]` — that's what makes click-to-run work in Showroom.
6. **Console labels you can't ground from the CLI** get a `[CAPTURE-VERIFY]` marker + a grounded CLI alternative beside them; the smoke tester confirms the labels in a browser.
7. **Environment values only via attributes** (`{user}`, `{ocp_console_url}`, `{cluster_domain}`, version attributes from `partial$version-attributes.adoc`). A hardcoded URL is a CI failure.
8. **Entry chart conventions:** marker ConfigMap `ws-entry-mNN` in the primary namespace (verify scripts check it); `ws-meta.yaml` lists purge namespaces for reset; every template carries a one-line "why" comment; secrets only by reference.
9. **Measure timings while performing** — the instructor table and `[~N min]` chips are measured, never guessed.
10. **Verify scripts run as the attendee**: no reads outside the user's namespaces (e.g. derive the Gitea host from the ingress domain instead of reading the route cross-namespace).
11. **Naming/acronym house convention** (resolves the 04-STYLE-GUIDE §1-vs-§5 ambiguity): full product name at first PROSE use per page ("Red Hat OpenShift Dev Spaces", then "Dev Spaces"); workshop-concept acronyms (S2I, UDI, ESO…) expanded at first use per page; ubiquitous tech acronyms (DNS, API, JSON, CPU, URL, JVM, PVC…) never expanded. Page titles and `//` comments don't count as first use.
12. **Checkpoints are for cluster-verifiable actions** — video/reading-only sections carry a timing chip but no `✔ Verify` block. **Tabs dual-path applies where console/CLI duality exists** — IDE-centric modules (M03) are a sanctioned exception.

## Gates

G1 self-audit (DoD in 03-DEV-WORKFLOW §4, output the checklist) → G2 content-editor mechanical pass → G3 sa-smoke-tester cold start (fresh user, follows the lab literally) → wave G4 milestone audit → G5 Serhat.
