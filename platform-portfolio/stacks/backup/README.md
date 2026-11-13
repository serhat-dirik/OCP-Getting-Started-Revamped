# stacks/backup — OADP backup and restore

App-of-apps installed with `--stacks backup`. One child:

| App | Entitlement | Purpose |
|---|---|---|
| `pp-oadp` (`components/oadp`) | `[OCP]` | OADP/Velero + in-cluster NooBaa S3: back up and restore an app namespace, PVC data included |

## Prerequisite

ODF / MCG (NooBaa), for the in-cluster S3 bucket (`components/oadp/README.md`). Without it the
ObjectBucketClaim never binds and `pp-oadp` stays OutOfSync/Missing.

## Not part of the workshop install

No module uses OADP — resilience-multicluster-dr teaches app-level failover. `bootstrap/install.sh`
therefore never adds this stack. It lived in the `resilience` stack until 2026-11-13; on a cluster without
ODF it held `tools/ws/adm ready` red, because that check waits for every Argo application to be Healthy.
