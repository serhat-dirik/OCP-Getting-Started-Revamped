# components/loki-logging — cluster log aggregation (Loki + OpenShift Logging)

> **STATUS: DELIBERATELY NOT WIRED. Nothing installs this, and that is a decision, not an oversight.**
> Do not wire it back in on the strength of "it looks finished" — it is finished, and it is still
> disabled on purpose. Read *Why it is not wired* before you touch `stacks/observability/kustomization.yaml`.

The full log-aggregation tier: the **Loki Operator** and **Red Hat OpenShift Logging** stand up a shared
**LokiStack** log store, a **Vector** `ClusterLogForwarder` ships application and infrastructure logs into
it, and the **COO Logging `UIPlugin`** surfaces them in the console's **Observe → Logs** view. Twelve
manifests, sync-waved to the portfolio convention, live-verified end to end on a real cluster.

It has never been installed by any workshop install, on any cluster, since the day it was written.

## How "not wired" is implemented, and why it is not simply missing

A stack Application for this component **does** exist — `stacks/observability/apps/loki-logging.yaml`,
`pp-loki-logging`, pointing `spec.source.path` at this directory. It is **commented out** of
`stacks/observability/kustomization.yaml`'s `resources:` list. That single comment is the whole mechanism:

`argocd-bootstrap/lib-components.sh` derives the render set by reading each stack kustomization's
`resources:` list (`kustomize_resources()` → `active_app_files()`), never by globbing `apps/*.yaml`. An app
file that is not in `resources:` is not rendered, so no child Application is created, so this overlay never
reaches a cluster. `tools/lint/crd-unknown-field-guard.py` and
`tools/lint/disabled-module-namespace-guard.py` derive their scopes the same way, and both name this
component as the standing example of why.

So this is **disabled inventory, not orphaned inventory**. The wiring is written, reviewed, and switched
off in one place. Turning it on is a one-line edit — which is exactly why the reasons below have to be
written down next to it rather than left in a commit message.

## Why it is not wired — two independent reasons, six weeks apart

**Reason 1 — the dependency and the capacity (2026-07-09, when this was written).** A LokiStack needs
S3-compatible object storage, and this component gets it from an ODF/NooBaa `ObjectBucketClaim`. The
portfolio's standing rule is that a stack installs cleanly on *any* OCP cluster; this one cannot, because
it requires ODF **and** a Secret a human has to assemble by hand (see *The `logging-loki-s3` Secret
contract*). It is also the heaviest observability add — a Vector DaemonSet is one pod per node, on top of
the LokiStack's own pods; `stacks/observability/README.md` measures the tracing tier at roughly 1–1.5 CPU /
2.5 Gi and the same tier *with* Loki at roughly 3 CPU / 7 Gi.

**Reason 2 — the content ruling (2026-08-22), which is the stronger one.** The `application-logging`
module was created six weeks after this component and rules, explicitly, that the workshop teaches **what
an application emits** — structured JSON, log levels, redaction, correlation across replicas — and treats
cluster log aggregation as **concept-level prose only**. That is not a gap waiting to be filled:

- `content/modules/ROOT/pages/application-logging/concept.adoc` names all three operators (`cluster-logging`,
  `loki-operator`, `cluster-observability-operator`), says none is installed, and gives the reason in the
  page's own words: a LokiStack is six to eight pods and needs object storage, a dependency not every
  cluster has and not one a workshop should manufacture — and standing one up would teach the platform
  team's build rather than the developer's.
- `content/modules/ROOT/pages/application-logging/instructor.adoc` makes the same call twice: the scope is
  "deliberately the *other half*", there is "no operator to install, no ClusterLogForwarder, no object
  storage", and the answer to the room's first question — *"Why aren't we setting up a log aggregation
  stack? That's what I came for."* — is that the tier is downstream of what the application emits, and a
  collector cannot name a field nobody wrote. The instructor guide tells the deliverer, in as many words,
  not to take that question into a terminal.
- `content/modules/ROOT/pages/observability-health-scale/wrapup.adoc` makes the matching deferral from the
  other side.

**The chronology matters.** This component predates the ruling. Its own inline comments and the stack
kustomization only know Reason 1, and describe the gate as "OPTIONAL / capacity-gated" — which reads as
*"turn it on when you have the capacity."* Since 2026-08-22 that reading is wrong. On a cluster with ODF
and capacity to spare, Reason 1 is satisfied and Reason 2 still is not: wiring this in would install
infrastructure that the workshop's own content states, on the page and in the instructor guide, is not
installed. That is a content defect, not a capacity decision, and it is not yours to make from a
kustomization file.

## Would it actually deploy if you uncommented it? No — not as-is

