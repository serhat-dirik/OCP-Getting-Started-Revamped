# OpenShift Application Platform — Getting Started

A modern, modular **OpenShift enablement workshop**: 25 self-contained modules that take developers, DevOps engineers, and architects from "I have credentials to a cluster" to "I can develop, deliver, and operate applications on OpenShift — and I know why the platform works this way."

## Workshop Content

You join **Parasol Insurance** as an engineer on its claims platform, and the workshop is your first weeks on the job: you deploy the claims service for the first time, wire it to configuration and storage, put pipelines and security gates in front of every change, hand operations to GitOps, learn to observe and scale it, and finish by keeping it running through the loss of a whole site and packaging it for other teams to install. Every module advances the same story on the same application — nothing is a toy example.

The 25 modules are grouped into four blocks:
**A · Foundations, B · Delivery & Trust, C · Platform & Tenancy, D · Advanced Electives**.


| Block | # | Module | What you do | Prep | Time |
|---|---|---|---|---|---|
| A | M01 | Platform Orientation & First App | Deploy the claims portal from a container image, scale it to three replicas, and kill a pod to watch OpenShift replace it automatically. Publish it with a Route and ask OpenShift Lightspeed a question. | ~2-3 min | 30 min |
| A | M02 | Ways to Build & Deliver Apps | Build the claims service from Git with Source-to-Image, then rebuild it with a Dockerfile to see why you'd choose one over the other. Deploy a polyglot Node.js service and a database from the catalog, then wire the claims service to it. | ~3-4 min | 35 min |
| A | M03 | Dev Spaces & the Inner Loop | Open the claims service in a browser-based Dev Spaces workspace already wired to a database, and watch Quarkus hot-reload your changes in seconds. Add a cache to the devfile, debug a live request, and push your change to Git. | ~3-5 min | 50 min |
| A | M04 | Config, Secrets & Multi-Environment | Break the claims service with a bad setting, then fix it properly by moving configuration into a ConfigMap and credentials into a Secret. Add health probes, set resource requests and limits against a quota, and promote the same image to stage and prod. | ~3-5 min | 40 min |
| A | M05 | Storage & Stateful Apps | Watch the claims database lose its data because it runs on ephemeral storage, then add a PersistentVolumeClaim so it survives a restart. Run a StatefulSet, stage a partitioned update, and migrate a schema with an init container. | ~3-5 min | 40 min |
| A | M06 | Jobs, Batch & Queued Workloads | Run a monthly-statement Job, break it and fix it, then shard the work across pods with an Indexed Job and schedule it with a CronJob. Put the batch work under quota and priority with Kueue, then run an AI batch-inference job through the same queue. | ~3-5 min | 30 min |
| A | M07 | Observability, Health & Scale | Read the claims service's golden signals and a custom metric, then write an alert that fires for real when you break the database under load. Follow a slow request with a trace, autoscale under load with an HPA, and drain a node without dropping traffic thanks to a PodDisruptionBudget. | ~3-5 min | 40 min |
| A | M08 | Application Logging | Make your app's logs answer questions: structured JSON, a level you change without a rebuild, credentials that never reach a log line, and one request followed across three replicas. | ~4-5 min | 55 min |
| B | M09 | Pipelines Fundamentals & Task Libraries | Turn your manual build-and-deploy commands into a Tekton pipeline built from reusable Tasks, then explore the company task library behind it. Break the pipeline with a failing test, fix it, and wire Pipelines-as-Code so a Git push builds and deploys on its own. | ~3-5 min | 40 min |
| B | M10 | Application Security Testing (SAST · SCA · DAST) | Run a seeded, vulnerable build through five security gates — SAST, SCA, image scanning, configuration checks, and DAST — fixing a real flaw at each one until the pipeline goes green. Finish by reading where every finding actually lives across the SonarQube, RHACS, and pipeline consoles. | ~4-6 min | 100 min |
| B | M11 | Trusted Software Supply Chain | Watch the pipeline refuse an unsigned, vulnerable image while a clean one sails through, then verify its signature yourself with cosign. Inspect its SBOM and build provenance, try keyless signing against the transparency log, and prove the cluster refuses to run anything unsigned. | ~8-12 min | 40 min |
| B | M12 | GitOps Fundamentals | Change the cluster by hand and watch it not stick, then create your first Argo CD Application and let it sync from Git instead. Cause drift on purpose, watch Argo CD self-heal it, then promote a git-driven change to stage. | ~2-4 min | 40 min |
| B | M13 | GitOps at Scale & Progressive Delivery | Replace a pile of hand-authored Argo CD Applications with one ApplicationSet that generates them from a template, then order a database migration with sync waves and hooks. Ship a change to production as a canary, and watch an automated analysis roll it back on its own when it fails. | ~5-8 min | 40 min |
| B | M14 | Developer Hub & Golden Paths | Tour Parasol's software catalog in Red Hat Developer Hub to see who owns what, then scaffold a brand-new microservice from a golden-path template in one form. Watch the paved road build, sign, and deploy it into your namespace with the platform's standards already applied. | ~2-4 min | 30 min |
| B | M15 | Securing Apps with Keycloak | Put a Keycloak login in front of the claims API and web frontend, watching HTTP status flip between 401 and 403 as you fix authentication and then authorization. Give a batch job its own machine identity, then watch Keycloak refuse a token-exchange escalation you attempt on purpose. | ~4-6 min | 40 min |
| C | M16 | Multi-Tenancy & Workload Security | Stand up a safe sandbox for a new team: bind them to groups with the right roles, author a least-privilege custom Role, and set a quota and limits. Watch OpenShift refuse a workload that tries to run as root, then give it a proper non-root identity instead. | ~2-3 min | 40 min |
| C | M17 | Networking for Dev & DevOps | Trace a packet through the claims app's three tiers, expose the front end to the world, then lock the namespace down with a default-deny network policy. Re-open only the traffic the app actually needs, and give another namespace native isolation with a UserDefinedNetwork. | ~4-6 min | 40 min |
| C | M18 | Deployment Targets & Scheduling | Watch where pods land and why, then direct the claims API with anti-affinity and spread it evenly across nodes with topology spread constraints. Reserve a dedicated node pool for the batch worker, and make a rolling update finish without dropping a single request. | ~3-5 min | 40 min |
| C | M19 | Registry, Images & Catalog Governance | Tour the internal registry and your ImageStream, then promote an image across environments by tag and prove it resolves to the exact same digest. Re-import a base image on a schedule, pull from a private registry with a pull secret, and publish your own catalog entry. | ~3-4 min | 30 min |
| C | M20 | Platform Guardrails (Policy-as-Code & External Secrets) | Get the claims database password out of Git and into a vault the app reads through External Secrets, then rotate it and watch the Secret follow in fifteen seconds. Read the admission policy that governs your own actions on this cluster, predict which rule a bad manifest trips, and watch it refused. | ~2-3 min | 50 min |
| D | M21 | Service Mesh 3 & Advanced Gateways | Enroll the claims chain into the service mesh and prove mutual TLS by watching a plaintext client get refused, then watch live traffic in the Kiali graph. Shift traffic between service versions, inject faults and a circuit breaker, and lock down who may call whom with an AuthorizationPolicy. | ~4-6 min | 40 min |
| D | M22 | Serverless Zero-to-Hero | Wake a Knative Service that's scaled to zero and feel the real cold start, then watch it autoscale on concurrency and melt back to zero when traffic stops. Split traffic between two revisions by tag, and wire a first taste of eventing that wakes the service on an event. | ~3-5 min | 40 min |
| D | M23 | Eventing Deep-Dive & Serverless Workflows | Route a real CloudEvent through a broker to wake a consumer from zero, then filter delivery by attribute across several independent triggers. Break a consumer on purpose and watch Knative retry it and then dead-letter the event, reading exactly why it failed. | ~4-6 min | 40 min |
| D | M24 | Resilience, Multi-Cluster & DR | Prove a service survives a pod loss with replicas, a PodDisruptionBudget, and an HPA, then scale an entire site to zero and watch the service mesh fail traffic over to a second site with zero dropped requests. As an add-on, connect two sites into one network with Red Hat Service Interconnect. | ~4-6 min | 30 min |
| D | M25 | Packaging & Distributing Your App (Helm & OLM) | Package the notifications service as a Helm chart, install it, upgrade it, break it on purpose, and roll back to the version that worked. Push the chart to the registry as an OCI artifact, then take apart a real operator's bundle to see what happens when someone clicks Install. | ~4-6 min | 40 min |

