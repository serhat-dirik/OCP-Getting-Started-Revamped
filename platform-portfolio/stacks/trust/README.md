# stack: trust

The platform prerequisite for the workshop's **`trusted-supply-chain`** module. Installs the shared
supply-chain security infrastructure as an Argo CD app-of-apps: scan images, sign them (with a key, and
keyless with a workload's SPIFFE identity), and prove what is inside. Everything here is a **single
shared install** — never per-user; the per-user wiring is the module's entry state (below).

```bash
./argocd-bootstrap/install.sh --stacks trust
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,trust
```

## What it installs

| Component | Operator (channel) | Config | Stack wave |
|---|---|---|---|
| `rhacs-operator` | `rhacs-operator` (`stable`; v5.0.0 live 2026-11-13) | AllNamespaces OperatorGroup | 0 |
| `trust-signing` | — (needs only openshift-pipelines) | hook Job → cosign key in `signing-secrets` + exports `chains-cosign-pub` | 0 |
| `rhacs-central` | — (uses the operator) | `Central` + init-bundle hook (sensor bundle + CI token) + `SecuredCluster` + delegated-scanning + "Block Log4Shell at build" `SecurityPolicy` | 1 |
| `zero-trust-workload-identity-operator` | `openshift-zero-trust-workload-identity-manager` (`stable-v1` = v1.1.3) | AllNamespaces OperatorGroup. Operator only, so an adopting cluster skips it | 1 |
| `workload-identity` | — (uses the operator) | PostSync hook: creates the SPIRE operands (trust domain = apps domain, issuer `https://oidc-discovery.<apps domain>`) unless the cluster already runs SPIRE, waits for OIDC discovery, then points Fulcio at it | 2 |
| `rhtas` | `rhtas-operator` (`stable` = v1.5.1) | v1 `Securesign` (Fulcio/Rekor/CTlog/Trillian/TUF/TSA) + the Fulcio SPIFFE-issuer hook, which then makes Tekton Chains sign keyless | 3 |
| `policy-controller-operator` | `policy-controller-operator` (`stable` = v1.1.2) | AllNamespaces OperatorGroup in `openshift-policy-controller`. Operator only, so an adopting cluster skips it | 4 |
| `policy-controller` | — (uses the operator) | `PolicyController` webhook in `policy-controller-operator` (enforced on `policy.rhtas.com/include=true` namespaces, `no-match-policy: allow`) + PostSync hook → `TrustRoot trusted-artifact-signer` from this cluster's TUF root | 5 |

App-waves order **creation** only: child Applications carry no health, so nothing here assumes a
lower-wave app is ready. Each hook waits for exactly what it needs (the operands hook for the ZTWIM
CRDs; the Fulcio issuer script for both the Securesign and the issuer, run by both hooks so whichever
finishes last completes it). The ZTWIM operator needs a connected cluster (its catalog entry says
`disconnected: "false"`).

## How the pieces serve `trusted-supply-chain`

- **Scan gate (LAB):** the module pipeline's `acs-image-check` task runs `roxctl image check` against the
  built image; the shipped **"Block Log4Shell (CVE-2021-44228) at build"** `SecurityPolicy` (BUILD +
  `FAIL_BUILD_ENFORCEMENT`) fails the build on the seeded log4j-core. Deterministic (feed-independent
  of severity thresholds): a clean image lacks the CVE and passes.
- **Signing (LAB):** Tekton Chains signs **every pipeline-built image and its in-toto SLSA provenance
  keyless**, with no per-run wiring: the rhtas hook gives the Chains controller the SPIFFE ID
  `spiffe://<trust domain>/ns/openshift-pipelines/sa/tekton-chains-controller` (static SPIRE entries
  `ogsr-spire-agents` + `ogsr-tekton-chains-controller`: SPIRE skips `openshift-*` namespaces) and points
  TektonConfig `spec.chain` at Fulcio (`provider: spiffe`), Rekor and TUF through their in-cluster
  Services. A 10-minute certificate per signature; Rekor's entry time keeps it verifiable afterwards.
  Verify: `cosign initialize --mirror http://tuf.trusted-artifact-signer.svc --root
  http://tuf.trusted-artifact-signer.svc/root.json`, then `cosign verify --certificate-identity <that ID>
  --certificate-oidc-issuer https://oidc-discovery.<apps domain> <image@digest>`. `trust-signing`'s
  cosign key stays in `signing-secrets` but Chains no longer uses it once Fulcio is on.
- **Admission (LAB):** the `policy-controller` webhook refuses, in a labelled namespace, an image a
  consumer's `policy.sigstore.dev` `ClusterImagePolicy` matches unless it satisfies it
  (`trustRootRef: trusted-artifact-signer`). Every image in a labelled namespace must resolve to a
  digest: the webhook resolves tags with the pod's pull secrets, so a tag it cannot read (e.g.
  `registry.redhat.io/...:tag`, which only the node's global pull secret can pull) is refused with
  "must be an image digest" — pin such images by digest.
- **Block-unsigned (LAB, [OCP]):** the attendee applies a native namespaced `ImagePolicy`
  (`policyType: PublicKey`, the exported cosign public key) — no operator required.
- **Keyless signing + Rekor transparency (LAB):** a workload's SPIFFE identity is the signer. ZTWIM
  runs SPIRE; Fulcio trusts SPIRE's OIDC issuer (`type: spiffe`, `clientID: sigstore`, scoped by
  `spiffeTrustDomain`), so a pod holding a JWT-SVID gets a short-lived certificate whose URI SAN is
  its own ID — `spiffe://<apps domain>/ns/<namespace>/sa/<service account>`. Tekton Chains is one such
  workload (above). On a cluster that already runs SPIRE, Fulcio trusts THAT issuer and trust domain
  instead; nothing of theirs is changed.

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

