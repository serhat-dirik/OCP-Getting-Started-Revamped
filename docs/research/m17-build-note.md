# M17 build note — Registry, Images & Catalog Governance

Date: 2026-07-12 · Author: research-analyst R4d · Spec: 02-MODULE-SPECS §M17 (lines 212-221) · Entitlement: **[OCP]** (all core OpenShift — no operator SKU)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22, k8s 1.34.8, READ-ONLY — a G4 audit was running concurrently) — `oc explain` / `oc get` on the image, mirror, samples, pruner, registry-operator, console-operator and catalog-source APIs; repo inspection (`gitops/`, `platform-portfolio/`, `content/`); docs.redhat.com (OCP Images / Disconnected chapters) + `openshift/openshift-docs`. `versions.yaml` extended with a verified `ocp_registry_governance` block (2026-07-12). Cross-checked M02/M03/M08 build notes for no-overlap.

## Verified versions

| Product / API | Version / status | Group·Kind (name) | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-12 |
| Internal image registry | Managed, PVC `pvc-image-registry`, `rolloutStrategy=Recreate`, **no default route** | `imageregistry.operator.openshift.io/v1·Config` (cluster) | live `oc get config.imageregistry.operator/cluster` | 2026-07-12 |
| Internal registry endpoint | `image-registry.openshift-image-registry.svc:5000` | Service `image-registry` :5000 | live `status.internalRegistryHostname` | 2026-07-12 |
| **ImageDigestMirrorSet (IDMS)** | **CURRENT** — Compatibility level 1 (stable) | `config.openshift.io/v1·ImageDigestMirrorSet` (idms) | live `oc explain` + `oc get crd` | 2026-07-12 |
| **ImageTagMirrorSet (ITMS)** | **CURRENT** — Compatibility level 1 (stable) | `config.openshift.io/v1·ImageTagMirrorSet` (itms) | live `oc explain` | 2026-07-12 |
| **ImageContentSourcePolicy (ICSP)** | **DEPRECATED since 4.13** — Compatibility level 4, still served | `operator.openshift.io/v1alpha1·ImageContentSourcePolicy` | live `oc explain` + docs (`oc adm migrate icsp`) | 2026-07-12 |
| Allowed/blocked registries (pods+builds) | `spec.registrySources.allowedRegistries` \| `blockedRegistries` (cluster-wide, MCO→node) | `config.openshift.io/v1·Image` (cluster) | live `oc explain images.config…spec.registrySources` | 2026-07-12 |
| Allowed registries **for import** | `spec.allowedRegistriesForImport` (API-server admission, no node roll) | `config.openshift.io/v1·Image` (cluster) | live `oc explain` | 2026-07-12 |
| Cluster Samples Operator | Managed, x86_64 | `samples.operator.openshift.io/v1·Config` (cluster) | live `oc get/explain configs.samples.operator` | 2026-07-12 |
| Image Pruner (auto) | daily @ midnight, `keepTagRevisions=3`, `keepYoungerThan` 60m | `imageregistry.operator.openshift.io/v1·ImagePruner` (cluster) | live `oc get imagepruner/cluster` + docs | 2026-07-12 |
| Developer-catalog governance | `spec.customization.developerCatalog.{types,categories}` | `operator.openshift.io/v1·Console` (cluster) | live `oc explain consoles.operator…` | 2026-07-12 |
| Custom catalog Sample | `source.type` GitImport \| ContainerImport (cluster-scoped) | `console.openshift.io/v1·ConsoleSample` | live `oc explain` (0 objects on cluster) | 2026-07-12 |
| Namespaced Template (attendee catalog) | namespaced — appears only in its own ns catalog | `template.openshift.io/v1·Template` | live `oc api-resources` | 2026-07-12 |
| OperatorHub sources / custom catalogs | `spec.sources[]` + `CatalogSource` | `config.openshift.io/v1·OperatorHub` + `operators.coreos.com/v1alpha1·CatalogSource` | live (custom `redhat-rhpds-gitea` catalogsource present) | 2026-07-12 |
| Quay | mention-level only (not on cluster) | — | spec | 2026-07-12 |

**Headline naming confirmation (spec-critical):** IDMS + ITMS (`config.openshift.io/v1`) are the CURRENT mirroring API; **ICSP (`operator.openshift.io/v1alpha1`) is deprecated (since 4.13) and only kept for back-compat** — convert with `oc adm migrate icsp`. Live `oc explain` proves the compatibility tiers: IDMS/ITMS = "Compatibility level 1: Stable within a major release"; ICSP = "Compatibility level 4: No compatibility is provided, the API can change at any point." Zero mirror objects exist on the cluster (clean slate). Content must say IDMS/ITMS, never ICSP except as "the deprecated predecessor."

