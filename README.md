# OpenShift Application Platform — Getting Started

A modern, modular **OpenShift enablement workshop**: 26 self-contained modules that take developers, DevOps engineers, and architects from "I have credentials to a cluster" to "I can develop, deliver, and operate applications on OpenShift — and I know why the platform works this way."

The same content base doubles as a **presenter-led demo kit** for Red Hat Solution Architects: every module renders as an attendee workshop guide, an SA demo guide (talk track + click path), and an instructor runbook — from one AsciiDoc source.

## Workshop Content

You join **Parasol Insurance** as an engineer on its claims platform, and the workshop is your first weeks on the job: you deploy the claims service for the first time, wire it to configuration and storage, put pipelines and security gates in front of every change, hand operations to GitOps, learn to observe and scale it, and finish with an AI-assisted platform that helps you modernize legacy code and build agents on top of the same services. Every module advances the same story on the same application — nothing is a toy example.

The 26 modules are grouped into four blocks:

**A — Foundations (M01–M06)**

| # | Module |
|---|---|
| M01 | Platform Orientation & First App |
| M02 | Ways to Build & Deliver Apps |
| M03 | Dev Spaces & the Inner Loop |
| M04 | Config, Secrets & Multi-Environment |
| M05 | Storage & Stateful Apps |
| M06 | Jobs, Batch & Queued Workloads |

**B — Delivery & Trust (M07–M13)**

| # | Module |
|---|---|
| M07 | Pipelines Fundamentals & Task Libraries |
| M08 | Application Security Testing (SAST · SCA · DAST) |
| M09 | Trusted Software Supply Chain |
| M10 | GitOps Fundamentals |
| M11 | GitOps at Scale & Progressive Delivery |
| M12 | Developer Hub & Golden Paths |
| M13 | Observability, Health & Scale |

**C — Platform & Tenancy (M14–M17)**

| # | Module |
|---|---|
| M14 | Securing Apps with Keycloak |
| M15 | Multi-Tenancy & Workload Security |
| M16 | Networking for Dev & DevOps |
| M17 | Deployment Targets & Scheduling |

**D — Advanced Electives (M18–M26)**

| # | Module |
|---|---|
| M18 | Registry, Images & Catalog Governance |
| M19 | Service Mesh 3 & Advanced Gateways |
| M20 | Serverless Zero-to-Hero |
| M21 | Eventing Deep-Dive & Serverless Workflows |
| M22 | Resilience, Multi-Cluster & DR |
| M23 | Application Modernization (MTA + Developer Lightspeed) |
| M24 | Agentic AI on OpenShift |
| M25 | AI-Assisted Development on OpenShift (Vibe Coding, Safely) |
| M26 | Packaging & Distributing Your App (Helm & OLM) |

**Modules are flexible.** Every module is self-contained: automation materializes its starting environment per attendee, so no module assumes another one ran first. Attendees can start with any module, follow one of the recommended paths, or jump straight to the topic their team needs today.

**SA demo guides ship as a second showroom.** Alongside the per-attendee workshop cockpits, the install deploys an **SA-Demos showroom** — a presenter cockpit that renders every module's scripted demo (Say / Show / Do talk track with timings) plus one-click launchers into the Console, Gitea, Argo CD, Dev Spaces, Developer Hub, and SonarQube. A Solution Architect can run a customer demo end-to-end from that one browser tab, reusing all the workshop's preparation without the lab framing.

## Project Content

| Directory | What it is |
|---|---|
| `content/` | Antora/Showroom content — one source, three renderings (`site-workshop.yml`, `site-demo.yml`, `site-instructor.yml`) |
| `apps/` | Parasol Insurance sample services (Quarkus-primary, deliberate polyglot moments) |
| `platform-portfolio/` | **Standalone GitOps installer** — operators/tools as composable Argo CD stacks, replicable on any OpenShift 4.20+ cluster. Workshop-agnostic; also usable alone for SA PoC/demo clusters. See its [README](platform-portfolio/README.md) |
| `gitops/` | Workshop layer on top of the portfolio: users/RBAC/quotas, Gitea seeding, per-module **entry states**, promotion structures |
| `pipelines/` | Parasol company task library + per-module pipeline definitions |
| `tools/` | `ws` CLI (`ws start\|verify\|reset\|solve <module>`) + per-module verify scripts |
| `bootstrap/` | Cluster installer: portfolio stacks + workshop layer in one command |

## Quick Installation on OpenShift

**Prerequisites**

* An OpenShift **4.20+** cluster with a default StorageClass (any footprint: self-managed, ROSA/ARO, or an RHDP sandbox). ODF/NooBaa is needed only if you enable M22 (its backup target is an in-cluster S3 bucket).
* `cluster-admin` access, with the `oc` CLI logged in to that cluster.
* `git` on the machine you install from.
* The installer is **non-invasive on existing clusters**: operators already present are adopted (never overwritten or upgraded), attendees live in their own identity provider, and nothing about the cluster's default behavior is changed.

**1. Clone this repository**

```bash
git clone https://github.com/serhat-dirik/OCP-Getting-Started-Revamped.git
cd OCP-Getting-Started-Revamped
```

**2. Configure the install** — all inputs live in one gitignored vars file; the installer takes no flags:

```bash
cp bootstrap/vars.example.yaml bootstrap/vars.yaml
# edit bootstrap/vars.yaml
```

The variables that matter:

