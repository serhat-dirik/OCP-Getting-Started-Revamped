# OldContent Mining Index

> Build note — research-analyst **R3** · verified **2026-07-08** · sources: `OldContent/` PDFs + `OldContent/repos/` clones (GitHub, all reachable this date).
> Purpose: tell module-builders / platform-engineer exactly which source to open, what to lift, and what to leave. Rewrite tech, port narrative. `OldContent/` is an INPUT — never committed into this repo.
> Every row cites a real path or repo. "TAKE" = port the idea/shape and re-verify tech at build. "DISCARD/FLAG" = do not port (stale or banned per 04-STYLE-GUIDE §5).

Absolute clone root: `/Users/.../OCP-GettingStarted-Revamped/OldContent/repos/` (shown below as `repos/<name>`).

---

## 1. Reference-clone status (verify job)

Background `clone-oldcontent.sh` completed cleanly. **19 direct repos + 2 org dirs = all present, all non-empty. Zero clone failures. Zero 404s.** Then R3 added 4 fresh finds (job 2). Last-commit dates flag which repos are narrative-only antiques.

| repo (`repos/…`) | git files | last commit | license | role |
|---|---|---|---|---|
| starter-guides | 275 | 2023-07-24 | Apache-2.0 | M01/M02 lineage — **narrative only (2023)** |
| nationalparks | 43 | 2023-04-28 | Apache-2.0 | sample-app deploy shape — **narrative only (2023)** |
| openshift-gitops-workshop | 97 | 2026-03-06 | Apache-2.0 | M08 (current) |
| advanced-gitops-workshop | 100 | 2025-11-25 | Apache-2.0 | M08/M09 (current) |
| argo-rollouts-workshop | 132 | 2025-11-28 | Apache-2.0 | M09 (current) |
| tech-exercise | 871 | 2026-06-15 | MIT | patterns only — **mind anti-goal** |
| enablement-framework | 57 | 2026-05-27 | none | patterns only |
| ubiquitous-journey | 48 | 2024-01-25 | Apache-2.0 | app-of-apps pattern — **mind anti-goal** |
| showroom (rh-cloud-arch-workshop) | 391 | 2026-03-09 | none | M18 + Cloud-Native-Arch story; also a live showroom sample |
| service-mesh-workshop-code | 162 | 2022-07-18 | Apache-2.0 | M16 **narrative only — SM2, all tech banned** |
| service-mesh-workshop-dashboard | 76 | 2022-05-02 | none | M16 **narrative only — SM2** |
| agentops-in-prod-showroom | 161 | 2026-05-09 | none | M22 AI showroom (current) |
| showroom_template_default | 28 | 2025-11-11 | none | **Antora scaffold base — see §5** |
| ossm-gateway-demo (serhat-dirik) | 57 | 2026-06-04 | Apache-2.0 | M16 adv ingress / M13 decision tree (D18) |
| kc-token-exchangeV2-demo (serhat-dirik) | 56 | 2026-06-01 | Apache-2.0 | M29 token exchange (D18) |
| devspaces-android-sample-app (serhat-dirik) | 85 | 2026-07-06 | none | M03 Dev Spaces + devfile (D18) |
| gitops-catalog (redhat-cop) | 1763 | 2026-06-22 | Apache-2.0 | platform-portfolio operator bases (D14) |
| rh-mad-workshop/ (org) | 25 subrepos | mixed 2024-26 | mixed | M02/M04/M06/M10/M21 MAD track |
| app-connectivity-workshop/ (org) | 9 subrepos | mixed | mixed | M13/M16/M20 connectivity |
| **parasol-insurance** (added, redhat-ads-tech) | — | 2026-07-02 | **none** | **apps/ primary mine — see §3** |
| **parasol-insurance-manifests** (added) | — | 2026-07-02 | **none** | GitOps deploy shapes — see §3 |
| **adv-app-platform-demo-showroom** (added, rhpds) | — | 2026-07-08 | none | **demo-mode gold standard — see §4** |
| **showroom-rhtap** (added, rhpds) | — | 2025-07-14 | none | M07 supply-chain showroom variant |

Notable stale-but-kept (narrative mines, tech deliberately ignored): starter-guides, nationalparks, service-mesh-workshop-code/-dashboard, ubiquitous-journey.

---

## 2. Source → module map (05-REFERENCES §1 enriched with what is actually in the clones)

