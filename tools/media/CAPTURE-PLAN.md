# Capture plan — verified job-by-job, before the login is spent

`RUNBOOK.md` is the sequence to follow on the day. **This file is the pre-flight**: what the one
console login actually buys, job by job, verified against the code and the disk rather than
against anyone's memory of the job files.

Everything below was produced by reading `capture.py`, loading all eight `jobs-*.yaml` through
`capture.py`'s own loader, and stat-ing every target path. Verified 2026-07-29.

---

## Outcome of the 2026-07-29 run — read this before trusting the forecast below

The forecast said **8 PNGs change**. Six did. The rest is worth knowing, because none of the three
failures was a bad prediction about *state* — two were bad assertions and one was the cluster.

| shot | outcome |
|---|---|
| `observability-01-observe-metrics` · `-04-alert-firing` · `-05-alerting-inactive` | captured, committed `df7acda` |
| `trusted-supply-chain-03-imagestream-tags` | captured, then **re-shot**: the first frame was the right page with the Tags table below the fold. `require_in_frame` exists because of it. |
| `securing-apps-keycloak-05-claims-env` | captured on the retry. The first failure was an **unsatisfiable assertion**, not a state problem — see rule 5 in `RUNBOOK.md`. The cluster had been correct the whole time. |
| `observability-03-topology-hpa-scale` | **PARKED** — the cluster cannot schedule four replicas. Numbers in the job file. |
| `trusted-supply-chain-02-pipelinerun-scan-failed` | **PARKED** — Phase 3 ran early and took `{user}-cicd` with it. |
| `pipelines-fundamentals-01-pipelinerun-graph` | not attempted here; its `ws solve` was still running when this was written |

Two lessons that outlive this cluster, both now enforced in code rather than prose: **a wait that
passes tells you nothing about what is in the frame**, and **a wait can be impossible to satisfy on
a page that is displaying exactly what you asked for**. Between them they cost the first two shots
above, and one of them had already been committed before a human noticed.

---

## What your one login buys

**8 PNGs change. 5 are shots that do not exist at all; 3 replace assets the manifests mark
❌ RE-CAPTURE.** Everything else in the eight job files is already a no-op.

| | count | detail |
|---|---|---|
| **NEW** — nothing on disk today | **5** | alerting-inactive · alert-firing · imagestream-tags · claims-env · scan-failed |
| **REPLACE** — known-bad asset, `reshoot: true` | **3** | observe-metrics · topology-hpa-scale · pipelinerun-graph |
| KEEP — on disk, guard refuses to touch | 14 | no cluster state needed, no time spent |
| PARKED — never executed, reason in the job | 4 | not fixable by this harness |
| **total jobs across 8 files** | **26** | |

Distinct output files affected: **8**. Two job entries in `jobs-m12-alerts.yaml` are duplicates of
console-sweep outputs (see *Overlapping outputs*, below), which is why 26 jobs yield 8 files.

**Beyond screenshots, the same session also buys** the modal/dialog grounding pass described at the
end of `RUNBOOK.md` — roughly a third of the 83 open `[CAPTURE-VERIFY]` markers, closed by writing
what is actually on screen into `CONSOLE-GROUNDING.md`, with no new assets committed. That is the
cheapest value in the window and it needs no cluster state at all.

**Is the run worth it?** The three replacements are all currently *un-embedded* — the content
already carries `// media-pass:` notes saying "do not embed the asset on disk, it is wrong". So the
run converts three broken placeholders and five gaps into eight real images across four modules
(m13 observability, m14 keycloak, m09 supply-chain, m07 pipelines). If the window is short, Phase 1
alone delivers 6 of the 8.

---

## Correction to the brief

Two things in the task brief were wrong, and one was right:

- ✅ **The clobber guard is default-deny.** `Job.reshoot` defaults to `False`, and *both*
  `print_plan()` and the run loop skip when `out_path.exists() and not job.reshoot`. Jobs do not
  carry `reshoot: false`; they carry nothing, and nothing means refuse. That is the stronger design
  and it is what is implemented (`capture.py:131`, `:474`, `:598`).
- ❌ **Parked count is 4, not 5.** `observability-02-observe-traces`,
  `gitops-fundamentals-07-gitea-edit-overlay`, `pipelines-fundamentals-02-gitea-webhook`,
  `pipelines-fundamentals-03-pipelinerun-failed`. `gitops-fundamentals-02-new-app-form` is
  documented as unreachable in a trailing comment but is **not a job entry**, which is probably
  where a fifth came from.