* `users` — how many attendees to provision (`user1`…`userN`).
* `cluster_domain` — leave `""` to auto-detect from the cluster.
* `maas` — the LLM endpoint behind the workshop's AI beats (Lightspeed answers, batch inference, agent modules). Any **OpenAI-compatible chat-completions endpoint** works: Red Hat Models-as-a-Service, an on-cluster vLLM/OpenShift AI serving runtime, or a **public provider** — OpenAI directly, Google Gemini via its OpenAI-compatible endpoint, or Anthropic Claude behind an OpenAI-compatible gateway (for example LiteLLM). Set `endpoint`, `model`, and `api_key`; the key is a secret and never leaves `vars.yaml`.
* `lightspeed` — installs OpenShift Lightspeed wired to the model above. If no LLM endpoint is configured, the installer **skips this automatically**; on a cluster that already runs Lightspeed, the existing install is adopted, not touched.
* `modules_disabled` — the module filter, e.g. `modules_disabled: [m13, m22]`. A filtered module is **hidden from the workshop showroom** and its components and platform stacks are **not installed** (unless another enabled module needs them). Leave the list empty to install the full catalog.

**3. Install** — stands up the platform stacks and the workshop layer in one command:

```bash
./bootstrap/install.sh
```

**4. Hand out the links.** Each attendee gets a personal cockpit (guide + terminal + tool tabs) at `https://showroom-user1.<cluster-domain>` … `showroom-userN`, sharing one memorable password printed at the end of the install. The SA demo cockpit is at `https://showroom-demos.<cluster-domain>`.

## Operating the Workshop

Attendees drive everything from inside their cockpit: `ws prep <module>` sets the module up, `ws verify <module>` checks their work, `ws reset <module>` returns to a clean start. From your admin machine the same CLI manages the fleet:

```bash
tools/ws/ws start m01 --user user3     # materialize a module for one attendee
tools/ws/ws status                     # fleet health at a glance
tools/ws/ws git-refresh                # publish content updates to a live session
```

## Reset & Uninstall

**a) Reset the workshop** — wipe all attendee work so a *new group of users* can start fresh; the platform and content stay installed:

```bash
tools/ws/ws cohort-reset
```

**b) Delete the workshop** — remove it from the cluster entirely. Always preview first; the uninstall is non-invasive by design (adopted operators and anything the cluster had before the install are preserved):

```bash
./bootstrap/ogsr-uninstall.sh --dry-run   # prints the full removal plan; changes nothing
./bootstrap/ogsr-uninstall.sh             # removes the workshop
```

## Local Content Preview

To read or edit the content without a cluster, build any of the three renderings locally:

```bash
cd content && npx antora site-workshop.yml    # also: site-demo.yml, site-instructor.yml
# or, with live reload:
./utilities/lab-serve
```

## Credits

This workshop reuses and modernizes patterns from earlier Red Hat enablement assets and community workshops.

| Source | Used in | What was adopted |
|---|---|---|
| Konveyor `customers-tomcat-legacy` (Apache-2.0; via the Red Hat Modern Application Development workshop `rh-mad-workshop`) | Application Modernization | The `parasol-legacy-claims` migration target: Spring-on-Tomcat WAR structure, the hardcoded-configuration anti-patterns, and the assess → analyze → refactor → deploy arc — re-themed to the Parasol claims domain (insurance domain original). |
| `parasol-insurance` (redhat-ads-tech) | Agentic AI on OpenShift apps (`parasol-agent`, `mcp-servers/claims-db`, `mcp-servers/policy-docs`) | The Parasol Insurance AI claims-triage **domain narrative** (an assistant answering claim questions). Ideas only — re-implemented from scratch in Quarkus LangChain4j + MCP (their AI calls went OpenAI-direct; ours use LangChain4j AI services and MCP tool servers). |
| `agentops-in-prod-showroom` (rhpds) | Agentic AI on OpenShift apps (`parasol-agent`); AI-Assisted Development on OpenShift | The "**tools are your APIs**" + tool-call-tracing + "**review the agent critically**" framing (the agent reports which tools it called; you read the trace and verify its claims). Framing only — none of its Python/LangGraph/MLflow tech was ported; M24 re-points it at the platform MCP server. |
| `app-connectivity-workshop` (redhat-ads-tech) | Resilience, Multi-Cluster & DR (Red Hat Service Interconnect `[ADD-ON]` section) | The Virtual Application Network narrative and the Skupper v2 `Site` / `Connector` / `Listener` / `AccessGrant`→`AccessToken` resource shapes — re-homed to Parasol's claims service across two simulated sites. Ideas + CR shapes only; re-verified live on a current cluster. |
| Red Hat `openshift/starter-guides` | Ways to Build & Deliver Apps | The Source-to-Image narrative arc (source → builder image → running app) and the S2I-versus-Dockerfile framing. Narrative only — every step is freshly built and re-verified on a live cluster; the Parasol apps, the PostgreSQL catalog template, and the build flows are original. |
| `rcarrata/devsecops-demo` (Apache-2.0) | Pipelines Fundamentals, Application Security Testing & Trusted Software Supply Chain — DevSecOps pipeline | The staged security-gate-at-every-stage arc, the block-the-bad-image + fix-image remediation beat, and the `roxctl deployment check` and ZAP DAST stages — re-implemented on our modern stack (in-cluster Gitea, internal registry, Quarkus Parasol claims, and current tool versions: SonarQube Community Build / Trivy / ZAP / RHACS). No code ported. |
