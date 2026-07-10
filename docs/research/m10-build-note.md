# M10 build note — GitOps at Scale & Progressive Delivery  `[OCP]`

Date: 2026-07-09 · Author: research-analyst R5 · Spec: 02-MODULE-SPECS §M10 (lines 130-139) · Builds on the M09 student instance (ADR-0002)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22), `oc api-resources`/`oc explain` (Rollout/ApplicationSet CRDs), live UWM + Argo instance, docs.redhat.com GitOps + developers.redhat.com, repo inspection. versions.yaml (2026-07-08) trusted; re-verified live 2026-07-09.

## Verified versions
| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-09 |
| OpenShift GitOps | 1.21.1 (Argo CD 3.4) | latest | packagemanifest + CSV Succeeded (live); versions.yaml | 2026-07-09 |
| Argo Rollouts | `RolloutManager`/`Rollout` `argoproj.io/v1alpha1`; Analysis CRDs present; GA since GitOps 1.13 | `oc api-resources` (live); versions.yaml | 2026-07-09 |
| ApplicationSet | `argoproj.io/v1alpha1`; generators list/git/matrix/merge/clusters/scmProvider/pullRequest/plugin/clusterDecisionResource/selector | `oc explain applicationset.spec.generators` (live) | 2026-07-09 |
| OpenShift Route traffic-router plugin | supported since GitOps 1.13 | docs.redhat.com GitOps `argo_rollouts`; developers.redhat.com 2024-10-02 | 2026-07-09 |

