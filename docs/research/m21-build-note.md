# M21 build note — Resilience, Multi-Cluster & DR

Date: 2026-07-12 · Author: research-analyst · Spec: `Project-Shared/instructions/02-MODULE-SPECS.md` **§M21 "Resilience, Multi-Cluster & DR"** (Gen3 catalog; Eventing is M20, Virtualization dropped). Entitlement: **[OCP]** for OADP + single-cluster resilience; **[ADD-ON]** for the RHSI section; ACM mention-only.

Method: READ-ONLY on **two** live clusters as `admin` (never `oc login`) — `ocp-ws-revamped` (cluster-qvkd5, `~/.kube/ocp-ws-revamped.config`) and `cluster2` (cluster-km7vw, `~/.kube/cluster2.config`), both OCP **4.21.22 / k8s 1.34.8**: `oc get packagemanifest/csv/crd/storageclass/volumesnapshotclass/csidriver` only, no mutations. Neither OADP nor RHSI is installed → product facts verified via **live OLM packagemanifests (owned-CRD apiVersions, channels)** + docs.redhat.com/developers.redhat.com (docs.redhat.com 403s on direct fetch → reached via WebSearch) + `OldContent/repos/app-connectivity-workshop` + `gitops-catalog`. `versions.yaml` `oadp` (1.5.7) and `rhsi` (2.2.1-rh-1) **re-confirmed live today**; both verified 2026-07-08 (4 days — fresh, <60d); **not edited** per instruction.

## Verified versions

| Product / capability | Version / state | API / mechanism | Source | Date |
|---|---|---|---|---|
| OpenShift (both clusters) | 4.21.22 (k8s 1.34.8) | `stable-4.21` | `oc version` live (qvkd5 + km7vw) | 2026-07-12 |
| **OADP** `[OCP]` | operator **v1.5.7**; **`stable` is the only channel** | Subscription `redhat-oadp-operator`; **install mode OwnNamespace only** | live packagemanifest (qvkd5); versions.yaml | 2026-07-12 |
| OADP → Velero | **Velero 1.16.x** bundled | `velero.io/v1` | WebSearch (openshift/oadp-operator) — verify exact patch at build | 2026-07-12 |
| **DataProtectionApplication** (install CR) | GA | **`oadp.openshift.io/v1alpha1`** | live packagemanifest owned-CRDs | 2026-07-12 |
| Backup / Restore / Schedule / BackupStorageLocation / VolumeSnapshotLocation | GA | **`velero.io/v1`** | live packagemanifest | 2026-07-12 |
| DataUpload / DataDownload (CSI Snapshot **Data Mover**) | GA-with-1.5 | **`velero.io/v2alpha1`** | live packagemanifest | 2026-07-12 |
| PodVolumeBackup / PodVolumeRestore (File System Backup, Kopia/Restic) | GA | `velero.io/v1` | live packagemanifest | 2026-07-12 |
| **NonAdminBackup / NonAdminRestore / NonAdminBSL** (self-service) | **Technology Preview** (OADP 1.5) | `*.oadp.openshift.io/v1alpha1` (CRDs present live) | developers.redhat.com 2025-12-23 | 2026-07-12 |
| DataProtectionTest (BSL/snapshot self-check) | new in 1.5 | `oadp.openshift.io/v1alpha1` | live packagemanifest | 2026-07-12 |
| **RHSI / Service Interconnect** `[ADD-ON]` | operator **v2.2.1-rh-1**; defaultChannel **`stable-2`** | Subscription `skupper-operator` (Skupper v2) | live packagemanifest (qvkd5); versions.yaml | 2026-07-12 |
| RHSI CRs (Skupper v2) | Site, Listener, Connector, Link, AccessGrant, AccessToken, RouterAccess, SecuredAccess, Certificate | **`skupper.io/v2alpha1`** | live owned-CRDs + `app-connectivity-workshop/demo_scripts` | 2026-07-12 |
| **RHSI channel trap** | bare **`stable` AND `stable-1` = v1.9.5-rh-1 (legacy Skupper v1)** | v1 CRs/CLI incompatible with v2 | live packagemanifest | 2026-07-12 |
| OpenShift GitOps (re-materialize-anywhere / "DR superpower") | 1.21.1, Argo CD 3.4 | — | versions.yaml (live-confirmed) | 2026-07-12 |
| Single-cluster resilience primitives `[OCP]` | GA core | PDB `policy/v1`, HPA `autoscaling/v2`, `topologySpreadConstraints`, probes | versions.yaml `ocp_scheduling` + `docs/research/m16-build-note.md` | 2026-07-12 |
| ACM (DR-tier **mention only**) | v2.17.0, channel `release-2.17` | `advanced-cluster-management` (NOT installed) | live packagemanifest | 2026-07-12 |
| MCE | v2.17.0, `stable-2.17` | `multicluster-engine` (NOT installed) | live packagemanifest | 2026-07-12 |
| Submariner (alt L3 multicluster net) | v0.24.0, `stable-0.24` | `submariner` (NOT installed) | live packagemanifest | 2026-07-12 |