Cluster reality (verified live 2026-07-12):

- **Internal registry has NO external route.** `defaultRoute` is unset and `oc get route -n openshift-image-registry` → none. So `podman/docker login`+push from a laptop is impossible today. Storage is a single RWO PVC (`pvc-image-registry`, `Recreate` rollout = one registry pod). Endpoint `image-registry.openshift-image-registry.svc:5000` is in-cluster only.
- **Two different "Image" kinds — do not confuse.** `image.config.openshift.io/v1` (`Kind: Image`, singleton `cluster`) holds `registrySources` + `allowedRegistriesForImport`; `image.openshift.io/v1` (`Kind: Image`) is the runtime image object. Plain `oc explain image.spec.registrySources` FAILS (resolves to the wrong group) — always fully-qualify `images.config.openshift.io`.
- **`registrySources.allowedRegistries|blockedRegistries` is enforced by CRI-O on every node** ("only registries permitted for pull AND push … all other registries denied"; "does not contain configuration for the internal cluster registry"; only one of allowed/blocked may be set). Changing it makes the **Machine Config Operator re-render `/etc/containers/registries.conf` + `policy.json` on every node and roll the pool (drain/uncordon/reboot)** — minutes of disruption, all pods rescheduled.
- **`allowedRegistriesForImport` is the low-blast-radius sibling** — openshift-apiserver admission that limits which registries *normal users* may import ImageStreams from; **instant, no node reboot**, and does not affect admins. This is the field that makes a live allowed-registries demo feasible.
- **Samples operator Kind is `Config`** (`configs.samples.operator.openshift.io`, name `cluster`), Managed. Managing the developer catalog cluster-wide: `spec.skippedImagestreams` / `spec.skippedTemplates` disable ONE sample; `managementState: Removed` deletes **all 60 imagestreams + 51 templates** in ns `openshift` (measured live) — which M02 depends on.
- **Auto image pruner is live and firing** (`ImagePruner/cluster`, CronJob ran successfully): daily @ midnight, keeps 3 tag revisions, spares images < 60m old. Real for multi-day events (see risks).
- **Console `developerCatalog` is on the OPERATOR config**, `consoles.operator.openshift.io/cluster` (`{"types":{"state":"Enabled"}}`), NOT `config.openshift.io` (that explain fails). `perspectives:[{id:dev, Disabled}]` re-confirms the unified console (matches M01/M12).
- **Custom-catalog scaffolding exists on-cluster**: `ConsoleSample` CRD present (0 objects), and a real custom `CatalogSource` `redhat-rhpds-gitea` (ns `gitea-operator`) is a ready governance example of "the platform added an operator source." `imageStreamImportMode` cluster default = `Legacy`.
- **In-repo governance artifact already shipped**: `gitops/workshop-config/templates/java-21-imagestream.yaml` — a custom `java-21` builder ImageStream in ns `openshift` with `importPolicy.scheduled: true`, `referencePolicy.type: Local`, and full developer-catalog annotations. This is M17's lesson made concrete and is the single best teaching object in the repo.

## Spec deltas

