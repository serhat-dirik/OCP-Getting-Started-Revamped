# M25 build note — Packaging & Distributing Your App (Helm, Operators, OLM)

Date: 2026-07-15 · Author: research-analyst · Spec: `Project-Shared/instructions/02-MODULE-SPECS.md` **§M25 (lines 303-312)** · Entitlement: **[OCP]** (core OpenShift — no add-on SKU; 02-MODULE-SPECS line 13 lists M25-M26 as `[OCP]`) · 90 min · profile `core`.

Method: READ-ONLY live build cluster `ocp-ws-revamped` (C1; OCP 4.21.22 / k8s 1.34.8) as `admin`, no mutations — `oc api-resources` / `oc get` on OLM v0 (`operators.coreos.com`) + OLM v1 (`olm.operatorframework.io`) objects, CSVs, subscriptions, packagemanifests, catalogsources, the image-registry config/route, and `platform-observer`. No `helm push`/`oc registry login` run (those mutate the registry). Repo inspection: `apps/`, `gitops/entry-states/`, `platform-portfolio/`, `versions.yaml`. Product facts via docs.redhat.com / developers.redhat.com / connect.redhat.com (WebSearch; docs.redhat.com 403s on direct fetch). Cross-checked `docs/research/m17-build-note.md` (shared internal-registry reality) and §M26 (spectrum/OLM-v1 alignment). Live infra strings scrubbed to placeholders per the CI privacy guard.

## Verified versions

| Product / API | Version / status | Group·Kind (evidence) | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 (k8s 1.34.8) | stable-4.21 | `oc version` (live C1) | 2026-07-15 |
| **Classic OLM (v0)** | **CURRENT default install path** — every operator on-cluster installed this way | `operators.coreos.com` — Subscription/ClusterServiceVersion/CatalogSource/InstallPlan/OperatorGroup | live `oc get subscriptions.operators.coreos.com -A` / `oc get csv -A` | 2026-07-15 |
| **OLM v1 (Operator Controller)** | **GA since OCP 4.18**; present + serving on 4.21 but **0 ClusterExtensions installed**; **CLI-only, not surfaced in the 4.21 web console** | `olm.operatorframework.io/v1` — ClusterCatalog (cluster-scoped) + ClusterExtension | live `oc get clustercatalog/clusterextension` + docs 4.21 OLM v1 | 2026-07-15 |
| OLM v1 components | pods Running 7d | ns `openshift-catalogd`, `openshift-operator-controller`, `openshift-cluster-olm-operator` | live `oc get ns/pods` | 2026-07-15 |
| Helm | client **v3.12.1** (laptop); OCI registry support **GA since Helm 3.8** | `helm version` | live + helm.sh docs | 2026-07-15 |
| Internal image registry | Managed; Service `image-registry.openshift-image-registry.svc:5000`; **NO external route** (`spec.defaultRoute` unset, `oc get route -n openshift-image-registry` → none) | `imageregistry.operator.openshift.io/v1·Config`; host from `image.config.openshift.io/cluster .status.internalRegistryHostname` | live | 2026-07-15 |
| **Pipelines operator** (recommended dissection target) | `openshift-pipelines-operator-rh.v1.22.4`, Succeeded; channel `latest` (== `pipelines-1.22`); **14 owned CRDs**; installMode AllNamespaces; catalog `redhat-operators` | `operators.coreos.com·ClusterServiceVersion` (ns `openshift-operators`) + `packages.operators.coreos.com·PackageManifest` | live `oc get csv/packagemanifest` | 2026-07-15 |
| GitOps operator (alt target) | `openshift-gitops-operator.v1.21.1`, Succeeded; channels `gitops-1.6`..`gitops-1.21` + `latest`; catalog `redhat-operators` | same | live | 2026-07-15 |
| ClusterCatalogs (OLM v1) | 4 serving: `openshift-redhat-operators`, `-certified-operators`, `-community-operators`, `-redhat-marketplace` (all `Serving=True`) | `olm.operatorframework.io/v1·ClusterCatalog` | live | 2026-07-15 |
| CatalogSources (OLM v0) | `redhat-operators`, `certified-operators`, `community-operators`, `redhat-marketplace` (ns `openshift-marketplace`) + custom `redhat-rhpds-gitea` | `operators.coreos.com/v1alpha1·CatalogSource` | live | 2026-07-15 |
| **parasol-notifications app** | **EXISTS** — polyglot Node/Python, port 8080, `GET /health`→`{status:UP}`, optional `SITE` env, **no DB** (in-memory) | repo `apps/parasol-notifications/` | repo + README | 2026-07-15 |
| Red Hat certification (ISV road) | Operator/container bundle → **Preflight** + Red Hat Partner Connect portal; Helm chart → **chart-verifier** + `openshift-helm-charts` repo; both publish to the **Red Hat Ecosystem Catalog** | — | connect.redhat.com + docs.redhat.com software-certification 2025 | 2026-07-15 |

