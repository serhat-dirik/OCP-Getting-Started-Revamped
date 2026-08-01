# ADR-0001: Entry states are Helm-parameterized charts materialized as Argo CD Applications

Date: 2026-07-08 · Status: accepted (PM decision, flagged for the project owner review) · Owner: PM

## Context

Module independence (Decision D11) requires `ws start m09 --user user5` to materialize module 9's world for one user without any other module having run. 01-ARCHITECTURE originally sketched "kustomize bases with a per-user overlay template", which at 30 users × 27 modules means either committing ~800 generated overlay directories to git or teaching `ws` to render+commit per invocation (git plumbing, conflicts, cleanup).

## Decision

Each entry state is a small **Helm chart** (`gitops/entry-states/mNN/`: `Chart.yaml`, `values.yaml`, `templates/`). `ws start` creates one Argo CD **Application** (`entry-mNN-userN`) with `helm.parameters: user=userN, clusterDomain=<detected>`, sourced **from the in-cluster Gitea mirror** (git-localize, D15). Reset = delete Application (prune via resources-finalizer) + recreate. Charts share conventions, not a library chart, until repetition earns one.

## Consequences

- `ws start` is one `oc apply`; no generated files; Argo-native diff/health; reset is free.
- Module authors write Helm templates instead of raw manifests — mitigated by the m01 exemplar + `docs/module-template/`.
- 01-ARCHITECTURE §3 updated to match (same-change rule); the M08 meta-reveal still works: attendees inspect the Application CRs and the charts in Gitea.

## Amendment — 2026-07-09 (Phase 2 G3 wave findings)

Two field-proven semantics were added to the engine after the M04/M05 smoke tests:

1. **`selfHeal: false` on every entry Application** (automated `prune` stays on). In a training lab, attendee
   mutations to chart-owned workloads *are the exercise*, not drift to correct: with selfHeal on, Argo reverted
   the M05 attendee's `oc set volume` within ~1s, so the module's central persistence exercise could never
   complete (G3-M05 SEV1). Creation still auto-syncs, so materialization is unchanged; `ws reset`
   (delete + purge + fresh apply) remains the only re-convergence path — now by design, not just convention.
2. **Declared-conflict eviction on `ws start`/`ws solve`.** Entry charts that materialize the *same named
   workloads* (m02–m05 all own `parasol-claims`/`claims-db` in `{user}-dev`) deadlock when their Applications
   coexist: SharedResourceWarning, both permanently OutOfSync, and the attendee gets a silently wrong world
   while the entry-marker check stays green (G3-M04 SEV2). Each chart's `ws-meta.yaml` now declares
   `conflictsWith:`; start/solve evicts those Applications, purges this module's `purgeNamespaces`, and
   recycles its own Application so the fresh apply triggers a creation auto-sync (required with selfHeal off).

## Amendment — 2026-07-10 (attendee self-service + same-namespace policy)

3. **`ws prep` — attendee self-service front door** (project directive). Attendees hold per-user,
   name-scoped RBAC on their own entry Applications (`gitops/workshop-config/templates/per-user-argo-rbac.yaml`:
   get/list broadly; patch/delete pinned to `entry-mNN-{user}` by resourceNames; create accepted un-scoped for
   the workshop threat model, guarded by the workshop-entries AppProject repo pin). `ws prep <module>` detects
   leftovers/conflicts/missing state, reports them plainly, asks consent (`--yes` for non-interactive), then
   runs the purge-first reset path and the entry verify. Instructor `ws start`/`ws reset` remain the
   no-questions bulk/backstop verbs. Proven live as a real attendee (user7: fast no-op on a clean module;
   full detect→evict→create→verify on a dirty one).
4. **Same-namespace modules are conflicts — coexistence requires disjoint namespaces.** The earlier claim that
   m01 (`parasol-web`) coexists with the claims modules in `{user}-dev` proved purge-fragile: any prep/reset of
   a claims module purges the shared namespace, killing m01's workloads, and with selfHeal off the m01 app then
   reports Synced/Healthy while its Deployment is GONE (observed live on user7 — the worst failure mode: green
   status, wrong world). Policy: modules that materialize into the same namespace declare each other in
   `conflictsWith` (m01 ↔ m02–m05 are mutual); only cross-namespace modules truly coexist (m06 in
   `{user}-batch` beside any dev-namespace module — proven through three G3 runs and the G4 audit).

