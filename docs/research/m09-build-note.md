# M09 build note — GitOps Fundamentals  `[OCP]`

Date: 2026-07-09 · Author: research-analyst R5 · Spec: 02-MODULE-SPECS §M09 (lines 119-128) · Operationalizes ADR-0002 (two Argo instances)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22), OLM CSV, `oc explain argocd/appproject`, live `openshift-gitops` ArgoCD CR + pods, repo inspection. versions.yaml (2026-07-08) trusted; GitOps re-verified live 2026-07-09.

## Verified versions
| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-09 |
| OpenShift GitOps | 1.21.1 (Argo CD 3.4) | latest (== gitops-1.21) | packagemanifest `openshift-gitops-operator` + CSV Succeeded (live); versions.yaml | 2026-07-09 |
| ArgoCD CR | `argoproj.io/v1beta1` | — | `oc explain argocd` (live) | 2026-07-09 |
| Application / AppProject / ApplicationSet | `argoproj.io/v1alpha1` | — | `oc api-resources` (live) | 2026-07-09 |

Cluster reality (verified live 2026-07-09):
- Default `openshift-gitops` ArgoCD instance (v1beta1) live. **SSO = `sso.dex.openShiftOAuth: true`, `provider: dex`** (dex-server pod running) — OpenShift OAuth login via **Dex** is the default + confirmed pattern. `sso.keycloak` is marked **Removed** in the CRD ("no longer supported") → do NOT use keycloak SSO.
- Instance footprint = **5 workload pods** (application-controller StatefulSet, dex-server, redis, repo-server, server) + shared operator `cluster` + gitops-plugin. A second (student) instance ≈ **+5 pods** — matches ADR-0002.
- Apps-in-any-namespace present: `argocd.spec.sourceNamespaces` (+ `applicationSet.sourceNamespaces`) and `appproject.spec.sourceNamespaces` all exist → per-user boxing feasible. `NamespaceManagement` CRD (`argoproj.io/v1beta1`) present. Default instance `sourceNamespaces` = EMPTY (apps only in `openshift-gitops` today).
- `gitops/promotion/claims-config-template` exists: kustomize **base** (configmap/secret/db/app+svc+route, all 3 probes, requests/limits) + **dev/stage/prod overlays** (replicas/APP_ENV/log level; `__user__` namespace placeholder). Published as `parasol/claims-config-template`; the M04 fork job (`gitops/entry-states/m04/templates/gitea-fork.yaml`) forks it → `{user}/claims-config` and personalizes `__user__`→`{user}`. Image = `…/parasol-images/parasol-claims:1.0`.
- `{user}-dev/stage/prod/cicd` exist. **NO `{user}-gitops` namespace exists** (`per-user-namespaces.yaml` makes only dev/stage/prod/cicd).
- `workshop-attendees` Group + per-user `admin` RoleBindings on `{user}-*` exist; the PLATFORM AppProject `workshop-entries` (`gitops/workshop-config/templates/appproject-workshop-entries.yaml`) boxes entry-state apps in `openshift-gitops`.

## Spec deltas
- Spec watchout "per-user Argo vs shared + AppProjects (decide in build)": **DECIDED by ADR-0002** = two SHARED instances. Platform `openshift-gitops` (portfolio + entry states, attendee read-only) + student `student-gitops` (attendee-writable, apps-in-any-namespace, per-user AppProject). Student instance + AppProjects land in the **workshop layer** (persistent, survives `ws reset`), NOT per-user entry states.
- ADR-0002 names a **`userN-gitops` source namespace that does not exist yet** — must be added (workshop layer). Alternative: reuse existing `{user}-cicd`. Recommend adding `{user}-gitops` (ADR-blessed; keeps CI vs GitOps concerns separate; lightweight, no workloads).
- Argo SSO mechanism unpinned by spec; CRD reality forces **Dex + openShiftOAuth** (keycloak removed) — record it.
- Independence: M09 assumes student instance + AppProject + `{user}-gitops` (shared platform infra, always present); the entry state materializes only the `{user}/claims-config` fork + EMPTY dev/stage (attendee creates the first Application = the lab).

