# Instructor Runbook

What to do, in order, to deliver a live session. Installing and troubleshooting live in
[INSTALL.md](INSTALL.md). Each module's instructor page (`content/modules/ROOT/pages/<slug>/instructor.adoc`)
has its own timing table, pre-flight checklist and watchouts.

1. [Plan](#1-plan)
2. [Day before](#2-day-before)
3. [Morning of](#3-morning-of)
4. [During](#4-during)
5. [When something breaks](#5-when-something-breaks)
6. [After](#6-after)

---

## 1. Plan

1. **Pick the agenda** from the [README delivery table](README.md#workshop-content) (half-day,
   full day, 2-day, 3-day) or choose your own modules. Put the list in `modules_enabled`.
2. **AI modules need a model endpoint and key at install time.** That covers jobs-batch-kueue's
   batch inference, agentic-ai, ai-assisted-development and app-modernization's Lightspeed step.
3. **Order and size the cluster** with [INSTALL.md › Before you order](INSTALL.md#1-before-you-order).

---

## 2. Day before

1. **Install and verify:** [INSTALL.md › Install](INSTALL.md#2-install), steps 1–7.
2. **Run the pre-flight checklist** on the instructor page of every module in your agenda.
3. **Running Application Modernization's demo, or a new AI model?** See
   [Appendix: module preparation](#appendix-module-preparation).

---

## 3. Morning of

1. **If you changed content since installing:**

   ```bash
   tools/ws/adm git-refresh --restart-terminals --all
   ```

2. **Check the cluster:** `tools/ws/adm doctor`
3. **Share the Etherpad link:** `https://ogsr-pad.<apps>/p/workshop`. It holds the Showroom link and
   a numbered list where each attendee claims a user, so no two people take the same one.
   - Showroom: `https://ogsr-showroom.<apps>`. Log in as `userN` with the workshop password.
   - Your demo cockpit, if you use it: `https://ogsr-demos.<apps>`.
4. **Last check before you start:** `tools/ws/adm status` must end with
   `shared cockpit showroom-shared ✅ 1/1` and `platform all-Synced ✅`.

No login refresh is needed. Each attendee's terminal logs in from their own browser sign-in.

---

## 4. During

**Pacing.** Use the timing table on each module's instructor page.

- The stated time is for a mixed room. Confident attendees finish in about half; newcomers need
  about a third longer.
- A module that runs long is almost always waiting on a cold image, build or workspace. That is
  what [module preparation](#appendix-module-preparation) prevents.

**Instructor-only exercises.** Nine modules have one exercise you perform yourself, because it
changes something cluster-wide. Attendees see the result.

| Module | You demonstrate |
|---|---|
| Deployment Targets & Scheduling | Cluster-wide scheduling settings |
| Networking for Dev & DevOps | Gateway API (the GatewayClass is cluster-wide) |
| Multi-Tenancy & Workload Security | Cluster-wide platform settings and a scoped SCC exception, reverted afterwards |
| Registry, Images & Catalog Governance | Import blocking, mirroring, sample curation |
| Serverless Zero-to-Hero | Building a Function with `kn func` (the attendee terminal cannot build images) |
| Resilience, Multi-Cluster & DR | Draining a node while a PodDisruptionBudget paces it |
| Trusted Software Supply Chain | The cluster refusing an unsigned image (cluster-wide `ImagePolicy`) |
| Securing Apps with Keycloak | The same Keycloak backing the OpenShift console login |
| Dev Spaces & the Inner Loop | GUI debugging, only on a disconnected cluster |

**Switching modules.** No module depends on another. But starting a module **discards** the state of
a module that shares its namespaces:

- `{user}-cicd`: Pipelines Fundamentals, Application Security Testing, Trusted Software Supply Chain.
- Own namespaces, no conflicts: Jobs/Batch & Kueue, Service Mesh, Application Modernization,
  Agentic AI, Resilience/Multi-Cluster/DR.
- Every other module shares `{user}-dev` (and `-stage`/`-prod` where used).

Tell attendees before they switch within a family: work in progress is lost; `ws prep` brings the
module back clean.

`adm start` does not reset a module the attendee already has. For a clean slate, use
`tools/ws/ws reset <module> --user <u>`.

---

## 5. When something breaks

| Symptom | Fix |
|---|---|
| Terminal says `Unauthorized` on the first command | The attendee's browser sign-in expired. They reload the cockpit page, sign in, and reopen the terminal. |
| `ws prep` refused: "attendees may only use their own AppProject" | The cockpit runs an old `ws`. Run `tools/ws/adm git-refresh --restart-terminals --all`. |
| An AI module returns an authentication error | Run `tools/ws/adm maas show`, then fix with `tools/ws/adm maas set`. No reinstall. |

Anything else: collect this, then check the module's `troubleshooting.adoc` and
[INSTALL.md › Troubleshooting](INSTALL.md#5-troubleshooting).

```bash
tools/ws/adm doctor
tools/ws/adm status
tools/ws/adm diag --user <userN> [<module>]
oc get applications -n openshift-gitops
```

---

## 6. After

| Next | Run |
|---|---|
| New cohort, same cluster (the normal case) | `./bootstrap/ogsr-reset.sh --dry-run`, then `./bootstrap/ogsr-reset.sh --restart-terminals` |
| Keep one sample attendee | `./bootstrap/ogsr-wipe-users.sh` |
| Give the cluster back | [INSTALL.md › Remove the workshop](INSTALL.md#remove-the-workshop) |

`ogsr-reset.sh` clears all lab work and keeps the platform and every account. It does **not** clear:

- Data inside shared tools: MTA applications, SonarQube projects, Developer Hub catalog entries.
  Delete attendees' MTA applications in the MTA console before a new group.
- Contents of each attendee's Keycloak realm.
- Attendee home directories in the cockpit.
- Gitea tokens and SSH keys on the kept accounts.

---

## Appendix: module preparation

Only these modules need anything from you before the session.

| Module | When | Do this |
|---|---|---|
| Application Modernization | You run its demo version | The evening before, stage three MTA applications: `parasol-legacy-claims-demo`, `parasol-legacy-claims-fixed-demo`, `parasol-claims-demo` (recipe: the Prep block on the module's Demo page). Allow 10–15 min of Hub time. Keep the `-demo` suffix: the Hub is shared with attendees. |
| AI-Assisted Development | You changed the AI model | Run exercise 3 once on the new model. Models differ in whether they carry out writes. |
| Ways to Build, Pipelines Fundamentals, Application Security Testing, Trusted Software Supply Chain, Dev Spaces | Until the install pre-warms them (in progress) | Run each once as a sample user the day before (`tools/ws/adm solve <slug> --user <u>`). The first build or workspace start is several minutes slower. |