Answered explicitly because "unwired" and "ready" are different things, and the annotation quality here
makes it easy to assume the second.

| # | Blocker | Evidence | Bites on |
|---|---|---|---|
| 1 | **`logging-loki-s3` does not exist and nothing in this repo creates it.** `lokistack.yaml` sets `spec.storage.secret.name: logging-loki-s3`; that Secret is not in `kustomization.yaml`, and no Job, hook or script anywhere assembles it. Until a human runs the block below, the LokiStack does not reconcile. | grep the tree: outside this directory `logging-loki-s3` appears exactly once, as a prose reference in `stacks/observability/apps/loki-logging.yaml`'s header comment. Nothing creates it. | **Every** cluster, including the workshop's own. |
| 2 | **The `ObjectBucketClaim` is the one non-stock kind with no dry-run escape.** `objectbucket.io/v1alpha1` is delivered by ODF/NooBaa. The `LokiStack`, `ClusterLogForwarder` and `UIPlugin` all carry `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`; `objectbucketclaim.yaml` does **not** (`grep -L SkipDryRunOnMissingResource *.yaml`). Without ODF the Application fails on its first sync, at the OBC. | The three annotated files vs. the OBC. | Any cluster without ODF. |
| 3 | **The LokiStack pins one cluster's StorageClass by name.** `storageClassName: ocs-external-storagecluster-ceph-rbd` is the workshop build cluster's ODF **external-mode** default. Internal-mode ODF names the same thing `ocs-storagecluster-ceph-rbd`; any other backend names it something else. On a mismatch the Loki PVCs sit `Pending` and the LokiStack CR reports nothing useful. Dropping the field entirely would take the cluster default and be strictly more portable. | `content/modules/ROOT/pages/storage-stateful/lab.adoc` teaches attendees not to assume these exact names — this manifest assumes them. | Any cluster whose block class is named differently. |
| 4 | **`openshift-operators-redhat` may already carry an OperatorGroup.** OLM allows one per namespace; a second fails every CSV in it with `TooManyOperatorGroups`, while the pods keep running — so an operator the org owns breaks silently. | `argocd-bootstrap/install.sh` preflights this and refuses; see *The shared OperatorGroup caveat*. | Clusters already running Red Hat operators there. |

Blockers 1 and 2 are hard stops. Blocker 3 is a silent one. **None of this is a half-built component** —
every manifest is correct and was proven on a cluster (below); what is missing is the automation that
would make the proven thing install itself.

The contrast worth studying is `components/oadp`, which is **wired** (the `resilience` stack) and solves
the identical NooBaa-OBC-to-Secret problem: it ships `bsl-glue.yaml`, a sync-hook Job that reads the OBC's
ConfigMap and Secret and writes Velero's `cloud-credentials` automatically. This component was never given
that Job. That is the entire distance between "proven once, by hand" and "installs unattended."

## It is complete and it was proven — which is why deleting it would cost something

Verified live on **2026-07-11** (commit `3a61306`, loki-operator 6.5.1 + cluster-logging 6.5.1): the whole
tier was stood up, the LokiStack reconciled `Ready=True` against NooBaa S3, the Vector DaemonSet ran 6/6
(one per node), the Logging `UIPlugin` reconciled, logs were queryable across ten application namespaces —
and then it was torn down. Two real bugs came out of that run, both **silent** (no CR error, only a runtime
failure), and both are fixed in these manifests:

1. `ClusterLogForwarder.spec.outputs[].lokiStack.target` requires **both** `name` and `namespace`.
2. The collector ServiceAccount needs `logging-collector-logs-writer` (write to the LokiStack gateway) on
   top of the two `collect-*-logs` read roles — without it every push is dropped with HTTP 403 and nothing
   anywhere says so.

Neither was findable by reading documentation; both cost a live cluster run. That is the artifact this
directory is really holding.

## What's in here

| File | Why |
|---|---|
| `namespace-operators-redhat.yaml` | `openshift-operators-redhat` — Loki Operator install namespace (AllNamespaces) |
| `namespace-logging.yaml` | `openshift-logging` — Logging operator, LokiStack, collector and OBC live here |
| `operatorgroup-loki.yaml` / `operatorgroup-logging.yaml` | all-namespaces OperatorGroups, one per namespace |
| `subscription-loki.yaml` | `loki-operator` from `redhat-operators`. **No `spec.channel`** — OLM resolves the package's `defaultChannel` on the target cluster (unpinned in commit `60339a7`, 2026-07-25) |
| `subscription-logging.yaml` | `cluster-logging` from `redhat-operators`, `spec.channel` likewise unpinned |
| `objectbucketclaim.yaml` | requests a NooBaa S3 bucket (`storageClassName: openshift-storage.noobaa.io`), wave -1 |
| `lokistack.yaml` | `LokiStack` `logging-loki`, size `1x.demo`, schema v13, tenants `openshift-logging`, wave 2 |
| `collector-serviceaccount.yaml` + `collector-rbac.yaml` | the Vector collector SA and its three ClusterRoleBindings (two read, one write) |
| `clusterlogforwarder.yaml` | `ClusterLogForwarder` on `observability.openshift.io/v1` (the Logging 6.x API, **not** the retired `logging.openshift.io/v1`), app+infra → Loki, wave 2 |
| `uiplugin-logging.yaml` | COO Logging console plugin pointed at `logging-loki`, wave 2 |