## Approach recommendations
1. Build `student-gitops` as a workshop-layer `ArgoCD` CR (ns `student-gitops`; copy `sso.dex.openShiftOAuth: true` from the default; `sourceNamespaces: ["*-gitops"]`, `applicationSet.sourceNamespaces: ["*-gitops"]`).
2. Per-user isolation = `AppProject proj-{user}` (`sourceNamespaces: [{user}-gitops]`; `destinations: [{user}-dev/stage/prod only]`; `sourceRepos: "*"`) + Argo RBAC policy mapping OpenShift user → role scoped to `proj-{user}`; add `{user}-gitops` ns to workshop-config.
3. M09 entry state = **reuse the M04 claims-config fork job** (fork `parasol/claims-config-template` → `{user}/claims-config`, personalize overlays); leave dev/stage EMPTY so the attendee's first Application deploys the app live.
4. Design the drift beat around **`selfHeal: true`**: attendee bumps replicas in the console, watches Argo revert it within the reconcile window ("the platform argues back") — the confirmed selfHeal-reverts-manual-edits behavior IS the lesson.
5. Meta-reveal: attendees open the PLATFORM `openshift-gitops` UI **read-only** to see the `entry-*` Applications + Helm charts in Gitea that built their world (ADR-0002) — no writes.

## Mining results
- `OpenShiftDemos/openshift-gitops-workshop` (current, 2026-03) → Application-CR anatomy labs + sync/self-heal exercises (mining-index §2b). Discard `kam`, Homeroom.
- `OpenShift GitOps Workshop.pdf` → push-vs-pull contrast, Application-CR anatomy walkthrough, 20-min-theory/long-lab split (05-REFERENCES §1). Discard kam CLI, DevNation logistics.
- `advanced-gitops-workshop` → base/overlays + RBAC-per-team shapes (re-verify operator channel).
- `adv-app-platform-demo-showroom` (GitOps handoff beat) → demo-flavor Say/Show/Do reference.

## Open risks
- `student-gitops` instance + per-user AppProjects + `{user}-gitops` ns + Argo RBAC = net-new workshop-layer infra (nothing today); platform-engineer build.
- Verify the Argo RBAC policy actually blocks user2 from user1's project on a live student instance. `// TODO(verify-on-cluster)`
- Dex `openShiftOAuth` on a NON-default namespaced ArgoCD instance: confirm group/user claims + RBAC scoping work for a second instance at 1.21 (the default instance proves the mechanism; a second instance is untested). `// TODO(verify-on-cluster)`
- sync-wave collisions with entry-state apps (spec watchout): student apps live in `student-gitops`, entry apps in `openshift-gitops` — split failure domains help, but verify no cross-instance contention on the same `{user}-*` namespaces.
- Quota: the student Application deploys claims+db into `{user}-dev/stage` (within pvc 5 / pods 30) — fine; watch when M10 adds prod + Rollout.

## Builder appendix

**Teaching goals (from spec):** pull vs push reconciliation; create an Argo `Application`; experience drift/self-heal; structure kustomize base/overlays; read health/sync; where Helm fits; the meta-reveal.

**Exercise arc (Parasol framing, ~75 min):**
- `[~15m]` Concept + create `Application` (points at `{user}/claims-config` overlay dev) → app appears; read health/sync.
- `[~15m]` Drift theater: edit the live Deployment (replicas 1→3) in the console; watch selfHeal revert it.
- `[~15m]` Git is truth: change via Git (PR in Gitea) → sync → diff view.
- `[~15m]` Overlay change for stage (replicas/config); promote by pointing an Application at the stage overlay.
- `[~10m]` Break the manifest; read degraded health; fix. Wrap + meta-reveal (read-only platform Argo).

**Entry-state requirements (`gitops/entry-states/m09/`, per-user):** assumes student instance + `proj-{user}` + `{user}-gitops` (workshop layer) + claims image. Materializes: `{user}/claims-config` fork (reuse m04 job); EMPTY dev/stage (attendee's Application does the deploy). Do NOT pre-create the Application.

**Platform requirements (all NEW, workshop layer — platform-engineer):**
- *Shared/cluster:* `student-gitops` `ArgoCD` instance (Dex+openShiftOAuth; sourceNamespaces `*-gitops`) + Argo RBAC policy.
- *Per-user (persistent):* `{user}-gitops` namespace; `AppProject proj-{user}` (source ns + destination boxing); OpenShift RBAC so the attendee may CRUD `Application` CRs in their `{user}-gitops` ns + read the student Argo UI.

**App requirements:** none new — `claims-config-template` (base + dev/stage/prod overlays) already exists and is reused.

**Demo angle:** drift-revert theater (edit live, watch Argo undo) — 8 min, always lands. Short console capture of the self-heal revert.
