# Capture runbook — the order, and why it is that order

`README.md` explains how the harness works. This file is what to actually do, in sequence, on the
day. Follow it top to bottom; nothing here is a judgement call to be made under time pressure.

**The scarce resource is a human completing one OAuth login.** Everything in Phase 0 exists to keep
cluster time, build time and mistakes out of that window.

> **Read `CAPTURE-PLAN.md` first, once.** It is the verified pre-flight: what the login actually
> buys (8 files change — 5 new, 3 replacements), the job-by-job state/staging table, and the list
> of things that would waste or damage the run. Two of them matter *before* you start: the `mNN`
> module numbers used throughout this directory are wrong (type **slugs**, never `m08`/`m12`/`m13`),
> and two of the eight job files exit non-zero in Phase 0.1 **by design**.

---

## The five rules the job files now enforce for you

**1. The clobber guard.** `capture.py` refuses to overwrite a screenshot that already exists unless
that job carries `reshoot: true`. These shots are state-dependent, so re-running a jobs file does
not reproduce the same picture — it produces whatever the lab looks like *now*, which is a valid
PNG of the wrong moment and looks fine in review. It cost the M10 drift diff on 2026-07-26. Of the
26 jobs in this directory, 18 point at files that are already on disk; before the guard, a single
wholesale run would have replaced all eighteen. Set `reshoot: true` only where the module's
`media-manifest.md` says ❌ RE-CAPTURE, and say so in a comment beside the flag.

**2. Waits assert the VIEW and the STATE, not a landmark.** `wait_all_text` takes a list and every
string must be present. A single landmark that a list page and its detail pages both carry passes
on the wrong screen — that is how eleven committed screenshots went wrong. Name the object *and*
the state: `["ParasolClaimsErrorRateHigh", "Firing"]` cannot be satisfied by the same rule sitting
Pending, while the rule name alone can.

**3. `forbid_text` catches pages that render their own error.** A positive wait cannot see
"Access restricted" — it arrives *beside* the heading the wait matched. That is exactly how a
screenshot of a 403'd query browser got committed as `observability-health-scale-01`.

**4. `require_in_frame` is the only assertion that sees the PICTURE.** Every wait above tests
`document.body.innerText`, and innerText contains text that is scrolled far out of view — so all of
them pass happily on a perfect page whose subject is below the fold. That is not hypothetical:
`trusted-supply-chain-03` landed on exactly the right ImageStream detail page, satisfied a wait on
`.sig` (a string only the Tags rows ever render), and shot a frame in which the Tags table sat at
y=1047..1281 of a 1000px viewport. Nothing in the harness noticed; a human opening the PNG did.
`require_in_frame` measures each string's bounding box against the frame and fails the job. **Name
the thing the caption promises**, not the heading above it, and fix a failure by raising
`viewport.height` or setting `scroll_to_text` — never by deleting the assertion.

**5. Editable forms need `wait_all_field_values`, not `wait_all_text`.** Some console views are
forms: the Deployment → Environment tab renders every variable name and value inside an
`<input value="…">`, and input values are **not** part of innerText. `wait_all_text` there is
unsatisfiable no matter how correct the cluster is — it timed out on 2026-07-29 against a Deployment
whose `oc set env --list` showed all five variables and whose page was displaying every one of them.
If a wait fails on a view full of boxes-with-text-in-them, suspect the assertion before the state.

Run `--plan` on any jobs file to see all five applied, with no browser and no cluster:

```bash
tools/media/.venv/bin/python tools/media/capture.py \
  --jobs tools/media/jobs-console-sweep.yaml --domain apps.example.com --plan
```

---

## Phase 0 — before anyone is asked to log in

No browser. Unattended. Budget 30–45 minutes of cluster time.

```bash
export KUBECONFIG=~/.kube/<cluster>.config
export OGSR_DOMAIN=apps.<cluster>.<base-domain>
cd <repo root>
```

**0.1 — Plan every file.** Any load error, any unexpected `RUN` on a file already on disk, stop and
fix it here.

```bash
for f in tools/media/jobs-*.yaml; do
  tools/media/.venv/bin/python tools/media/capture.py --jobs "$f" --domain "$OGSR_DOMAIN" --plan
done
```

**0.2 — Entry-state freshness.** Several charts were bumped in the last 24h. A namespace still
carrying the previous render will not match the lab, and Argo does not always re-sync a chart whose
version moved without other drift. For any module in the sweep whose chart moved, reset rather than
start:

| chart | version | in this run? |
|---|---|---|
| `agentic-ai` | 0.1.5 | no |
| `ai-assisted-development` | 0.1.5 | no |
| `app-modernization` | 0.1.5 | no |
| `deployment-targets-scheduling` | 0.1.2 | no |
| `workshop-config` | 0.1.27 | **yes, indirectly** — it owns the shared task library and per-user quotas that every pipeline shot depends on |

None of the *bumped* module charts is shot in this pass, so no per-module reset is forced. But
because `workshop-config` moved, confirm the shared task library re-rendered before relying on any
pipeline run:

```bash
oc get task -n ogsr-parasol-tasks
oc get application -n openshift-gitops workshop-config -o jsonpath='{.status.sync.status}{"\n"}'
```

If it is not `Synced`, follow the sync discipline in CLAUDE.md (mirror-sync → hard refresh → ~10s →
sync) *now*, not during the window.

**0.3 — M08 state must exist, because Phase 3 destroys it.** `{user}-cicd` is shared by
`pipelines-fundamentals`, `trusted-supply-chain` and `app-security-testing`, and all three declare
each other in `conflictsWith`: starting any one evicts the others and purges the namespace.

```bash
oc get istag -n user1-cicd | grep '\.sig'      # signed tag present?
# only if empty — it re-runs the warm build, 6-12 min:
./tools/ws/ws start trusted-supply-chain --user user1
```

**0.4 — Build the failed scan run.** 6–12 minutes, no browser needed, so it must not happen inside
the window.

```bash
./tools/media/stage-m08-scan.sh user1
```

It exits non-zero if the gate *passed* — that would mean there is nothing to photograph, and the
RHACS policy needs looking at before the window opens.

**0.5 — Warm the profile for the non-console tools, only if you are recapturing them.** On this
cluster every Argo/Gitea/RHDH shot is already on disk and will print `KEEP`, so the console login
alone is enough. On a fresh cluster, note that a console session does **not** carry to Argo CD: log
in through that tool as the attendee via `workshop-users`, separately. Gitea has its own local
login again.

---

## Phase 1 — the window opens: the console sweep

One `--login`. Everything after this reuses the cached session.

```bash
cd tools/media
KUBECONFIG=~/.kube/<cluster>.config OGSR_DOMAIN=apps.<cluster>.<base> \
  .venv/bin/python capture.py --jobs jobs-console-sweep.yaml \
    --profile ~/.ogsr-shot-profile \
    --login https://console-openshift-console.$OGSR_DOMAIN
```

Expect ~35–50 minutes. The order inside the file is load-bearing twice over:

| # | shot | state it needs | why it must be here |
|---|---|---|---|
| 1 | `observability-01-observe-metrics` | healthy baseline, load generator running | after `ws start` + the rule fixture; the 90s wait also lets the ruler load the rule for shot 05 |
| 2 | `observability-05-alerting-inactive` | rule armed, **nothing firing** | it is literally the "before" of shot 4 |
| — | `observability-02-observe-traces` | — | **PARKED**, see below |
| 3 | `observability-04-alert-firing` | database down, 5xx banked | destroys the baseline shot 2 needs — must come after it |
| — | `observability-03-topology-hpa-scale` | — | **PARKED** on a capacity-bound cluster, see below |
| 4 | `trusted-supply-chain-03-imagestream-tags` | `{user}-cicd` from Phase 0 | read-only; no staging |
| 5 | `securing-apps-keycloak-05-claims-env` | M13 entry + exercise 2's `oc set env` | **LAST** — `ws start securing-apps-keycloak` purges `{user}-dev` and evicts M12 |

**Nothing above the last row can be re-run after it without redoing `ws start observability-health-scale`.**

If a single shot fails, retry just that one — `--only` matches a filename fragment:

```bash
.venv/bin/python capture.py --jobs jobs-console-sweep.yaml --profile ~/.ogsr-shot-profile \
  --only 04-alert-firing
```

...but read the failure first, and sort it into one of two piles.

**The state was not reached** — `never saw 'Firing'`, `pre_sh rc=1`. Re-running the same job fails
the same way; re-stage instead (`./tools/media/stage-m12-alert.sh user1`).

