# M16 build note — Deployment Targets & Scheduling  `[OCP]`

> ⚠ **Zero-downtime beat SUPERSEDED (2026-07-16).** The graceful-shutdown recipe below (preStop +
> `terminationGracePeriodSeconds` + Quarkus `quarkus.shutdown.timeout`) was a MIS-DIAGNOSIS. Grounded
> live on C1 2026-07-16: the real cause is the shared `claims-db` being reseeded on every parasol-claims
> boot (Hibernate `drop-and-create`) → a rolling-update pod silently discards data written since the last
> boot (proven: a written value reverts to its seed after one pod restart), compounded by a cold-start
> CPU throttle (27s@500m → 17s@2). Fix = `schema-management=none` + a decoupled seed-once-at-deploy Job +
> a raised CPU limit; the graceful `SIGTERM` drain the image already does was never the cause. The shipped
> content, entry-state, and verify now teach this. The scheduling/placement sections of this note stand.

Date: 2026-07-12 · Author: research-analyst · Spec: 02-MODULE-SPECS §M16 (lines 201-210) · Renumber: OLD M14 → NEW M16 (decoder `docs/module-catalog-renumber-2026-07-10.md`)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22, k8s 1.34.8) READ-ONLY as `admin` — node/MachineSet/DaemonSet inventory, `oc explain` on every scheduling/strategy/PDB/sidecar field, platform-observer RBAC read; repo inspection (apps + entry-states + workshop-config); docs.redhat.com OCP 4.20 EUS Nodes; kubernetes.io (native sidecar GA); quarkus.io (graceful shutdown). versions.yaml (2026-07-08) trusted for OCP; native-sidecar GA row added 2026-07-12.

> **Everything M16 teaches is core OpenShift/Kubernetes — GA on this cluster.** No operator, no subscription. The whole research risk is not "does the API exist" (it all does) but **"does the RHDP cluster have the node topology the entry state assumes"** — and it does not. That is the load-bearing finding.

## Verified versions

| Product / feature | Version / status | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-12 |
| Kubernetes | 1.34.8 | — | `oc version` (live) | 2026-07-12 |
| Native sidecar (init `restartPolicy: Always`) | **GA** (stable `apps/v1`) | core | `oc explain …initContainers.restartPolicy` (live, field present + "sidecar" lifecycle described); kubernetes.io GA since **k8s 1.33** | 2026-07-12 |
| Scheduler primitives — nodeSelector / node+pod (anti)affinity / topologySpreadConstraints / taints+tolerations | GA | core | `oc explain` (all fields live); docs.redhat.com OCP 4.20 Nodes "Controlling pod placement onto nodes (scheduling)" | 2026-07-12 |
| Deployment strategy (RollingUpdate maxSurge/maxUnavailable · Recreate) | GA `apps/v1` | core | `oc explain deployment.spec.strategy` (enum `Recreate,RollingUpdate`; defaults 25%/25%) | 2026-07-12 |
| Graceful shutdown (`terminationGracePeriodSeconds`, `lifecycle.preStop`, SIGTERM) | GA | core | `oc explain` (both fields live); Quarkus `quarkus.shutdown.timeout` (quarkus.io) | 2026-07-12 |
| PodDisruptionBudget | GA `policy/v1` (incl. `unhealthyPodEvictionPolicy` enum `AlwaysAllow,IfHealthyBudget`) | core | `oc explain pdb.spec` (live); docs.redhat.com OCP 4.20 Nodes | 2026-07-12 |
| DaemonSet | GA `apps/v1` | core | live inventory (21 DaemonSets across `openshift-*`) | 2026-07-12 |
| MachineSet / MachineAutoscaler | GA `machine.openshift.io` — **observed-only, and hollow here** | — | live: 1 MachineSet desired=0, only 3 master Machines, no MachineAutoscaler/ClusterAutoscaler | 2026-07-12 |

All entitlement **`[OCP]`** (core platform primitives; no operator installs). `versions.yaml` gained a verified `native_sidecar` row (2026-07-12); the `ocp` row (2026-07-08) is still <60 days and matches live.

### Cluster reality (verified live 2026-07-12, READ-ONLY)

