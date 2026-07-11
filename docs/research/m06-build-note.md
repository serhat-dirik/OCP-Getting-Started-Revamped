# M06 build note — Jobs, Batch & Queued Workloads

Date: 2026-07-09 · Author: research-analyst R5 · Spec: 02-MODULE-SPECS §M06 (lines 82-91)
Method: live cluster `ocp-ws-revamped` (OCP 4.21.22), OLM packagemanifests (CSV alm-examples), `oc explain`, live MaaS egress test, docs.redhat.com Red Hat build of Kueue.

## Verified versions
| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| Red Hat build of Kueue operator | 1.3.1 | stable-v1.3 | packagemanifest `kueue-operator` (Red Hat Operators) | 2026-07-09 |
| Custom Metrics Autoscaler (KEDA) | 2.19.0-1 | stable | packagemanifest `openshift-custom-metrics-autoscaler-operator` | 2026-07-09 |

API shapes (verified 2026-07-09):
- **Kueue operator config CR:** `Kueue` (`kueue.openshift.io/v1`), name `cluster`; alm-example spec = `{managementState, config:{integrations:{frameworks:[BatchJob]}}}`. InstallMode **AllNamespaces only**; suggested ns `openshift-kueue-operator`. (packagemanifest CSV)
- **Kueue workload CRDs (operand, `kueue.x-k8s.io/v1beta1`):** ResourceFlavor, ClusterQueue, LocalQueue, Workload, WorkloadPriorityClass. Grounded via docs.redhat.com "Red Hat build of Kueue" (quotas & workloads). CRDs ABSENT on cluster until the operand installs (verified absent).
- **Job (batch/v1, `oc explain`):** completions, parallelism, backoffLimit, activeDeadlineSeconds, ttlSecondsAfterFinished, completionMode(Indexed), suspend, podFailurePolicy, backoffLimitPerIndex, maxFailedIndexes — all present.
- **CronJob (batch/v1):** schedule(req), concurrencyPolicy, startingDeadlineSeconds, suspend, successfulJobsHistoryLimit, failedJobsHistoryLimit, timeZone — all present/GA.
- **KEDA/CMA CRDs (packagemanifest):** `ScaledJob` & `ScaledObject` at `keda.sh/v1alpha1`; operator config `KedaController` (`keda.sh/v1alpha1`, name `keda`, ns `openshift-keda`); TriggerAuthentication, CloudEventSource, HTTPScaledObject(`http.keda.sh/v1alpha1`). NOT installed.
- **MaaS egress:** `https://<maas-endpoint>/v1/models` reachable FROM cluster pods — **HTTP 200 in 0.38s** (ubi9 pod, 2026-07-09). Auth = Bearer from `secret/credentials` key `apitoken` in `openshift-lightspeed`. Live model: `qwen3-14b` (content stays model-agnostic per M01; recorded for build).
- **Namespace:** `user1-batch` does NOT exist yet — entry state / batch stack must create it. Namespaces carry `workshop.redhat.com/user` label (usable for ClusterQueue `namespaceSelector`).

## Spec deltas
- **Quota model:** entry state says "per-user LocalQueues against a quota'd ClusterQueue" (singular). Kueue quota lives ONLY in the ClusterQueue; LocalQueue holds none. A single shared CQ = cross-user starvation, contradicting the watchout "one user's batch can't starve others." → use **per-user ClusterQueue** (each with its LocalQueue). Sketched below.
- **Kueue packaging (spec "verify GA/version"):** operator CSV v1.3.1; config CR `kueue.openshift.io/v1`; workload API `kueue.x-k8s.io/v1beta1` (NOT v1). Entitlement OCP is provisional (D16 dagger) — confirm with the project owner.
- `user1-batch` namespace + all Kueue CRs are net-new platform (the batch stack) — nothing present today.

