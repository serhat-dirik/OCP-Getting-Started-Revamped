# M07 build note — Pipelines Fundamentals & Task Libraries  `[OCP]`

Date: 2026-07-09 · Author: research-analyst R5 · Spec: 02-MODULE-SPECS §M07 (lines 97-106)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22), OLM packagemanifests + CSV, `oc api-resources`/`oc explain`, live TektonConfig + shipped Tasks + PAC route, docs.redhat.com + pipelinesascode.com, repo inspection. versions.yaml (2026-07-08) trusted; re-verified live 2026-07-09.

## Verified versions
| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-09 |
| OpenShift Pipelines | 1.22.4 | latest (== pipelines-1.22) | packagemanifest `openshift-pipelines-operator-rh` + CSV `…v1.22.4` Succeeded (live); versions.yaml | 2026-07-09 |
| Tekton core API | `tekton.dev/v1` (Pipeline/Task/PipelineRun/TaskRun GA); StepAction `tekton.dev/v1beta1` | — | `oc api-resources` (live) | 2026-07-09 |
| Pipelines-as-Code | bundled + GA; `Repository` `pipelinesascode.tekton.dev/v1alpha1` | — | live PAC controller/watcher/webhook pods + CRD | 2026-07-09 |

Cluster reality (verified live 2026-07-09):
- Operator installed **cluster-wide** (OperatorGroup in `openshift-operators`), CSV `openshift-pipelines-operator-rh.v1.22.4` Succeeded. Default `TektonConfig/config` present: `enable-api-fields: beta`, **all four resolvers ON** (`enable-cluster-resolver`, `enable-git-resolver`, `enable-hub-resolver`, `enable-bundles-resolver` = true); addon params `resolverTasks`/`communityResolverTasks`/`pipelineTemplates` = true. → PAC + resolvers work with **no extra config**.
- **45 bundled Tasks** in `openshift-pipelines` ns (`git-clone`, `buildah`, `maven`, `s2i-java`, `openshift-client`, `argocd-task-sync-and-wait`, `helm-upgrade-*`, `kn`, `pull-request`…, plus `…-1-22-0` versioned twins) + 6 StepActions — all **cluster-resolver-referenceable**. `ClusterTask` kind **REMOVED since Pipelines 1.17** (redhat.com "Migration from ClusterTasks to Tekton Resolvers"); we run 1.22.4 → never author ClusterTasks.
- **PAC + Gitea feasible.** PAC controller route live: `pipelines-as-code-controller-openshift-pipelines.apps.cluster-qvkd5…` (edge TLS) = the webhook target. Gitea is a first-class PAC provider (`git_provider.type: gitea|forgejo`, `url`, `secret`, `webhook_secret`; signatures NOT validated for Gitea) — pipelinesascode.com/docs/providers/forgejo + docs.redhat.com PaC. In-cluster Gitea route live (`gitea-gitea.apps.cluster-qvkd5…`) → in-cluster webhook reachable.
- `{user}-cicd` exists (live): ResourceQuota `workshop-quota` = requests.cpu 3 / requests.memory 6Gi / limits.cpu 6 / **limits.memory 12Gi** / **pvc 5** / pods 30; LimitRange `workshop-limits` default container **500m / 1Gi**, request 100m/256Mi, **no min/max**.
- `apps/parasol-claims` EXISTS (contradicts M04 note gap): Quarkus JVM fast-jar, JDK 21 / UBI9 (Containerfile, non-root UID 185), Panache + PostgreSQL (prod) / **H2 (test)**, SmallRye Health, **one** rest-assured test (`ClaimResourceTest`). Builds via `buildah` (Containerfile) OR `s2i-java` (java-21 ImageStream in `openshift` ns). Shared prebuilt image `…/parasol-images/parasol-claims:1.0`; per-user fork `{user}/parasol-claims` seeded by the M02 fork job (`gitops/entry-states/m02/templates/fork-repos.yaml`).
- **`pipelines/` repo directory EXISTS but is EMPTY** — the intended reusable task library is unbuilt.

## Spec deltas
- Spec "Tekton Hub deprecation → verify": confirmed — `ClusterTask` removed (1.17+); `TektonHub` CRD still present but deprecated-as-product (banned, 04-STYLE §5). Current reuse = **cluster / git / hub resolvers**; hub resolver → **Artifact Hub** (Artifact Hub content itself is not Red Hat-supported, only the resolver config is). Teach resolvers, never ClusterTask.
- `pipelines/` empty → the "company task library" the spec leans on does not exist; net-new content+platform.
- `platform-portfolio/components/openshift-pipelines/` = **Subscription only** (channel `latest`); relies on the operator's auto-created default `TektonConfig` (verified sufficient). Fine, but pruner/retention is unmanaged — optional add.
- LimitRange default container **limit = 1Gi**: a Maven/Quarkus build TaskRun under that cap risks **OOMKill** — the spec's "pipeline PVC contention" watchout understates it (it's memory too).

