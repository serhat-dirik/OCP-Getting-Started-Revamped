# M22 build note — Application Modernization (MTA + AI)

Date: 2026-07-12 · Author: research-analyst · Spec: `Project-Shared/instructions/02-MODULE-SPECS.md` §M22 (lines 270-279) · Entitlement: **[OCP]** for MTA base (assess/analyze/CLI/replatform) + **[ADS]** for the AI refactoring (Red Hat Developer Lightspeed for MTA) — see Spec deltas.

Method: READ-ONLY live build cluster `ocp-ws-revamped` (OCP 4.21.22 / k8s 1.34.8) via `~/.kube/ocp-ws-revamped.config` — `oc get packagemanifest/csv/crd/ns` only, no mutations, `oc whoami`=admin, never `oc login`. MTA is **not installed**; verified the catalog offering (`mta-operator`, redhat-operators) + provided CRDs from the packagemanifest. docs.redhat.com 403s on direct WebFetch (per M18/M14 notes) → MTA console/CLI/Lightspeed facts verified via WebSearch over docs.redhat.com + developers.redhat.com + redhat.com/blog + Open VSX + launch press (Oct 2025). Repo inspection: `platform-portfolio/`, `gitops/entry-states/`, `apps/`, `CREDITS.md`, `versions.yaml`; `OldContent/repos/rh-mad-workshop` (MAD dev-guides M1/M2, `customers-tomcat-legacy`, `coolstore-monolith-legacy`) and `OldContent/repos/gitops-catalog/migration-toolkit-apps` (stale). `versions.yaml` `mta` re-confirmed live today (channel + CSV match); **not edited** per task instruction.

## Verified versions

| Product / API | Version / status | Group·Kind / channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 (k8s 1.34.8) | stable-4.21 | `oc version` (live) | 2026-07-12 |
| **MTA operator** | **v8.1.2 = MTA 8.1.2**, default channel `stable-v8.1`, catalog **redhat-operators**; **NOT installed** | package `mta-operator` | live packagemanifest; `versions.yaml` `mta` | 2026-07-12 |
| MTA channels offered | `stable-v8.1`→**v8.1.2** (newest) · `stable-v8.0`→v8.0.1 · `stable-v7.0..7.3`, `v6.0..6.2` also present; **no 8.2** | — | live packagemanifest | 2026-07-12 |
| **MTA install CR** | **Tackle** → creates ns `openshift-mta`, stands up Hub/UI/assessment/analysis | `tackle.konveyor.io/v1alpha1`·**Tackle** (`tackles.tackle.konveyor.io`) | live owned-CRDs; docs.redhat.com MTA UI install guide | 2026-07-12 |
| MTA other CRDs | Addon, Extension, Schema, Task | `tackle.konveyor.io/v1alpha1` | live packagemanifest | 2026-07-12 |
| MTA analysis engine | **analyzer-lsp** (Windup retired); **YAML** rules; targets `cloud-readiness`/`openshift`/`containerization`; assessment = questionnaire + **archetypes** (Tackle Pathfinder name retired) | — | docs.redhat.com MTA 8.1 Release Notes + CLI guide | 2026-07-12 |
| MTA CLI | **`mta-cli`** (upstream **kantra**); `analyze --target=…`, `rules list-targets`; **containerless Java mode default** when JDK/Maven present | — | docs.redhat.com MTA 8.1 CLI guide; github konveyor/kantra | 2026-07-12 |
| **Developer Lightspeed for MTA** | **released 2025-10-23**, shipped in MTA 8.0/8.1 as the AI refactor component **in the VS Code extension**; **model-agnostic** (OpenAI-compatible / Ollama / shared); LLM key set in **Tackle CR** + extension; entitlement **ADS** | component of `redhat.mta-vscode-extension` | developers.redhat.com/products/mta/developer-lightspeed; docs.redhat.com MTA 8.1 DL guide; redhat.com blog | 2026-07-12 |
| MTA VS Code extension on Open VSX | **present**: `redhat/mta-vscode-extension` (upstream `konveyor/editor-extensions`) → **Dev Spaces-installable** | — | open-vsx.org/extension/redhat/mta-vscode-extension | 2026-07-12 |
| IDE prereqs (DL for MTA) | Language Support for Java (redhat.java) + JDK + **8 GB RAM**; macOS maxproc≥2048 | — | docs.redhat.com MTA 8.1 DL "Getting started" | 2026-07-12 |
| OpenShift Lightspeed (DISTINCT) | `lightspeed-operator` v1.1.1 — **console assistant, NOT MTA** | `ols.openshift.io/v1alpha1` | `versions.yaml` `lightspeed` (lines 84-96) | 2026-07-12 |
| Community operators (AVOID) | `konveyor-operator`, `windup-operator` = **community-operators** | — | live packagemanifest | 2026-07-12 |

