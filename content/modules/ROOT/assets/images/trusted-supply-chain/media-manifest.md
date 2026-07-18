# Trusted Software Supply Chain — media manifest

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
Shoot as **user1** (or any prepped user) on the workshop cluster, 16:10, default console theme,
annotate with numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a commented
`// media-pass: …` line — replace with the `image::` when the asset lands.

**Rebalance note (2026-07-18):** the module now builds the trust story on a **pre-scanned** clean
image, with scanning compressed to one red beat (the seeded `:candidate` build). All mechanics were
**re-performed and captured from the CLI/API as user3 on 2026-07-18**: the seeded `:candidate` run
Failed at `acs-scan` on Log4Shell (CVSS 10, log4j-core 2.14.1) in 7m11s; the warm clean run passed
(`scan-passed=true`) and Chains-signed `parasol-claims:latest`; `cosign` + `rekor-cli` fetched from
the RHTAS cli-server; `cosign verify`/`verify-attestation` RC=0 (SLSA provenance v0.2); keyless
`cosign sign-blob` recorded the SBOM in the live Rekor log, `verify-blob` → `Verified OK`. The
console/RHACS/Rekor-UI screenshots below are the **deferred media pass** (the build was CLI-driven).

## Staging the red (and green) states — READ THIS FIRST

The wave-1 capture pass was blocked because "the red state isn't reproducible right now" (the seed bug,
fixed 2026-07-18). It is now deterministic. Stage each state as follows, as the shoot user (`NS=<user>-cicd`).

### Prerequisite: the environment is pre-warmed
`ws prep trusted-supply-chain --user <user> --yes` (or `ws start …`) leaves a **green** state already in
place — a scanned, signed `parasol-claims:latest` — so the *green* verdict and the *signed image* views
(screens 4–5) need no extra work. Only the **red** state must be produced.

### Producing the RED state (the seeded build the gate refuses)
Run the seeded branch to a throwaway `:candidate` tag (identical to lab exercise 1). It takes ~7 min and
ends `Failed` at `acs-scan`:

```sh
NS=<user>-cicd
oc create -n $NS -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata: {generateName: shoot-vuln-}
spec:
  pipelineRef: {name: parasol-claims-supply-chain}
  params:
    - {name: git-revision, value: seed-vulnerable}
    - {name: image, value: "image-registry.openshift-image-registry.svc:5000/$(context.pipelineRun.namespace)/parasol-claims:candidate"}
  taskRunTemplate: {serviceAccountName: pipeline}
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate: {spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}}
  taskRunSpecs:
    - {pipelineTaskName: sbom-report, computeResources: {requests: {memory: 1Gi}, limits: {memory: 1536Mi}}}
    - {pipelineTaskName: build-image, computeResources: {requests: {memory: 1536Mi}, limits: {memory: 2Gi}}}
EOF
```

**Timing the shot:** the red state is only visible **after** `build-image` succeeds and `acs-scan` runs
(~6–7 min in). Watch with `tkn pipelinerun logs --last -f -n $NS`; when you see `❌ image check FAILED`,
the run is red and RHACS has the scan result. The red PipelineRun graph and the RHACS violation persist
after the run finishes, so there is no rush once it is red.

**Which view shows each red state:**
| Red state | Where it renders | Notes |
|-----------|------------------|-------|
| The **violation** (the CVE) | RHACS console (`{acs_console_url}`) → **Vulnerability Management** → Images → `parasol-claims:candidate`, and → **Violations** (the `Block Log4Shell at build` policy) | The RHACS store must be **warm** (~1 h after a fresh install) or the scan finds nothing — pre-warm first, confirm the CLI log prints `Block Log4Shell` |
| The **red pipeline** | OCP console → **Pipelines → PipelineRuns** → the `shoot-vuln-…` run — `build-image` green, `acs-scan` red | The load-bearing message is in the `acs-scan` step log, shown inline in the lab |
| The **gate log** | Same run → `acs-scan` step **Logs** tab | The `TOTAL: 1 … CRITICAL: 1` + `Block Log4Shell (CVE-2021-44228) at build` table |

