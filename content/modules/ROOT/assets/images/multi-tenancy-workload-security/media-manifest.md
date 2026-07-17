# M14 media manifest — Multi-Tenancy & Workload Security

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`mNN-<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is dual-path but not the content — so the mandatory
recording is a **terminal cast** of the demo arc; screenshots are optional enrichment for the
Console tabs. All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22,
2026-07-12 as user1); the diagram SVG exports below are the deferred media pass. Every screenshot
needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc` files with a
commented `// media-pass:` line — replace with the `image::…` when the asset lands.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `multi-tenancy-workload-security-01-identity-flow.svg` | concept.adoc Mermaid "identity → authority" | IdP → User → **Group** → RoleBinding → Role → verbs; highlight the group as the design lever; reused on slide 2 |
| `multi-tenancy-workload-security-02-scc-admission.svg` | concept.adoc Mermaid "restricted-v2 admission" | Pod `runAsUser:0` → restricted-v2 UID-range gate → **rejected** vs **fix the image** vs **scoped SCC grant**; the module's anchor diagram, reused on slide 4 |
| `multi-tenancy-workload-security-03-platform-accretion.svg` | concept.adoc — media-pass pending (centrally maintained master diagram) | **master accretion diagram**, the M14 layer (tenant sandbox: RBAC + quota + SCC around `{user}-dev/stage/prod`) highlighted on the running Parasol platform |
| `multi-tenancy-workload-security-04-what-you-built.svg` | wrapup.adoc Mermaid recap | tenant sandbox (payments-ci/ops, non-root workload, quota) vs platform-owned levers (platform-observer, self-provisioning/template, OAuth IdPs); green = tenant self-service, blue = platform-owned |

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

| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `multi-tenancy-workload-security-01-deploy-0of1-event.png` | Console → Workloads → Deployments → `root-demander` → Events tab, showing the SCC `FailedCreate` | Circle: `0 of 1` pods + the `restricted-v2 … runAsUser` event line | lab.adoc ex. 1 Console tab |
| 2 | `multi-tenancy-workload-security-02-create-rolebinding.png` | Console → User Management → RoleBindings → Create binding form (subject=ServiceAccount payments-ci, role=edit) | Circle: Subject type=ServiceAccount, Role name=edit | lab.adoc ex. 3 Console tab |
| 3 | `multi-tenancy-workload-security-03-resourcequota-gauges.png` | Console → Administration → ResourceQuotas → `workshop-quota` donut gauges | Circle: requests.memory used-vs-hard (6Gi cap) | lab.adoc ex. 5 Console tab |

**Animated gif (PREFERRED for the multi-click RoleBinding flow):**
`multi-tenancy-workload-security-04-grant-role.gif` (<30 s, silent) — the Console path of ex. 3:
User Management → RoleBindings → Create binding → pick ServiceAccount subject + `edit` role → Create,
then the binding appears. Multi-click console flow → gif beats static shots (Serhat 2026-07-11).

`[CAPTURE-VERIFY]` labels to confirm while shooting (OCP 4.21 unified console — no perspective
switch): (1) Deployment **Events** tab surfaces the `FailedCreate`/SCC message; (2) **User
Management → RoleBindings → Create binding** offers a *ServiceAccount* subject type with a subject
namespace field; (3) **Administration → ResourceQuotas** shows the used/hard gauges. These confirm the
Console-tab click-paths written with `[CAPTURE-VERIFY]` in `lab.adoc`; the CLI tabs are authoritative.

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 12-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"same team, two service accounts — one can read the
payment secrets, one is completely blind to them, and the difference is one custom Role."*
