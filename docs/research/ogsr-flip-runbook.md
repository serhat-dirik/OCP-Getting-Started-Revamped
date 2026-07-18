# `ogsr-` shared-namespace flip — C1 cluster runbook

**Status:** choreography for the coordinator to execute **on-cluster** after merging the
`ogsr-` shared-namespace rename. This document is a plan; the rename PR itself changes no
live cluster. Author: platform-engineer (off-cluster). Owner decision: 2026-07-17 —
**shared** namespaces get an `ogsr-` prefix; per-user and product/operator namespaces do not.

The rename moves five (six on an observability cluster) shared namespaces:

| Old | New | Has an external Route? | Route host after flip |
|-----|-----|------------------------|-----------------------|
| `gitea` | `ogsr-gitea` | yes (operator route `gitea`) | **CHANGES** → `gitea-ogsr-gitea.<domain>` (host is namespace-derived) |
| `showroom` | `ogsr-showroom` | yes (per-user + demos) | **IDENTICAL** — `showroom-<user>.<domain>`, `showroom-demos.<domain>` (explicit `spec.host`) |
| `student-gitops` | `ogsr-student-gitops` | yes (Argo server route) | **IDENTICAL** — `student-gitops-server-student-gitops.<domain>` (PINNED via `spec.server.host`; instance name kept) |
| `parasol-tasks` | `ogsr-parasol-tasks` | no | — |
| `parasol-images` | `ogsr-parasol-images` | no | — |
| `observability-workshop` | `ogsr-observability-workshop` | no | — (only if the observability stack is installed) |

## The one hazard: `HostAlreadyClaimed`

A Route host is admitted **once cluster-wide**. Any surface whose new namespace serves the
**same** host as its old namespace will collide: the second Route to claim the host is
rejected `HostAlreadyClaimed` and never admits.

- **`showroom` / `showroom-demos`** — hosts are explicit and **identical** in old and new
  (`showroom-<user>.<domain>`, `showroom-demos.<domain>`). → **COLLIDES.**
- **`student-gitops`** — the Argo server route host is **pinned to its old value**
  (`student-gitops-server-student-gitops.<domain>`) so the attendee URL is preserved;
  the new `ogsr-student-gitops` instance therefore claims the **same** host as the old one.
  → **COLLIDES.**
- **`gitea`** — the operator route takes the OpenShift **default** host `<route>-<namespace>`,
  so the old namespace serves `gitea-gitea.<domain>` and the new one serves
  `gitea-ogsr-gitea.<domain>` — **two different hosts**. → **does NOT collide** (old and new
  can co-exist during the transition). The attendee-facing gitea URL **does change** to
  `gitea-ogsr-gitea.<domain>` (see "Known behaviour changes").
- **`parasol-tasks` / `parasol-images` / `observability-workshop`** — no Routes at all.
  → no collision.

**Rule that falls out of this:** for the two colliding surfaces (`showroom`, `student-gitops`)
the **old namespace must be gone before Argo admits the new Route.** Argo CD does not
guarantee prune-before-create across namespaces, so we delete the old colliding namespaces
**manually, first**, then sync. `gitea` and the routeless namespaces need no such gating.

## Preconditions

1. **Cohort boundary.** Run this between cohorts / with no live attendee session. Gitea
   content is **re-derived** by the flip (mirror re-mirrors from GitHub; workshop users and
   `parasol/*` seed repos are re-seeded; per-user forks are re-created by the next `ws prep`).
   Nothing an attendee committed only into in-cluster Gitea survives — acceptable **only** at a
   cohort reset. Do not run mid-cohort.
2. **`WS_RESERVED_USERS` / `reservedUsers` empty** for the flip (no live session to shield).
3. **Bump the chart versions** of `gitops/workshop-config` (and any touched entry charts) in
   the merge, or bump before syncing — a poisoned Argo manifest cache survives SHA changes and
   Redis flushes; a chart-version bump is the reliable cache-bust (session best-practice).
4. Cluster-admin `oc` context on C1; `argocd` CLI or the two Argo consoles reachable.
5. Merge landed on the branch the C1 Argo apps track (or point them at it).

## Sequence

Follow Argo sync discipline throughout: **mirror-sync → hard refresh → ~10 s → sync**; never
start a sync while an operation is `Running` (the patch is silently swallowed); a stuck op →
patch `status.operationState.phase=Terminating`, then a fresh sync.