## Approach recommendations
1. Teach **PipelineRun-centric first** (author Pipeline+Tasks, run, read logs; params/workspaces/results), **then PaC** as the git-push evolution (`.tekton/` in `{user}/parasol-claims` → Gitea webhook → `Repository` CR) — both halves feasible (in-cluster Gitea + PAC route live).
2. Build parasol-claims via bundled `buildah` (cluster resolver, Containerfile) + `maven` (test) + `openshift-client` (deploy) — all by resolver, zero copied YAML.
3. "Company task library" = a shared **`parasol-tasks` namespace** of curated Tasks referenced via **cluster resolver** (`resolver: cluster; params kind/name/namespace`) — the supported ClusterTask replacement; grant per-user pipeline SAs `get` on tasks there.
4. Library beat: author custom `image-size-report` Task into `parasol-tasks` + pull a `lint`/catalog task from Artifact Hub via **hub resolver** → shows the reuse layers (catalog → org library → app pipeline).
5. Workspace = a `volumeClaimTemplate` PVC in `{user}-cicd` (vs pvc 5 cap); set build-task memory **request 1.5Gi / limit 2Gi** to beat the 1Gi LimitRange default; runs serial per user.

## Mining results
- `adv-app-platform-demo-showroom` M2 (Tekton + Sonar + Argo handoff) → "pipeline-catches-a-bug" narrative + pipeline→GitOps handoff beat (oldcontent-mining-index §4). Discard Sonar (that is M08).
- `redhat-ads-tech/parasol-insurance-manifests` `build/` (maven-build → update-manifest → triggers Tekton chain) → pipeline SHAPE + task decomposition for parasol-claims; re-implement (license = none). (mining-index §3)
- MAD M3 + `rh-mad-workshop/mad-dev-guides-m6`, `tech-exercise` pipeline exercises → mechanics/lab-progression IDEAS only; anti-goal on tech-exercise's opinionated TL500 stack (05-REFERENCES; mining-index §2b).
- Discard everywhere: `ClusterTask`, Tekton-Hub-as-product, `kam`.

## Open risks
- `pipelines/` empty + `parasol-tasks` ns + per-user pipeline SA/RBAC = net-new platform+content; nothing today.
- Maven build **OOM** under the 1Gi LimitRange default — set explicit task resources; confirm a full parasol-claims build fits `{user}-cicd` quota. `// TODO(verify-on-cluster)`
- PAC Gitea webhook: signatures unvalidated (acceptable for lab); confirm the fork's webhook POSTs to the PAC route from in-cluster egress on a real push. `// TODO(verify-on-cluster)`
- Break-fix needs a deliberately-failing unit test — parasol-claims has ONE test; app-developer adds a toggleable failing test (or lab flips an assertion).
- `tektonpipeline` status reports operand "pipeline v1.9.3"; the load-bearing fact is the **API `tekton.dev/v1` (GA)** — do not cite the operand number in content.

## Builder appendix

**Teaching goals (from spec):** read/author Tasks+Pipelines (params/workspaces/results); a build-test-deploy PipelineRun; trigger on git push via PaC; find/reuse tasks (resolvers/Artifact Hub); start + justify a curated org task library.

**Exercise arc (Parasol framing, ~90 min):**
- `[~15m]` Anatomy: run the seeded `parasol-claims` build-test-deploy Pipeline in `{user}-cicd`; follow logs; read params/workspaces/results.
- `[~15m]` Reuse: add a hub-resolver `lint` task; swap in a cluster-resolver task from `parasol-tasks`.
- `[~20m]` Author: write `image-size-report` Task; add it to the Parasol library ns; reference it by cluster resolver.
- `[~25m]` PaC: seed `.tekton/pull-request.yaml` in the `{user}/parasol-claims` fork; create the `Repository` CR + Gitea webhook; push from Dev Spaces (M03 muscle memory) → pipeline fires; PR-based flow glimpse.
- `[~10m]` Wrap: "why platform teams curate a library" + decision guide; break-fix = failing test gates the build.

**Entry-state requirements (`gitops/entry-states/m07/`, per-user):** assumes `{user}-cicd`, java-21 IS, parasol-images pull, the shared `parasol-tasks` library. Materializes: `{user}/parasol-claims` fork (reuse m02 fork-job pattern); a pipeline SA + push RoleBinding to its image target; the seeded Pipeline + Tasks (or cluster-resolver refs); the `.tekton/` PipelineRun in the fork; optionally the PAC `Repository` CR (attendee adds the webhook = lab).

**Platform requirements:**
- *Shared/cluster:* OpenShift Pipelines operator — **EXISTS** (`pp-openshift-pipelines`). **NEW** `parasol-tasks` namespace + curated Tasks + read-RBAC for per-user pipeline SAs (the cluster-resolver library). Optional TektonConfig pruner tuning.
- *Per-user:* pipeline ServiceAccount + registry-push RoleBinding, workspace PVC, PAC `Repository` CR — all in `{user}-cicd` (materialized by the entry state).