- **"allowed-registries policy blocks docker.io [INSTRUCTOR-DEMO] … attendees verify + fix by mirroring path (IDMS demo)".** The naive reading — apply `registrySources.allowedRegistries` then an IDMS live — is **not runnable during a multi-module day**: BOTH `registrySources.*` and IDMS/ITMS render via the MCO and **roll every node** (drain/reboot). Even as an instructor demo this reschedules all 30 users' running labs. Delta: block live with **`allowedRegistriesForImport`** (API-level, instant, no reboot); keep `registrySources.allowedRegistries` + the IDMS "fix" as **talk-through / pre-recorded**. The attendee "verify + fix" loop as written cannot be per-attendee (these objects are cluster singletons).
- **Samples operator Kind.** Spec/task write `Samples.samples.operator.openshift.io`; the actual Kind is **`Config`** (`configs.samples.operator.openshift.io/cluster`). "Disable a sample" = add to `skippedImagestreams`/`skippedTemplates`, **never** `managementState: Removed` (all-or-nothing; nukes the 60 IS + 51 templates M02 uses).
- **Internal-registry hands-on assumes push access.** With no `defaultRoute`, the "images from earlier builds in internal registry" and "tag/promote" beats must run **route-free via the API** (`oc tag`, `oc import-image`, in-cluster builds) — `oc registry login`+`podman push` need `defaultRoute: true` first (a build decision). "Push/pull with external registries" uses an *external* registry + pull secret, so it is unaffected.
- **"private devfile registry" is a Dev Spaces concept, not a cluster-wide OCP API.** On OCP the developer-catalog devfiles come from `ConsoleSample` CRs + the community `registry.devfile.io`; a *private/custom* devfile registry is a **CheCluster** (Dev Spaces) configuration → correctly "ties M03". Frame the devfile beat as a peek (inspect `ConsoleSample` on-cluster + the Dev Spaces devfile registry), not an OCP catalog API.
- **platform-observer cannot see M17's objects yet.** The shipped `platform-observer` ClusterRole (`gitops/workshop-config/templates/platform-observer-clusterrole.yaml`) grants `config.openshift.io` only for `clusteroperators/clusterversions/infrastructures/ingresses` + `packagemanifests` — it is MISSING read on `images`, `imagedigestmirrorsets/imagetagmirrorsets`, samples `configs`, `imagepruners`, `catalogsources`, `operatorhubs`, `consolesamples`. Attendees can't inspect the governance surface until the role is extended (build action; re-verify no cross-tenant leak — the same file records a prior namespaces-grant leak incident).
- **No M17 scaffolding exists.** No `gitops/entry-states/m17`, no `ws-meta.yaml`, no `platform-portfolio` component for registry/samples/mirroring/operatorhub — all net-new. (M01-M13 entry states exist; M14-M17 do not.)
- **Import mode.** Cluster default `imageStreamImportMode: Legacy` → a scheduled import of a multi-arch external repo resolves to a single arch; use `importMode: PreserveOriginal` per-tag if multi-arch matters (minor).

## Approach recommendations