### 2a. PDFs / decks (in `OldContent/*.pdf|*.pptx`)
| Source | Feeds | TAKE | DISCARD / FLAG |
|---|---|---|---|
| `Getting Started with OpenShift for Developers - Lab Intro.pdf` | M01, M02, intro deck | monolith→microservices→K8s ramp, self-healing storyboards, logistics-slide pattern, polyglot-choice idea | ALL 2020-era tech steps, DeploymentConfig, "master", NodePort expose, Parksmap app |
| `MAD Roadshow - Dev Track Content Overview.pdf` + `Modern App Development Roadshow - Overview.pptx` | M02, M04, M06, M10, M21 | per-module rubric (Business/Dev-challenge/Goal/Products), Globex→Parasol technique, assess→refactor→deploy arc (M21), per-user namespaces | RHV story, 3scale/RH-SSO/Service Binding, VS Code Server (→Dev Spaces), old MTA UI |
| `Provisioning Guide and Support.pdf` + `Cloud Native Architectures Workshop - Provisioning Guide.pdf` | instructor runbook, bootstrap design | day-before rule, +10% seats, N+2 buffer, Let's Encrypt note, admin-panel idea, layered support, lifecycle warnings | beta-era RHDP flows, email credential distribution, inconsistent auto-stop numbers |
| `Cloud Native Architectures Workshop - Intro/Content Overview.pdf` + `One Stop_*.pdf` | M18, story design, One-Stop page, field-ops | business-challenge-first template, module-independence + pick-your-adventure, persona-takeaway slide, hashtag tagging, One-Stop pattern, TTT/videos ecosystem | App Services BU branding, 3scale/RH-SSO/Camel K/AMQ, Salesforce IDs |
| `OpenShift GitOps Workshop.pdf` | M08 | push-vs-pull contrast, Application-CR anatomy walkthrough, hub/cluster/app-scoped topology framing, 20-min-theory/long-lab split | kam CLI, DevNation logistics, Homeroom |
| `Argo Rollouts Lab Instructions.pdf` | M09, instructor guide | facilitator run-book shape, pre-flight "all Argo apps Synced" gate | its empty "TBD" troubleshooting (our anti-pattern) |
| `OpenShift Service Mesh 2.x - Workshop Presentation.pdf` | M16 | cascading-failure narrative, pop-quiz energy resets, one-concept-slide-per-CRD-before-lab, "map to your systems" close | ALL SM2 tech (SMCP/SMMR, bundled Jaeger/Grafana), 1.x→2.x migration slides |
| `App Connectivity Workshop.pdf` + `App Connectivity Workshop_ One Stop.pdf` | M13, M16, M20, diagrams | accreting arch diagram, traffic-direction product map (cross-env/east-west/north-south), Travel-Agency→Parasol RHSI port, complete-delivery-kit pattern | Summit-2025 catalog specifics |