**Headline (spec-critical):** OADP install CR is **DataProtectionApplication (`oadp.openshift.io/v1alpha1`)** wrapping **Velero 1.16** (`velero.io/v1` Backup/Restore/Schedule/BSL). It supports **CSI snapshots + Data Mover** (`DataUpload/DataDownload v2alpha1` → object store) **and** File System Backup (Kopia). **Non-Admin self-service backup is Technology Preview**, not GA. RHSI is Skupper **v2** (`skupper.io/v2alpha1`), and the bare `stable` channel is a **legacy-v1 trap** — versions.yaml correctly pins `stable-2`. Both operators + a `core+resilience` profile are **net-new**.

### Cluster/repo reality (verified live 2026-07-12, read-only)

- **Neither OADP nor RHSI installed** on qvkd5 (no `velero.io`/`skupper.io` CRDs) → both are **net-new GitOps installs**.
- **S3 backup target is already in-cluster — the spec's #1 watchout is solved.** ODF/MCG **NooBaa** is present: StorageClass `openshift-storage.noobaa.io`, CRD `objectbucketclaims.objectbucket.io`, `noobaa.io` CRDs. An **OBC → S3 endpoint + creds** is exactly the OADP `BackupStorageLocation` input — **no external AWS S3 needed**. (redhat.com even documents OADP+ODF/NooBaa directly.)
- **CSI snapshots available:** `VolumeSnapshotClass` for both `…-cephfs` and `…-rbd`; default SC `ocs-external-storagecluster-ceph-rbd` (RWO, WaitForFirstConsumer, expansion on), plus `…-cephfs` (RWX). CSI drivers `openshift-storage.{rbd,cephfs}.csi.ceph.com`. → OADP can back the claims-DB PVC via **CSI snapshot + Data Mover to NooBaa**, or **File System Backup**; pick in a build spike (RBD is block/RWO).
- **A real 2nd cluster exists and is reachable:** `cluster2` (km7vw) is a separate OCP 4.21.22 cluster → the spec's `[INSTRUCTOR-DEMO with 2nd cluster if available]` (active-passive / ACM / cross-cluster RHSI) is **feasible, not hypothetical**.
- **Repo:** `gitops/entry-states/` stops at **m14** (no m15–m21). `platform-portfolio/components/` has **no oadp, no service-interconnect**. `platform-portfolio/stacks/` = ai-assist, auth, batch, core-devtools, observability, portal, progressive-delivery, trust, trust-demo — **no resilience stack**. All net-new. Component shape to mirror: `platform-portfolio/components/tempo/` (namespace + operatorgroup + subscription + CR + kustomization).
- **gitops-catalog has a RHSI base but it's mis-channeled:** `service-interconnect-operator/operator/overlays/stable` patches `spec.channel: 'stable'` → **legacy Skupper v1 (v1.9.5)** on this catalog. Must override to `stable-2`. No OADP base exists in gitops-catalog → build OADP fresh from docs (tempo-component shape).
- **Cluster topology gap (shared with M16):** 6 schedulable nodes but **zero `topology.kubernetes.io/zone` labels** (versions.yaml `ocp_scheduling`) → the chaos-drill "spread across zones" needs **synthetic zone labels at bootstrap**, cluster-scoped, not a per-user chart.