### Phase 0 — snapshot the "before" (for verification later)

```
oc get route -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.host \
  | grep -E 'gitea|showroom|student-gitops'      # record the OLD hosts
oc get ns gitea showroom student-gitops parasol-tasks parasol-images 2>/dev/null
```

### Phase 1 — gitea (no collision; re-derives its data)

The gitea host changes rather than collides, so the new gitea can come up alongside the old.

1. Sync the **portfolio** `pp-core-devtools` app (or the app-of-apps root). This creates
   `ogsr-gitea`, installs the Gitea CR there (route `gitea` → host `gitea-ogsr-gitea.<domain>`),
   and re-runs the **git-mirror** hook Job, which re-mirrors `parasol/ocp-getting-started` from
   GitHub into `ogsr-gitea`.
2. Wait until the new gitea is Ready and the mirror `HEAD == origin`:
   ```
   oc get gitea gitea -n ogsr-gitea
   oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}{"\n"}'   # -> gitea-ogsr-gitea.<domain>
   # mirror HEAD (attendee-safe idiom):
   curl -ksf "https://gitea-ogsr-gitea.<domain>/api/v1/repos/parasol/ocp-getting-started/branches/main" \
     | sed -n 's/.*"id":"\([a-f0-9]*\)".*/\1/p'
   ```
3. The old `gitea` namespace may stay up for now (different host — harmless). It is removed in
   Phase 4.
4. **Re-publish the shared workshop password into the new gitea namespace.** Found missing during
   the C1 flip window. `gitops/workshop-config`'s **gitea-user-seed** Job (Phase 2, sync-wave 2) reads
   the `workshop-user-creds` secret FROM `ogsr-gitea` — it does not create it. That secret is normally
   published once by `helm/bootstrap`'s `ogsr-gitea-seed-secret` hook Job
   (`helm/bootstrap/templates/job-gitea-seed-secret.yaml`), which does **not** re-run on a flip
   (bootstrap is the one-time imperative step; renaming the gitea namespace does not re-trigger it).
   Without this, Phase 2's seed Job fails against the new `ogsr-gitea` and no attendee accounts or
   `parasol/*` repos get (re-)seeded. Re-publish it with the exact contract that Job uses:
   ```
   oc create secret generic workshop-user-creds \
     --from-literal=password="<workshop_user_password from vars.yaml>" -n ogsr-gitea \
     --dry-run=client -o yaml \
     | oc label --local -f - "workshop.redhat.com/owner=ogsr" --overwrite -o yaml \
     | oc apply -f -
   ```
   (Equivalent shortcut for the whole cohort: `tools/ws/ws passwd <the known password>` — it writes
   this same secret into `ogsr-gitea` AND keeps the OpenShift console/CLI login in sync. Pass the
   EXISTING password explicitly; a bare `ws passwd` generates and rotates to a NEW one.)
5. **Re-point `workshop-config`'s Argo Application at the new gitea host.** Found missing during the
   C1 flip window. `workshop-config` is a **static, bootstrap-created** `Application`
   (`helm/bootstrap/templates/applications.yaml`) — its `spec.source.repoURL` is a literal string baked
   in at `helm install` time (`https://gitea-<OLD gitea namespace>.<domain>/parasol/ocp-getting-started.git`)
   and does **not** self-heal when the gitea namespace is renamed: nothing re-renders the bootstrap
   chart on a flip, and Argo's `selfHeal` reconciles the resources an Application *manages*, not the
   Application object's own `spec.source`. Left alone, the Phase 2 sync below keeps pulling from the
   OLD host (which still resolves until Phase 4 deletes it, so this fails silently-late rather than
   loudly-now — patch it before syncing, not after):
   ```
   oc patch application workshop-config -n openshift-gitops --type=merge \
     -p '{"spec":{"source":{"repoURL":"https://gitea-ogsr-gitea.<domain>/parasol/ocp-getting-started.git"}}}'
   ```
   (Any other wave-2 Application sourced from the mirror — currently only `workshop-config` — needs
   the same patch.)

### Phase 2 — routeless shared namespaces (no collision)

