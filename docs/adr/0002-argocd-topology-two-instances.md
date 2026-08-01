# ADR-0002: Argo CD topology — two shared instances (platform + student)

Date: 2026-07-08 · Status: accepted · Owner: PM (spike by research-analyst)

## Context

The entry-state machinery runs as Argo Applications; M08/M09 additionally have attendees create their *own* Applications/ApplicationSets. Options: one shared instance with per-user AppProjects; per-user instances (~5 pods × 30 users); or two shared instances. Verified: "applications in any namespace" is GA since GitOps 1.13 (cluster runs operator v1.21.1); the operator supports multiple namespace-scoped ArgoCD instances.

## Decision

**Two shared instances.**
1. **Platform instance** — the default `openshift-gitops`: portfolio stacks + workshop layer + all `entry-*` Applications (AppProject `workshop-entries`). Admin-only writes; attendees get read-only visibility (the M08 "the machinery that built your world is Argo CD" reveal).
2. **Student instance** — `student-gitops` (added by the workshop layer in Phase 3, before M08): apps-in-any-namespace enabled, per-user AppProject boxing each user to their own repos/namespaces/`userN-gitops` source namespace.

## Consequences

- One RBAC slip in student-land cannot delete the entry-state machinery — the failure domain is split.
- Cost: one extra Argo instance (~5 pods) — far below per-user instances.
- Phase 0/1 only need the platform instance; `student-gitops` lands with the M08 wave.

## Amendment 1 (2026-07-10) — apps-in-any-namespace does not exist for namespace-scoped instances; attendee app CRs live in the student control plane

GitOps operator 1.21.1 (Argo CD 3.4.4) **refuses `spec.sourceNamespaces` on a namespace-scoped
instance** — verified live four ways (glob and explicit-list `sourceNamespaces`; a hand-set
`application.namespaces` param is reverted by the operator in ~15s; the managed-by-cluster-argocd
label is inert). The operator only honors source namespaces for instances listed in
`ARGOCD_CLUSTER_CONFIG_NAMESPACES` — i.e. **cluster-scoped** ones.

Cluster-scoping `student-gitops` (option A) was REJECTED: it preserves the cosmetic detail
(per-user `{user}-gitops` app-CR namespaces) by sacrificing this ADR's primary promise — an
instance that *physically cannot reach* the platform machinery — and widens any attendee
mistake's blast radius to the cluster.

**Decision (option B):** attendee Application CRs live in the `ogsr-student-gitops` namespace itself.
Isolation layers, each proven live before ratification: per-user Argo RBAC (userN cannot
sync/delete userM's apps — `argocd admin settings rbac can` verified), per-user AppProjects
boxing destinations to `{user}-dev/stage/prod`, and k8s RBAC denying attendees direct writes to
the control-plane namespace (apps are created via the Argo UI under their SSO identity).
`{user}-gitops` namespaces remain as per-user workspace/markers.

**Engine consequence:** attendee-created apps live outside every purge namespace, so ws-meta
gains `purgeAppsNamespace` + `purgeAppsProject` (`${USER}` resolves); `ws reset` and the
conflict-eviction gc delete the user's apps by `.spec.project` — attendees cannot be relied on
to label what they create in a UI.

## Amendment 2 (2026-07-31) — the Platform-instance "admin-only writes" line is false; correct the record, not just the code

The Decision's Platform-instance line above — **"Admin-only writes; attendees get read-only
visibility"** — was superseded on 2026-07-10 by the attendee-self-service directive (commit
`e2808e6`, "attendee self-service ws prep") and never amended here. From that commit onward,
attendees hold per-user, name-scoped Argo RBAC on the platform instance's `workshop-entries`
AppProject [*corrected inline 2026-08-01 — see Amendment 4: this grant is plain **k8s** RBAC keyed on
Application **names**, not Argo RBAC, and it is scoped to no AppProject at all. Read as written it
sends the next person hunting for a `policy.csv` rule that does not exist.*]
(`gitops/workshop-config/templates/per-user-argo-rbac.yaml`): get/list broadly,
patch/delete pinned to `entry-mNN-{user}` by resourceNames, **and an unscoped `create`** —
because `ws prep` → `cmd_reset` → `render_app | oc apply` is itself a CREATE whenever an
attendee's entry Application is absent. Attendees write to the platform instance directly;
they have not had read-only visibility since that date.