**Modules are flexible.** Every module is self-contained: automation materializes its starting environment per attendee, so no module assumes another one ran first. Attendees can start with any module or jump straight to the topic their team needs today.

**Pick your modules.** Choose the modules that fit your audience and time; the **Time** column is each module's hands-on time (the whole catalog is about 17 hours). Put the list in `modules_enabled` in `bootstrap/vars.yaml` (see [INSTALL.md](INSTALL.md)).

## Project Content

| Directory | What it is |
|---|---|
| `content/` | Antora/Showroom content — one source for the workshop guide (`site-workshop.yml`) and the instructor guide (`site-instructor.yml`) |
| `apps/` | Parasol Insurance sample services (Quarkus-primary, deliberate polyglot moments) |
| `platform-portfolio/` | **Standalone GitOps installer** — operators/tools as composable Argo CD stacks, replicable on any OpenShift 4.20+ cluster. Workshop-agnostic; also usable alone for SA PoC/demo clusters. See its [README](platform-portfolio/README.md) |
| `gitops/` | Workshop layer on top of the portfolio: users/RBAC/quotas, Gitea seeding, per-module **entry states**, promotion structures |
| `pipelines/` | Parasol company task library + per-module pipeline definitions |
| `tools/` | `ws` attendee CLI (list/prep/verify/reset) + `adm` operator CLI (start/solve/status/...), plus per-module verify scripts |
| `bootstrap/` | Cluster installer: portfolio stacks + workshop layer in one command |
| `helm/bootstrap/` | The same install as a Helm chart — how the Red Hat Demo Platform deploys the workshop from its catalog, instead of you running `bootstrap/install.sh` |
| `showroom/` | Site config that builds the attendee cockpit |
| `utilities/` | `lab-serve` — preview the content locally with live reload, no cluster needed |