**App requirements:** parasol-claims builds today via buildah + s2i (verified). ADD a toggleable failing unit test (break-fix). Populate `pipelines/` (Tasks + Pipeline + `.tekton/` PipelineRun) — content+platform.

**Demo angle:** push → pipeline → deployed in 10 min + task-library talk track (platform-team POV). Terminal cast of the PipelineRun + a short capture of the PaC fire on push.

---

## PM addendum — platform landed, read this before building content (2026-07-10, PM)

Everything below is BUILT and verified (per-item status); the module-builder starts from here,
not from the "nothing exists today" framing above.

**Task library — DONE (`ded7cf4`), PM-verified end-to-end.** `parasol-tasks` namespace with
curated `image-size-report` + `maven-jdk21` Tasks + per-user reader RBAC (workshop layer,
`gitops/workshop-config/templates/parasol-tasks.yaml`); `pipelines/` populated (Pipeline
`parasol-claims-build-test-deploy` — 5 tasks, ALL by cluster resolver — PipelineRun with
`volumeClaimTemplate` + memory overrides, `.tekton/` PaC entrypoint, per-user RBAC example).
Proven twice on-cluster (PE run + independent PM re-run from committed artifacts): Succeeded,
~8.5 min first run, image 391 MB within the 500 MB budget, no OOM.

**Delta superseding §30:** the bundled `maven` task is **JDK-17-pinned with no image param**
(`stepSpecs` cannot override a step image) → it cannot build this app. The library's
**`maven-jdk21`** task (ubi9/openjdk-21, ships Maven 3.9) is the unit-test task. Teach this
delta — it IS the "why platform teams curate a library" beat, better than any invented example.

**Deploy-target decision (PM, recorded in 06-BACKLOG decision log):** the pipeline deploys into
`{user}-cicd` and the entry state ships an ephemeral `claims-db` there (M04/M05 pattern). No
cross-namespace deploy; environment promotion stays M09/M10's story. The lab should not imply the
`-cicd` deploy is production practice — one honest sentence ("in later modules the pipeline hands
off to GitOps instead") plants M09.

**Break-fix — DONE (`82dd046`), PM-verified both states on two JDK-21 distros.** Test
`approvingAClaimRequiresAnAssignedAdjuster` in `ClaimResourceTest`. The attendee's one-line
change in their fork (line ~191): `final boolean assignAdjusterBeforeApproval = true;` → `false`.
Failure reads: *"Parasol rule violated: claim CLM-NNNN was Approved while still Unassigned - an
adjuster must own a claim before it can be approved"*. Default = 14/14 green.
⚠ **The claim number is DYNAMIC** (sibling tests bump the shared H2 counter) — the lab must say
"your claim number", never quote a fixed `CLM-10xx`. The toggle is documented in the app README's
"Intentional flaws — do not fix" list; don't let a content pass "fix" it.

**Entry state — DONE, G1 CLOSED (2026-07-10; chart `6742664` + fixes `e2161b1`/`c433bcd`, full
live cycle PASSED on user6).** `gitops/entry-states/m07/` (fork + `.tekton` seeded into the
user's OWN fork via Gitea API with a populated-main wait, claims-db, in-namespace Pipeline by
cluster-resolver refs, optional PaC `Repository` CR, blocking solve, `tools/verify/m07.sh`;
ws-meta: namespace `{user}-cicd`, no conflicts with built modules — first `-cicd` module,
`waitSeconds: 1200`). Cycle evidence: `ws start` Synced/Healthy first try + 7/7 verify checks ·
`ws solve` **blocks ~8 min and returns only when the app is truly up** (deploy 1/1, pod Running,
0 restarts against the entry claims-db — the deploy-target decision holds) · `ws reset` leaves
zero PipelineRuns and no app · `ws prep --yes` 7/7 → "start the lab".

**Engine changes shipped with this module (`c433bcd`) — content authors should know:**
1. `ws` readiness now also gates on the Argo sync *operation* (PostSync hooks genuinely block),
   sized per-module via ws-meta `waitSeconds`. The first live cycle caught `ws solve` printing
   "demo-ready" ~7 min early while the pipeline still ran — instructors: solve now takes ~8–10
   min BY DESIGN and is truthful when it returns; put that in the instructor pre-flight/timing.
2. `ws reset` now purges `pipelineruns.tekton.dev` (`oc delete all` never touched Tekton CRs) —
   attendee re-runs start with a clean run list.

**Seed-gate note for the PaC exercise:** the attendee's fork is created by THIS module's entry
state, so M07 does not wait on the (disabled) app-repo seed Job. But the fork is taken from
`parasol/parasol-claims` as-is — if that shared repo is ever refreshed (Serhat's call), nothing
here breaks; the fork job tolerates pre-existing forks.
