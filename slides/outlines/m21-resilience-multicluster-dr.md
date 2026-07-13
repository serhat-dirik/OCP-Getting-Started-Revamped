# M21 — Resilience, Multi-Cluster & DR

## Slide: Resilience keeps you up — DR brings you back

- Parasol's claims tier survives a pod crash and a node drain — replicas, PDB, spread, HPA (M01/M12/M16)
- That does NOTHING for a deleted namespace, a corrupt database, or a lost cluster
- The resilience LADDER: pod → node → zone → cluster → region
- Single-cluster resilience owns the bottom rungs; DR owns the top rungs
- This module is the top rungs: back up data, connect sites, decide DR tiers

Notes: Open on the distinction, because it's the whole module. Parasol's claims tier is genuinely resilient — three replicas, a PodDisruptionBudget, topology spread across nodes, an autoscaler. That reflex, built in M01, M12, and M16, absorbs the common failures: a pod crashes and the Deployment replaces it; a node is drained and the PDB paces the eviction so a quorum stays up. But "we have three replicas" does nothing the moment the failure is a fat-fingered oc delete, a corrupt database, a dead cluster, or a region outage — because what you lost is the DATA and the cluster itself, and no number of replicas brings those back. Think of it as a ladder: pod, node, zone, cluster, region. The bottom three rungs are single-cluster resilience, and you already own them. The top two — a destroyed namespace, a lost cluster — are disaster recovery, and they need a copy that lives somewhere else: a backup in an object store, a link to another site, or a platform declared in Git that rebuilds anywhere. Resilience and DR are different disciplines; this module is the DR half, built on top of the resilience you already have.
Visual: A vertical ladder, five rungs bottom-to-top: "① pod fails," "② node fails," "③ zone fails," "④ cluster / data destroyed," "⑤ region fails." The bottom three tinted green with a bracket labeled "single-cluster resilience: replicas · PDB · spread · HPA (you own this)"; the top two tinted amber with a bracket labeled "disaster recovery: OADP · GitOps · RHSI · replication (this module)." Each rung's edge annotated with the mechanism that absorbs it.

## Slide: RPO & RTO — the two numbers that size your DR

- RPO — Recovery Point Objective: how much DATA can you lose (measured in time)?
- RTO — Recovery Time Objective: how long can you be DOWN?
- Cheap answer: nightly backup (lose ≤ a day) + restore on demand (down for hours)
- Expensive answer: synchronous replication (lose nothing) + hot standby (down for seconds)
- Size them PER APPLICATION — a system-of-record and a rebuildable cache are not the same

Notes: Before choosing any DR mechanism, answer two questions about each application. RPO — Recovery Point Objective — is how much data you can afford to lose, measured in time: an RPO of 24 hours means a nightly backup is fine and you might lose a day of writes; an RPO of zero means you cannot lose a single committed transaction, which forces synchronous replication and a much bigger bill. RTO — Recovery Time Objective — is how long you can be down while you recover: four hours tolerates a restore-from-backup, sixty seconds demands a hot standby already running. RPO drives how OFTEN you copy data; RTO drives how READY the recovery target is. The trap is treating every app the same. Parasol's claims-of-record database might need a tight RPO because losing a claim is a legal and financial problem; a read-only rate-lookup cache can be rebuilt from source and needs almost no DR at all. Sizing RPO and RTO per application is what stops you from paying active-active prices to protect a cache — and from protecting a system of record with a weekly backup. It is the single most valuable DR conversation a team can have.
Visual: Two dials side by side. Left dial "RPO — data loss," needle spanning "nightly backup (hours)" to "sync replication (zero)"; sub-label "drives how often you copy." Right dial "RTO — downtime," needle spanning "restore (hours)" to "hot standby (seconds)"; sub-label "drives how ready the target is." Below, three app chips — "claims system-of-record (tight)," "quote portal (medium)," "rate cache (loose)" — placed at different points to show per-app sizing.

## Slide: OADP — back up the DATA, not just the objects

