# Field-Sourced Content (FSC) + Standalone-Install Integration Note

Research analyst note for PM packaging decision. Date: 2026-07-11. Author: research-analyst
(returned as text per agent constraints; saved in-tree verbatim by the PM).
No cluster work performed. No content changed.

---

## 0. Verified versions / platform facts (source + date)

All RHDP/AgnosticD facts verified 2026-07-11 by reading raw files via `gh api` on the public repos named. These are tooling facts (not workshop product SKUs), so they are **not** tracked in `versions.yaml`.

| Fact | Value | Source | Date |
|---|---|---|---|
| FSC template repo (reference copy) | `rhpds/field-sourced-content-template`, default branch `main`, pushed 2026-01-23 | `gh api repos/rhpds/field-sourced-content-template` | 2026-07-11 |
| **Production** field-content role (has MaaS + multi-user; template lacks both) | `rhpds/core_workloads` → `roles/ocp4_workload_field_content/` | `gh api repos/rhpds/core_workloads/contents/roles/ocp4_workload_field_content/{defaults,tasks/workload}.yml` | 2026-07-11 |
| RHDP catalog item to order | "Field Sourced Content — OpenShift Base", `babylon-catalog-prod/published.ocp-field-asset.prod` | hyperledger README §"Option A" (`serhat-dirik/hyperledger-on-openshift-demo/README.md`) — confirm live | 2026-07-11 |
| "lite MaaS" = LiteMaaS | `rhpds/rhpds.litemaas` (role `ocp4_workload_litemaas`); virtual keys `rhpds/rhpds.litellm_virtual_keys` | `gh api -X GET search/code q='org:rhpds lite maas'`; `rhpds.litellm_virtual_keys/README.md` | 2026-07-11 |
| LiteMaaS production endpoint cluster | `maas-rdhp` (old `litellm-rhpds` **decommissioned 2026-06-21** — treat any doc citing it as STALE) | `rhpds.litellm_virtual_keys/README.md` (CRITICAL NOTICE) | 2026-07-11 |
| Showroom deployer chart | `rhpds/showroom-deployer` `showroom-single-pod` `^2.0.0`; content `showroom-content`, terminal `openshift-showroom-terminal-ocp` | `field-sourced-content-template/docs/SHOWROOM-UPDATE-SPEC.md` | 2026-07-11 |
| Our target min OCP for standalone | OpenShift **4.20+** (EUS) with cluster-admin | `platform-portfolio/README.md` line 3; `versions.yaml` `ocp` | 2026-07-08/11 |
| Our showroom stack (already built, newer than template) | nookbag `v0.3.7`, content `v1.4.2`, terminal `2026-04-07` | `gitops/workshop-config/values.yaml` lines 54–61 | 2026-07-10 |
| Red Hat build of Keycloak (M13 synergy) | new-install target `rhbk-operator.v26.6.4-opr.1`, channel `stable-v26.6` | `versions.yaml` `rhbk`; `docs/research/m13-build-note.md` | 2026-07-09 |

Product-doc anchors for MaaS (verify at build): docs.redhat.com RHOAI "Govern LLM access with Models-as-a-Service"; redhat.com/en/blog "Protecting enterprise AI: How to manage API keys in Models-as-a-Service (MaaS)".

---

## 1. The FSC contract (summary, with sources)

RHDP's "Field Sourced Content" is a self-service way to run **your own GitOps repo** on an RHDP-provisioned OpenShift cluster. The whole contract:

1. **You publish a Helm chart** (root of repo or a sub-path). Source: `field-sourced-content-template/README.md`, `project-documentation.md`.
2. **You order the "Field Sourced Content — OpenShift Base" catalog item** and give three parameters:
   - `GitOps Repo URL` (required — `ocp4_workload_field_content_gitops_repo_url`)
   - `GitOps Path` (default = repo root — `..._gitops_repo_path`)
   - `GitOps Revision` (default `main` — `..._gitops_repo_revision`)
   Source: `core_workloads/.../defaults/main.yml`; hyperledger README "Option A".
