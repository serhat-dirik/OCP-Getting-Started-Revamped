# SA Provisioning Guide — enablement paths & module selection

Audience: the Red Hat SA (or instructor) **provisioning and planning** a session.
Attendees never see this page — their Showroom shows only the module library and the
modules you selected. (project direction 2026-07-11: recommended paths live here, not
on the attendee index; demo paths belong to the SA-Demos showroom, not the workshop.)

## How paths relate to module numbers

Module numbers follow the **teaching arc** (blocks A — Foundations → B — Delivery &
Trust → C — Platform → electives). A path is a **curated subset** for a time-box —
skipping numbers is expected and fine. Within any path, modules always run in
**ascending order**; a path that violates that is a defect. Roughly **four hands-on
modules make a day**.

## Workshop paths

| Path | Audience | Sequence |
|---|---|---|
| `WS-FULL-3D` (flagship) | 3-day full enablement | **Day 1** M01 → M02 → M03 → M04 · **Day 2** M07 → M08 → M09 → M10 · **Day 3** M11 → M12 → M14 → M23 |
| `WS-FULL-2D` | 2-day compressed | **Day 1** M01 → M02 → M03 → M04 · **Day 2** M07 → M09 → M10 → M12 |
| `WS-DEV-1D` | 1-day developer | M01 → M02 → M03 → M04 |
| `WS-OPS-1D` | 1-day devops / platform | M07 → M08 → M10 → M14 |

Composition rationale (change deliberately, not accidentally):

- **WS-FULL-3D** — Day 1 foundations core; Day 2 the delivery story in its natural
  order (build pipelines → trust the supply chain → GitOps → GitOps at scale): M08
  sits **beside M07** because the supply-chain gates extend the very pipeline the
  attendee just built. Day 3 broadens to developer experience (M11), operations
  (M12), multi-tenancy (M14), and the AI elective finale (M23).
  *(Fixed 2026-07-11: the earlier draft ran M12 before M08 on Day 3 — an
  ascending-order violation that made the numbering look wrong. The numbering was
  right; the path wasn't.)*
- **WS-FULL-2D** — drops trust + developer hub to fit two days; observability (M12)
  stays because ops questions always come up.
- **WS-DEV-1D** — the developer on-ramp, foundations only.
- **WS-OPS-1D** — assumes container fluency; jumps straight to pipelines, supply
  chain, scale, and tenancy.

Storage (M05) and batch (M06) are strong swap-ins for audiences that ask for them —
every module is self-contained, so any ascending selection works.

## Demo paths — SA-Demos showroom (separate category)

Demos are **not** workshop paths and never appear on the attendee index. The demo
flavor (`site-demo.yml`, presenter Say/Show/Do blocks per module) feeds a **separate
SA-Demos showroom** whose purpose is fluent, presenter-led demonstrations with
talk-and-show points — reusing all the module preparation without the lab framing.
*(Direction of 2026-07-11 — the cockpit itself is described below; demo-path
composition pages are still queued, see 06-BACKLOG "SA-Demos showroom".)*

| Demo path | Audience | Sequence |
|---|---|---|
| `DEMO-EXEC-45` | 45-minute executive demo (presenter-led) | M03 + M08 + M10 + M23 |

More demo paths (e.g. "OpenShift Advanced App Platform Demo") are composed as
SA-Demos content work continues.

## SA-Demos cockpit

The SA-Demos showroom above is a **cockpit**, not just a set of pages: a second,
shared Showroom instance (`templates/showroom-demos.yaml` in `gitops/workshop-config/`)
that builds and serves the demo rendering the same way each attendee cockpit serves
the workshop rendering — split-pane guide + tool tabs, built at pod-init from the
in-cluster mirror. It is **one shared instance**, not one per attendee: there is no
"SA user," so it carries no terminal and no per-attendee identity (see the template's
header comment for the full reasoning). Use it to run a demo end-to-end from a
browser tab: the left pane carries the Say/Show/Do talk track, the right pane is
one-click launchers into Console, Gitea, Argo CD, Dev Spaces, Dev Hub, and SonarQube
— the same tools every module demo references. A demo step that needs a live shell
uses the presenter's own already-authenticated attendee cockpit (a reserved session
is the natural fit — see "Reserved showrooms" below) rather than this one.

**URL pattern:** `https://showroom-demos.<cluster-domain>` (parallel to
`showroom-<user>.<cluster-domain>` for attendee cockpits, just without a user segment).

