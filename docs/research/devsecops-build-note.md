# DevSecOps program build note — M07 (Pipelines) · M08 (Trusted Supply Chain) · M27 (App Security Testing, NET-NEW)

Date: 2026-07-15 · Author: research-analyst (placed by PM) · Method: live cluster `ocp-ws-revamped` (OCP 4.21.22) read-only; repo inspection; `versions.yaml`; docs.redhat.com / sonarsource.com / trivy.dev / zaproxy.org / Artifact Hub. Builds on `docs/research/m07-build-note.md` and `docs/research/m08-build-note.md` — read those first; this note is the **program-level** view plus the net-new M27.

Scope decisions taken as given (owner): SAST = SonarQube shared service · split M08 (trust) vs new module (SAST/SCA/DAST) · new module = **M27** (Advanced Electives) · app = Quarkus **Parasol claims** (not PetClinic). PM-confirmed recommendations while owner away: **SonarQube Community Build** · **Trivy** for SCA · **external PostgreSQL** · **M27 = `[OCP]`** (third-party OSS callout) · **`roxctl deployment check` in M27 stage 9** · DAST hits Service DNS, pipeline still creates the edge Route.

## Verified versions

| Product | Version | Channel / edition | Date |
|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | 2026-07-15 |
| OpenShift Pipelines (Tekton) | 1.22.4 | latest | 2026-07-15 |
| Tekton Chains | v0.26.3, in-toto+oci, **key-based live** | bundled | 2026-07-15 |
| Tekton Results | running (api+postgres+watcher), Route **edge** | bundled | 2026-07-15 |
| OpenShift GitOps (Argo CD) | 1.21.1 / Argo 3.4 | latest | 2026-07-15 |
| RHACS | 4.11.1 | stable | 2026-07-15 |
| roxctl (image check) | RHACS 4.11.1 image, digest-pinned | — | 2026-07-15 |
| RHTAS (Trusted Artifact Signer) | 1.4.2 | stable | 2026-07-15 |
| RHTPA (Trusted Profile Analyzer) | 1.1.6 | stable-v1.1 — **packaged, NOT installed** | 2026-07-15 |
| Native `ImagePolicy` sigstore admission | GA (OCP 4.20+; verify 4.21) | core, namespaced | 2026-07-15 |
| **SonarQube Community Build** | rolling CB; Server LTA 2026.1, latest 2026.2 | **Community Build** — LGPLv3 binaries, SSALv1 analyzers | 2026-07-15 |
| SonarScanner CLI image | 12.1.0.3233_8.0.1 (2026-05-20) | `docker.io/sonarsource/sonar-scanner-cli` | 2026-07-15 |
| SonarQube Helm chart | `SonarSource/helm-chart-sonarqube` (`OpenShift.enabled=true`, `createSCC=false`) | non-root, restricted-SCCv2 | 2026-07-15 |
| Trivy | current (fs + `--scanners license`; `--exit-code 1`) | `aquasecurity/trivy` (pin by digest) | 2026-07-15 |
| ZAP (Zed Attack Proxy, formerly OWASP ZAP) | stable; `zap-baseline.py` | `ghcr.io/zaproxy/zaproxy:stable` (old `owasp/zap2docker-*` DEPRECATED) | 2026-07-15 |

SonarQube CB exact build is rolling (Helm resolves it) — pin chart + image digest at build. Quality-gate mechanism verified: `sonar.qualitygate.wait=true` polls the compute-engine task and returns **non-zero exit** on a red gate; available in Community Build (`sonar.qualitygate.timeout` default 300s).

## Cluster / repo reality