**Reset between shots:** the red state is idempotent — re-running the same PipelineRun reproduces it. To
return to a clean slate, `ws prep trusted-supply-chain --user <user> --yes` (re-warms + restores the seed).

## Screenshots (console/UI views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `trusted-supply-chain-01-acs-violation.png` | ⬜ NOT CAPTURED — **TOP PRIORITY (the money shot)** | **RHACS console** → **Violations** / the `parasol-claims:candidate` image → the **Log4Shell CVE-2021-44228** entry (CVSS 10, `log4j-core` 2.14.1) and the **"Block Log4Shell at build"** policy | the single CRITICAL CVE that breaks the build; the policy that enforces it; the component + version | lab.adoc ex. 1 (the RHACS view of the violation) |
| 2 | `trusted-supply-chain-02-pipelinerun-scan-failed.png` | ⬜ NOT CAPTURED | **Pipelines → PipelineRuns → the seeded run** — `build-image` green, `acs-scan` **red** | the build **Succeeded** but the run **Failed** at the scan — the gate refused a *built* image | lab.adoc ex. 1 (console view of the failed run) |
| 3 | `trusted-supply-chain-03-imagestream-tags.png` | ⬜ NOT CAPTURED | **Builds → ImageStreams → parasol-claims → Tags** — `latest` + `sha256-….sig` + `sha256-….att` | the signature and SLSA attestation stored **beside** the image, by digest | lab.adoc ex. 3 (the artifacts Chains stored) |
| 4 | `trusted-supply-chain-04-rekor-entry.png` | ⬜ NOT CAPTURED (NEW — trust spine) | **Rekor Search UI** (`rekor-search-ui-trusted-artifact-signer.{cluster_domain}`) → search by the SBOM hash → the entry | the keyless signature as a **public, permanent** transparency-log record (log index, integrated time, the issued identity) | lab.adoc ex. 4 (the transparency-log receipt) |

Screenshot **1 (the RHACS violation screen) is the priority capture** — the visual that makes the threat
concrete. Screenshots 2–4 are **enrichment**; the lab's load-bearing evidence is CLI output (the `acs-scan`
table, the `jq` SBOM query, `cosign verify` "verified against the specified public key", `verify-blob`
"Verified OK"), shown inline. None is required for the page to read correctly (all embed points are
`// media-pass:` comments, so their absence breaks nothing).

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `trusted-supply-chain-01-trust-triangle.svg` | concept.adoc Mermaid — `examples/diagrams/trusted-supply-chain/01-trust-triangle.mmd` | the key diagram: source → SBOM → build+sign → scan gate → registry (image + .sig + .att) → ImagePolicy admission. Colour the two refusals (gate + admission) red, the trustworthy path green |
| `trusted-supply-chain-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/trusted-supply-chain/03-what-you-built.mmd` | the rebalanced spine: scanning as one red beat (seeded → refused), then the pre-scanned signed image → cosign verify → provenance/SBOM → keyless/Rekor → admission |
| `trusted-supply-chain-04-platform-accretion.svg` | (new) master accretion diagram, **trust/supply-chain layer** highlighted | reuse the platform base; light up the scan-gate + signing + admission layer |

## Recordings

- **Terminal cast** (asciinema, `trusted-supply-chain-demo.cast`) of the trust arc: the seeded run failing
  on Log4Shell → the SBOM `jq` finding `log4j-core@2.14.1` → `cosign verify` on the clean `:latest` →
  `verify-attestation` (SLSA provenance) → keyless `cosign sign-blob` → `rekor-cli search` finding the
  entry → `verify-blob` "Verified OK". Recorded in the Showroom terminal as `user1`. Preferred (CLI-first).
- **Optional short screen capture** (<90 s) of the RHACS violation screen (screenshot 1's view, in motion)
  and/or the Rekor Search UI entry (screenshot 4) if used live in the demo.

At least one recording is mandatory per `04-STYLE-GUIDE §4`; the terminal cast is the primary.