**Headline (spec-critical):** MTA 8.1.2 installs via the Red Hat **`mta-operator`** (`stable-v8.1`, catalog **redhat-operators**) → a single **`Tackle`** CR in **`openshift-mta`** brings up the web console (portfolio inventory, questionnaire assessment, analysis, reports). Nothing MTA is on the cluster today — **net-new** like M18's mesh. Base MTA (assess/analyze/`mta-cli`/replatform-manifest-gen) is **[OCP]**; the AI-assisted refactoring is **Red Hat Developer Lightspeed for MTA**, an **[ADS]** VS Code-extension feature (on Open VSX → Dev Spaces-capable) that wires to any OpenAI-compatible LLM — the workshop MaaS endpoint fits.

## Spec deltas

- **Entitlement split (the headline delta).** §M22 tags the module **[OCP]** (spec entitlement table, line 13) and its hands-on + flagship demo center on "fix with Developer Lightspeed for MTA," but that AI refactoring is **ADS-only** (developers.redhat.com product page; MTA 8.1 blog; `versions.yaml` owner note line 94-95: "Developer Lightspeed (RHDH/MTA) = Advanced Developer Suite"). Base MTA assess/analyze/replatform IS [OCP]. Recommend flagging the Lightspeed beats **[ADS]** with graceful degradation to a manual/MTA-hint-guided fix when ADS is absent — mirrors M08/M11 ([ADS]) and M01's "graceful degradation if not entitled." **Owner decision.**
- **Legacy app is net-new.** `parasol-legacy-claims` (Tomcat/JWS, no EAP/JMS) does not exist. `OldContent/repos/parasol-insurance` is a **modern Quarkus** app (devfile/pom/Containerfile). The MAD `customers-tomcat-legacy` (Spring-on-Tomcat, hardcoded-IP config) is the correct ancestor shape; `coolstore-monolith-legacy` is **JBoss EAP** → forbidden by D16 (Tomcat/JWS switch, backlog line 215).
- **Product-name precision.** §M22 header says "MTA + Lightspeed"; Gen3/task says "MTA + AI"; the exact product is **Red Hat Developer Lightspeed for MTA** — style guide §5 mandates disambiguating it from OpenShift Lightspeed and Developer Lightspeed for RHDH on first use. Cosmetic, but content must use the precise name.
- **Assessment naming drift.** MAD's "Tackle Pathfinder" is retired; MTA 8.1 uses questionnaire-based assessment + **archetypes** + bulk assessment. Port the concept (suitability → risks → proposed action/effort), not the name.
- **Dev Spaces beat needs real build.** Spec says "Dev Spaces workspace ready" — but the workspace image/devfile is net-new: preload `redhat.mta-vscode-extension` + `redhat.java` from Open VSX, JDK 17, **8 GB/workspace**, and the LLM wiring. Feasible (extension is on Open VSX) but not free.
- **Virtualization bridge is gone (confirmed).** Backlog line 49: no MTV/VM lift-vs-modernize; MTA modernization stands alone. Spec already reflects this — no delta to fix, just confirming.

## Approach recommendations

1. Install GitOps-native net-new `platform-portfolio/components/mta`: Subscription `mta-operator` (**pin `stable-v8.1`**, catalog redhat-operators) + shared `Tackle` CR in `openshift-mta` (imperative install = defect); community konveyor/windup operators are banned.
2. Split the module by entitlement: [OCP] core = assess → analyze (targets `cloud-readiness`/`openshift`) → read report/story-points → replatform + S2I/pipeline deploy; mark the Developer Lightspeed refactor beat + flagship demo [ADS] with a manual-fix fallback.
3. Wire the AI to MaaS via the existing M06 `maas-credentials` pattern (OpenAI-compatible provider/model into the Tackle CR + the Dev Spaces MTA extension settings) — model-agnostic, no extra model infra; temperature 0 + a pre-vetted issue for demo determinism.
4. Build `parasol-legacy-claims` by re-theming the MAD/Konveyor `customers-tomcat-legacy` (Spring-on-Tomcat, hardcoded-IP/external-config/filesystem issues) — small enough to analyze in minutes, no EAP/JMS.
5. Path discipline: MTA web console assessment/analysis/report = single-path product UI (screenshots/gif); operator install + `mta-cli analyze` + deploy = dual-path CLI|Console; Dev Spaces AI-fix = single-path IDE (M03 exception); add `gitops/entry-states/m22` (per-user MTA app + Git repo + workspace) + ws-meta.

## Mining results

