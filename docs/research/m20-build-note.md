# M20 build note — Eventing (Knative Eventing on OpenShift Serverless)

Date: 2026-07-12 · Author: research-analyst · Spec: `Project-Shared/instructions/02-MODULE-SPECS.md` **§M20 "Eventing Deep-Dive & Serverless Workflows"**. The 2026-07-12 Block-D reorder has **landed**: this module IS **M20** (right after M19 Serverless), Virtualization is dropped, and the spec, catalog, and decoder are all renumbered.

Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22 / k8s 1.34.8) — READ-ONLY as `admin` (never user5). Serverless is **not installed** (no serverless/knative CSVs, no `KnativeEventing`/`KnativeServing` CRs, no `*.knative.dev` API groups) → eventing facts verified via **OLM catalog + docs.redhat.com Serverless 1.37 doc-set (via search; docs.redhat.com 403 on fetch) + `OldContent/repos/gitops-catalog/serverless-operator`**. `versions.yaml` `serverless`/`serverless_logic`/`streams_kafka` re-confirmed live today; **not edited** (all fresh 2026-07-08).

## Verified versions

| Product / capability | Version / state | API / mechanism | Date |
|---|---|---|---|
| OpenShift | 4.21.22 (k8s 1.34.8) | — | 2026-07-12 |
| **OpenShift Serverless** `[OCP]` | operator **v1.37.1**, channel **stable** (pins `stable-1.29`…`stable-1.37`) | `serverless-operator` Subscription | 2026-07-12 |
| — Knative **Serving** | **1.16** | `KnativeServing` | 2026-07-12 |
| — Knative **Eventing** (GA) | **1.17** | `KnativeEventing` | 2026-07-12 |
| — Knative **for Apache Kafka** | **1.17** | `KnativeKafka` | 2026-07-12 |
| — `kn` / Kourier | **1.16** / 1.16 | CLI + ingress | 2026-07-12 |
| serverless-operator owned CRDs | `KnativeServing`, `KnativeEventing`, `KnativeKafka` | install-time CRs | 2026-07-12 |
| `KnativeServing`/`KnativeEventing` CR | install CR | **`operator.knative.dev/v1beta1`** (ns `knative-serving`/`knative-eventing`) | 2026-07-12 |
| `KnativeKafka` CR | Kafka-backed eventing | **`operator.serverless.openshift.io/v1alpha1`** (`spec.channel`, `spec.source` toggles) | 2026-07-12 |
| **Broker / Trigger** | GA | **`eventing.knative.dev/v1`**; Trigger `spec.filter.attributes`, `spec.subscriber.ref`, `spec.delivery.deadLetterSink` | 2026-07-12 |
| Default broker class | **MTChannelBasedBroker** (in-memory `InMemoryChannel`) — subscription-free | `Broker` (no `spec.config`) | 2026-07-12 |
| **Channel / Subscription / InMemoryChannel** | GA | **`messaging.knative.dev/v1`** | 2026-07-12 |
| **Sources** (PingSource, ApiServerSource, SinkBinding, ContainerSource) | GA | **`sources.knative.dev/v1`**; Kafka via `KafkaSource` | 2026-07-12 |
| Knative **Service** (subscriber/sink) | GA | **`serving.knative.dev/v1`** — Trigger wakes a ksvc from scale-to-zero | 2026-07-12 |
| **OpenShift Serverless Logic** (SonataFlow) `[OCP]` | **GA since Serverless 1.33**; operator **`logic-operator` v1.38.0**, `stable` | SonataFlow + `kn-workflow` CLI + runtime/mgmt console + VSCode ext | 2026-07-12 |
| **Streams for Apache Kafka** `[ADD-ON]` | `amq-streams` **v3.2.0** (name "AMQ Streams" banned §5) | needed only for `KnativeKafka` | 2026-07-12 |
| New in 1.37 | Eventing authz policies = Tech Preview; Python Functions runtime = GA | — | 2026-07-12 |