3. **The platform applies exactly one thing**: an ArgoCD `Application` named **`field-content`** in namespace **`openshift-gitops`**, pointing at your repo/path/revision. Source: `core_workloads/.../templates/application.yaml.j2`, `tasks/workload.yml`.
4. **Order of operations**: RHDP provisions the cluster + installs OpenShift GitOps first, then the workload role creates the `field-content` Application. It is **"fire and forget"** — the role verifies the Application is *accepted* within ~1 min and does **not** wait for Synced/Healthy. `syncPolicy.automated` with `prune: false, selfHeal: false, CreateNamespace=true`. Source: `core_workloads/.../defaults/main.yml` (deployment-behavior block), `application.yaml.j2`. Consequence (documented in hyperledger README): RHDP shows "Ready" ~1 min in, but child apps keep deploying for ~25 min.
5. **Auto-injected Helm values** your chart can rely on:
   - `deployer.domain` (= `openshift_cluster_ingress_domain`, e.g. `apps.cluster.example.com`)
   - `deployer.apiUrl` (= `openshift_api_url`, e.g. `https://api…:6443`)
   - `gitops.repoURL` / `gitops.revision` / `gitops.path` (self-reference so your app-of-apps children can point back at the same repo)
   - `litemaas.{enabled,apiUrl,apiKey,model}` — **only when a MaaS key was provisioned** (see §3)
   - `multi_user.{num_users,users[]}` — **only when multi-user was requested** (see §4)
   Source: `core_workloads/.../tasks/workload.yml` (the `combine` chain).
6. **App-of-apps convention**: your root chart emits N child `Application` CRs (one per component: operators, apps, showroom), each pointing at a `components/<x>` path. Source: `field-sourced-content-template/examples/helm/templates/applications.yaml`.
7. **Two required RHDP integration labels**:
   - `demo.redhat.com/application: "<name>"` on resources → **health monitoring**.
   - `demo.redhat.com/userinfo: ""` on a **ConfigMap** → RHDP reads its `data` keys and shows them to the requester (URLs, credentials, instructions). Source: `README.md` "RHDP Integration", `examples/helm/components/hello-world/templates/userinfo.yaml`, `docs/ansible-developer-guide.md`.
8. **Showroom** is just one component you deploy (single-pod: `git-cloner` init → `antora` build → `nginx` + `content`(nookbag) + `ttyd` terminal, fronted by a Route). **Single-user only** in the template pattern. Source: `examples/helm/components/showroom/templates/showroom.yaml`, `docs/SHOWROOM-UPDATE-SPEC.md` ("What NOT to Update: Multi-user deployments — only single-user mode").
9. **Helm or Ansible**: a chart may also carry ansible-runner Jobs for wait-for-ready / API calls / secret generation, ordered by Argo sync-waves. Source: `docs/ansible-developer-guide.md`. Variables given to ansible: `cluster_domain`, `cluster_api_url`, `namespace`.
10. **Uninstall is NOT implemented** by the workload role (`remove_workload.yml` prints "Removing this workload is not implemented"). De-provisioning = RHDP deletes the whole cluster. Source: `core_workloads/.../tasks/remove_workload.yml`.

**Key subtlety for us:** the FSC platform performs **zero imperative `oc`**. Everything you need must be expressible as GitOps (Helm manifests + optional in-cluster Jobs). Our current bootstrap does several imperative acts at install time — that is the central gap (§2, §5).

---

## 2. Reference implementation map — `serhat-dirik/hyperledger-on-openshift-demo`

This repo is a **near-exact template for what we would ship**, and it uses the *same two-phase Gitea-mirror pattern our own `bootstrap/install.sh` already uses*. FSC-readiness mapping:

| FSC-ready element | File | What it does |
|---|---|---|
| Root chart entrypoint RHDP points at | `helm/bootstrap/` (order param `GitOps Path: helm/bootstrap`) | Phase-1 chart |
| RHDP-injected values consumed | `helm/bootstrap/values.yaml` (`deployer.domain`/`deployer.apiUrl` "set by platform, do not hardcode") | |
| App-of-apps entrypoint | `helm/bootstrap/templates/applications.yaml` | Emits Gitea (wave 0) + mirror Job (wave 1) + 5 child Applications (wave 2) |
| Data-back to RHDP | same file: `certchain-userinfo` ConfigMap labelled `demo.redhat.com/userinfo: ""` | Emits `showroom_url`, `cert_portal_url`, `argocd_url`, `gitea_url`, `cluster_domain` |
| Health label | `demo.redhat.com/application: "certchain"` on every child Application | |
| Showroom component | `helm/components/showroom/` + `showroom/site.yml` (8 browser tabs) | The chart our `gitops/workshop-config/templates/showroom.yaml` is explicitly adapted from (see its header comment) |
| Standalone fallback install | `scripts/install.sh --gitea` or `--repo-url <fork>` | BYO-cluster path, OCP 4.16+ |
| Prereq gate | `scripts/check-prerequisites.sh` | tools/version/perms/capacity |
| Uninstall | `scripts/teardown-all.sh` | Deletes Argo apps + Helm releases + the 5 project namespaces; **explicitly does NOT remove the GitOps operator** ("it may be shared with other workloads") |
| Namespace-prefix idea | `env.sh` `PROJECT_NAMESPACE="certchain"` → org namespaces `certchain-<org>` | Exactly the pattern for our `ogsr-` requirement |