- ❌ **`~/.ogsr-shot-profile.session.json` does not exist.** There is no cached token to protect
  right now. The profile dir `~/.ogsr-shot-profile` exists (0700) but holds no session, so the
  `--login` really is cold — nobody can skip it.

Job total (26) and `reshoot: true` count (3) were both correct.

---

## Phase 1 — `jobs-console-sweep.yaml`, inside the login window

Order is the file order. It is load-bearing twice: `ws start` evicts conflicting modules and purges
the namespace, and inside m13 the state moves one way only.

| # | output | verdict | state required | staged by | extra login |
|---|---|---|---|---|---|
| 1 | `observability-health-scale-01-observe-metrics.png` | **REPLACE** (75 KB error page) | m13 entry state + PrometheusRule fixture, load generator running | inline `pre_sh`: `ws start observability-health-scale` + `oc apply fixtures/m12-prometheusrule.yaml`, `+90s` | none |
| 2 | `observability-health-scale-05-observe-alerting-inactive.png` | **NEW** | rule armed, **nothing firing** — inherits job 1's world | none (depends on job 1) | none |
| — | `observability-health-scale-02-observe-traces.png` | PARKED | — | — | — |
| 3 | `observability-health-scale-04-alert-firing.png` | **NEW** | claims-db at 0 **and** ≥30 banked 5xx | `stage-m12-alert.sh user1`, `+90s` | none |
| 4 | `observability-health-scale-03-topology-hpa-scale.png` | **REPLACE** (64 KB calm 3-node) | db restored, pool recycled, HPA at ceiling **under live load** | `stage-m12-hpa.sh user1`, `+20s` | none |
| 5 | `trusted-supply-chain-03-imagestream-tags.png` | **NEW** | signed `.sig` tag in `{user}-cicd` from Phase 0.3 | inline `pre_sh` **guard only** — checks, never builds | none |
| 6 | `securing-apps-keycloak-05-claims-env.png` | **NEW** | m14 entry + exercise 2's `oc set env` | `ws start securing-apps-keycloak` + `stage-m13-oidc.sh user1`, `+15s` | none |

**Row 6 is a one-way door.** `ws start securing-apps-keycloak` purges `{user}-dev` and evicts
observability-health-scale. Nothing in rows 1–4 can be re-run afterwards without redoing the whole
m13 start.

**Order validated — no violation found.** Checked against `gitops/entry-states/*/ws-meta.yaml`:

- `observability-health-scale` ↔ `securing-apps-keycloak` declare each other, both own
  `${USER}-dev`. m14 last is correct and necessary.
- `trusted-supply-chain` ↔ `pipelines-fundamentals` ↔ `app-security-testing` declare each other,
  all own `${USER}-cicd`.
- **`securing-apps-keycloak` does *not* conflict with `trusted-supply-chain`** (disjoint
  namespaces). This is the one that could have silently broken the plan: row 6 does **not** destroy
  the `{user}-cicd` state that row 5 and Phase 2 depend on. Verified, not assumed.
- Within m13, 05 (inactive) genuinely precedes 04 (firing), and 03 (restored + autoscaled) follows
  both. The declared order satisfies the one-way constraint.

---

## Phase 2 — `jobs-trusted-supply-chain.yaml`, same session

| output | verdict | state required | staged by | extra login |
|---|---|---|---|---|
| `trusted-supply-chain-02-pipelinerun-scan-failed.png` | **NEW** | a **failed** PipelineRun in `{user}-cicd` | `stage-m08-scan.sh user1` — **in Phase 0**, 6–12 min | none |

`url_sh` resolves the newest run whose `Succeeded` condition is `False`. If Phase 0.4 was skipped
the shell yields nothing and the job fails loudly instead of photographing the green warm run.

---

## Phase 3 — `jobs-pipelines-fundamentals.yaml`. **Destroys `{user}-cicd`. Run last.**

| output | verdict | state required | staged by | extra login |
|---|---|---|---|---|
| `pipelines-fundamentals-01-pipelinerun-graph.png` | **REPLACE** (103 KB, no task graph) | a green 5-Task run | inline `ws start` + `ws solve` — **blocks ~9 min** | none |
| `pipelines-fundamentals-04/05/06` | KEEP | — | — | — |
| `pipelines-fundamentals-02-gitea-webhook` | PARKED | — | — | *(would need Gitea)* |
| `pipelines-fundamentals-03-pipelinerun-failed` | PARKED | — | — | — |

Running anything here evicts `trusted-supply-chain` and purges the namespace, taking the signed
ImageStream that Phase 1 row 5 and Phase 2 both photograph. Nothing from Phase 1–2 may follow it.

