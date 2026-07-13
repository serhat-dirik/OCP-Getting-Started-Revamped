# M16 — Deployment Targets & Scheduling

## Slide: From scheduled-wherever to placed-on-purpose

- Parasol's claims API lands wherever it fits
- A batch job fights the API for the same CPUs
- A routine rollout drops customer requests
- None of it is a bigger cluster — it's control
- Placement is a decision, not a lottery

Notes: Open on the concrete pain. Parasol's claims API lands wherever the scheduler happens to drop it, a monthly-statement batch job elbows the live API off the same CPUs, and a routine rollout quietly drops a handful of customer requests every time it runs. This module is how you take control: where each pod lands, how replicas spread so one dead node can't take the service down, which workloads get dedicated capacity, and how a deploy finishes without a customer noticing. Same app, same cluster — but by the end the API is spread across the cluster, the batch job runs on its own nodes, and a rollout keeps serving throughout. The one idea under all of it: placement is a decision you make, not a lottery you accept.
Visual: A "before" cluster: pods scattered at random across nodes, a batch box and an API box crammed onto the same node (red "contention"), and a deploy arrow leaking a couple of dropped-request dots.

## Slide: The scheduler in one mental model

- Every pod: FILTER then SCORE, then bind
- Filter: which nodes CAN run it (requests, taints, selectors)
- Score: which survivor is BEST (room, spread)
- No survivor → Pending + FailedScheduling event
- The currency is REQUESTS, not usage

Notes: You don't need the scheduler's internals — you need one two-step pipeline that runs for every pod. Filter throws out every node that can't run it: not enough unreserved CPU or memory measured by the pod's requests, a taint it doesn't tolerate, a nodeSelector or affinity that doesn't match. Score ranks the survivors — most room, best spread, anti-affinity satisfied — and binds to the winner. If no node survives, the pod stays Pending and the scheduler writes a FailedScheduling event that names the reason node by node — reading that event is the whole skill. The currency in the filter is requests, not usage and not limits: a pod that requests 200m is placed as if it always uses 200m; a pod that requests nothing can be packed onto a full node. Requests also set QoS (Guaranteed/Burstable/BestEffort), which decides eviction order.
Visual: Reuse concept diagram m16-...-01-scheduler-pipeline.svg — Pending pod → FILTER → SCORE → BIND, with a red branch "0 survive → Pending + FailedScheduling."

## Slide: Direct pods — who seeks, who repels

- Affinity / nodeSelector: the POD seeks (attract)
- Taint: the NODE repels
- Toleration: only PERMITS — it does not attract
- Dedicated pool needs taint + toleration + selector
- podAntiAffinity: never two replicas on one node

Notes: There are two families of placement control, and confusing them is the most common scheduling mistake there is. Affinity is the pod reaching toward a node — nodeSelector is the blunt form, nodeAffinity adds required/preferred, podAntiAffinity points at other pods ("never two of me on a node") to spread replicas. A taint is the node pushing pods away: NoSchedule means nothing lands unless it tolerates the taint. Here's the trap that catches everyone: a toleration only permits, it does not attract. A pod that tolerates the batch taint may land on the batch node, but the scheduler is just as happy to put it anywhere else. To actually pin a workload to a dedicated pool you need all three: a taint (keep others off), a toleration (be allowed on), and a nodeSelector (be sent there). Add the selector alone and the pod goes Pending on the untolerated taint.
Visual: Reuse concept diagram m16-...-02-seek-vs-repel.svg — left "affinity pulls the pod toward a labelled node"; right "a taint pushes pods away; a toleration is a permitted-but-not-attracted arrow."

## Slide: Spread across failure domains

- Anti-affinity: blunt "no two on a node"
- topologySpreadConstraints: EVEN spread across a domain
- Domain = any node label (hostname, zone, region)
- maxSkew = how uneven you'll tolerate
- DoNotSchedule (hard) vs ScheduleAnyway (soft)

Notes: Anti-affinity is a blunt "no two on one node." topologySpreadConstraints is the precise version: keep replicas evenly spread across a domain, where the domain is any node label — hostname (spread across nodes), a zone label (spread across failure zones), a region. maxSkew is how uneven you'll tolerate — maxSkew 1 means no domain holds more than one pod above the least-loaded. whenUnsatisfiable is the teeth: DoNotSchedule makes the spread a hard requirement (a breaking pod stays Pending); ScheduleAnyway makes it a strong preference (spread if you can, never block a deploy). The honest note for this workshop: real zones need real failure domains a single bare-metal cluster doesn't have — hostname spread is the always-true story, and where you see a zone label it was synthesized on the workshop nodes. On a cloud you'd point at the provider's real topology.kubernetes.io/zone.
Visual: Three nodes (or three zones) each holding one replica evenly, with a maxSkew=1 caption; a fourth would-be pod bouncing off with "DoNotSchedule → Pending" vs sliding in with "ScheduleAnyway".

## Slide: Dedicated pools — the trio in practice

- Platform taints a pool: keep everything off
- Your workload tolerates it: allowed on
- Your workload selects it: sent there
- Miss the selector → Pending (untolerated taint)
- GPU / batch / licensed-software pools work this way

