# M19 build note — Serverless Zero-to-Hero

Date: 2026-07-12 · Author: research-analyst · Spec: 02-MODULE-SPECS §M19 (lines 238-247) · Entitlement: **[OCP]** (OpenShift Serverless is included with an OpenShift subscription)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22, k8s 1.34.8, `~/.kube/ocp-ws-revamped.config`, READ-ONLY — no mutations, user5 untouched): `oc version`, `oc get csv -A / crd / ns / packagemanifest serverless-operator`. Repo inspection (`platform-portfolio/`, `gitops/entry-states/`, `apps/parasol-claims`, `apps/parasol-service-template`, `content/`). docs.redhat.com is 403 to WebFetch today → product facts verified via WebSearch surfacing of docs.redhat.com Serverless 1.37/1.35/1.34 chapters + release notes, and API field names verified directly against knative.dev (upstream, version-stable). `versions.yaml` `serverless` block re-verified live and refreshed (2026-07-12); generated partial unchanged (`version:` still 1.37.1). Cross-checked M06/M07/M10/M17 build notes + in-repo serverless prose for no-overlap.

## Verified versions

| Product / API | Version / status | Group·Kind (name / ns) | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 (k8s 1.34.8) | stable-4.21 | `oc version` (live) | 2026-07-12 |
| **OpenShift Serverless operator** | **1.37.1 GA** | channel `stable` (default) — per-minor pin `stable-1.37` -> `serverless-operator.v1.37.1` | live `oc get packagemanifest serverless-operator` + docs.redhat.com Serverless 1.37 | 2026-07-12 |
| Knative Serving / Eventing / Kourier / `kn` CLI | **1.17** (shipped by operator 1.37) | — | docs.redhat.com Serverless 1.37 release notes (via WebSearch) | 2026-07-12 |
| **KnativeServing** CR | `operator.knative.dev/v1beta1` | KnativeServing (name+ns `knative-serving`) | redhat-cop gitops-catalog instance + docs.redhat.com 1.35 install | 2026-07-12 |
| **KnativeEventing** CR | `operator.knative.dev/v1beta1` | KnativeEventing (name+ns `knative-eventing`) | docs.redhat.com 1.35 install (via WebSearch) | 2026-07-12 |
| Knative Service (**ksvc**) | `serving.knative.dev/v1` | Service | knative.dev/docs/serving/traffic-management + RH Serving | 2026-07-12 |
| Autoscaler (KPA default) | annotations `autoscaling.knative.dev/{class,min-scale,max-scale,target,metric,window}` · `spec.template.spec.containerConcurrency` · `config-autoscaler` CM (`enable-scale-to-zero`, `scale-to-zero-grace-period`, `scale-to-zero-pod-retention-period`, `target-utilization-percentage`) | ConfigMap ns `knative-serving` | knative.dev/docs/serving/autoscaling | 2026-07-12 |
| Traffic / revisions | `spec.traffic[]` = `{revisionName, tag, percent, latestRevision}`; new revision on any `spec.template` change; tagged URL `<tag>-<route>.<ns>.<domain>` | — | knative.dev/docs/serving/traffic-management | 2026-07-12 |
| Ingress / routing | **Kourier** default; operator **auto-creates a per-ksvc edge OpenShift Route** in ns `knative-serving-ingress`; two routes/ksvc (external + `*.svc.cluster.local`) | — | docs.redhat.com Serving "External and Ingress routing" (via WebSearch) | 2026-07-12 |
| Cluster-local (private) ksvc | label `networking.knative.dev/visibility=cluster-local` (on ksvc / Route / K8s Service) | — | knative.dev/docs/serving/services/private-services | 2026-07-12 |
| Functions (`kn func`) | templates `go,node,python,quarkus,rust,springboot,typescript` × `{http,cloudevents}`; **local build needs podman >=3.4.7 + a registry**; **on-cluster build needs OpenShift Pipelines** | — | docs.redhat.com Functions + developers.redhat.com (via WebSearch) | 2026-07-12 |
| **Install status on build cluster** | **NOT installed** — 0 serverless CSVs, no `knativeserving`/`knativeeventing` CRDs, no `knative-*` ns; operator present in catalog only | — | live `oc get csv -A / crd / ns` | 2026-07-12 |

