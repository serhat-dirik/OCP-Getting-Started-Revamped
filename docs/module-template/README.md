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
8. **Entry chart conventions:** marker ConfigMap `ws-entry-mNN` in the primary namespace (verify scripts check it); `ws-meta.yaml` lists purge namespaces for reset; every template carries a one-line "why" comment; secrets only by reference. **Optional `smokeCommands:` key** — a `ws-meta.yaml` list of 1–3 representative attendee commands the module genuinely leans on (an in-terminal `mvn …`, an `argocd app delete`); `ws smoke mNN` runs each as `{user}` inside the live cockpit and asserts exit 0 (`${USER}` resolves to the target user). Default empty — the generic smoke battery already covers the cockpit/identity class, so add only load-bearing commands (YAGNI). Example: `smokeCommands:` then `  - "oc get deployment claims-analysis -n ${USER}-prod"`.
9. **Measure timings while performing** — the instructor table and `[~N min]` chips are measured, never guessed.
10. **Verify scripts run as the attendee**: no reads outside the user's namespaces (e.g. derive the Gitea host from the ingress domain instead of reading the route cross-namespace).
11. **Naming/acronym house convention** (resolves the 04-STYLE-GUIDE §1-vs-§5 ambiguity): full product name at first PROSE use per page ("Red Hat OpenShift Dev Spaces", then "Dev Spaces"); workshop-concept acronyms (S2I, UDI, ESO…) expanded at first use per page; ubiquitous tech acronyms (DNS, API, JSON, CPU, URL, JVM, PVC, RBAC…) never expanded (RBAC ruled in 2026-07-11 — mixed precedent resolved). Page titles and `//` comments don't count as first use.
12. **Checkpoints are for cluster-verifiable actions** — video/reading-only sections carry a timing chip but no `✔ Verify` block. **Tabs dual-path (CLI | Console) is the STANDARD for every lab step where console/CLI duality exists — all modules, not just M01–M04** (project ruling 2026-07-11; supersedes the style guide's earlier scoping). Duality test: can the step be done both in the terminal and in the OpenShift web console? If yes → `[tabs]`. Single path only where duality is genuinely absent (pure product-UI beats like Argo CD UI/RHDH portal/Gitea, pure-git steps); IDE-centric modules (M03) stay a sanctioned exception. Console click-paths are grounded live (rule 1: unified console) with `[CAPTURE-VERIFY]` + CLI alternative per rule 6.
13. **Entry charts own only in-namespace state — never namespace policy.** The `workshop-entries` AppProject blacklists `ResourceQuota`/`LimitRange` (they must survive `ws reset`), so a chart that ships them NEVER syncs via the sanctioned `ws start` path — and `helm template | oc apply` during the build will mask it (G3-M06 F1: the chart worked for the builder, failed for every attendee). Per-user namespaces, quotas, limits, and RBAC live in the workshop layer (`gitops/workshop-config/templates/per-user-*.yaml`; module-extra namespaces follow the `per-user-batch.yaml` precedent). Self-check before G1: `helm template` your chart and grep for `kind: (ResourceQuota|LimitRange|Namespace)` — Namespace is cluster-whitelisted but still belongs to the workshop layer. **Attendee-facing prep/reset text says `ws prep {module-id}`** (self-service: detects leftovers, asks consent, wipes + re-prepares — project directive 2026-07-10; `--yes` variant for a factory-fresh redo). `ws start`/`ws reset` are the instructor bulk/backstop verbs — never tell attendees to run them. **Same-namespace modules are conflicts**: if your chart materializes into a namespace another module uses, list each other in `ws-meta.yaml` `conflictsWith` (both directions — see ADR-0001 amendment 2026-07-10); only cross-namespace modules truly coexist.

## Gates

G1 self-audit (DoD in 03-DEV-WORKFLOW §4, output the checklist) → G2 content-editor mechanical pass → G3 sa-smoke-tester cold start (fresh user, follows the lab literally) → wave G4 milestone audit → G5 project-owner sign-off.

G1 additionally requires the **attendee-cockpit gate**: `ws smoke mNN [userN]` green — it runs the attendee path (ws-on-PATH, `$HOME`/JVM `user.home`, isolation, freshness, in-cockpit `ws prep`/`verify`, plus any `smokeCommands`) from inside the live cockpit as `{user}`, never the admin kubeconfig. Paste its output as G1 evidence. Runs from admin/builder context after you've materialized the module (`ws prep mNN --user userN`, then `ws git-refresh --restart-terminals --user userN` so the cockpit clone is fresh).
14. **Verify scripts are MODE-SPLIT: entry checks never run at completion.** Checks that assert
    entry-state materialization (a seeded flaw is present, canonical fork content, "no app deployed
    yet") belong to `--entry-only` mode ONLY. Full/end mode asserts OUTCOMES and must stay green
    after a correctly completed lab — including states the lab legitimately leaves different from
    `ws solve`'s (use `>=`-style checks, not `==`; the lab may scale past the solve baseline).
    Earned twice on 2026-07-11: m09's verify hardcoded stage==2 against a lab that ends at 3, and
    m08's "seed-vulnerable carries the CVE" entry check fired red after the attendee had correctly
    REMOVED the CVE — both told successful attendees they failed and hinted at a work-destroying
    `ws reset`. A false ❌ is the fastest way to lose an attendee's trust in every other ✅.