- OADP = OpenShift API for Data Protection (Red Hat-supported Velero)
- Backs up Kubernetes OBJECTS + the DATA inside persistent volumes → an S3 object store
- The database volume: CSI snapshot → Data Mover (DataUpload) → in-cluster NooBaa bucket
- That upload is what makes the backup SURVIVE the namespace's deletion
- No external AWS S3 needed — the object store is part of the platform (ODF/NooBaa)

Notes: The backup-and-restore tier is made concrete by OADP — OpenShift API for Data Protection, the Red Hat-supported packaging of the open-source Velero project. What makes it a DR tool and not just a YAML exporter is that it backs up two things: the Kubernetes objects — Deployments, Services, Secrets, the works — AND the data inside persistent volumes, both into an S3-compatible object store. For Parasol's claims database, which lives on a Ceph-RBD block volume, OADP captures the bytes with a CSI snapshot plus the Data Mover: Velero takes a Container Storage Interface volume snapshot, then a DataUpload copies that snapshot's data into an object store. On this cluster the object store is an in-cluster NooBaa bucket from OpenShift Data Foundation, so no external AWS S3 is required — the target is part of the platform. That Data Mover upload is the crucial step: once the data is in the bucket, it lives INDEPENDENTLY of the volume it came from, which is exactly why the backup survives the namespace being deleted. The restore runs it in reverse — a DataDownload repopulates a fresh volume from the object store. Two custom resources define the install (a DataProtectionApplication and a BackupStorageLocation, both platform-owned); two more drive every backup (a Backup and a Restore).
Visual: The OADP flow diagram (concept slide 2 asset): left, the app namespace with a claims-db + parasol-claims box and a PVC cylinder; center, a Velero box; right, a NooBaa object-store box split into "backed-up objects" and "DataUpload: PVC snapshot data." Solid arrows Backup-direction (objects + CSI snapshot → store), dashed arrows Restore-direction (Restore recreates objects; DataDownload repopulates a NEW PVC). Callout on the DataUpload: "data now lives in the store — survives the namespace's deletion."

## Slide: Backup is a PLATFORM operation — the honest split

- Velero's Backup/Restore objects live in the platform's openshift-adp namespace
- Attendees (and most app teams) are NAMESPACE-admins, not cluster-admins
- `oc auth can-i create backups.velero.io -n openshift-adp` → NO
- So backup/restore is a cluster-admin / platform-team job; app teams CONSUME + VERIFY it
- Self-service (NonAdminBackup) exists but is Tech Preview — and off here (needs NAC enabled)

Notes: Here's the honest reality that shapes how DR actually works in an org. Velero's Backup and Restore objects live in the platform's openshift-adp namespace, and creating them requires access there. Workshop attendees — like most application teams — are namespace-admins of their own project, not cluster-admins. Run oc auth can-i create backups dot velero dot io in openshift-adp as a namespace-admin and you get a flat NO. So namespace backup and restore is a cluster-admin, platform-team operation — app teams consume and verify it, they don't operate it. That's not a workshop limitation; it's how DR ownership works in practice, and it's why the lab hands attendees the parts that are genuinely theirs — inspect the stack, destroy it, verify the data survived — and keeps the backup and restore with the instructor. OADP does ship a self-service path — NonAdminBackup and NonAdminRestore, namespaced CRs a project-admin can create in their own namespace — but it's Technology Preview and requires the platform team to enable the Non-Admin Controller in the DataProtectionApplication, which is off on this cluster. Treat it as the future of self-service DR, not something to gate a production runbook on today.
Visual: A permissions diagram: an "app team (namespace-admin)" figure with a green check over "their namespace: inspect / destroy / verify" and a red X over "openshift-adp: create Backup." A "platform team (cluster-admin)" figure with a green check over "Backup / Restore." A dashed future box "NonAdminBackup (Tech Preview) — self-service when NAC is enabled," greyed. Terminal chip: "oc auth can-i create backups.velero.io -n openshift-adp → no."

## Slide: Delete it, restore it — the data SURVIVED