Takeaway: we do **not** need to invent the FSC shape — we need to wrap our existing `platform-portfolio` + `workshop-config` in one root chart that mirrors `helm/bootstrap`, and add a UserInfo ConfigMap. Its teardown script is the model for our non-destructive uninstall (§5).

---

## 3. The MaaS key answer (the project owner's explicit question) — MECHANISM FOUND

**"Lite MaaS Model API Key" = LiteMaaS** (`rhpds/rhpds.litemaas`), a LiteLLM-based Models-as-a-Service. Per-lab keys are issued by the `rhpds.litellm_virtual_keys` collection (role `ocp4_workload_litellm_virtual_keys`), which creates a key `virtkey-{GUID}` against the production endpoint cluster **`maas-rdhp`**.

**Where the platform puts the token/URL — the precise answer:** *not* in a Secret or ConfigMap that the platform creates. It flows as **Helm values on the `field-content` ArgoCD Application**. The chain (all verified in source):

1. `ocp4_workload_litellm_virtual_keys` provisions the key and publishes structured facts via `agnosticd_user_info`/`agnosticd_user_data`: `litellm_api_base_url` (e.g. `https://maas-rdhp.apps…/v1`), `litellm_virtual_key` (`sk-…`), `litellm_available_models`, `litellm_key_duration`. Source: `rhpds.litellm_virtual_keys/README.md` ("User Info Data").
2. The **production** `ocp4_workload_field_content` reads them from `agnosticd_user_data` into role vars `ocp4_workload_field_content_litemaas_api_url` / `_api_key` / `_model` (default model **`llama-scout-17b`**). Source: `core_workloads/.../defaults/main.yml` (LiteMaaS/MaaS block).
3. The role injects them into the Application's Helm values as a **top-level `litemaas` map**, or `litemaas.enabled: false` if absent. Source: `core_workloads/.../tasks/workload.yml`:
   ```yaml
   litemaas:
     enabled: true
     apiUrl: <api_url>   # OpenAI-compatible base, ends in /v1
     apiKey: <api_key>   # sk-...
     model: <model>      # default llama-scout-17b
   ```

**So the contract our chart must satisfy:** accept `.Values.litemaas.{enabled,apiUrl,apiKey,model}` and *itself* materialize whatever Secret/env our workloads read. This maps cleanly to our standalone path, where `bootstrap/install.sh` already creates `secret/credentials {apitoken:<key>}` in `openshift-lightspeed` (lines 122–130) — under FSC that secret must be rendered by the chart from `litemaas.apiKey` instead. The LiteMaaS endpoint is OpenAI/vLLM-compatible, so it wires to Lightspeed's `OLSConfig` provider `rhoai_vllm` (url + `apitoken` secret) — consistent with `versions.yaml` `lightspeed` notes.

**Important caveat (template vs production):** the public `field-sourced-content-template` repo is a **"reference copy"** (its `roles/.../meta/main.yml` says so) and **does NOT contain the LiteMaaS wiring** — only `rhpds/core_workloads` does. Do not design against the template's role.

**What remains UNVERIFIED (needs an RHDP test order):** the exact requester-facing form — i.e. whether "lite MaaS Model API Key" is a checkbox on the Field-Content catalog item itself vs. a property of the base OpenShift CI — lives in the private Babylon/AgnosticV catalog config, which the analyst cannot read. The *injection mechanism* above is verified; the *order-form surface* is not.

---

## 4. User provisioning — options table + recommendation