Consequence for authors: a module whose chart re-materializes an existing named workload OR shares a namespace
with another module MUST list the other owners in `conflictsWith` (both directions); the G3 smoke deliberately
probes cross-module coexistence to catch omissions.

## Amendment — 2026-07-31 (item 3's "repo pin" never existed; the real control is an admission-layer guard)

Item 3 above says the unscoped `create` grant is "guarded by the workshop-entries AppProject repo pin." There
was never such a pin to rely on. Verified directly against both facts it depends on:

- `workshop-entries` sourceRepos was, and is, `["*"]` — not a pin:
  `oc get appproject workshop-entries -n openshift-gitops -o jsonpath='{.spec.sourceRepos}'` → `["*"]`.
- k8s RBAC cannot scope a `create` verb by resource name in the first place — there is no name yet at
  admission time — so "create accepted un-scoped, guarded by X" was never a coherent claim about *any* X
  expressed as an AppProject field; the grant was simply open.

This is the same false premise ADR-0002 carried and has now corrected in its own Amendment 2 — that ADR
is the canonical account of the escalation, the measurement that proved it live (an attendee `Application`
naming `project: default` was accepted and reconciled Synced/Healthy by the cluster-admin platform
controller), and the fix. Summary as it bears on this ADR's engine: the escalation is now closed at
admission, not by any AppProject repo pin.

- `gitops/workshop-config/templates/attendee-entry-app-guard.yaml` (commit `79c694c`) adds the
  ValidatingAdmissionPolicy `ogsr-attendee-entry-app-guard` + binding, with four validations bounding an
  attendee-authored Application's name, its AppProject, and its source path. Verified live on cluster2
  today, not merely committed:
  `oc get validatingadmissionpolicy,validatingadmissionpolicybinding | grep entry` →
  `validatingadmissionpolicy.../ogsr-attendee-entry-app-guard` and
  `validatingadmissionpolicybinding.../ogsr-attendee-entry-app-guard`, both present, age 161m at check time.
- `workshop-entries` destinations were narrowed from `"*"` to an enumerated list (commit `7b526ac`),
  including the empty-namespace entry entry-state Applications need. Verified live on cluster2 today:
  `oc get appproject workshop-entries -n openshift-gitops -o jsonpath='{range .spec.destinations[*]}[{.namespace}] {end}'`
  → `[] [user1-*] [user2-*] ... [user8-*] [ogsr-gitea] [ogsr-system] [openshift-lightspeed] [sonarqube] [stackrox]`
  — no `"*"`.
- `sourceRepos` itself is unchanged (`["*"]`, confirmed above) — the admission policy and the destination
  enumeration are the controls; the source-repo field never was and still is not one.

One residual is accepted, not closed: all eight attendees share this one AppProject, so an attendee can
still name a *peer's* namespace pattern. Cooperative-classroom risk, not a customer-data risk — see
ADR-0002 Amendment 2, and the header of
`gitops/workshop-config/templates/attendee-entry-app-guard.yaml`, for the full threat model.

## Amendment — 2026-08-01 (per-user AppProjects exist now; they are not yet load-bearing)

The residual noted just above has a fix in progress, not a finished one. Verified against cluster2
today, not recalled:

- `entries-user1` … `entries-user8` AppProjects exist
  (`gitops/workshop-config/templates/appproject-entries-per-user.yaml`, committed `dac87dc`):
  `oc get appproject -n openshift-gitops --no-headers | awk '{print $1}' | sort` →
  `default`, `entries-user1` … `entries-user8`, `ogsr-platform`, `workshop-entries`.
- Nothing routes an attendee into their own project yet. A live entry Application still names the
  shared one: `oc get application entry-gitops-fundamentals-user2 -n openshift-gitops -o
  jsonpath='{.spec.project}'` → `workshop-entries`. `tools/ws/ws` still defaults to it
  (`ARGO_PROJECT="${WS_ARGO_PROJECT:-workshop-entries}"`, line 44 — unmodified; `git diff HEAD --
  tools/ws/ws` is empty). And the admission guard from the Amendment above still requires the
  shared project on cluster2: `oc get validatingadmissionpolicy ogsr-attendee-entry-app-guard -o
  jsonpath='{.spec.validations[0].expression}'` → `has(object.spec.project) &&
  object.spec.project == 'workshop-entries'`.