- **`OldContent/repos/rh-mad-workshop/mad-dev-guides-m1`** (`2-assessment.adoc`, `3-analyze.adoc`) **+ `-m2`** (`2-refactor.adoc`, `3-deploy-to-kubernetes.adoc`) → the direct-ancestor **arc**: assess (2nd-assessment / cross-cutting-concerns → high risk → proposed action **Refactor** + effort estimate) → analyze vs **Containers/Linux/OpenJDK** targets → report (Issues, **story points** = effort, hints, source view) → refactor (hardcoded-IP → externalized config) → deploy to OpenShift. **DISCARD MTA 6 tech:** Windup, "Tackle Pathfinder" name, `.windup.xml` XML rules, "Migration perspective" UI, RHV story, "VS Code server" (→ Dev Spaces). **Add a CREDITS.md line** (none today).
- **MAD `customers-tomcat-legacy`** (in `OldContent/repos/rh-mad-workshop/modern-app-dev`; `io.konveyor.demo.ordermanagement`, Apache-2.0 Konveyor example) → porting source for `parasol-legacy-claims`: Spring-on-Tomcat, `PersistenceConfig.java` hardcoded IP in `persistence.properties` — exactly MTA-flaggable, **Tomcat not EAP**. Re-theme to Parasol claims.
- **`MAD Roadshow - Dev Track Content Overview.pdf`** (per 05-REFERENCES; feeds M22) → per-module Business/Dev-challenge/Goal/Products rubric + Globex→Parasol narrative technique + the assessment→refactor→deploy arc.
- **`OldContent/repos/gitops-catalog/migration-toolkit-apps`** → **DO NOT PORT** (MTA 6-era; README self-marked `DEPRECATED`; `*-dc.yaml` **DeploymentConfig** = banned rule 6). Sibling `migration-toolkit-containers` is **MTC** (Migration Toolkit for Containers — a *different* product for cluster/VM migration), not MTA — ignore.
- **In-repo reuse:** `platform-portfolio/components/devspaces` (Dev Spaces base for the workspace) + `gitops/entry-states/m06/templates/maas-credentials.yaml` (the MaaS-key injection pattern for the LLM wiring).

## Open risks

- **Developer Lightspeed for MTA = ADS** — the flagship "AI-assisted fix" depends on an entitlement the [OCP] tag doesn't include; resolve framing + graceful degradation before build (blocking design decision).
- **Dev Spaces runtime of the MTA extension UNVERIFIED** — Open VSX presence confirmed, but the guided-refactor/agentic webview running analysis inside **Che-Code** (not desktop VS Code) + **8 GB/workspace ×30** + Language Support for Java + JDK/Maven is a build spike. `// TODO(verify-on-cluster)`.
- **Analysis runtime ×30** (spec watchout) — Hub analysis Tasks run as pods in shared `openshift-mta`; prefer **containerless Java mode** (8.x default, no analyzer image pull) or `mta-cli` in the workspace; otherwise stagger. Exact Hub sizing (hub+keycloak+postgres+pathfinder) **UNVERIFIED** — docs say "check system requirements."
- **MTA has weak multi-tenancy** — shared Hub + per-user Application entries + per-user Git repos (no strong per-user RBAC in MTA UI). Confirm the isolation model at build.
- **LLM nondeterminism** (spec watchout) — pick an issue with a stable Lightspeed suggestion; temperature 0; pre-capture the demo diff.
- **MTA web console click-paths UNVERIFIED live** (MTA not installed) — assessment/analysis/report screenshots need `[CAPTURE-VERIFY]` against a live 8.1 console at build.
- **`versions.yaml` `mta` is accurate but THIN** — channel `stable-v8.1` + CSV `v8.1.2` match live (verified 2026-07-08, 4 days old, **not stale**), but it has no `source:` URL, no Tackle CR API, no `mta-cli`, and no Developer Lightspeed/ADS note. Recommend enrichment (left unedited per task instruction).
- **docs.redhat.com verified via WebSearch** (direct WebFetch 403s) — MTA console/CLI specifics are doc-summary-grounded, not first-party-fetched; re-confirm the exact 8.1 UI at build.

## Builder/platform appendix

**Entry-state — `gitops/entry-states/m22/`** (net-new, per-user, Helm): a `parasol-legacy-claims` Git repo seeded per user (Tomcat/Spring, deliberate hardcoded-config/filesystem/logging issues, no EAP/JMS); one MTA Application entry per user in the shared Hub (or per-user project); a Dev Spaces workspace (devfile preloading `redhat.mta-vscode-extension` + `redhat.java`, 8 GB, JDK 17) with the MTA extension + LLM settings wired to MaaS via the `maas-credentials` pattern. `ws solve` → refactored app + generated deploy manifests + OpenShift deploy. `ws reset` purges the per-user MTA app + workspace + repo. `ws-meta.yaml`: `conflictsWith` any same-ns module.