Sync **`gitops/workshop-config`**. This creates `ogsr-parasol-tasks` (curated Task library) and
`ogsr-parasol-images` (shared image registry namespace + puller grants +, as of 2026-07-18, the
`parasol-claims`/`parasol-web` BuildConfigs themselves — see "Known behaviour changes"), and re-runs the
**gitea-user-seed** + **app-repo-seed** Jobs against `ogsr-gitea` (re-seeds workshop users and
`parasol/*` repos). If the observability stack is installed, sync it to create
`ogsr-observability-workshop` (Tempo owns/creates it; the OTel collector deploys into it).

> Note: this same `gitops/workshop-config` sync **also** wants to create the colliding
> `ogsr-showroom` + `ogsr-student-gitops` Routes. If the old `showroom` / `student-gitops`
> namespaces still exist, those Routes will `HostAlreadyClaimed`. That is expected — do Phase 3
> **first if you sync as one app**, or split the sync (selective sync of the non-cockpit,
> non-student-argo resources here; cockpits + student Argo after Phase 3). Simplest is to run
> **Phase 3 immediately before the workshop-config sync** so the hosts are already free.

### Phase 3 — free the colliding hosts, THEN bring up the new cockpits + student Argo

1. **Delete the old colliding namespaces** (this releases their Routes/hosts):
   ```
   oc delete ns showroom --wait=true
   oc delete ns student-gitops --wait=true
   ```
   (Deleting the namespace removes its Routes, ArgoCD CR, Deployments, and PVCs. Per-user
   cockpit home PVCs are disposable; kubeconfigs are re-seeded at pod init.)
2. Confirm the hosts are no longer claimed:
   ```
   oc get route -A | grep -E 'showroom-|student-gitops-server' || echo "hosts free"
   ```
3. **Sync `gitops/workshop-config`** (or re-sync if Phase 2 was the same app). Argo now creates
   `ogsr-showroom` (per-user cockpits + `showroom-demos`) and `ogsr-student-gitops` (the student
   Argo instance, `spec.server.host` pinned to `student-gitops-server-student-gitops.<domain>`).
   The freed hosts admit cleanly.
4. Wait for the student Argo route + cockpits to be Admitted/Ready:
   ```
   oc get route student-gitops-server -n ogsr-student-gitops -o jsonpath='{.spec.host}{"\n"}'
   #   -> student-gitops-server-student-gitops.<domain>   (UNCHANGED)
   oc get deploy -n ogsr-showroom -l app.kubernetes.io/name=showroom
   ```
5. **Cockpit content image (`antora-ext`).** `workshop-config` also creates the `antora-ext`
   ImageStream + BuildConfig (sync-wave 2, `templates/showroom-antora-build.yaml`); its ConfigChange
   trigger fires build #1 on creation. The wave-3 cockpits schedule *before* that build finishes, so
   their `antora-build` initContainer sits in `Init:ImagePullBackOff` until the tag is pushed — this
   **self-heals** once the build completes (the kubelet keeps retrying the pull; verified on C2
   2026-07-18, cockpits went Running with no restart). Watch the build; only kick a cockpit that is
   *still* wedged after the tag exists:
   ```
   oc logs -f bc/antora-ext -n ogsr-showroom                # follow build #1
   oc get istag antora-ext:latest -n ogsr-showroom          # present once the build succeeds
   oc rollout restart deploy -n ogsr-showroom               # ONLY if a cockpit stays ImagePullBackOff after the tag appears
   ```
   (`ws doctor` reports this as the "showroom antora image" check.)

### Phase 4 — remove the remaining old namespaces

Once the new surfaces are healthy:
```
oc delete ns gitea --wait=true
oc delete ns parasol-tasks parasol-images --wait=true
oc delete ns observability-workshop --wait=true   # only if it existed
```
(If Argo prune is enabled on the owning apps it may have already removed these; the explicit
delete is idempotent.)

### Phase 5 — rebuild cockpit content (pick up the new gitea host)

Attendee cockpits build content at pod-init and inject `gitea_url` = `gitea-ogsr-gitea.<domain>`.
Restart the terminals so pages + the in-pod clone refresh from the re-mirrored `ogsr-gitea`
(only after the mirror `HEAD == origin`, or cockpits serve stale content):
```
tools/ws/ws git-refresh --restart-terminals --all
```

## Verification checklist

- **Routes serve (hosts):**
  - `gitea-ogsr-gitea.<domain>` → Gitea UI (200). *(new host — see behaviour changes)*
  - `showroom-<user>.<domain>` → cockpit loads (unchanged host).
  - `showroom-demos.<domain>` → SA-Demos cockpit (unchanged host).
  - `student-gitops-server-student-gitops.<domain>` → student Argo login (**unchanged** host).