**Headline confirmation (spec-critical):** the spec's "Serverless (Knative Serving/Eventing/Functions), `kn`" is current and correct; operator **1.37.1** on channel `stable` is the GA, matching `versions.yaml`. Serverless 1.37 = Knative **1.17** across Serving/Eventing/Kourier/kn.

Cluster reality (verified live 2026-07-12, read-only):

- **Serverless is not on the cluster.** The catalog holds `serverless-operator` (defaultChannel `stable`; channels `stable-1.29`...`stable-1.37`, `stable`=`stable-1.37`=`serverless-operator.v1.37.1`) but nothing is installed — no CSV, no `serving.knative.dev`/`eventing.knative.dev` CRDs, no `knative-serving`/`knative-eventing` namespaces. So the spec's entry-state line "**Serverless installed**" is a **net-new platform build**, not a given.
- **No GitOps serverless component exists.** `platform-portfolio/components/` has no serverless/knative dir; `platform-portfolio/README.md` still lists `serverless` under "*(coming)*". There is **no `serverless` stack** in `platform-portfolio/stacks/` (present: ai-assist, auth, batch, core-devtools, observability, portal, progressive-delivery, trust, trust-demo). The spec profile **`core+serverless`** has no wiring yet.
- **`keda` component is the install model.** `platform-portfolio/components/keda/` (Custom Metrics Autoscaler, `custom-metrics-autoscaler.v2.19.0-1`) is the ready operator-component pattern: `namespace.yaml` + `operatorgroup.yaml` + `subscription.yaml` (channel `stable`, `installPlanApproval: Automatic`, `source: redhat-operators`, `sourceNamespace: openshift-marketplace`) + the instance CR (`kedacontroller.yaml`). The serverless component mirrors it exactly, swapping in the two Knative instance CRs.
- **`apps/parasol-claims` IS the "claims-processor".** Quarkus app, `Containerfile`, `openshift/buildconfig.yaml`, `catalog-info.yaml`, `devfile.yaml`; `application.properties` binds **`quarkus.http.port=8080`** (the ksvc container port) with `/q/health/live|ready` probes on. It already ships **`ClaimEvent.java`** — a natural CloudEvents sink for the eventing taste.
- **`apps/parasol-service-template`** (golden-path skeleton + `template.yaml`) is the model for the `kn func` "premium-calculator" function and/or a ksvc packaging.
- **`gitops/entry-states/` stops at m13** — no m14-m19. All M19 entry state (image-ready, ksvc/eventing seed) is net-new.

## Spec deltas