The stale ADR text was not inert. `tools/ws/ws` cited this ADR **by name** as the reason the
unscoped `create` grant was safe: "attendees lack Application-create rights on the platform
Argo instance by design, ADR-0002." That was false when written, and the underlying accepted-
risk reasoning (the ws CLI "always renders project=workshop-entries", and that AppProject
"pins the source repo to the in-cluster mirror") was measured false on 2026-07-31 and proven
live end-to-end: an attendee-created `Application` with `project: default` was accepted AND
reconciled to Synced/Healthy by the platform controller, which runs as cluster-admin. k8s RBAC
cannot resourceName-scope `create`, `workshop-entries` ships `sourceRepos: ["*"]` (same as
stock `default`, plus `destinations: "*"` and `clusterResourceWhitelist: "*"`), and an attacker
does not go through `ws` at all — they POST the object directly. Argo's own RBAC is correctly
locked down and is irrelevant: this is a k8s-API side door the Argo RBAC layer never sees.

The code comments (`gitops/workshop-config/templates/per-user-argo-rbac.yaml` header and
`tools/ws/ws` `cmd_start`) were corrected in commit `6b57949` to stop citing this ADR for a
protection that does not exist. This amendment brings the ADR itself into agreement with that
commit so the two no longer tell different stories.

**Current state (2026-07-31): the escalation is CLOSED, at admission.** The unscoped `create`
grant remains — it must, for the reason above — but it is no longer sufficient to escalate.
`gitops/workshop-config/templates/attendee-entry-app-guard.yaml` (commit `79c694c`) constrains
*what* an attendee may create: the ValidatingAdmissionPolicy
`ogsr-attendee-entry-app-guard` and its binding carry four validations bounding the
Application's name, its AppProject, and its source path. Verified live on both clusters the
same day — policy and binding present and bound, not merely committed.

A second control landed alongside it (`7b526ac`): `workshop-entries` no longer ships
`destinations: "*"`. It enumerates the attendee namespace patterns plus five shared namespaces,
so even an admitted Application cannot land outside them. Argo enforces the project twice — once
against the Application's own `spec.destination`, and again against **each resource's** namespace
at sync time — which was measured on-cluster, not assumed.

Do not read this as the Decision section's original line coming back. Attendees still write to
the platform instance directly; "admin-only writes" remains superseded. What changed is that the
write is now *bounded* by an admission-layer partner rather than by an ADR sentence that was not
true. The standing rule worth carrying out of this: **any "these users may create X" grant needs
a partner at the admission layer or in the object's own scoping**, because k8s RBAC cannot scope
a `create` by name.

One residual is accepted and documented rather than closed: all attendees share this single
AppProject, so an attendee can still target a *peer's* namespace. That is a cooperative-classroom
risk, not a customer-data risk; the threat model and the per-attendee AppProject pattern that closes
it are documented in the header of `gitops/workshop-config/templates/attendee-entry-app-guard.yaml`.

## Amendment 3 (2026-08-01) — two corrections to Amendment 2: the per-attendee AppProject it named now exists (but is inert), and its own "five shared namespaces" was itself one of the bugs this cluster of changes fixed

**1. The per-attendee AppProject pattern.** Amendment 2 named this as what "closes [the peer-
namespace residual] if the audience is ever strangers," without it existing yet. It now exists:
`gitops/workshop-config/templates/appproject-entries-per-user.yaml` (committed `dac87dc`) renders
an `entries-{user}` AppProject per attendee, and all eight are live on cluster2 today
(`oc get appproject -n openshift-gitops --no-headers | awk '{print $1}' | sort` →
`entries-user1` … `entries-user8`, verified). It is not yet load-bearing: the admission guard this
ADR's escalation depends on (`ogsr-attendee-entry-app-guard`) still carries the committed
`workshop-entries` expression on cluster2, and `tools/ws/ws` still renders that project by default.
A local, uncommitted edit to the guard would switch it, but it is deliberately held until it ships
in the same commit as the `ws` change plus a `ws git-refresh --restart-terminals --all` [*command
corrected inline 2026-08-01: this was originally written here without a scope. `ws git-refresh
--restart-terminals` with no `--user`/`--all` hits `die "restart needs a target"` in
`restart_terminals` (`tools/ws/ws`) and restarts **nothing** — following the sequence literally
would sync the guard and leave every cockpit on the old `ws`, which is exactly the outage the hold
existed to prevent. Corrected in place rather than only in an amendment because a reader who copies
this line causes the failure. See Amendment 4.*]. Full command evidence is in ADR-0001's matching
2026-08-01 amendment; not repeated here. Until that lands, this ADR's residual paragraph above still
holds exactly as written: attendees remain on one shared AppProject. [*Superseded 2026-08-01 —
it landed the same day, in `0f25a52`. See Amendment 4.*]