**platform-portfolio (net-new `components/mta`):** Subscription `mta-operator` (channel `stable-v8.1`, catalog redhat-operators) + OperatorGroup + a shared `Tackle` CR (`openshift-mta`) with genAI provider/model fields pointed at the MaaS endpoint (for the extension). Sequence before entry-states. Community konveyor/windup operators banned.

**Lab arc:** concept (6 Rs; how MTA rules work) → install/tour MTA web console **[OCP]** → add app + run analysis vs `cloud-readiness`+`openshift` targets (dual: console + `mta-cli analyze`) → triage report (issues, story points, hints; pick 3) → **[ADS]** open in Dev Spaces, fix with Developer Lightspeed (review diffs — teach skepticism) OR manual fix (graceful degrade) → re-analyze, story points drop → build/deploy to OpenShift (S2I → pipeline, ties M02/M07) → smoke test → wrap: portfolio strategy + strangler/RHSI pointer to M21 (concept only — RHSI is [ADD-ON], no hard dep).

**Cross-module fit:** legacy stack ties M02 (S2I/builds) + M07 (pipeline deploy); Dev Spaces from M03; MaaS wiring from M06; strangler/RHSI pointer to M21; the AI-output-skepticism rule generalizes to M23/M24. Entitlement handling mirrors M08/M11 ([ADS]) + M01 (Lightspeed graceful degradation).

**Decisions for the owner:** (1) entitlement framing — [OCP] core + [ADS] Lightspeed section with manual fallback, or re-tag M22 [ADS]? (2) MTA topology — shared Hub + per-user apps vs per-user Tackle (resource cost). (3) analysis mode — containerless Java (fast; needs JDK/Maven in workspace) vs container Task (Hub pods). (4) AI fix in Dev Spaces (Open VSX) or a provided desktop-VS-Code fallback if the Che-Code webview fails the spike.

### Relevant absolute paths
- Spec §M22: `Project-Shared/instructions/02-MODULE-SPECS.md` (lines 270-279)
- versions.yaml: `versions.yaml` — `mta` (204-211), `lightspeed` (84-96)
- Primary mines: `OldContent/repos/rh-mad-workshop/mad-dev-guides-m1/documentation/modules/ROOT/pages/{2-assessment,3-analyze}.adoc` · `.../mad-dev-guides-m2/documentation/modules/ROOT/pages/{2-refactor,3-deploy-to-kubernetes}.adoc` · legacy app `.../rh-mad-workshop/modern-app-dev` (`customers-tomcat-legacy`)
- Do-NOT-port: `OldContent/repos/gitops-catalog/migration-toolkit-apps`
- In-repo reuse: `platform-portfolio/components/devspaces` · `gitops/entry-states/m06/templates/maas-credentials.yaml`
- Format templates: `docs/research/m18-build-note.md`, `docs/research/m14-build-note.md`

Sources:
- MTA 8.1 Release Notes — https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.1/html/release_notes/index
- MTA 8.1 CLI guide (`mta-cli`/kantra, targets, containerless) — https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.1/html-single/using_the_migration_toolkit_for_applications_command-line_interface/index
- Configuring and Using Red Hat Developer Lightspeed for MTA (8.1; LLM config, getting started, IDE prereqs) — https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.1/html/configuring_and_using_red_hat_developer_lightspeed_for_mta/configuring-llm_mta-developer-lightspeed
- Configuring and Using the VS Code Extension for MTA (8.0) — https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.0/html-single/configuring_and_using_the_visual_studio_code_extension_for_mta/index
- MTA UI install (Tackle CR, `openshift-mta`) — https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/7.3/html/user_interface_guide/mta-7-installing-web-console-on-openshift_user-interface-guide
- Developer Lightspeed for MTA product page (ADS entitlement, model-agnostic) — https://developers.redhat.com/products/mta/developer-lightspeed
- Red Hat blog "Migration toolkit for applications 8: bringing modernized applications to market faster" (replatforming, DL = ADS) — https://www.redhat.com/en/blog/migration-toolkit-applications-8-bringing-modernized-applications-market-faster
- Launch coverage 2025-10-23 — https://www.businesswire.com/news/home/20251023240341/en/ · https://siliconangle.com/2025/10/23/red-hat-aims-new-developer-lightspeed-ai-features-application-migration/
- Open VSX MTA extension (Dev Spaces installability) — https://open-vsx.org/extension/redhat/mta-vscode-extension
- Upstream — https://github.com/konveyor/kai · https://github.com/konveyor/kantra · https://github.com/konveyor/editor-extensions
- Live cluster `ocp-ws-revamped` — `oc get packagemanifest mta-operator` (redhat-operators, `stable-v8.1`→`v8.1.2`, `Tackle` CRD) + `oc version` (4.21.22), read-only, 2026-07-12

Note on `versions.yaml`: the `mta` entry is current (matches live, 4 days old) so it was not edited; per task instruction flagged as accurate-but-thin rather than changed.