## Spec deltas

- **NonAdminBackup is Technology Preview, not GA (OADP 1.5).** The attendee "backup claims ns" beat cannot assume GA self-service. Attendees are namespace-admins, not cluster-admins; a GA path needs the **cluster-admin/instructor** to drive `Backup`/`Restore` against the shared Velero in `openshift-adp`, OR use **NonAdminBackup flagged as TP**. This is M21's central build constraint (mirrors M14's quota-RBAC constraint). DECISION — appendix.
- **OADP install mode = OwnNamespace only** → there is exactly **one** OADP/Velero install (conventionally `openshift-adp`), cluster-wide. "Per-user backup" = **per-namespace `Backup` CRs** against the shared Velero (or per-user NonAdminBackup), never a per-user operator.
- **RHSI "legacy site on RHEL" → simulate as a 2nd OpenShift namespace.** App Connectivity M1 uses a real RHEL VM + `skupper` CLI + `skupper system setup` + `scp` token transfer. Our bootstrap has no RHEL VM; the spec already permits "2nd namespace or instructor cluster." Do **site B = a 2nd namespace** (both Sites are Kube), which also removes the error-prone scp/ssh token hop — the AccessGrant→AccessToken redemption happens in-cluster.
- **RHSI channel must be pinned `stable-2`.** Bare `stable`/`stable-1` install **legacy Skupper v1 (v1.9.5)**; v1's CRs and CLI (`skupper init`) are incompatible with v2 (`skupper.io/v2alpha1`, `skupper system setup`). versions.yaml is correct; the gitops-catalog base is **wrong** — do not copy its overlay verbatim.
- **RHSI is a separate subscription `[ADD-ON]`.** The module must deliver fully (resilience recap + OADP backup/restore + DR tabletop) **with RHSI off**; no `[OCP]` beat may depend on it (D16). The whole cross-site section is flagged + skippable.
- **Chaos drill needs real resilience primitives seeded.** "instructor kills things; attendees' PDB/spread/HPA absorb" requires the entry state to seed a **multi-replica claims deployment with PDB + topologySpreadConstraints + HPA** (recap of M12/M16) — otherwise there is nothing to absorb. Zone-spread needs the synthetic zone labels above.
- **Backup must target a dedicated, deletable namespace.** "delete ns (feel it); restore" cannot delete `{user}-dev` (shared by M01–M05, M09+). Use a dedicated **`{user}-resilience`** namespace so the delete→restore arc is safe.
- **Numbering confirmed:** M21 = Resilience/Multi-Cluster/DR in Gen3 (Eventing = M20, Virtualization dropped) — consistent with `docs/research/m20-build-note.md` and the renumber decoder. No delta.

## Approach recommendations