### 2b. Repos (enriched with observed layout)
| Source repo | Feeds | TAKE (with path hints) | DISCARD / FLAG |
|---|---|---|---|
| `repos/starter-guides` | M01, M02 | ordered lab-progression shape; "describe the cluster" onboarding beat | 2023 OCP UI, Parksmap, `oc new-app` DC output |
| `repos/nationalparks` | M02, M04, M05 | build→deploy→data-tier→map story; health-probe demo beat | pinned old images, webhook UI screenshots |
| `repos/openshift-gitops-workshop` | M08 | Application-CR anatomy labs, sync/self-heal exercises (current) | any `kam`; Homeroom launcher |
| `repos/advanced-gitops-workshop` | M08, M09 | app-of-apps, ApplicationSets, sync-waves, RBAC-per-team labs | — (re-verify GitOps operator channel) |
| `repos/argo-rollouts-workshop` | M09 | canary + blue-green + analysis-template lab shapes | empty troubleshooting sections |
| `repos/tech-exercise` (rht-labs, 871 files) | M06, M07, M08 patterns | pipeline+GitOps+DevSpaces lab scaffolding *ideas* | **anti-goal: do NOT adopt the TL500 framework wholesale / its opinionated stack** |
| `repos/enablement-framework`, `repos/ubiquitous-journey` | patterns | app-of-apps values conventions to contrast with our platform-portfolio | anti-goal; UJ last touched 2024 |
| `repos/showroom` (Cloud-Native-Arch, 391 files) | M18, story, One-Stop | business-first module writing; also a *second live showroom example* to compare nav/attribute style | BU branding, dated product mixes |
| `repos/service-mesh-workshop-code` + `-dashboard` | M16 | cascading-failure demo *story*, dashboard UX idea | **ALL tech (2022 SM2, SMCP/SMMR) — banned** |
| `repos/agentops-in-prod-showroom` | M22 | AI-in-prod showroom narrative, guardrails/agent framing; overlap-check vs our M22 | re-verify every AI version at M22 build (highest churn) |
| `repos/ossm-gateway-demo` (Serhat) | M16, M13 | Gateway-API advanced ingress, demo-client pattern, decision tree — **credit Serhat** | — |
| `repos/kc-token-exchangeV2-demo` (Serhat) | M29 | token-exchange v2 flow — **credit Serhat** | — |
| `repos/devspaces-android-sample-app` (Serhat) | M03 | devfile patterns, Dev Spaces showcase — **credit Serhat** | — |
| `repos/gitops-catalog` (redhat-cop, 1763 files) | platform-portfolio (D14) | operator kustomize bases (primary mine) — namespace/subscription/operatorgroup shapes per operator | verify each channel at build; some bases lag |
| `repos/rh-mad-workshop/coolstore-*` | M02, M04, M06, M10, M21 | Coolstore→Parasol microservice split, `coolstore-gitops`, `coolstore-software-templates` (RHDH template shape), `coolstore-microservice-helm` | 3scale/RH-SSO, `mad-dev-guides-mig-eap` old MTA UI |
| `repos/rh-mad-workshop/mad-dev-guides-m1..m7` | M02, M04, M06, M10 | per-module dev-guide structure = MAD rubric in practice | dated screenshots, old operator channels |
| `repos/app-connectivity-workshop/{showroom,travels-demo-ui,acw-helm,agnosticd}` | M13, M16, M20 | Travels-demo→Parasol RHSI/Connectivity-Link narrative; `acw-helm` deploy shape; `workshop-devspaces` devfile | Summit-2025 catalog specifics; verify RHSI→"Service Interconnect" naming |
| `repos/showroom-rhtap` (rhpds) | M07 | RHTAP/Trusted-supply-chain showroom flow (SBOM, EC, attestation) | RHTAP now **Red Hat Advanced Developer Suite** — re-verify all product names/UI (04-STYLE-GUIDE §5) |

---

## 3. Parasol Insurance — findings + recommendation

**Current canonical home is the `redhat-ads-tech` GitHub org** ("ADS" = Red Hat **Advanced Developer Suite**), the team behind the Advanced App Platform demo. Older workshop copies live under `rh-java4ai-workshop` and community forks.

### Candidate repos (searched rhpds / rh-rad / redhat-gpte* / RedHatQuickCourses / rh-aiservices-bu + global)
| repo | contains | stack | last commit | license |
|---|---|---|---|---|
| **`redhat-ads-tech/parasol-insurance`** ⭐ | Claims + email-triage app (`ClaimsResource`, `InboxResource`, `EmailRouter`, `EmailGenerator`, models `Claim`/`Email`) + static web UI | **Quarkus 3.17.5** (REST, Panache, Postgres, **Kafka** reactive messaging, scheduler, health); frontend = static HTML/CSS/JS in `src/main/resources/META-INF/resources/`; AI via OpenAI-compatible endpoint (LiteLLM), profiles for Ollama/Jlama | 2026-07-02 | **none** |
| `redhat-ads-tech/parasol-insurance-manifests` | Deploy shapes: `app/` Helm (deployment, service, route, **hpa**, **es-kafka**, **es-litellm**, **authorizationpolicy + waypoint + waypoint-podmonitor** = OSSM3 ambient/Gateway-API) + `build/` full **Tekton** supply chain (maven-build, sonar-scan, update-manifest, triggers, external secrets for GitLab/Quay/Sonar) | Helm + Tekton | 2026-07-02 | none |
| `redhat-ads-tech/parasol-insurance-secured-manifests` | Secured/zero-trust variant of the above | Helm | 2026-07-02 | none |
| `redhat-ads-tech/parasol-chat` | Chatbot companion app | Python | 2026-04-14 | none |
| `redhat-ads-tech/devfiles` | Devfile registry for the demo | — | 2026-05-19 | none |
| `rh-java4ai-workshop/parasol-insurance` | Older Java-for-AI workshop frontend | TypeScript/React (20★) | 2025-11-04 | none |
| `nodeshift/parasol-insurance-nodejs` | Node.js port of the app | TypeScript (2★) | 2026-06-22 | none |
| `rh-aiservices-bu/parasol-*` (`parasol-ai-studio`, `parasol-demo-deployment`, `parasol-code-server`) | RHOAI-flavoured Parasol demo (AI studio, deployment recipe) | TypeScript / Jupyter / Shell | 2025-10 | none |
| `ansible-tmm/parasol-website` | Static marketing website for "Parasol" | HTML | 2025-12-18 | none |