**Headline (spec-critical): teach classic OLM v0 as the primary "read a bundle/catalog" mechanism; show OLM v1 as the direction.** On this 4.21.22 cluster *every* operator the attendees used all week (Pipelines M07, GitOps M08, Serverless M20, Service Mesh M18, Tempo/OTel M12, …) was installed by **classic OLM v0** — a `Subscription` (channel + `redhat-operators` source) → `InstallPlan` → `ClusterServiceVersion` → Deployment. That is exactly "what happens when a customer clicks your tile," and it is what the console OperatorHub / Installed Operators pages still drive. **OLM v1 is GA (since 4.18) and live here — 4 ClusterCatalogs are serving — but nothing is installed through it (0 ClusterExtensions) and the 4.21 web console does not surface it yet** (docs: OLM v1 procedures are CLI-only in 4.21). So the spec's `dissect a real operator's bundle on-cluster (CSV, CRDs, channels)` maps cleanly onto v0 objects; OLM v1 (`ClusterCatalog`/`ClusterExtension`, `registry+v1` bundle) is a 5-minute "where this is going" beat that ties §M26's "OLM v1 direction." **`parasol-notifications` already exists and is a good Helm target — it is NOT a blocking prerequisite** (details below).

## Cluster / repo reality (verified live 2026-07-15, read-only)

- **Both OLM generations coexist.** `oc api-resources` shows `operators.coreos.com` (csv/subscriptions/installplans/operatorgroups/catalogsources) AND `olm.operatorframework.io/v1` (clustercatalogs/clusterextensions). v0 is doing all the work; v1 is idle-but-serving.
- **The "customer clicks your tile" chain is v0, live and inspectable.** e.g. `subscriptions.operators.coreos.com/openshift-pipelines-operator-rh` (ns `openshift-operators`, channel `latest`, source `redhat-operators`, `status.installedCSV=openshift-pipelines-operator-rh.v1.22.4`) → CSV `Succeeded`. The Pipelines CSV owns 14 CRDs (`TektonConfig`, `TektonPipeline`, `TektonTrigger`, `TektonChain`, `TektonResult`, `OpenShiftPipelinesAsCode`, …), installMode `AllNamespaces`, install strategy `deployment` — a rich, clean bundle to dissect.
- **Global operators' CSVs are COPIED into every namespace** (AllNamespaces install mode). Filter to the real ones with `oc get csv -A -l '!olm.copiedFrom'`; the authoritative copy lives in the operator's own namespace (`openshift-operators`, `openshift-gitops-operator`, …).
- **Internal registry has NO external route** (`spec.defaultRoute` unset; zero routes in `openshift-image-registry`) — identical to M17's finding. `helm push oci://` from the laptop or cockpit is therefore **not runnable as-written** without a platform decision (see Spec deltas #3). Registry Service is `image-registry.openshift-image-registry.svc:5000` (ClusterIP, in-cluster only).
- **Bare-name ambiguity trap, hit live:** `oc get subscription` returned a `subscriptions.messaging.knative.dev` object (a Knative InMemoryChannel), NOT the OLM Subscription — because two `subscription` kinds are served. Content and verify scripts MUST fully-qualify `subscriptions.operators.coreos.com`. Same class as the known `oc get packagemanifest` bare-name trap; enumerate packagemanifests with `--field-selector=metadata.name=<name> -o json | jq …`.
- **`platform-observer` ClusterRole (live) is missing the OLM-dissection reads.** It grants `packages.operators.coreos.com/packagemanifests` (get,list) and `operators.coreos.com/catalogsources` (get,list,watch) — but NOT `operators.coreos.com` {`clusterserviceversions`,`subscriptions`,`installplans`,`operatorgroups`}, NOT `apiextensions.k8s.io/customresourcedefinitions`, NOT `olm.operatorframework.io` {`clustercatalogs`,`clusterextensions`}. Attendees cannot read an operator's CSV/CRDs/InstallPlan read-only until the role is extended (`gitops/workshop-config/templates/platform-observer-clusterrole.yaml`).
- **No M25 scaffolding exists.** `gitops/entry-states/` runs m01-m23 + m27; there is **no `m25`** and **no Helm chart / "chart skeleton" seeded anywhere** in the repo. All net-new.
- **`parasol-notifications` is a clean Helm target.** Node (stdlib, zero deps) or Python (FastAPI) with an identical API; `PORT` (default 8080), optional `SITE` env, probe `GET /health`, an in-memory store (no DB), runs under restricted-v2 SCC. It ships **no** k8s workload manifests — the chart templates Deployment/Service/Route fresh, which is exactly the `helm create` lesson.
- **Cluster noise (not M25's bug, but attendees will see it):** `cert-manager-operator.v1.20.0` CSV is `Failed` and KEDA `custom-metrics-autoscaler` is mid-`Replacing`. Steer dissection to Pipelines (`Succeeded`) or use a Failed CSV as an honest "this is what a broken install looks like" aside.

## Spec deltas

- **"OLM available (default)" + "read an OLM bundle/catalog" — clarify which OLM.** The default that installs operators is **classic OLM v0**; **OLM v1 is GA-and-present but idle (0 ClusterExtensions) and console-invisible in 4.21**. Not an either/or: teach v0 as the graded dissection path (it installed everything all week and drives OperatorHub), preview v1 as direction. Evidence: live `oc get clusterextension` → none; docs "OLM v1 procedures are CLI-based only" in 4.21.
- **Entry state "parasol-notifications source in `{user}` Gitea; chart skeleton seeded" — half true, and no scaffolding yet.** `parasol-notifications` EXISTS (`apps/parasol-notifications/`) — but it is a deliberately-tiny **Node/Python polyglot**, not the Quarkus service the owner brief hypothesised. There is **no chart skeleton** and **no `gitops/entry-states/m25`** anywhere. Also a minor internal tension: entry state says "chart skeleton seeded" while Hands-on says "`helm create`" — recommend the attendee runs `helm create` live (fast, instructive) and the entry state seeds only the notifications *source* in `{user}` Gitea + a *prebuilt image* so `helm install` has something to pull.
- **"push as OCI artifact to the registry" is not runnable as-written.** The internal registry has no external route (`defaultRoute` unset). The OCI push needs a platform decision (Approach #3): enable `defaultRoute: true` (documented, reversible — but touches a cluster characteristic → tension with the "non-invasive on existing clusters" hard rule), OR push from the in-cluster cockpit pod to `svc:5000`, OR use Gitea's built-in OCI/package registry. Pick and ground before writing steps.
- **Bare-name kind ambiguity (hit live).** `oc get subscription` resolves to Knative's `subscriptions.messaging.knative.dev`, not `operators.coreos.com`. Content/verify must fully-qualify. (Spec doesn't mention this; it will bite attendees and any `ws verify` script.)
- **platform-observer RBAC gap.** The role cannot read CSV/Subscription/InstallPlan/OperatorGroup, CRDs, or OLM v1 objects — extend it before the dissection exercise can run read-only for attendees (re-run the cross-tenant-leak check; the role file records a prior namespaces-grant incident).
- *(No delta on scope vs M26 — the spec's own "align spectrum with M26" holds; see Approach #5.)*

## Approach recommendations (max 5, one line each)

1. Teach **classic OLM v0** as the graded dissection path (Subscription→InstallPlan→CSV→CRDs→channels on the live **Pipelines** operator), and add a ~5-min **OLM v1 "direction"** beat (`oc get clustercatalog` shows 4 serving; `ClusterExtension`/`registry+v1`) — not either/or.
2. Run the Helm lab on **`parasol-notifications` as-is** (Node/Python, no DB): `helm create` → template image/`SITE`-env/`/health`-probe/port-8080/**edge Route** → `install`/`upgrade --set`/`rollback` → one `helm test` (curl `/health`) — keep scope tight (no subcharts, no CRDs-in-charts) per the watchout.
3. Resolve the **OCI-push path as a platform spike before content**: recommend enabling registry `defaultRoute: true` (documented `helm registry login`/`helm push oci://`/`helm pull` flow) OR an in-cluster `svc:5000` push from the cockpit pod — the push is mutating, so ground it end-to-end at build (`// TODO(verify-on-cluster)`), not now.
4. Build **net-new scaffolding**: `gitops/entry-states/m25` (per-user notifications source in Gitea + a prebuilt notifications image istag) + **extend `platform-observer`** for CSV/Subscription/InstallPlan/CRD/ClusterCatalog reads; compose-don't-chain (never assume M02/M07 ran).
5. Align the **packaging spectrum with M26**: manifests → OpenShift Template → Kustomize → Helm → Operator, ordered by day-2 cost; M25 = *consumer* depth (read a bundle, when NOT to write an operator), M26 = *producer* depth (`operator-sdk` builds the bundle) — share one honesty line.

## Mining results

- **Spec says "Mine: fresh"** and 05-REFERENCES §1 maps **no OldContent** to M25 — no legacy workshop covers Helm-as-OCI / OLM anatomy at this depth. Build fresh from product docs.
- **In-repo (no external credit):**
  - `apps/parasol-notifications/` → the Helm target; endpoints/env/port grounded above. Its README's "Honest limitation" (in-memory, resets on restart) is a ready **"when not to use this"** line.
  - `apps/parasol-service-template/` (Quarkus Backstage golden-path `template.yaml` + `skeleton/`) → NOT a Helm chart; use as the **contrast** for "packaging as scaffolding vs packaging as a release artifact," and the M10 tie.
  - `gitops/entry-states/m06/Chart.yaml` (+ m05) → the entry-state Helm-chart shape to copy for `m25` (`apiVersion: v2`, `type: application`).
  - `versions.yaml` `ocp_registry_governance` block (M17, verified 2026-07-12) → reuse the internal-registry facts (svc:5000, no defaultRoute, pruner, PVC) — do not re-verify from scratch.
  - `docs/research/m17-build-note.md` → the **disconnected/mirror ISV-road tie** (IDMS/ITMS mirroring, CatalogSource governance, `oc-mirror`); reference for the "disconnected-customer expectations" beat, don't re-teach.
- **Live "operators you used all week" as the concept catalog:** point at the real CSVs — Pipelines (M07), GitOps (M08), Serverless (M20), Service Mesh 3 (M18), Tempo/OTel (M12) — "each of these is a bundle in a channel in a catalog."
- **Product docs (verify at build):** Helm OCI registries (helm.sh/docs/topics/registries); OCP 4.21 **OLM v1** (docs.redhat.com …/operators/olm-v1 and …/extensions); OCP **"Exposing the registry"** (`oc patch configs.imageregistry.operator/cluster … defaultRoute:true`); developers.redhat.com "Manage operators as ClusterExtensions with OLM v1" (2025-06-02); Red Hat **software certification** 2025 policy guide + Partner Connect (operator: Preflight; Helm: chart-verifier / `openshift-helm-charts`).

## Open risks

- **OCI push blocked without a platform decision** (no external registry route). Enabling `defaultRoute` is documented and reversible but changes a cluster characteristic (non-invasive hard-rule tension) — owner call. `// TODO(verify-on-cluster)` the chosen push+pull round-trip at build.
- **Helm-chart-as-OCI to the OpenShift internal registry is UNVERIFIED here** (verifying it means pushing = mutating, which this read-only pass did not do). The registry is Distribution-based and generally accepts OCI artifacts, but it may store the chart **without** creating a browsable ImageStream (storage-only) — a build spike must confirm `helm push`/`helm pull` succeed and how the artifact shows up.
- **Cockpit terminal Helm version/PATH unknown** — verify the Showroom terminal image ships `helm` ≥ 3.8 (OCI-capable) on `PATH` (`oc` does not bundle helm). `// TODO(verify-on-cluster)`.
- **Bare-name ambiguity ×2** (`subscription`, `packagemanifest`) resolve to the wrong kind — content + `ws verify` must fully-qualify or they will silently read Knative/other-catalog objects.
- **platform-observer RBAC gap** → attendee dissection fails read-only until extended; re-run the cross-tenant-leak check (prior incident in the role file).
- **Registry storage = one RWO PVC + nightly pruner** (M17): 30 users each pushing chart layers add churn, and a pushed **chart artifact is not referenced by any running Deployment**, so the daily pruner (`keepYoungerThan 60m`) could remove it overnight on a multi-day event — mitigate (pin, or push into the same lab session that pulls).
- **OLM v1 is moving** (console surfacing likely 4.22+); re-verify at build — but keeping v0 as the graded path insulates the lab from that churn.
- **Module independence:** the m25 entry state must materialize the notifications source + a pullable image without assuming M02 (build) or M07 (pipeline) ran.

## Builder / platform appendix

### Lab spine (grounded step outline)

**A — Helm a real service (`{user}-dev`, attendee, dual-path where genuine):**
1. `helm create parasol-notifications` → read the generated tree (Chart.yaml, values.yaml, templates/, _helpers.tpl).
2. Template it: point `image` at the internal-registry istag (or a prebuilt public image), set `containerPort: 8080`, probes `httpGet /health`, env `SITE`; **replace the stock Ingress with an OpenShift edge Route** (per the browser-routes-need-edge rule — `oc create route edge`/a Route template, not plain Ingress/`oc expose`).
3. `helm lint` → `helm template` (inspect rendered YAML) → `helm install parasol-notifications ./parasol-notifications -n {user}-dev`.
4. `helm upgrade --set replicaCount=2` (or an env change) → `helm history` → `helm rollback parasol-notifications 1`. (break/fix: set a wrong probe path, watch it fail, roll back — satisfies the "deliberate break" rule.)
5. One `helm test` Pod (curl `/health`, then `POST /api/notify` → `GET /api/notifications`) + one lifecycle hook (a `post-install` Job) — then STOP (watchout: no subchart/CRD rabbit holes).
6. `helm package parasol-notifications` → `parasol-notifications-0.1.0.tgz`; `helm registry login <target>` + `helm push … oci://<target>/{user}-dev` **[MUTATING — build-spike path per Approach #3]**; `helm pull`/`helm install oci://…` to prove install-from-registry.

**B — Dissect a real operator's bundle (cluster read; attendee needs extended platform-observer). Recommended: Pipelines. All read-only:**
- Channels (avoid the bare-name trap): `oc get packagemanifests --field-selector=metadata.name=openshift-pipelines-operator-rh -o json | jq '.status.defaultChannel, [.status.channels[].name]'` → `latest` (== pipelines-1.22), `pipelines-1.15`..`pipelines-1.22`.
- The "tile click" result: `oc get subscriptions.operators.coreos.com -n openshift-operators openshift-pipelines-operator-rh -o yaml` (channel, source, `status.installedCSV`).
- The bundle's heart: `oc get csv -n openshift-operators openshift-pipelines-operator-rh.v1.22.4 -o yaml` (`spec.customresourcedefinitions.owned` = 14 CRDs; `spec.install.spec.deployments`; `spec.installModes`; `relatedImages`).
- The CRDs it owns: `oc get crd | grep tekton`; `oc get crd tektonconfigs.operator.tekton.dev -o yaml`.
- Where it came from: `oc get catalogsource -n openshift-marketplace redhat-operators -o yaml`; `oc get installplan -n openshift-operators`.
- OLM v1 direction (read): `oc get clustercatalog` (4 serving) and `oc get clusterextension` (none — "this is the new model, not yet used here").

**C — [paper exercise] map your product onto the spectrum → wrap: certification/marketplace pointers** (Preflight for operators, chart-verifier + `openshift-helm-charts` for charts, Red Hat Ecosystem Catalog; disconnected mirrors → M17).

### Packaging spectrum (concept diagram, ordered by day-2 responsibility)

| Package | Templating | Versioned artifact | Runtime lifecycle (day-2) | Authoring cost | Ties |
|---|---|---|---|---|---|
| Raw manifests / `oc apply` | none | no | you own everything | ~0 | — |
| OpenShift **Template** / `oc process` | params | no | one-shot instantiate, no upgrade | low | M17 dev-catalog |
| **Kustomize** | overlays/patches | no (git) | declarative, no hooks/reconcile | low | M08 GitOps |
| **Helm** | Go templates + values | **yes (chart, OCI)** | `helm upgrade`/`rollback`, hooks, tests — client-side, no continuous reconcile | medium | **M25 focus** |
| **Operator (OLM)** | CRD + controller | **yes (bundle, channel, catalog)** | **continuous reconcile** — owns upgrades/backup/failover; + OLM distribution + certification | high | **M26 builds one** |

Axis: going down, MORE day-2 responsibility is encoded IN the package (off the human) at the cost of authoring + lifetime complexity. **"When NOT to write an operator": if `helm upgrade` covers day-2, you don't need a reconcile loop** (honesty rule; shared with M26).

### OLM anatomy (concept diagram) — "what happens when a customer clicks your tile" (v0)

`Catalog (CatalogSource / ClusterCatalog)` → `PackageManifest (channels)` → you pick a channel via `Subscription` → OLM resolves → `InstallPlan` (Automatic/Manual approval) → `ClusterServiceVersion` (owned CRDs + Deployment + RBAC) → operator Pod reconciles your CRs. Show the **OLM v1** overlay: `ClusterCatalog` (catalogd) + `ClusterExtension` (operator-controller), `registry+v1` bundle, manual ServiceAccount RBAC — GA, CLI-only in 4.21.

### Entry-state sketch — `gitops/entry-states/m25/` (per-user, net-new; compose-don't-chain)
- `parasol-notifications` source pushed to `{user}` Gitea (reuse the established per-user seed-repo pattern).
- A **prebuilt notifications image** as an istag in `{user}-dev` (materialize via a hook Job / `oc import-image`, NOT by assuming M02) so `helm install` has a pullable image.
- `platform-observer` (already cluster-bound) **plus the extended OLM/CRD reads** (below).
- `ws-meta.yaml` `conflictsWith` any same-namespace module; `ws reset` purges the user's Helm releases + istag; idempotent templates.

### Platform / platform-portfolio needs (net-new)
- **Decide + implement the OCI-push path** (Approach #3). If `defaultRoute`: a small reversible `configs.imageregistry.operator/cluster` patch in `platform-portfolio` (adds `default-route-openshift-image-registry.apps.<cluster-domain>`); document the uninstall reversal.
- **Extend `platform-observer` ClusterRole** with read (get,list,watch) on: `operators.coreos.com` {`clusterserviceversions`,`subscriptions`,`installplans`,`operatorgroups`}, `apiextensions.k8s.io` {`customresourcedefinitions`}, `olm.operatorframework.io` {`clustercatalogs`,`clusterextensions`}. Re-run the cross-tenant-leak check.
- Confirm the **Showroom terminal image** ships `helm` ≥ 3.8.

### Cross-module fit (no overlap)
- **M17** owns registry/mirroring/catalog *governance* (IDMS/ITMS, CatalogSource sources, disconnected). M25 *reuses* the internal-registry reality and *references* M17 for the disconnected ISV-road beat — does not re-teach mirroring.
- **M26** owns operator *authoring* (`operator-sdk`, reconcile, `make bundle`). M25 sets up the *consumer* vocabulary (CSV/CRD/channel/catalog, read a bundle) M26 then produces; shared "when NOT to write an operator" line.
- **M07/M08** are the meta-payoff: the Pipelines & GitOps operators the attendee dissects are the CI/CD they used all week — "the platform runs on the exact packaging you just learned."

### Recommended `versions.yaml` addition (verified today; not written per this task's file-scope — paste at build)
```yaml
olm:
  v0_status: "current default install path (Subscription/CSV/CatalogSource) on OCP 4.21"
  v1_status: "GA since OCP 4.18; present+serving on 4.21 (ClusterCatalog/ClusterExtension); CLI-only, not in 4.21 web console; 0 ClusterExtensions on build cluster"
  v1_apis: "olm.operatorframework.io/v1 (ClusterCatalog, ClusterExtension); ns openshift-catalogd/openshift-operator-controller/openshift-cluster-olm-operator"
  dissection_target: "openshift-pipelines-operator-rh.v1.22.4 (14 owned CRDs; channel latest==pipelines-1.22; catalog redhat-operators)"
  verified: 2026-07-15
  source: "live cluster ocp-ws-revamped (oc get csv/subscription/packagemanifest/clustercatalog) + docs.redhat.com OCP 4.21 OLM v1"
  entitlement: OCP
helm:
  cli: "3.12.1 (laptop); OCI GA since Helm 3.8 — verify cockpit image ships >=3.8"
  oci_target: "internal registry has NO external route (defaultRoute unset) — OCI push needs a platform decision (see m25 build note)"
  verified: 2026-07-15
  source: "helm version + live image-registry config on ocp-ws-revamped"
  entitlement: OCP
```

### Relevant absolute paths
- Spec §M25 / §M26: `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/Project-Shared/instructions/02-MODULE-SPECS.md`
- Helm target app: `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/OCP-Getting-Started-Revamped/apps/parasol-notifications/`
- Scaffolding contrast: `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/OCP-Getting-Started-Revamped/apps/parasol-service-template/`
- Entry-state chart pattern to copy: `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/OCP-Getting-Started-Revamped/gitops/entry-states/m06/`
- platform-observer role (extend): `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/OCP-Getting-Started-Revamped/gitops/workshop-config/templates/platform-observer-clusterrole.yaml`
- Shared internal-registry facts: `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/OCP-Getting-Started-Revamped/versions.yaml` (`ocp_registry_governance`) + `docs/research/m17-build-note.md`

Sources:
- OCP 4.21 OLM v1 — https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/operators/olm-v1
- OCP 4.21 Extensions — https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/extensions/index
- Manage operators as ClusterExtensions with OLM v1 — https://developers.redhat.com/articles/2025/06/02/manage-operators-clusterextensions-olm-v1
- OCP Exposing the registry (defaultRoute) — https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/registry/securing-exposing-registry
- Helm OCI registries — https://helm.sh/docs/topics/registries/
- Red Hat OpenShift Software Certification Policy Guide (2025) — https://docs.redhat.com/en/documentation/red_hat_software_certification/2025/html-single/red_hat_openshift_software_certification_policy_guide/index
- Helm Chart software certification for OpenShift — https://connect.redhat.com/en/blog/helm-chart-software-certification-now-available-openshift
- Live cluster `ocp-ws-revamped` (read-only, 2026-07-15): `oc get csv/subscriptions.operators.coreos.com/packagemanifests/clustercatalog/clusterextension/catalogsource -A`, `oc get route -n openshift-image-registry`, `oc get configs.imageregistry.operator/cluster`, `oc get clusterrole platform-observer`