**2. Amendment 2's own destination count was wrong** — a small, on-topic instance of the standing
lesson this whole change teaches. Amendment 2 said `workshop-entries` "enumerates the attendee
namespace patterns plus five shared namespaces." That five-item list (added in `7b526ac`) was
itself short by two — `ogsr-student-gitops` and `openshift-pipelines` — which broke `ws start
gitops-at-scale` and `ws start trusted-supply-chain` at Argo sync time, on both clusters, until
`dac87dc` fixed it the same night ("my destination narrowing was missing two shared namespaces —
two modules break at sync"). The fix was not "add the two missing entries": the list is now
generated from one Helm helper (`workshop-config.entryDestinationsShared` in
`gitops/workshop-config/templates/_helpers.tpl`), shared by both `workshop-entries` and the new
`entries-{user}` projects so the two can never drift apart again, with the regeneration recipe
(render every entry chart at `solve=false` and `solve=true`, collect every `metadata.namespace`,
drop the `{user}-` ones, sort -u) written beside the list instead of left to memory. The count today
is seven, not five: `ogsr-gitea`, `ogsr-student-gitops`, `ogsr-system`, `openshift-lightspeed`,
`openshift-pipelines`, `sonarqube`, `stackrox`. The lesson for this ADR: a hand-maintained
enumeration of a fact that is mechanically derivable from other files (here, every entry chart's
own rendered manifests) will drift out from under you — the fix is to derive it, not to proofread
it harder.

## Amendment 4 (2026-08-01) — the per-attendee AppProject switch has LANDED; the shared-project residual is closed in the repo, and Amendment 2's "Argo RBAC" attribution was wrong

Amendment 3 was written hours before the thing it describes as held shipped. Commit `0f25a52`
(`feat(rbac): box each attendee into their own AppProject — guard and ws in one slice`) landed both
halves together, which is what Amendment 3 said the hold was waiting for.

**What changed, read out of the two files rather than out of the commit message.**

- `gitops/workshop-config/templates/attendee-entry-app-guard.yaml` validation 1 now reads
  `has(object.spec.project) && object.spec.project == 'entries-' + request.userInfo.username`
  (was `== 'workshop-entries'`), with the message *"attendees may only use their own
  'entries-<username>' AppProject"*.
- `tools/ws/ws` gained `argo_project "$user"`, called from the one emitter of `spec.project` for
  entry Applications (`render_app`). It resolves `entries-<user>` → `workshop-entries` → `default`,
  probing each with `oc get appproject` and printing a loud stderr explanation of every fallback,
  including the exact denial the attendee would otherwise receive with no context. `WS_ARGO_PROJECT`
  is now an explicit pin (`ARGO_PROJECT_PIN`) that short-circuits the whole chain, rather than the
  old `${WS_ARGO_PROJECT:-workshop-entries}` collapse — so "pinned to the shared project" is
  distinguishable from "unset".

**The residual this ADR has carried since Amendment 2 is closed in the repo.** Peer tenancy — an
attendee having the cluster-admin application-controller write into another attendee's namespace —
is what the shared `workshop-entries` project allowed and what pinning each attendee to their own
`entries-<user>` project removes. Per-user destination lists only become a boundary once something
stops an attendee naming a *different* project, and k8s RBAC cannot do that (it cannot scope a
`create` by name); the admission guard is what does.

**What is deliberately NOT closed, and should not be read as closed:** `entries-{user}` still permits
the seven shared workshop namespaces from `workshop-config.entryDestinationsShared` (`ogsr-gitea`,
`ogsr-student-gitops`, `ogsr-system`, `openshift-lightspeed`, `openshift-pipelines`, `sonarqube`,
`stackrox`), because the entry charts genuinely write Roles, RoleBindings, ServiceAccounts and Jobs
into them and Argo cannot scope a destination by resource name. The blast radius shrinks from "any
of N attendees' namespaces" to "seven workshop-owned namespaces that hold no attendee work" — it
does not go to zero.

**Committing this did NOT make it live, and that is the point most likely to be misread.** The
`workshop-config` Argo Application sources from the **in-cluster Gitea mirror**, not from GitHub —
`bootstrap/install.sh` renders its `repoURL` as `https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}.git`
and `helm/bootstrap/templates/applications.yaml` uses the same mirror value. So a push to `main`
propagates to no cluster until someone deliberately syncs the mirror. `main` carrying the switch and
a cluster running the switch are two separate facts; check the cluster, never the branch.

**The rollout command, corrected.** Amendment 3 (and every runbook that copied it) wrote
`ws git-refresh --restart-terminals`. Without a scope that command reaches
`die "restart needs a target: --user <u> (one session) or --all (whole cohort, minus any
WS_RESERVED_USERS)"` and restarts zero terminals. The correct command is:

```
ws git-refresh --restart-terminals --all
```

One command, in the order the switch requires: force the Gitea pull-mirror to fetch and wait until
its HEAD equals origin's, run a real sync operation on `pp-git-mirror` and then on `workshop-config`
(which is what updates the policy and renders `entries-{user}`), and only then roll every cockpit
terminal Deployment so each re-clones the new `ws`. Two caveats that are not optional reading:

- `--all` **skips `WS_RESERVED_USERS`**. If that variable is set at rollout time, those sessions keep
  the old `ws`, keep rendering `workshop-entries`, and stay Forbidden until restarted by name with
  `--user <u>`.
- Restarting terminals *before* the mirror has the commit re-clones the old content. That ordering is
  baked into the single command precisely so it cannot be got wrong by hand.

The confirmation steps (including the `ARGO_PROJECT_PIN` grep that tells you whether a given cockpit
actually holds the new `ws`) and the rollback valve live in the guard file's own header, not here —
one copy, next to the code, is the whole lesson of Amendment 3 item 2. The one thing worth repeating:
an admin-run `ws start` proves nothing about this policy, because its `matchConditions` exclude every
identity outside the `workshop-attendees` group. The end-to-end check is an attendee running
`ws prep` in their own cockpit.

**Correction to Amendment 2.** Amendment 2 describes the per-user grant as "per-user, name-scoped
**Argo RBAC** on the platform instance's `workshop-entries` AppProject". Both halves are wrong.
`gitops/workshop-config/templates/per-user-argo-rbac.yaml` — despite its filename — declares plain
k8s `rbac.authorization.k8s.io/v1` `Role`/`RoleBinding` objects whose `resourceNames` are Application
**names** (`entry-<slug>-<user>`); it names no AppProject, and no Argo `policy.csv` rule anywhere in
`gitops/` or `platform-portfolio/` mentions `workshop-entries` (there is no `policy.csv` in either
tree). Amendment 2's own conclusion is unaffected — the escalation was real and is closed at
admission — but its attribution would send the next reader looking for an Argo policy line that does
not exist. Argo's RBAC layer never sees any of this: the side door was always the k8s API.

**Live state at the time of writing (cluster 2, read-only, 2026-08-01 — grounded, not recalled).**
The switch is committed but **not yet rolled out** there:

- `oc get validatingadmissionpolicy ogsr-attendee-entry-app-guard -o jsonpath='{.spec.validations[0].expression}'`
  → `has(object.spec.project) && object.spec.project == 'workshop-entries'` — still the old
  expression, i.e. the mirror has not been synced.
- A cockpit still holds the old `ws`: `oc exec -n ogsr-showroom deploy/showroom-user2 -c terminal --
  bash -lc 'grep -n "ARGO_PROJECT=" ~/ocp-getting-started/tools/ws/ws'` →
  `44:ARGO_PROJECT="${WS_ARGO_PROJECT:-workshop-entries}"`, and `grep -c ARGO_PROJECT_PIN` on the same
  file returns 0.
- All eight `entries-user1` … `entries-user8` projects exist.
- Twenty live entry Applications: 13 on `workshop-entries`, 7 already on `entries-userN` (3 user2,
  2 user7, 1 user4, 1 user5). Those seven were created by an **admin** running the new `ws` from a
  laptop checkout, which the policy never evaluates. That mixed data state is harmless in both
  directions — already-materialized Applications keep their project until the attendee's next
  `ws prep`/`ws start` — but it means "some apps say `entries-userN`" is not evidence the rollout
  happened. The policy expression and the cockpit's `ws` are the two facts that decide.