- The disaster: `oc delete all,pvc --all` — the app, the database, AND the volume are gone
- A query fails: "deployments.apps claims-db not found" — no replica can bring this back
- The Restore: recreates objects + a DataDownload repopulates a FRESH volume from the store
- The 25 seeded rows come back BYTE-FOR-BYTE — CLAIMANT-0001 / home / 637, unchanged
- A backup you've never RESTORED is a hope, not a capability — drill the round-trip

Notes: This is the beat that makes disaster recovery real instead of a slide. The attendee destroys their own namespace's contents — oc delete all comma pvc — which removes the app, the database, and the persistent volume holding all the data. A query immediately fails: deployments dot apps claims-db not found. This is the failure no number of replicas survives, because the data itself is destroyed; the resilient tier could not save you here. Then the cluster-admin runs the Restore. It recreates every object, and a DataDownload repopulates a FRESH persistent volume from the object-store copy — note the new PV, same data. Ninety seconds after the namespace was empty, the exact same 25 seeded rows are back: CLAIMANT-0001, home, 637, and all the rest, byte-for-byte identical to what the attendee read at the start. That contrast — empty namespace to restored data — IS the difference between resilience and disaster recovery: the copy lived somewhere else, and OADP brought the data back, not just the objects. The lesson to land hard: a backup you have never restored is a hope, not a capability. Drill the round-trip on a schedule; restore semantics and volume data movement have edge cases that only a real restore surfaces.
Visual: A three-panel filmstrip. Panel 1 "before": the stack + a table showing 25 rows (CLAIMANT-0001…). Panel 2 "delete": the same namespace empty, a red terminal line "claims-db not found," a broken-cylinder icon. Panel 3 "restore": the stack back, a NEW PV cylinder, and the SAME 25 rows highlighted "byte-for-byte." A big arrow from the object store into panel 3 labeled "DataDownload." Caption: "resilience couldn't save this — DR did."

## Slide: RHSI — Layer-7 connectivity without a VPN [ADD-ON]

- Multi-site DR also needs to REACH services elsewhere — a remote-site DB, a second cluster
- Old answer: a VPN or a flattened network (heavy, security-owned, cross-boundary-hostile)
- RHSI / Skupper v2 builds a Virtual Application Network — mutual-TLS L7, links SPECIFIC services
- Site → expose with a Connector → consume with a Listener → link via AccessGrant→AccessToken
- The app is UNCHANGED: it reads a remote DB through a LOCAL name; same CRs link two clusters

Notes: Disaster recovery is not only about restoring data; it's about reaching services that live somewhere else. When Parasol's claims app on the main cluster needs a Postgres at a different site — a legacy data center, a second cluster, a partner's environment — the old answer is a VPN or a flattened network: heavyweight, security-team-owned, and often impossible across organizational boundaries. Red Hat Service Interconnect, built on Skupper version 2, is the modern answer. It creates a Virtual Application Network: a dedicated mutual-TLS Layer-7 overlay that links just the specific services that need it, with no VPN, no shared subnet, and no firewall holes beyond a single outbound connection. Each participating namespace becomes a Site; you expose a service on one site with a Connector, consume it on another with a Listener bound to the same routing key, and link the sites by issuing an AccessGrant and redeeming it with an AccessToken. The elegant part is that the application is completely unchanged — it connects to a LOCAL address that only exists because the VAN provides it, and traffic is carried, encrypted, to the remote site's real database. In the lab, a psql from the main cluster FAILS before the VAN — the name doesn't resolve — and SUCCEEDS against the remote site's data after. This whole section is a flagged, skippable add-on: RHSI is a separate subscription, and nothing in the graded core depends on it.
Visual: The RHSI VAN diagram (concept slide 3 asset): left "Site: claims-app (main cluster)" with parasol-claims → a Listener chip "claims-db-siteb:5432 · key claims-db"; center a "Virtual Application Network (mutual-TLS L7)" cloud with a Link token; right "Site: site-b (remote)" with a Connector chip "selector app=claims-db · key claims-db" → a claims-db cylinder "SITE-B data." A [ADD-ON] ribbon corner-tag. Footer: "before the VAN: host not found · after: reads SITE-B rows — app unchanged."