---

## Phase 4 — the free ones. **Zero work on a cluster that already has them.**

| file | jobs | verdict |
|---|---|---|
| `jobs-tools-landing.yaml` | 4 | all **KEEP** — no-op |
| `jobs-gitops-fundamentals.yaml` | 6 | 5 **KEEP**, 1 **PARKED** — no-op |

Both stay as the recipe for a fresh cluster. On a fresh cluster `jobs-gitops-fundamentals.yaml`
needs an **Argo CD login** (student instance, via `workshop-users`) which the console session does
**not** carry, and its five apps only exist after a human walks the lab — `ws solve` produces 04
and 06 but never 03 or 05.

**Gitea login: not required for this run.** The only Gitea-dependent jobs
(`gitops-fundamentals-07`, `pipelines-fundamentals-02`) are both parked and cannot execute. This
refines task #87: m10 shot 07 *would* need a Gitea login, but it is parked, so the console login is
the only credential the run consumes.

---

## Not in any phase — `jobs-m12-alerts.yaml`

A **repair tool**, deliberately outside the sequence: it re-shoots only the before/after alert pair
without re-materialising four other modules (~40 min saved).

⚠️ **It writes the same two filenames as `jobs-console-sweep.yaml`.** That is the exact shape that
got `jobs-observability-health-scale.yaml` emptied — two files claiming one output. It is safe
*only* because neither entry sets `reshoot: true`, so after Phase 1 creates those files this whole
file becomes a no-op. Do not add `reshoot: true` to it without re-reading this paragraph.

---

## Empty by design — expect two "failures" in Phase 0.1

`jobs-observability-health-scale.yaml` and `jobs-rekor.yaml` are `jobs: []`. `capture.py` exits **1**
with `no jobs matched`. The `for` loop in RUNBOOK Phase 0.1 will therefore print two failures, and
Phase 0.1 tells you to stop on any load error.

**Do not stop. Both are intentional**, each with a full explanation in its own header. Expect
exactly these two and no others.

---

## What would have wasted or damaged this run

Blunt list. Ordered by what it would have cost.

### 1. `ws start m08` would destroy Phase 0's 6–12 minute build — the numbers in this directory are wrong

The media tooling's module numbers do not match `modules.yaml`, which is the SSOT (a module's
number is its **position** in that file):

| this directory says | actually is | m*NN* is really |
|---|---|---|
| "M08" trusted-supply-chain | **m09** | m08 = `app-security-testing` |
| "M12" observability-health-scale | **m13** | m12 = `developer-hub-golden-paths` |
| "M13" securing-apps-keycloak | **m14** | m13 = `observability-health-scale` |
| "M07" pipelines-fundamentals | m07 ✅ | — |
| "M10" gitops-fundamentals | m10 ✅ | — |

Affected names: `stage-m08-scan.sh`, `stage-m12-alert.sh`, `stage-m12-hpa.sh`,
`stage-m13-oidc.sh`, `jobs-m12-alerts.yaml`, `fixtures/m12-prometheusrule.yaml`, and the prose in
`RUNBOOK.md` and every job header.

**The automated path is safe** — every `pre_sh` uses the *slug*, never `mNN`, and slugs are correct
everywhere. The hazard is a human reading "M08 state must exist" and typing `./tools/ws/ws start
m08 --user user1`: that starts **app-security-testing**, which declares `trusted-supply-chain` in
`conflictsWith`, evicts it, and purges `{user}-cicd` — deleting both the signed ImageStream (Phase
1 row 5) and the failed scan run (Phase 2), each 6–12 minutes to rebuild. Same trap for "M13":
`ws start m13` starts observability-health-scale, not Keycloak, and both purge `{user}-dev`.

**Mitigation for the day: type slugs, never `mNN`, for anything in this pass.** Renaming the files
is a separate, non-urgent slice — do not do it during the window.

### 2. The reported blocker was a misdiagnosis; the real one is different and already satisfied

`ModuleNotFoundError: No module named 'playwright'` came from running **system `python3`**. The
venv has existed at `tools/media/.venv` since 2026-07-28 and has playwright 1.61.0. `RUNBOOK.md`
already invokes `.venv/bin/python` everywhere — the reproduction just did not.

The *real* latent blocker was one layer down and is worth knowing: playwright's own browser cache
holds `chromium-1148` while 1.61.0 wants `chromium_headless_shell-1228`, so
`p.chromium.launch()` **fails**. It does not matter, because `capture.py` and `login.py` both launch
`channel="chrome"` — the *system* Google Chrome (150.0.7871.187, present). Verified by launching it
and writing a real PNG.