1. Install both GitOps-native, net-new: `components/oadp` (Subscription `redhat-oadp-operator`/`stable`, OwnNamespace `openshift-adp` + OperatorGroup, one `DataProtectionApplication` with `defaultPlugins:[openshift,csi]` + a **NooBaa-OBC-backed** `BackupStorageLocation`) and `components/service-interconnect` (Subscription `skupper-operator` **channel `stable-2`**); wire into net-new `stacks/resilience` (profile `core+resilience`) — no imperative `oc apply`.
2. Backup target = **in-cluster NooBaa OBC** (ODF MCG) → S3 BSL; back up `{user}-resilience` incl. the claims-DB PVC via **CSI snapshot + Data Mover** (fallback File System Backup/Kopia); restore into the deleted namespace and verify seeded DB rows survived — no external S3.
3. Make the graded backup **GA-safe**: instructor/cluster-admin drives `Backup`/`Restore` on the shared Velero; offer per-user **`NonAdminBackup` only as a clearly-flagged Tech-Preview** optional beat — never gate the lab on TP.
4. RHSI section (`[ADD-ON]`, skippable): two namespaces as Skupper **v2** Sites (`Site`+`RouterAccess`) → `Connector` in site B (claims Postgres) ↔ `Listener` in the app ns, linked by `AccessGrant`→`AccessToken`; **script the token redemption** (spec watchout); app consumes DB transparently; visualize in the Skupper network console + console **Service Interconnect** tab.
5. Entry state seeds a genuinely resilient claims stack (≥2–3 replicas + PDB + TSC + HPA + persistent seeded DB) so the instructor chaos drill absorbs; close with a time-boxed **DR-tier tabletop** (backup-restore vs active-passive vs active-active) framing **GitOps re-materialization as the DR superpower** (ties M10), optionally demoed onto cluster2.

## Mining results

