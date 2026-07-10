# component: rhtpa (OPTIONAL — instructor-demo only)

Red Hat Trusted Profile Analyzer — the enterprise SBOM/VEX explorer UI. This is the **optional
"go deeper" SBOM beat** for M08; the module's core SBOM lesson is app-native CycloneDX inspected in
the terminal (`cosign download sbom | jq`), which needs none of this.

**Not in the core `trust` stack** (build-note verdict + PM decision 2026-07-09: RHTPA = optional
`trust-demo` component, INSTRUCTOR-DEMO only, PROVISIONAL — Serhat may cut at G5). It is heavy
(~12–15 pods) and, unlike RHACS/RHTAS, installs **SingleNamespace** and needs three external
contracts before the `TrustedProfileAnalyzer` CR will come up:

1. **OIDC** — a realm/client on the shared Red Hat build of Keycloak (issuer + client secret).
2. **Object storage** — a NooBaa `ObjectBucketClaim` (storageclass `openshift-storage.noobaa.io`
   is present on this cluster) for the SBOM/advisory store.
3. **Database** — a PostgreSQL (the CR can create one, or reference an external DSN).

This component installs **only the operator** (Subscription + SingleNamespace OperatorGroup). Bringing
up the stack is a deliberate instructor step: supply the contracts above, then apply a
`TrustedProfileAnalyzer` CR (`rhtpa.io/v1`) with `oidc`, `storage`, `database`, and `appDomain`.
Fields are version-sensitive — `oc explain trustedprofileanalyzer.spec` + the catalog alm-example on
the live operator before authoring the CR (this component was intentionally NOT installed live —
cut-candidate; verify on first enable).

Enable via the `trust-demo` stack:

```bash
./argocd-bootstrap/install.sh --stacks trust,trust-demo
```