**Version note.** The verification above was done against the 6.5 line, and `/versions.yaml` records
`loki` / `cluster_logging` at 6.5.1 as a **floor, not a cap**. Because both Subscriptions are unpinned, an
opt-in today resolves whatever `defaultChannel` currently serves — which was already `stable-6.6` when the
catalogue was read on 2026-08-22. Anyone wiring this in is installing a line these manifests were not
verified against, and should re-verify rather than trust the 2026-07-11 result.

## The `logging-loki-s3` Secret contract

Bucket keys are **never** in git. The `ObjectBucketClaim` provisions a bucket and emits its coordinates as
a ConfigMap and a Secret (both named `logging-loki-bucket`) in `openshift-logging`. The LokiStack expects a
**single** S3 Secret named `logging-loki-s3` assembled from them, and it must exist **before** the LokiStack
reconciles. (Same shape as the Lightspeed `credentials` contract.)

| Field | Value |
|---|---|
| Namespace | `openshift-logging` |
| Name | `logging-loki-s3` (referenced by `LokiStack.spec.storage.secret.name`) |
| Keys | `access_key_id`, `access_key_secret`, `bucketnames`, `endpoint` |

```bash
# Verified on install 2026-07-11: the NooBaa OBC emits ConfigMap keys BUCKET_NAME / BUCKET_HOST
# (s3.openshift-storage.svc) / BUCKET_PORT (443) and Secret keys AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY;
# the four assembled keys below reconcile the LokiStack to Ready against NooBaa S3.
# Values stay in shell variables and are never echoed — keep it that way.
OBC_CM=logging-loki-bucket; OBC_SECRET=logging-loki-bucket; NS=openshift-logging
BUCKET=$(oc get cm     "$OBC_CM"     -n "$NS" -o jsonpath='{.data.BUCKET_NAME}')
AKID=$(  oc get secret "$OBC_SECRET" -n "$NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}'     | base64 -d)
ASEC=$(  oc get secret "$OBC_SECRET" -n "$NS" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
oc create secret generic logging-loki-s3 -n "$NS" \
  --from-literal=access_key_id="$AKID" \
  --from-literal=access_key_secret="$ASEC" \
  --from-literal=bucketnames="$BUCKET" \
  --from-literal=endpoint="https://s3.openshift-storage.svc:443"
```

## The shared OperatorGroup caveat

Some clusters pre-create `openshift-operators-redhat` **with** an AllNamespaces OperatorGroup for other Red
Hat operators. OLM allows exactly one per namespace; a second triggers `TooManyOperatorGroups` and fails
every CSV in the namespace while the pods keep running. If the target cluster already has one, drop
`operatorgroup-loki.yaml` from `kustomization.yaml` and reuse theirs. `argocd-bootstrap/install.sh`
preflights both namespaces and refuses to install rather than break an operator the org owns.

## Known hazard while this sits here unwired

`bootstrap/install.sh`'s `snapshot_operators()` and `bootstrap/ogsr-uninstall.sh`'s
`enumerate_operators()` still **glob** `stacks/<stack>/apps/*.yaml` instead of using
`active_app_files()`. They therefore pick up `apps/loki-logging.yaml` even though it is commented out, and
— whenever the `observability` stack is selected and no such Subscription exists on the cluster yet —
record `op_loki-operator=created:openshift-operators-redhat` and `op_cluster-logging=created:openshift-logging`
in the install-state ConfigMap, for operators the workshop never installs. `lib-components.sh` documents
having measured exactly this on a live cluster on 2026-08-05, and instructs new consumers to use
`active_app_files()`; the two existing consumers were not converted.

Why it matters: `csv_delete_authorized_by_state()` is the *only* thing that authorises a CSV deletion at
teardown, and it authorises on precisely the string `created:<ns>`. `protected_csv_set()` does not save
these, because it excludes anything recorded `created:` by construction. So if an org installs Red Hat
OpenShift Logging on this cluster *after* a workshop install and *before* the teardown, the stale
`created:` record authorises `ogsr-uninstall.sh` to delete their `cluster-logging` / `loki-operator` CSV.
The namespaces themselves survive (that sweep is gated on the `workshop.redhat.com/owner` label, which
these namespaces never receive), so the operator goes and its namespace stays.

