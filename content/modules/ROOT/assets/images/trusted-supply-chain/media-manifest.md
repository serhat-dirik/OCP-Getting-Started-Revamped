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
| 2 | `trusted-supply-chain-02-pipelinerun-scan-failed.png` | ✅ CAPTURED 2026-07-31 (as user6, `seed-scan-5zds5` in `user6-cicd`, against a healthy RHACS Central) | **Pipelines → PipelineRuns → the seeded run** — `build-image` green, `acs-scan` **red** | the build **Succeeded** but the run **Failed** at the scan — the gate refused a *built* image; the Details tab also now shows an inline "Log snippet" of the failure | lab.adoc ex. 1 (console view of the failed run) — now embedded |
| 3 | `trusted-supply-chain-03-imagestream-tags.png` | ✅ CAPTURED 2026-07-29 | **Builds → ImageStreams → parasol-claims → Tags** — `latest` + `sha256-….sig` + `sha256-….att` | the signature and SLSA attestation stored **beside** the image, by digest | lab.adoc ex. 3 (the artifacts Chains stored) — **provenance caveat CLOSED 2026-07-31:** verified live as user6 that `user6-cicd`'s PipelineRuns (including the one that built `latest`) all carry `workshop.redhat.com/module=trusted-supply-chain` — the artifacts in this shot genuinely belong to this module, not a neighboring one. Separately, as of 2026-07-31 the live ImageStream actually carries **9** tags / **3** pairs (`candidate` + `cleancheck` + `latest`, each with its own `.att`/`.sig`) — the `cleancheck` pair is an out-of-band verification build (see lab.adoc's grounding note beside the Chains-artifacts step), not something this exercise's own instructions produce, so this screenshot's 1-pair/3-row/Image-count-3 state was deliberately left as-is rather than re-shot. A 9-tag reference capture exists (reviewed, not committed) if a future pass wants to show three pairs on purpose. |
| 4 | `trusted-supply-chain-04-rekor-entry.png` | ✅ CAPTURED 2026-08-01 (as user4; **anonymous — the Rekor Search UI needs no login at all**) | **Rekor Search UI** (`rekor-search-ui-trusted-artifact-signer.{cluster_domain}`) → search by the SBOM hash → the entry | the keyless signature as a **public, permanent** transparency-log record: Entry UUID, Type `hashedrekord`, Log Index, Integrated time, the searched sha256, the signature, and the decoded Fulcio certificate whose **Validity window is ten minutes wide** — the certificate that signed it has already expired while the log entry stays verifiable forever | lab.adoc ex. 4 (the transparency-log receipt) — **now embedded** |

### Row 1 — re-attempted 2026-08-01, blocked on an RHACS login

The 2026-08-01 media pass could not shoot this one. The blocker is **access, not cluster state**:
RHACS Central runs its own user database (the module's own lab says so — the RHACS screens are
instructor-shown precisely because the workshop issues attendees no RHACS account), it has no
anonymous read surface at all, and this pass was barred from typing a password into any login form.
Contrast row 4, which fell to this same pass in minutes *because* the Rekor Search UI needs no login.

So the prerequisite for row 1 is not "produce the red state" — that part is deterministic and
documented above, and takes ~7 min. It is **one headed `login.py` window against
`{acs_console_url}` with an RHACS credential**, after which the Violations view is a plain
`capture.py` job. Until someone does that, the row cannot move, and its absence breaks nothing (its
embed point is a `// media-pass:` comment).

Screenshot **1 (the RHACS violation screen) is the priority capture** — the visual that makes the threat
concrete. Screenshots 2–4 are **enrichment**; the lab's load-bearing evidence is CLI output (the `acs-scan`
table, the `jq` SBOM query, `cosign verify` "verified against the specified public key", `verify-blob`
"Verified OK"), shown inline. Only screenshot **1** is still outstanding, and its absence breaks nothing
(its embed point is a `// media-pass:` comment).

### Screenshot 4 (Rekor) — the prerequisite, and a defect this pass fixed

**Defect fixed 2026-08-01: this row had no embed point.** The row claimed `lab.adoc` exercise 4, but the
file contained exactly ONE `// media-pass:` marker (the RHACS one, in exercise 1) — so even a correct
capture had nowhere to land. The marker now exists, in exercise 4, right after the "That UUID is a
permanent, tamper-evident record" paragraph, with the image embedded.

