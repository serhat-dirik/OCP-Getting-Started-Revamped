# M08 media manifest — Trusted Software Supply Chain

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
Shoot as **user1** on the workshop cluster, 16:10, default console theme, annotate with
numbered red circles matching the referenced step. Every screenshot needs alt text
(what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass: …` line — replace with the `image::` (screenshot) or the SVG
`image::` (diagram) when the asset lands.

Media note: the module's mechanics — the scan-gate **fail** on Log4Shell (RHACS `roxctl image check`,
CVSS 10), the 225-component CycloneDX SBOM, the **fixed** run passing with a Chains-signed image,
and `cosign verify`/`verify-attestation` (SLSA provenance v0.2) — were all performed and captured
from the CLI/API as `user2` on 2026-07-10. The console/RHACS screenshots and the SVG diagram exports
below are the **deferred media pass** (no screenshots captured yet — the build was CLI-driven).
Diagrams currently ship inline as Mermaid (they satisfy the ≥1-diagram requirement today); the SVG
exports replace/augment them in the pass.

## Screenshots (console/UI views — the view IS the content)

| # | Filename | Status | View | Notice | Embed point |
|---|----------|--------|------|--------|-------------|
| 1 | `trusted-supply-chain-01-acs-violation.png` | ⬜ NOT CAPTURED — **TOP PRIORITY (the money shot)** | **RHACS console** ({acs_console_url}) → **Vulnerability Management** (or **Violations**) → the `parasol-claims` image → the **Log4Shell CVE-2021-44228** entry (CVSS 10, `log4j-core` 2.14.1) and the **"Block Log4Shell at build"** policy | the single CRITICAL CVE that breaks the build; the policy that enforces it; the affected component + version | lab.adoc ex. 1 (the RHACS view of the violation the `acs-scan` log names) |
| 2 | `trusted-supply-chain-02-gitea-pom-edit.png` | ⬜ NOT CAPTURED | **Gitea → your fork → `seed-vulnerable` branch → `pom.xml` (edit)** — the `log4j-core` `<dependency>` block selected for deletion | the exact block to remove (the `M08 seeded CVE` comment + the 5-line `log4j-core` dependency); the branch selector reads `seed-vulnerable` | lab.adoc ex. 3 (the fix edit) |
| 3 | `trusted-supply-chain-03-pipelinerun-scan-failed.png` | ⬜ NOT CAPTURED | **Pipelines → PipelineRuns → (the vulnerable run)** — `build-image` green, `acs-scan` **red** | the build **Succeeded** but the run **Failed** at the scan — the gate refused a *built* image | lab.adoc ex. 1 (console view of the failed run; the log message is the load-bearing artifact and is shown inline) |

Screenshot **1 (the RHACS violation screen) is the priority capture** — it is the visual that makes
the threat concrete (a named CVE, CVSS 10, the exact library) and the one attendees will remember.
Screenshots 2 and 3 are **enrichment**; the lab's load-bearing evidence is CLI output (`roxctl image
check` table, the `jq` SBOM query, `chains.tekton.dev/signed=true`), shown inline. None is required
for the page to read correctly (all embed points are `// media-pass:` comments, so their absence
breaks nothing).

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `trusted-supply-chain-01-trust-triangle.svg` | concept.adoc Mermaid "trust triangle / pipeline" | the module's key diagram: source → SBOM → build+sign → scan gate → registry (image + .sig + .att) → ImagePolicy admission. Colour the two refusals (gate + admission) red, the trustworthy path green |
| `trusted-supply-chain-03-what-you-built.svg` | wrapup.adoc Mermaid recap | the trustworthy path green; the two refusals (Log4Shell → gate red; unsigned → admission red) |
| `trusted-supply-chain-04-platform-accretion.svg` | (new) master accretion diagram, **trust/supply-chain layer** highlighted | reuse the platform base; light up the scan-gate + signing + admission layer in red (accretion pattern) |

## Recordings

- **Terminal cast** (asciinema, `trusted-supply-chain-demo.cast`) of the demo-arc happy path:
  the vulnerable run failing on Log4Shell → the SBOM `jq` finding `log4j-core@2.14.1` → the fix →
  the fixed run passing + `signed=true` + the `.sig`/`.att` tags. Recorded in the Showroom terminal
  as `user1`. Preferred over a screen capture (this flow is CLI-first).
- **Optional short screen capture** (<90 s) of the RHACS violation screen (screenshot 1's view,
  in motion) if the RHACS console is used live in the demo.

At least one recording is mandatory per `04-STYLE-GUIDE §4`; the terminal cast is the primary.