### Recommendation
**Mine `redhat-ads-tech/parasol-insurance` as the primary source for `apps/parasol-claims` (Quarkus backend) and seed `apps/parasol-web` from its `META-INF/resources/` pages.** Rationale: it is (1) the newest and canonically maintained (2026-07-02), (2) already **Quarkus-primary** matching our stack decision, (3) domain-perfect — the Claim + Email-triage model is the exact Parasol narrative, and (4) paired with real GitOps manifests using **current, non-banned tech** (OSSM3 ambient waypoints + Gateway API, HPA, Kafka via Streams-for-Kafka, LiteLLM) that platform-portfolio can study directly. Pull `parasol-insurance-manifests` for M08/M09/M16 deploy shapes and the Tekton supply chain (M06/M07). Use `rh-java4ai-workshop/parasol-insurance` or `nodeshift/parasol-insurance-nodejs` only if we later want a richer React SPA for `parasol-web` (the ads-tech repo's UI is server-served static HTML, not a React build).

Domain assets worth lifting verbatim (ideas, then rewrite): claim photos + seed `import.sql`, the dashboard/claims/claim-detail/inbox page set, the email→Kafka("intake" topic)→router→claim flow.

**License caveat (see §6):** every `redhat-ads-tech` repo shows **license = none**. Treat as internal Red Hat material: mine domain/narrative/shape and re-implement; do not copy source verbatim into our repo without an explicit license grant.

---

## 4. `adv-app-platform-demo-showroom` — demo-mode gold standard (rhpds, pushed 2026-07-08)

This is the same Parasol claims/email-triage story rendered as a facilitated demo — the closest existing thing to our demo flavor. **Its 7-module arc maps almost 1:1 onto our backlog** and is the best structural reference for the `ifdef::demo` Say/Show/Do flow.

Pages: `content/modules/ROOT/pages/{index,01-overview,02-details,03-module-01-developer-experience … 09-module-07-ai-applications}.adoc` (numeric filename prefixes drive order; nav uses `.Section N:` group titles).

| adv-app-platform module | Our module(s) | Port |
|---|---|---|
| M1 Developer experience (app modernization, DevSpaces, Quarkus dev-mode) | M02/M03/M04 | DevSpaces onboarding + Quarkus live-code beat |
| M2 CI/CD pipeline (Tekton, Sonar code-smells, Argo CD delivery) | M06/M07/M08 | pipeline-catches-a-bug narrative + GitOps handoff |
| M3 Platform operations (traffic mgmt+security, Kiali, autoscaling, external secrets/Vault) | M11/M15/M16 | OSSM3 traffic story, Kiali observ., HPA scale demo |
| M4 Developer Hub + Software Catalog (RHDH + Developer Lightspeed, self-service) | RHDH module | catalog + self-service golden-path template |
| M5 Secure development (Dependency Analytics, secure build/MR) | M07 | shift-left dependency-scan beat |
| M6 Trusted software supply chain (SBOM w/ Trusted Profile Analyzer, topology) | M07 | SBOM/attestation supply-chain close |
| M7 AI-enhanced applications (email triage, LLM routing) | M22 | LLM email-routing demo (mirrors `EmailRouter`) |

Also take: the `.Section N` nav grouping, per-module `#part-N` + `#summary` anchor convention, and `examples/workshop/99-conclusion.adoc` as a wrap-up pattern. Image set under `assets/images/` (devspaces-*, argocd-*, ossm-*, ocp-hpa-*, ocp-pipeline-*) documents exactly which console screens each beat shows.

---

## 5. Antora scaffold spec — `showroom_template_default` anatomy (+ current `nookbag` delta)

> **This is the section the PM builds our 3-site-config Antora scaffold from.** Verified by reading the cloned repo `repos/showroom_template_default` (commit eecfe92, 2025-11-11) and cross-checking the live `adv-app-platform-demo-showroom` and the newer `rhpds/showroom_template_nookbag` (pushed 2026-07-03). RHDP "Showroom" renders these; staying wire-compatible is what lets our guide drop into an RHDP catalog item unchanged.

### 5.1 Directory layout (what to replicate under our `content/`)
```
<repo root>
├── default-site.yml        # Antora playbook — dev/local defaults
├── site.yml                # (real demos add this) deploy-time playbook; RHDP picks one
├── ui-config.yml           # RHDP Showroom workbench tabs (NOT Antora)
├── content/
│   ├── antora.yml          # component descriptor (name: modules, version, nav, default attributes)
│   ├── modules/ROOT/
│   │   ├── nav.adoc        # left-nav (xref list)
│   │   ├── pages/          # *.adoc lab pages (index.adoc = start_page)
│   │   ├── assets/images/  # image:: sources
│   │   ├── partials/       # reusable include:: snippets
│   │   └── examples/       # downloadable files
│   ├── supplemental-ui/    # css/img/partials overlaid on the UI bundle (favicon, head-meta.hbs, header-content.hbs)
│   └── lib/                # Antora JS extensions (dev-mode.js etc.) — supplemental_files
├── utilities/{lab-serve,lab-build,lab-clean,lab-stop}   # local podman preview
└── podman-compose.yaml
```
Single Antora component, `name: modules`, module `ROOT`. `start_page: modules::index.adoc`. `output.dir: ./www`. Content source is the repo itself: `content.sources: [{ url: ., start_path: content }]`.

### 5.2 Attribute injection — the "zero-touch" pattern (critical for our env values)
- **Defaults** live in `content/antora.yml → asciidoc.attributes` (e.g. `lab_name`, `guid`, `ssh_user`, `ssh_password`, `page-pagination: true`, `page-links`).
- **At RHDP deploy time** the Showroom operator supplies real environment values by overriding `asciidoc.attributes` in the deploy playbook (`site.yml`) — the checked-in `default-site.yml` holds only local/dev values. `adv-app-platform` ships `default-site.yml` and `site.yml` with identical bodies precisely so either can be the injection point.
- Pages consume with inline `{attr}` syntax (e.g. ``The terminal is logged in as `{ssh_user}`.``). Sample-output blocks that must interpolate use `subs="attributes"` (or `subs="+attributes"`).
- `ui-config.yml` does env substitution too: `url: 'https://console-openshift-console.${DOMAIN}'` — `${DOMAIN}` is filled from the provisioned environment.
- **Implication for us:** ALL environment-specific values (`{user}`, `{cluster_domain}`, console URLs, MaaS endpoints) must be attributes, never hardcoded — exactly matching CLAUDE.md rule 4. Our workshop/demo/instructor playbooks differ ONLY by `asciidoc.attributes` (and start_page/nav), not by content structure.

### 5.3 Authoring conventions our renderer MUST preserve
- **`[source,sh,role=execute]`** — `role=execute` makes a code block click-to-run in the Showroom terminal tab. This is the single most important convention; every runnable lab command uses it.
- `[source,texinfo,subs="attributes"]` / `subs="attributes"` — sample output with attribute interpolation.
- `page-pagination: true` — bottom prev/next nav on every page.
- `nav.adoc`: `* xref:page.adoc[Title]` with nested `** xref:page.adoc#anchor[Sub]`; `.Section Title` lines create nav group headers (seen in adv-app-platform).
- Images: `image::name.png[alt,width,height]` resolved from `assets/images/`.
- `experimental: true` attribute (adv-app-platform) enables kbd:/btn:/menu: macros.

### 5.4 UI bundle (theme) — pin this
`ui.bundle.url` points at the **RHDP Showroom theme** `github.com/rhpds/rhdp_showroom_theme`, `snapshot: true`. Observed release tags, newest UX first:
- `…/releases/download/patternfly-6/ui-bundle.zip` — used by the **live adv-app-platform demo**; PatternFly 6 = current OCP-console look. **Recommend we pin this.**
- `…/releases/download/latest/ui-bundle.zip` — used by `nookbag` (moving target).
- `…/releases/download/v0.0.1/ui-bundle.zip` — old default template (avoid).
Supplemental overlay files live in `content/supplemental-ui/` (`css/site-extra.css`, `img/favicon.ico`, `partials/head-meta.hbs`, `partials/header-content.hbs`) — how we brand without forking the bundle.

### 5.5 `nookbag` = the newer template (delta the PM should weigh)
`showroom_template_default/README.adoc` line 1 explicitly says: **"Use https://github.com/rhpds/showroom_template_nookbag instead."** `nookbag` (pushed 2026-07-03) is leaner and adds capability:
- Playbook is **`site.yml` only** (no `default-site.yml`, no `utilities/`, no `podman-compose.yaml`).
- Adds Antora extensions we likely want: **`@sntke/antora-mermaid-extension`** (Mermaid diagrams inline) and **`@andrew-jones/antora-tabs-extension`** (tabbed content — natural fit for workshop/demo variants on one page).
- Richer `ui-config.yml`: `default_width: 30`, `persist_url_state: true`, a **`view_switcher`** (`split` vs `doc` mode), and commented templates for OCP-Console tab, wetty terminal (`path: /wetty, port: 443`), split terminals.
- `default` template's **`dev-mode.js`** extension (auto-generates an "Attributes Page" listing every attribute available while authoring) is worth copying into our scaffold as a dev aid regardless of base.

### 5.6 Local preview tooling to port into `tools/` / `utilities/`
- `utilities/lab-serve` → `podman run -d --rm --name showroom-httpd -p 8080:8080 -v ./www:/var/www/html/:z registry.access.redhat.com/ubi9/httpd-24:1-301`.
- `utilities/lab-build` builds `./www`; `lab-clean`/`lab-stop` manage the container.
- Recommended live-edit container (README): `ghcr.io/juliaaano/antora-viewer`.
- CLAUDE.md already references `./utilities/lab-serve` (Showroom convention) — keep that name.

### 5.7 Compatibility checklist for our 3 site configs
1. Each of `site-workshop.yml` / `site-demo.yml` / `site-instructor.yml` is an Antora playbook resolving the **same single `modules` component** (`content.sources: [{url: ., start_path: content}]`), differing only in `asciidoc.attributes`, `start_page`, and possibly `nav`.
2. Set the demo flavor via an attribute (e.g. `demo: true`) so `ifdef::demo[]` Say/Show/Do blocks render — this is exactly how Showroom already toggles content; no custom machinery needed.
3. `start_page: modules::index.adoc`, `output.dir: ./www`, pin UI bundle to `patternfly-6`.
4. Use `version: ~` (versionless component, as adv-app-platform does) to keep clean URLs, OR a fixed version string across all three — but be consistent, or xref/nav breaks.
5. Keep env values as attributes only (5.2); never hardcode cluster/user specifics.
6. Adopt nookbag's mermaid + tabs extensions if our modules use diagrams/variant-tabs.

---

## 6. Risks / flags
- **License = none on all `redhat-ads-tech` and most `rhpds` repos** (parasol-insurance, manifests, adv-app-platform-demo-showroom, showroom-rhtap, agentops). Mine ideas/domain/shape and re-implement; do **not** copy source verbatim without a license grant. Raise with Serhat if we intend to lift code (Decision-Record question).
- **RHTAP renamed → Red Hat Advanced Developer Suite (RHADS).** `showroom-rhtap` and older Parasol demos use the old name; re-verify every product name/UI path against 04-STYLE-GUIDE §5 before porting (M07).
- **AI stack churn (highest):** parasol-insurance AI path (LiteLLM/Ollama/Jlama), agentops showroom, and Red Hat AI versions must be re-verified at M22 build time per 05-REFERENCES §4 — do not trust anything here beyond ~60 days.
- **`nookbag` vs `default` template divergence:** RHDP is mid-migration (default README defers to nookbag; live demo still uses the older two-playbook shape). PM should choose ONE base now; recommend the nookbag structure + patternfly-6 bundle to avoid a rebuild later.
- **UI bundle `snapshot: true` + moving tags** (`latest`) can shift rendering between builds. Pin `patternfly-6` (or a dated release) and record it in `versions.yaml`.
- **Serhat's D18 repos** (ossm-gateway-demo, kc-token-exchangeV2-demo, devspaces-android-sample-app) are reuse-with-credit — ensure `CREDITS.md` entries when ported.
- **Anti-goal repos** (tech-exercise / ubiquitous-journey / enablement-framework): mine *patterns only*; do not import the TL500 framework or its opinionated stack.
- `versions.yaml` NOT modified by R3 — nothing here is a product-GA version to record (Quarkus 3.17.5 and the showroom theme tag are build-tool/theme versions; PM to decide whether the pinned UI-bundle tag belongs in `versions.yaml`).

*Sources are live GitHub repos + `OldContent/` files as cited; all reachable 2026-07-08.*