- **`OldContent/repos/app-connectivity-workshop/showroom/content/modules/ROOT/pages/m1/module-01.{0,1,3,4}.adoc`** (Module 1 — "Connect apps across hybrid cloud") → **direct-port the RHSI narrative + lab shape** (spec's "App Connectivity M1 (direct port)"): the **VAN / L7-vs-VPN** framing (quote-quality bullets on why a VAN beats a VPN), the **Site / Listener / AccessGrant / AccessToken** concept boxes, the token-redemption diagram, and the "**curl fails → build the VAN → curl succeeds**" redemption arc + network-console exploration. Re-home travels-db → Parasol claims Postgres; RHEL site → 2nd namespace. License **none** (redhat-ads-tech) — mine ideas, re-implement, **credit in CREDITS.md**.
- **`OldContent/repos/app-connectivity-workshop/demo_scripts/demo_scripts/{openshift_site,listener,grant}.yaml`** → **current `skupper.io/v2alpha1` CR shapes** (Site `ha:true`/`linkAccess:default`; Listener `host/port/routingKey`; AccessGrant `redemptionsAllowed/expirationWindow`) — matches the live packagemanifest owned-CRDs; use as the CR skeleton.
- **`OldContent/App Connectivity Workshop.pdf`** (+ `…One Stop.pdf`) → the **accreting-architecture diagram** + **traffic-direction product map** (cross-env / east-west / north-south) for the resilience-ladder and DR-tier concept diagrams; "complete delivery kit" pattern (mining index §2a; M15/M18 already use this trick).
- **`OldContent/repos/gitops-catalog/service-interconnect-operator/**`** → RHSI Subscription/OperatorGroup GitOps skeleton — **but its `overlays/stable` patches channel to legacy `stable`**; re-implement with **`stable-2`**. Pattern-only; credit.
- **`OldContent/MAD Roadshow - Dev Track Content Overview.pdf`** (+ `.pptx`) → the per-module rubric (Business / Dev-challenge / Goal / Products) + Globex→Parasol technique; MAD is mapped to old-numbering "M21" in the mining index — decode by topic (the rubric/narrative, not tech).
- **OADP: no OldContent asset covers it → build fresh from docs.** Best fits: developers.redhat.com "**Getting started with OpenShift APIs for Data Protection**" (2025-12-23), redhat.com blog "**OADP + OpenShift GitOps — application disaster recovery**" (exact match for the GitOps-as-DR-superpower concept), and "**Backup and restore stateful apps on OpenShift using OADP and ODF**" (NooBaa/ODF target = our cluster).
- **ACM: pointer-only** (spec). ACM 2.17 docs for the DR-tier mention (ACM ships cluster backup/restore via OADP + Submariner for network + policy/GitOps). **Do not build ACM labs.**

## Open risks

- **NonAdminBackup = Technology Preview** (OADP 1.5, developers.redhat.com 2025-12-23) — do not gate the graded lab on it; may graduate in 1.6 — re-verify GA at build.
- **No live OADP/RHSI verification possible** (neither installed) — DPA/BSL field names, restore-of-deleted-namespace semantics, Data-Mover vs FSB behavior, Skupper link formation, and all console click-paths carry `// TODO(verify-on-cluster)` / `[CAPTURE-VERIFY]` until the `resilience` profile is up. Exact Velero patch inside 1.5.7 also needs a live check.
- **OADP↔OCP 4.21 support matrix not crisply confirmed** — the operator IS live in the 4.21 Red Hat Operators catalog (`stable` = v1.5.7, strong evidence) but the formal compatibility matrix + the "included at no additional cost" wording were not verified this pass; confirm at build via the **OADP FAQ** (access.redhat.com/articles/5456281) + Operator Life Cycles. Entitlement `[OCP]` is taken from versions.yaml/spec (D16 authority).
- **RHSI channel trap** — bare `stable`/`stable-1` = legacy Skupper v1 (v1.9.5); the component MUST pin `stable-2`. v1↔v2 CRs/CLI are incompatible.
- **Backup storage sizing/lifecycle** — one NooBaa OBC bucket per event; ×N namespace backups + restore data movement is real I/O. Size the bucket, set a backup TTL, and **`ws reset` must purge Velero `Backup`/`Restore` (+ any NonAdmin*) CRs, PVCs, and Skupper `Site`/`Link` objects** from user namespaces or a re-run leaks state.
- **CSI-snapshot vs File-System-Backup tradeoff** unresolved (RBD is block/RWO) — needs a build spike to pick the reliable PVC-data path for the "verify data survived restore" checkpoint.
- **Chaos drill needs synthetic zone labels** (cluster has zero zone labels, per M16) — cluster-scoped bootstrap step, coordinate with M16's synthesis.
- **`versions.yaml` has no ACM/MCE/submariner block** — fine while ACM is mention-only; add an `acm`/`mce` entry only if the cluster2 instructor DR demo is built.

## Builder/platform appendix

### Decisions for the owner
1. **Backup actor (primary):** cluster-admin/instructor `Backup` on shared Velero (**GA**, recommended for the graded beat) vs per-user **`NonAdminBackup`** (**Tech Preview**, attractive self-service — flag it).
2. **PVC-data path:** CSI snapshot + Data Mover to NooBaa vs File System Backup (Kopia). Spike on RBD (block/RWO) before committing.
3. **RHSI topology:** two namespaces (default, self-contained) vs cluster2 for a real cross-cluster link (instructor).
4. **Wire cluster2 (km7vw)?** It's a live 4.21.22 cluster — enables the active-passive / ACM / cross-cluster RHSI `[INSTRUCTOR-DEMO]`. Optional.
5. **Resilience-recap depth:** how much M12/M16 (PDB/probes/TSC/HPA) to re-run live vs reference.

### Platform (platform-engineer)
- Net-new **`components/oadp`**: ns `openshift-adp` + OperatorGroup (**OwnNamespace**) + Subscription `redhat-oadp-operator`/`stable` + `DataProtectionApplication` (`oadp.openshift.io/v1alpha1`, `configuration.velero.defaultPlugins:[openshift,csi]`, `nodeAgent.enable:true` for FSB) + a NooBaa `ObjectBucketClaim` + `BackupStorageLocation` (S3, from OBC secret/endpoint) + label a `VolumeSnapshotClass` `velero.io/csi-volumesnapshot-class=true`.
- Net-new **`components/service-interconnect`**: Subscription `skupper-operator` **channel `stable-2`** (never bare `stable`) + per-user Site enablement; skip if the `[ADD-ON]` section is disabled at provisioning.
- Net-new **`stacks/resilience`** app-of-apps; profile **`core+resilience`** in bootstrap; **synthetic zone labels** at bootstrap (shared with M16). cluster2 optional for instructor DR.

### Entry state — `gitops/entry-states/m21/` (Helm, like m05/m06; net-new)
- **`{user}-resilience`**: a resilient claims stack — Deployment ≥2–3 replicas + `PodDisruptionBudget` + `topologySpreadConstraints` + `HorizontalPodAutoscaler` + a **persistent claims-DB PVC seeded with deterministic rows** (the restore-verification anchor).
- **`{user}-site-b`** (for the RHSI beat): a standalone claims Postgres to expose via `Connector`.
- **ws-meta:** `purgeNamespaces` runs `oc delete all,pvc --all` + must additionally prune `backups/restores.velero.io`, `nonadmin*.oadp.openshift.io`, and `sites/links/listeners/connectors/accessgrants/accesstokens.skupper.io`; `conflictsWith` same-namespace modules.

### App / image work
- The claims service must reach its DB via a **Service name that can be swapped to the RHSI `Listener`** (e.g. host `claims-db` resolves to the local Service normally, and to the Listener virtual endpoint in the cross-site exercise) — mirrors the App-Connectivity travels→db pattern. Seed rows deterministic for the survived-restore `✔ Verify`.

### Demo arc (spec)
- delete-namespace → full Velero restore (feel-the-loss → data back) + cross-site RHSI link (DB from site B) — **12 min**.

### Timing (90 min workshop)
- resilience recap map (PDB/probes/TSC/HPA) ~15 · OADP concept + backup `{user}-resilience` incl. PVC ~20 · delete + restore + verify data ~15 · RHSI cross-site link `[ADD-ON]` ~20 · chaos drill `[INSTRUCTOR-DEMO]` ~10 · DR-tier tabletop ~10. Demo flavor 12 min.

### Relevant absolute paths
- Spec §M21: `Project-Shared/instructions/02-MODULE-SPECS.md`
- Direct-port mine (RHSI narrative + CRs): `OldContent/repos/app-connectivity-workshop/showroom/content/modules/ROOT/pages/m1/` and `OldContent/repos/app-connectivity-workshop/demo_scripts/demo_scripts/`
- RHSI GitOps skeleton (fix channel→stable-2): `OldContent/repos/gitops-catalog/service-interconnect-operator/`
- Component shape to mirror (OADP/RHSI): `platform-portfolio/components/tempo/`
- Portfolio stacks + values: `platform-portfolio/stacks/`
- Versions source of truth (oadp / rhsi / ocp_scheduling): `versions.yaml`
- Templates followed: `docs/research/m14-build-note.md`, `docs/research/m18-build-note.md`, `docs/research/m20-build-note.md`
- Kubeconfigs used (read-only): `~/.kube/ocp-ws-revamped.config` (qvkd5), `~/.kube/cluster2.config` (km7vw)

Sources:
- Live packagemanifests/CRDs/storage on `ocp-ws-revamped` + `cluster2` (`oc get packagemanifest redhat-oadp-operator|skupper-operator|advanced-cluster-management|multicluster-engine|submariner`, `oc get crd`, `oc get storageclass/volumesnapshotclass/csidriver`) — 2026-07-12
- Getting started with OpenShift APIs for Data Protection — developers.redhat.com/articles/2025/12/23/getting-started-openshift-apis-data-protection (NonAdmin = Tech Preview; OADP 1.5+)
- OADP FAQ — access.redhat.com/articles/5456281 · OpenShift Operator Life Cycles — access.redhat.com/support/policy/updates/openshift_operators (OADP valid under OCP subscription)
- OADP + OpenShift GitOps application disaster recovery + Backup/restore stateful apps with OADP & ODF — redhat.com/en/blog (GitOps-as-DR; NooBaa target)
- Why Red Hat Service Interconnect version 2 — developers.redhat.com/blog/2025/02/03/why-red-hat-service-interconnect-version-2 · Using Service Interconnect 2.0/2.1 — docs.redhat.com/en/documentation/red_hat_service_interconnect (Skupper v2 CRs, console)
- `Project-Shared/instructions/02-MODULE-SPECS.md` §M21; `versions.yaml` (`oadp`, `rhsi`, `ocp_scheduling`); `docs/research/{m16,m20}-build-note.md`; `docs/research/oldcontent-mining-index.md`