- **6 SCHEDULABLE nodes, single flavor split.** `control-plane-cluster-abcde-{1,2,3}` carry **both** `control-plane`/`master` **and** `worker` roles with **no `NoSchedule` taint** (15.5 CPU / 64Gi each); `worker-cluster-abcde-{1,2,3}` are `worker` (15.5 CPU / ~30Gi each). ≈ **93 CPU / ~285Gi allocatable**, 250 pods/node. Capacity is ample for the scheduling exercises at 30 users.
- **No node shaping exists.** `oc get nodes` shows **zero taints**, **no `topology.kubernetes.io/zone` or `/region`**, **no `node.kubernetes.io/instance-type`**, **no custom `workload=`/pool labels**. Only `kubernetes.io/hostname` is present on all 6 nodes. → the spec's entry-state assumption is unmet (see Spec deltas #1).
- **Platform = BareMetal.** The sole MachineSet `cluster-abcde-mv7nt-worker-0` is **desired=0 / current=0**; only the 3 **master** Machines exist as `Machine` objects — **the 3 worker nodes are NOT Machine-API-managed**. No MachineAutoscaler, no ClusterAutoscaler. → you cannot "scale a MachineSet" to make a pool here; node shaping = direct `oc label node` / `oc adm taint node` (see Spec deltas #2).
- **Native sidecar is GA on-cluster:** `initContainers[].restartPolicy` is in the **stable `apps/v1`** schema and `oc explain` describes the "continually restarted until all regular containers terminate … referred to as a sidecar" lifecycle. Answer to the spec's "confirm GA vs beta": **GA** (k8s 1.33; default-on gate since 1.29).
- **21 DaemonSets to inspect** (the "read the platform's own node agents" beat): `desired=6` (every node) — `openshift-ovn-kubernetes/ovnkube-node` (CNI), `openshift-monitoring/node-exporter`, `openshift-machine-config-operator/machine-config-daemon`, `openshift-dns/dns-default`+`node-resolver`, `openshift-cluster-node-tuning-operator/tuned`, `openshift-multus/multus`, `openshift-storage/*csi*-nodeplugin` (Ceph), **`stackrox/collector`** (ACS runtime, from the M08 trust stack); and **`desired=3` control-plane-only** DaemonSets (`ironic-proxy`, `machine-config-server`, `network-node-identity`) that demonstrate a DS using **nodeSelector + tolerations** to target only some nodes — a perfect live tie-in to the taint/affinity beat.
- **platform-observer already covers the MachineSet beat, not the DaemonSet beat.** `gitops/workshop-config/templates/platform-observer-clusterrole.yaml` grants read on `nodes`, `machinesets`/`machines` (comment literally: "M16 scaling/infrastructure inspection"), storageclasses, cluster operators, etc. — but **NOT `apps/daemonsets`** and no cross-namespace `pods`. So attendees can `oc get machinesets`/`oc get nodes` today, but **cannot** `oc get ds -A` read-only (see Spec deltas #3).
- **M12 already ships a PDB + node-drain demo.** `gitops/entry-states/m12/templates/solve-endstate.yaml` renders a `PodDisruptionBudget` (`policy/v1`, `minAvailable: 1`) on `parasol-claims` plus a `[INSTRUCTOR-DEMO]` node drain that honors it (m12-build-note). Direct overlap with M16's "set PDB; watch drain respect it" (see Spec deltas #5).
- **The multi-component base + load-gen already exist.** `gitops/entry-states/m12/` runs `parasol-claims` (image `parasol-images/parasol-claims:1.1`, shared, no per-user build) + `claims-db` + a tiny **`ose-cli` curl-loop load generator** (50m/64Mi) in `{user}-dev`. That claims Deployment has **no `strategy`, no `terminationGracePeriodSeconds`, no `preStop`, no affinity, no TSC** — i.e. M16 genuinely adds every hardening field. `apps/` holds 5 Parasol services (`parasol-web`, `-claims`, `-fraud`, `-notifications`, `-service-template`) → a real web→claims→fraud→db multi-component app is available.

## Spec deltas

1. **Entry state "cluster has labeled/tainted node groups prepared (e.g. `workload=batch:NoSchedule` pool, zone labels)" — UNMET.** There are no taints, no zone labels, and no pools on this cluster today. Node labels/taints are **cluster-scoped**, so per the entry-state contract (`gitops/entry-states/README.md` rule 2) they can live in **neither** the per-user entry chart **nor** the per-user workshop-config layer — they must be created **once at bootstrap** (platform layer). Feasibility verdict below.
2. **"platform teams shape clusters (MachineSets … MachineAutoscaler)" — observable but hollow.** The one MachineSet is empty and does not manage the bare-metal workers; there is no autoscaler. The `[INSTRUCTOR-DEMO: taint a pool live]` **cannot** be "scale/edit a MachineSet" — it must be a direct `oc adm taint node` / `oc label node`. Teach MachineSets as concept + an honest read-only peek at the placeholder object ("on a cloud cluster this has N replicas you scale; here it's a stub — this is the shape, this is what platform teams do with it").
3. **"inspect the cluster's node agents (DaemonSets) via platform-observer" — RBAC gap.** platform-observer lacks `apps/daemonsets` read. Add `{apiGroups:["apps"], resources:["daemonsets"], verbs:[get,list,watch]}` (mirrors the existing machinesets grant) so `oc get ds -A` works read-only for attendees; otherwise this beat is `[INSTRUCTOR-DEMO]`.
4. **"topology spread across zones" — no real failure domains.** RHDP here is single-AZ bare metal (no zone labels). Either (a) bootstrap **synthesizes** `topology.kubernetes.io/zone` on the 6 nodes (safe label-add; frame honestly as lab topology), or (b) teach TSC/anti-affinity on the real `kubernetes.io/hostname` (spread across the 6 nodes) — recommended as the always-true story, with zones optional.
5. **PDB + instructor-drain overlaps M12 (and M21 recap).** M12's solve-endstate already teaches PDB + drain-honors-PDB; M21 recaps resilience (probes/PDB/spread/HPA). Deconflict: **M16 owns the deep placement story** (anti-affinity + TSC + drain + PDB together, and PDB×RollingUpdate interaction / `unhealthyPodEvictionPolicy`); M12 keeps the scale-side quick-win; M21 recaps. Avoid re-teaching the basic PDB from scratch.
6. **Native sidecar framing:** the spec's "confirm GA vs still-beta" resolves to **GA** (k8s 1.33). Content should state GA, not "tech preview / know-it's-coming."
7. **Terminology watchout (not a product change):** `oc get nodes --show-labels` will display `node-role.kubernetes.io/master` on screen (k8s still sets it). Prose must say "control plane" (04-STYLE-GUIDE §5 bans "master"); do not rename the label — refer to it correctly and, if shown, note it's the legacy role label.

## Approach recommendations

1. **Bootstrap (not the entry chart) pre-creates one shared, tainted+labeled batch pool** — `oc label node <worker> workload=batch` + `oc adm taint node <worker> workload=batch:NoSchedule`; the attendee toleration+selector exercise is then per-user, namespaced, concurrent-safe, and needs no live taint.
2. **Teach spread on `kubernetes.io/hostname` (real, 6 nodes) as the always-true anti-affinity/TSC story;** optionally synthesize `topology.kubernetes.io/zone` at bootstrap for a clearly-labelled "across zones" narrative.
3. **Compose a fresh `entry-states/m16/` in `{user}-dev`** reusing the m12 claims+db+load-gen shapes (mutual `conflictsWith` m01-05/m09-13); the `solve` split adds affinity+TSC+tuned RollingUpdate+preStop/gracePeriod+PDB.
4. **Zero-downtime beat = preStop `sleep` + `terminationGracePeriodSeconds` + Quarkus `quarkus.shutdown.timeout`, measured with a failure-counting load-gen** before/after a roll; contrast Recreate; cross-ref M10 for canary/blue-green (Rollout already in `gitops/promotion/.../rollouts/`).
5. **Extend platform-observer with `apps/daemonsets` read** so the node-agent inspection is attendee-runnable; keep MachineSet/autoscaler concept + read-only peek, and do "taint a pool live" as `[INSTRUCTOR-DEMO]` via `oc adm taint`, never MachineSet scaling.

## Mining results

Spec Mine = "fresh; fragments in old ops decks." **Confirmed — the decks yield essentially nothing for pod scheduling.**

- **Ops/overview decks** (`Provisioning Guide and Support.pdf`, `Cloud Native Architectures Workshop - *.pdf`, `MAD Roadshow - Dev Track Content Overview.pdf`, `App Connectivity Workshop.pdf`): `pdftotext` grep for scheduling/affinity/taint/toleration/topology/PDB/rolling/graceful/DaemonSet/MachineSet/drain returns only workshop-**calendar** "scheduling" hits + one line "minimal disruption of existing applications" (CNA Content Overview p.80). **Nothing portable.** Build the concept + labs fresh from docs.
- **`redhat-cop/gitops-catalog`** (platform-portfolio mine): `gpu-operator-certified/.../aws-gpu-machineset` and `sandboxed-containers-operator/.../aws/setup-machineset.yaml` are MachineSet+taint examples for **GPU / dedicated pools** → useful as **concept illustration only** for "GPU/licensed-software pools via MachineSet" (they are **AWS-specific and not runnable** on this bare-metal cluster). Do not port as lab.
- **`redhat-ads-tech/parasol-insurance-manifests`** `app/` Helm (deployment+route+**hpa**) — the Parasol claims deploy shape M16 layers scheduling fields onto; re-implement (license = none; mining-index §3, §6).
- **In-repo reuse (preferred over OldContent):** the m12 `load-generator.yaml` (`ose-cli` curl loop — extend it to tally non-2xx/connection failures), the m12 `solve-endstate` PDB, `gitops/promotion/claims-config-template/rollouts/claims-rollout.yaml` (the M10 canary form = the "where Rollouts fit" cross-ref), and the 5 `apps/` Parasol services for the multi-component app.
- **Do NOT mine the "M16" rows in 05-REFERENCES / oldcontent-mining-index** (Service Mesh 2.x deck, App Connectivity, `ossm-gateway-demo`, `service-mesh-workshop-code`): those are **OLD numbering** = today's **M18/M15**, unrelated to scheduling.

## Open risks

- **Batch-pool sizing (spec watchout):** one dedicated node serving ~30 users' toleration pods fits comfortably **iff** the batch component is tiny (~50-100m; one node = 15.5 CPU / 250 pods → 30 pods ≈ 1.5-3 CPU). Make "quota/size the batch pod" the lesson; verify concurrent placement at target seat count. If bigger per-user batch is wanted, dedicate 2 nodes (leaves 4 general).
- **Node taint/label is one-time cluster-scoped state, not GitOps-per-user** — needs an **idempotent bootstrap step** plus a **verify-script check that the pool exists** (fail closed if the node was recycled/relabelled, or the toleration exercise silently schedules anywhere and the lesson is lost). `// TODO(verify-on-cluster)` the exact node chosen (avoid tainting a control-plane node; use a `worker-*`).
- **Events readability (spec watchout):** the teaching signal is the `FailedScheduling` event (`0/6 nodes are available: N node(s) had untolerated taint {workload=batch}…`); surface via `oc get events --field-selector` / `oc describe pod`. Readable, but scope the query so 30 users' events don't drown the target.
- **No real multi-zone / failure domain** — any "spread across zones" is synthetic; be explicit in content that RHDP is single-AZ bare metal (credibility rule).
- **PDB/drain three-way overlap (M12 / M16 / M21)** — settle ownership at build so the same demo isn't taught three times.
- **`unhealthyPodEvictionPolicy` + PDB during a rolling update** is a subtle interaction (a PDB can stall a drain/roll if `minAvailable` == replicas) — verify the chosen replica/`minAvailable`/`maxUnavailable` math on-cluster before content so the drain demo actually proceeds.
- **`ose-cli:latest` in the load-gen** — the m12 pattern pins `:latest`; re-pin/verify at build (drift risk), and confirm the failure-counting variant still runs under the restricted SCC.

## Builder / platform appendix

**Teaching goals (spec):** direct pods (nodeSelector/affinity/anti-affinity); spread (TSC); tolerations for dedicated nodes; read scheduler events; strategy choice (RollingUpdate params vs Recreate; canary→M10); graceful shutdown (gracePeriod/preStop/SIGTERM — the missing half of zero-downtime); DaemonSets (+ read the platform's own); native sidecar exists; PDB; how platform teams shape clusters (MachineSets/pools/MachineAutoscaler; `[INSTRUCTOR-DEMO]` taint a pool live).

**Exercise arc (Parasol framing, ~75 min):**
- `[~20m]` Placement: `nodeSelector` → node/pod **affinity** → **anti-affinity** forces the 2-3 claims replicas onto distinct `kubernetes.io/hostname`; read the scheduler `FailedScheduling` event when it can't; kill a node's pods `[observation]` and watch reschedule.
- `[~10m]` **topologySpreadConstraints** across hostnames (real) — and across synthetic `topology.kubernetes.io/zone` if bootstrapped.
- `[~10m]` **Dedicated pool:** the batch component gets `tolerations` **+** `nodeSelector: {workload: batch}`; verify placement onto the batch node. Teaching point (docs.redhat.com Nodes): a toleration only **permits**, it does not **attract** — you need the label+selector too, else the pod lands anywhere.
- `[~15m]` **Strategy:** tune RollingUpdate `maxSurge`/`maxUnavailable`, roll under the load-gen; add `preStop` + `terminationGracePeriodSeconds` + Quarkus graceful shutdown, compare dropped-request counts **before/after** (true zero downtime); contrast **Recreate**. Cross-ref M10 for canary/blue-green.
- `[~15m]` **DaemonSets** (inspect `ovnkube-node`/`node-exporter`/`machine-config-daemon` read-only) → native-sidecar sidebar ("know they exist", GA) → **PDB** + `[INSTRUCTOR-DEMO]` drain respects it; MachineSet/autoscaler concept + read-only peek; `[INSTRUCTOR-DEMO]` `oc adm taint` a pool live.

**Entry state `gitops/entry-states/m16/` (Helm, per-user, `{user}-dev`):**
- `values.yaml`: `user`, `clusterDomain`, `solve` (mirror m12).
- `templates/`: multi-component Parasol stack (`parasol-web` + `parasol-claims` @ 2-3 replicas + optionally `parasol-fraud` + `claims-db`), all shared prebuilt images (no per-user build); a **batch component** WITHOUT toleration at entry (attendee adds it) — reuse the M06 monthly-statement Job or a trivial worker Deployment; a **failure-counting load generator** (extend the m12 `ose-cli` loop). `solve`/`ws solve` renders the end state: podAntiAffinity + TSC + tuned RollingUpdate + `preStop`/`terminationGracePeriodSeconds` + PDB.
- `ws-meta.yaml`: `purgeNamespaces: [${USER}-dev]`; `conflictsWith: [m01,m02,m03,m04,m05,m09,m10,m11,m12,m13]` — **mutual**, so add `m16` to each of those charts' `conflictsWith` (same-namespace policy, ADR-0001 amendment). `m06`/`m07`/`m08` are disjoint namespaces → leave alone.

**Platform (bootstrap, cluster-scoped, one-time, idempotent — NOT an entry chart):**
- Batch pool: `oc label node <a worker> workload=batch` + `oc adm taint node <same worker> workload=batch:NoSchedule` (label evicts nothing; `NoSchedule` only blocks new untolerated pods). Choose a `worker-*` node, not a control-plane node.
- Optional: synthesize `topology.kubernetes.io/zone={a,b,c}` across the 6 nodes for the zone-spread narrative.
- RBAC: extend `platform-observer-clusterrole.yaml` with `apps/daemonsets` (get/list/watch).
- Verify: a check that the batch pool (label+taint) and any synthetic zones exist; fail closed.

**App-developer:**
- `parasol-claims` graceful shutdown: set `quarkus.shutdown.timeout` (e.g. 20-30s) so in-flight HTTP drains on SIGTERM; health probes already ship. The zero-downtime recipe (verified): readiness fails first → `preStop sleep` (endpoint-propagation delay) → in-flight requests finish within the timeout → exit; `terminationGracePeriodSeconds ≥ preStop delay + shutdown timeout + buffer` (~30s comfortable).
- Load-gen: a variant that tallies non-2xx **and connection failures** during a roll (e.g. `curl -w '%{http_code}'` + counters, or a tiny Quarkus/bash worker) — this is what makes the before/after dropped-request contrast measurable.

**Demo arc (spec, 10 min):** "dedicated nodes for the right workloads" (batch component snaps onto the tainted pool via toleration+selector) + zero-downtime roll (preStop+graceful under the load-gen, dropped-request counter stays at 0). Both feasible once the pool is bootstrapped.

**Cross-refs / non-refs:** M10 (Rollouts canary/blue-green — the progressive-delivery half of "strategies"; Rollout manifest already in-repo). M06 (batch component / Kueue — different mechanism: Kueue quota in `{user}-batch`, not node taints; no direct conflict). M04 (requests/limits "scheduling effect" preview) and M14 (quota math) set up this module. **ADR-0003-m16-* is OLD-M16 = Service Mesh (now M18); no ADR governs scheduling.**