- **Console plugins all enabled** (owner's console-operator patch): pipelines + gitops + advanced-cluster-security. The M07 console-UX story and the M08/M27 ACS-dashboard story are unblocked.
- **Existing pipeline** (`pipelines/pipeline/parasol-claims-build.yaml`, live in `parasol-tasks` + per-user `-cicd`): `fetch-source → unit-test (maven-jdk21) → build-image (buildah) → image-report → deploy (openshift-client)`. Every task by **cluster resolver**. The deploy task `oc create deployment … --port=8080`, wires `claims-db`, sets a readiness probe, `oc rollout status`. **It does NOT create a Route today.**
- **`parasol-tasks` library today = 3 tasks**: `acs-image-check`, `image-size-report`, `maven-jdk21`. M27 adds to this same curated library.
- **M08 scan gate is built + deterministic**: `acs-image-check` runs `roxctl image check … --categories "Supply Chain Security"`; the trust stack ships `SecurityPolicy/block-log4shell-at-build` = `FAIL_BUILD_ENFORCEMENT` on CVE-2021-44228, category-scoped. Seeded `log4j-core 2.14.1` in the vulnerable fork trips it. **The ported "block the bad image" moment is already done.**
- **Signing wired**: `TektonConfig.spec.chain` = in-toto + simplesigning, storage oci; `signing-secrets` (key-based) + `chains-cosign-pub` present. M08 copies `rox-api-token` + `chains-cosign-pub` per-user into `{user}-cicd` (`gitops/entry-states/m08/templates/rox-cosign-hook.yaml`) — **reuse this exact pattern for Sonar/Trivy tokens.**
- **ACS Central** reachable at `central-stackrox.apps.<cluster_domain>` + in-cluster `central.stackrox`.
- **Tekton Results is live with an edge Route** — historical PipelineRun/TaskRun + logs queryable; a concrete reporting surface.
- RHTPA (1.1.6) is **packaged but not installed** (heavy: ~12–15 pods, OwnNamespace, own OIDC/object-store/Postgres).

## Spec deltas

- **02-MODULE-SPECS has no M27 entry** — write the spec stanza first. M08's spec already claims SBOM/signing/admission — only remove any implication it owns SAST/DAST (it never did).
- **Tekton community catalog is archived** (`tektoncd-legacy`): its `sonarqube-scanner` pins `sonar-scanner-cli:4.6` (no `qualitygate.wait`); `trivy-scanner` is 0.2.0. Do **not** consume these — author current tasks in `parasol-tasks` (matches the M07 "curate your own library" lesson).
- **SonarQube Community Build has no branch/PR analysis** — post-merge/main-branch reporting only. Our model (build the pushed revision, analyze, gate on `qualitygate.wait`) works; do NOT promise "PR decoration in Gitea".
- **M27 is not a Red Hat-product module** — SonarQube/Trivy/ZAP are third-party OSS. Tag `[OCP]` (runs on included Pipelines) with an explicit third-party-OSS callout.
- **Trivy supply-chain incident (2026)**: Trivy's GitHub Action was compromised (Mar 2026), deb/rpm GPG keys rotated (Apr 2026) — pin the Trivy **container** image by digest, avoid the Action. (Excellent teaching point in a DevSecOps module.)

## Proposed pipeline design (M27 capstone — ordered stages)

`[M07]`/`[M08]` = already built; `[NEW]` = M27.

| # | Stage | Task (resolver) | Gate / fail | Fix (break-fix) | Reports to |
|---|---|---|---|---|---|
| 1 | Fetch source | `git-clone` `[M07]` | — | — | PipelineRun graph |
| 2 | **SAST** | `sonar-scan` `[NEW]` | `qualitygate.wait=true` → red = exit 1 | remove seeded hardcoded credential (Sonar S2068) → externalize (ties M04) | **SonarQube dashboard** + TaskRun log |
| 3 | **SCA (deps + LICENSE)** | `trivy-scan` fs `[NEW]` | `--exit-code 1 --severity HIGH,CRITICAL` + copyleft license policy | Trivy flags seeded `log4j-core 2.14.1` at source + a copyleft dep → bump/remove | TaskRun log + **SARIF/CycloneDX artifact** |
| 4 | Unit test | `maven-jdk21` `[M07]` | failing test | flip seeded assertion (existing M07 break-fix) | TaskRun log |
| 5 | Build image | `buildah` `[M07]` | build failure | — | TaskRun log |
| 6 | **Image scan** | `acs-image-check` `[M08]` | Block-Log4Shell enforced → fail | bump base / drop log4j | **ACS console** + TaskRun log |
| 7 | Image size report | `image-size-report` `[M07]` | >budget (report only) | — | PipelineRun results |
| 8 | **Sign + attest** | Tekton **Chains** (async) + optional `cosign verify` `[M08]` | verify fails if unsigned | — | TaskRun log + **Tekton Results** |
| 9 | **Deployment (config) check** | `roxctl-deployment-check` `[NEW]` | `roxctl deployment check --file … -o junit` → policy violation | add resource limits / drop excess caps | ACS console + TaskRun **JUnit** |
| 10 | Deploy + **create Route** | `openshift-client` (extended) `[M07+NEW]` | rollout timeout | — | Topology + Route (click-through) |
| 11 | **DAST** | `zap-baseline` `[NEW]` | ZAP FAIL threshold on running app | add security headers (CSP / X-Content-Type-Options / HSTS) in Quarkus | TaskRun WARN/FAIL summary + **HTML artifact** |

Reproducibility: stages 2, 3(license), 9, 11 need **pinned seeds** (hardcoded-credential string, a fixed copyleft dep, a manifest missing limits, missing headers) so they fail deterministically regardless of CVE-feed drift — same discipline as M08's log4shell pin. Stage 3's log4j hit reuses M08's vulnerable fork (same CVE at two layers — a "defense in depth" beat).

**GitOps config security** (concept/wrapup, not a gate): (a) `roxctl deployment check` on rendered manifests pre-GitOps, (b) Argo drift/self-heal (x-ref M09/M10), (c) ACS policy-as-admission (M08 instructor demo), (d) signed commits (Gitea + gitsign) as concept-only "go deeper".

## Net-new platform components + content

**Platform (`platform-portfolio/` — GitOps-only):**
- `components/sonarqube` + `stacks/appsec` — SonarSource Helm chart as an Argo `Application` (Community Build, `OpenShift.enabled=true`, `createSCC=false`), external small PostgreSQL, PVC, Route; **node prereq `vm.max_map_count ≥ 262144` via MachineConfig/Tuned** (see risks — may be permission-blocked, queue for owner); bootstrap Job → create Parasol project + CI token.
- `parasol-tasks` additions: `sonar-scan`, `trivy-scan`, `roxctl-deployment-check`, `zap-baseline` (kept byte-identical to `pipelines/tasks/*.yaml`, per the M07 lockstep convention).
- `pipelines/pipeline/parasol-claims-devsecops.yaml` — the 11-stage capstone; extend the deploy task with `oc create route edge parasol-claims --service=parasol-claims --insecure-policy=Allow`.

**Content:** `content/modules/ROOT/pages/m27-<slug>/{concept,lab,wrapup,instructor,troubleshooting}.adoc`, slides, `gitops/entry-states/m27/` (full pipeline + seeded-vulnerable fork + per-user Sonar/rox token copies via the M08 hook), `tools/verify/m27.sh`, media.

**App (`apps/parasol-claims`):** add pinned SAST seed (hardcoded credential on a seed branch, "Intentional flaws — do not fix"), the copyleft dep for the Trivy license gate, the missing-headers state the DAST fix addresses. No runtime logic change beyond seeds + the header fix.

## Console UX for M07 (owner item 7)

The enabled `pipelines-console-plugin` gives (OCP 4.21): PipelineRun **graph**, per-task **step logs**, **Details → Results**, and **Actions → Start** with a **params form** (pre-fillable). Exact 4.21 form labels need `[CAPTURE-VERIFY]` on-cluster before screenshots. **Pipeline-created Route: yes** — an `openshift-client` step `oc create route edge parasol-claims --service=parasol-claims --insecure-policy=Allow` (edge+Allow per "browser routes need edge") means the attendee never runs `oc expose`.

## Mining — `github.com/rcarrata/devsecops-demo` (Apache-2.0)

- **TAKE (re-implement):** the ordered security-gate-at-every-stage arc; the "block the bad image" + `fix-image/` remediation beat (already realized in M08); `roxctl deployment check` as a deploy-time gate (→ M27 stage 9); ZAP DAST post-deploy (→ stage 11); report-consolidation intent.
- **REPLACE (stale, v1.2.0 Sept-2023, OCP 4.7–4.9):** Gogs → in-cluster **Gitea**; Nexus → internal registry (drop Nexus); Spring PetClinic → **Quarkus Parasol claims**; era SonarQube/scanner-4.x → **CB + scanner 12.x**; StackRox → **RHACS 4.11**; **Gatling** perf test → **re-implemented on k6** as the pipeline's load/perf gate (owner decision 2026-07-17; container-native, threshold-gated, HTML report — `pipelines/tasks/k6-load-test.yaml`; the earlier "perf is M12, drop it" call is reversed); custom report server → **console-native reporting** (Pipelines plugin + Tekton Results + ACS + Sonar dashboards — directly answers the owner's reporting complaint).
- **CREDIT (repo-level CREDITS.md only, never a module page):** *"rcarrata/devsecops-demo (Apache-2.0) → M07/M08/M27 DevSecOps pipeline: the staged security-gate arc, block-the-bad-image + fix-image remediation, roxctl deployment-check and ZAP DAST stages; re-implemented on Gitea / internal registry / Quarkus-Parasol / current tool versions, no code ported."*