This is latent rather than active, and it is **not** a defect in this component — every file here is
correct. It is a defect in two globbing callers, and this component is its only live instance. It is
recorded here because it is the one real cost of leaving these files on disk, and because whoever fixes
those two functions will come looking for the case that motivated it. **Fix belongs in
`bootstrap/install.sh` and `bootstrap/ogsr-uninstall.sh`, not here.**

## What would have to be true to wire this in

All five, in order. The first is the one that cannot be bought with hardware:

1. **The content ruling changes.** `application-logging`'s concept and instructor pages state that none of
   this is installed. Installing it makes those pages wrong. This is an owner decision.
2. **The cluster has ODF/MCG** — StorageClass `openshift-storage.noobaa.io` and the
   `s3.openshift-storage.svc` endpoint — or `objectbucketclaim.yaml` is replaced with an external-S3 Secret
   of the same four keys.
3. **Something creates `logging-loki-s3` automatically**, or the operator accepts a documented manual step.
   Copy `components/oadp/bsl-glue.yaml` if you want it unattended; it solves this exact problem.
4. **`lokistack.yaml`'s `storageClassName` is corrected or removed** for the target cluster's block class.
5. **The tier is re-verified on the 6.6 line**, since both Subscriptions are unpinned and the 2026-07-11
   proof was against 6.5.1.

Then uncomment `apps/loki-logging.yaml` in `stacks/observability/kustomization.yaml` — and update
`stacks/observability/README.md` and `bootstrap/vars.example.yaml` in the same change, both of which
describe the current, disabled state.

## What to do instead, if you actually want log aggregation on a cluster

- **Teaching the workshop?** Do not install this. The answer lives in
  `content/modules/ROOT/pages/application-logging/concept.adoc` and in the instructor guide's first Top-5
  question, and it is a better answer than a demo: name `cluster-logging`, `loki-operator` and
  `cluster-observability-operator`, say what each owns, and say what the tier costs. The always-true
  baseline the workshop *does* teach — `oc logs` and the console's **Pod → Logs** — is unaffected by any of
  this, so nothing structural is lost.
- **Running a PoC or customer cluster off `platform-portfolio/` and genuinely need aggregation?** Install
  it as its own thing, out of band, from these manifests: satisfy points 2–5 above, `oc apply -k` this
  directory (or add the app file to a **private** stack overlay), assemble the Secret, and verify below.
  Do not turn it on inside the workshop's `observability` stack, because that stack is what workshop
  clusters install and the content says this is absent.
- **Just need to look at logs across a few replicas right now?** `oc logs -l app=<name> --all-containers
  --prefix --tail=-1` covers the live case without a log store, and is what the `application-logging` lab
  actually teaches.

## Recommendation on file (2026-08-23)

**Keep and document — do not delete.** Deleting would discard a live-verified artifact carrying two bug
fixes that only a real cluster run could find; it would break the documented standing example that
`tools/lint/crd-unknown-field-guard.py`, `tools/lint/disabled-module-namespace-guard.py` and
`argocd-bootstrap/lib-components.sh` each cite by name for why the render set is derived from `resources:`
rather than globbed (`crd-unknown-field-guard`'s canary fixture is *built* to mirror this directory, and
its README says so); and it would remove the concrete backing for the instructor guide's strongest answer,
which is "we can, here it is, and here is what it costs" rather than "we didn't."

## Verify (only if you have wired it in)

```bash
oc get lokistack logging-loki -n openshift-logging          # Ready, once logging-loki-s3 and the operator are up
oc get clusterlogforwarder instance -n openshift-logging    # condition Ready; Vector pods, one per node
oc get pods -n openshift-logging                            # LokiStack + collector pods Running
oc get uiplugin logging                                     # COO Logging console plugin
```

---

*A note on module references.* This file names modules by **slug** only, never by number. Module numbers
are positions in `/modules.yaml` and move whenever the catalogue is re-ordered. The comments in
`kustomization.yaml` and in `stacks/observability/apps/loki-logging.yaml` still carry a stale "T3" module
token from the thirteenth slot — which today holds a GitOps module and has nothing to do with logging.
(Written in words rather than as a token, following the convention
`tools/lint/module-number-drift-guard.py` sets in its own header: that guard cannot tell a number being
quoted from one being used, and a bare number with no slug beside it is outside what it checks by design.
So a stale one will not be caught for you.) Write slugs.