## The entry-state seam (NOT installed here)

This stack is workshop-agnostic. The **per-user** wiring is the `trusted-supply-chain` entry state
(`gitops/entry-states/trusted-supply-chain/`, built separately) and layers on top:

- Copies the shared `stackrox/rox-api-token` and `openshift-pipelines/chains-cosign-pub` into
  `{user}-cicd` (least-privilege cross-namespace RBAC).
- The workshop layer's `ClusterSPIFFEID ogsr-attendee-signers` registers attendee pods labelled
  `workshop.redhat.com/spiffe-signer: "true"`. The operator's own fallback ClusterSPIFFEID
  (`zero-trust-workload-identity-manager-spire-default`) gives the same ID shape to any pod that mounts
  `csi.spiffe.io`, so the label documents intent; attestation (own namespace and service account) is
  what keeps one attendee from holding another's identity.
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
oc get csv -n zero-trust-workload-identity-manager                      # ZTWIM Succeeded
oc get zerotrustworkloadidentitymanager,spireserver,spireagent,spiffecsidriver,spireoidcdiscoveryprovider cluster
ISSUER=$(oc get spireoidcdiscoveryprovider cluster -o jsonpath='{.spec.jwtIssuer}')
curl -s "$ISSUER/.well-known/openid-configuration"                      # issuer + jwks_uri on the same host
oc get securesign securesign -n trusted-artifact-signer -o jsonpath='{.spec.fulcio.config.oidcIssuers}'   # type spiffe
oc get tektonconfig config -o jsonpath='{.spec.chain}'                 # signers.x509.fulcio.* + transparency.*
oc get clusterstaticentry ogsr-tekton-chains-controller                # Chains' SPIFFE ID
oc get csv -n openshift-policy-controller                               # policy-controller Succeeded
oc get cm config-policy-controller -n policy-controller-operator -o jsonpath='{.data}'   # no-match-policy allow
oc get trustroot trusted-artifact-signer
```

## Uninstall

Delete the stack Applications (`oc delete application pp-rhacs-operator pp-rhacs-central pp-rhtas
pp-trust-signing pp-workload-identity pp-zero-trust-workload-identity-operator pp-policy-controller
pp-policy-controller-operator -n openshift-gitops`) —
prune removes the components. The cosign key in `signing-secrets` is left in place (deleting it would
unsign Chains); remove manually if desired.

Hooks also create the `TrustRoot trusted-artifact-signer`, the `ClusterStaticEntry`s
`ogsr-spire-agents` + `ogsr-tekton-chains-controller` (labelled `workshop.redhat.com/owner=ogsr`) and the
TektonConfig `spec.chain` signer keys; no prune removes them.

The SPIRE operands are created by a hook, so no prune removes them. Delete the ones carrying
`workshop.redhat.com/owner=ogsr` BEFORE the operator Application, in this order (the product docs'):
`spireoidcdiscoveryprovider`, `spiffecsidriver`, `spireagent`, `spireserver`,
`zerotrustworkloadidentitymanager` (all named `cluster`), then
`oc delete pvc -l app.kubernetes.io/name=spire-server -n zero-trust-workload-identity-manager`. The
workshop's `bootstrap/ogsr-uninstall.sh` does exactly that, and leaves unlabelled (pre-existing) SPIRE
alone.