- The guard-side half of the switch is written but deliberately held back, not lost: the working
  tree carries an unstaged edit to `attendee-entry-app-guard.yaml` (`git status --short` shows it
  modified, not committed) that repoints validation 1 to
  `entries-' + request.userInfo.username`. Its own file header explains why it is not committed
  alone: it must land together with a `tools/ws/ws` change that renders `entries-${user}`, because a
  cockpit terminal only picks up a new `ws` at pod start — shipping the guard first would make every
  running attendee's `ws prep` Forbidden. The rollout order is written down in
  `appproject-entries-per-user.yaml`'s own header: sync the Gitea mirror and wait for its HEAD to
  match origin's, sync `workshop-config`, then `ws git-refresh --restart-terminals --all`. [*Command
  corrected inline 2026-08-01: transcribed here (and still written in that file's header) without a
  scope. `ws git-refresh --restart-terminals` alone hits `die "restart needs a target"` in
  `restart_terminals` and restarts nothing, which produces precisely the half-landed state the rest
  of this bullet warns about. `--all` is required — and it skips `WS_RESERVED_USERS`. See the
  amendment below.*]

Net for this ADR: the per-user AppProjects are correctly scoped and materialized, but "per-user
AppProjects" is not yet true of the *running* system — every attendee is still on `workshop-entries`
until the guard, `ws`, and a terminal restart land together. Do not cite this ADR as evidence the
per-user isolation is enforced; it is provisioned, not wired in. [*Superseded later the same day —
see the amendment below; `0f25a52` wired it in.*]

## Amendment — 2026-08-01, later the same day (the switch landed; the amendment above is superseded)

The amendment directly above was written hours before `0f25a52` shipped both halves in one commit,
so its "not yet load-bearing" reading of the engine is stale. What is true of the engine now:

- `tools/ws/ws` no longer defaults to the shared project. `ARGO_PROJECT="${WS_ARGO_PROJECT:-workshop-entries}"`
  is gone; `argo_project "$user"` resolves `entries-<user>` first, falls back to `workshop-entries`
  and then to stock `default`, and **announces every fallback on stderr** with the denial message the
  attendee would otherwise get with no explanation. `WS_ARGO_PROJECT` became an explicit pin that
  short-circuits the chain rather than a `:-` default.
- The resolver has a dependency worth naming here because it fails silently otherwise: the attendee
  must be able to **read** `entries-<user>`, or the probe misses and the chain falls through. That
  read is `appprojects get,list` in `gitops/workshop-config/templates/per-user-argo-rbac.yaml`
  (`<user>-entry-apps` Role) — an attendee on an older Role lands on `workshop-entries` or `default`
  and is then denied by the admission guard.
- `render_app` is the only emitter of `spec.project` for entry Applications, so routing its four
  callers (`cmd_start` single and `--all-users`, both `cmd_solve` paths) through the one resolver is
  the complete change. The other `.spec.project` selectors in `ws` read `purgeAppsProject` /
  `proj-${user}` — those belong to the **student** instance (ADR-0002 Amendment 1) and are correctly
  untouched.
- Item 3 of the 2026-07-10 amendment is now doubly stale and should be read only through this one:
  its "guarded by the workshop-entries AppProject repo pin" was already corrected on 2026-07-31 (no
  such pin ever existed), and the project it names is no longer the one `ws` renders.

**Committing is not deploying.** `workshop-config` sources from the in-cluster Gitea mirror, not from
GitHub, so nothing about this reaches a cluster until someone syncs that mirror. On cluster 2 at the
time of writing the live policy still carried the old `== 'workshop-entries'` expression and a cockpit
still held the old `ws` — verified, not assumed. ADR-0002 Amendment 4 is the canonical account of the
switch, the rollout command, the confirmation steps and the rollback valve; not repeated here.