1. Split every beat into **attendee-runnable (namespaced, non-disruptive)** vs **cluster-wide [INSTRUCTOR-DEMO] (instructor-guide-scheduled)** — see the beat table in the appendix; no attendee ever touches a cluster singleton.
2. Build the internal-registry + ImageStream arc **route-free via the API** (`oc tag` promote across istags; `oc import-image … --scheduled --confirm`; `oc secrets link <sa> <pull-secret> --for=pull`; observe `referencePolicy: Local` pull-through) and teach it off the already-shipped **`java-21` ImageStream** as the worked example.
3. Demo allowed-registries with **`allowedRegistriesForImport`** live (instant block of a normal user's `oc import-image docker.io/...`, then revert); keep `registrySources.allowedRegistries` + **IDMS/ITMS mirroring as talk-through / pre-recorded** (both roll every node — cannot run mid-event).
4. Teach catalog governance safely: **attendee applies a namespaced `Template`** to their ns (appears in *their* catalog); instructor disables a stock sample via **`skippedImagestreams`/`skippedTemplates`** (never `managementState`) and adds a cluster **`ConsoleSample`**; devfile peek ties to M03's Dev Spaces devfile registry.
5. Net-new platform work: **extend `platform-observer`** for the governance reads; add `gitops/entry-states/m17` (per-user seeded istags + external pull-secret + custom-Template seed) + `ws-meta` purge; add an **instructor-guide scheduling block** so the two cluster-wide demos never overlap M02/import-heavy modules; consider a **cluster-local private registry** (registry:2 + htpasswd) so "deploy from private registry" is self-contained and deterministic.

## Mining results

- **`gitops/workshop-config/templates/java-21-imagestream.yaml` (IN-REPO)** → the canonical M17 artifact: custom builder ImageStream in ns `openshift`, `importPolicy.scheduled: true` + `referencePolicy.type: Local` + catalog annotations (`display-name`, `iconClass`, `tags: builder,java,openjdk`, `supports`, `sampleRepo`). Use it as BOTH the ImageStream scheduled-import/Local-reference teaching object AND the "the platform team curated your catalog" governance story.
- **`OldContent/repos/gitops-catalog/openshift-image-registry/`** (redhat-cop, Apache-2.0) → kustomize base for internal-registry config (storage PVC size, `rolloutStrategy`, provider overlays). Model for a `platform-portfolio` registry component IF `defaultRoute`/storage-sizing must be managed for the event (see `README.md` + `overlays/vsphere`).
- **`OldContent/repos/kc-token-exchangeV2-demo/openshift/imagestreams.yaml` + `buildconfigs.yaml`** (Serhat, credit D18) → minimal "ImageStream must exist before the BuildConfig can push" pattern with the exact failure it prevents (`InvalidOutputReference`) → a ready-made troubleshooting seed.
- **`OldContent/repos/nationalparks/` + `repos/starter-guides/`** → older S2I→ImageStream promotion flows; take the tag/promote *narrative shape* only. **Discard the tech** (2020-era, DeploymentConfig, `oc` v3 templates) per the reference-map "discard" column.
- **`redhat-ads-tech/devfiles`** (mining-index §, license none, NOT cloned) → a real Parasol-adjacent devfile-registry reference for the devfile peek; re-implement, verify freshness at build.
- **Live custom `CatalogSource` `redhat-rhpds-gitea`** (on-cluster) → a concrete "custom operator catalog source" to point at when teaching OperatorHub-source governance.
- **Provisioning/MAD PDFs → nothing portable for M17.** `Provisioning Guide and Support.pdf` + `Cloud Native Architectures Workshop - Provisioning Guide.pdf` are RHDP catalog-provisioning runbooks (registration IDs, seat counts) already mined for the instructor runbook; the only "registry" hits are Apicurio **Service Registry** in the MAD overview (API design — out of scope per D16). The spec Mine line "MAD provisioning guide hints" yields **no registry/pruning/sizing content** — M17's storage-sizing + pruning watchouts are grounded in the live pruner config + OCP docs, not old content. Genuinely "build fresh."

## Open risks

- **`registrySources.allowedRegistries` + IDMS/ITMS = MCO node rollout** (cordon/drain/reboot of every node, all pods rescheduled). CANNOT run live during a multi-module day, even by the instructor. `TODO(verify-on-cluster)` the exact 4.21 rollout scope/timing at build; default plan = talk-through / pre-recorded.
- **`allowedRegistriesForImport` is still cluster-wide** — while live-runnable (no reboot), it blocks imports for **every** concurrent user. The instructor must announce, apply in a tight window, and revert; the instructor guide schedules it away from M02/import-heavy sessions.
- **Nightly image pruner on multi-day events** — daily @ midnight, `keepTagRevisions=3`, `keepYoungerThan=60m`: unreferenced entry-state images (old istag revisions, dangling build images) can vanish overnight. Mitigate: keep entry-state images referenced by a running Deployment/istag, or raise `keepTagRevisions`/suspend the pruner for the event (ops decision for the instructor runbook).
- **Registry storage is one RWO PVC** (`pvc-image-registry`, single `Recreate` pod) — sizing must account for 30 users × multi-day image churn; monitor fill (a full registry blocks all pushes/builds cluster-wide).
- **No internal-registry route** → decide up-front: keep hands-on route-free (recommended) or enable `defaultRoute: true` (adds an external attack surface + TLS/pull-secret handling).
- **`platform-observer` RBAC extension** must be scoped read-only and re-tested for cross-tenant leakage (prior namespaces-grant incident recorded in the role file).
- **`managementState: Removed` foot-gun** — the disable-a-sample demo MUST use skipped lists and MUST NOT run before M02 completes for any concurrent user, or their catalog loses the 60 IS + 51 templates.
- **Private devfile registry** — don't overpromise an OCP catalog "devfile registry API"; it's a Dev Spaces/CheCluster construct (M03). Keep the beat a peek.

## Builder/platform appendix

### Beat table — who runs what (the module's spine)

| Beat | Object / command | Scope | Who |
|---|---|---|---|
| Tag / promote | `oc tag {user}-dev/parasol-claims:1.0 {user}-dev/parasol-claims:prod` | namespaced | **attendee** |
| Scheduled import | `oc import-image {user}-dev/ext-ubi --from=registry.access.redhat.com/ubi9/ubi:latest --scheduled --confirm` → inspect `importPolicy.scheduled` | namespaced | **attendee** |
| Pull-secret → SA | create dockerconfigjson for the (cluster-local) private registry; `oc secrets link deployer <secret> --for=pull`; deploy an image that only pulls with it | namespaced | **attendee** |
| referencePolicy Local | inspect the shipped `java-21` stream; observe pull-through vs Source | namespaced (read) | **attendee** |
| Custom Template | `oc apply -f parasol-template.yaml -n {user}-dev` → +Add ▸ Developer Catalog ▸ Templates | namespaced | **attendee** |
| Inspect governance | view `images.config/cluster`, IDMS/ITMS (none), samples `Config`, `ImagePruner`, `CatalogSource`, `ConsoleSample` | cluster (read) | **attendee** (needs extended platform-observer) |
| Block imports | set `images.config/cluster spec.allowedRegistriesForImport`; show `oc import-image docker.io/...` denied; revert | cluster singleton, instant | **[INSTRUCTOR-DEMO]** |
| Block pods/builds + mirror-fix | `spec.registrySources.allowedRegistries` + `ImageDigestMirrorSet` | cluster, **MCO node roll** | **[INSTRUCTOR-DEMO] talk-through / pre-recorded** |
| Disable a stock sample | samples `Config spec.skippedImagestreams/skippedTemplates` | cluster singleton | **[INSTRUCTOR-DEMO]** (not before M02) |
| Add a cluster Sample | `ConsoleSample` (GitImport/ContainerImport) | cluster-scoped | **[INSTRUCTOR-DEMO]** |

### Entry-state sketch — `gitops/entry-states/m17/` (per-user, net-new; compose-don't-chain)

- `{user}-dev` (or dedicated `{user}-registry` ns) seeded with **1-2 prebuilt images already pushed to the internal registry as ImageStreams** (e.g. `parasol-claims:1.0` istag + a second tag to promote) — materialize via a hook Job running a baseline build or `oc import-image`, NOT by assuming M02 ran.
- A **sample private-registry pull secret** (dockerconfigjson). Recommend a **cluster-local private registry** (`registry:2` + htpasswd, shared) over external quay creds → self-contained, deterministic, no `vars.yaml` secret sprawl; the "deploy from private registry" beat then pulls from it with the linked secret.
- A **custom Template** YAML the attendee applies (pre-staged in their Gitea or shipped in the ns).
- `platform-observer` (already bound cluster-wide via `workshop-attendees`) **plus the extended read grants** (below).
- `ws-meta.yaml purgeNamespaces` the user's imagestreams/istags/imported images on reset; idempotent templates.

### platform-portfolio / workshop-config needs (net-new)

- **Extend `platform-observer` ClusterRole** with read (`get,list,watch`) on: `config.openshift.io` {`images`, `imagedigestmirrorsets`, `imagetagmirrorsets`, `operatorhubs`}, `samples.operator.openshift.io` {`configs`}, `imageregistry.operator.openshift.io` {`configs`, `imagepruners`}, `operators.coreos.com` {`catalogsources`}, `console.openshift.io` {`consolesamples`, `consoleyamlsamples`}. Re-run the cross-tenant-leak check.
- Optional **`platform-portfolio/components/image-registry`** (model on `redhat-cop/gitops-catalog/openshift-image-registry`) only if `defaultRoute`/storage-sizing/pruner-tuning must be event-managed.
- **Instructor-guide scheduling block** listing the cluster-wide demos, their blast radius, and the safe window (start-of-day or a dedicated maintenance slot; never during M02 or any import-heavy module).

### Concept diagram (≥1, per style guide) — two supply chains on one page

1. **Image supply**: external registries → (pull secret / `allowedRegistriesForImport` / `registrySources` / IDMS-ITMS mirror) → internal registry (svc:5000 + PVC + nightly pruner) → ImageStream (importPolicy.scheduled, referencePolicy Local) → workload. Trust axis ties **M08** (signature admission = the complementary control) and **M02** (builds push here).
2. **Catalog supply**: OperatorHub sources / `CatalogSource` · samples operator `Config` (skipped lists) · `ConsoleSample` · namespaced `Template` · devfile registry (community + Dev Spaces/CheCluster → **M03**) → the developer catalog **M02** uses. "The platform team decides what developers can run and offer."

### Cross-module fit (no overlap)

- **M02** owns builds→istag, catalog *browsing*, the `java-21` stream, UBI trusted content. M17 goes deeper on the registry/ImageStream *lifecycle* (scheduled imports, Local reference, pull-secrets-to-SA, promotion, pruning) and the *governance* layer above the catalog — it does not re-teach "what is an ImageStream / import from Git."
- **M08** owns sigstore signature admission (`ImagePolicy`/`ClusterImagePolicy` — a *different* axis: whether an image is trusted). M17's trust boundary = *where images may come from* (registry sources / mirroring). Reference M08, don't re-teach it.
- **M03** owns devfile *authoring* in Dev Spaces. M17's devfile beat = *where catalog devfiles come from* (supply/governance), pointing to M03 for the private (CheCluster) devfile registry.
