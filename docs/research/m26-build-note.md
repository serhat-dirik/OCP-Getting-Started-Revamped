# M26 build note — Operator Development Deep-Dive

Date: 2026-07-15 · Author: research-analyst · Spec: `Project-Shared/instructions/02-MODULE-SPECS.md` **§M26 (lines 314-323)** · Entitlement: **[OCP]** (core OCP; the SDK itself is upstream OSS, **not** a Red Hat-supported SKU on 4.21 — see below). Profile: `core` + an operator-dev workspace image. 120 min (double slot).

Method: READ-ONLY live build cluster `ocp-ws-revamped` (OCP 4.21.22 / k8s 1.34.8) as `admin` (no mutations) — `oc get/explain/api-resources`, `oc auth can-i --as=user1` impersonation for the attendee RBAC boundary. Product facts via github.com/operator-framework, sdk.operatorframework.io, book.kubebuilder.io, quarkiverse, redhat.com/blog, docs.redhat.com (403 on direct fetch → WebSearch). Repo inspection: `gitops/entry-states`, `platform-portfolio`, `gitops/workshop-config`, `versions.yaml`, `docs/adr`. Cross-checked M03 (Dev Spaces), M05 (Storage), M06 (Jobs/CronJob) build notes. **No `docs/research/m25-build-note.md` exists yet** — OLM v1 verified independently here; M25 dependency noted. `versions.yaml` left unedited per task constraint (proposed `operator_sdk`/`olm_v1` blocks in the appendix).

## Verified versions