Notes: This is where the who-seeks/who-repels idea becomes a recipe. A platform team taints a pool of nodes (NoSchedule) so ordinary pods stay off — a GPU box, a node licensed for a commercial database, a batch pool. To run YOUR workload there, it needs a toleration (permission past the taint) and a nodeSelector or affinity (direction to the pool). In the lab you feel the failure mode directly: add the selector alone and the batch worker goes Pending with "untolerated taint" — the selector sent it to the pool node but the taint repels it. Add the toleration and it snaps onto the pool. Selector to send it, toleration to permit it — you need both. This is exactly how expensive or special hardware earns its keep: the taint keeps freeloaders off, the toleration-plus-selector puts the right workload on.
Visual: A three-step strip: (1) platform taints the pool, (2) pod + toleration = permitted, (3) pod + selector = directed; with a red inset "selector alone → Pending."

## Slide: Zero-downtime is two-sided

- maxUnavailable: 0 — surge before retire, capacity flat
- Recreate — for single-writers (deliberate gap)
- preStop + grace — drain the endpoint before SIGTERM
- The app's half: handle SIGTERM, finish in-flight
- A PDB makes a node drain wait its turn

Notes: A Deployment doesn't just run pods, it replaces them — and how it replaces them has a downtime consequence. RollingUpdate with maxUnavailable 0 is the load-bearing setting: it surges a new pod to ready before retiring an old one, so ready-pod count never dips (you watch it hold flat through a roll). Recreate is correct for a single-writer database — a deliberate gap so two copies never run at once. But maxUnavailable 0 only guarantees capacity; it doesn't guarantee a terminating pod releases in-flight connections cleanly. That's the two-sided recipe: the Deployment's half is a preStop hook (drain the endpoint before SIGTERM) plus a grace period; the app's half is handling SIGTERM — fail readiness, finish in-flight, then exit. Miss either and a roll still leaks a few requests. Finally a PodDisruptionBudget protects voluntary disruptions: a node drain must respect minAvailable, so it waits its turn instead of taking your last replica — and minAvailable equal to the replica count deadlocks the drain.
Visual: Two panels — top "maxUnavailable:0" with a flat "3/3 ready" line through a rollout; bottom a drain arrow hitting a PDB shield labelled "minAvailable 1 → wait, don't breach."

## Slide: How platform teams shape the cluster

- DaemonSets: one pod per node (the node-agent pattern)
- The CNI, monitoring, machine-config ARE DaemonSets
- Native sidecar (GA): init container, restartPolicy Always
- MachineSets: the object that builds the pools
- You read these; creating a pool is cluster-wide

Notes: The pools and agents you work around are built with the same primitives you just learned. DaemonSets run one pod per node — the node-agent pattern — and the cluster's own plumbing is built this way: the CNI (ovnkube-node), the monitoring node-exporter, the machine-config daemon are all DaemonSets, one on every node. Some target only a subset of nodes using the very nodeSelector-plus-tolerations you learned — a control-plane-only agent, for instance. A native sidecar is an init container with restartPolicy Always: it starts first and keeps running alongside your app for the pod's whole life — GA on OpenShift, the pattern a mesh proxy or log shipper uses; know it exists. MachineSets are the declarative "how many nodes of this shape" object: on a cloud a platform team scales one to grow a pool, labels and taints its nodes, and a MachineAutoscaler sizes it to demand — that's how the batch pool you pinned onto was made. You read all this via a read-only role; creating and tainting a pool is the instructor's segment because it's cluster-wide.
Visual: A node grid with a DaemonSet agent icon on every node; one agent only on the control-plane row (nodeSelector); a side callout "MachineSet → labels + taints → the pool you target."

## Slide: What you'll do — and map to your org

- Read placement; force replicas apart; read a refusal
- Spread across nodes (and, with one knob, zones)
- Pin the batch worker onto a dedicated pool
- Roll under load with capacity held flat; add a PDB
- If that node died now — replica elsewhere, guaranteed?

Notes: Set expectations for the hands-on, all in the attendee's own claims-app namespace, then land the transfer. You read how the scheduler placed the pods and confirm it against a Scheduled event; force the API replicas apart with required anti-affinity and read the FailedScheduling event when the scheduler can't oblige; spread them evenly with topologySpreadConstraints across nodes, and with one changed key across zones; pin the batch worker onto a dedicated pool the honest way — feeling the Pending a nodeSelector alone earns, then fixing it with the toleration; make a rollout zero-downtime where the Deployment can (maxUnavailable 0 holding capacity flat) and protect it with a PodDisruptionBudget that blocks an eviction rather than breach its floor. Take the questions back: if the node under your busiest service died right now, is a replica already running elsewhere — guaranteed, or just probably? Is your expensive hardware running the workload you bought it for and nothing else? And do your deploys drop requests — does anyone even know?
Visual: Numbered arc strip: read/force-apart → spread → dedicated pool (break-fix) → zero-downtime roll + PDB; footnote pointer to the GitOps at Scale module for canary/blue-green.