**What FSC offers:** the production field-content role passes a **`multi_user` values block** (`num_users`, `users: [{username: user1}, …]`) into your chart when `create_multi_user`/`num_users` are set on the order (source: `core_workloads/.../tasks/workload.yml`). This tells your chart *how many users exist and their names* — it does **not**, by itself, prove the base CI creates htpasswd identities. Whether the RHDP base CI stands up the htpasswd IdP + `userN` logins is **UNVERIFIED** (base-CI AgnosticV, needs a test order). Our current bootstrap creates them itself.

| Option | Mechanism | Pros | Cons | Fit |
|---|---|---|---|---|
| **A. Platform users (FSC `multi_user`)** | Order asks for N users; role passes `multi_user.num_users/users` as Helm values; (assumed) base CI creates htpasswd `userN` | Zero user-mgmt code for us; RHDP-native; console login "just works" if base CI provisions them | htpasswd creation by base CI unconfirmed; only a **values contract**, not identities we can guarantee; no OIDC/roles for app-auth labs | FSC path |
| **B. Own Keycloak (Red Hat build of Keycloak)** | Small shared RHBK in our namespace; per-user realms; add an OpenID IdP to `oauth/cluster` for console login | Portable across ANY cluster; real OIDC = curriculum for M13/M14; one identity for console AND apps | We own IdP lifecycle; must patch `oauth/cluster` (imperative or Job); ~2 pods (KC+Postgres) footprint | Both paths; best for standalone |
| **C. Current htpasswd (status quo)** | `bootstrap/install.sh` builds htpasswd secret + appends `workshop-users` IdP to `oauth/cluster` (append-if-absent) | Works today; simple; idempotent; preserves pre-existing IdPs | Imperative (not GitOps-expressible for FSC); no app-auth story | Standalone only |

**M13 synergy:** M13 already plans a **new, shared, workshop-owned Red Hat build of Keycloak** as `platform-portfolio/components/keycloak` + `stacks/auth` (Subscription `rhbk-operator` `stable-v26.6` + `Keycloak` CR + Postgres), with **one realm per user** via `KeycloakRealmImport realm-{user}` using `spec.placeholders` for per-user redirect URIs (`docs/research/m13-build-note.md`). That instance is designed for **app login**; the project owner's "workshop users log in via KC" idea additionally wants **console login** — achievable by pointing `oauth/cluster` at the same RHBK (an OpenID IdP), which is what the live RHDP cluster already does for its admin login. Live cluster login IdP is `keycloak/sso` — **read-only, do not reuse**.

**Recommendation:** **Option B, built once, consumed by both paths, sequenced after M13's `auth` stack lands.** Promote M13's `components/keycloak` to also serve **console** login (opt-in overlay). Standalone path uses it directly; FSC path keeps Option A (`multi_user` values) as the default but can layer B for AI/auth-heavy events. Keep current htpasswd (C) as the zero-dependency default until the RHBK stack is proven.

---

## 5. Fallback (standalone) install-script contract — draft

the project owner's verbatim constraints: (a) **every project we create — showrooms included — gets an `ogsr-` prefix**; (b) target clusters **may already have** our operators (GitOps, Pipelines) — **adopt/skip, never fight or duplicate**, and **uninstall must not destroy pre-existing platform components**.

### 5.1 Prereqs (from `bootstrap/install.sh` preflight + `platform-portfolio/README.md`)
- OpenShift **4.20+**, cluster-admin (`oc auth can-i '*' '*'`).
- Local tools: `oc`, `yq` (mikefarah v4), `htpasswd`, `openssl`. (For BYO-repo also `git`.)
- Internet-reachable cluster (pulls quay.io/github images + Gitea mirror).
- Default StorageClass (showroom + Gitea PVCs).

### 5.2 Parameters (already in `bootstrap/vars.yaml` / portfolio flags)
`--profiles core[,ai-assist,trust,observability,batch,auth,…]` · `--users N` · `--domain <apps.…>` (auto-detected if omitted) · `--lightspeed true|false` · `--maas-key <sk-…>` (or `litemaas.apiUrl/apiKey/model`) · `--repo-url` / `--revision` · `--workshop-password <pw|generate>`.

