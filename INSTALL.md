# Installing the Workshop

How to stand this workshop up on an OpenShift cluster, run a delivery, and clean up afterwards.

All `ws` commands below are run from a clone of this repo as `tools/ws/ws`. Attendees get `ws` on their
`PATH` inside their cockpit; you call it by path.

**Contents**

1. [What you need](#1-what-you-need)
2. [Sizing the cluster](#2-sizing-the-cluster)
3. [Installing](#3-installing)
4. [Verifying the install](#4-verifying-the-install)
5. [Running the workshop](#5-running-the-workshop)
6. [Ending a delivery](#6-ending-a-delivery)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. What you need

### The cluster

| Requirement | Notes |
|---|---|
| OpenShift **4.20+** | Verified on 4.22. The preflight check fails below 4.20. |
| **cluster-admin** | The install creates operators, CRDs and cluster-scoped RBAC. |
| A **default StorageClass** | The workshop provisions PVCs dynamically; several labs need RWX. |
| **`linux/amd64` worker nodes** | |
| Outbound registry access | Operators pull from Red Hat and Quay registries. |
| Enough capacity | See [§2](#2-sizing-the-cluster). Get this right before you order — it is not adjustable later without disruption. |

An OpenShift Local / single-node cluster is not a supported target: see the sizing table for why.

### On the machine you install from

| Tool | Why |
|---|---|
| `oc` | Logged in to the cluster as cluster-admin. |
| `git` | Clone this repo; the installer seeds Git content from it. |
| `yq` (mikefarah v4) | The installer reads all of its input from `vars.yaml`. |
| `htpasswd` | Creates the attendee identity provider. Ships in `httpd-tools` / `brew install httpd`. |
| `openssl` | Generates the attendee passwords and secrets. |

The installer exits immediately with a clear message if any of these is missing.

### A model endpoint (AI modules only)

The AI modules call an **OpenAI-compatible chat-completions endpoint** — Red Hat Models-as-a-Service,
an on-cluster vLLM runtime, or a public provider. You configure it in `vars.yaml`; no GPU is
provisioned on your cluster. Skip it and the AI modules are simply unavailable.

**MaaS keys are model-scoped.** A key issued for one model returns 401 against another, and the error
does not say so. This is the most common cause of AI-module failures — see [§7.7](#77-ai-modules-return-authentication-errors).

---

## 2. Sizing the cluster

All figures measured on a live 8-attendee cluster.

**The platform costs about 32 CPU / 56 Gi in requests** across ~170 pods, before a single attendee does
anything. This is the number people underestimate.

| Layer | Pods | CPU requests | Memory requests |
|---|---|---|---|
| Operators (RHACS, Keycloak, GitOps, mesh, MTA, Dev Spaces, …) | 132 | 27.3 | 47.6 Gi |
| Workshop shared services (Gitea, cockpits, seeded apps) | 38 | 4.4 | 8.5 Gi |
| 8 attendees, 1–2 modules each | ~27 | — | 6.5 Gi |

**RHACS alone is 26 Gi — 46% of the platform's memory.** If you need to order lean, dropping the
RHACS-dependent modules via `modules_disabled` is the single biggest lever you have.

### What one attendee costs

Plan for the **peak concurrent module**, not the sum of anyone's quota. Measured per attendee:

| Module class | Per attendee at peak | Examples |
|---|---|---|
| Light | ~1 CPU / 1 Gi | networking, config, GitOps, observability |
| Medium | ~2 CPU / 4 Gi | pipelines, the security-scanning runs |
| **Heavy** | **~2.5 CPU / 0.5 Gi requested** (~4.25 Gi limit) | Dev Spaces workspace, MTA analysis, the AI modules |

Working through one or two modules, attendees measured **2–6 pods, 0.3–1.1 Gi of requests, and
28–514 Mi actually in use**. The per-user quota ceiling of 41 CPU / 82 Gi is a guard rail, not a
forecast — nobody is ever in all thirteen of their namespaces at once.

So the planning allowance is **2.5 CPU and 1.5 Gi of requests per attendee**: the heaviest module's
CPU, plus enough memory for its workspace and the one or two other modules they have materialized.

### What to order

```
total = 32 CPU / 56 Gi                (the platform, measured above)
      + attendees × 2.5 CPU / 1.5 Gi  (assume everyone is on a heavy module at once)
      + 20% headroom
```

Sized against a **32 vCPU / 64 GiB** worker — figure on roughly 30 CPU and 58 Gi of that being
*allocatable* once kubelet and system reservations come out.

| Workshop size | Attendees | Minimum allocatable | Workers by capacity | **Order** |
|---|---|---|---|---|
| Small | 12 | ~74 CPU / ~89 Gi | 3 | **5** |
| **Normal** | **20** | **~98 CPU / ~103 Gi** | **4** | **5** |
| Large | 30 | ~128 CPU / ~121 Gi | 5 | **5** |

**Five 32 vCPU / 64 GiB workers runs any workshop up to 30 people.** Capacity is not what sets the
floor below 30 — module topology is, and the next section explains why. If you order for capacity
alone you will land on 3 or 4 workers and one module will not run.

**CPU decides the capacity column, not memory.** Every row needs one to two more nodes for CPU than
for memory, and the gap widens with the cohort. That is the Dev Spaces workspace: 2.5 CPU requested
against 0.5 Gi. It is a large CPU reservation for something that mostly waits for a human to type,
but requests are what the scheduler enforces, so requests are what you buy.

**Order fewer, larger nodes.** A workspace needs its 2.5 CPU on *one* node, so a 4 CPU worker can
host exactly one and nothing else. Small nodes strand capacity you have paid for.

**Do not size on a `top` reading.** Actual CPU ran 4–61 m per attendee against requests an order of
magnitude higher. A cluster that looks 90% idle will still refuse to place a pod.

> **The footprint grows with modules *materialized*, not modules *in progress*.** Starting a module
> only evicts one that declares a conflict in the same namespace, so an attendee working through
> several non-conflicting modules accumulates all of them until a reset. The figures above are for
> one or two modules each; a cohort deep into the catalog sits higher. If a long delivery starts
> crowding the cluster, resetting finished modules reclaims it.

### Why five workers, when capacity says three

**One module needs free *nodes*, not just free totals — and that is what sets the floor.**

*Deployment Targets & Scheduling* spreads three claims replicas across three distinct nodes with
anti-affinity, then performs a rolling update whose `maxSurge` pod needs a fourth. So it wants **four
nodes that can each still admit a 200m / 256Mi pod**, judged on requests rather than usage.

Those four must be nodes the workload is allowed to use. The installer dedicates one worker to a
**batch pool** — labelled and tainted `NoSchedule` — so that *Jobs, Batch & Queued Workloads* can
teach node pinning. That worker does not count toward the four.

**Four non-batch plus one batch is five**, at every cohort size. Aggregate headroom does not help
here: a workload that must spread cannot borrow capacity from a node it is forbidden to use.

The installer already refuses the trap in one direction — it **skips the batch taint below three
workers**, because tainting one of two workers starved the rest of the cluster in practice. It does
not, however, know whether you enabled the scheduling module, so three workers plus that module is a
combination it will let you build.

**If you want to run leaner than five workers**, disable that module rather than hoping it fits:

```yaml
modules_disabled: [deployment-targets-scheduling]
```

Then the capacity column governs — 3 workers for a small cohort, 4 for normal. `modules_disabled`
works the same way for any heavy module: the operators still install, but no attendee can start it.

### Where to get a cluster

**At Red Hat:** order the **OpenShift Field Asset** item from the Red Hat Demo Platform (internal):

> https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.ocp-field-asset.prod

Node count and shape are chosen at order time. This is also the target this repo's `helm/bootstrap/`
chart is built for, so a delivery can be driven either by running `bootstrap/install.sh` yourself or by
pointing the catalog item at the chart.

Whichever route: get the cluster with enough lead time to **install and smoke-test before the session**.
Never plan to install in front of the room.

---

## 3. Installing

### 3.1 Preflight (read-only)

```bash
tools/ws/ws preflight
```

Checks local tooling, cluster access, version and StorageClass, then prints an **adoption forecast** —
for every shared component, whether the install will reuse what is already there or create its own:

```
▶ Adoption forecast (preview only — nothing is changed)
  • OpenShift GitOps                 ADOPT — operator present; install reuses it, uninstall preserves it
  • OpenShift Lightspeed             ADOPT — OLSConfig present; ai-assist skipped, existing provider reused
  • user-workload monitoring         ADOPT — enableUserWorkload already true; left as-is
```

**On a customer cluster, show this to the customer before installing.** It is the moment to catch a
component you did not expect them to have.

A `⚠ prior install detected` row means the cluster already ran the installer. Re-running is idempotent;
for a fresh cohort run `bootstrap/ogsr-reset.sh` ([§6](#6-ending-a-delivery)) rather than a full
uninstall — reinstalling the platform costs far more time than resetting it.

### 3.2 Configure

All input lives in one gitignored file. The installer takes no flags.

```bash
cp bootstrap/vars.example.yaml bootstrap/vars.yaml
# edit bootstrap/vars.yaml
```

| Key | Meaning |
|---|---|
| `users` | Cohort size. Grow or shrink later with `ws scale-users N`. |
| `cluster_domain` | The `apps.` ingress domain. Leave `""` to auto-detect. |
| `modules_disabled` | Modules to hide from this delivery — `mNN` or slugs. A disabled module is hidden from the cockpit and its components are not installed. |
| `workshop_user_password` | Shared attendee password. Deliberately memorable, not a secret. |
| `maas.endpoint` / `.model` / `.api_key` | AI modules only. |
| `repo_url` / `repo_revision` | Where content is mirrored from. |

### 3.3 Install

```bash
./bootstrap/install.sh
```

Six phases, idempotent — re-run it freely. Budget **15–20 minutes** to the completion banner, plus more
for operators to finish reconciling behind it. It ends with a summary of what it adopted.

**Do not judge success by the banner.** Confirm with §4.

---

## 4. Verifying the install

```bash
tools/ws/ws doctor                 # is the environment sane? (login, Argo, Gitea, operators)
tools/ws/ws status                 # cohort dashboard: every platform app + every attendee
tools/ws/ws status --user user1    # one attendee: namespaces + quota headroom
```

A healthy cluster looks like:

```
Summary: 8 user(s) · 8/8 cockpit(s) ready · 0 entry app(s) · platform all-Synced ✅
```

Then spot-check one module end to end:

```bash
tools/ws/ws start  m01 --user user1
tools/ws/ws verify m01 --user user1
tools/ws/ws reset  m01 --user user1
```

**Verify is mode-split.** At entry state it asserts the attendee has *not* done the lab yet; after the
lab it asserts the outcomes. A ✅ at the wrong point means nothing, so do not "confirm" a module by
running verify at the wrong time.

---

## 5. Running the workshop

Attendees self-serve from their cockpit (`ws prep`, `ws verify`, `ws reset`). These are the admin-side
commands.

| Task | Command |
|---|---|
| Materialize a module for someone stuck | `tools/ws/ws start <module> --user userN` |
| Show the finished state — **instructor only** | `tools/ws/ws solve <module> --user userN` |
| Put someone back to the start | `tools/ws/ws reset <module> --user userN` |
| Rotate the shared password | `tools/ws/ws passwd [NEWPASS]` |
| Grow or shrink the cohort | `tools/ws/ws scale-users N` |
| Push new content to cockpits | `tools/ws/ws git-refresh --restart-terminals --all` |
| Change the AI model or rotate the key | `tools/ws/ws maas set` |
| Check what the AI modules run on | `tools/ws/ws maas show` |
| Are any pods running an old image? | `tools/ws/ws rebuild-images --check` |
| Rebuild an app image everywhere | `tools/ws/ws rebuild-images --image <name> --all` |

### 5.1 Publishing content updates mid-session

Each cockpit builds its content from the in-cluster Gitea mirror **when its pod starts**. So the order
matters: sync the mirror, wait until its HEAD matches origin, *then* restart the cockpits. Restarting
early serves stale content and looks like your change never landed.

One command does the sequencing:

```bash
tools/ws/ws git-refresh --restart-terminals --all
```

A scope is required — `--restart-terminals` on its own refuses with "restart needs a target" and
restarts nothing. Use `--user <u>` for one session or `--all` for the cohort. Run it between modules,
never mid-exercise.

### 5.2 Changing the AI model or rotating the key

**No reinstall needed.** Each AI module reads its model and endpoint from a ConfigMap and its key from a
Secret at runtime; `ws maas` is the entry point to them.

```bash
tools/ws/ws maas show                            # what are the AI modules actually running on?
tools/ws/ws maas set --model qwen3-14b           # same key, different model
tools/ws/ws maas set --key-file ~/new-maas.key   # rotate the key, keep model + endpoint
pbpaste | tools/ws/ws maas set --key-stdin       # paste a key without it touching disk or history
```

Any value you do not supply falls back to `vars.yaml`, then to what is already on the cluster.

There is deliberately **no `--key <value>` flag** — a key on the command line is readable by every user
on the machine via `ps`.

**Nothing is staged until the key, endpoint and model are proven together.** `ws maas set` checks the
key's shape, asks the endpoint's `/v1/models` whether it offers your model, then spends one token on a
real completion. A 401/403 refuses the change and cannot be overridden. All three values are written
together, because a key from one source paired with an endpoint from another is a known way to break a
running cluster.

Afterwards it re-converges every AI module for every attendee who has one materialized — without
touching their lab work. Safe mid-session and safe to run twice. Scope with `--user userN`, or skip with
`--no-converge`. Finish with `ws maas show` and confirm each attendee reads `working`.

### 5.3 Rebuilding an app image mid-cluster

`oc start-build` produces a new image but does **not** put it into anything already running — a
container keeps its digest until something rolls it.

```bash
tools/ws/ws rebuild-images --check                        # read-only: which pods are behind?
tools/ws/ws rebuild-images --image parasol-claims --all   # build, then roll every stale consumer
tools/ws/ws rebuild-images --no-build --user user3        # roll one attendee against current tags
```

It compares the digest each **running pod** reports against the digest its ImageStream tag points at
now — the workload spec cannot answer this, since it says `parasol-claims:1.1` before and after.

- **A rebuild that changed nothing restarts nothing**, so it is safe against a live cohort.
- **`--check` exits 1 when anything is behind**, so it works as a pre-session gate. It never builds or
  restarts.
- **Knative Services cannot be rolled** — a ksvc needs a new Revision, and the serverless entry states
  pin revision names. Re-materialize instead: `ws reset <module> --user userN`.

---

## 6. Ending a delivery

Install once. What you run next depends on what you are doing.

| Command | Scope | Use when |
|---|---|---|
| `tools/ws/ws reset <module> --user U` | One attendee, one module | Someone wants to redo an exercise |
| `./bootstrap/ogsr-reset.sh` | All attendee lab content; platform and every account stay | **End of a delivery, same cluster hosts the next cohort — the normal path** |
| `./bootstrap/ogsr-wipe-users.sh` | `user2`…`userN` removed; `user1` kept as a working sample | Cutting the cluster down to one attendee |
| `./bootstrap/ogsr-uninstall.sh` | Everything the workshop created | Giving the cluster back to its owner |

All three scripts take `--dry-run` (print the plan, change nothing) and `--yes` (skip the prompt). They
need a full repo checkout — copying `bootstrap/` alone will not work.

### 6.1 Between cohorts: `ogsr-reset.sh`

```bash
./bootstrap/ogsr-reset.sh --dry-run              # print the plan
./bootstrap/ogsr-reset.sh                        # confirm, then reset
./bootstrap/ogsr-reset.sh --restart-terminals    # also cycle the cockpits for the new group
```

Deletes all lab content and returns the cluster to its immediately-post-install state. Keeps the
platform, every attendee account, Gitea with every repository, Keycloak with every login, and every
cockpit — that is the design, and it is worth stating plainly to whoever uses the cluster next.

### 6.2 Cutting down to one attendee: `ogsr-wipe-users.sh`

```bash
./bootstrap/ogsr-wipe-users.sh --dry-run
./bootstrap/ogsr-wipe-users.sh
./bootstrap/ogsr-wipe-users.sh --keep 2          # keep user1 and user2 (default 1)
```

Removes `user2`…`userN` entirely — namespaces, Keycloak identities and realms, Gitea accounts and
repositories, cockpits, quotas, Argo projects and OpenShift identities. Verified on a real cluster:
nothing belonging to a removed user survives in any of those.

**Two things it leaves behind**, neither a reason to stop:

1. **SonarQube accounts survive** — the only leftover that can bite. The seed job is
   create-if-absent, so re-provisioning a cohort here finds `user2` already present and skips it,
   leaving that account on the *old* password while every other tool moves to the new one. Harmless if
   the next cohort reuses the same password; otherwise delete the stale accounts in SonarQube first.
2. **The Developer Hub catalog is not pruned.** Components an attendee scaffolded stay listed after
   their repository is gone. Cosmetic, never a collision.

### 6.3 Removing the workshop: `ogsr-uninstall.sh`

```bash
./bootstrap/ogsr-uninstall.sh --dry-run    # prints the WIPE / PRESERVE plan
./bootstrap/ogsr-uninstall.sh              # performs it
./bootstrap/ogsr-check-clean.sh            # read-only proof; non-zero while anything remains
```

**Never skip the dry run on a customer cluster.**

**What is preserved:** anything the adoption forecast marked ADOPT — operators the cluster already had,
their namespaces, Subscriptions, CSVs and OperatorGroups. Adopted namespaces are de-labelled rather
than deleted.

`ogsr-check-clean.sh` **never deletes anything.** It reports leftover namespaces, stale APIServices,
dead webhooks, orphaned CSVs and workshop-created CRDs with live instance counts, and prints the exact
`oc` command to remove each — the cluster's admin decides. Against a full install it takes a couple of
minutes and every section prints elapsed time, so it is visibly working rather than hung.

---

## 7. Troubleshooting

### 7.1 An Argo Application will not sync

**Never start a sync while an operation is already Running** — the request is silently swallowed. The
reliable sequence is: sync the mirror → hard refresh → wait ~10s → sync.

For a genuinely stuck operation, patch `status.operationState.phase=Terminating`, then sync fresh.

**If a sync keeps re-applying content you already changed**, the manifest cache is poisoned. It survives
a new commit SHA, a Redis flush, and even reverting a Helm parameter override. The reliable fix is to
**bump the chart version**.

Two related traps:

- Argo's `helm.parameters` does not expand Helm's `{a,b,c}` list literals the way the `helm` CLI does.
  Keep lists in `values.yaml` and parameterize only scalars.
- Auto-heal will not re-run a Sync-phase hook when nothing else drifted, so a hook-only change silently
  does not propagate. Delete the hook Job first, or force a targeted resource sync.

### 7.2 A namespace is stuck `Terminating`

Read the conditions — they name the blast radius:

```bash
oc get ns <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'
```

| Condition | Meaning | Action |
|---|---|---|
| `NamespaceDeletionDiscoveryFailure=True` | A stale APIService broke discovery. **Every** namespace on the cluster is wedged, including ones that are not yours. | Find and remove the unavailable APIService. |
| `=False` with `NamespaceFinalizersRemaining=True` | One stranded finalizer, that namespace only. | See below. |

For the second: find the blocking object and check whether its controller still exists. A finalizer
whose operator is still running clears itself if you wait; one whose operator was deleted first can
never run and must be removed by hand.

**Patch the blocking object, never the namespace's own finalizer** — patching the namespace orphans the
content instead of deleting it.

### 7.3 An operator the cluster owner cares about stops upgrading

Cause: **two OperatorGroups in one namespace.** A namespace may hold exactly one. With two, OLM marks
every CSV there `Failed` / `TooManyOperatorGroups` and stops reconciling — **while the pods keep running
1/1**. Nothing looks wrong until an upgrade that never comes.

`openshift-operators` always ships one, so nothing may ever add another there.

Assert after any install that this returns nothing:

```bash
oc get operatorgroups -A --no-headers | awk '{print $1}' | sort | uniq -c | awk '$1>1'
```

Related: three API groups claim the plural `subscriptions`. Always write
`subscriptions.operators.coreos.com` in full.

### 7.4 Database pods stuck Terminating, replacements blocked

Cluster disruption can leave RWO volumes with wedged `VolumeAttachment` objects. The signature is
**Multi-Attach errors blocking replacement pods in several namespaces at once**, which presents as
multiple unrelated outages.

Force-delete the stuck pods, then delete the wedged VolumeAttachments. An orphaned-CSV wedge can
co-present, so re-check §7.3 afterwards.

### 7.5 A cockpit serves old content

Almost always the mirror-versus-restart ordering in [§5.1](#51-publishing-content-updates-mid-session).
Confirm what is actually served rather than trusting the job that pushed it:

```bash
curl -sk "https://showroom-user1.<apps-domain>/modules/<slug>/lab.html" | grep -o '<expected string>'
```

### 7.6 An attendee cannot log into a tool

| Tool | Credentials |
|---|---|
| OpenShift console | `userN` + workshop password, via the **workshop-users** identity provider |
| Gitea | Same pair (accounts seeded at install) |
| SonarQube | Same pair — but signing in is optional, the dashboard is readable anonymously |
| MTA | No login at all — the Hub is open |
| Argo CD (attendee instance) | Via the cockpit link |

If SonarQube rejects the login, the seed job did not run. It is an Argo sync hook, so re-syncing
`workshop-config` re-runs it:

```bash
oc logs job/sonarqube-user-seed -n sonarqube --tail=20
```

### 7.7 AI modules return authentication errors

**MaaS keys are model-scoped.** A key issued for one model fails against another, and the error looks
generic rather than saying so.

Start with `tools/ws/ws maas show` — it prints, per attendee, the model and endpoint in use and a
working / degraded / unknown verdict. Two verdicts name this problem directly:

- `credential-rejected-by-endpoint` — the key is wrong for this endpoint, **or** right for a different
  model.
- `credential-is-a-jwt-not-an-api-key` — the modules fell back to an adopted Lightspeed secret belonging
  to another provider. Stage the workshop's own credential.

The fix is `ws maas set` ([§5.2](#52-changing-the-ai-model-or-rotating-the-key)), not a reinstall.

### 7.8 MTA: attendees see each other's applications

Expected — brief the room. The Hub is one shared instance with no per-user view, and MTA's roles are
personas rather than tenants, so enabling authentication would not change what anyone sees.

This is why the lab has each attendee name their application `parasol-legacy-claims-<user>`. Portfolio
state lives in the Hub database, not the attendee's namespace, so `ws reset` does not remove it — delete
stale applications in the MTA console between cohorts.

### 7.9 A hook Job fails immediately

Two recurring causes:

- **`ose-cli` OOMs at 256Mi.** Give hook Jobs **≥512Mi**.
- **No runtime `dnf`** under the restricted SCC. Use a purpose-built image rather than installing
  packages at runtime.

### 7.10 `parasol-web` / `parasol-claims` never become Ready

They run images built into the cluster by the workshop's image-load step. If those ImageStreams have not
populated, the Deployments exist but never start — check the `ogsr-parasol-images` namespace. This is a
provisioning timing issue, not a module defect.

### 7.11 A `LoadBalancer` Service sits `<pending>` forever

Expected. There is no MetalLB on purpose — it is a cluster-wide networking component, and installing it
would change the character of a cluster we do not own. The workshop exposes everything through Routes,
and the networking module teaches the `<pending>` as real bare-metal behaviour.

### Collect this before escalating

```bash
tools/ws/ws doctor                             # whole cluster
tools/ws/ws doctor --user <userN>              # same checks, other attendees filtered out
tools/ws/ws status
tools/ws/ws diag --user <userN> [<module>]     # read-only bundle for one stuck attendee
oc get applications -n openshift-gitops
```

`ws diag` prints entry-app status and conditions, recent events per namespace, not-Ready pods, cockpit
status and a logs pointer. It always exits 0 — it is a report, not a gate.

---

## Appendix — how the install stays non-invasive

The workshop must drop onto an existing cluster without changing its character:

- **Operators already present are adopted**, never reinstalled or upgraded. The install prints what it
  adopted, and uninstall refuses to touch those.
- **Cluster-wide default behaviour is never altered.** (This is why the OpenShift console opens in a new
  tab instead of being embedded in the cockpit — embedding would require a global IngressController
  header rewrite, which changes behaviour for every workload on the cluster.)
- **Attendees are walled off** from the organisation's namespaces and from each other: each gets their
  own Argo `AppProject` listing only their own namespaces, and an admission policy pins them to it.
- **Full removal reverses what we created and leaves the rest**, and a read-only checker proves it.

The litmus test for any change: *would anything of the cluster owner's differ after a full removal?*

### Two design choices that look odd until you know why

- **Two Argo CD instances, not one** (~5 extra pods). The platform instance owns the machinery that
  builds every attendee's world; a second, namespace-scoped instance is where attendees create their own
  Applications during the GitOps modules. Split that way, an attendee mistake cannot delete the
  machinery.
- **Every attendee's starting state is an Argo Application**, not a script. `ws start` writes a small
  Application and lets Argo materialize it, so entry states are reproducible and `ws reset` is a
  delete-and-resync rather than a cleanup script guessing what changed.
