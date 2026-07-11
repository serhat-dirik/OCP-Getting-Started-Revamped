# M08 build note — Trusted Software Supply Chain

Date: 2026-07-09 · Author: research-analyst R4b · Spec: 02-MODULE-SPECS §M08 (lines 108-117) · Entitlement: **[ADS]** (Red Hat Advanced Developer Suite)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22, k8s 1.34.8) — OLM packagemanifests, `oc explain`, live TektonConfig/CRD inspection; docs.redhat.com (RHACS, Pipelines, OCP config-APIs); versions.yaml (2026-07-08) cross-checked and re-confirmed live.

## Verified versions

| Product | Version | Channel | Install mode | Source | Date |
|---|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | — | `oc version` (live) | 2026-07-09 |
| Advanced Cluster Security (RHACS) | 4.11.1 | **stable** (=`rhacs-4.11`) | AllNamespaces | packagemanifest `rhacs-operator` (live); versions.yaml | 2026-07-09 |
| Trusted Artifact Signer (RHTAS) | 1.4.1 | **stable** (=`stable-v1.4`) | AllNamespaces | packagemanifest `rhtas-operator` (live) | 2026-07-09 |
| Trusted Profile Analyzer (RHTPA) | 1.1.6 | **stable-v1.1** | **OwnNamespace / SingleNamespace** | packagemanifest `rhtpa-operator` (live) | 2026-07-09 |
| OpenShift Pipelines (Tekton + Chains) | 1.22.4 | latest (=pipelines-1.22) | AllNamespaces | packagemanifest + live TektonConfig | 2026-07-09 |
| Native sigstore admission (ImagePolicy) | GA (OCP 4.20+) | n/a (core) | namespaced CRD | live CRD `imagepolicies.config.openshift.io/v1` | 2026-07-09 |

Cluster reality (verified live 2026-07-09):

- **Tekton Chains is already installed and READY** — `TektonChain/chain` v0.26.3 (`READY=True`). `TektonConfig/config` (`spec.profile: all`, ns `openshift-pipelines`) has `spec.chain` set: `artifacts.pipelinerun.format=in-toto`, `artifacts.taskrun.format=in-toto`, `artifacts.oci.format=simplesigning`, all `storage=oci`, `disabled=false`. So provenance = **in-toto (SLSA) attestations stored in the OCI registry**; the module configures *how it signs*, not whether Chains exists.
- **No signing key yet** — `secret/signing-secrets` in `openshift-pipelines` is **absent**. Key-based Chains needs it created; keyless needs Fulcio config instead.
- **RHTAS `Securesign` CR** (`rhtas.redhat.com/v1alpha1`) composes owned CRDs Fulcio, Rekor, CTlog, Trillian, Tuf, TimestampAuthority. Keyless linchpin = `spec.fulcio.config.OIDCIssuers[]` (`Issuer`/`IssuerURL`/`ClientID`/`Type`). `spec.tuf.rootKeySecretRef: tuf-root-keys` + `spec.tuf.keys[]` (rekor.pub, ctfe.pub, fulcio_v1.crt.pem, tsa.certchain.pem). External access + monitoring toggles per component. (alm-example, live)
- **RHACS** = two CRs: `Central` (`platform.stackrox.io/v1alpha1`, spec root `central`) + `SecuredCluster` (spec root `clusterName`), plus `SecurityPolicy` (`config.stackrox.io/v1alpha1`). RHACS verifies **only Cosign** signatures (public keys **and** certificates/keyless); admission enforcement via the **"Not verified by trusted image signers"** policy criterion set to *Inform and enforce* (docs.redhat.com RHACS 4.x "Verifying image signatures").
- **Native `ImagePolicy`** (`config.openshift.io/v1`, **namespaced**, GA 4.20+; core-payload verify added 4.21): `spec.policy.rootOfTrust.policyType ∈ {PublicKey, FulcioCAWithRekor, PKI}`; `publicKey.keyData` for key-based, `fulcioCAWithRekor.{fulcioCAData,fulcioSubject.{oidcIssuer,signedEmail},rekorKeyData}` for keyless; `spec.scopes[]` (image-repo scope) + `spec.policy.signedIdentity.matchPolicy`. (`oc explain imagepolicy.spec`, live)
- **Worker capacity**: 3 workers × 15.5 CPU / ~30Gi = ~46 CPU / ~90Gi allocatable; current use ~1.8 CPU / ~18Gi → **~44 CPU / ~72Gi free** (`oc get nodes`, `oc adm top nodes`). Ample for shared trust services.
- **`pipelines/` task library is EMPTY** (net-new); `apps/parasol-claims` exists (Quarkus 3.33.2.1, JDK 21, UBI9 `openjdk-21:1.23` multi-stage Containerfile, `com.parasol.claims`).