### 5.3 `ogsr-` naming — what changes (files to touch; do NOT change mid-wave)
**Prefix these workshop-created namespaces** (currently unprefixed — verified none carry `ogsr-`):
- `gitea` → `ogsr-gitea`; `showroom` → `ogsr-showroom`; `student-gitops` → `ogsr-student-gitops`; `parasol-tasks` → `ogsr-parasol-tasks`; `parasol-images` → `ogsr-parasol-images`; `observability-workshop` → `ogsr-observability-workshop`. Sources: `gitops/workshop-config/values.yaml` (giteaNamespace, showroom.namespace), `bootstrap/install.sh` `GITEA_NS`, various `platform-portfolio/components/*/namespace.yaml`.
- Per-user sandboxes `{user}-dev/stage/prod/cicd` (`gitops/workshop-config/templates/per-user-namespaces.yaml`) and entry-state namespaces (`parasol-claims`, `parasol-web`, `parasol-claims-supply-chain`, `parasol-claims-build-test-deploy`, `user-queue` under `gitops/entry-states/*`) — **scope question for the project owner** (attendee-visible names lengthen).
- **Do NOT prefix** product-canonical operator namespaces (`openshift-gitops`, `openshift-operators`, `cert-manager-operator`, `stackrox`, `openshift-logging`, `openshift-lightspeed`, `rhdh`, `openshift-tempo-operator`, etc.) — OLM/products own those names; renaming breaks installs.
- **Belt-and-suspenders:** because operator namespaces can't be renamed, also stamp **every resource we create with a common owner label** (e.g. `workshop.redhat.com/owner: ogsr`) so admins can find our footprint even inside shared namespaces. Model: hyperledger's `app.kubernetes.io/part-of: certchain`.

### 5.4 Operator adoption — the real gap
**Already adopts** (good, keep): OpenShift GitOps (`platform-portfolio/argocd-bootstrap/install.sh` lines 50–54 — checks the subscription, reuses it) and OpenShift Lightspeed (`bootstrap/install.sh` lines 77–82 — checks `olsconfig`).

**Does NOT adopt (greenfield-assumption defects):** the ~15 component operators install a Subscription (+ for dedicated-namespace ones an OperatorGroup) with no "already present?" guard. If the target already has the operator:
- **Install collision (TooManyOperatorGroups):** every dedicated-namespace OperatorGroup — `platform-portfolio/components/{rhacs-operator,opentelemetry,kueue,cluster-observability-operator,cert-manager,loki-logging(×2),openshift-lightspeed,keda,tempo,rhdh-operator,rhtas,rhtpa}/operatorgroup*.yaml` — fails if that operator preexists in its namespace with its own OG.
- **Ownership fight (shared namespace):** `openshift-pipelines`, `devspaces`, `web-terminal` Subscriptions target `openshift-operators` (rely on the global OG). If the operator preexists, Argo tries to own the existing Subscription → OutOfSync churn.
- **Fix pattern (already known in-repo + shown by FSC):** the FSC template's operator component does `lookup … Subscription; {{- if not $existingSub.metadata }}` (skip if present) — `field-sourced-content-template/examples/helm/components/operator/templates/subscription.yaml`; the ansible variant checks `k8s_info` first. Propagate that guard to each component (or gate the OperatorGroup on "no existing OG in namespace").

### 5.5 Non-destructive uninstall — the second real gap
Today: our stacks (`stack-app.template.yaml`) and `workshop-config` use `prune: true, selfHeal: true`. Deleting a stack Application **prunes the Subscription/OperatorGroup/namespace** — which would delete an operator that *pre-existed*. That violates constraint (b).
Draft `ogsr-uninstall.sh` (model: hyperledger `teardown-all.sh`):
1. Delete only **our** Argo Applications (`workshop-config`, `pp-*`, entry-state apps) and Helm releases.
2. Delete only **`ogsr-`-prefixed** namespaces + resources carrying our owner label.
3. For operators: only remove Subscriptions/OGs/namespaces this install **created** (track via an annotation `ogsr.workshop.redhat.com/created-by-us: "true"` set only when the adoption guard installed it). **Never** delete GitOps operator, nor any operator/namespace we adopted. Print what was skipped and why.
4. Verify: `oc get ns | grep ogsr-` empty; adopted operators still present.

---

## 6. Integration recommendation — FSC-first, script-first, or both

**Recommendation: BOTH, script-first, then a thin FSC wrapper.** The two paths share ~90% of the machinery (same `platform-portfolio` stacks + `workshop-config` layer + showroom). They differ only at the entrypoint and in how imperative steps are handled.