**What it serves:** the `demo: true` Antora rendering — `showroom/site-demo.yml`
in-cluster (the demo-flavor sibling of `showroom/site.yml`, which the attendee
cockpit builds), equivalent in content terms to `content/site-demo.yml`. Every
module's `ifdef::demo[]` Say/Show/Do block renders here; workshop-only exercise
framing (`ifdef::workshop[]`) does not.

**How to disable at provisioning:** set `showroomDemos.enabled: false` in the
`workshop-config` values (e.g. a pure attendee-only run with no SA presenting live
demos). It defaults to **true**. The cockpit shares its namespace with the attendee
showrooms by default (`showroomDemos.namespace: ""` inherits `showroom.namespace`);
set that value explicitly only if it should live in its own namespace.

**Not yet built** (queued in 06-BACKLOG "SA-Demos showroom," landing with the
`ogsr-` rename slice): a consolidated Quick-Access page (every deployed URL, the
shared workshop password, admin/troubleshooting pointers) and a Troubleshooting page
inside this cockpit. This section covers the cockpit plumbing only — the shared
instance that will host those pages once they land.

## Module selection at provision time (planned)

Direction (2026-07-11): SAs choose **some modules or full** when provisioning, and
the attendee Showroom renders only the chosen set. Design queued (see 06-BACKLOG):
a module list in the provisioning values drives per-module AsciiDoc attributes, and
the nav/library include each module conditionally — one content source, filtered at
Showroom content-build time. Until that lands, selection is advisory: tell attendees
which modules their session includes.

## Publishing content updates to a LIVE session (publish runbook)

You author on your laptop and push to `main`. The cluster runs from an **in-cluster
Gitea mirror** of `main`, and each attendee cockpit has a **pod-local clone** (the `ws`
CLI + entry states) plus **pre-rendered lab pages**, both built at pod start. Getting a
fresh push in front of live attendees is two moves — do the first always, the second
only when readers need the new/changed **pages**:

1. **Advance the mirror + re-run seeds** (always, non-disruptive):

   ```
   ws git-refresh
   ```

   Force-syncs the Gitea mirror to your pushed `main` and re-syncs the platform Argo
   apps (git-localize + workshop-config seeds). It **never restarts pods** — safe to run
   as often as you like, including mid-session.

   After this, an attendee's **`ws` CLI self-heals**: the next `ws prep|list|verify|reset`
   notices a just-published module is missing from its clone, pulls the clone up to the
   mirror, and finds it — **no pod restart needed**. This covers everything the terminal does.

2. **Refresh what attendees READ** (only when pages changed, opt-in, targetable):

   Rendered lab pages are built at pod-init and the CLI self-heal can't touch them, so a
   running cockpit keeps stale pages until its pod restarts. Restart cockpit pods explicitly:

   ```
   ws git-refresh --restart-terminals --user user3      # one session
   ws git-refresh --restart-terminals --all             # whole cohort (spares reserved sessions)
   ws git-refresh --restart-terminals --all --exclude user2
   ```

   The fresh pod re-clones to current `main` and re-renders. Best run at a natural break —
   a restart interrupts whatever the attendee had open in that terminal.

   **Reserved sessions are protected.** `--all` never restarts users in `WS_RESERVED_USERS`
   (default `user5` — the live demo/test session). To restart a reserved user you must name
   it explicitly (`--user user5`), which prints a RESERVED warning. Set
   `WS_RESERVED_USERS="user5 user9"` to protect more.

> **One-time bootstrap caveat:** the self-heal (move 1) only works once a pod is already
> running the self-healing `ws`. Cockpits provisioned **before** this CLI shipped must be
> restarted **once** (move 2) to pick it up; from then on move 1 alone keeps their CLI current.

## Reserved showrooms — protecting a live session from rollouts

A live cockpit (your own demo/test session, or an attendee mid-exercise) can be disrupted
two independent ways. Both are guarded, and both default to **`user5`**:

| Vector | What triggers it | Guard | Where |
|---|---|---|---|
| **CLI restart** | `ws git-refresh --restart-terminals --all` | `WS_RESERVED_USERS` (env) skips them | `tools/ws/ws` |
| **Argo self-heal** | a **pod-spec** change to the showroom chart (new env/lifecycle hook/image bump) that Argo Recreate-rolls into every showroom | `.Values.reservedUsers` renders their pod template **without** the change → no diff → no roll | `gitops/workshop-config/values.yaml` |

The second is the subtle one: `workshop-config` has `selfHeal: true`, so a pushed pod-spec
change reaches the cluster on its own (mirror auto-pull, or your `ws git-refresh`) and rolls
**all** showrooms — the CLI reserved-list can't stop that, because no `ws` command is involved.
`reservedUsers` closes it at the chart: for a listed user the roll-inducing block is not
rendered, so their Deployment's `spec.template` is byte-identical to what's live and Argo has
nothing to sync. Check the fleet at a glance:

```
oc get deploy -n ogsr-showroom -L workshop.redhat.com/reserved-session
```

`reserved-session=true` = frozen against pod-spec rollouts. Keep a live session in BOTH lists
(they are independent; both default to `user5`). For a fresh/replicable cluster with no live
session, set `reservedUsers: []` so every showroom simply tracks the chart.

### Deliberate update — hand a reserved showroom its pending changes

A reserved user stays on the pre-change pod-spec until you release them **on purpose**, during
their maintenance window:

1. In `gitops/workshop-config/values.yaml`, remove the user from `reservedUsers` (drop
   `- user5`; leave `reservedUsers: []` if none remain). Bump `version:` in
   `gitops/workshop-config/Chart.yaml` (busts Argo's manifest cache). Commit and push to `main`.
2. When the user is free, publish it:

   ```
   ws git-refresh
   ```

   `workshop-config` syncs, the user's Deployment now renders the pending pod-spec, and Argo
   rolls **that one showroom once**. The marker flips to `reserved-session=false`. Confirm:

   ```
   oc rollout status deploy/showroom-user5 -n ogsr-showroom
   ```

A released user takes **all** pending pod-spec changes in that single roll (the guard is not
per-change). Re-adding them to `reservedUsers` afterward would render their pod-spec back
without those changes and roll them **again** — only re-reserve a user you intend to freeze at
the current spec, not one you just updated.

## Uninstall — removing the workshop from a shared/customer cluster

The workshop is built to drop onto a cluster the org already uses and to reverse **without
changing any characteristic of their cluster**. The teardown is `bootstrap/ogsr-uninstall.sh`
(the inverse of `bootstrap/install.sh`). Always dry-run first:

```
./bootstrap/ogsr-uninstall.sh --dry-run   # prints the WIPE / PRESERVE plan; changes nothing
./bootstrap/ogsr-uninstall.sh             # interactive confirm, then uninstall  (--yes to skip the prompt)
```

**The two guarantees**

1. **Adopted operators are never removed.** `install.sh` records — per operator, in the
   `ogsr-uninstall-state` ConfigMap (namespace `ogsr-system`) — whether it *pre-existed* (adopted)
   or was *created by us*. Uninstall removes only the ones we created; anything adopted, or not
   recorded, is preserved. The GitOps operator itself is removed only if we installed it.
2. **Deleting our Argo apps never prunes an adopted operator.** Each `pp-*` / `workshop-config` /
   `entry-*` Application is stripped of its resources-finalizer and deleted with `--cascade=orphan`,
   so component resources are **orphaned, not pruned**. Only resources carrying
   `workshop.redhat.com/owner=ogsr`, plus operators recorded as created-by-us, are then deleted.

**What it restores (not just deletes)**

- `cluster-monitoring-config` → its recorded prior `enableUserWorkload` value (the ConfigMap is
  deleted only if the workshop created it).
- The `workshop-users` OAuth IdP entry is removed while **every other identity provider is
  preserved** (the cluster's real login IdP is untouched).
- Node labels (`workshop.redhat.com/pool`, `/zone`) and the batch `NoSchedule` taint are removed.
- `openshift-default` GatewayClass, `openshift/java-21` ImageStream, `platform-observer` /
  Lightspeed cluster RBAC, the `workshop-attendees` Group, Kueue cluster objects, and the
  per-user/shared workshop namespaces — each removed (the GatewayClass and GitOps operator only
  if we created them).

**Prerequisite:** run it from a clone of this repo (it reads the component manifests to know which
operators belong to which stack) as a **cluster-admin**. If the `ogsr-uninstall-state` ConfigMap is
missing (e.g. an install predating this tooling), the script still removes everything owner-labeled
but **defaults to preserving operators and shared-object mutations** — safe, but review the plan.

**Verify afterwards** (the script prints these):

```
oc get ns -l workshop.redhat.com/owner=ogsr                       # expect: no resources
oc get applications -n openshift-gitops | grep -E 'pp-|entry-|workshop-config'   # expect: none
oc get csv -A | grep -v ogsr                                      # adopted operators still Present/Succeeded
```

The litmus test for "non-invasive": after uninstall, nothing the org owned should differ. If you
find a leftover, capture it and file it — the owner label (`-l workshop.redhat.com/owner=ogsr`) is
how we enumerate the full footprint on any cluster.