Cluster/repo reality (2026-07-12):
- **Serverless not installed**; **`platform-portfolio/` has no serverless/knative stack** → GitOps install is **net-new**.
- **Entry-states stop at `m13`** — no m19/m20 chart.
- **No `claims-processor` app.** `apps/parasol-claims` + `apps/parasol-fraud` have **no CloudEvents/Knative/reactive-messaging dependency** — emit/consume is net-new app work.
- **Name clash:** `apps/parasol-claims/…/ClaimEvent.java` already exists — a JPA audit entity, not a CloudEvent. Builder must disambiguate.

## Spec deltas

- **Numbering reconciled (2026-07-12).** The Block-D reorder has landed: Eventing IS **M20** across `02-MODULE-SPECS.md`, `08-MODULE-CATALOG.md`, the repo roadmap/navs, and the `docs/module-catalog-renumber-2026-07-10.md` decoder (Gen 3 section). Virtualization (old M20) is dropped entirely; AI-Assisted Dev moved M27 → M24. Any pre-2026-07-12 "M24 = Eventing" / "M20 = Virtualization" text decodes by topic + date.
- **Serverless Logic GA is RESOLVED** — spec §M20 watchout + `versions.yaml serverless_logic` note ("GA/TP unverified") are out of date: GA since Serverless 1.33, `logic-operator` v1.38.0 on `stable`, with console + `kn-workflow` CLI + VSCode ext. Correct the note string at next versions.yaml touch.
- **Entry state over-assumes** ("claims-processor ksvc deployed (M19 end state); broker + SonataFlow ready; source seeded"): none exists. Module-independence requires the M20 entry-state to materialize ALL of it — Serverless + KnativeEventing + a Broker + the consumer ksvc + a seeded source — without assuming M19 ran.
- **Kafka path must use Red Hat Streams, not community strimzi** (`amq-streams`, `[ADD-ON]`); the gitops-catalog `KnativeKafka` overlay defaults `channel.enabled: false`.
- **Scope split is a live decision:** full §M20 bundles core Eventing + SonataFlow + optional Kafka. With Eventing now right behind M19, whether the SonataFlow deep-dive stays in M20 or defers is unsettled — confirm with owner.

## Approach recommendations

1. **Install GitOps-native, net-new:** `platform-portfolio/components/serverless` (Subscription `serverless-operator`/`stable` + OperatorGroup + `KnativeServing` + `KnativeEventing`, `operator.knative.dev/v1beta1`), wire into `core+serverless` app-of-apps — no imperative `oc apply`.
2. **Pre-empt Argo CRD-before-CR failure:** sync-wave the operator ahead of the `KnativeServing`/`KnativeEventing` CRs (+ ServerSideApply / SkipDryRunOnMissingResource).
3. **Concrete Parasol demo:** `parasol-claims` POSTs a `com.parasol.claim.submitted` CloudEvent to the namespace Broker on `POST /api/claims` → Trigger A filters on type/fraud-score to the fraud consumer, Trigger B fans out to an audit sink → kill the consumer to show retries + `deadLetterSink`.
4. **Make the M19 composition the money shot:** the consumer is a **Knative Service** targeted by `Trigger.spec.subscriber.ref` → an event **wakes it from scale-to-zero**; teach **broker/trigger vs channel/subscription** as a real delivery/fan-out/filter decision table.
5. **Default path subscription-free** (in-memory MTChannelBasedBroker); gate the Kafka broker (`KnativeKafka` + Streams) and the SonataFlow workflow as clearly-flagged `[ADD-ON]` / deep-dive so the module runs fully on OCP-included Serverless.

## Mining results

- `OldContent/repos/gitops-catalog/serverless-operator/**` → the GitOps install shape to re-implement (operator/base Subscription+OperatorGroup+Namespace, overlays/stable channel patch, instance/knative-serving + instance/knative-eventing CRs, and the `KnativeKafka` overlay). **Credit in CREDITS.md.**
- `OldContent/repos/parasol-insurance` (redhat-ads-tech) ⭐ → the domain EDA narrative (email→Kafka intake→router→claim flow). Re-implement as CloudEvents `claim.submitted` → broker → filtered triggers. Ideas only (unlicensed) — credit.
- `OldContent/repos/parasol-insurance-manifests` → deploy-shape reference (external secret, HPA) for the optional Kafka section.
- `OldContent/repos/rh-mad-workshop/…/globex-serverless` → serverless-module Helm/lab shape (globex→Parasol port).
- **CNA Workshop M6** PDF → lab-arc reference for serverless/eventing (confirm exact module at build).
- `gitops-catalog/strimzi-kafka-operator` → Kafka-operator GitOps shape — pattern only; swap to Red Hat `amq-streams`.
- docs.redhat.com Serverless 1.37 doc-set → authoritative citations; anchor to 1.37.