## Slide: DR tiers — a decision on RPO/RTO + cost (GitOps is the superpower)

- Backup & restore: cheapest; RPO = last backup, RTO = restore time → MOST apps
- Active-passive: a warm standby; RPO/RTO in minutes → systems of record with tight RTO
- Active-active: both serving; RPO/RTO ≈ zero → only the crown jewels
- GitOps is the multiplier: platform re-materializes from Git (M10); data restores from OADP
- Over-buying DR is a real, expensive mistake — size the tier PER application

Notes: There are three broad DR postures, and choosing among them is an RPO/RTO-and-cost decision made per application. Backup and restore: periodic backup to an object store, restore on disaster; RPO is since the last backup, RTO is the restore time, cost is lowest — object storage plus a runbook. Active-passive: a standby cluster kept warm with data replicated, fail over on disaster; RPO and RTO in the minutes, cost is medium — a second cluster mostly idle. Active-active: two or more clusters both serving, traffic shifts on disaster; RPO and RTO near zero, cost is highest — full duplicate capacity plus data sync. Most applications belong in backup and restore — it's cheap, it's what OADP gives you, and "restore in an hour, lose at most last night's writes" is a fine answer for the majority. Reserve active-passive and active-active for the few workloads whose numbers justify the cost. And here's the multiplier that changes every tier's economics: GitOps. If your entire platform is declared in Git and reconciled by Argo CD — from M10 — then standing up the environment on a new cluster is not a heroic runbook, it's pointing Argo at a fresh cluster and letting it converge. The data still needs OADP or replication, but the PLATFORM re-materializes from Git in minutes. That's why a modern DR strategy starts with everything in Git. Over-buying DR is a real and common waste; sizing it per system is the skill.
Visual: A three-column comparison (Backup & restore | Active-passive | Active-active) across rows RPO, RTO, cost, "reach for it when," each cell filled from the concept table, with cost shaded low→high left-to-right. A banner across the top: "GitOps re-materializes the PLATFORM (M10) + OADP restores the DATA = cheapest strong posture." A right-rail callout "ACM automates this across a fleet."

## Slide: DR decision guide + map to your org

- Pod/node/zone loss → replicas + PDB + spread (M12/M16), NOT a backup
- Destroyed data / deleted namespace → OADP restore, NOT more replicas
- Stand a platform up elsewhere → GitOps re-materialize (M10) + OADP data, NOT a runbook
- Reach a service at another site → RHSI [ADD-ON], NOT a VPN; most apps → backup & restore
- Map to your org: which rung does each measure absorb? when did you last RESTORE a backup?

Notes: Close on the decision and the transfer. Match the mechanism to the failure: a pod, node, or zone loss is replicas plus a PodDisruptionBudget plus spread — from M12 and M16 — not a backup; destroyed data or a deleted namespace is an OADP restore, not more replicas; standing a platform back up on a new cluster is a GitOps re-materialization from M10 plus OADP for the data, not a 40-page runbook; reaching a service at another site without a flat network is RHSI, an add-on; and most apps, most of the time, are simply backup and restore plus GitOps. Then take the questions back to your org. Which rung does each of your "resilience" measures actually absorb — and is there anything for the data and cluster rungs, or does "we have replicas" quietly stand in for a DR plan you don't have? When did you last RESTORE a backup — not take one, restore one — because a backup you've never restored is a hope. Can each system's owner state RPO and RTO as two numbers? Who runs backup and restore — is it a bottleneck? And how much of your DR plan is a document versus reconciled from Git? The honest core of a modern strategy: the platform rebuilds from Git, the data restores from the object store, and you've TESTED both.
Visual: A "what's it FOR" matrix: rows = failure/need (pod-node-zone / destroyed data / lost cluster / reach another site / crown jewels / most apps / fleet-scale), columns = "Reach for" and "Not." Right rail "Map to your org" with the five prompts as check-boxes. Bottom banner pointer: "M12/M16 resilience · M10 GitOps · builds toward ACM (fleet DR)."
