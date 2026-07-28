# OpenShift Application Platform — Getting Started

A modern, modular **OpenShift enablement workshop**: 26 self-contained modules that take developers, DevOps engineers, and architects from "I have credentials to a cluster" to "I can develop, deliver, and operate applications on OpenShift — and I know why the platform works this way."

The same content base doubles as a **presenter-led demo kit** for Red Hat Solution Architects: every module renders as an attendee workshop guide, an SA demo guide (talk track + click path), and an instructor runbook — from one AsciiDoc source.

## Workshop Content

You join **Parasol Insurance** as an engineer on its claims platform, and the workshop is your first weeks on the job: you deploy the claims service for the first time, wire it to configuration and storage, put pipelines and security gates in front of every change, hand operations to GitOps, learn to observe and scale it, and finish with an AI-assisted platform that helps you modernize legacy code and build agents on top of the same services. Every module advances the same story on the same application — nothing is a toy example.

The 26 modules are grouped into four blocks: **A · Foundations, B · Delivery & Trust, C · Platform & Tenancy, D · Advanced Electives**.

| Block | # | Module | What you do | Time |
|---|---|---|---|---|
| A | M01 | Platform Orientation & First App | Deploy the claims portal from a container image, scale it to three replicas, and kill a pod to watch OpenShift replace it automatically. Publish it with a Route and ask OpenShift Lightspeed a question. | 30 min |
| A | M02 | Ways to Build & Deliver Apps | Build the claims service from Git with Source-to-Image, then rebuild it with a Dockerfile to see why you'd choose one over the other. Deploy a polyglot Node.js service and a database from the catalog, then wire the claims service to it. | 30 min |
| A | M03 | Dev Spaces & the Inner Loop | Open the claims service in a browser-based Dev Spaces workspace already wired to a database, and watch Quarkus hot-reload your changes in seconds. Add a cache to the devfile, debug a live request, and push your change to Git. | 50 min |
| A | M04 | Config, Secrets & Multi-Environment | Break the claims service with a bad setting, then fix it properly by moving configuration into a ConfigMap and credentials into a Secret. Add health probes, set resource requests and limits against a quota, and promote the same image to stage and prod. | 40 min |
| A | M05 | Storage & Stateful Apps | Watch the claims database lose its data because it runs on ephemeral storage, then add a PersistentVolumeClaim so it survives a restart. Run a StatefulSet, stage a partitioned update, and migrate a schema with an init container. | 40 min |
| A | M06 | Jobs, Batch & Queued Workloads | Run a monthly-statement Job, break it and fix it, then shard the work across pods with an Indexed Job and schedule it with a CronJob. Put the batch work under quota and priority with Kueue, then run an AI batch-inference job through the same queue. | 30 min |
| B | M07 | Pipelines Fundamentals & Task Libraries | Turn your manual build-and-deploy commands into a Tekton pipeline built from reusable Tasks, then explore the company task library behind it. Break the pipeline with a failing test, fix it, and wire Pipelines-as-Code so a Git push builds and deploys on its own. | 40 min |
| B | M08 | Application Security Testing (SAST · SCA · DAST) | Run a seeded, vulnerable build through five security gates — SAST, SCA, image scanning, configuration checks, and DAST — fixing a real flaw at each one until the pipeline goes green. Finish by reading where every finding actually lives across the SonarQube, RHACS, and pipeline consoles. | 60 min |
| B | M09 | Trusted Software Supply Chain | Watch the pipeline refuse an unsigned, vulnerable image while a clean one sails through, then verify its signature yourself with cosign. Inspect its SBOM and build provenance, try keyless signing against the transparency log, and prove the cluster refuses to run anything unsigned. | 40 min |
| B | M10 | GitOps Fundamentals | Change the cluster by hand and watch it not stick, then create your first Argo CD Application and let it sync from Git instead. Cause drift on purpose, watch Argo CD self-heal it, then promote a git-driven change to stage. | 40 min |
| B | M11 | GitOps at Scale & Progressive Delivery | Replace a pile of hand-authored Argo CD Applications with one ApplicationSet that generates them from a template, then order a database migration with sync waves and hooks. Ship a change to production as a canary, and watch an automated analysis roll it back on its own when it fails. | 40 min |
| B | M12 | Developer Hub & Golden Paths | Tour Parasol's software catalog in Red Hat Developer Hub to see who owns what, then scaffold a brand-new microservice from a golden-path template in one form. Watch the paved road build, sign, and deploy it into your namespace with the platform's standards already applied. | 30 min |
| B | M13 | Observability, Health & Scale | Read the claims service's golden signals and a custom metric, then write an alert that fires for real when you break the database under load. Follow a slow request with a trace, autoscale under load with an HPA, and drain a node without dropping traffic thanks to a PodDisruptionBudget. | 40 min |
| C | M14 | Securing Apps with Keycloak | Put a Keycloak login in front of the claims API and web frontend, watching HTTP status flip between 401 and 403 as you fix authentication and then authorization. Give a batch job its own machine identity, then watch Keycloak refuse a token-exchange escalation you attempt on purpose. | 40 min |
| C | M15 | Multi-Tenancy & Workload Security | Stand up a safe sandbox for a new team: bind them to groups with the right roles, author a least-privilege custom Role, and set a quota and limits. Watch OpenShift refuse a workload that tries to run as root, then give it a proper non-root identity instead. | 40 min |
| C | M16 | Networking for Dev & DevOps | Trace a packet through the claims app's three tiers, expose the front end to the world, then lock the namespace down with a default-deny network policy. Re-open only the traffic the app actually needs, and give another namespace native isolation with a UserDefinedNetwork. | 40 min |
| C | M17 | Deployment Targets & Scheduling | Watch where pods land and why, then direct the claims API with anti-affinity and spread it evenly across nodes with topology spread constraints. Reserve a dedicated node pool for the batch worker, and make a rolling update finish without dropping a single request. | 40 min |
| D | M18 | Registry, Images & Catalog Governance | Tour the internal registry and your ImageStream, then promote an image across environments by tag and prove it resolves to the exact same digest. Re-import a base image on a schedule, pull from a private registry with a pull secret, and publish your own catalog entry. | 30 min |
| D | M19 | Service Mesh 3 & Advanced Gateways | Enroll the claims chain into the service mesh and prove mutual TLS by watching a plaintext client get refused, then watch live traffic in the Kiali graph. Shift traffic between service versions, inject faults and a circuit breaker, and lock down who may call whom with an AuthorizationPolicy. | 40 min |
| D | M20 | Serverless Zero-to-Hero | Wake a Knative Service that's scaled to zero and feel the real cold start, then watch it autoscale on concurrency and melt back to zero when traffic stops. Split traffic between two revisions by tag, and wire a first taste of eventing that wakes the service on an event. | 40 min |
| D | M21 | Eventing Deep-Dive & Serverless Workflows | Route a real CloudEvent through a broker to wake a consumer from zero, then filter delivery by attribute across several independent triggers. Break a consumer on purpose and watch Knative retry it and then dead-letter the event, reading exactly why it failed. | 40 min |
| D | M22 | Resilience, Multi-Cluster & DR | Prove a service survives a pod loss with replicas, a PodDisruptionBudget, and an HPA, then scale an entire site to zero and watch the service mesh fail traffic over to a second site with zero dropped requests. As an add-on, connect two sites into one network with Red Hat Service Interconnect. | 30 min |
| D | M23 | Application Modernization (MTA + Developer Lightspeed) | Run the Migration Toolkit for Applications over a legacy Java WAR to see exactly what blocks containerizing it, then fix a flagged issue with Developer Lightspeed for MTA and watch the effort score drop on re-analysis. Containerize and deploy the modernized service, then break and fix its startup probe. | 40 min |
| D | M24 | Agentic AI on OpenShift | Ask a running AI agent questions about live claims and policies, and watch grounding depend on how you phrase the question. Inspect the MCP tools it calls, ground an answer in policy documents with RAG, and read its token, latency, and tool-call metrics. | 50 min |
| D | M25 | AI-Assisted Development on OpenShift (Vibe Coding, Safely) | Connect an AI coding assistant to the cluster through an MCP server and have it diagnose a broken deployment read-only, then grant it a scoped write so it can fix the problem itself. Watch RBAC flatly refuse the same agent when it reaches for a namespace it was never granted. | 30 min |
| D | M26 | Packaging & Distributing Your App (Helm & OLM) | Package the notifications service as a Helm chart, install it, upgrade it, break it on purpose, and roll back to the version that worked. Push the chart to the registry as an OCI artifact, then take apart a real operator's bundle to see what happens when someone clicks Install. | 40 min |