**The capture was wrong, the state was fine** — `not in frame: …`, or a wait that names something
the page is visibly showing (see rule 5). Here re-running `pre_sh` is actively harmful: most of
these begin with `ws start`, which purges the namespace and rebuilds it, so a retry can destroy a
good state and — on a loaded cluster — fail to bring it back. Fix the job, verify the state by hand,
and shoot what is already there:

```bash
oc set env deploy/parasol-claims -n user1-dev --list     # prove the state yourself first
.venv/bin/python capture.py --jobs jobs-console-sweep.yaml --profile ~/.ogsr-shot-profile \
  --only 05-claims-env --no-pre
```

`--no-pre` skips every `pre_sh` and its `pre_wait_s`; `url_sh` still runs, because it resolves the
target rather than creating it. Both of the 2026-07-29 recoveries went this way.

**Cluster hygiene after Phase 1.** The HPA staging leaves a load pod running:

```bash
oc delete pod claims-burst -n user1-dev --ignore-not-found
```

---

## Phase 2 — the M08 scan gate (same session, no new login)

```bash
.venv/bin/python capture.py --jobs jobs-trusted-supply-chain.yaml --profile ~/.ogsr-shot-profile
```

Fast: the run was built in Phase 0. `url_sh` resolves the newest FAILED PipelineRun, so if Phase 0.4
was skipped this exits loudly instead of shooting the green warm run.

> **Currently PARKED** (2026-07-29) — and the way it failed is the argument for Phase 3 coming last.
> Phase 3 had already run, so `{user}-cicd` belonged to `pipelines-fundamentals`;
> `trusted-supply-chain` had been evicted and the namespace purged. `url_sh` did precisely what it
> promises — resolved the newest **failed** run in that namespace — and got an M07
> `solve-parasol-claims-…`, whose tasks are fetch-source / unit-test / build-image / image-report /
> deploy. The wait on `acs-scan` refused it. A run existing is not the same as the right run
> existing, and `url_sh` cannot tell the difference; the task-name wait is what does. Reason and
> un-park instructions are in the job file.

---

## Phase 3 — M07 pipelines. **This destroys `{user}-cicd`; run nothing from Phase 1–2 afterwards.**

```bash
.venv/bin/python capture.py --jobs jobs-pipelines-fundamentals.yaml --profile ~/.ogsr-shot-profile
```

`ws start` then `ws solve` runs the real build-test-deploy pipeline and blocks ~9 minutes (longer
cold; `waitSeconds` is 1200 and `pre_sh` is allowed 1800s). Only shot 01 runs — the other three
console shots are already on disk and print `KEEP`, and two are parked.

---

## Phase 4 — the free ones (any time, any order)

```bash
.venv/bin/python capture.py --jobs jobs-tools-landing.yaml --profile ~/.ogsr-shot-profile
.venv/bin/python capture.py --jobs jobs-gitops-fundamentals.yaml --profile ~/.ogsr-shot-profile
```

On this cluster both are no-ops (everything `KEEP`s). They are the recipe for a fresh cluster, where
`jobs-tools-landing.yaml` is the cheapest four shots in the whole pass.

---

## Afterwards

1. **Look at every PNG.** The size heuristic (<20 KB) catches a splash screen, not a wrong page.
   Check for a visible token or password before anything is committed — CI's privacy guard runs
   `git grep` and cannot read an image. Ephemeral RHDP cluster domains inside screenshots are fine
   (owner decision, 2026-07-26); credentials never are.
2. **Update the module's `media-manifest.md` row** from `⬜ NOT CAPTURED` / `❌ RE-CAPTURE` to
   captured.
3. **Replace the `// media-pass: …` comment** in the `.adoc` with the real `image::` macro plus alt
   text. A captured file that nothing embeds is not done.
4. **Commit state-dependent shots immediately** — do not batch them behind another run.

---

## What is NOT capturable, and why — coordinator decisions, not chores

These are parked in their job files with the same reasoning. None is a workaround away.

