# components/oadp — OpenShift API for Data Protection (Velero)

Installs the **OADP operator** (`redhat-oadp-operator`, channel `stable`, OwnNamespace in `openshift-adp`)
and a **`DataProtectionApplication`** wired to an **in-cluster NooBaa (ODF MCG) S3 bucket** — no external
AWS S3 required. Backs the M22 "Resilience, Multi-Cluster & DR" module (backup / restore an app namespace
incl. PVC data). Entitlement `[OCP]` (included with an OpenShift subscription).

## What it creates

| Wave | Object | Why |
|---|---|---|
| 0 | Namespace / OperatorGroup (OwnNamespace) / Subscription | operator install (OADP is OwnNamespace-only) |
| 0 | ServiceAccount + Role/RoleBinding + ClusterRole/Binding (`oadp-bsl-glue`) | least-privilege for the glue Job |
| 1 | `ObjectBucketClaim` `oadp-backups` (bucket `parasol-oadp-backups`) | claims a NooBaa S3 bucket as the backup target |
| 2 | Sync-hook Job `oadp-bsl-glue` | transforms the OBC S3 keys → Velero `cloud-credentials` (INI) + labels a CSI `VolumeSnapshotClass` |
| 3 | `DataProtectionApplication` `parasol-dpa` | reconciles Velero + node-agent; `defaultPlugins: [openshift, csi, aws]`, `nodeAgent` (Kopia/FSB) |

## Prerequisite

**ODF / MCG (NooBaa) must be present** — StorageClass `openshift-storage.noobaa.io` and the in-cluster
`s3.openshift-storage.svc` endpoint. On a cluster without ODF, replace `objectbucketclaim.yaml` + the glue
Job with your own `cloud-credentials` Secret + an external-S3 `BackupStorageLocation` (same DPA contract).

## PVC-data path (build spike decision)

**File System Backup (Kopia, `nodeAgent.enable: true`) is the default** — driver-agnostic, works on the
default RWO Ceph-RBD PVCs, and needs no VolumeSnapshotClass. The `csi` plugin + the auto-labeled
`VolumeSnapshotClass` also enable the CSI-snapshot + Data Mover path where a snapclass exists.

## Plugin note (correction to the M22 build note)

The build note specified `defaultPlugins: [openshift, csi]`. A `provider: aws` BSL (which is how any
S3-compatible target, incl. NooBaa, is addressed) needs the **`aws`** object-store plugin, so this
component uses `[openshift, csi, aws]`. Without `aws`, Velero cannot read/write the bucket.

## Reusability

`--stacks resilience` on any OCP 4.20+ cluster **with ODF** installs this cleanly. Verified against OADP
1.5.7 on OCP 4.21.22.