## Open risks

- **SonarQube ES host prereq (HIGH):** bundled Elasticsearch needs `vm.max_map_count ≥ 262144`, but the OpenShift-mode chart disables the privileged sysctl init container — worker nodes must carry the sysctl via **MachineConfig/Tuned** or ES won't bootstrap. Cluster-admin + node rollout; **may be permission-blocked → queue for owner.** `// TODO(verify-on-cluster)`
- **SonarQube sizing:** Web + CE + embedded ES ≈ 2–4Gi RAM + PVC + external Postgres; validate under ×N-user load.
- **SonarQube non-interactive bootstrap:** forces admin-password change on first login — the project+token Job must script the change then `POST /api/user_tokens/generate` (like the ACS init-bundle bootstrap).
- **Sonar quality-gate exit code:** confirm in the build spike that `qualitygate.wait=true` returns non-zero on a red gate. `// TODO(verify-on-cluster)`
- **Trivy hygiene:** pin image by digest (not the Action); Trivy pulls its vuln DB at scan time — pre-warm/mirror `TRIVY_DB_REPOSITORY` or ×N users rate-limit.
- **ZAP runtime/scale:** baseline ≈ 1+ min/user; time-box, target Service DNS, single-path per user.
- **roxctl auth:** image + deployment gates reuse the per-user `rox-api-token` M08 copies — no new auth surface; Sonar/Trivy add one token each, same copy pattern.
- **Console-native DAST reporting is the weakest link:** ZAP HTML is an artifact, not a dashboard — the reliable console surface is the TaskRun WARN/FAIL summary.
- **Program coherence vs module independence:** M27's entry state ships the complete 11-stage pipeline, not a diff on M08.