## Approach recommendations
1. Batch stack: install Kueue operator (AllNamespaces, ns `openshift-kueue-operator`) + `Kueue/cluster` with `integrations.frameworks:[BatchJob]`; then seed ResourceFlavor + per-user ClusterQueue/LocalQueue + `user{N}-batch` ns.
2. Per-user ClusterQueue (NOT shared) with tiny `nominalQuota` so ~2 sample pods fit and the rest pend — makes admission order visible; `preemption.withinClusterQueue: LowerPriority` for visible preemption.
3. Two WorkloadPriorityClasses (batch-low/high); Jobs carry labels `kueue.x-k8s.io/queue-name` + `kueue.x-k8s.io/priority-class`; keep sample pods 200m/256Mi and <2 min (spec watchout).
4. Batch-inference sample: Job POSTs to MaaS `/v1/chat/completions` (egress verified) using the `apitoken` secret; model-agnostic ("cluster's configured model"), tiny batch, ties M23.
5. KEDA is mention-only: reference `ScaledJob` (`keda.sh/v1alpha1`) as the event-driven contrast; do NOT install CMA for M06 unless a queue-depth-scaling demo needs it.

## Mining results
- Spec Mine = fresh. Kueue YAML from docs.redhat.com "Red Hat build of Kueue 1.x" (quotas_and_workloads, cohorts_and_advanced_configurations).
- RHOAI 3.x distributed-workloads docs (Kueue-backed) for the AI-batch narrative.
- developers.redhat.com: "manage LLM evaluation workloads at scale with EvalHub and Kueue" (2026-06-18) + "gang autoscaling on OpenShift with Kueue and ProvisionRequest" (2026-06-08) — current AI-batch talk tracks.
- No OldContent (net-new module).

## Open risks
- Workload API is `v1beta1` (config CR is v1) — spec "API churn" watchout stands; re-verify with `oc explain clusterqueue` at build AFTER operand install.
- Cluster-total nominal quota = Σ per-user CQs (30 users × 500m ≈ 15 cores); size so concurrent admission fits real allocatable capacity; test at target seat count.
- MaaS key is short-lived (RHDP) — batch-inference Job reads the secret at runtime; degrade gracefully on 401 (mirror M01 Lightspeed degradation).
- Kueue entitlement (OCP vs add-on) provisional — confirm before claiming `[OCP]` in rendered content.

## Builder appendix — Kueue layout (config CR from CSV alm-example; workload API v1beta1 per docs.redhat.com). Sizing 5–30 users:
```yaml
apiVersion: kueue.openshift.io/v1              # 1) operator config (one, cluster-scoped)
kind: Kueue
metadata: {name: cluster}
spec: {managementState: Managed, config: {integrations: {frameworks: [BatchJob]}}}
---
apiVersion: kueue.x-k8s.io/v1beta1             # 2) one shared ResourceFlavor (matches any node)
kind: ResourceFlavor
metadata: {name: default-flavor}
---
apiVersion: kueue.x-k8s.io/v1beta1             # 3) two priorities -> visible preemption
kind: WorkloadPriorityClass
metadata: {name: batch-low}
value: 100
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: WorkloadPriorityClass
metadata: {name: batch-high}
value: 1000
---
apiVersion: kueue.x-k8s.io/v1beta1             # 4) PER-USER ClusterQueue (isolation; no cohort = no borrowing)
kind: ClusterQueue
metadata: {name: cq-user1}
spec:
  namespaceSelector: {matchLabels: {workshop.redhat.com/user: user1}}   # binds to user1's ns
  preemption: {withinClusterQueue: LowerPriority, reclaimWithinCohort: Never}
  resourceGroups:
  - coveredResources: [cpu, memory]
    flavors:
    - name: default-flavor
      resources:
      - {name: cpu,    nominalQuota: "500m"}    # ~2 pods @200m  -> 3rd job pends
      - {name: memory, nominalQuota: "512Mi"}   # ~2 pods @256Mi
---
apiVersion: kueue.x-k8s.io/v1beta1             # 5) PER-USER LocalQueue in user{N}-batch
kind: LocalQueue
metadata: {name: user-queue, namespace: user1-batch}
spec: {clusterQueue: cq-user1}
# Job labels: kueue.x-k8s.io/queue-name: user-queue ; kueue.x-k8s.io/priority-class: batch-high|batch-low
# Lesson: submit 5 batch-low -> 2 admitted, 3 pending ; submit 1 batch-high -> preempts 1 low.
```