Cluster reality (verified live 2026-07-09):
- **ApplicationSet generators** confirmed present: `list`, `git`, `matrix` (spec's minimum) **+** `merge`, `clusters`, `scmProvider`, `pullRequest`, `plugin`, `clusterDecisionResource`, `selector`. `applicationSet.sourceNamespaces` present.
- **Rollout.spec.strategy has BOTH `canary` and `blueGreen`.** Analysis CRDs (`analysistemplates`, `analysisruns`, `clusteranalysistemplates`, `experiments`) present. **NO `RolloutManager` installed** → the Rollouts controller must be provisioned.
- **OpenShift Route traffic-router plugin** (GitOps 1.13+, supported): mutates `Route.alternateBackends` for canary weight; creates route + rollout + 2 services; if the Route is Argo-managed → Argo shows out-of-sync, fix with `ignoreDifferences` (developers.redhat.com/blog/2024/10/02/argo-rollouts-traffic-manager-openshift-routes). **No mesh/Gateway needed on the core profile.**
- **UWM enabled** (`prometheus-user-workload-0/1` + `thanos-ruler-user-workload` running) → a Prometheus `AnalysisTemplate` can query user-workload metrics (aligns with M12).
- Builds on the M09 student instance + `{user}-gitops` + `proj-{user}` (workshop layer). `{user}-dev/stage/prod` exist. `claims-config-template` dev/stage/prod overlays exist — but **no Rollout/ApplicationSet/AnalysisTemplate source** yet.

## Spec deltas
- Spec entry state "M09 end state + prod namespace + Rollouts controller": prod ns exists; **`RolloutManager` does NOT** → provision as shared infra (cluster-scoped, **one per cluster**). Independence: the M10 entry state must **pre-create the per-user Applications synced to dev+stage** (the M09 end state) so M10 runs without M09.
- Spec "verify GA status/analysis templates": **Rollouts GA** (GitOps 1.13+); canary + blueGreen + AnalysisTemplate all present live. Confirmed.
- Route traffic-splitting (spec watchout): **supported via the OpenShift Route plugin on the core profile** — but requires `RolloutManager` plugin config + `ignoreDifferences` on the Argo-managed Route.
- Analysis needs UWM (spec "align with M12"): UWM already on, **but** the Prometheus `AnalysisTemplate` must authenticate to `thanos-querier` (openshift-monitoring) with a token + `cluster-monitoring-view` RBAC on the analysis SA — non-trivial; flag.

## Approach recommendations
1. Provision Rollouts as a **cluster-scoped `RolloutManager`** (shared infra, new component) with the **OpenShift Route trafficRouterPlugin** enabled — one per cluster covers all `{user}-prod`.
2. M10 entry state **pre-creates the M09 end state per-user**: `{user}/claims-config` fork + Applications (dev+stage) synced via the student instance → attendee starts from "app is GitOps-managed" (keeps the module independent).
3. ApplicationSet arc: convert dev/stage/prod to a `list` or `git` generator over env folders (take the **"folders not branches"** position); add sync-waves (db → app → web) + a pre-sync migration-hook Job.
4. Canary on prod: convert claims Deployment → `Rollout` (canary 20/50/100 + Prometheus `AnalysisTemplate` on error-rate; fail one step on purpose → auto-rollback); use the Route plugin for real traffic %; add `ignoreDifferences` on `Route.alternateBackends`.
5. Blue-green as the second strategy (manual promotion gate) reusing the same Rollout scaffolding; keep `{user}-prod` tiny (replicas 1-2) for quota.

## Mining results
- `OpenShiftDemos/advanced-gitops-workshop` + `argo-rollouts-workshop` → "both directly reusable" (05-REFERENCES §Mine): ApplicationSet / app-of-apps / sync-wave labs + canary / blue-green / analysis-template shapes. Discard the empty "TBD" troubleshooting (anti-pattern).
- `Argo Rollouts Lab Instructions.pdf` → facilitator run-book + pre-flight "all Argo apps Synced" gate.
- `redhat-ads-tech/parasol-insurance-manifests` `app/` Helm (hpa, deployment, route) → prod deploy shape to convert to a Rollout; re-implement (license = none). (mining-index §3)
- old Rollouts PDF run-book pattern.

## Open risks
- `RolloutManager` (cluster-scoped + Route-plugin config) = net-new shared component; **only one per cluster** — coordinate any other Rollouts use. Verify exact supported plugin coordinates/config at build. `// TODO(verify-on-cluster)`
- Prometheus `AnalysisTemplate` → `thanos-querier` auth + `cluster-monitoring-view` RBAC per `{user}-prod` analysis SA is fiddly; build + verify a working template before content. Fallback: a job/web metric provider or a deterministic synthetic metric. `// TODO(verify-on-cluster)`
- Argo-managed Route + the Rollouts plugin mutating `alternateBackends` → out-of-sync noise; `ignoreDifferences` required — verify the exact JSON path.
- Per-user prod quota (pvc 5 / pods 30 / 12Gi): canary transiently doubles pods (stable+canary) + analysis pods — size replicas 1-2; verify concurrent 8-user canary fits allocatable.
- Migration hook is synthetic (parasol-claims uses Hibernate auto-DDL + `import.sql`, no Flyway/Liquibase) — design an idempotent SQL pre-sync Job or add a real migration (app-developer).

## Builder appendix

**Teaching goals (from spec):** structure repos for many apps/envs; ApplicationSets vs app-of-apps; sync-waves/hooks; promote by PR; canary + blue-green with Argo Rollouts + automated analysis; know ACM/multicluster exists (pointer to M21).

**Exercise arc (Parasol framing, ~90 min):**
- `[~15m]` Convert dev/stage/prod to an ApplicationSet (env generator) on the student instance.
- `[~15m]` Add a pre-sync DB-migration hook + waves (db → app → web); watch ordered sync.
- `[~15m]` Promotion PR dev→stage; merge; watch the ApplicationSet reconcile.
- `[~25m]` Convert prod Deployment → Rollout; canary 20/50/100 with metric analysis; fail one on purpose → auto-rollback.
- `[~15m]` Blue-green with a manual promotion gate. `[~5m]` Wrap: progressive-delivery decision guide (Rollouts vs Mesh vs Serverless — xref M18/M19).

**Entry-state requirements (`gitops/entry-states/m10/`, per-user):** assumes student instance + `proj-{user}` + `{user}-gitops` + cluster `RolloutManager` + UWM. Materializes the **M09 end state**: `{user}/claims-config` fork with dev+stage Applications synced; prod overlay + the Rollout/AnalysisTemplate/ApplicationSet source in the fork; analysis SA + `cluster-monitoring-view` RBAC in `{user}-prod`.

**Platform requirements:**
- *Shared/cluster (NEW):* `RolloutManager` (cluster-scoped) + OpenShift Route `trafficRouterPlugin` config. Reuses `student-gitops` (M09) + UWM (`monitoring-uwm` component, live).
- *Per-user:* the analysis SA + monitoring-view RBAC in `{user}-prod` (entry state).

**App requirements:** ADD to `claims-config-template` (or a `rollouts` overlay): a `Rollout` variant (canary + blueGreen), a Prometheus `AnalysisTemplate`, an `ApplicationSet`, and a pre-sync migration Job (real or synthetic SQL). App-developer/content.

**Demo angle:** canary with auto-rollback on bad metrics — 12 min flagship. Console capture of the Rollout dashboard rolling back at a failed analysis step.
