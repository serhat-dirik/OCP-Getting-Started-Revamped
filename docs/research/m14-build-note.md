# M14 build note — Multi-User & Multi-Tenancy

Date: 2026-07-12 · Author: research-analyst · Spec: 02-MODULE-SPECS §M14 (lines 179-188)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22, k8s 1.34) — READ-ONLY inspection (a G4 audit was running concurrently; no mutations): `oc get scc/oauth/clusterrolebinding/namespace/sa/secret`, `oc get clusterrole admin -o json` (verb analysis), `oc adm policy who-can`, pod `openshift.io/scc` annotation distribution, PSA namespace labels. Repo inspection (`gitops/workshop-config/templates/*`, `gitops/entry-states/m06`, ADR-0002, `bootstrap/install.sh`). docs.redhat.com OCP 4.21 (Authentication & authorization; Building applications; Hosted control planes) + redhat.com/access.redhat.com. `versions.yaml` `ocp` (4.21.22) re-confirmed live today; not edited (all M14 products are core-OCP behaviors, not versioned operators — same call R3 made).

## Verified versions

All entitlement `[OCP]` — RBAC, SCC/PSA, ResourceQuota/LimitRange, OAuth/IdP, projects/templates, ServiceAccounts are core OpenShift. No operator install; nothing new for `versions.yaml`.

| Product / capability | Version / state | API / mechanism | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | — | `oc version` (live) | 2026-07-12 |
| Kubernetes | 1.34 | — | cluster (per versions.yaml) | 2026-07-12 |
| **restricted-v2** SCC (the default) | active, 270 running pods | `runAsUser=MustRunAsRange`, drop **ALL** caps, `allowPrivilegeEscalation=false`, allow `NET_BIND_SERVICE`, `seccomp=runtime/default`, no host access | `oc get scc restricted-v2` + `openshift.io/scc` annotation census (live) | 2026-07-12 |
| **restricted-v3** SCC (new, NON-default) | present, 9 pods | adds `userNamespaceLevel=RequirePodLevel` + `runAsUser=MustRunAs 1000-65534` (Linux user namespaces) | `oc get scc restricted-v3` (live) | 2026-07-12 |
| Pod Security Admission | global **enforce=privileged**; warn/audit=restricted via label-syncer | SCC is the real control; syncer sets warn+audit per SA's SCCs; `openshift-*`/`kube*`/`default` exempt | live ns labels + redhat.com "Pod Admission and SCCs Version 2" | 2026-07-12 |
| SCC-exception grant pattern | current, non-deprecated | RoleBinding → ClusterRole `system:openshift:scc:<name>` (verb `use`, `resourceNames:[<scc>]`) — what `oc adm policy add-scc-to-user -z` writes | `oc get clusterrole system:openshift:scc:anyuid` (live) | 2026-07-12 |
| Bound SA tokens (legacy secret auto-gen **OFF**) | default on 4.21 | `LegacyServiceAccountTokenNoAutoGeneration`; use projected volume / `oc create token` (bounded lifetime, invalidated on pod delete) | live (default SA has only `-dockercfg`, zero `service-account-token` secrets) + openshift/enhancements `bound-sa-tokens.md` | 2026-07-12 |
| Project self-provisioning | **enabled** (default) | CRB `self-provisioners` → ClusterRole `self-provisioner` → Group `system:authenticated:oauth`; **`autoupdate=true`** | `oc get clusterrolebinding self-provisioners` (live) | 2026-07-12 |
| Project request template | **none** (cluster default) | `project.config.openshift.io/cluster` `spec.projectRequestTemplate` empty; no template in `openshift-config` | live | 2026-07-12 |
| Cluster OAuth IdPs | **two, already wired** | `rhbk` (OpenID → `keycloak/sso`, client `idp-4-ocp`) + `workshop-users` (HTPasswd) | `oc get oauth cluster` (live) | 2026-07-12 |
| `oc adm policy who-can` | works; output verbose | resourceAccessReview | live (≈25+ SAs for one verb — see risks) | 2026-07-12 |
| Hosted control planes (HCP) | GA on OCP 4.21 (mention-level) | control planes as pods on a management cluster; needs MCE 2.11 | docs.redhat.com OCP 4.21 Hosted control planes | 2026-07-12 |

Cluster reality (verified live 2026-07-12, read-only):

