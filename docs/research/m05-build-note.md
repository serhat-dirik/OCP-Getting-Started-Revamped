# M05 build note — Storage & Stateful Apps

Date: 2026-07-09 · Author: research-analyst R5 · Spec: 02-MODULE-SPECS §M05 (lines 71-80)
Method: live cluster `ocp-ws-revamped` (OCP 4.21.22), `oc get sc/quota`, `oc explain`, ODF docs, Red Hat Ecosystem Catalog.

## Verified versions
| Product | Version/Ref | Source | Date |
|---|---|---|---|
| OpenShift | 4.21.22 | `oc version` | 2026-07-09 |
| Storage backend | ODF external-mode (Ceph RBD + CephFS + NooBaa) | `oc get sc` | 2026-07-09 |
| PostgreSQL image | `registry.redhat.io/rhel9/postgresql-16:latest` | Red Hat Ecosystem Catalog (657b0386…) | 2026-07-09 |

StorageClasses (`oc get sc`, 2026-07-09) — **this is ODF/Ceph, not cloud EBS**:
| Name | Provisioner | Default | Expansion | BindingMode | Reclaim | Access |
|---|---|---|---|---|---|---|
| ocs-external-storagecluster-ceph-rbd | rbd.csi.ceph.com | **true** | true | **WaitForFirstConsumer** | Delete | RWO (fs) |
| ocs-external-storagecluster-ceph-rbd-immediate | rbd.csi.ceph.com | – | true | Immediate | Delete | RWO (fs) |
| ocs-external-storagecluster-cephfs | cephfs.csi.ceph.com | – | true | Immediate | Delete | **RWX**+RWO |
| openshift-storage.noobaa.io | noobaa.io/obc | – | – | Immediate | Delete | object (OBC) |

Grounded facts (verified 2026-07-09):
- Access modes (docs.redhat.com ODF managing-PVCs): RBD filesystem = RWO; RBD **block** = RWO+RWX; CephFS = RWO+**RWX**; RWOP supported on all; **ROX NOT supported in ODF**. There IS a real RWX filesystem option (cephfs) — richer than the spec's EBS assumption.
- Default SC = ceph-rbd, `WaitForFirstConsumer` → PV not provisioned until a consuming pod schedules (PVC stays Pending). Teach this explicitly.
- Resize: `allowVolumeExpansion=true` on all Ceph SCs. CLI `oc patch pvc <n> -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'`; Console PVC → Actions → Expand PVC. Online (no restart). Field `spec.resources.requests.storage` present (`oc explain`).
- StatefulSet partitioned update (`oc explain statefulset.spec.updateStrategy.rollingUpdate`, 4.21): `partition <integer>` present — "pods ordinal Replicas-1..Partition updated; Partition-1..0 untouched." Sibling `maxUnavailable` is **alpha** (MaxUnavailableStatefulSet gate) — DO NOT use. `updateStrategy.type`: RollingUpdate (default) | OnDelete.
- Postgres image: in-cluster imagestream `openshift/postgresql` tops at `15-el9` (→ rhel9/postgresql-15); **no 16 tag**. `registry.redhat.io/rhel9/postgresql-16:latest` EXISTS and is pullable (registry.redhat.io present in global `pull-secret`). SCL env contract: `POSTGRESQL_USER|PASSWORD|DATABASE|ADMIN_PASSWORD`; runs arbitrary non-root UID (restricted-PSA safe).
- Reclaim: all SCs `Delete` → deleting PVC deletes PV + Ceph volume. **StatefulSet volumeClaimTemplate PVCs (`data-<sts>-<ordinal>`) are NOT deleted on STS delete.** No PVCs exist in user ns today (clean baseline).

## Spec deltas
- **Access-mode teaching:** spec watchout implies default provisioner is RWO-only (EBS gp3 mental model). Here default (rbd) = RWO but **cephfs SC gives RWX** — update the RWO/RWX slide to match ODF reality.
- **Postgres version:** spec/story wants PostgreSQL 16; in-cluster imagestream only ships 15. Use `registry.redhat.io/rhel9/postgresql-16` directly (pullable), NOT the `openshift/postgresql` imagestream.
- **Binding mode:** default is `WaitForFirstConsumer` (not Immediate) — the "inspect StorageClass" step must call out PVC-Pending-until-pod.

## Approach recommendations
1. Verify script detects the default SC dynamically (never hardcode the name); assert `allowVolumeExpansion=true` and record `volumeBindingMode`.
2. StatefulSet: `registry.redhat.io/rhel9/postgresql-16` (digest-pinned), 2 replicas + headless Service + volumeClaimTemplates; SCL env + arbitrary UID = restricted-PSA safe.
3. Teach access modes honestly: default rbd = RWO (fits single-writer DB); show cephfs as the RWX option and when RWX is (rarely) right for app data.
4. Resize exercise: expand via Console Actions→Expand and CLI patch; show online expansion; surface WaitForFirstConsumer (PVC Pending until a pod consumes it).
5. Partitioned update: set `spec.updateStrategy.rollingUpdate.partition` to roll only the top ordinal, verify, then `partition:0` to finish; never touch alpha `maxUnavailable`.

## Mining results
- Spec Mine = "none of the old decks cover this — build fresh from docs." Confirmed. Primary sources: OCP 4.21 Storage docs + ODF managing-PVCs (access modes, resize table).
- `apps/parasol-web/.../application.properties` → health-path convention for wiring the init-container/app; `parasol-claims` datasource env (from M04) for the DB connection.
- No OldContent port; cite the docs.redhat.com ODF access-mode table for the RWO/RWX concept slide.

## Open risks
- `:latest` on postgresql-16 floats — pin to a digest in the entry state; verify the digest at build.
- **ws reset must explicitly purge StatefulSet volumeClaimTemplate PVCs** (`data-<sts>-N`) — they survive STS deletion; add to `ws-meta.yaml` purge list.
- WaitForFirstConsumer: a PVC-only demo with no pod shows Pending — set expectations in troubleshooting.
- ODF external-mode capacity is shared cluster-wide (5 PVC/user × N users on one Ceph); keep sample volumes ≤1–2Gi and watch total PVC count at seat scale.