**Rekor is EMPTY on a fresh cluster** (`treeSize: 0`), so the search UI has nothing to return and any shot
of it is a picture of an empty form. Perform the module's own exercise 4 first, as the attendee, to write
a real entry — `oc exec` into the attendee's Showroom pod gives exactly that identity:

```sh
oc exec -n ogsr-showroom <showroom-{user}-pod> -c terminal -- bash -s <<'EOF'
# ... the lab's own exercise 4, verbatim: curl cosign + rekor-cli from $CLI, clone seed-vulnerable,
# mvn ...:makeBom, cosign initialize --mirror=$TUF, then
#   TOKEN=$(oc create token pipeline --audience trusted-artifact-signer -n {user}-cicd)
#   cosign sign-blob -y --identity-token="$TOKEN" --bundle ~/sbom.bundle \
#     target/parasol-claims-sbom.json
sha256sum target/parasol-claims-sbom.json     # <- the digest the shot searches by
EOF
```

That container runs as `lab-user` and `oc whoami` already returns `{user}` — same container, same tools,
same identity the ttyd terminal hands an attendee, so nothing here is admin-flavoured. The whole sequence
(including the Maven SBOM build) took **~2 min** on 2026-08-01.

Then shoot `?hash=sha256:<digest>` — the UI runs the search on page load, so no typing is needed. Job:
`tools/media/jobs-anon-surfaces.yaml`. Two traps recorded there and worth repeating: "Rekor" is in
`<title>` but **not** in the body so it can never satisfy a text wait; and "Log Index" must **not** go in
`require_in_frame` because the closed *Attribute* dropdown contains an option with that exact text and the
frame check resolves the hidden one first.

> `tools/media/jobs-rekor.yaml` is still PARKED with a note saying this row cannot be shot until an image
> is genuinely signed. **That reason is now obsolete** — the prerequisite is documented above and the row
> is captured. Fold or delete that file.

**Bonus captures, 2026-07-31 (not numbered above, not wired to any embed point):**
`trusted-supply-chain-05-pipelineruns-list.png` (the PipelineRuns tab for all three `user6-cicd` runs,
showing the *Vulnerabilities* column rendering a bare "-" for every run — including the one with a live
CRITICAL CVE) and `trusted-supply-chain-06-pipelinerun-clean-check-succeeded.png` (`clean-check-9mjb2`'s
Details tab, the all-green counterpart to screenshot 2's all-red-at-acs-scan graph). Both sit in this
asset directory, untracked, evidence for the grounding notes in lab.adoc rather than lab content in their
own right; promote to a numbered row if a future media pass wants to use them directly.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `trusted-supply-chain-01-trust-triangle.svg` | concept.adoc Mermaid — `examples/diagrams/trusted-supply-chain/01-trust-triangle.mmd` | the key diagram: source → SBOM → build+sign → scan gate → registry (image + .sig + .att) → ImagePolicy admission. Colour the two refusals (gate + admission) red, the trustworthy path green |
| `trusted-supply-chain-03-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/trusted-supply-chain/03-what-you-built.mmd` | the rebalanced spine: scanning as one red beat (seeded → refused), then the pre-scanned signed image → cosign verify → provenance/SBOM → keyless/Rekor → admission |
| `trusted-supply-chain-04-platform-accretion.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/trusted-supply-chain/04-platform-accretion.mmd` | reuse the platform base; light up the scan-gate + signing + admission layer |

## Recordings

- **Terminal cast** (asciinema, `trusted-supply-chain-demo.cast`) of the trust arc: the seeded run failing
  on Log4Shell → the SBOM `jq` finding `log4j-core@2.14.1` → `cosign verify` on the clean `:latest` →
  `verify-attestation` (SLSA provenance) → keyless `cosign sign-blob` → `rekor-cli search` finding the
  entry → `verify-blob` "Verified OK". Recorded in the Showroom terminal as `user1`. Preferred (CLI-first).
- **Optional short screen capture** (<90 s) of the RHACS violation screen (screenshot 1's view, in motion)
  and/or the Rekor Search UI entry (screenshot 4) if used live in the demo.

At least one recording is mandatory per `04-STYLE-GUIDE §4`; the terminal cast is the primary.