## Spec deltas

- **Chains already on** — spec implies "enable Chains"; it's installed and configured for in-toto/OCI. The teachable action is configuring **signing identity** (cosign key or Fulcio keyless) + `signing-secrets`, not enabling Chains. Re-word objective.
- **Product name** — "[ADS]" is now **Red Hat Advanced Developer Suite (RHADS)** (GA 2025-07-01; ex-"Trusted Application Pipeline"/RHTAP). Content must use RHADS or the individual product names; **never "RHTAP"** (mining source `showroom-rhtap` uses the dead name — oldcontent-mining-index §6). Not yet in 04-STYLE-GUIDE §5 ban list — recommend adding "RHTAP → RHADS / product names".
- **ACS entitlement** — ACS ships in **both** OpenShift Platform Plus **and** RHADS (developers.redhat.com RHADS overview). Spec footnote ‡ is right; content should say "included in Platform Plus and in RHADS," not ADS-only.
- **Native admission is [OCP] now** — spec assumes the "block unsigned" gate is an ACS/[ADS] job; OCP 4.20+ ships **namespaced `ImagePolicy`** (GA). The per-user beat can be [OCP], strengthening the D16 "lead with what OpenShift includes" framing. Spec should acknowledge the OCP path.
- **RHTPA install mode** — spec/versions.yaml imply a normal cluster operator; it is **OwnNamespace/SingleNamespace** and deploys a ~12-pod stack needing its own OIDC + object storage + Postgres. Materially affects stack design (see risks).
- **M07 not built; `pipelines/` empty** — entry state cannot assume M07's pipeline exists; M08 must define the pipeline/task library itself (compose-don't-chain).

## Approach recommendations (≤5)

