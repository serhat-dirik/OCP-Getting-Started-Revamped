# M12 build note — Observability, Health & Scale

Date: 2026-07-09 · Author: research-analyst R4c · Spec: 02-MODULE-SPECS §M12 (lines 152-161)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22, k8s 1.34.8) — OLM packagemanifests (channels/CSVs/alm-examples/installModes), UWM configmaps + pods, node/storage capacity; repo inspection (apps + entry-states + portfolio); docs.redhat.com (COO 1-latest, Monitoring stack 4.21); developers.redhat.com (4.19 unified console). versions.yaml re-verified + extended 2026-07-09.

## Verified versions

| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-09 |
| Cluster Observability Operator (COO) | 1.5.1 | stable | packagemanifest `cluster-observability-operator` (Red Hat); csv `cluster-observability-operator.v1.5.1` | 2026-07-09 |
| Tempo Operator | 0.21.0-2 | stable | packagemanifest `tempo-product` (Red Hat); csv `tempo-operator.v0.21.0-2` | 2026-07-09 |
| Red Hat build of OpenTelemetry | 0.152.0-1 | stable | packagemanifest `opentelemetry-product` (Red Hat); csv `opentelemetry-operator.v0.152.0-1` | 2026-07-09 |
| Loki Operator (Red Hat) | 6.5.1 | stable-6.5 | packagemanifest `loki-operator` (Red Hat); csv `loki-operator.v6.5.1` | 2026-07-09 |
| Red Hat OpenShift Logging | 6.5.1 | stable-6.5 | packagemanifest `cluster-logging` (Red Hat) | 2026-07-09 |
| VerticalPodAutoscaler | 4.21.0 | stable | packagemanifest `vertical-pod-autoscaler` (Red Hat) | 2026-07-09 |
| Custom Metrics Autoscaler (KEDA) | 2.19.0 | stable | versions.yaml (installed via batch stack, M06) | 2026-07-08 |

All entitlement `[OCP]` (COO/Tempo/OTel/Loki/Logging/VPA are Red Hat platform-observability operators). All four observability operators install **AllNamespaces**; **none installed today** (verified: no CSV on cluster). COO owns `UIPlugin` (`uiplugins.observability.openshift.io/v1alpha1`) → console Observe → Dashboards(Perses)/Traces/Logs (docs.redhat.com `red_hat_openshift_cluster_observability_operator/1-latest`).

Cluster reality (verified live 2026-07-09):

- **UWM already ON cluster-wide** — configmap `cluster-monitoring-config` = `enableUserWorkload: true`; UWM Prometheus retention `24h` (configmap `user-workload-monitoring-config`); pods `prometheus-user-workload-0/1` + `thanos-ruler-user-workload-0/1` Running (ns `openshift-user-workload-monitoring`). Owned by portfolio component `platform-portfolio/components/monitoring-uwm`. → per-namespace ServiceMonitor + PrometheusRule work **today**, no new metrics infra.
- **parasol-claims is metrics- and trace-ready** (`apps/parasol-claims/pom.xml` + `application.properties`): Quarkus 3.33.2.1/JDK21; exposes **`/q/metrics`** (`quarkus-micrometer-registry-prometheus`, `quarkus.micrometer.binder.http-server.enabled=true` → `http_server_requests_seconds*` per app); ships `quarkus-opentelemetry` with OTLP exporter **OFF** (`quarkus.otel.sdk.disabled=true`) — M12 flips `QUARKUS_OTEL_SDK_DISABLED=false` + `OTEL_EXPORTER_OTLP_ENDPOINT` (4317 gRPC). Health `/q/health/{live,ready}`. `parasol-web` has the same metrics baseline (`apps/parasol-web/pom.xml`). → **core arc needs no app code change.**
- **Capacity is ample:** 6 nodes (3 control-plane+worker @15.5 CPU/64Gi, 3 worker @15.5 CPU/30Gi) ≈ **93 CPU / 285Gi allocatable** for 8 users (`oc get nodes`). A shared metrics+traces+logs stack (~3 CPU / ~7Gi est.) is negligible here.
- **Object storage exists:** ODF external Ceph — storageclasses `ocs-external-storagecluster-ceph-rbd` (default RWO), `-cephfs` (RWX), **`openshift-storage.noobaa.io`** (S3 OBC); `objectbucketclaims.objectbucket.io` CRD present → LokiStack/TempoStack object backends feasible.
- **KEDA already installed** via the batch stack (M06) — the custom-metric/event autoscaler is present; M06 owns the KEDA hands-on (`docs/research/m06-build-note.md`).

## Spec deltas