| Product / tool | Version / status | API / mechanism | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 (k8s 1.34.8) | stable-4.21 | `oc version` (live) | 2026-07-15 |
| **OLM v1** (operator-controller + catalogd) | **GA since OCP 4.18, enabled by default** alongside OLM Classic | `olm.operatorframework.io/v1` — **ClusterCatalog** + **ClusterExtension** (both cluster-scoped) | live `oc get crd`/`api-resources`; ns `openshift-catalogd` + `openshift-operator-controller` Active; OCP 4.18 relnotes + redhat.com "Announcing OLM v1" | 2026-07-15 |
| OLM v1 catalogs (live) | 4 default ClusterCatalogs SERVING (redhat/certified/community/marketplace); **0 ClusterExtension objects** (unused) | catalogd | live `oc get clustercatalog/clusterextension` | 2026-07-15 |
| OLM Classic (v0) | present + in use (the workshop's install path — CSVs live everywhere) | `operators.coreos.com` Subscription/CSV/CatalogSource/OperatorGroup/InstallPlan | live `oc api-resources` | 2026-07-15 |
| **operator-sdk (upstream/community)** | **v1.42.3 (2025-06-26)** — Go/Ansible/Helm plugins; Go scaffolding on Go 1.24 | `operator-sdk init --plugins go/v4` (wraps Kubebuilder) | github.com/operator-framework/operator-sdk/releases | 2026-07-15 |
| operator-sdk **Quarkus/Java bootstrap** | **DELEGATED to Quarkus tooling since operator-sdk v1.37.0** — the `quarkus`/`java` plugins are no longer the scaffold path | "bootstrap your Quarkus-based operator with the provided Quarkus tools" | sdk.operatorframework.io/docs/upgrading-sdk-version/v1.37.0 | 2026-07-15 |
| operator-sdk **Red Hat-supported CLI** | **LAST shipped with OCP 4.18 = v1.38.0**; **NOT shipped in 4.20/4.21**; last-shipped supported ~3 yrs | Red Hat decoupling SDK from OCP; future = OLM v1 | redhat.com/en/blog/future-red-hat-openshift-operator-sdk + OCP "CLI tools → Operator SDK" | 2026-07-15 |
| **Kubebuilder** (Go, what go/v4 wraps) | canonical **CronJob Tutorial builds a CronJob-CRD controller that creates + OWNS Jobs** via ownerReferences (Go) | `kubebuilder init` + `create api` → controller-runtime | book.kubebuilder.io/cronjob-tutorial | 2026-07-15 |
| **Quarkus Operator SDK (QOSDK)** | **v7.7.x** (current 2026 line) → Quarkus **3.35.x** / JOSDK **5.x** (5.3.4); OLM bundles via `quarkus-operator-sdk-bundle-generator` | Quarkus CLI + `io.quarkiverse.operatorsdk` extension (NOT operator-sdk) | github.com/quarkiverse/quarkus-operator-sdk + quarkus.io/extensions | 2026-07-15 |
| Java Operator SDK (JOSDK, Fabric8) | **v5.x** (5.3.4 via QOSDK 7.7.x) | `Reconciler` + dependent-resource model | quarkiverse (transitive) | 2026-07-15 |
| Dev Spaces | 3.29.0 (CheCluster `openshift-devspaces/devspaces` Active) | devspacesoperator.v3.29.0 | live `oc get checluster` + `versions.yaml devspaces` | 2026-07-15 |
| **UDI workspace image** | `registry.redhat.io/devspaces/udi-rhel9:3.29` — ships **golang, java, maven, oc/kubectl, helm**; **operator-sdk ABSENT** | Universal Developer Image | Red Hat Ecosystem Catalog UDI listing + Dev Spaces docs (`make`/`gcc` presence + operator-sdk-absence → confirm on a live UDI pod at build) | 2026-07-15 |
| CronJob / Job / PVC | GA; `ownerReferences` + `jobTemplate` present | `batch/v1` CronJob+Job, `core/v1` PVC | live `oc explain` + M06 note | 2026-07-15 |

**Headline (spec-critical, three findings that reshape the module):**
1. **operator-sdk is Go-first and no longer scaffolds Java at all** (delegated to Quarkus since v1.37.0). The spec's literal *"scaffold an operator with operator-sdk"* is only true for **Go**. → **Recommend Go** (detail + ADR rationale in appendix).
2. **There is NO Red Hat-supported operator-sdk on OCP 4.21.** The last OCP to ship it was 4.18 (v1.38.0). Content must use the **upstream community operator-sdk (v1.42.x)** and say so honestly; Red Hat's stated future is **OLM v1** (install without the SDK/bundle for some cases).
3. **OLM v1 is GA and live by default** here (`olm.operatorframework.io/v1`, catalogd serving 4 catalogs) — so "package as an OLM bundle → run via OLM" can be taught on the **modern** path (ClusterExtension),   aligning M26 (write a bundle) with M25 (read a bundle). But ClusterExtension is **cluster-scoped** → attendees can't self-serve it (see RBAC).

## Spec deltas

- **"scaffold an operator with operator-sdk" (Java option).** operator-sdk removed Java/Quarkus bootstrap in **v1.37.0**; a Java operator today is scaffolded with the **Quarkus CLI + QOSDK extension**, not `operator-sdk`. So the spec's "Go operator-sdk **vs** Java Operator SDK" is really "operator-sdk (Go) **vs** Quarkus+QOSDK (Java, different toolchain)." (sdk.operatorframework.io v1.37.0 upgrade note.)
- **"operator-sdk … OLM" as if Red Hat-supported.** On 4.21 the SDK is **upstream-only** (RH last shipped it with 4.18). Not a blocker — the upstream CLI works fine — but content/`versions.yaml`/ADR must label it upstream, and the "package as a bundle" beat should present **OLM v1 as the modern install path**, not just OLM Classic. (redhat.com future-of-operator-sdk blog.)
- **"run locally against the cluster, then in-cluster" + `make deploy` assume permissions attendees don't have.** Verified live (`--as=user1`): an attendee **cannot** create CRDs, Namespaces, ClusterRoles, or OLM v1 ClusterExtensions. Default `operator-sdk`/Kubebuilder `make install` (creates the CRD) and `make deploy` (creates a `<project>-system` namespace + ClusterRole + leader-election) are **cluster-admin operations** → they fail for an attendee. The CRD must be **pre-installed by the platform**, and in-cluster deploy must be **re-scoped to `{user}-dev`** (namespaced Role, no ClusterRole, no new namespace). See RBAC in the appendix — this is the module's central cluster-fit fact.
- **Entry state "scaffolded sample repo."** Confirmed necessary and stronger than written: pre-scaffold the **full `operator-sdk init` + `create api` output** AND pre-warm the **Go module cache** in the workspace image — otherwise ×30 cold `go build`/`make` (controller-runtime deps, hundreds of MB) blows the 120-min budget and hammers egress.
- **No M24/M25/M26 scaffolding exists** (entry-states stop at m23, plus m27; no `content/…/m26`; no `operator_sdk`/`olm_v1` in `versions.yaml`). All net-new. The `ClaimsArchive` CRD, the operator-dev workspace image, the aggregated RBAC, and `gitops/entry-states/m26/` are clean-sheet.

## Approach recommendations (max 5)

1. **Language = Go** (`operator-sdk` upstream **v1.42.x**, `go/v4` plugin) for the graded lab; document the **Java/QOSDK** path as a take-home in **ADR-0006** — deciding reason: operator-sdk no longer scaffolds Java, and the canonical **Kubebuilder CronJob-owns-Jobs tutorial IS this exact lesson** (de-risks authoring; Go is the platform's lingua franca).
2. **Pre-scaffold + pre-warm:** seed the `init`/`create api` output into `{user}` Gitea and bake a **warm Go module cache** into the workspace image, so the double slot is spent on reconcile logic — not boilerplate or first-build downloads.
3. **Reconcile = create-or-update an OWNED PVC + CronJob** (`SetControllerReference`), set **status Conditions** + emit **Events**, and **scope the manager cache to the single target namespace** (a namespaced identity cannot watch cluster-wide → the default all-namespaces cache is Forbidden).
4. **Platform pre-provisions the cluster-scoped parts:** install the `ClaimsArchive` **CRD** + ship an **aggregate-to-admin ClusterRole** (`claimsarchives` + `/status`), and grant the **workspace ServiceAccount** the namespaced verbs on `{user}-dev` so `make run` works password-free; re-scope `make deploy` to `{user}-dev`.
5. **Bundle:** `make bundle` (registry+v1) is the attendee deliverable and ties **M25**'s read-a-bundle; **installing** it (OLM v1 `ClusterExtension` or `operator-sdk run bundle`) is **[INSTRUCTOR-DEMO]** — both are cluster-scoped and attendee-forbidden.

## Mining results

- **OldContent yields nothing portable for operator *authoring*** (confirms the spec's "Mine: fresh"). A repo grep for `operator-sdk`/`kubebuilder`/`controller-runtime`/`reconcile`/CRD hit only operator *instances* and RBAC templates (`gitops-catalog/*`, `app-connectivity-workshop/…/chaos-engineering/crd.j2`, `enablement-framework/…/crd-reader.yaml`) — none teach writing a controller. Do not port.
- **book.kubebuilder.io — CronJob Tutorial** → THE porting target for the lab shape: a CRD controller that builds/owns Jobs, with ownerReferences, status, and events, in Go. Re-implement as `ClaimsArchive`→CronJob (Parasol claims archival), do not copy verbatim; credit is optional (docs, not code reuse).
- **sdk.operatorframework.io — OLM Integration / bundle tutorial + CLI overview** (`make bundle`, `operator-sdk run bundle`) → authoritative for the bundle beat; pair with **OCP 4.20/4.22 "OLM v1" docs** + **developers.redhat.com "Manage operators as ClusterExtensions with OLM v1" (2025-06-02)** for the modern install path.
- **CNCF / operator-framework "Operator Capability Levels" (I–V)** → the wrap-up's cost/benefit + "when NOT to write an operator" spine. NOTE: level II's official name is **"Seamless Upgrades"** — cite it as a proper noun; do **not** let vale's banned-word rule (§5 "seamless") rewrite the official level name, and don't use "seamless" as generic prose.
- **Repo (no external credit):** `gitops/entry-states/m03` (Dev Spaces factory-from-Gitea + `parasol-claims` seed), `m06` (CronJob/Job mechanics + per-user `{user}-batch` pattern), `m05` (PVC/StorageClass reality — ODF `ocs-external-storagecluster-ceph-rbd` RWO default) — M26 composes all three. `platform-portfolio/components/devspaces` (UDI + Gitea SCM registration) is the base to extend for the operator-dev workspace.

## Open risks

- **Hard audience filter is real — and it's now a *Go* filter.** Java-leaning attendees pay a Go-syntax tax on top of the controller concepts. Mitigate: heavy pre-scaffold, provide the reconcile body as copy-paste chunks with `<callouts>`, make it fill-in-the-blank (not write-from-scratch). Biggest UX risk in the library.
- **Double slot is tight.** Cold `operator-sdk init` + first `make` pulls a large Go module cache per attendee ×30 → minutes each + egress spike. **Must** pre-scaffold + pre-warm the cache; never run `init` cold at ×30. Budget in the appendix.
- **CRD install + `make deploy` + ClusterExtension are cluster-admin** (verified `--as=user1` = no on CRD/namespace/clusterrole/clusterextension). CRD pre-installed by platform; in-cluster deploy re-scoped to `{user}-dev`; bundle install = demo. If shipped as-generated, the lab breaks at "install."
- **Manager watch scope.** controller-runtime's default cluster-wide cache → immediate Forbidden for the namespaced attendee/SA. The scaffold **must** set `Cache.DefaultNamespaces` to the target ns. `// TODO(verify-on-cluster)` the exact `make run` failure/fix at build.
- **Workspace identity.** A Dev Spaces workspace runs as a per-workspace **ServiceAccount** (`edit` on `{user}-devspaces` only — corroborated by the M03 android-SA finding), NOT the OAuth user, so `make run` won't reach `{user}-dev` by default. Fix: bind the operator perms to the workspace SA on `{user}-dev` (recommended, password-free) OR have the attendee `oc login --web` once. Exact Dev Spaces token injection → `// TODO(verify-on-cluster)`.
- **Aggregated-role behavior.** The built-in `admin` ClusterRole does **not** auto-grant a brand-new CRD; an `aggregate-to-admin/-edit/-view` ClusterRole is required (kubernetes.io RBAC aggregation). Verify the attendee can CRUD `ClaimsArchive` in `{user}-dev` once the CRD + aggregated role exist — `// TODO(verify-on-cluster)`.
- **Owning a PVC is a data footgun (teach it).** Because the PVC carries an ownerReference, `oc delete claimsarchive …` GC-deletes the PVC and its archived data. Good honesty/anti-pattern beat; in "real life" consider not owning the PVC or using a finalizer.
- **Operator image build/push ×30.** `make docker-build`/push to the internal registry has **no default route** (M17) → push in-cluster to `image-registry.openshift-image-registry.svc:5000` with the SA token, or ship a **prebuilt operator image** and keep the attendee build optional. Sizing/egress risk at scale.
- **QOSDK exact release/date UNVERIFIED** (fetch returned inconsistent dates — 7.7.4 vs 7.7.5); QOSDK also targets **Quarkus 3.35.x** while the workshop pins **3.33 LTS** — pin/reconcile at build if the Java take-home ships runnable.
- **`versions.yaml` gap:** no `operator_sdk`/`olm_v1` entries. Verified today; **left unedited per task constraint** — proposed blocks below (add at next touch).

## Builder / platform appendix

### A. The language decision (ADR-0006-ready): Go vs Java/QOSDK

| Axis | **Go — operator-sdk go/v4 (RECOMMEND)** | Java — Quarkus + QOSDK/JOSDK |
|---|---|---|
| Scaffolds with `operator-sdk`? | **Yes** — first-class, actively maintained (v1.42.3) | **No** — removed in v1.37.0; use Quarkus CLI + QOSDK |
| Canonical lesson exists? | **Yes** — Kubebuilder CronJob tutorial *is* an owns-Jobs controller | No equivalent CronJob-owning tutorial |
| Ecosystem fit | **Lingua franca** — every operator they used all week is Go | Familiar language, non-standard operator path |
| Attendee familiarity | Lower (Go tax) | **Higher** (Quarkus-primary, Java-leaning) |
| Inner-loop speed | **Fast** — `make run` a compiled binary; instant "delete it → restored" | Slower — Maven/.m2 warmup + Quarkus rebuild per change |
| Toolchain image | UDI has Go+make+oc+helm; **add 1 binary** (operator-sdk) | UDI has Java+Maven; no binary, but heavier build footprint |
| OLM bundle | `make bundle` (registry+v1) → OLM v1/Classic | `quarkus-operator-sdk-bundle-generator` |
| Version drift | tracks Go 1.24 cleanly | QOSDK wants Quarkus **3.35** vs workshop **3.33 LTS** |

**Recommendation:** **Go**, `operator-sdk` upstream **v1.42.x**, `go/v4` plugin, for the single graded toolchain. Rationale (ADR-ready): (1) it is the only path the spec's "scaffold with operator-sdk" literally describes; (2) the Kubebuilder CronJob tutorial is this exact lesson, shrinking authoring + review risk; (3) "everything all week was reconcile loops — now you write one" lands hardest in the platform's own language; (4) fastest self-healing demo loop and smallest toolchain delta on UDI. **Honest counter-weight (record in the ADR):** the workshop is Quarkus-primary and this is the one module with a hard audience filter, so Go asks Java devs to read Go. We accept that because the module teaches the *universal K8s controller pattern*, not a language — and mitigate with heavy pre-scaffolding + a documented, runnable **Java/QOSDK take-home** (`quarkus-operator-sdk` + `-bundle-generator`) for teams who want it in Java. File as `docs/adr/0006-m26-operator-sdk-language.md`.

### B. `ClaimsArchive` CRD shape (design proposal — Parasol claims archival; composes M06 CronJob + M05 PVC)

```yaml
apiVersion: parasol.example.com/v1alpha1   # group/version = pick a Parasol domain; v1alpha1 (teach versioning taste)
kind: ClaimsArchive
spec:
  schedule: "0 2 * * *"        # -> CronJob.spec.schedule (M06)
  retentionDays: 90            # claims older than N days get archived -> Job env/arg
  suspend: false               # -> CronJob.spec.suspend (pause archiving)
  image: "…/parasol-archiver:…" # optional; the archive Job image (default a Parasol image)
  archiveStorage:
    size: 1Gi                  # -> owned PVC (M05)
    storageClassName: ""       # optional; default SC = ocs-external-storagecluster-ceph-rbd (RWO)
status:
  conditions: []               # metav1.Condition: Ready / Progressing / Degraded (+reason,message,observedGeneration)
  lastArchiveTime: null        # mirror CronJob.status.lastSuccessfulTime
  # archivedClaimsCount: int   # OPTIONAL/nice-to-have — only if the Job can report it deterministically
```

### C. Reconcile logic (level-based, idempotent — the teaching core)

```
Reconcile(req):
  ca = Get(ClaimsArchive)          ; if NotFound -> return (GC cascades children via ownerRefs)
  pvc = desiredPVC(ca)             ; SetControllerReference(ca, pvc) ; CreateIfAbsent   # PVCs ~immutable
  cj  = desiredCronJob(ca)         ; SetControllerReference(ca, cj)  ; CreateOrUpdate    # reconcile schedule/suspend/image
  setCondition(ca, Ready=True|Progressing|Degraded) ; ca.status.lastArchiveTime = cj.status.lastSuccessfulTime
  UpdateStatus(ca) ; recorder.Event(ca, Normal, "Ensured", …)   # Warning on error
  return   # watch-driven, no periodic requeue
// SetupWithManager: For(&ClaimsArchive{}).Owns(&batchv1.CronJob{}).Owns(&corev1.PVC{})
// -> deleting the owned CronJob fires the Owns watch -> reconcile recreates it  == the "self-healing, from the author's seat" demo
// -> deleting the ClaimsArchive cascades (ownerRef GC) -> CronJob + PVC (and archived data) removed
// Manager: cache.Options{DefaultNamespaces: {"{user}-dev": {}}}   # REQUIRED — namespaced identity can't watch cluster-wide
```

### D. RBAC (verified live `--as=user1`, 2026-07-15) — the cluster-fit spine

Attendee = built-in `admin` (namespaced) + `monitoring-edit` bound in `{user}-{dev,stage,prod,cicd}` (`per-user-rbac.yaml`).

| Action | Scope | `can-i --as=user1` | Consequence for M26 |
|---|---|---|---|
| create cronjobs / pvc / events / deployments / roles in `{user}-dev` | namespaced | **yes** | reconcile targets + `make run` mutations are fine in-namespace |
| create `customresourcedefinitions` | cluster | **no** | CRD **pre-installed by platform**; `make install` is not attendee-runnable |
| create `namespaces` | cluster | **no** | default `make deploy` (`<project>-system` ns) blocked → re-scope to `{user}-dev` |
| create `clusterroles` | cluster | **no** | default `make deploy` (ClusterRole + leader-election) blocked → namespaced Role only |
| create `clusterextensions` (OLM v1) | cluster | **no** | install-your-bundle via ClusterExtension = **[INSTRUCTOR-DEMO]** |
| get `clustercatalogs` (OLM v1) | cluster | **no** | catalog dissection = demo / platform-exposed |

**Net-new platform RBAC to ship (bootstrap / cluster-admin):**
- Install the `ClaimsArchive` **CRD** cluster-wide.
- An **aggregate-to-admin/-edit/-view ClusterRole** granting `claimsarchives`, `claimsarchives/status`, `claimsarchives/finalizers` (so the attendee's namespaced `admin` picks it up; kubernetes.io RBAC aggregation).
- Grant the **workspace SA** (or a dedicated operator SA) the namespaced verbs on `{user}-dev` (`claimsarchives*`, `cronjobs`, `persistentvolumeclaims`, `events`) so `make run` from the workspace is password-free.
- Optionally extend `platform-observer` with read on `clustercatalogs`/`clusterextensions` if attendees inspect OLM v1 (else demo-only).

### E. Workspace image (existing vs new; size / pre-pull)

- **Base = existing UDI** `registry.redhat.io/devspaces/udi-rhel9:3.29` — already ships golang, java, maven, oc/kubectl, helm, build tools; **already pre-pulled** in the M03 devspaces stack (Image Puller). So the "big image" is UDI, and it is *already* on nodes.
- **Net-new = add the operator-sdk binary** (upstream v1.42.x, ~1 file, ~100-150 MB) — the only real delta. Two options: **(a)** a thin derived image `FROM udi-rhel9:3.29` with operator-sdk baked in (deterministic, air-gap-friendly, pre-pull via Image Puller — RECOMMEND for ×30) or **(b)** a devfile `postStart` that fetches operator-sdk (no new image, but adds start-time + needs egress). `controller-gen`/`kustomize` are fetched into `bin/` by `make` — no image change. **Also bake a warm Go module cache** (controller-runtime deps) into the image to kill the ×30 first-build stall.
- Verify on a live UDI pod at build: exact Go version, `make`/`gcc` presence, and that operator-sdk is truly absent (`// TODO(verify-on-cluster)`).

### F. Entry-state requirements — `gitops/entry-states/m26/` (net-new, compose-don't-chain)

- `{user}-dev` reused as the operator's target namespace (co-locate the managed CronJob/PVC with the claims app the attendee already knows) — materialize independently, don't assume M05/M06 ran.
- Per-user **Gitea repo pre-seeded** with the `operator-sdk init` + `create api` scaffold (go/v4), `ClaimsArchive` types stubbed, reconcile left as guided fill-in-the-blank.
- **CRD pre-installed** + **aggregated ClusterRole** + **workspace-SA grants** (section D) — all cluster/bootstrap layer, not a per-user chart (mirrors the M06 finding that quota/RBAC live in the workshop layer).
- A **prebuilt operator image** in the internal registry for the in-cluster step (so the attendee build is optional).
- `ws-meta.yaml` `conflictsWith` any same-`{user}-dev` module; `ws reset` purges `ClaimsArchive` CRs + owned CronJob/PVC (PVCs survive CR-less deletion — purge explicitly).

### G. Lab spine (grounded step outline, Go path, ~120 min)

1. **Concept (~20):** reconciliation honestly (level-based / idempotent / spec-vs-status); "controllers are the platform's own pattern — you've watched reconcile loops all week, now you write one."
2. **Tour the scaffold (~10):** read the pre-generated go/v4 layout (`api/…/claimsarchive_types.go`, `internal/controller/…`, `config/`, `Makefile`); explain what `init`+`create api` produced (read-through, not cold-run).
3. **Define the CRD (~15):** edit spec/status; `make manifests` regenerates `config/crd` + deepcopy; `oc get crd claimsarchives…` (pre-installed) to confirm.
4. **Implement Reconcile (~30):** ensure PVC + CronJob (SetControllerReference + CreateOrUpdate), status Conditions, Events; set the namespaced manager cache.
5. **`make run` locally (~15):** create a `ClaimsArchive` in `{user}-dev` → operator creates the owned CronJob + PVC; read status + events in the console and `oc describe`.
6. **Self-healing (~10 / demo arc):** `oc delete cronjob <owned>` → operator recreates it (Owns watch) → then `oc delete claimsarchive …` → ownerRef cascade. Toggle `suspend` / change `schedule` → reconcile.
7. **In-cluster (~10):** stop `make run`; deploy the operator into `{user}-dev` (re-scoped Deployment + namespaced Role, or platform-run); confirm it reconciles.
8. **Bundle + wrap (~10):** `make bundle` (registry+v1) → inspect CSV/CRD/annotations (ties M25); [INSTRUCTOR-DEMO] install via OLM v1 ClusterExtension; wrap = cost/benefit, capability levels I-V, "imperative installer in an operator costume" anti-pattern, and the OLM-v1/SDK-deprecation reality.

### H. M25 tie + OLM v1 coordination (no m25 note yet)

M25 = *read* a bundle (CSV/CRDs/channels; the packaging spectrum). M26 = *write + build* the same **registry+v1** bundle. Keep vocabulary identical. Both should present **OLM v1 (ClusterExtension) as the modern install path** and note the SDK-decoupling. OLM v1 constraint to teach: it installs bundles that are **registry+v1**, **AllNamespaces** install mode, and **no webhooks** — so keep the `ClaimsArchive` operator webhook-free (also keeps the scaffold simple). When the M25 note lands, reconcile the exact bundle-dissection object (a real on-cluster CSV vs the attendee's own bundle).

### I. Proposed `versions.yaml` blocks (verified today; NOT written per task constraint)

```yaml
operator_sdk:
  upstream_version: "1.42.3"     # community, github.com/operator-framework/operator-sdk (2025-06-26); go/v4 plugin, Go 1.24
  rh_supported_version: "1.38.0" # LAST Red Hat-supported, shipped with OCP 4.18 ONLY; not shipped in 4.20/4.21
  channel: upstream              # RH decoupled the SDK CLI from OCP; future = OLM v1
  verified: 2026-07-15
  source: github.com/operator-framework/operator-sdk/releases; redhat.com/en/blog/future-red-hat-openshift-operator-sdk
  notes: Quarkus/Java bootstrap delegated to Quarkus tooling since v1.37.0. Content must label the SDK UPSTREAM (not RH-supported on 4.21).
  entitlement: OCP               # runs on core OCP; tool is upstream OSS, not a SKU
olm_v1:
  status: GA (OCP 4.18+, enabled by default alongside OLM Classic)
  api: olm.operatorframework.io/v1
  kinds: [ClusterCatalog, ClusterExtension]   # both cluster-scoped
  version: "4.21"
  verified: 2026-07-15
  source: live cluster ocp-ws-revamped (ns openshift-catalogd/openshift-operator-controller Active; 4 ClusterCatalogs serving); OCP 4.18 relnotes; redhat.com "Announcing OLM v1"
  notes: Installs registry+v1 bundles, AllNamespaces mode, NO webhooks. ClusterExtension is cluster-scoped -> attendees cannot self-install (INSTRUCTOR-DEMO). qosdk_note = Quarkus Operator SDK 7.7.x targets Quarkus 3.35 vs workshop 3.33 LTS.
  entitlement: OCP
```

### J. Relevant absolute paths
- Spec: `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/Project-Shared/instructions/02-MODULE-SPECS.md` (§M26 L314-323; M25 L303-312)
- ADR to create: `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/OCP-Getting-Started-Revamped/docs/adr/0006-m26-operator-sdk-language.md`
- Compose-from notes: `docs/research/m03-build-note.md` (Dev Spaces/UDI), `m05-build-note.md` (PVC/SC), `m06-build-note.md` (CronJob/Job)
- Workspace base to extend: `platform-portfolio/components/devspaces/`
- RBAC precedent: `gitops/workshop-config/templates/per-user-rbac.yaml`, `platform-observer-clusterrole.yaml`
- Entry-state pattern precedent: `gitops/entry-states/m03/`, `m06/`
- versions.yaml (gap): `/Users/hdirik/RHSA/RedHatSASupport/OCP-GettingStarted-Revamped/OCP-Getting-Started-Revamped/versions.yaml`

Sources:
- operator-sdk releases (v1.42.3) — https://github.com/operator-framework/operator-sdk/releases
- operator-sdk v1.37.0 upgrade (Quarkus bootstrap delegated) — https://sdk.operatorframework.io/docs/upgrading-sdk-version/v1.37.0/
- The future of the Red Hat OpenShift Operator SDK (last shipped 4.18) — https://www.redhat.com/en/blog/future-red-hat-openshift-operator-sdk
- Kubebuilder CronJob Tutorial (owns Jobs, Go) — https://book.kubebuilder.io/cronjob-tutorial/cronjob-tutorial
- operator-sdk OLM bundle tutorial / CLI overview — https://sdk.operatorframework.io/docs/olm-integration/tutorial-bundle/ · https://sdk.operatorframework.io/docs/olm-integration/cli-overview/
- Announcing OLM v1 — https://www.redhat.com/en/blog/announcing-olm-v1-next-generation-operator-lifecycle-management
- Manage operators as ClusterExtensions with OLM v1 — https://developers.redhat.com/articles/2025/06/02/manage-operators-clusterextensions-olm-v1
- OCP 4.22 OLM v1 docs — https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/operators/olm-v1
- Quarkus Operator SDK (QOSDK) — https://github.com/quarkiverse/quarkus-operator-sdk · https://quarkus.io/extensions/io.quarkiverse.operatorsdk/quarkus-operator-sdk-bundle-generator/
- Dev Spaces UDI (Ecosystem Catalog) — https://catalog.redhat.com/en/software/containers/devspaces/udi-rhel9/673f8460bbf0c33aca0fe316
- Kubernetes RBAC aggregation — https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles
- Live cluster ocp-ws-revamped (read-only): `oc version`, `oc get crd/api-resources/checluster/clustercatalog/clusterextension`, `oc auth can-i --as=user1` (2026-07-15)