**Consequence: `playwright install chromium` is not needed and should not be run.** But if anyone
ever drops `channel="chrome"`, or runs the pass on a machine without Google Chrome installed,
capture dies instantly at the first job. Both are true today; neither is guaranteed tomorrow.

### 3. Stale orphaned Chrome processes are still running from an old probe

`pgrep` shows headless Chrome still alive from a raw `--screenshot=showroom-probe.png` attempt
against a **decommissioned** cluster, holding `--user-data-dir=/tmp/ogsr-shot-profile`. They do
**not** lock the capture profile (`~/.ogsr-shot-profile` is a different directory), so they will not
break the run — but they are orphans burning a little CPU and they make `pgrep`-based triage during
the window ambiguous. Kill them before you start.

Related, and worth knowing before it bites: `--login` uses `launch_persistent_context`, and Chrome
holds a **ProcessSingleton lock** per profile dir. If a previous capture left a window open on
`~/.ogsr-shot-profile`, the next run cannot open it. Close it before re-running.

### 4. Two ❌ RE-CAPTURE shots have no job — the login will not buy them unless you add one

| asset | why it is not in the run |
|---|---|
| `platform-orientation-04-unified-console-landmarks.png` | ❌ RE-CAPTURE (stale nav, shot as `user5` on a dead cluster, already un-embedded). **Not in any jobs file.** This is m01's hero console image and among the cheapest possible shots — console home with `user1-dev` selected. It is pure URL-and-shoot. |
| `build-deliver-04-topology-built-and-wired.png` | ❌ RE-CAPTURE (2 nodes, ungrouped, no `parasol-notifications`). **Not in any jobs file.** Needs its own `ws start build-deliver`, which owns `{user}-dev` and conflicts with m13/m14 — so it can only go **first, before Phase 1 row 1**, or **last, after row 6**. Never in the middle. |

Both are decisions, not oversights I should make unilaterally: neither job is grounded against a
live console, and an ungrounded job that fails inside the window is the exact cost this pre-flight
exists to avoid. If you want the m01 one, it is ~1 minute of window time and fails fast if wrong.

### 5. Three known-bad assets survive this run, because their jobs are parked

`observability-health-scale-02-observe-traces.png` (57 KB "No Tempo instance selected"),
`gitops-fundamentals-07-gitea-edit-overlay.png` (Commit Changes panel below the fold), and
`gitops-fundamentals-02-new-app-form.png` (scrolled past the GENERAL section) are all ❌ in their
manifests and all unfixable by this harness. **They stay wrong on disk after a fully successful
run.** Do not read a clean run as "the module's media is done".

### 6. Two capture targets have no embed point — captured but not finished

- `trusted-supply-chain-03-imagestream-tags.png` — **no `// media-pass:` marker anywhere** in the
  module's pages. Capturing it produces an orphan asset. Per RUNBOOK's own rule, "a captured file
  that nothing embeds is not done."
- `trusted-supply-chain-02-pipelinerun-scan-failed.png` — the marker at
  `content/modules/ROOT/pages/trusted-supply-chain/lab.adoc:410` names
  `trusted-supply-chain-**03**-pipelinerun-scan-failed.png`, which is a different (and wrong)
  filename from the manifest row and the job. Whoever embeds it will chase this.

Both live under `content/`, owned by another lane — reported, deliberately not touched here.

### 7. An aborted Phase 1 leaves the cluster broken

`stage-m12-alert.sh` intentionally leaves `claims-db` at 0 replicas; `stage-m12-hpa.sh` (the next
job) is what restores it. If the run dies between row 3 and row 4 — a failed wait, a lost session,
Ctrl-C — `{user}-dev` is left with a downed database and a firing alert. `RUNBOOK.md` documents the
`claims-burst` cleanup but not this one.

```bash
# if Phase 1 aborts between the alert shot and the HPA shot:
oc scale deploy/claims-db -n user1-dev --replicas=1
oc rollout restart deploy/parasol-claims -n user1-dev   # poisoned connection pool — not optional
oc delete pod claims-burst -n user1-dev --ignore-not-found
```

### 8. `RUNBOOK.md`'s own counts were stale

It said "28 jobs … 13 pointed at files the manifests mark ✅ CAPTURED". Actual: **26 jobs, 18
targets already on disk.** Corrected in place. Minor, but it is the number a reader uses to decide
how much the guard is protecting.