## Owner decisions (recommendations taken as decisions while away — revisit on return)

1. SonarQube edition → **Community Build** (free; quality gates + dashboard; no PR decoration — state honestly).
2. M27 entitlement → **`[OCP]`** + third-party-OSS callout; add `ZAP (Zed Attack Proxy, formerly OWASP ZAP)` naming note to 04-STYLE-GUIDE §5.
3. SCA tool → **Trivy** (vuln + license, one tool); RHTPA stays M08 instructor-optional; make the Trivy-2026 incident a teaching point.
4. SonarQube DB → **external PostgreSQL** (small); H2 unsupported for a shared service.
5. `roxctl deployment check` → **M27 stage 9** (M08 = image trust; M27 = app + config security).
6. DAST target → pipeline creates the edge Route (attendee UX) but ZAP hits Service DNS (reliability).

## Ready-to-paste `versions.yaml` stanzas (add when decisions confirmed)

```yaml
sonarqube:
  chart: SonarSource/helm-chart-sonarqube   # OpenShift.enabled=true, createSCC=false
  edition: community-build                  # LGPLv3 binaries + SSALv1 analyzers
  scanner_image: "docker.io/sonarsource/sonar-scanner-cli:12"  # 12.1.0.3233_8.0.1 (2026-05-20); pin digest
  verified: 2026-07-15
  notes: External PostgreSQL; node vm.max_map_count>=262144 (MachineConfig/Tuned); qualitygate.wait gates the pipeline. Third-party OSS.
  entitlement: OCP
trivy:
  image: "docker.io/aquasecurity/trivy"     # pin by digest; avoid the GitHub Action (2026 incident)
  verified: 2026-07-15
  notes: fs scan; --scanners vuln,license; --exit-code 1 --severity HIGH,CRITICAL gates. Pre-warm/mirror TRIVY_DB_REPOSITORY.
  entitlement: OCP
zap:
  image: "ghcr.io/zaproxy/zaproxy:stable"   # old owasp/zap2docker-* deprecated
  verified: 2026-07-15
  notes: DAST baseline (zap-baseline.py). ZAP (Zed Attack Proxy), formerly OWASP ZAP. Target in-cluster Service DNS.
  entitlement: OCP
```

Sources: sonarsource.com/open-source-editions · sonarsource.com/license · github.com/SonarSource/sonar-scanner-cli-docker/releases · docs.sonarsource.com (OpenShift Helm + CI integration/qualitygate.wait) · trivy.dev/docs · zaproxy.org/docs/docker/baseline-scan · docs.redhat.com RHACS 4.9 roxctl policy compliance · github.com/rcarrata/devsecops-demo
