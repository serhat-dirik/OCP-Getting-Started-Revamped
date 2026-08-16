# Instructor Runbook — Delivering a Live Session

The document you follow to actually run this workshop in front of a room, in delivery order:
provisioning → day before → morning of → during → when something breaks → after.

This runbook does not re-explain the mechanics — **[INSTALL.md](INSTALL.md)** owns installing,
verifying, and troubleshooting; **[README.md](README.md)** owns the module catalogue and the
recommended delivery lengths; each module's `instructor.adoc` page (the *Instructor* rendering of
`site-instructor.yml`, or read directly under `content/modules/ROOT/pages/<slug>/instructor.adoc`)
owns that module's own timing table, pre-flight checklist, demo notes, top questions, and
watchouts. This runbook's job is to sequence all of that into one thing you check off on delivery
day. Every command below is copied from `INSTALL.md`, `README.md`, or `tools/ws/adm --help` /
`tools/ws/adm` itself — none are invented. Most of what follows is `adm`, the operator surface of
the workshop CLI; attendees use `ws`, its four-verb surface (`list`/`prep`/`verify`/`reset`), inside
the cockpit.

**Contents**

1. [Weeks/days before](#1-weeksdays-before)
2. [Day before](#2-day-before)
3. [Morning of](#3-morning-of)
4. [During](#4-during)
5. [When something breaks](#5-when-something-breaks)
6. [After](#6-after)

---

## 1. Weeks/days before

### Decide the shape of the delivery

Before you order anything, settle three things — they drive the sizing math below:

1. **How many attendees?** Sets `users` in `bootstrap/vars.yaml` and the sizing table's row
   (Small/Normal/Large — [INSTALL.md §2](INSTALL.md#2-sizing-the-cluster)).
2. **How long is the session?** [README's delivery table](README.md#workshop-content) gives four
   proven shapes — half-day taster, full-day essentials, 2-day core, and the 3-day full workshop —
   or assemble your own subset, since every module is self-contained. Read the module lists and the
   totals off that table rather than off a copy here: they are summed from the per-module time
   figure in the module table just above it, which is also what you pace against in
   [§4](#4-during), so a second copy in this file silently contradicts the real one the first time
   a module is re-measured — which is exactly what happened to the copy that used to sit here.
   Whichever shape you pick, its module list is what you translate into `modules_disabled` in
   step 3 below.
3. **Which modules are actually in scope?** Anything you're dropping goes in `modules_disabled`
   in `vars.yaml` (`mNN` or slug). This isn't just a content choice — it changes what you need to
   order:
   - Dropping the RHACS-dependent modules (app-security-testing, trusted-supply-chain) is "the
     single biggest lever" for a lean install — RHACS alone is ~26 Gi, 46% of the platform's
     memory ([INSTALL.md §2](INSTALL.md#2-sizing-the-cluster)).
   - Dropping `deployment-targets-scheduling` is the only way to run fewer than **five** workers —
     that module alone is what forces the fifth (batch-pool) worker at every cohort size, because
     it needs four *schedulable, non-batch* nodes plus one tainted batch node, not just aggregate
     capacity. If it stays in scope, order five workers regardless of headcount.
   - If any AI module is in scope (jobs-batch-kueue's batch inference, agentic-ai,
     ai-assisted-development, app-modernization's MTA Lightspeed beat), you need an OpenAI-compatible
     model endpoint decided *now* — MaaS, an on-cluster vLLM runtime, or a public provider — since
     it's a `vars.yaml` input at install time, not something you bolt on live. Note MaaS keys are
     **model-scoped**: the key you get has to match the model you configure, or every AI-module call
     fails with a generic auth error ([INSTALL.md §1](INSTALL.md#1-what-you-need)).

### Order the cluster

Use the sizing table in [INSTALL.md §2](INSTALL.md#2-sizing-the-cluster) — worker count follows
from cohort size *and* whether `deployment-targets-scheduling` is in scope, not from headcount
alone. At Red Hat, order the OpenShift Field Asset item from the Red Hat Demo Platform (see
INSTALL.md for the catalog link); node count and shape are chosen at order time.

**Lead time:** the repo does not prescribe a fixed number of days — the one hard rule is *get the
cluster with enough lead time to install and smoke-test before the session, and never plan to
install in front of the room* ([INSTALL.md §2](INSTALL.md#2-sizing-the-cluster)). Budget for the
install itself (15–20 minutes to the completion banner, more for operators to finish reconciling
behind it — INSTALL.md §3.3), a full pre-flight pass, and time to fix whatever pre-flight finds —
none of that should be happening the morning of the session.

---

## 2. Day before

### Install and verify

Follow [INSTALL.md §3–§4](INSTALL.md#3-installing) start to finish:

```bash
tools/ws/adm preflight                        # read-only: tooling, cluster access, adoption forecast
# review the adoption forecast — on a customer cluster, show it to the customer first
cp bootstrap/vars.example.yaml bootstrap/vars.yaml
# edit vars.yaml: users, cluster_domain, modules_disabled, workshop_user_password, maas.*
./bootstrap/install.sh                       # six phases, idempotent, ~15-20 min to the banner
tools/ws/adm doctor                           # is the environment sane?
tools/ws/adm status                           # cohort dashboard: every platform app + every attendee
```

Then spot-check one module end to end, exactly as INSTALL.md prescribes — `ws verify` is
**mode-split** (entry-state assertions before the lab, outcome assertions after), so a green check
at the wrong point proves nothing:

```bash
tools/ws/adm start m01 --user user1
tools/ws/ws verify m01 --user user1
tools/ws/ws reset  m01 --user user1
```

### Warm and pre-open what the day's modules need

Every module's `instructor.adoc` carries its own **Pre-flight checklist** ("Run these before the
session") — run the ones for every module in your agenda. A subset of modules call out something
that specifically needs *warming* or *pre-opening* the day before, because the first live run in
front of the room is measurably slower than a warm one:

| Module | What to warm/pre-open | Why |
|---|---|---|
| Platform Orientation & First App | Deploy-and-delete the claims image once as a sample user | Warms the 410 MB image on a node — first pull is ~18 s, subsequent starts are seconds |
| Ways to Build & Deliver Apps | `adm solve build-deliver --user <u>` before the session | First S2I build is ~4.5 min warm but up to **~11 min** on a cold node (Maven Central + no builder-image cache) |
| Dev Spaces & the Inner Loop | Start one workspace before the room arrives (pulls the universal developer image onto a node) | First workspace start is ~85 s cold vs ~20 s once a node has the image; for a large event, ask the platform team to enable Dev Spaces' `imagePuller` on the CheCluster instead |
| Pipelines Fundamentals & Task Libraries | `adm solve pipelines-fundamentals --user <u>` before the room — it blocks for a whole pipeline run (measured 7m45s, but 20m49s for the same pipeline on a slower cluster; budget the worst) | The `maven-cache` is a **per-user PVC**, not a node cache: solving `user1` warms `user1` and nobody else, so warming a room costs one full run per attendee. No cached run has been timed yet, so promise the room no number — the alternative is to accept that every attendee's first run is the slow one and let exercise 2 fill the wait, which is what the module is designed for |
| Trusted Software Supply Chain | Run the seeded pipeline once on a sample user, ~1 hour before the session | The RHACS vulnerability store needs ~1 hour to populate on a freshly installed cluster before the Log4Shell policy fires; separately, materializing this module at all — `adm start`/`solve`, or an attendee's own `prep` — blocks ~8 min building a warm signed image — budget that into provisioning too, not just the day before |
| Application Security Testing | Have attendees clone and start their first run before you deliver the concept. **Running the demo flavor instead? Stage its six finished PipelineRuns days ahead** — the arc is a tour of runs that have already finished and triggers nothing live, so its prep is one full pass through this module's own lab (**~66 min of pipeline**, and that floor cannot be negotiated down) | No cache survives a run (unit tests ~5.5 min + image build ~4 min every time), so hands-on is ~85–105 min — a genuine double slot, and the module table's 100 min is a figure inside that band, not a slot you can compress. Pre-warming the first run closes part of the gap; the demo flavor (~15 min of room time) is the honest choice if all you have is a single hour — but that 15 min is *room* time only, and its preparation is the ~66 min above, so it is not a way to save the day-before |
| Multi-Tenancy & Workload Security | Warm the `openshift/tools` image on a node (`oc run` it once, then delete) | Exercise 1's fix and exercise 5's SCC demo both stall on a cold image pull (up to ~20 s) otherwise |
| Developer Hub & Golden Paths | Sign in as guest and open the Catalog filtered to `parasol-claims` before the room | So the first beat is one glance, not a cold login + navigation |
| GitOps Fundamentals / GitOps at Scale | `adm solve <slug> --user <u>` before the room | Leaves a pre-solved, pre-signed-in state ready as your opening visual — but note it performs a real sync to the entry Git revision, so a private rehearsal of the later beats is a second sync/self-heal cycle against that same revision |
| Securing Apps with Keycloak | Confirm the workshop `sso-workshop` Keycloak and each attendee's seeded realm are up (pre-flight items 2–3) | The whole module depends on both being healthy; also brief yourself not to let attendees "fix" exercise 4's deliberate break early |
| Service Mesh 3 & Advanced Gateways | Pre-open Kiali, signed in, correct project selected, on a second screen | It's the visual for the enroll/traffic beats |
| Resilience, Multi-Cluster & DR | Run `ws reset resilience-multicluster-dr` before the session, not live | It's slow |
| Serverless Zero-to-Hero | The opposite of warming: let the service settle to **zero** pods (~a minute of no traffic) before beat 1 | If you've been poking it, the cold start won't actually fire |
| Eventing Deep-Dive & Serverless Workflows | `curl` both services once to warm them before you start, *unless* you want the ~14 s cold wake as a deliberate beat | Otherwise the demo waits on a cold start mid-sentence |
| Application Modernization (MTA + Lightspeed) | **Stage three MTA applications, not one** — `parasol-legacy-claims-demo`, `parasol-legacy-claims-fixed-demo` and `parasol-claims-demo`, all in *Source code* mode against the same five targets. Budget **~10–15 min of Hub time** (three analyses at ~3–5 min each, and they overlap) plus the console clicks and the one `git push` that creates the `demo-fixed` branch — the module measures neither, so do it the evening before, not in the last half hour. The repo/branch table and the exact commands live in the module's demo-prep block ("Before you present"); stage from there so there is one recipe and not two. Also warm the Dev Spaces workspace (first start pulls the universal developer image, 2–3 min) | The MTA console keeps **one current report per application**, so re-analysing in place *overwrites* the baseline the first beat opens on — three applications is the only way to put a before and an after on screen together. Keep the `-demo` suffix on all three: the Hub's portfolio is shared and flat, so a row named after an attendee hands them the finished analysis the lab asks them to produce. The warm workspace is what keeps the AI-assisted-fix beat from stalling on infrastructure |
| AI-Assisted Development on OpenShift | Re-verify the MaaS key is present and unexpired; run exercise 3 end to end on *your* cluster's model beforehand; do one throwaway `ask-agent` diagnosis right before you present | Models differ in whether they execute a write at all, or write it correctly — check on your own model, don't assume; the first call of the day is also the slowest (cold model, key fetch) |

If a module in your agenda isn't in this table, it still has a Pre-flight checklist — run it, it's
just read-only verification rather than something to warm.

---

## 3. Morning of

**Refresh attendee logins first — this is the single most likely day-of failure.** Each cockpit's
kubeconfig is written once, when its pod starts, and holds an OAuth token that expires on the
cluster's own schedule (24 hours unless the cluster overrides it). Installing the day before is the
normal case, so without this step the first thing an attendee types comes back `Unauthorized`
while everything else — pod Running, Application Synced, cockpit page loaded — looks fine
([INSTALL.md §7.1](INSTALL.md#71-attendees-get-unauthorized-on-their-first-command)):

```bash
tools/ws/adm session-refresh --all
```

Takes seconds, needs no pod restart, safe to run again at any point during the day.

**If you pushed content or updated the workshop since installing**, use this instead — it covers
the logins *and* re-clones each cockpit (which `session-refresh` deliberately does not do), fixing
the "`ws prep` refused with an AppProject error" failure at the same time
([README.md](README.md#starting-the-workshop), [INSTALL.md §7.2](INSTALL.md#72-ws-prep-fails-with-attendees-may-only-use-their-own-appproject)):

```bash
tools/ws/adm git-refresh --restart-terminals --all
```

**Hand out one link.** The whole room uses the same cockpit — guide + terminal + tool tabs in one
page — and each person signs in as their own attendee user:

```
https://ogsr-showroom.<cluster-domain>
```

They log in as `userN` with the shared workshop password (a deliberately memorable, non-secret
value you set in `vars.yaml`, printed again at the end of `install.sh`). The terminal comes up
already logged in as that user, so `oc whoami` is their own identity.

Read the cohort board out instead of the raw URL if you prefer — it carries the same link plus a
numbered list people claim, which stops two attendees taking the same slot:

```
https://ogsr-pad.<cluster-domain>/p/workshop
```

The SA demo cockpit, if you're using it, is
`https://ogsr-demos.<cluster-domain>`, behind the same login.

**One last glance before the room fills up:**

```bash
tools/ws/adm status
```

Confirm `N/N cockpit(s) ready` and `platform all-Synced` before you start talking.

---

## 4. During

### Pace against the modules' own timing chips

Each module's `instructor.adoc` has a *Timing* table — total hands-on time, per-exercise-group
minutes, and a "measured CLI core" column that's the real command time behind the estimate. Use
those, not a stopwatch on the room. Two things every one of them says the same way, worth knowing
once rather than relearning per module:

- **The stated time is a planning figure for a mixed room, not a stopwatch number.** A confident
  attendee finishes in roughly half; someone new to OpenShift may need about a third longer. Plan
  the agenda on the stated figure and the room stays together (README.md).
- **The dominant variable is almost always a cold resource** — an image pull, a Maven build, a
  workspace start, a scanner warm-up. That's exactly what [§2's warm/pre-open table](#2-day-before)
  exists to take off the room's clock; if you skipped warming a module that's in today's agenda,
  expect its first live run to run long.

### `[INSTRUCTOR-DEMO]` exercises — what they are and why

Nine modules contain one exercise group that's an **instructor demo inside an otherwise hands-on
module**, not a whole separate demo delivery. All nine follow the same reason: the action is a
**cluster-wide singleton** — it affects every tenant on the cluster, not just the attendee's own
namespace — so attendees read the result but the instructor performs the action:

| Module | What's demonstrated | Why it's instructor-only |
|---|---|---|
| Deployment Targets & Scheduling | Cluster-wide scheduling levers | Affect every tenant |
| Networking for Dev & DevOps | The Gateway API — the strategic direction | The GatewayClass is a cluster-wide singleton the platform team owns |
| Multi-Tenancy & Workload Security | The platform team's cluster-wide levers, and a scoped SCC exception | Cluster singletons, sequenced and reverted so later modules keep working |
| Registry, Images & Catalog Governance | The governance surface (import blocking, mirroring, sample curation) | Setting these affects every tenant; attendees only read the results |
| Serverless Zero-to-Hero | Build a Function (`kn func`) | Needs a container build path (local engine+registry, or on-cluster Pipelines) the workshop terminal doesn't have — presented as concept + demo, not a graded exercise |
| Resilience, Multi-Cluster & DR | Draining a node, watching the PodDisruptionBudget pace it | Node drain is cluster-wide |
| Trusted Software Supply Chain | The cluster refusing to run an unsigned image (admission) | The `ImagePolicy` is applied cluster-wide by the instructor; the effect lands in the attendee's own namespace |
| Securing Apps with Keycloak | The same Keycloak instance backs the OpenShift console login | Ties the attendee's realm to a cluster-wide fact only the instructor can show directly |
| Dev Spaces & the Inner Loop | The GUI debug path, *only* if the registry is unreachable (disconnected cluster) | Situational fallback — the guaranteed `jdb` terminal path is the hands-on default |

### Sequencing constraints between modules

**No module assumes another one ran.** Any module can be an attendee's first. But most modules
share a namespace family with several others, and *starting* a module evicts a **conflicting**
module's materialized state in the same namespace (`gitops/entry-states/<slug>/ws-meta.yaml`,
`conflictsWith`):

- **`{user}-dev`(/`-stage`/`-prod`/`-cicd` where used)** is the family most modules live in:
  Platform Orientation, Ways to Build & Deliver Apps, Dev Spaces & the Inner Loop, Config/Secrets &
  Multi-Environment, Storage & Stateful Apps, GitOps Fundamentals, GitOps at Scale, Developer Hub &
  Golden Paths, Registry/Images & Catalog Governance, Deployment Targets & Scheduling,
  Multi-Tenancy & Workload Security, Securing Apps with Keycloak, Serverless Zero-to-Hero,
  Eventing Deep-Dive, Observability/Health & Scale, Networking for Dev & DevOps, Packaging &
  Distributing, AI-Assisted Development.
- **`{user}-cicd`** is its own smaller family: Pipelines Fundamentals, Application Security
  Testing, and Trusted Software Supply Chain conflict with each other.
- **Dedicated namespaces that conflict with nothing:** Jobs/Batch & Kueue (`{user}-batch`),
  Service Mesh (`{user}-mesh`), Application Modernization (`{user}-modernize`), Agentic AI
  (`{user}-ai`), Resilience/Multi-Cluster/DR (`{user}-client`/`{user}-site-a`/`{user}-site-b`).

**In practice:** if an attendee wants to jump from one same-family module to another mid-day,
warn them that starting the new one discards the old one's materialized state — the module itself
isn't damaged (`ws reset`/`ws prep` bring it back cleanly), but any work in progress on top of it
is gone. When *you* materialize a module for someone stuck, this cuts the other way too: `adm start`
**does not purge** a module that's already resident for that attendee — it only evicts a different,
*conflicting* module. If they already have that module materialized and you need them on a
genuinely clean slate, run `ws reset <module> --user <u>`, not `adm start` again (documented against
Serverless Zero-to-Hero's `instructor.adoc`, but the underlying behavior is in the shared `ws`
code, not module-specific).

---

## 5. When something breaks

The three failures most likely to actually happen in a live room, in the order you're likely to
meet them, each drawn straight from [INSTALL.md §7](INSTALL.md#7-troubleshooting):

**1. An attendee's terminal says `Unauthorized` on the very first command.**
Almost always the morning-of session refresh didn't happen or didn't reach that attendee. Confirm
the token lifetime, then fix:

```bash
oc get oauth cluster -o jsonpath='{.spec.tokenConfig.accessTokenMaxAgeSeconds}{"\n"}'   # empty = 24h default
tools/ws/adm session-refresh --user <userN>          # or --all for the whole cohort
```
([INSTALL.md §7.1](INSTALL.md#71-attendees-get-unauthorized-on-their-first-command))

**2. `ws prep` is refused: "attendees may only use their own AppProject."**
The cockpit is running a stale copy of `ws` — this happens after you push a content update but
only `git-refresh` the mirror, not the terminals. Confirm which half a cockpit has, then fix with
the scoped flag (not `--restart-terminals` alone, which "refuses with restart needs a target" and
restarts nothing):

```bash
oc exec -n ogsr-showroom deploy/showroom-shared -c terminal -- grep -c ARGO_PROJECT_PIN /showroom/repo/tools/ws/ws
tools/ws/adm git-refresh --restart-terminals --all
```

Non-zero means current (a current cockpit prints `3`), `0` means old. There is one cockpit now, and
`ws` reaches it through a read-only mount of the build's clone at `/showroom/repo`, so there is no
per-attendee `~/ocp-getting-started` to check.
([INSTALL.md §7.2](INSTALL.md#72-ws-prep-fails-with-attendees-may-only-use-their-own-appproject))

**3. An AI module (jobs-batch-kueue's batch beat, agentic-ai, ai-assisted-development,
app-modernization's Lightspeed beat) returns an authentication error.**
MaaS keys are model-scoped — a key issued for one model fails against another, and the error looks
generic. Diagnose per attendee, then fix without a reinstall:

```bash
tools/ws/adm maas show          # per-attendee model/endpoint + working/degraded/unknown verdict
tools/ws/adm maas set --model <model> --key-file <path>   # re-stage; re-converges every AI module live
```
([INSTALL.md §7.9](INSTALL.md#79-ai-modules-return-authentication-errors))

**Anything else:** collect the standard bundle before you escalate, then check the specific
module's own `troubleshooting.adoc` (every module has one) and the rest of
[INSTALL.md §7](INSTALL.md#7-troubleshooting) — it covers 13 total scenarios, including stuck
`Terminating` namespaces, an Argo Application that won't sync, and OperatorGroup collisions on an
adopted cluster:

```bash
tools/ws/adm doctor
tools/ws/adm status
tools/ws/adm diag --user <userN> [<module>]     # read-only bundle for one stuck attendee
oc get applications -n openshift-gitops
```

---

## 6. After

**Same cluster, next cohort — this is the normal end-of-delivery step.** Deletes all attendee lab
content and returns the cluster to its immediately-post-install state; the platform, every
attendee account, Gitea (with its repos), Keycloak (with its logins), and every cockpit stay
exactly as installed:

```bash
./bootstrap/ogsr-reset.sh --dry-run              # print the plan; change nothing
./bootstrap/ogsr-reset.sh                        # do it
./bootstrap/ogsr-reset.sh --restart-terminals    # also cycle the cockpits for the new group
```

(`adm cohort-reset` is the engine this script calls internally — run the script, not the raw `adm`
command, so you get the dry-run and the scripted ordering.)

**Handing the cluster back to its owner instead** (delivery is over, not just the cohort) — see
[INSTALL.md §6.3](INSTALL.md#63-removing-the-workshop-ogsr-uninstallsh) for the full picture, but
in short:

```bash
./bootstrap/ogsr-uninstall.sh --dry-run    # prints the WIPE / PRESERVE plan — never skip this on a customer cluster
./bootstrap/ogsr-uninstall.sh              # performs it
./bootstrap/ogsr-check-clean.sh            # read-only proof; non-zero while anything remains
```

**Cutting down to one attendee** (keeping a live sample for stakeholders, not a full teardown) uses
`ogsr-wipe-users.sh` instead — see [INSTALL.md §6.2](INSTALL.md#62-cutting-down-to-one-attendee-ogsr-wipe-userssh)
for its two harmless leftovers (a stale SonarQube account if the next cohort's password differs,
and an unpruned Developer Hub catalog).