1. **Signing = key-based cosign for the per-user lab; keyless Fulcio = [INSTRUCTOR-DEMO].** Install full shared `Securesign` (gives cosign/TUF + the keyless "short-lived cert + Rekor entry" wow), but attendees sign with a cosign key in `signing-secrets` (deterministic, no per-user OIDC wiring) — resolves the spec's "pick one, document" watchout.
2. **Per-user "block unsigned" via native namespaced `ImagePolicy`** (`policyType: PublicKey`, cosign pubkey, `scopes` = user's claims repo) — [OCP], reliable, per-ns; keep **ACS admission** ("Not verified by trusted image signers", Inform+enforce) as the cluster-wide [INSTRUCTOR-DEMO].
3. **SBOM = app-native CycloneDX** (Quarkus/`cyclonedx-maven-plugin` emits CycloneDX at build) → `cosign attest --type cyclonedx` → inspect with `cosign download sbom`/`jq` in the terminal (find the seeded vulnerable dep). No dependency on community syft; RHTPA becomes the optional "enterprise SBOM UI" demo.
4. **ACS is the pipeline gate**: `roxctl image scan`/image-check task fails the build on a **pinned reproducible CVE** (seeded vulnerable base tag/dep); fix = bump base image → re-run. Shared Central, per-user pipeline task + secured-cluster admission.
5. **Scope RHTPA to demo/optional component** (heavy + own OIDC/object-store); if wave capacity or build time is tight, **cut RHTPA to a "go deeper" pointer** and let CycloneDX terminal inspection carry the SBOM lesson.

## Exercise arc (Parasol framing · target 45-60 min hands-on + ~15 min concept)

Hook: *"Parasol just failed a supplier audit — nobody could prove which build produced the claims image running in prod, or what's inside it."*

1. `[~10m]` **Scan gate** — add ACS image-check task to the claims pipeline; run → **fails on the seeded CVE** in the base/dep. Read the CVE. *(ACS, [ADS])*
2. `[~5m]` **Fix the base** — bump `ubi9/openjdk-21` tag; re-run; gate passes (continues the M02 "trusted UBI base" thread).
3. `[~10m]` **Sign + attest** — pipeline produces image; Chains signs (cosign key) + emits **in-toto SLSA provenance**; `cosign verify --key` + `cosign verify-attestation` in the terminal.
4. `[~10m]` **SBOM** — build emits CycloneDX; `cosign attest`/`download sbom`; grep the log4shell-style dep. *(optional: open the same SBOM in shared RHTPA — instructor)*
5. `[~10m]` **Only-signed-runs** — attendee applies a namespaced `ImagePolicy` to `{user}-dev`; their signed image deploys, an unsigned `docker.io/...` pull is **blocked**. *(OCP)*
6. `[demo]` **The block moment** + keyless Fulcio short-lived-cert + Rekor transparency entry (instructor, shared RHTAS). *(the 15-min SA demo arc)*

When-not-to-use (wrap-up): keyless OIDC complexity, Rekor retention, ACS scan cache (4h) vs admission real-time.

## NEW platform stack — `pp-trust` (stacks/trust/) — fully specified

Follows the `platform-portfolio` component pattern (Subscription+OperatorGroup+namespace+config CR, Argo `Application` per component, sync-waves). Repo pattern matches `components/kueue` and `stacks/batch` (verified in-repo).

- **`components/rhacs-operator`** — `Subscription` (name/pkg `rhacs-operator`, ns `rhacs-operator`, channel **`stable`**, source `redhat-operators`) + AllNamespaces `OperatorGroup`. Wave 0.
- **`components/rhacs-central`** — `Central` CR (`platform.stackrox.io/v1alpha1`, ns `stackrox`, `spec.central: {}` defaults) wave 2 + **init-bundle bootstrap** (hook Job using the Central API/roxctl to mint the sensor bundle secret) + `SecuredCluster` CR (`spec.clusterName: ocp-ws-revamped`) wave 3. *Mine `redhat-cop/gitops-catalog` ACS base for the init-bundle Job (oldcontent-mining-index §2b).* `SkipDryRunOnMissingResource=true` on CRs.
- **`components/rhtas`** — `Subscription` (`rhtas-operator`, channel **`stable`** or pin `stable-v1.4`, ns `trusted-artifact-signer`) + AllNamespaces `OperatorGroup` + `Securesign` CR (ns `trusted-artifact-signer`) with `fulcio.config.OIDCIssuers[]` = cluster SA-token issuer (`Type: kubernetes`) for keyless-from-CI, `tuf.rootKeySecretRef: tuf-root-keys` (secret contract). Wave 2 CR.
- **`components/trust-signing`** — two hook Jobs (mirrors `components/git-mirror` job pattern): (a) `cosign generate-key-pair k8s://openshift-pipelines/signing-secrets`; (b) server-side-apply patch of the operator-owned singleton `TektonConfig/config` `spec.chain` (`transparency.enabled/url` = Rekor; for keyless add `signers.x509.fulcio.*`). **ADR needed**: Argo cannot co-own the operator-managed `TektonConfig`; use a patch Job, not a managed manifest.
- **`components/rhtpa` (OPTIONAL / demo profile)** — `Subscription` (`rhtpa-operator`, channel **`stable-v1.1`**, ns `rhtpa`) + **SingleNamespace `OperatorGroup` targeting `rhtpa`** (NOT AllNamespaces) + `TrustedProfileAnalyzer` CR (`rhtpa.io/v1`) with `oidc` (own realm on shared rhbk), `storage` (noobaa OBC — `openshift-storage.noobaa.io` SC present), `database`, `appDomain`. Keep in a `trust-demo` stack variant, not the core `pp-trust`.
- **Footprint estimate (shared, validate with `oc adm top` post-install)**: ACS ~5-6 CPU / 13-16Gi (Central+DB+scanner+DB+sensor) · RHTAS ~1.5-2.5 CPU / 3-5Gi (~8 sigstore pods) · RHTPA ~4-6 CPU / 8-12Gi (~12-15 pods) · Recommend **single shared instance of each**; RHTPA optional. All fit ~44 CPU/72Gi free.

## Entry-state requirements — `gitops/entry-states/m08/` (per-user, self-contained)

Compose-don't-chain (README rules): materialize the whole build world; do **not** reference M07.

- `{user}-cicd` in-namespace state: the **claims build→scan→sign pipeline + task library** (Parasol tasks; net-new in `pipelines/`), the user's Gitea fork of `parasol-claims` seeded at a **known-vulnerable commit** (older base tag / pinned CVE dep — documented intentional flaw), cosign **public-key** ConfigMap for verify, RBAC to read ACS + Rekor.
- Hook Job (Sync/BeforeHookCreation, per m06 `claims-data.yaml` pattern): run one baseline `PipelineRun` so a signable image exists at entry.
- `{user}-dev`: deploy target for the `ImagePolicy` admission beat (workshop-layer ns; survives reset).
- `ws-meta.yaml purgeNamespaces: {user}-cicd` (clear PipelineRuns/images on reset). Idempotent templates.
- Shared references (not per-user): ACS Central endpoint, RHTAS TUF/Rekor URLs, `signing-secrets` (in `openshift-pipelines`).

## App requirements (`apps/parasol-claims`)

- Add **CycloneDX SBOM** generation (`cyclonedx-maven-plugin`, or Quarkus CycloneDX) to the pom — exact coordinates `TODO(verify-at-build)`.
- Provide a **reproducible vulnerable variant** for the CVE gate: an older base-image tag (contrast with current `openjdk-21:1.23`) and/or a pinned CVE-bearing dependency, in a seed branch, documented under the README "Intentional flaws — do not fix" convention.
- No runtime code change; supply-chain metadata + build wiring only.

## Mining results

- `repos/showroom-rhtap` (rhpds) → SBOM/Enterprise-Contract/attestation **flow shape only**; **flag: rename RHTAP→RHADS, re-verify every product name/UI** (oldcontent-mining-index §2b, §6).
- `adv-app-platform-demo-showroom` M5 (Dependency Analytics / shift-left) + M6 (SBOM w/ TPA, topology) → the "pipeline-catches-a-bug" + "SBOM/attestation close" narrative; screenshot set `ocp-pipeline-*` (oldcontent-mining-index §4). License=none → ideas only.
- `redhat-ads-tech/parasol-insurance-manifests` `build/` → the real Tekton supply-chain shape (maven-build, sonar-scan, external secrets) to model the Parasol task library on (oldcontent-mining-index §3). Re-implement (license=none).
- Tech: docs.redhat.com RHACS "Verifying image signatures"; Pipelines "Using Tekton Chains for supply chain security"; live `TektonConfig.spec.chain`; RHTAS learning path (developers.redhat.com).

## Open risks & feasibility verdicts

- **LAB-VIABLE**: ACS scan+CVE-fail gate; key-based cosign sign + in-toto attest + `cosign verify`; CycloneDX SBOM + terminal inspection; per-user native `ImagePolicy` block-unsigned.
- **DEMO-ONLY**: keyless Fulcio/Rekor signing (per-user OIDC wiring too fragile in 60 min); ACS cluster-wide admission policy; RHTPA SBOM UI.
- **CUT CANDIDATE**: RHTPA entirely (heavy, own OIDC/object-store; CycloneDX terminal beat covers the SBOM objective) — PM/project-owner call; keep as optional `trust-demo` component if kept.
- **ACS init-bundle bootstrap** is the fragile install step (SecuredCluster needs a Central-minted secret) — solve with a hook Job; test idempotency.
- **`TektonConfig` singleton ownership** — patch-Job, not Argo-managed manifest (ADR).
- **RHACS signature cache is 4h** — for the lab, admission enforcement is real-time on deploy but the *scan/policy re-eval* lags; script the demo to avoid the cache window (`TODO(verify-on-cluster)` the exact enforcement timing).
- **ImagePolicy exact fields** GA-new — platform-engineer must `oc explain imagepolicy.spec.policy` at build and test a real block (image pull-through + signature discovery in the internal registry).
- Capacity: all shared services ≈ +16 CPU / +34Gi; fits, but RHTPA is the margin risk on an 8-user run.

## Builder appendix — grounded sketches (live 2026-07-09)

```yaml
# 1) Per-user block-unsigned — native, namespaced, [OCP], GA 4.20+ (oc explain imagepolicy.spec)
apiVersion: config.openshift.io/v1
kind: ImagePolicy
metadata: {name: only-signed-claims, namespace: user1-dev}
spec:
  scopes: ["image-registry.openshift-image-registry.svc:5000/user1-dev/parasol-claims"]
  policy:
    rootOfTrust:
      policyType: PublicKey            # key-based lab path
      publicKey: {keyData: <base64 cosign.pub>}   # keyless alt: FulcioCAWithRekor{fulcioCAData,fulcioSubject{oidcIssuer,signedEmail},rekorKeyData}
    signedIdentity: {matchPolicy: MatchRepoDigestOrExact}
```

```sh
# 2) Tekton Chains signing config — patch the operator-owned singleton (NOT Argo-managed)
oc patch tektonconfig config --type merge -p '{"spec":{"chain":{
  "transparency.enabled":"true","transparency.url":"https://rekor-server-trusted-artifact-signer.<domain>",
  "artifacts.pipelinerun.format":"in-toto"}}}'    # live baseline already in-toto/oci/simplesigning
cosign generate-key-pair k8s://openshift-pipelines/signing-secrets   # key-based; secret is ABSENT today
```

RHACS admission (instructor): SecuredCluster up → Signature Integration (cosign pubkey) → default policy *"Not verified by trusted image signers"* → Inform **and enforce**, scope = `user*-dev` (docs.redhat.com RHACS 4.x).
