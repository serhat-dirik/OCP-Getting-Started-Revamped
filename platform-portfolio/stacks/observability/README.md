# stack: observability

The platform prerequisite for **M13 — Observability, Health & Scale**. Installs shared, cluster-wide
observability infrastructure as an Argo CD app-of-apps. Everything here is a **single shared install** —
never per-user; per-user isolation is done with namespaced `ServiceMonitor`/`PrometheusRule` and RBAC
(the M13 entry state's job, below).

```bash
./argocd-bootstrap/install.sh --stacks observability
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,observability
```

## What it installs

| Component | Operator (channel) | Config CRs | Wave |
|---|---|---|---|
| `cluster-observability-operator` | `cluster-observability-operator` (`stable`) | `UIPlugin` Dashboards + DistributedTracing (console Observe -> Dashboards/Traces) | 0 |
| `tempo` | `tempo-product` (`stable`) | `TempoMonolithic` (memory backend, OTLP ingest) + the shared `ogsr-observability-workshop` namespace | 0 |
| `opentelemetry` | `opentelemetry-product` (`stable`) | `OpenTelemetryCollector` (OTLP :4317/:4318 -> Tempo) | 1 |
| `loki-logging` *(optional)* | `loki-operator` + `cluster-logging` (`stable-6.5`) | `LokiStack` 1x.demo + `ClusterLogForwarder` + Logging `UIPlugin` | 2 |

**Metrics need nothing here.** User-workload monitoring (UWM) is already on via the always-on
`monitoring-uwm` component in `core-devtools`, so per-namespace `ServiceMonitor` + `PrometheusRule` +
console **Observe -> Metrics/Alerting** work today. This stack adds **tracing** (and optional **logging**)
on top.

## Shared `ogsr-observability-workshop` namespace model

The tracing workloads — the `TempoMonolithic` store and the `OpenTelemetryCollector` — both live in one
shared namespace, **`ogsr-observability-workshop`**. The `tempo` component owns/creates it (Tempo is the
pipeline anchor); the `opentelemetry` stack app runs **one wave later** so the namespace exists before the
collector applies (same pattern as `core-devtools` gitea wave 0 -> git-mirror wave 1 — dependencies are
ordered by sync-wave, not sleep-and-hope). Operators themselves install into their own
`openshift-*-operator` namespaces (AllNamespaces mode); only the workload CRs share `ogsr-observability-workshop`.

The stable in-cluster endpoints this exposes:

- **Collector (apps send traces here):** `otel-collector.ogsr-observability-workshop.svc.cluster.local:4317` (OTLP gRPC), `:4318` (OTLP HTTP)
- **Tempo (collector exports here):** `tempo-traces.ogsr-observability-workshop.svc.cluster.local:4317`

## Footprint

Tracing tier (COO + Tempo memory-backend + collector): **~1–1.5 CPU / ~2.5Gi**. With the optional Loki tier
(Vector DaemonSet one pod/node + LokiStack): **~3 CPU / ~7Gi total** — negligible on the workshop cluster
(~93 CPU / 285Gi allocatable), but Loki is the cut candidate for lean/low-capacity events. Tempo uses the
**memory backend** (traces are ephemeral, bounded by pod memory) so there is no PVC footprint and retention
stays low by construction — the shared-cluster-safe default.

## The M13 entry-state seam (NOT installed here)

This stack is workshop-agnostic. The **per-user** wiring is the M13 entry state's job
(`gitops/entry-states/observability-health-scale/`, built separately) and layers on top of this shared infra:

- Flip OTLP export on `parasol-claims`: `QUARKUS_OTEL_SDK_DISABLED=false` and
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.ogsr-observability-workshop.svc.cluster.local:4317`.
- A per-user `ServiceMonitor` in `{user}-dev` scraping `parasol-claims` `/q/metrics` (UWM picks it up).
- Solve-state extras: a `PrometheusRule` alert, an `HorizontalPodAutoscaler` (CPU), a `PodDisruptionBudget`.

None of that belongs in this portfolio stack — it is user-/story-specific and stays in the workshop layer.

## Optional logging tier

`loki-logging` is **commented out** of `kustomization.yaml`. It needs ODF/NooBaa object storage and the
`logging-loki-s3` Secret contract — see `platform-portfolio/components/loki-logging/README.md`. Uncomment
`apps/loki-logging.yaml` to opt in. Without it, the M13 logs beat degrades to `oc logs` / the console
**Pod -> Logs** tab (always available).

## Verify

```bash
oc get applications -n openshift-gitops -l portfolio.redhat.com/component | grep -E 'cluster-observability|tempo|opentelemetry'
oc get csv -A | grep -E 'cluster-observability|tempo|opentelemetry'         # operators Succeeded
oc get tempomonolithic -n ogsr-observability-workshop                            # traces -> Ready
oc get opentelemetrycollector -n ogsr-observability-workshop                     # otel -> pod Running
oc get uiplugin                                                             # dashboards, distributed-tracing
```

> Verified on install 2026-07-11: the full stack was stood up live on OCP 4.21 (COO 1.5.1, Tempo 0.21.0-2,
> OTel 0.152.0-1, and the optional Loki 6.5.1 / Logging 6.5.1 tier). Every config-CR field that was authored
> from alm-examples/docs is now confirmed against the live CRDs (UIPlugin `spec.type` enum, Tempo
> `spec.ingestion.otlp`, LokiStack size/schema/tenants enums, the Logging UIPlugin `lokiStack` ref) and an
> end-to-end signal was demonstrated: a parasol-claims trace reached Tempo and its custom metric was scraped
> by UWM. Every install-time verification marker is now resolved in-manifest.