- Spec lists "Loki, Tempo+OTel" per the entry state's single-user framing; on a shared cluster these are **shared single installs** (one LokiStack / TempoMonolithic / OTel Collector), per-user isolation via namespace-scoped queries + RBAC — **not per-user stacks**. Per-user cost is only app + load-gen + ServiceMonitor + PrometheusRule.
- Spec "per-user dashboard (console dashboards or Perses/Grafana per current guidance — verify)": current path is **COO Perses** dashboards/UIPlugin; the catalog Grafana operator is **Community** (avoid as a product). Use console Observe → Metrics + COO Perses; not Grafana. (docs.redhat.com COO 1-latest)
- Spec "HPA on CPU/custom metric": OCP ships **no custom-metrics adapter** by default — custom-metric autoscaling = KEDA `ScaledObject` (already installed). Keep M12's HPA hands-on to **CPU (autoscaling/v2)**; treat custom-metric/KEDA as a short decision-tree beat pointing to M06 (avoids overlap — `m06-build-note.md`).
- Entry state "claims app (instrumented build) under load generator in `{user}-dev`": the app now exists (`apps/parasol-claims`, contra the stale note in `m04-build-note.md`) and is instrumented, but **there is no `gitops/entry-states/m12/` chart yet** (only m01-05, m06). Load-gen + ServiceMonitor + OTLP env wiring are net-new entry-state material.
- Spec "trace the slow endpoint; find the N+1 to db": `ClaimResource` has **no N+1 today** (single `findAll`+`count`, `apps/parasol-claims/.../ClaimResource.java`). The N+1 story needs a deliberately-slow endpoint (app work below) or a reframe to "read the JDBC span latency."
- Console: from **4.19 the Developer perspective is no longer enabled by default** (unified console) — all M12 console steps use the single unified Observe section (developers.redhat.com/articles/2025/06/26/openshift-419-brings-unified-console; docs.redhat.com OCP 4.20 web_console).

## Approach recommendations

