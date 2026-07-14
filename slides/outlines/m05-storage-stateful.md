# M05 — Storage & Stateful Apps

## Slide: The database that was a time bomb

- Parasol's claims DB ran all week
- Its data lived in an emptyDir
- One Pod restart wipes everything
- Routine churn, total data loss
- Persistence is the missing piece

Notes: Open with the stakes. The claims database has been running fine, but its storage is an emptyDir — a volume that belongs to the Pod and dies with it. The first node drain, upgrade, or crash destroys every claim. This is not an edge case; Pod churn is normal. The module is the difference between storage that dies with a Pod and storage that outlives it, and running databases on the platform honestly.
Visual: A single "Pod restart" arrow turning a database full of claims into an empty one, red X over the lost data.

## Slide: The storage abstraction chain

- PVC: what your app asks for
- PV: what the platform provisioned
- StorageClass: the recipe it followed
- Dynamic provisioning: request becomes disk
- You write PVCs, never disks

Notes: The three objects and why the separation is the whole idea. A PersistentVolumeClaim is a request in your namespace ("2Gi, ReadWriteOnce"). A PersistentVolume is the actual storage the platform provisioned. A StorageClass is the rules it followed — provisioner, access modes, expansion, reclaim. Dynamic provisioning makes it a one-liner: submit a PVC and a matching PV is created and bound on demand. App teams ask; the platform provisions.
Visual: Reuse concept diagram m05-...-01-storage-chain.svg — Pod → PVC (namespace) → PV (cluster) → StorageClass → storage backend (Ceph).

## Slide: Ephemeral vs persistent is a property of the volume

- emptyDir: lives and dies with the Pod
- PVC: outlives the Pod, cluster-managed
- Same app, same DB, different volume
- Change the volume, change the outcome
- WaitForFirstConsumer: Pending is not broken

Notes: The core beat, and the one attendees feel in the lab. The same database Pod loses or keeps its data based only on what its data volume is — swap emptyDir for a PVC and a Pod restart stops being catastrophic. Also pre-empt the number-one confusion: a new PVC on a WaitForFirstConsumer class sits Pending until a Pod uses it, on purpose, so the disk lands near the Pod. Pending with no consumer is waiting, not failing.
Visual: Two identical DB Pods side by side — one on emptyDir (restart → empty), one on a PVC (restart → intact).

## Slide: Access modes — don't assume

- RWO: one node writes at a time
- RWX: many nodes write at once
- ROX: many read-only mounts
- Not every backend offers RWX
- Read your StorageClasses, don't guess

Notes: Access modes, taught against reality instead of a single-cloud mental model. RWO (single-writer, right for a database) is universal; RWX (shared multi-writer files) exists on some backends and not others; ROX is niche. The rule: do not assume RWX exists — an app that quietly relies on shared volumes fails to schedule where the backend is block-only. On this cluster the default class is RWO and a separate file class offers RWX; you confirm which by reading the StorageClasses. RWX is the right tool for genuinely shared files (a scaled image registry, a shared content directory) and only a problem when it stands in for a database or an object store.
Visual: RWO/RWX/ROX three-panel with node/Pod icons; a checklist "what does MY cluster support? → oc get sc".

## Slide: StatefulSet — identity and storage travel together

- Stable names: pg-sts-0, pg-sts-1
- Headless Service: per-Pod DNS
- volumeClaimTemplate: one PVC per Pod
- Ordered lifecycle, partitioned updates
- Not automatically a replicated database

Notes: When identity matters, a Deployment's interchangeable Pods are wrong. A StatefulSet gives ordinal names that persist across restarts, a headless Service so each Pod has its own stable DNS name, and a volumeClaimTemplate so each Pod gets its own PVC — identity and storage stay bound together. Updates can be staged with a partition (canary one ordinal, then finish). Be honest: two replicas of PostgreSQL are two independent instances, not an HA database — real replication is an Operator's job. The StatefulSet is the plumbing.
Visual: Reuse concept diagram m05-...-02-sts-vs-deployment.svg — Deployment (shared Service, random Pods) vs StatefulSet (headless Service, pg-sts-0/1 each with its own PVC).

## Slide: What you'll do

- Seed claims, then lose them (emptyDir)
- Add a PVC; watch them survive
- Walk PVC → PV → StorageClass
- Run a StatefulSet: identity, DNS, per-Pod volumes
- Partitioned update, init container, online resize

Notes: Set expectations for the hands-on. Attendees seed real claims, watch a Pod restart destroy them, swap the emptyDir for a PVC (a deliberate break-and-fix on the oc set volume command), and watch the same restart leave the data intact. Then they inspect the storage chain and access modes, run a two-replica PostgreSQL StatefulSet, stage a partitioned update to one member, migrate a schema with an init container, and grow a volume online — all in their own project.
Visual: Numbered arc strip: seed → lose → add PVC → survive → inspect → StatefulSet → partition/init/resize.

## Slide: Map to your org — and when not

- Which of your "databases" are actually ephemeral?
- Who owns backup and failover?
- Run databases with an Operator (not a bare StatefulSet)
- RWX: for shared files, not a DB substitute
- Not every workload needs persistence

Notes: Land the transfer and stay honest. Discussion prompts: which dev/test datastores are secretly ephemeral; who restores your in-cluster data and when they last tested it; whether your StorageClass is a clean self-service contract. Then the credibility close — production databases run on the platform through Operators (EDB/CloudNativePG, CockroachDB, MongoDB, Couchbase) that own backup, failover, and upgrades, ideally in their own project; a bare StatefulSet is only the plumbing, and a managed service is the hands-off alternative. RWX is the right tool for genuinely shared files but a poor stand-in for a datastore or object store; and caches belong on emptyDir. Backup is its own capability (OADP, a later module).
Visual: Decision card — raw StatefulSet (primitives) → database Operator (production, its own project), with a managed data service as the hands-off alternative; footnote pointer to the backup module.