## Quick Installation on OpenShift

Sizing, every option and troubleshooting: **[INSTALL.md](INSTALL.md)**.

**Prerequisites**

* OpenShift **4.20+**, `cluster-admin`, a default StorageClass, `linux/amd64` workers.
  Red Hat SAs: order [**Field Sourced Content - OpenShift Base**](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.ocp-field-asset.prod)
  with **3 workers or more** ([how many](INSTALL.md#sizing)).
* On your machine: `oc`, `git`, `yq`, `htpasswd`, `openssl`.
* Optional, for OpenShift Lightspeed and M06's AI batch-inference step: an OpenAI-compatible model endpoint and key.

**1. Clone**

```bash
git clone https://github.com/serhat-dirik/OCP-Getting-Started-Revamped.git
cd OCP-Getting-Started-Revamped
```

**2. Preflight** — read-only. It shows what the install would adopt versus create. The workshop
needs a dedicated, fresh cluster ([INSTALL.md §6](INSTALL.md#6-dedicated-cluster)).

```bash
tools/ws/adm preflight
```

**3. Configure** — set at least `users` and the `maas` endpoint, model and key
([all keys](INSTALL.md#2-install)):

```bash
cp bootstrap/vars.example.yaml bootstrap/vars.yaml
```

**4. Install** — about 15–20 minutes, safe to re-run:

```bash
./bootstrap/install.sh
```

Then verify with `tools/ws/adm doctor` and `tools/ws/adm status`.

## Starting the Workshop

The commands below run from your own machine and manage the whole room — they use `adm`, the
operator surface of the workshop CLI. Attendees only ever see `ws`, its four-verb surface
(`list`/`prep`/`verify`/`reset`), inside the cockpit — steps 3 and 4 below are theirs.

**1. If you have pushed content since installing, re-clone the cockpit.**

```bash
tools/ws/adm git-refresh --restart-terminals --all
```

A cockpit clones the workshop when its pod starts and never again, so a cluster that has not been
restarted since an update serves the old copy. The symptom is `ws prep` being refused —
[INSTALL.md](INSTALL.md#ws-prep-is-refused-own-appproject-only). Skip this if nothing has changed since the install.

**Attendee logins need no morning refresh.** One cockpit serves the whole cohort behind an OpenShift
login, and its terminal mints each attendee's kubeconfig from that sign-in — there is no pod-start
token to go stale, so **installing the day before a workshop is fine**. If an attendee's first
command returns:

```
error: You must be logged in to the server (Unauthorized)
```

their *browser* sign-in has lapsed, not the cluster: they reload the cockpit page and reopen the
terminal. Nothing else looks wrong when that happens — the pod is Running and the page loads — so it
is worth recognising on sight rather than diagnosing. See [INSTALL.md](INSTALL.md#attendee-gets-unauthorized).

> `adm session-refresh` belongs to the retired per-user cockpit, where each pod held one long-lived
> token. Against the shared cockpit it reports `nothing to refresh` and changes nothing. It is still
> the right command if you deliberately set `showroom.shared.enabled: false`.

**2. Share one URL with the whole room.** Every attendee uses the same cockpit — the guide, a terminal,
and tool tabs in a single browser page:

```
https://ogsr-showroom.<cluster-domain>
```

It sits behind an OpenShift login. Attendees sign in as their own `userN` with the shared password the
installer prints at the end, and the terminal comes up already logged in as that user — `oc whoami`
returns their own identity, so the whole cohort is not sharing one account.

The easiest way to hand it out is the cohort board, which carries the same URL plus a numbered list
people claim so two attendees never take the same slot:

```
https://ogsr-pad.<cluster-domain>/p/workshop
```


> Earlier releases gave each attendee a personal `showroom-<user>` URL with no authentication in front
> of it. Those are retired: enabling the shared cockpit (`showroom.shared.enabled`, the default) stops
> rendering them, because leaving an unauthenticated shell reachable alongside a login page means the
> login page is decorative. Set it to `false` only if you deliberately want the old per-user model.

**3. Tell them to pick a module and prepare it.** The cockpit lists all modules; any module can be first.
Inside the cockpit terminal:

```bash
ws prep <module>        # build this module's starting environment
```

Warn them this is a real wait — roughly 2 to 6 minutes for most modules, longer for M09 and M11 —
and that the concept page is there to read while it runs. The per-module estimates are the **Prep**
column in the [module table](#workshop-content) above. An attendee who is not told this will assume
the terminal has hung and start over, which only makes it slower.

**4. They do the lab**, following the guide in the left pane, and check their own work:

```bash
ws verify <module>      # did I do it right?
ws reset  <module>      # start this module over
```

That is the whole attendee loop — prep, do, verify. Nothing else is required of them.

### Managing the session

From your admin machine, `adm` — the operator surface of the same CLI — runs against the whole
cohort. It lives in the repo at `tools/ws/adm` (attendees get `ws`, the four-verb attendee
surface, on their `PATH` inside the cockpit; you call `adm` by path):

```bash
tools/ws/adm status                     # fleet health at a glance
tools/ws/adm start m01 --user user3     # prepare a module for someone who is stuck
tools/ws/adm git-refresh                # publish content updates to a live session
```

## Ending a Delivery

Install once; what you run next depends on what you're doing — see **[INSTALL.md §4](INSTALL.md#4-after-a-delivery)** for
the full picture. In order of how often you'll actually reach for them:

**a) One attendee, one module** — reset a single exercise so someone can redo it; nothing else changes:

```bash
tools/ws/ws reset <module> --user userN
```

**b) Between cohorts, same cluster** — the normal end-of-delivery step. Deletes all attendee lab
content and returns the cluster to its immediately-post-install state. The platform, every attendee
account, Gitea (with its repos), Keycloak (with its logins) and every cockpit stay exactly as installed:

```bash
./bootstrap/ogsr-reset.sh --dry-run    # print the plan; change nothing
./bootstrap/ogsr-reset.sh              # do it
```

This is the one to run. (`adm cohort-reset` is the engine it calls internally — you do not need to run
it yourself.)

**c) Wipe users** — removes `user2`…`userN` entirely (namespaces, Keycloak identities, Gitea repos)
and leaves **`user1`** behind as a working sample, login included, so the cluster still demonstrates the
workshop with only one attendee on it:

```bash
./bootstrap/ogsr-wipe-users.sh --dry-run   # print the plan; change nothing
./bootstrap/ogsr-wipe-users.sh             # do it
./bootstrap/ogsr-wipe-users.sh --keep 2    # keep user1 and user2 (default 1)
```

One deliberate side effect: the Developer Hub catalog is **not pruned**, so components scaffolded by
removed users stay listed after their namespaces are gone. Expected, not a bug.

**d) Remove the workshop entirely** — reach for this only when the *cluster* has to go back to its
owner. The workshop needs a dedicated cluster and does not restore every cluster-wide setting it changed
([INSTALL.md §6](INSTALL.md#6-dedicated-cluster)), so prefer disposing of the cluster. Adopted operators are preserved:

```bash
./bootstrap/ogsr-uninstall.sh --dry-run   # prints the full removal plan; changes nothing
./bootstrap/ogsr-uninstall.sh             # removes the workshop entirely
./bootstrap/ogsr-check-clean.sh           # read-only report; the admin decides what else to remove
```

**Logging is never removed.** `cluster-logging` and `loki-operator` are preserved by name, whatever
the install state records — a log store is something the rest of a cluster grows to depend on, and the
cluster admin is the only person who can judge that. The uninstall says `PRESERVING` and moves on.

Two further things the teardown deliberately leaves behind, and says so on every run: declared residue, and
**cluster-scoped CRDs the organisation still depends on** — one another operator also owns, or that
still has their instances in it. Deleting such a CRD would delete every instance of it in every
namespace, so it is named with its evidence and a read-only `oc get <crd> -A`, never a delete command.
The checker exits **0** with those still registered, saying `no UNEXPECTED leftover` rather than
`clean` — see [INSTALL.md](INSTALL.md#remove-the-workshop).

## Local Content Preview

To read or edit the content without a cluster, build any of the three renderings locally:

```bash
cd content && npx antora site-workshop.yml    # also: site-instructor.yml
# or, with live reload:
./utilities/lab-serve
```

## Credits

This workshop reuses and modernizes patterns from earlier Red Hat enablement assets and community workshops. Its own direct ancestor is Red Hat's long-running **OpenShift Getting Started** workshop (the `openshift/starter-guides` content) — the workshop this project is a *revamp* of, and the one that set the original mission: get a room of engineers hands-on and productive on OpenShift, from zero. Everything this project draws on, including that workshop's specific contribution, is credited in the table below.

| Source | Used in | What was adopted |
|---|---|---|
| `app-connectivity-workshop` (redhat-ads-tech) | Resilience, Multi-Cluster & DR (Red Hat Service Interconnect `[ADD-ON]` section) | The Virtual Application Network narrative and the Skupper v2 `Site` / `Connector` / `Listener` / `AccessGrant`→`AccessToken` resource shapes — re-homed to Parasol's claims service across two simulated sites. Ideas + CR shapes only; re-verified live on a current cluster. |
| Red Hat `openshift/starter-guides` | Ways to Build & Deliver Apps | The Source-to-Image narrative arc (source → builder image → running app) and the S2I-versus-Dockerfile framing. Narrative only — every step is freshly built and re-verified on a live cluster; the Parasol apps, the PostgreSQL catalog template, and the build flows are original. |
| `rcarrata/devsecops-demo` (Apache-2.0) | Pipelines Fundamentals, Application Security Testing & Trusted Software Supply Chain — DevSecOps pipeline | The staged security-gate-at-every-stage arc, the block-the-bad-image + fix-image remediation beat, and the `roxctl deployment check` and ZAP DAST stages — re-implemented on our modern stack (in-cluster Gitea, internal registry, Quarkus Parasol claims, and current tool versions: SonarQube Community Build / Trivy / ZAP / RHACS). No code ported. |