1. Build M12 in three signal tiers, all **shared** infra: **T1 (zero new footprint)** UWM metrics + PromQL in console Observe → Metrics + a `PrometheusRule` (`monitoring.coreos.com/v1`) alert in `{user}-dev`, fires in Observe → Alerting; **T2** COO + `TempoMonolithic` + one `OpenTelemetryCollector` for the trace-the-slow-request story + a Perses dashboard; **T3 (capacity-gated)** shared `LokiStack` 1x.demo + `ClusterLogForwarder` + COO Logging UIPlugin for "logs across replicas." Log baseline degrades to `oc logs`/console Pod Logs (always-true).
2. New **`observability` portfolio stack** (mirror `stacks/batch`) with components `coo`, `tempo`, `opentelemetry`, and optional `loki`+`cluster-logging` — each an AllNamespaces Subscription (kueue component pattern) + config CRs (UIPlugins, TempoMonolithic, OpenTelemetryCollector, LokiStack). Shared, one install; never per-user.
3. Scale arc = **plain HPA (autoscaling/v2) on CPU** under the load-gen (the star) + **PodDisruptionBudget** quick-win (hands-on) + node-drain honoring the PDB `[INSTRUCTOR-DEMO]`; KEDA custom-metric `ScaledObject` = optional short beat pointing to M06; **VPA = concept-only** (don't let VPA + HPA both manage CPU on one target).
4. Entry state `m12` (Helm chart like `entry-states/m05`): `parasol-claims` + `claims-db` + `parasol-web` in `{user}-dev` with OTLP env wired to the shared collector; a per-user `ServiceMonitor` targeting `/q/metrics`; a tiny load-gen Deployment (curl loop, 50m/64Mi — sized per the "load generator sizing" watchout). Solve state adds HPA + PrometheusRule + PDB (mirror the m05 `.Values.solve` split).
5. Per-user isolation = namespaced `ServiceMonitor`/`PrometheusRule` in `{user}-dev` (UWM scopes rules to the namespace; docs.redhat.com Monitoring stack 4.21 "managing alerts as a developer"). Self-serve alert **routing** (`AlertmanagerConfig`) additionally needs the UWM Alertmanager enabled — a platform toggle on the `monitoring-uwm` component; keep routing optional.

## Mining results

Spec says "none of the old assets does this well → build fresh." Confirmed.

- `adv-app-platform-demo-showroom` **M3 "Platform operations"** (autoscaling/HPA demo; `assets/images/ocp-hpa-*`) → the HPA-under-load demo beat + console screenshot targets. (`docs/research/oldcontent-mining-index.md` §4)
- Nothing else portable; keep the "observe your app / the platform observes itself" framing fresh and **re-verify COO nav every build** (fast-moving area, per spec Mine).

## Open risks

- COO `UIPlugin` exact `spec.type` casing (Dashboards / DistributedTracing / Logging / Monitoring / TroubleshootingPanel) + the Perses dashboard CR — `TODO(verify-on-cluster)` after COO install (`oc explain uiplugin`; alm-examples did not surface UIPlugin). apiVersion `observability.openshift.io/v1alpha1` confirmed via owned CRD.
- `LokiStack` size enum: alm-example ships `1x.small`; smallest is `1x.demo` — confirm at build. Loki is the heaviest add (Vector DaemonSet 1 pod/node ×6 + ~6 Loki pods, ~1.5 CPU/4Gi est.) — trivial here, but the cut candidate for a lean event.
- Tempo retention on shared cluster (spec watchout): `TempoMonolithic` memory/PV backend — cap retention low; `TempoStack` needs an OBC (available).
- Custom-metric HPA overlaps M06's KEDA — keep M12 to CPU HPA + pointer. VPA operator not installed; concept-only.
- Load-gen sizing: over-aggressive load trips UWM/quota — keep concurrency low, cap CPU so the HPA scale-up is visible but bounded.

## Builder/platform appendix — observability stack sketch (verify CRs at build; component pattern = `platform-portfolio/components/kueue/`, stack = `stacks/batch/`)

- **coo:** Subscription `cluster-observability-operator` (channel `stable`, AllNamespaces OperatorGroup) + `UIPlugin` CRs (Dashboards, DistributedTracing, [Logging]).
- **tempo:** Subscription `tempo-product` (`stable`) + `TempoMonolithic` (`tempo.grafana.com/v1alpha1`) with OTLP ingest, monolithic memory/PV backend.
- **opentelemetry:** Subscription `opentelemetry-product` (`stable`) + `OpenTelemetryCollector` (`opentelemetry.io/v1beta1`) receiving OTLP :4317, exporting to Tempo.
- **loki (optional):** Subscription `loki-operator` (`stable-6.5`) + `LokiStack` (`loki.grafana.com/v1`, size `1x.demo`, ODF OBC) + Subscription `cluster-logging` + `ClusterLogForwarder` → Loki; COO Logging UIPlugin.
- **App OTLP env (entry-state, on parasol-claims Deployment):** `QUARKUS_OTEL_SDK_DISABLED=false`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://<collector>.<obs-ns>.svc:4317`.

**App work for app-developer (both OPTIONAL — core arc needs none):** (1) add a deliberately-slow / N+1 endpoint on `parasol-claims` for the trace exercise (e.g. `GET /api/claims/{n}/history` issuing one query per related row); (2) a custom business metric (Micrometer `Counter claims_created_total`) for the "custom metric" PromQL/dashboard beat.

**Demo-flavor angle:** "trace-the-slow-request" 10 min — Observe → Traces (COO), drill web→claims→db spans, point at the slow DB span; alert fires live in Observe → Alerting. (spec Demo arc)

**Timing (90 min workshop):** metrics/PromQL/alert ~30 · trace + dashboard ~25 · logs ~10 · scale (HPA+PDB+drain) ~25. Demo flavor 10-15 min.

---

## Install-deltas addendum (platform-engineer, 2026-07-11)

Installed the observability stack live on `ocp-ws-revamped` (OCP 4.21.22) via the portfolio app-of-apps and built + proved the M12 entry state on **user2**. Domains below are placeholders (privacy guard).

### What's live (permanent — the M12 prerequisite)

`./argocd-bootstrap/install.sh --stacks observability` → `pp-observability` app-of-apps → three child apps **Synced/Healthy**:

| Component | Operator CSV (channel) | Instance | State |
|---|---|---|---|
| cluster-observability-operator | `cluster-observability-operator.v1.5.1` (stable) | UIPlugins `dashboards`, `distributed-tracing` | reconciled |
| tempo | `tempo-operator.v0.21.0-2` (stable) | `TempoMonolithic/traces` (memory) in `observability-workshop` | Ready=True |
| opentelemetry | `opentelemetry-operator.v0.152.0-1` (stable) | `OpenTelemetryCollector/otel` (deployment) in `observability-workshop` | Ready 1/1 |

Stable endpoints (verified): collector `otel-collector.observability-workshop.svc:4317` (gRPC) / `:4318`; Tempo `tempo-traces.observability-workshop.svc:4317`.

### TODO(verify-on-install) resolution table (all 9 resolved, zero remaining)

| # | Marker (file) | Verified value / evidence |
|---|---|---|
| 1 | COO `uiplugin-dashboards` spec.type | CRD enum `[Dashboards, TroubleshootingPanel, DistributedTracing, Logging, Monitoring]`; `Dashboards` reconciled with no sub-config |
| 2 | COO `uiplugin-distributed-tracing` | `DistributedTracing` reconciled with `type` alone — COO auto-discovers Tempo, no sub-ref (`oc get uiplugin distributed-tracing -o` = `{"type":"DistributedTracing"}`) |
| 3 | Tempo `tempomonolithic` ingestion.otlp | `spec.ingestion.otlp.grpc/http.enabled` correct (CR Ready=True); operator Service `tempo-traces` :4317/:4318 |
| 4 | OTel `otel-collector` Service/target | operator Service `otel-collector` :4317/:4318; live config exports to `tempo-traces...:4317` tls.insecure; collector Ready 1/1 |
| 5 | Loki README OBC keys | NooBaa OBC emits cm `BUCKET_NAME`/`BUCKET_HOST`(s3.openshift-storage.svc)/`BUCKET_PORT`(443) + secret `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`; assembled `logging-loki-s3` → LokiStack Ready |
| 6 | Loki `collector-rbac` ClusterRole names | `collect-application-logs` + `collect-infrastructure-logs` exist (read). **Delta:** also need `logging-collector-logs-writer` (write) — added |
| 7 | Loki `lokistack` enums | size `[1x.demo,1x.pico,1x.extra-small,1x.small,1x.medium]` (1x.demo smallest); `storage.schemas` required, version `[v11,v12,v13]`; `tenants.mode [static,dynamic,openshift-logging,openshift-network]` — all as authored |
| 8 | Loki `uiplugin-logging` | spec.type `Logging` (enum) + `spec.logging.lokiStack {name,namespace}` (`oc explain`); reconciled "successfully" |

### End-to-end signal proof (on user2, via the m12 entry state)

- **Trace:** collector `otelcol_receiver_accepted_spans_total{transport="grpc"}=106` and `otelcol_exporter_sent_spans_total{server_address="tempo-traces...",port="4317"}=106`, zero failures. Tempo TraceQL `{ resource.service.name = "parasol-claims" }` returns traces — `GET /api/claims` **94 ms** vs `GET /api/claims/{claimNumber}/history` **995 ms** (the N+1 endpoint is ~10× slower; visible as 6 JDBC spans). `resource.service.name` tag value `parasol-claims` present in Tempo.
- **Metric:** UWM thanos-querier `claims_created_total{namespace="user2-dev",prometheus="openshift-user-workload-monitoring/user-workload"}=38` and `up{service="parasol-claims"}=1` — the per-user ServiceMonitor is scraped by UWM and queryable.

### Optional Loki/Logging tier — proven, then torn down (stays commented-off by default)

Stood up the full tier transiently to verify (loki-operator 6.5.1, cluster-logging 6.5.1): LokiStack **Ready=True** against NooBaa S3, Vector ClusterLogForwarder **Ready/Authorized/Valid**, DaemonSet **6/6** (one per node), Logging UIPlugin reconciled, and **logs queryable** — 10 application namespaces in Loki incl. a `parasol-claims` line from `user2-dev` (`Installed features: [agroal, cdi, hibernate-orm, ...] / Profile prod activated`). **Two real bugs fixed** (both silent — no CR error, only runtime failure): (a) `ClusterLogForwarder.spec.outputs[].lokiStack.target` needs BOTH `name` and `namespace`; (b) the collector SA needs `logging-collector-logs-writer` (write to LokiStack) or every push 403s. Loki stays **commented out of the stack by default** (hard rule 2 — it needs ODF/NooBaa + the manual `logging-loki-s3` secret, so it cannot "install cleanly on ANY cluster"); opt-in = uncomment `apps/loki-logging.yaml` + assemble the secret (README contract).

### Entry-state design decisions

- **parasol-web omitted.** `apps/parasol-web` ships micrometer only (no `quarkus-opentelemetry`), so it cannot emit trace spans — deploying it adds no trace value. The spec entry-state line is "claims app (instrumented build) under load generator," and the real instrumented trace is claims→db (the N+1 `/history`). The full **web→claims→db** distributed trace the objectives mention needs parasol-web OTel instrumentation = **app-developer backlog** (see Open issues).
- **Image tag 1.1** (not the 1.0 pins m01–m05 use) — the instrumented build with `/history` N+1, `claims_created_total`, and OTLP auto-instrumentation.
- **DB ephemeral** (emptyDir, drop-and-create reseed) — M12 is observability, not storage; deterministic 30 claims + 21 events every boot.
- **Alert** is armed-not-firing at the clean baseline (5xx rate), verified loaded by UWM thanos-ruler (`state=inactive health=ok`); the resilience beat trips it. The `openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus` label is NOT needed (default UWM evaluation works).
