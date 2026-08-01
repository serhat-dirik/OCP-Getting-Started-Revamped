# M14 media manifest — Multi-Tenancy & Workload Security

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is dual-path but not the content — so the mandatory
recording is a **terminal cast** of the demo arc; screenshots are optional enrichment for the
Console tabs. All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22,
2026-07-12 as user1); the diagram SVG exports below are already rendered and committed (2026-07-26,
label fix + platform-accretion diagram 2026-07-28) — the mandatory terminal cast and the optional
screenshots remain the deferred media pass. Every screenshot
needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass:` line — replace with the `image::…` when the asset lands.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `multi-tenancy-workload-security-01-identity-flow.svg` | concept.adoc Mermaid "identity → authority" — `examples/diagrams/multi-tenancy-workload-security/01-identity-flow.mmd` | IdP → User → **Group** → RoleBinding → Role → verbs; highlight the group as the design lever; reused on slide 2 |
| `multi-tenancy-workload-security-02-scc-admission.svg` | concept.adoc Mermaid "restricted-v2 admission" — `examples/diagrams/multi-tenancy-workload-security/02-scc-admission.mmd` | Pod `runAsUser:0` → restricted-v2 UID-range gate → **rejected** vs **fix the image** vs **scoped SCC grant**; the module's anchor diagram, reused on slide 4 |
| `multi-tenancy-workload-security-03-platform-accretion.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/multi-tenancy-workload-security/03-platform-accretion.mmd` | **master accretion diagram**, the M14 layer (tenant sandbox: RBAC + quota + SCC around `{user}-dev/stage/prod`) highlighted on the running Parasol platform |
| `multi-tenancy-workload-security-04-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/multi-tenancy-workload-security/04-what-you-built.mmd` | tenant sandbox (payments-ci/ops, non-root workload, quota) vs platform-owned levers (platform-observer, self-provisioning/template, OAuth IdPs); green = tenant self-service, blue = platform-owned |

Shared legend across all four: namespace box, User/Group/ServiceAccount subject icons, Role/binding
tag, quota gauge, SCC shield — same palette as M01–M13 (Red Hat-neutral, no vendor-logo soup).

## Recordings

### Terminal cast — the five-minute safe sandbox (`multi-tenancy-workload-security-demo.cast`, ~10 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as `user1` (drive it
straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`):

1. show the three ungoverned ServiceAccounts;
2. grant `payments-ci` edit-in-dev / view-in-prod, prove with `can-i` (edit dev, read-only prod);
3. author the custom `deployer` Role, bind `payments-ops`, prove deployments-yes / secrets-**no**;
4. scale `root-demander` and show the live **restricted-v2 rejection** naming `runAsUser: 0` (this is the signature moment — hold on it).

The rejection in step 4 is the module's signature moment; embed near lab.adoc exercise 1 and the demo
arc. Warm the `openshift/tools` image first so there's no cold-pull dead air before the fix. Never
show a minted token on screen (decode claims only).

## Screenshots (optional — Console tabs get visual support; CLI is the source of truth)
> **Media-pass status, 2026-08-01.** The console rows in this module could not be shot: the OpenShift
> console sits behind OpenShift OAuth, the cached capture session in `shot-profile.session.json` had
> expired (a probe came back as a 25 KB PNG of the IdP chooser — conventions §4 exactly), and
> establishing a new one needs a human to type a password, which that lane is barred from doing.
> What the lane did instead: it **staged and proved every cluster state these shots need** on
> `user7` and wrote them into `tools/media/jobs-m14-m19-console.yaml` with the staging scripts
> (`tools/media/stage-m1*.sh`). One login window now runs the whole block. Per-row status below.


| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `multi-tenancy-workload-security-01-deploy-0of1-event.png` | 🟡 READY TO SHOOT 2026-08-01 — state staged and proved on user7 (`tools/media/stage-m15-multitenancy.sh` scales `root-demander` to 1 and polls until the refusal event exists); job row written. **Correction:** the `FailedCreate` is emitted by the **ReplicaSet**, not the Deployment — the pod is refused at admission and never created, so the Deployment's own Events tab may show nothing. The job shoots the ReplicaSet's Events tab (name resolved at run time). The caption's `0 of 1` lives on the Deployment page; if both must share a frame this row needs splitting. Console → Workloads → Deployments → `root-demander` → Events tab, showing the SCC `FailedCreate` | Circle: `0 of 1` pods + the `restricted-v2 … runAsUser` event line | lab.adoc ex. 1 Console tab |
| 2 | `multi-tenancy-workload-security-02-create-rolebinding.png` | ⛔ PARKED 2026-08-01 — confirmed unreachable headlessly (modal form, no pre-fillable deep link, harness cannot type). Record the GIF below instead and drop the still. Console → User Management → RoleBindings → Create binding form (subject=ServiceAccount payments-ci, role=edit) | Circle: Subject type=ServiceAccount, Role name=edit | lab.adoc ex. 3 Console tab |
| 3 | `multi-tenancy-workload-security-03-resourcequota-gauges.png` | ✅ CAPTURED 2026-07-30 · **EMBEDDED 2026-08-01** (it had been on disk but `lab.adoc` still carried the `// media-pass:` placeholder) — Console → Administration → ResourceQuotas → `workshop-quota` donut gauges (`/k8s/ns/user1-dev/resourcequotas/workshop-quota`) | Circle: requests.memory used-vs-hard gauge — captured at 13.5% used (832Mi/6Gi). Six gauges render: limits.cpu 26.7%, limits.memory 13.5%, persistentvolumeclaims 0 of 10, pods 4 of 30, requests.cpu 18.3%, requests.memory 13.5% | lab.adoc ex. 5 Console tab |

**Animated gif (PREFERRED for the multi-click RoleBinding flow):**
`multi-tenancy-workload-security-04-grant-role.gif` (<30 s, silent) — the Console path of ex. 3:
User Management → RoleBindings → Create binding → pick ServiceAccount subject + `edit` role → Create,
then the binding appears. Multi-click console flow → gif beats static shots (project owner, 2026-07-11).

`[CAPTURE-VERIFY]` labels to confirm while shooting (the unified console — no perspective
switch): (1) Deployment **Events** tab surfaces the `FailedCreate`/SCC message; (2) **User
Management → RoleBindings → Create binding** offers a *ServiceAccount* subject type with a subject
namespace field; (3) **Administration → ResourceQuotas** shows the used/hard gauges. These confirm the
Console-tab click-paths written with `[CAPTURE-VERIFY]` in `lab.adoc`; the CLI tabs are authoritative.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 12-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"same team, two service accounts — one can read the
payment secrets, one is completely blind to them, and the difference is one custom Role."*