- **The namespace `admin` role (what every attendee already holds on their namespaces) splits the M14 hands-on cleanly** (`oc get clusterrole admin -o json`): full CRUD on **roles, rolebindings, serviceaccounts, secrets** — but **resourcequotas / limitranges are GET/LIST/WATCH only**, and there is **no `securitycontextconstraints` rule at all**. So an attendee can create teammate SAs, grant them roles, author a custom Role, and inspect tokens — but **cannot apply a ResourceQuota/LimitRange, and cannot self-grant an SCC** (RBAC escalation-prevention). This is the module's central build constraint.
- **restricted-v2 is genuinely the default** (270 pods vs 9 on restricted-v3). The spec's naming is correct; treat restricted-v3 as a forward-looking footnote (userns), not the core beat.
- **The SCC-grant is a RoleBinding to `system:openshift:scc:<name>`** — `system:openshift:scc:anyuid` grants `use` on scc `anyuid` via `resourceNames`. This is the non-deprecated pattern the spec asks for; `add-scc-to-user`/`add-scc-to-group` are the CLI wrappers that create exactly this binding.
- **OAuth already carries BOTH IdPs** (htpasswd + Keycloak-OIDC) → the `[INSTRUCTOR-DEMO]` htpasswd→Keycloak swap is a **read-only tour of the live `oauth/cluster` CR**, no mutation needed. `bootstrap/install.sh` appends the htpasswd IdP into the OAuth singleton *append-if-absent* precisely because "Argo would replace the atomic identityProviders list — locking everyone out" (a real "OAuth is a merge-hazard singleton" teaching point).
- **`self-provisioners` CRB carries `autoupdate=true`** → `remove-cluster-role-from-group` alone is silently reconciled back; the demo MUST also set `autoupdate=false` (access.redhat.com/solutions/4182181).
- **Legacy SA token secrets are gone** — a fresh SA gets only a `-dockercfg` pull secret; "inspect a bound SA token" must use `oc create token <sa>` / the projected volume, not a `<sa>-token-xxxxx` secret.
- **The workshop's OWN live multi-tenancy is the proven worked example** (`gitops/workshop-config/templates/`): `workshop-attendees` Group → `platform-observer` read-only ClusterRole + per-user `admin` RoleBindings on `{user}-dev/stage/prod/cicd`, standing ResourceQuota+LimitRange per namespace. The attendee can inspect exactly how *they* were provisioned.

## Spec deltas

- **Entry state "3 namespaces (payments team) + 2 synthetic teammate SAs; platform-observer":** the standing setup already gives each attendee **four** admin namespaces + `platform-observer` (`per-user-namespaces.yaml`, `per-user-rbac.yaml`, `platform-observer-bindings.yaml`). The payments-team *framing*, the **2 teammate SAs**, a **root-demanding workload**, and any quota-author grant are **net-new**, and **there is no `gitops/entry-states/m14/` chart yet** (entry-states stop at m13).
- **"apply ResourceQuota + LimitRange":** namespace `admin` is **read-only** on both (verified). Either (a) reuse the *standing* quota/limitrange the attendee already lives under (read effects → exceed → fix) with **zero new RBAC**, or (b) grant a **scoped** quota-author Role in the team namespaces. DECISION — see appendix.
- **"grant a scoped SCC to its ServiceAccount `[INSTRUCTOR-DEMO for the grant]`":** correct — admin has no SCC rule, so the grant is genuinely privileged. Implement as a **namespaced RoleBinding to `system:openshift:scc:nonroot-v2`** (least-privilege: fixed non-random UID) or `anyuid` (only if the image truly needs uid 0) targeting **just the team's SA**.
- **"run an image that demands root; read the admission failure":** the clean, deterministic failure is a Deployment that **explicitly sets `securityContext.runAsUser: 0`** → restricted-v2 rejects at admission ("unable to validate against any security context constraint"). An image that merely `USER 0`s without forcing runAsUser will instead be **silently remapped to a random UID** and may break at *runtime* — a different (subtler) lesson. Pick the explicit-root form for the beat.
- **`[INSTRUCTOR-DEMO]` htpasswd→Keycloak IdP swap:** reference the **live login Keycloak** (`keycloak/sso`, the `rhbk` OIDC provider) — **not** M13's `sso-workshop` instance, which is app-login only and is *not* wired to console OAuth (per `m13-build-note.md`). Read-only.
- **Self-provisioning + project template are cluster singletons, both at defaults** (self-provisioning ON; no custom template) → both correctly `[INSTRUCTOR-DEMO applies cluster-wide]`; the `autoupdate=false` step is mandatory and must be reverted in teardown.
- **restricted-v3** now exists on 4.21 (userns) — footnote only; don't confuse the restricted-v2 core beat.

## Approach recommendations