- **Wave 1 — harden the standalone/script path (effort: ~1–3 days, we own all the code).** Delivers the project owner's verbatim constraints regardless of RHDP: `ogsr-` prefixing + owner label; operator-adoption guards on the ~15 components; non-destructive `ogsr-uninstall.sh`. Bonus: makes us a good tenant on *any* cluster, including RHDP-provisioned ones. Low-risk: nothing depends on unverifiable RHDP internals.
- **Wave 2 — add the FSC wrapper (effort: ~2–4 days; the imperative→GitOps conversion is the crux).** Create one root Helm chart (mirror hyperledger `helm/bootstrap`) at a repo path RHDP can point `field-content` at, that: (1) accepts `deployer.*`, `litemaas.*`, `multi_user.*` values; (2) emits our existing stacks + workshop-config as child Argo apps; (3) emits a `demo.redhat.com/userinfo` ConfigMap (showroom URL, console, gitea, users, password) + `demo.redhat.com/application` health labels; (4) **GitOps-ifies the imperative bootstrap steps** — the htpasswd secret + `oauth/cluster` IdP patch + MaaS secret currently done by `oc` in `bootstrap/install.sh` must become in-chart Jobs (FSC ansible-runner pattern) *or* be replaced by platform `multi_user`/`litemaas` inputs. Items (1)–(3) are trivial; item (4) is the entire risk of this wave.

Why not FSC-only: FSC de-provisioning = destroy the cluster, and it forbids imperative `oc` — a poor fit for BYO/partner clusters and for our IdP patching. Why not script-only: we'd forgo one-click RHDP ordering that the hyperledger demo proves works for this exact architecture.

---

## 7. Open questions — only the project owner / RHDP can answer

1. **RHDP test order needed:** does the Field-Content catalog item expose a "lite MaaS Model API Key" checkbox itself, or is MaaS provisioned by the base OpenShift CI? And does the base CI create htpasswd `userN` identities (vs. only passing the `multi_user` values)?
2. **Catalog item confirmation:** is `published.ocp-field-asset.prod` still the current FSC item, and what OCP version/size does it provision?
3. **MaaS entitlement/quota:** which LiteMaaS package/model tier do we target (`llama-scout-17b` default vs. a Granite model), and is per-attendee token quota enough for a full AI module?
4. **`ogsr-` scope decision:** do per-user sandbox namespaces (`{user}-dev/…`) get renamed to `ogsr-{user}-dev` (changes attendee-visible names) or is the owner-label sufficient for those? Attendee-UX call for the project owner.
5. **Console-login-via-Keycloak:** approve promoting M13's `auth`/RHBK stack to also back OpenShift console login (adds an `oauth/cluster` OpenID IdP binding)? Cluster-OAuth change — Decision-Record territory.

---

## Open risks

- **Template vs production divergence:** the public FSC template lacks MaaS + multi-user; only `rhpds/core_workloads` has them. If RHDP runs an older `core_workloads`, the `litemaas`/`multi_user` values may differ. Re-verify against a live order at build time.
- **Imperative-to-GitOps conversion (Wave 2, item 4)** is the only hard part and touches cluster OAuth — highest-risk change; keep it behind a Job + idempotent guard, test on the disposable cluster only.
- **`prune: true` everywhere** means the uninstall gap is a *live* footgun today on any shared cluster — first thing to fix in Wave 1.
- **MaaS endpoint churn:** `litellm-rhpds` decommissioned 2026-06-21; any mined doc referencing it is stale. Pin to `maas-rdhp`.
- Everything verified from source files/URLs as of 2026-07-11; §7 items are explicitly UNVERIFIED, gated on an RHDP test order or a project decision.

---

Sources (external): [rhpds/field-sourced-content-template](https://github.com/rhpds/field-sourced-content-template) · [rhpds/core_workloads (production field_content role)](https://github.com/rhpds/core_workloads) · [serhat-dirik/hyperledger-on-openshift-demo](https://github.com/serhat-dirik/hyperledger-on-openshift-demo) · [rhpds/rhpds.litemaas](https://github.com/rhpds/rhpds.litemaas) · [rhpds/rhpds.litellm_virtual_keys](https://github.com/rhpds/rhpds.litellm_virtual_keys) · [rhpds/openshift_ai_maas](https://github.com/rhpds/openshift_ai_maas) · [Field Sourced Content — OpenShift Base catalog item](https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/published.ocp-field-asset.prod) · [RHOAI: Govern LLM access with MaaS](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas) · [Red Hat blog: managing API keys in MaaS](https://www.redhat.com/en/blog/protecting-enterprise-ai-how-manage-api-keys-models-service-maas)