- **Task brief says "M20 Eventing (M19 precedes it)" — WRONG per current specs.** M20 is **OpenShift Virtualization** (02-MODULE-SPECS line 252); the eventing deep-dive + Serverless Logic is **M24** (line 295: "Eventing Deep-Dive & Serverless Workflows"), and M19's own text says "the deep eventing + workflows story is **M24**". `content/…/index.adoc` also lists M24 as the eventing module. The M19 handoff target is **M24**, not M20. (Old standalone Kafka M18 was RETIRED 2026-07-08, folded into M24.)
- **Entry-state "Serverless installed" is net-new platform work** (see Cluster reality) — operator + `KnativeServing` + `KnativeEventing` via a new `platform-portfolio/components/serverless` and a `core+serverless` stack; none exists today.
- **"claims-processor container image ready" is also net-new.** No m19 entry-state chart exists; the image must be materialized (hook Job building `apps/parasol-claims` into the internal registry, or an `oc import-image` of a prebuilt tag) — do **not** assume M02/M07 ran (module-independence rule 2). M17's "internal registry has no external route, build route-free via the API" applies here.
- **Routing: a ksvc is NOT published with `oc create route edge`.** The project's standing "browser Routes must be `oc create route edge … --insecure-policy=Allow`" rule (MEMORY `browser-routes-need-edge`, M01/M02) **does not apply to Knative**: the Serverless operator **auto-creates the external edge-terminated OpenShift Route** (ns `knative-serving-ingress`, backed by Kourier) and the browser URL is `ksvc.status.url` (HTTPS by default). Hand-rolling a Route for a ksvc is wrong and will fight the operator. This is the "how Knative's routing interacts" answer the brief asked for.
- **`kn func` local-build path is infeasible in the cockpit.** Local `kn func build/deploy` needs podman >=3.4.7 + push access to a registry; the Showroom **ttyd terminal has neither** (same constraint M17 recorded for the internal registry). The workshop func beat must use the **on-cluster build path**, which **requires OpenShift Pipelines** — so the `core+serverless` profile must also carry the `openshift-pipelines` component (M07's stack), or the func beat is `[INSTRUCTOR-DEMO]`/pre-built.
- **Cold-start expectation for a JVM Quarkus ksvc is multi-second.** `parasol-claims` is JVM Quarkus (not native); scale-from-zero cold start is realistically ~2-5 s. That is *fine as the teaching moment* for the demo arc, but latency-sensitive beats should set `autoscaling.knative.dev/min-scale: "1"` and the note should be honest (contrast Quarkus native / cost-vs-latency tradeoff), not hide it.
- **"eventing taste" default broker needs no Streams.** The PingSource->Broker->Trigger beat runs on the **default in-memory (MTChannelBasedBroker)** broker from `KnativeEventing` — no Kafka/Streams subscription (consistent with M24's subscription-free default). Per-user broker footprint is small but ×30 (see risks).

## Approach recommendations

1. **Build the GitOps install first** (rule 7 — imperative installs are a defect): net-new `platform-portfolio/components/serverless` modeled on `components/keda` = ns `openshift-serverless` + OperatorGroup + Subscription (`serverless-operator`, pin channel **`stable-1.37`**, `redhat-operators`) + **`KnativeServing`** (ns `knative-serving`) + **`KnativeEventing`** (ns `knative-eventing`); add a `serverless` stack and wire the `core+serverless` profile. Mine the redhat-cop base (below) for the CR/kustomize shape.
2. **Ksvc arc = deploy -> observe revisions -> scale 0->N -> tune concurrency**, all namespaced in `{user}-dev` against the pre-built `parasol-claims` image on port 8080; watch `ksvc.status.url` (operator-managed edge Route) — **never** `oc create route edge` for the ksvc. Load via a small in-cluster hey/curl-loop pod (no external LB dependency, the project demo-client pattern), watching `oc get pods -w` scale from zero.
3. **Traffic beat = tag-based blue/green on revisions** (`spec.traffic[]` with `tag`+`percent`, `latestRevision:false`), explicitly **contrasting M10 Argo Rollouts** (deployment-driven, metric-gated) — reuse the in-repo framing already in `m10-gitops-at-scale/concept.adoc`+`wrapup.adoc` so the three traffic-shift stories (Rollouts / mesh / Knative revisions) stay consistent.
4. **Eventing taste stays a taste** (deep story = M24): PingSource -> default in-memory Broker -> Trigger -> the `parasol-claims` ksvc `ClaimEvent` sink, in one diagram; close with an explicit "the broker-vs-channel decision, DLQ and SonataFlow are **M24**" pointer.
5. **Functions via on-cluster build only** (Pipelines dependency): `kn func create` a small `premium-calculator` (quarkus or node, `http` template) -> `kn func deploy` using the on-cluster/Pipelines build -> deploys as a ksvc. If Pipelines isn't in the profile, make this `[INSTRUCTOR-DEMO]` + a pre-built image; wrap with the honest **serverless-vs-Deployment decision matrix** (align with `m06 wrapup`).

## Mining results

- **`OldContent/repos/gitops-catalog/serverless-operator/`** (redhat-cop, Apache-2.0) → **primary GitOps mine**. Carries the exact `KnativeServing` instance (`instance/knative-serving/base/knative-serving-instance.yaml` — `operator.knative.dev/v1beta1`, name+ns `knative-serving`), a `knative-eventing` instance, and subscription/overlay kustomize. Re-implement as `platform-portfolio/components/serverless`; **credit redhat-cop gitops-catalog via CREDITS.md**. Verify the channel against `versions.yaml` at build (pin `stable-1.37`).
- **`OldContent/repos/showroom/content/modules/ROOT/pages/serverless/instructions.0-5.adoc`** + `module-serverless-intro.adoc` + `module-serverless-instructions.adoc` → a **complete pre-existing Knative Serving lab** (6 steps): this is the concrete **"CNA M6 shape"** the spec's Mine line points at. Port the **lab arc + narrative** (deploy ksvc -> scale-to-zero -> revisions/traffic), **re-implement on Parasol services**, discard any stale tech; credit the Cloud Native Architectures / rh-cloud-architecture showroom source.
- **`OldContent/Cloud Native Architectures Workshop - *.pdf`** (Content Overview / Intro / Provisioning) → the CNA business-challenge-first module rubric + persona-takeaway shape for the concept page and demo arc (per 05-REFERENCES row). Narrative only; no tech.
- **`apps/parasol-claims` (IN-REPO)** → the ksvc workload (port 8080, health probes, `ClaimEvent.java` sink). **`apps/parasol-service-template` (IN-REPO)** → model for the `kn func premium-calculator` function. No external credit (project-owned).
- **`platform-portfolio/components/keda/*` (IN-REPO)** → the operator-component skeleton (namespace+operatorgroup+subscription+instance CR) to clone for serverless; also the **autoscaling cross-ref** (KEDA/Custom Metrics Autoscaler for event/queue-driven scale vs Knative KPA for request-driven — the M06/M12 vs M19 distinction).
- **`content/…/m06-jobs-batch-kueue/wrapup.adoc` + `m10-gitops-at-scale/{concept,wrapup}.adoc` (IN-REPO)** → existing serverless decision-matrix and "third way to shift traffic" prose to stay consistent with (don't contradict the already-shipped framing).
- **`OldContent/repos/nationalparks`, `repos/starter-guides`** → older pipeline/serverless references; **discard the tech** (2020-era), take nothing but narrative shape if anything. `OldContent/repos/parasol-insurance` (upstream Parasol Quarkus app) → reference only; `apps/parasol-claims` already supersedes it.

## Open risks

- **Everything platform-side is net-new and unproven on this cluster.** Serverless operator + both Knative CRs + a `serverless` stack + `core+serverless` profile + an m19 entry-state chart + ws-meta all have to be built and G3-smoked; the install is `// TODO(verify-on-cluster)` until the component syncs and `KnativeServing`/`KnativeEventing` report Ready.
- **Route/edge behavior needs a live confirm once installed.** The "operator auto-creates an edge Route in `knative-serving-ingress`" and cluster-local-label facts came from docs.redhat.com via WebSearch (direct fetch 403s today); `[CAPTURE-VERIFY]` the actual Route object + `ksvc.status.url` scheme on-cluster at build before writing the routing beat.
- **`kn func` build path is the sharpest blocker.** No local podman/registry in the cockpit → on-cluster build → **hard dependency on OpenShift Pipelines** in the profile. Decide at build: add `openshift-pipelines` to `core+serverless`, or make the func beat instructor-demo/pre-built. Also pin the `kn` CLI (1.17) into the cockpit image.
- **Cold-start honesty.** JVM Quarkus scale-from-zero is ~2-5 s; the demo arc must either embrace it as the lesson or `min-scale: "1"` the latency-sensitive path — set expectations in prose (spec watchout "cold-start expectations").
- **Per-user broker/eventing footprint ×30.** Default in-memory broker is light but multiplies; size `KnativeEventing`/broker and per-user quota (M14 quota interplay) before enabling eventing for all attendees (spec watchout "per-user broker resources").
- **Autoscaler resource pressure under load demos.** 30 users each bursting a ksvc 0->N can spike scheduler/quota; cap `autoscaling.knative.dev/max-scale` (e.g. "3"-"5") in the entry state and lean on the standing ResourceQuota (M14).
- **Namespace-scoping of KPA config.** `config-autoscaler` is cluster-wide (ns `knative-serving`); per-attendee tuning must be via **per-ksvc annotations** (`autoscaling.knative.dev/*`), never the shared ConfigMap — otherwise one attendee's change hits all 30.
- **Do not mutate cluster singletons live.** `KnativeServing`/`KnativeEventing`/`config-autoscaler` are cluster-wide; attendee hands-on stays on their own ksvc annotations in `{user}-dev`.

## Builder/platform appendix

### Lab arc (75 min, spec-faithful) — the module spine

| Beat | Object / command | Scope | Path |
|---|---|---|---|
| Deploy ksvc | `kn service create parasol-claims --image …:8080` **or** `oc apply` a `serving.knative.dev/v1` Service | namespaced `{user}-dev` | **CLI \| Console** (Serverless perspective / +Add) |
| Watch scale 0->N | in-cluster load pod -> `oc get pods -w`; observe activator->pod, then scale-to-zero after grace period | namespaced | **CLI \| Console** (topology shows 0 pods) |
| Tune autoscaling | per-ksvc `autoscaling.knative.dev/target`, `containerConcurrency`, `min-scale`/`max-scale` | namespaced | **CLI \| Console** (YAML edit) |
| Tag-based traffic | new revision (change `spec.template`) -> `spec.traffic[]` tag+percent blue/green; contrast M10 | namespaced | **CLI \| Console** |
| Eventing taste | PingSource -> Broker (in-memory) -> Trigger -> `parasol-claims` ksvc (`ClaimEvent`) | namespaced | **CLI** (+ Console view) |
| Build a Function | `kn func create premium-calculator` -> **on-cluster** `kn func deploy` (Pipelines) | namespaced | **CLI** (IDE/product-UI beat) |
| Wrap | serverless-vs-Deployment decision matrix + pointer to **M24** | — | — |

Demo arc (spec): scale-from-zero under sudden load + revision rollback, 10 min.

### Entry-state sketch — `gitops/entry-states/m19/` (per-user, net-new; compose-don't-chain)

- A **pre-built `parasol-claims` image** already in the internal registry as an ImageStream/tag in `{user}-dev` (materialize via a hook Job that builds `apps/parasol-claims`, or `oc import-image` a prebuilt tag) — never assume M02/M07 ran.
- Namespace `{user}-dev` (already `admin`+quota'd+limit-ranged by the standing workshop-config) — reuse, don't re-create.
- `ws-meta.yaml`: `purgeNamespaces: ["${USER}-dev"]`-scoped cleanup of ksvc/revisions/route/broker/trigger/PingSource/func on reset; `conflictsWith` any other module sharing `{user}-dev` (M01-M05 do — declare both directions per ADR-0001 amendment 4, like `entry-states/m07/ws-meta.yaml`); generous `waitSeconds` (image build + first cold start).
- Verify script mode-split (entry vs completion), `>=` not `==` for scale outcomes.

### platform-portfolio needs (net-new, platform-engineer)

- **`platform-portfolio/components/serverless`** (model on `components/keda`): `namespace.yaml` (openshift-serverless) + `operatorgroup.yaml` + `subscription.yaml` (`serverless-operator`, channel `stable-1.37`, `redhat-operators`, `openshift-marketplace`, `installPlanApproval: Automatic`) + `knative-serving.yaml` (`KnativeServing`, ns `knative-serving`) + `knative-eventing.yaml` (`KnativeEventing`, ns `knative-eventing`). Sync-wave the CRs **after** the CSV is Succeeded (operator must register the CRDs first — same ordering lesson as other operator+instance components).
- New **`serverless` stack** + `core+serverless` profile map; include **`openshift-pipelines`** in the profile if the on-cluster func build is in-scope.
- Extend **`platform-observer`** (read-only) with `serving.knative.dev`/`eventing.knative.dev` reads if attendees inspect cluster-scoped serverless objects (re-run the cross-tenant-leak check, per M17).

### Concept diagram (>=1, per style guide)

Request-driven compute on one page: **client -> (auto edge Route in `knative-serving-ingress`, Kourier) -> Route/Config -> Revision(s) -> KPA (scale 0<->N on concurrency)**, with a side panel for the **eventing taste** (PingSource -> Broker -> Trigger -> ksvc) and a callout box "traffic split by revision tag — the third way (M10 = Rollouts, M16 = mesh, here = Knative)". Editable Mermaid in-repo (style-guide §1).

### Cross-module fit (no overlap)

- **M06** owns batch Jobs/Kueue and the async-spectrum decision table (already names Serverless as the request/event-driven counterpart) — M19 is the "request-driven" leg, don't re-teach batch.
- **M10** owns Argo Rollouts progressive delivery — M19's traffic beat is the *revision-tag* contrast, cross-referenced, not a re-teach.
- **M12/M06** own KEDA/Custom Metrics Autoscaler (event/queue-driven scale) — M19 owns KPA (request-driven, scale-to-zero); name the distinction, don't overlap.
- **M24** owns the eventing deep-dive + Serverless Logic (SonataFlow) + optional Kafka — M19 gives only the source->broker->trigger taste and hands off. M24's entry-state is "claims-processor ksvc deployed (M19-equivalent end state)".