**Modules are flexible.** Every module is self-contained: automation materializes its starting environment per attendee, so no module assumes another one ran first. Attendees can start with any module, follow one of the recommended paths, or jump straight to the topic their team needs today.

**Plan a delivery.** The whole catalog is about **17 hours**, so the designated full workshop is **3 days covering all 26 modules** — not a selection from them. Shorter formats drop modules rather than rush them:

| Delivery | Modules | Total |
|---|---|---|
| Half-day taster | M01 → M02 → M07 → M10 → M24 | ~3 h |
| Full-day essentials | M01 → M02 → M03 → M04 → M07 → M10 → M12 → M13 → M24 | ~6 h |
| 2-day core | everything except M15, M17, M18, M21, M22, M23, M25, M26 | ~12 h |
| **3-day full workshop** | **all 26** — Day 1 M01–M08 · Day 2 M09–M17 · Day 3 M18–M26 | ~17 h |

Each shorter path is a complete arc rather than a truncated one. The half day is deploy → build → automate the build → automate the delivery → and finish on the AI beat, so a taster still ends somewhere memorable. The full day adds the inner loop, configuration, the developer portal and observability — enough that someone leaves able to work on the platform, not just describe it.

**About the times.** They are per-module planning figures for a mixed room, not stopwatch numbers. A confident attendee finishes a module in roughly half the stated time; someone new to OpenShift may need about a third longer. Plan the agenda on the stated figure and the room stays together. Because every module materializes its own starting state, any subset above — or one you assemble yourself — is a valid agenda; see **Modules are flexible**, above.

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