| shot | blocker |
|---|---|
| `observability-03-topology-hpa-scale` | **Cluster capacity, measured 2026-07-29.** The shot needs `parasol-claims` at four ready replicas plus the `claims-burst` load pod. A replica requests 200m/256Mi; cluster-wide headroom for that pod was **two** — the one untainted worker had 9Mi of free memory, the control planes 100–300m of free CPU, and the third worker is reserved for the batch pool by `workshop.redhat.com/pool=batch:NoSchedule`. `stage-m12-hpa.sh` refused the shot rather than photograph a ring that never grew, which is the behaviour you want. Do **not** lower its `CEILING` to fit — `lab.adoc:561` promises 2→4, and an asset that contradicts its own prose is worse than a gap. Un-parks by itself on a cluster with room. |
| `trusted-supply-chain-02-pipelinerun-scan-failed` | `{user}-cicd` was taken over by `pipelines-fundamentals` (Phase 3 ran early), so the supply-chain Pipeline does not exist and `stage-m08-scan.sh` exits on its own pre-flight. Recovering it means purging a namespace with another lane's `ws solve` still running three PipelineRuns in it, then two 6–12 minute builds on a cluster that could not schedule the ones already queued. Coordinator decision. |
| `observability-02-observe-traces` | The Traces page needs four interactions — Tempo instance dropdown, service, TraceQL query, open a trace — with no grounded deep-link. A URL-only job can only reach the "No Tempo instance selected" landing state, which is exactly the asset pulled on 2026-07-28. Needs a human, or somebody grounds the query-parameter format. |
| `gitops-fundamentals-07-gitea-edit-overlay` | Wants an **uncommitted** edit (`count: 2` → `count: 3`) with the Commit Changes panel. The entry state re-asserts the fork's canonical content on every start/reset, so a clean cluster shows `count: 2`. Fixing it means typing in the editor, or pushing exercise 4's commit with the attendee's Gitea credentials. |
| `gitops-fundamentals-02-new-app-form` | The `+ NEW APP` panel is a modal with no route, and the shot must show it **filled**. |
| `pipelines-fundamentals-02-gitea-webhook` | Gitea's Add Webhook form, filled. Same shape; Gitea also has its own local login the console session does not carry. |
| `pipelines-fundamentals-03-pipelinerun-failed` | Needs a run that failed because a human broke a unit test in their fork. `ws solve` only ever produces a green run. (The asset on disk is good — leave it.) |
| `build-deliver-03-buildconfig-to-imagestream` | Wants a completed Build + S2I ImageStream tag. The entry state is an empty dev namespace by design and `solve` deploys a **prebuilt** image — no BuildConfig exists on any materialisable state. It has no `// media-pass:` embed point either. |
| `trusted-supply-chain-01-acs-violation` | RHACS is a separate product with its own login. |
| `trusted-supply-chain-04-rekor-entry` | Rekor Search UI on a separate host; needs a real SBOM hash to search by (see `jobs-rekor.yaml`). |
| `developer-hub-golden-paths-04/05/06` | Require actually running the scaffolder, which creates a repository. |
| `gitops-at-scale-04/05-canary-*` | Transient rollout states that must be caught mid-flight. |
| `devspaces-inner-loop-02/03` | Need a running DevWorkspace and an IDE. |

---

## `[CAPTURE-VERIFY]` markers — 83 open, and what resolves them

A marker is **not** a screenshot request. Every one of them asks the same question: *is this console
click-path still real?* Most already carry "CLI authoritative" beside them, so the CLI lane is
correct either way and only the Console tab's wording is at risk.

`CONSOLE-GROUNDING.md` is the artefact that closes them — a record of what was seen in an
authenticated console, in a tracked path, so a later contributor can tell observation from
assumption. Extend it during the same session as the capture run; do not open a second browser
window on another day.

**Resolved as a side effect of a queued job** (the shot itself shows the labels — 13 markers):

| marker | job that grounds it |
|---|---|
| `observability-health-scale/lab.adoc:93` Observe → Metrics | sweep shot 1 |
| `observability-health-scale/lab.adoc:561` Topology pod ring 2→4 | sweep shot 4 |
| `securing-apps-keycloak/lab.adoc:160` Environment tab rows | sweep shot 6 |
| `trusted-supply-chain/lab.adoc:524` ImageStream Tags: `.sig` / `.att` | sweep shot 5 |
| `trusted-supply-chain/lab.adoc:255` PipelineRun graph, build green / acs-scan red | Phase 2 |
| `trusted-supply-chain/lab.adoc:201` supply-chain Pipeline Details, 4 Tasks | Phase 2 (adjacent page) |
| `pipelines-fundamentals/lab.adoc:838` PipelineRuns list | Phase 3 |
| `registry-images-catalog-governance/lab.adoc:196` ImageStream tag + sha256 | Phase 3 neighbours it in `{user}-cicd`; the module's own row needs `{user}-dev` |
| `observability-health-scale/lab.adoc:308` claims-db pod count → 0 | staged by `stage-m12-alert.sh`, visible in the run |
| `gitops-at-scale/lab.adoc:488`, `:525` Search → Rollout | no plugin on this cluster; the markers already say the CLI is authoritative |
| `eventing-deep-dive/instructor.adoc:142`, `resilience-multicluster-dr/instructor.adoc:145` | prose framing, not click-paths — close by editing the sentence |

