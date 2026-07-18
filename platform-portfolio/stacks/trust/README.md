# stack: trust

The platform prerequisite for **M09 — Trusted Software Supply Chain [ADS]**. Installs the shared
supply-chain security infrastructure as an Argo CD app-of-apps: scan images, sign them, and prove
what is inside. Everything here is a **single shared install** — never per-user; the per-user wiring
is the M09 entry state's job (below).

```bash
./argocd-bootstrap/install.sh --stacks trust
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,trust
```

## What it installs

| Component | Operator (channel) | Config | Stack wave |
|---|---|---|---|
| `rhacs-operator` | `rhacs-operator` (`stable` = v4.11.1) | AllNamespaces OperatorGroup | 0 |
| `trust-signing` | — (needs only openshift-pipelines) | hook Job → cosign key in `signing-secrets` + exports `chains-cosign-pub` | 0 |
| `rhacs-central` | — (uses the operator) | `Central` + init-bundle hook (sensor bundle + CI token) + `SecuredCluster` + delegated-scanning + "Block Log4Shell at build" `SecurityPolicy` | 1 |
| `rhtas` | `rhtas-operator` (`stable` = v1.4.2) | `Securesign` (Fulcio/Rekor/CTlog/Trillian/TUF/TSA) — keyless-signing demo | 2 |

Operators are **wave-serialized** (rhacs wave 0 → rhtas wave 2) so only one OLM install churns at a
time. `rhacs-central` (wave 1) runs after the operator's CRDs exist.

## How the pieces serve M09

- **Scan gate (LAB):** the M09 pipeline's `acs-image-check` task runs `roxctl image check` against the
  built image; the shipped **"Block Log4Shell (CVE-2021-44228) at build"** `SecurityPolicy` (BUILD +
  `FAIL_BUILD_ENFORCEMENT`) fails the build on the seeded log4j-core. Deterministic (feed-independent
  of severity thresholds): a clean image lacks the CVE and passes.
- **Signing (LAB):** `trust-signing` gives Tekton Chains a cosign key, so **every pipeline-built image
  is signed + gets in-toto SLSA provenance** with no per-run wiring. `cosign verify --key` (the public
  key is exported as `chains-cosign-pub`) is the attendee's terminal beat. **This needs neither RHTAS
  nor keyless OIDC.**
- **Block-unsigned (LAB, [OCP]):** the attendee applies a native namespaced `ImagePolicy`
  (`policyType: PublicKey`, the exported cosign public key) — no operator required.
- **Keyless signing + Rekor transparency (INSTRUCTOR DEMO):** RHTAS (`Securesign`). Fulcio is wired to
  the cluster ServiceAccount-token issuer (`kubernetes` / `https://kubernetes.default.svc`) so a
  Tekton SA token is a keyless identity. Per-user keyless wiring is too fragile for a 60-min lab
  (build-note verdict) — demo only.

## The fragile install step (RHACS bootstrap)

SecuredCluster needs a Central-minted **init bundle** (sensor/collector/admission-control TLS) and the
scan gate needs a **roxctl API token** — both one-time secrets only available at generation time. The
`init-bundle` hook Job mints them against the live Central API (idempotent: skips if present, never
logs a secret). A separate `delegated-scanning` PostSync hook enables **delegated scanning** so Central
can scan images in the **cluster-local** OpenShift registry (verified: without it `roxctl image check`
fails "no matching image registries found"). Central's Scanner V4 downloads its vulnerability store on
first boot — allow it to finish (can take a while on a cold cluster) before the first scan succeeds.

## Footprint (live, ocp-ws-revamped 2026-07-11)

- **RHACS** (18 pods: Central + central-db + Scanner V2 + Scanner V4 + sensor + collector DaemonSet +
  admission-control): ~3.5 cores / ~7.3 Gi in use (scanner replicas pinned to 1 — autoscaling off).
- **RHTAS** (12 pods, sigstore stack): ~0.2 cores / ~0.65 Gi idle.
- Cluster had ~60 cores / ~180 Gi free before install — ample. RHTPA (the optional `trust-demo`
  component) would add ~12–15 more pods; it is default-off.

## The M09 entry-state seam (NOT installed here)

This stack is workshop-agnostic. The **per-user** wiring is the M09 entry state
(`gitops/entry-states/trusted-supply-chain/`, built separately) and layers on top:

- Copies the shared `stackrox/rox-api-token` and `openshift-pipelines/chains-cosign-pub` into
  `{user}-cicd` (least-privilege cross-namespace RBAC).
- The attendee's Gitea fork of `parasol-claims` with a `seed-vulnerable` branch (older base tag +
  log4j-core CVE) and the `parasol-claims-supply-chain` pipeline.

## Verify

```bash
oc get applications -n openshift-gitops -l portfolio.redhat.com/component | grep -E 'rhacs|rhtas|trust'
oc get csv -A | grep -E 'rhacs-operator|rhtas-operator'                 # both Succeeded
oc get central,securedcluster -n stackrox                               # Deployed
oc get securitypolicy block-log4shell-at-build -n stackrox              # the gate
oc get secret signing-secrets -n openshift-pipelines -o jsonpath='{.data.cosign\.pub}' | wc -c   # cosign key present
oc get securesign -n trusted-artifact-signer                            # sigstore stack
```

## Uninstall

Delete the stack Applications (`oc delete application pp-rhacs-operator pp-rhacs-central pp-rhtas
pp-trust-signing -n openshift-gitops`) — prune removes the components. The cosign key in
`signing-secrets` is left in place (deleting it would unsign Chains); remove manually if desired.