1. **Entry state = reuse the standing `{user}-dev/stage/prod`** reframed as the "payments team" (already `admin` + quota'd + limit-ranged); a new `gitops/entry-states/m14/` chart adds only in-namespace state (2 synthetic teammate SAs + a root-demanding Deployment), obeying the entry-state survives-reset rules.
2. **Attendee hands-on stays inside namespace `admin`** (zero extra cluster RBAC): grant teammate SAs `edit` in dev / `view` in prod → `who-can` audit → custom `deployer` Role (deployments yes, secrets no) → read the standing quota's effects (exceed → events → fix requests; LimitRange defaults) → inspect a bound token with `oc create token`.
3. **Instructor-demo owns the three cluster-singleton beats** — scoped SCC grant (RoleBinding → `system:openshift:scc:nonroot-v2`), disable project self-provisioning **with `autoupdate=false`**, custom project template (baked NetworkPolicy + quota) — sequenced + reverted so later modules (esp. M17) aren't broken.
4. **IdP-swap `[INSTRUCTOR-DEMO]` = read-only `oc get oauth cluster -o yaml`** showing the live htpasswd + Keycloak-OIDC providers ("the same Keycloak you used for app SSO in M13 also backs cluster login") — no mutation.
5. **Teach RBAC/tenancy against the attendee's OWN real provisioning** — inspect `platform-observer` (custom read-only ClusterRole), the `workshop-attendees` Group, the per-user `admin` bindings, and the deliberately-removed cluster-wide `namespaces` grant — the "the platform already did this to you, and here's why it's scoped" reveal.

## Mining results

**Primary mine = this repo's own live, proven multi-tenancy** (in-repo; no external credit needed):

- `gitops/workshop-config/templates/platform-observer-clusterrole.yaml` + `platform-observer-bindings.yaml` → a **real custom read-only ClusterRole** and the **removed cluster-wide `namespaces` grant** story (listing all namespaces leaked peers' projects into user5's console — the exact "scope carefully / who-can" watchout, from the field).
- `per-user-rbac.yaml` → per-user `admin` bindings **+ the `monitoring-edit` gap**: OpenShift's built-in `admin` deliberately omits `monitoring.coreos.com`, so "admin" is not all-powerful — a concrete RBAC-mental-model beat.
- `per-user-limits.yaml` → the exact **ResourceQuota** (`requests.cpu:3`, `requests.memory:6Gi`, `limits.cpu:6`, `limits.memory:12Gi`, `pvc:5`, `pods:30`) + **LimitRange** (default `500m/1Gi`, request `100m/256Mi`) the attendee reads and bumps into.
- `per-user-batch.yaml` → the **Kueue admin-role gap** (admin lacks the `kueue.x-k8s.io` CRDs — no aggregate-to-admin label → bind `kueue-batch-user-role`): same "why doesn't admin cover this?" lesson, plus generous-vs-constraining quota framing.
- `group-workshop-attendees.yaml` → the **IdP→group→RBAC** flow made concrete (bind to the group, not to N users).
- `gitops/entry-states/m06/templates/maas-credentials.yaml` → **least-privilege ServiceAccount + `resourceNames`-scoped Role** doing cross-namespace work: the "workload identity / scoped credentials" exemplar (also seeds M27's agent-SA story).
- `docs/adr/0002-argocd-topology-two-instances.md` → **per-user AppProject RBAC** + the "split the failure domain so one tenant's slip can't reach the platform" tenancy principle (a namespace-per-team-vs-blast-radius talking point).
- `bootstrap/install.sh` (lines ~95-121, 174) → htpasswd IdP mechanics + the **OAuth-singleton merge hazard** (why GitOps can't own `oauth/cluster`).

**OldContent** (largely fresh, per spec + `oldcontent-mining-index.md`):

- `MAD Roadshow - Dev Track Content Overview.pdf` → the per-module rubric (Business / Dev-challenge / Goal / Products) + per-user-namespace patterns (mining index §2a).
- `OldContent/repos/advanced-gitops-workshop` (mining index line 65) → "**RBAC-per-team labs**" — lab-shape reference (Argo-flavored; adapt to core OpenShift RBAC).
- `OldContent/repos/gitops-catalog/groups-roles-bindings/base/` → clean **RBAC-as-GitOps** shape (groups + roles + bindings) — pattern only.
- `App Connectivity Workshop.pdf` → the **accreting-architecture diagram** trick for the tenancy-spectrum concept diagram (mining index §2a).
- TL500 / `tech-exercise` = **anti-goal** (patterns only) — no direct port.

## Open risks

- **No `gitops/entry-states/m14/` chart exists.** The 2 teammate SAs, a root-demanding image, and any quota-author Role are net-new build.
- **Quota-author RBAC decision blocks the literal "apply quota" beat** — until resolved, the attendee can only *read/exceed/fix* the standing quota (still a strong lesson).
- **Root-demanding image is app/entry work.** Need a deterministic Deployment forcing `runAsUser:0` (clean SCC rejection) plus a "fixed" non-root variant (numeric USER, group-writable — ties M02). Exact admission error string is `// TODO(verify-on-cluster)` / `[CAPTURE-VERIFY]` (no pod created during this read-only pass).
- **`who-can` output overwhelm is real** (≈25+ SAs for a single verb, verified) — the "provide filters" watchout is mandatory: pair every `who-can` with a `| grep {user}` / role-scoped filter.
- **Instructor-demo mutations are cluster-wide and partly sticky** (SCC grant; self-provisioning with `autoupdate`; project template is a singleton). Pre-flight + teardown must restore defaults or M17 (project creation / catalog governance) and normal `oc new-project` break for later attendees — the instructor guide must schedule these like M17's cluster-wide demos.
- **Sandbox escape (spec watchout):** keep the custom `deployer` Role namespaced and the SCC RoleBinding scoped to the single team SA — never a ClusterRole/ClusterRoleBinding.
- **Never mutate** `oauth/cluster`, `keycloak/sso`, or `self-provisioners` during the workshop; the IdP-swap and self-provisioning beats are read-only / instructor-only-with-revert.

## Builder/platform appendix

### Decisions for the owner
1. **Quota authoring RBAC (primary decision).** namespace `admin` cannot apply ResourceQuota/LimitRange. **Recommend (A):** reuse the standing quota — attendee reads effects, exceeds it, reads events, fixes requests (zero new RBAC, faithful to "platform owns quota", matches `per-user-batch.yaml`'s "quotas belong to the platform"). **Option (B):** a *scoped* quota-author Role (create/update/delete on `resourcequotas`+`limitranges` in the 3 team namespaces only, bound to `{user}`) if the owner wants the literal "attendee applies the team's quota" — wrap-up then notes real orgs usually keep quota platform-owned.
2. **Entry-state shape:** reuse `{user}-dev/stage/prod` (recommended, lightest, already admin+quota'd) vs. net-new `{user}-payments-*` namespaces (cleaner story, more infra + duplicate quota). Recommend reuse; `cicd` stays out of the "team."
3. **IdP-swap source:** the **login Keycloak** (`keycloak/sso` via the `rhbk` OAuth IdP), read-only — **not** M13's `sso-workshop`. Confirm this reading (it's the only Keycloak actually wired to console OAuth).
4. **How much real RBAC to expose:** recommend **both** — synthetic "payments team" for the attendee's authoring hands-on, **plus** a read-only inspection of their OWN live bindings (`platform-observer`, `workshop-attendees`, per-user `admin`) as the "how you were provisioned" reveal.
5. **Scoped-SCC target:** `nonroot-v2` (least-privilege; fixes a non-random UID) by default; `anyuid` only if the demo image genuinely requires uid 0.
6. **restricted-v3:** one-line footnote (userns), not a core beat.

### Platform (platform-engineer)
- If Decision 1B is adopted: a small workshop-layer `per-user-quota-author.yaml` (namespaced Role in the 3 team namespaces + per-user RoleBinding) mirroring the `per-user-argo-rbac.yaml` shape — keep it namespaced (sandbox-escape watchout).
- `gitops/entry-states/m14/` (Helm, like `entry-states/m05`): 2 synthetic teammate SAs (`payments-ci`, `payments-ops` or similar) + a root-demanding Deployment (entry) and, at `ws solve`, the fixed non-root variant. In-namespace state only (quota/limits stay workshop-layer per `per-user-batch.yaml`'s G3-M06 lesson).

### App / image work
- A deterministic **root-demanding container** (stock image + `securityContext.runAsUser: 0`) for the SCC-rejection beat, and a **non-root "fixed" variant** (numeric USER, group-writable paths) for the "fix the image" path — the honest alternative to granting an SCC.

### Demo arc (spec)
- "Platform team gives a team a safe sandbox in 5 min": create ns → bind `edit`/`view` to team SAs → apply quota+limitrange (platform identity) → `who-can` audit; encore = root-image reject → scoped SCC grant redemption.

### Timing (90 min workshop)
- identity/RBAC model + teammate-SA grants + `who-can` ~25 · custom `deployer` Role ~10 · quota/limitrange exceed-and-fix ~15 · workload security (PSA/SCC, root reject, fix-vs-scoped-grant, bound token) ~25 · tenancy models + self-provisioning + project template `[INSTRUCTOR-DEMO]` ~15. Demo flavor 10-15 min.