- **Mirror fresh:** `HEAD == origin` on `parasol/ocp-getting-started@main` in `ogsr-gitea`.
- **Task library present:** `oc get tasks -n ogsr-parasol-tasks` → the 8 curated Tasks.
- **Images (re-)build automatically — no manual step:** the `parasol-claims`/`parasol-web`
  BuildConfigs in the new `ogsr-parasol-images` fire on creation (ConfigChange trigger); watch
  `oc logs -f bc/parasol-claims -n ogsr-parasol-images` (and `bc/parasol-web`), then confirm
  `oc get istag -n ogsr-parasol-images` shows `parasol-claims:1.0`, `parasol-claims:1.1`,
  `parasol-web:1.0`, `parasol-web:1.1` (`ws doctor`'s "parasol images" check asserts the same).
- **Observability (if installed):** `oc get opentelemetrycollector,tempomonolithic -n ogsr-observability-workshop` → Ready.
- **`ws` converges:** `tools/ws/ws doctor`, then `tools/ws/ws prep pipelines-fundamentals user1`
  (exercises: fork into `ogsr-gitea`, seed `.tekton/`, resolver into `ogsr-parasol-tasks`) and
  `tools/ws/ws verify pipelines-fundamentals user1` → all green. Then `ws prep gitops-fundamentals user1`
  → the student Argo app materializes in `ogsr-student-gitops` and reaches the pinned route.
- **Idempotency:** run `ws prep <module> user1` twice → no diff; `ws reset <module> user1` returns the entry state.
- **No orphan hosts:** `oc get route -A | grep -E 'gitea-gitea\.|-showroom\.|student-gitops-server'`
  shows only the new namespaces (and, for student-argo, the pinned old host under `ogsr-student-gitops`).

## Known behaviour changes (call these out to the owner)

- **No manual image/cockpit-content rebuild needed on this flip.** The shared prebuilt images
  (`parasol-claims`, `parasol-web`) and the showroom `antora-ext` cockpit-content image now self-seed
  declaratively (BuildConfigs owned by `gitops/workshop-config` — this change, plus a33b61a for
  antora-ext). A namespace-renaming flip like this one still needs the **one** Phase 2
  `workshop-config` sync to materialize those BuildConfigs *in the new namespace* (`ogsr-parasol-images`,
  `ogsr-showroom`) — the images don't exist until that sync runs and the ConfigChange-triggered builds
  complete — but nothing beyond that one sync is required; there is no separate manual
  `oc new-build`/`oc start-build`/`oc tag` step left to remember (that used to be an undocumented,
  easy-to-miss 4th re-derivation gap — the runbook never mentioned it because the old manual flow
  wasn't runbook material at all).
- **Gitea attendee URL changes:** `gitea-gitea.<domain>` → `gitea-ogsr-gitea.<domain>`. The
  gitea operator route host is namespace-derived and the workshop layer's `giteaHost` helper
  (`helm/bootstrap`), `showroom.yaml`/`showroom-demos.yaml` cockpit tabs, `ws` fallback, and the
  per-verify-script fallback all **derive** the host from the namespace — so they follow to
  `gitea-ogsr-gitea` automatically and stay internally consistent. Pinning gitea to the OLD host
  would require an explicit host + the cluster domain inside the **workshop-agnostic portfolio**
  component (which must not hold a domain), or a workshop-owned second Route to the gitea Service.
  Neither was done in this PR — flagged for an owner decision (see the merge report). Because the
  flip is a cohort-boundary event with `{gitea_url}` re-injected into freshly-rebuilt cockpits,
  the URL change is inert to any live session.
- **Student Argo + Showroom URLs are unchanged** (pinned / explicit hosts).
- **Gitea data is re-derived** (mirror, users, seed repos, per-user forks) — expected at a
  cohort reset, not acceptable mid-cohort.

## Rollback

The flip is forward-only in practice (old namespaces are deleted). To roll back, revert the
rename merge and re-run this runbook with old/new swapped: the OLD manifests recreate `gitea`,
`showroom`, `student-gitops`, … and the same collision rule applies (delete `ogsr-showroom` /
`ogsr-student-gitops` before syncing the reverted workshop-config). Gitea data re-derives again.
