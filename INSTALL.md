# Installing & Troubleshooting the Workshop

**Audience:** whoever stands this workshop up — on their own cluster, a customer's, or a lab cluster.
Not attendee-facing: attendees never read this, they get the modules.

Everything here has been performed on a live cluster. Where a step has bitten us, the guide says so and
tells you what it looked like — those entries cost real hours and are the reason this document exists.

Two sections are worth reading before you install rather than after:
[§2.4 Sizing](#24-sizing-how-many-nodes-to-order), because ordering too small a cluster is the most
common way a delivery fails, and
[§6.3](#63-an-operator-the-customer-owns-silently-stops-upgrading), because it describes a way this
install can quietly damage an operator the cluster's owner cares about.

---

## 1. What you are installing

A GitOps-delivered workshop: an Argo CD app-of-apps installs a platform portfolio (operators and shared
services), then a workshop layer (per-attendee namespaces, RBAC, quotas, Git accounts, and a browser
cockpit per attendee). Attendees never install anything; they consume what Argo reconciles.

**The non-invasive promise.** The workshop must drop onto an existing cluster without changing its
character. Concretely:

- Operators the cluster already has are **adopted**, not reinstalled. Install prints exactly what it
  adopted and records it, and uninstall refuses to touch those.
- We never alter cluster-wide default behaviour. (This is why the OpenShift console is opened in a new
  tab rather than embedded in the cockpit — embedding would need a global IngressController header
  rewrite, and that changes behaviour for every workload on the cluster.)
- Uninstall reverses what we created and leaves the rest, then a read-only checker proves it.

The litmus test for any change: **would anything of the customer's differ after uninstall?**

### Four things that look odd until you know why

These are the choices most likely to make you think something is broken or wasteful. Each was
deliberate.

- **Two Argo CD instances, not one** (~5 extra pods). The platform instance owns the machinery that
  builds every attendee's world; a second, namespace-scoped instance is where attendees create their
  own Applications in the GitOps modules. Split that way, an attendee mistake cannot delete the
  machinery. Merging them saves five pods and costs you that guarantee.
- **A `LoadBalancer` Service will sit `<pending>` forever.** There is no MetalLB, on purpose — it is a
  cluster-wide networking component and installing it would change the character of a cluster we do not
  own. The workshop exposes everything through Routes; the networking module teaches the `<pending>`
  as the real bare-metal behaviour rather than hiding it.
- **The AI modules need a model endpoint** and do not run one for you. They point at a shared
  Models-as-a-Service endpoint you configure in `vars.yaml`. No GPU is provisioned on your cluster.
- **Every attendee's starting state is an Argo Application**, not a script. `ws start <module>` writes
  a small Application and lets Argo materialise it, so a module's entry state is reproducible and
  `ws reset` is a delete-and-resync rather than a cleanup script trying to guess what changed.

---

## 2. Before you install

### 2.1 What you need

| Requirement | Notes |
|---|---|
| OpenShift **4.20+** | Verified on 4.22. Preflight fails below 4.20. |
| **cluster-admin** | Installing operators and cluster-scoped RBAC needs it. |
| A **default StorageClass** | The workshop provisions PVCs dynamically; several labs need RWX. |
| Local tools | `oc`, `yq` (mikefarah v4), `htpasswd`, `openssl`, `git` |
| A MaaS (model-as-a-service) endpoint | Only for the AI modules. Key is **model-scoped** — see §6.9. |

### 2.2 Run the preflight — always

```bash
ws preflight
```

Read-only. It checks local tooling, cluster access, version, StorageClass, and — the part that matters
most on a customer cluster — prints an **adoption forecast**: for every shared component, whether the
install will ADOPT what is already there or CREATE its own. Example:

```
▶ Adoption forecast (preview only — nothing is changed)
  • OpenShift GitOps                 ADOPT — operator present; install reuses it, uninstall preserves it
  • OpenShift Lightspeed             ADOPT — OLSConfig present; ai-assist skipped, existing provider reused
  • user-workload monitoring         ADOPT — enableUserWorkload already true; left as-is
  • GatewayClass openshift-default   ADOPT — present (a cluster istiod is already active)
```

**Show this to the customer before you install.** It is the whole non-invasive story in one screen, and
it is the moment to catch a component you did not expect them to have.

A `⚠ prior install detected` row means the cluster already ran the installer. Re-running is idempotent;
if you want a clean slate, uninstall first (§7).

### 2.3 Where to get a cluster

**What the cluster must give you**, however you obtain it:

- OpenShift 4.x with **cluster-admin** — the installer creates operators, CRDs and cluster-scoped objects.
- The node count and shape from §2.4. This is the one to get right up front; it is not adjustable later
  without disruption, and an undersized cluster fails in ways that look like workshop bugs.
- Outbound access to the image registries the operators pull from.

Any cluster meeting that runs the installer unmodified — `bootstrap/install.sh` reads `vars.yaml` and
takes no cluster-specific flags.

**If you are at Red Hat**, order the **OpenShift Field Asset** item from the Red Hat Demo Platform
(internal; the link will not resolve for anyone else):

> https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.ocp-field-asset.prod

That item exists for field-sourced workshop content: a full cluster with cluster-admin, node count and
shape chosen at order time. It is also the target this repo's `helm/bootstrap/` chart is built for, so
the workshop can be delivered either by running `bootstrap/install.sh` yourself or by pointing the
catalog item at the chart.

Whichever route: get the cluster with **enough lead time to run the install and a smoke test before the
session** — see §3 for the install budget. Never plan to install in front of the room.

### 2.4 Sizing: how many nodes to order

All numbers below were **measured on a live 8-attendee cluster**, not estimated.

**The workshop's own platform costs roughly 19 CPU / 59 Gi in requests** across ~80 pods — operators,
Argo CD, Gitea, the cockpits, RHACS, SonarQube, MTA, Keycloak, mesh and observability. That is a fixed
cost before a single attendee does anything, and it is the number people underestimate.

**Per attendee, actively working, it is far less than the quotas suggest.** One attendee with a typical
module materialized measured **5 pods / 0.6 CPU / 0.8 Gi**. The per-user quota *ceiling* across all 13
namespaces is 420 pods / 41 CPU / 82 Gi — but that is a guard rail, not a forecast. No attendee is ever
in thirteen namespaces at once; modules are independent and they work through one at a time.

So plan for the **peak concurrent module**, not the sum of quotas:

| Module class | Per attendee at peak | Examples |
|---|---|---|
| Light | ~1 CPU / 1 Gi | networking, config, GitOps, observability |
| Medium | ~2 CPU / 4 Gi | pipelines and the security-scanning runs |
| **Heavy** | **~4 CPU / 8–10 Gi** | Dev Spaces (8 Gi per workspace), MTA analysis, the AI modules |

**The planning formula:**

```
total = 20 CPU / 60 Gi   (platform)
      + attendees × 4 CPU / 10 Gi   (assume everyone on a heavy module at once)
      + 20% headroom
```

Worked examples:

| Cohort | Minimum allocatable | Practical order |
|---|---|---|
| 5 attendees | ~48 CPU / 132 Gi | 3 workers × 16 CPU / 64 Gi |
| **8 attendees** | **~62 CPU / 168 Gi** | **4 workers × 16 CPU / 64 Gi** |
| 12 attendees | ~82 CPU / 216 Gi | 5–6 workers × 16 CPU / 64 Gi |

**One module needs *free nodes*, not just free totals.** Deployment Targets & Scheduling is the only
module that asks the scheduler for four distinct placements at once — three anti-affinity-spread claims
replicas plus the `maxSurge: 1` pod of a rolling update. It needs **four non-batch nodes that can each
still admit a 200m-CPU / 256Mi pod**, judged on *requests*, not usage. It was authored on a 6-node
cluster; on a 5-node cluster whose schedulable nodes were already at 97–99% of their CPU requests from
the platform stacks (RHACS, ODF), exercises 2, 3 and 5 could not place a single additional replica even
though the cluster looked idle at 26–45% actual CPU. Aggregate headroom does not help here — a workload
that must spread cannot borrow capacity from a node it is forbidden to use. If you order lean, either
give the workers real slack or drop this module via `modules_disabled`.

**Memory is the binding constraint, not CPU.** The heavy modules are memory-hungry and CPU-idle — a
Dev Spaces workspace reserves 8 Gi and then mostly waits for a human to type. Order fewer, larger nodes
rather than many small ones: a 4 CPU / 16 Gi node cannot host a single Dev Spaces workspace plus its
share of platform pods, so small nodes strand capacity.

> **Reference point.** The cluster these numbers came from runs 5 schedulable nodes totalling 77.5 CPU /
> 214 Gi allocatable, and carries 8 attendees plus the full platform comfortably — with room to spare on
> everything except a hypothetical all-eight-in-Dev-Spaces moment.

**If you must run lean,** use `modules_disabled` in `vars.yaml` to drop the heavy modules from the
delivery. Their operators still install, but no attendee can start them, and the peak drops to the
medium row.

---

## 3. Installing

```bash
cp bootstrap/vars.example.yaml bootstrap/vars.yaml
# edit vars.yaml, then:
./bootstrap/install.sh
```

`install.sh` reads `vars.yaml` only — there are no CLI flags. The keys you will actually touch:

| Key | Meaning |
|---|---|
| `users` | Cohort size. Grow or shrink later with `ws scale-users N`. |
| `cluster_domain` | The `apps.` ingress domain. |
| `modules_disabled` | Modules to hide from this delivery — accepts `mNN` or slugs. |
| `workshop_user_password` | Shared attendee password. Deliberately memorable, not a secret. |
| `maas.endpoint` / `api_key` / `model` | AI modules only. |
| `repo_url` / `repo_revision` | Where the content is mirrored from. |

### What to expect

Install runs 6 phases and is idempotent — re-run it freely. Budget **15–20 minutes** to the "bootstrap
complete" banner, plus more for operators to finish reconciling behind it. It ends with a summary of
what it adopted and how many adopted resources it protected from teardown.

**Do not judge success by the banner alone.** Confirm with §4.

---

## 4. Verifying the install

Run these three, in order. They answer different questions.

```bash
ws doctor                 # is the environment sane? (login, Argo, Gitea, operators)
ws status                 # cohort dashboard: every platform app + every attendee
ws status --user user1    # drill into one attendee: namespaces + quota headroom
```

`ws status` is the one you will live in. A healthy cluster looks like:

```
Summary: 8 user(s) · 8/8 cockpit(s) ready · 0 entry app(s) · platform all-Synced ✅
```

Then spot-check a module end to end:

```bash
ws start  m01 --user user1
ws verify m01 --user user1
ws reset  m01 --user user1
```

**Verify scripts are mode-split.** `ws verify` at entry state asserts the attendee has NOT done the lab
yet; after the lab it asserts outcomes. A ✅ at the wrong mode is meaningless, so never "confirm" a
module by running verify at the wrong point.

---

## 5. Running the workshop

| Task | Command |
|---|---|
| Give attendees their world | Attendees self-serve: `ws prep <module>` in their cockpit |
| Materialize for someone stuck | `ws start <module> --user userN` |
| Show the finished state | `ws solve <module> --user userN` — **instructor only** |
| Put someone back to the start | `ws reset <module> --user userN` |
| Rotate the shared password | `ws passwd [NEWPASS]` |
| Grow/shrink the cohort | `ws scale-users N` |
| Fresh cohort, same platform | `ws cohort-reset --yes` |
| Push new content to cockpits | `ws git-refresh --restart-terminals --all` |
| Change the AI model / rotate the MaaS key | `ws maas set` — **no reinstall** |
| Check what the AI modules run on | `ws maas show` |
| Are any pods running an old image? | `ws rebuild-images --check` — read-only |
| Rebuild an app image and land it everywhere | `ws rebuild-images --image <name> --all` |

### Changing the MaaS model or rotating the key

**You do not need to reinstall.** Nothing about the model is baked into an image or a chart: at runtime
each AI module reads its model and endpoint from a per-namespace `maas-config` ConfigMap and its key
from a `maas-credentials` Secret, both derived from one upstream Secret
(`ogsr-system/ogsr-maas-credentials`). `ws maas` is the entry point to that Secret.

Two commands:

```
ws maas show                      # what are the AI modules actually running on?
ws maas set                       # validate, stage, and re-converge the AI modules
```

`ws maas set` reads `bootstrap/vars.yaml` (`.maas.api_key`, `.maas.endpoint`, `.maas.model`) by
default. Any field you do not supply falls back to that file, then to what is already on the cluster —
so the common changes are one flag each:

```
ws maas set --model qwen3-14b               # same key, different model
ws maas set --key-file ~/new-maas.key       # rotate the key, keep model + endpoint
pbpaste | ws maas set --key-stdin           # paste a key without it touching disk or your shell history
```

There is deliberately **no `--key <value>` flag**: an API key passed on the command line is readable by
every user on the machine through `ps`. Use `--key-file`, `--key-stdin`, or `vars.yaml`.

**Nothing is staged until the whole key + endpoint + model triple is proven.** `ws maas set` rejects a
3-segment JWT by shape, asks the endpoint's `/v1/models` whether it offers your model, and then spends
one token on a real `/v1/chat/completions` call — capturing the **status code only**, because a
LiteLLM 401 body echoes the whole token back. A 401/403 refuses the change outright and cannot be
overridden. All three values are then written together, because a credential from one source paired
with an endpoint from another is what took a cluster down on 2026-07-29.

**MaaS keys are model-scoped**, so "wrong model" and "wrong key" produce the same 401. This is the
single most common cause of AI-module failures, and it is why the model travels with the credential
rather than being a chart default. If `ws maas set` reports the model is not among the ones the
endpoint offers, believe it — the chart default is not necessarily what your key covers.

After staging, `ws maas set` re-runs each AI module's converge hook (`agentic-ai`,
`ai-assisted-development`, `app-modernization`, `jobs-batch-kueue`) for every attendee who has that
module materialized. It does this by deleting the hook Job and driving a fresh Argo sync operation —
**not** by `ws reset`, which would purge the attendee's namespaces and cost them their lab work. It is
safe to run mid-session and safe to run twice. Scope it with `--user userN`, or skip it with
`--no-converge`.

Finish with `ws maas show` and confirm every attendee reads `working`.

### Rebuilding a Parasol app image mid-cluster

`oc start-build` produces a new image. It does **not** put that image into anything that is already
running: a container keeps the digest it started with until something rolls it. Every workshop
Deployment sets `imagePullPolicy: Always`, so a restart *lands* the rebuild — but somebody still has to
perform the restart, in every namespace that consumes the image, and that list changes every time an
attendee starts a module.

`ws rebuild-images` is that step:

```
ws rebuild-images --check                              # read-only: which pods are behind their tag?
ws rebuild-images --image parasol-claims --all         # build it, then roll every stale consumer
ws rebuild-images --no-build --user user3              # roll one attendee against the tags as they are
```

It enumerates every Deployment, StatefulSet, DaemonSet, CronJob and Knative Service on the cluster
whose image comes from `ogsr-parasol-images` or from a per-user build, and compares **the digest each
running pod reports** (`containerStatuses[].imageID`) against the digest its ImageStream tag points at
now. The workload's own spec cannot answer this — it says `parasol-claims:1.1` before and after a
rebuild — which is exactly why the check has to happen at the pod.

Three consequences worth knowing:

- **A rebuild that changed nothing restarts nothing.** Workloads already on the current digest are left
  alone, so the command is safe to re-run and safe to run against a live cohort. That is also why
  rolling restarts require you to name a scope — `--user userN` or `--all` — while `--check` needs none.
- **`--check` exits 1 when anything is behind**, so it is usable as a gate in CI or a pre-session check.
  It never builds and never restarts.
- **Knative Services cannot be rolled.** A ksvc only picks up a new image via a new *Revision*, and
  both serverless entry states pin their revision name so the traffic split can address revisions
  by name — Knative's webhook rejects any template change that keeps the same name. The command detects
  this and tells you to re-materialize instead: `ws reset <module> --user userN`.

A stalled rollout is not an outage: the previous ReplicaSet keeps serving the old image until the new
pods are ready, so a namespace whose `ResourceQuota` is full will report a failure with its old pods
still up. Clear the quota and re-run, or `oc rollout undo` to abandon the change.

This is deliberately **not** part of `ws git-refresh`, which is non-disruptive by contract.

### Cockpit content is built at pod start

Each cockpit builds its content from the **in-cluster Gitea mirror** when its pod starts. So after you
push content:

1. `ws git-refresh` syncs the mirror,
2. **wait until the mirror's HEAD equals origin's** — it prints this,
3. only then restart the cockpits.

Restarting early serves stale content and looks like your change did not land. `ws git-refresh
--restart-terminals` does the sequencing for you; prefer it over doing the steps by hand.

---

## 6. Troubleshooting

Symptom → cause → fix. Ordered roughly by how often it bites.

### 6.1 An Argo Application will not sync

**Never start a sync while an operation is already Running** — the request is silently swallowed and you
will think the sync did nothing. The reliable sequence is: mirror-sync → hard refresh → wait ~10s → sync.

For a genuinely stuck operation, patch `status.operationState.phase=Terminating`, then start a fresh sync.

**If a sync keeps applying content you already changed**, you are looking at a poisoned manifest cache.
It survives a new commit SHA, a Redis flush, and even reverting a Helm parameter override — the stale
render can re-apply minutes later on an unrelated reconcile. The reliable bust is to **bump the chart
version**.

Two related traps:

- Argo's `helm.parameters` does **not** expand Helm's `{a,b,c}` list literals the way the `helm` CLI
  does. Keep list values in `values.yaml` and parameterize only scalars.
- Auto-heal will **not** re-run a Sync-phase hook when nothing else drifted. A hook-only chart change
  silently does not propagate, and `ws git-refresh` reports success either way. Delete the hook Job
  first, or force a targeted resource sync.

### 6.2 A namespace is stuck `Terminating`

**Read the conditions — they name the blast radius.**

```bash
oc get ns <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'
```

| Condition | Meaning | Action |
|---|---|---|
| `NamespaceDeletionDiscoveryFailure=True` | A stale APIService broke discovery. **Every** namespace on the cluster is wedged, including ones that are not yours. | Find and remove the unavailable APIService. |
| `=False` with `NamespaceFinalizersRemaining=True` | One stranded finalizer, in that namespace only. | See below. |

For the second: find the blocking object and check whether its controller still exists. A finalizer
whose operator is still running clears itself if you wait. A finalizer whose operator was deleted first
can **never** run and needs the finalizer removed by hand.

**Patch the blocking object, never the namespace's own finalizer** — patching the namespace orphans the
content instead of deleting it.

### 6.3 An operator the customer owns silently stops upgrading

Cause: **two OperatorGroups in one namespace.** A namespace may hold exactly one. With two, OLM sets
every CSV in that namespace to `Failed` / `TooManyOperatorGroups` and stops reconciling — **while the
pods keep running 1/1.** Nothing looks wrong until their next upgrade, which never comes.

`openshift-operators` always ships one, so nothing may ever apply an OperatorGroup there.

Assert after any install that this returns nothing:

```bash
oc get operatorgroups -A --no-headers | awk '{print $1}' | sort | uniq -c | awk '$1>1'
```

Related: three API groups claim the plural `subscriptions`, and `messaging.knative.dev` shadows OLM's.
**Always write `subscriptions.operators.coreos.com` in full.**

### 6.4 Database pods stuck Terminating, replacements blocked

Cluster disruption can leave RWO volumes with wedged `VolumeAttachment` objects. The signature is
**Multi-Attach errors blocking replacement pods in several namespaces at once** — it presents as
multiple unrelated outages.

Fix: force-delete the stuck pods, then delete the wedged VolumeAttachments. An orphaned-CSV OLM wedge
can co-present, so re-check §6.3 afterwards.

### 6.5 A cockpit serves old content

Almost always the mirror-versus-restart ordering in §5. Confirm what is actually being served rather
than trusting the job that pushed it:

```bash
curl -sk "https://showroom-user1.<apps-domain>/modules/<slug>/lab.html" | grep -o '<expected string>'
```

### 6.6 An attendee cannot log into a tool

| Tool | Credentials |
|---|---|
| OpenShift console | `userN` + workshop password, via the **workshop-users** identity provider |
| Gitea | Same pair (accounts seeded at install) |
| SonarQube | Same pair — **but signing in is optional**, the dashboard is readable anonymously |
| MTA | **No login at all** — the Hub is open |
| Argo CD (attendee instance) | Via the cockpit link |

If SonarQube rejects the login, the seed Job did not run. It is an Argo Sync hook, so re-syncing
`workshop-config` re-runs it:

```bash
oc logs job/sonarqube-user-seed -n sonarqube --tail=20
```

### 6.7 MTA: attendees see each other's applications

Expected, and worth briefing the room about. The Hub is **one shared instance with no per-user view**,
and MTA's roles (`tackle-admin` / `architect` / `migrator`) are personas, not tenants — enabling
authentication would not change what anyone can see, and `tackle-migrator` cannot create applications
at all, which would break the lab.

This is why the lab has each attendee name their application `parasol-legacy-claims-<user>`. Portfolio
state lives in the Hub database, **not** in the attendee's namespace, so `ws reset` does not remove it —
delete stale applications in the console between cohorts.

### 6.8 A hook Job fails immediately

Two recurring causes:

- **`ose-cli` OOMs at 256Mi.** Give hook Jobs **≥512Mi**.
- **No runtime `dnf`** under the restricted SCC. Use a purpose-built image rather than installing
  packages at runtime.

For credential handoff between an init container and the main container, use a memory-backed `emptyDir`.

### 6.9 AI modules return authentication errors

MaaS keys are **model-scoped**. A key issued for one model will not authenticate against another, and
the failure looks like a generic auth error rather than "wrong model". Confirm the model your key
actually covers against the endpoint's `/v1/models` before debugging anything else.

Start with `ws maas show` — it prints, per namespace, the model and endpoint each AI module is actually
using plus the verdict its converge hook recorded (`aiPathAvailable` / `aiPathReason`), and a
working / degraded / unknown line per attendee. Two verdicts name this exact problem:

- `credential-rejected-by-endpoint` — the key is wrong for this endpoint, **or** right for a different
  model.
- `credential-is-a-jwt-not-an-api-key` — the modules fell back to an adopted OpenShift Lightspeed
  secret whose bearer belongs to another provider (an Azure-OpenAI-wired Lightspeed writes one). Stage
  the workshop's own credential so the hooks stop guessing.

The fix is `ws maas set` (see §5, "Changing the MaaS model or rotating the key"), not a reinstall.

### 6.10 `parasol-web` / `parasol-claims` never become Ready

They run images built into the cluster by the workshop's image-load step. If those imagestreams have not
populated, the Deployments exist but never start. This is a provisioning timing issue, not a module
defect — check `ogsr-parasol-images` pods. The verify scripts deliberately assert **presence** for these
tiers and **readiness** only for tiers on always-present platform images.

---

## 7. Uninstalling

Three commands, in order. Never skip the dry run on a customer cluster.

```bash
./bootstrap/ogsr-uninstall.sh --dry-run    # prints the WIPE / PRESERVE plan
./bootstrap/ogsr-uninstall.sh              # performs it
./bootstrap/ogsr-check-clean.sh            # read-only proof; non-zero while anything remains
```

**`ogsr-check-clean.sh` never deletes.** It reports leftover namespaces, owner-labelled cluster-scoped
objects, stale APIServices, dead webhooks and created-by-us CRDs with instance counts, and prints the
exact `oc` command to remove each — then the cluster's admin decides. That separation is deliberate:
the tool that proves cleanliness must not be the tool that changes things.

**How long it takes.** Its runtime tracks the number of leftovers, not the size of the cluster, because
it classifies each marked object it finds. In the position above — straight after an uninstall — that is
well under a minute. Run against a *full* install, where every object is a finding, it takes a couple of
minutes; that is normal and it is not stuck. Every section prints its elapsed time as `(t+NNs)` and
section `[8/9]` announces how many objects it is about to classify, so you can always see it moving. On
a rate-limited cluster, lower the fan-out with `OGSR_CHECK_JOBS=2`.

### What is preserved

Anything the adoption forecast marked ADOPT: operators the cluster already had, their namespaces,
Subscriptions, CSVs and OperatorGroups, plus pre-existing cluster settings the install merely read.
Uninstall de-labels the namespaces it adopted rather than deleting them.

### Reset vs uninstall

| | Scope | Use when |
|---|---|---|
| `ws reset <module> --user U` | One attendee, one module | Someone wants to redo an exercise |
| `ws cohort-reset --yes` | All attendee state; platform stays | New cohort on the same cluster |
| `ogsr-uninstall.sh` | Everything we created | Giving the cluster back |

---

## 8. Escalation checklist

Before raising anything, collect:

```bash
ws doctor
ws status
ws diag --user <userN> [<module>]     # read-only bundle for one stuck attendee
oc get applications -n openshift-gitops
```

`ws diag` prints entry-app status with conditions and operation state, per-namespace recent events,
not-Ready pods, cockpit status and a logs pointer — plus copy-paste follow-up commands. It always exits
0; it is a report, not a gate.

---

## Appendix — a note on trusting output

Two habits this project learned the hard way, both worth carrying:

**A green checkmark from the wrong check is worse than no check.** Verify scripts are mode-split for
this reason, and a false ❌ destroys attendee trust in every other ✅.

**Diagnose from the side effect, not from the status field.** Background jobs, Argo operations and
harness task states have all been observed reporting "running" or "succeeded" while the truth was
elsewhere. The trustworthy signals are cluster state, the served page, and file timestamps.