## Open risks

- **Numbering reconciled (2026-07-12 reorder landed)** — Eventing is M20 across specs, catalog, decoder, roadmap, and navs; author against M20.
- **No live eventing verification possible now** — cluster has no Serverless. Broker/Trigger/DLQ behavior, retry counts, console click-paths carry `// TODO(verify-on-cluster)` / `[CAPTURE-VERIFY]` until the `serverless` profile is up.
- **Per-user broker sizing ×N** — in-memory MTChannelBasedBroker + eventing control-plane per ns ×~30 users is unbudgeted; prefer one shared Broker per user namespace; measure before committing timing/quota.
- **Net-new app work on two services** — CloudEvent emit in `parasol-claims` + a consuming ksvc. Quarkus decision: `quarkus-funqy-knative-events` vs plain REST + CloudEvents SDK.
- **Kafka path is `[ADD-ON]`** (separate Streams subscription) — fully optional/flagged; default demo must never require it.
- **SonataFlow footprint** — if the deep-dive stays in M20, `logic-operator` v1.38.0 + SonataFlowPlatform + workflow Postgres per user is real weight; GA + console confirmed, ×N footprint + scope are the risks.
- **`versions.yaml serverless_logic` note now inaccurate** — correct at next edit.

## Builder/platform appendix

**Decisions for owner:** (1) M20 scope — core Eventing only, or keep SonataFlow deep-dive + optional Kafka? (2) consumer identity — reuse `parasol-fraud` vs a dedicated `claims-processor` ksvc. (3) broker topology — one shared Broker per user ns (recommended) vs per-app. (4) Quarkus eventing style — funqy vs REST+CloudEvents SDK.

**Platform:** net-new `platform-portfolio/components/serverless` (operator + KnativeServing + KnativeEventing); profile `core+serverless`. Optional `components/streams-kafka` (`amq-streams`) + `KnativeKafka` overlay behind a `kafka` profile. Net-new `gitops/entry-states/m20/` (Helm, like m05) materializing a Broker + consumer ksvc + a seeded source (PingSource, or a claim-submit Job) so the module stands alone.

**App/image:** `parasol-claims` emit a CloudEvent on `POST /api/claims` (reuse `claims_created_total`/`claim_event` hook points; avoid the `ClaimEvent` JPA name clash); a consumer ksvc (fraud scoring) + a tiny dead-letter sink for the DLQ beat.

**Demo arc (§M20):** filtered routing + DLQ + (optional) live workflow instance, ~12 min; scale-from-zero consumer waking on an event is the M19+M20 payoff.

**Timing (90 min):** eventing model + broker/trigger-vs-channel/subscription ~20 · emit+trigger+filter ~25 · retry/DLQ break-fix ~15 · (optional) SonataFlow ~15 · Kafka `[ADD-ON]` ~10 · wrap + decision guide ~5.

### Relevant absolute paths
- Spec §M20: `Project-Shared/instructions/02-MODULE-SPECS.md`
- Numbering decoder (reconciled, Gen 3 section): `docs/module-catalog-renumber-2026-07-10.md`
- GitOps install mine: `OldContent/repos/gitops-catalog/serverless-operator/`
- Apps to extend: `apps/parasol-claims/`, `apps/parasol-fraud/`
- Template: `docs/research/m14-build-note.md`

Sources:
- OpenShift Serverless Logic GA (developers.redhat.com/articles/2024/10/09/openshift-serverless-logic-ga)
- About OpenShift Serverless 1.37 / 1.36 release notes / Eventing-Triggers 1.35 (docs.redhat.com; via search)
- Using Triggers (knative.dev/docs/eventing/triggers)
