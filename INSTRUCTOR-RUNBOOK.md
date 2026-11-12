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

1. **Pick the modules.** The [README module table](README.md#workshop-content) gives each module's
   hands-on time. Put the list in `modules_enabled`.
2. **AI steps need a model endpoint and key at install time.** That covers jobs-batch-kueue's
   batch inference and the OpenShift Lightspeed console assistant.
3. **Order and size the cluster** with [INSTALL.md › Before you order](INSTALL.md#1-before-you-order).

---

## 2. Day before

1. **Install and verify:** [INSTALL.md › Install](INSTALL.md#2-install), steps 1–7.
2. **Run the pre-flight checklist** on the instructor page of every module in your agenda.
3. **Changed the AI model?** Run `tools/ws/adm maas show`: every attendee must read `working`.

---

## 3. Morning of

1. **If you changed content since installing:**

   ```bash
   tools/ws/adm git-refresh --restart-terminals --all
   ```

2. **Check the cluster:** `tools/ws/adm doctor`
3. **Share the Etherpad link:** `https://ogsr-pad.<apps>/p/workshop`. It holds the Showroom link and
   a numbered list where each attendee claims a user, so no two people take the same one.
   - Showroom: `https://ogsr-showroom.<apps>`. Log in as `userN` with the workshop password on the
     Keycloak sign-in page. That one sign-in covers the Console, Dev Spaces and Argo CD tabs.
4. **Check the cohort:** `tools/ws/adm status` must end with
   `shared cockpit showroom-shared ✅ 1/1 · terminal pods ✅ N/N` and `platform all-Synced ✅`.
5. **Last check:** `tools/ws/adm ready` must end with `✅ workshop ready`.

No login refresh is needed. Each attendee's terminal logs in from their own browser sign-in.

---

## 4. During

**Pacing.** Use the timing table on each module's instructor page.

- The stated time is for a mixed room. Confident attendees finish in about half; newcomers need
  about a third longer.
- The install pre-pulls images and mirrors Maven, so first runs are fast. A module that still runs
  long is usually waiting on a build; its instructor page says how long to expect.

**Switching modules.** No module depends on another. But starting a module **discards** the state of
a module that shares its namespaces:

- `{user}-cicd`: Pipelines Fundamentals, Application Security Testing, Trusted Software Supply Chain.
- Own namespaces, no conflicts: Jobs/Batch & Kueue, Service Mesh, Resilience/Multi-Cluster/DR.
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
| A Console, Dev Spaces or Argo CD tab stays blank | `tools/ws/adm doctor`, row `workshop IdP`: more than one sign-in option is configured. Keep only the Keycloak one ([INSTALL.md › Dedicated cluster](INSTALL.md#6-dedicated-cluster)). |
| An AI step returns an authentication error | Run `tools/ws/adm maas show`, then fix with `tools/ws/adm maas set`. No reinstall. |

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

`ogsr-reset.sh` clears all lab work and empties each attendee's terminal home. It keeps the platform
and every account. It does **not** clear:

- Developer Hub catalog entries.
- SonarQube projects, until the attendee next prepares Application Security Testing (that starts
  their project fresh).
- Contents of each attendee's Keycloak realm.
- Gitea tokens and SSH keys on the kept accounts.