The steps below get a cluster running. For sizing the cluster before you order it, verifying the
install, and the failure modes we have actually hit — including one that can quietly stop an operator
the cluster's owner cares about from upgrading — see **[INSTALL.md](INSTALL.md)**.

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

**c) Confirm the cluster is clean** — run this *after* the uninstall to check for anything left behind or damaged:

```bash
./bootstrap/ogsr-check-clean.sh
```

This is **read-only**: it never deletes, patches, or labels anything. It scans the cluster for whether every adopted operator (and its OperatorGroup) is still healthy, ClusterServiceVersions that no Subscription installs (an orphan left behind when a Subscription went and its CSV did not — worth acting on, because OLM resolves the *next* install against the leftover and fails), workshop namespaces — and any other namespace — stuck `Terminating`, APIServices whose backing Service is gone, admission webhooks pointing at a Service that no longer exists, objects still carrying a workshop label, and CRDs from operators the install created, each reported with a live instance count (deleting a CRD deletes every instance of it, cluster-wide). For every finding it prints the exact `oc` command that would remove it, and it exits non-zero while anything remains. It does not remove anything itself: that decision belongs to the cluster admin, not the script, because the workshop has no way to know whether a given object is now load-bearing for something else on the cluster.

## Local Content Preview

To read or edit the content without a cluster, build any of the three renderings locally:

```bash
cd content && npx antora site-workshop.yml    # also: site-demo.yml, site-instructor.yml
# or, with live reload:
./utilities/lab-serve
```

Before pushing a block with `subs="attributes"`, run `tools/lint/curl-format-guard.py` — it catches `curl -w` format fields like `%{http_code}` being eaten as AsciiDoc attribute references (content-build runs antora at `--log-failure-level=warn`, so that warning fails the build).

## Credits

This workshop reuses and modernizes patterns from earlier Red Hat enablement assets and community workshops. Its own direct ancestor is Red Hat's long-running **OpenShift Getting Started** workshop (the `openshift/starter-guides` content) — the workshop this project is a *revamp* of, and the one that set the original mission: get a room of engineers hands-on and productive on OpenShift, from zero. Everything this project draws on, including that workshop's specific contribution, is credited in the table below.

| Source | Used in | What was adopted |
|---|---|---|
| Konveyor `customers-tomcat-legacy` (Apache-2.0; via the Red Hat Modern Application Development workshop `rh-mad-workshop`) | Application Modernization | The `parasol-legacy-claims` migration target: Spring-on-Tomcat WAR structure, the hardcoded-configuration anti-patterns, and the assess → analyze → refactor → deploy arc — re-themed to the Parasol claims domain (insurance domain original). |
| `parasol-insurance` (redhat-ads-tech) | Agentic AI on OpenShift apps (`parasol-agent`, `mcp-servers/claims-db`, `mcp-servers/policy-docs`) | The Parasol Insurance AI claims-triage **domain narrative** (an assistant answering claim questions). Ideas only — re-implemented from scratch in Quarkus LangChain4j + MCP (their AI calls went OpenAI-direct; ours use LangChain4j AI services and MCP tool servers). |
| `agentops-in-prod-showroom` (rhpds) | Agentic AI on OpenShift apps (`parasol-agent`); AI-Assisted Development on OpenShift | The "**tools are your APIs**" + tool-call-tracing + "**review the agent critically**" framing (the agent reports which tools it called; you read the trace and verify its claims). Framing only — none of its Python/LangGraph/MLflow tech was ported; M24 re-points it at the platform MCP server. |
| `app-connectivity-workshop` (redhat-ads-tech) | Resilience, Multi-Cluster & DR (Red Hat Service Interconnect `[ADD-ON]` section) | The Virtual Application Network narrative and the Skupper v2 `Site` / `Connector` / `Listener` / `AccessGrant`→`AccessToken` resource shapes — re-homed to Parasol's claims service across two simulated sites. Ideas + CR shapes only; re-verified live on a current cluster. |
| Red Hat `openshift/starter-guides` | Ways to Build & Deliver Apps | The Source-to-Image narrative arc (source → builder image → running app) and the S2I-versus-Dockerfile framing. Narrative only — every step is freshly built and re-verified on a live cluster; the Parasol apps, the PostgreSQL catalog template, and the build flows are original. |
| `rcarrata/devsecops-demo` (Apache-2.0) | Pipelines Fundamentals, Application Security Testing & Trusted Software Supply Chain — DevSecOps pipeline | The staged security-gate-at-every-stage arc, the block-the-bad-image + fix-image remediation beat, and the `roxctl deployment check` and ZAP DAST stages — re-implemented on our modern stack (in-cluster Gitea, internal registry, Quarkus Parasol claims, and current tool versions: SonarQube Community Build / Trivy / ZAP / RHACS). No code ported. |