**Already answered by `CONSOLE-GROUNDING.md` and closable by editing the page — do this first, it
costs nothing** (9 markers):

- `config-multienv/lab.adoc:310` — ConfigMaps has a plain **Create ConfigMap** button, *not* a
  dropdown (Secrets has the dropdown). Grounded. The form-vs-YAML toggle is still unchecked.
- `observability-health-scale/lab.adoc:194`, `securing-apps-keycloak/lab.adoc:586`,
  `storage-stateful/lab.adoc:576`, `jobs-batch-kueue/lab.adoc:216`, `:447`, `:533`,
  `multi-tenancy-workload-security/lab.adoc:464`, `resilience-multicluster-dr/lab.adoc:230`,
  `service-mesh-advanced-gateways/lab.adoc:311`, `:491`, `:539`, `:836` — all say "the masthead +
  (Quick create) → Import YAML". Grounded: the **+** button opens exactly *Import YAML · Import from
  Git · Container images*. Close them.
- `build-deliver/concept.adoc:65`, `registry-images-catalog-governance/lab.adoc:665`, `:666` —
  **Ecosystem → Software Catalog**; there is no "Developer Catalog" entry and no perspective
  switcher. The top-level path is grounded; only the *Type* filter inside it is not.

**No job, no coverage — will never resolve on its own** (the rest, ~55). Grouped by what it would
take:

| group | markers | what it needs |
|---|---|---|
| Modal/dialog forms (`Actions → …`, Create forms, Start forms) | `deployment-targets-scheduling:925`, `multi-tenancy:153/232/363`, `networking:267/450`, `registry:283/347/490`, `storage:205/456/834`, `packaging:412/540/834`, `observability:515`, `app-security-testing:133`, `service-mesh:207/684`, `gitops-at-scale:663`, `config-multienv:677` | A human opening the menu. Not URL-addressable. A **grounding pass** is the cheap answer: one authenticated browsing session, notes into `CONSOLE-GROUNDING.md`, no screenshots committed. Use `--out-root ~/ogsr-grounding` if you want reference images kept out of the tree. |
| List-page column labels | `deployment-targets-scheduling:168/176` (the Pods list has **no Node column** by default — the step now adds it, but the control's label is still ungrounded) | Same grounding pass. |
| Separate products | `app-modernization:149/245` (MTA), `app-security-testing:210` (SonarQube), `:329` (RHACS), `service-mesh:456` (Kiali), `resilience:434/547` (RHSI Service Interconnect plugin), `devspaces-inner-loop:665` | Each has its own login and its own UI version. Out of this harness's scope; needs whoever owns that product's demo. |
| Runtime variance, not labels | `serverless-zero-to-hero:371/482/541`, `app-modernization:303`, `agentic-ai:150/292/405/449`, `ai-assisted-development:144/471` | These say "re-capture on a full sequential run" — they are asking for a *lab walkthrough*, not a console check. |
| Cluster-admin surfaces an attendee cannot reach | `registry:91` and `registry/instructor:114` (the apiserver denial string for `allowedRegistriesForImport`), `packaging:834` (Subscription tab in `openshift-operators`) | A disposable cluster and cluster-admin. The registry ones were deliberately **not** applied on the shared build cluster — they are singletons affecting every tenant. |
| Header/prose mentions, not click-paths | `deployment-targets-scheduling:17`, `multi-tenancy:13`, `ai-assisted-development:14`, `app-security-testing:14`, `gitops-at-scale:29`, `registry/instructor:222` | Editorial. Close by rewording. |

**Recommendation for the coordinator.** The modal-form group is the largest and the cheapest per
marker: one grounding pass in the same authenticated window, walking ~20 `Actions` menus and Create
forms and writing what is actually there into `CONSOLE-GROUNDING.md`, closes roughly a third of the
open markers without adding a single asset to the tree. It is worth 30 minutes appended to Phase 4
while the session is still valid.
