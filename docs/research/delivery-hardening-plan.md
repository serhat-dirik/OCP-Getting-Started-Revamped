# Delivery Hardening Plan — non-invasive install + full uninstall

Wave 1 of the packaging direction in `docs/research/field-sourced-content-note.md` §5–6. Goal: the
workshop installs onto an org's **existing** OpenShift cluster and later **fully uninstalls, reversing
every change**, never touching the org's pre-existing operators / config.

Status: **authored 2026-07-17, off-cluster (both clusters Unauthorized).** Everything below is
verified with local tooling only (`helm template`, `helm lint`, `kustomize build --enable-helm`,
`bash -n`). Nothing is cluster-verified — the `TODO(verify-on-cluster)` checklist (§6) is the plan for
when tokens return. `yamllint` / `shellcheck` could not be run locally (not installed; podman absent) —
new files were written to be clean by construction; CI is the backstop.

---

## 1. The two problems Wave 1 solves

1. **Enumeration.** On a shared cluster, an admin must be able to see the *entire* workshop footprint —
   including objects that live in namespaces the workshop does not own (`openshift`, `openshift-config`,
   `openshift-monitoring`). Solved by the **owner label** `workshop.redhat.com/owner: ogsr` on every
   workshop-created resource: `oc get <kind> -A -l workshop.redhat.com/owner=ogsr`.
2. **Reversibility without collateral damage.** Removing the workshop must not delete an operator or
   config the org already had, and must *restore* shared/default objects (not blindly delete them).
   Solved by (a) an **install-time state capture** of prior state + operator adoption, and (b) a
   **non-destructive uninstall** that orphans-then-selectively-deletes and restores from the record.

---

## 2. Architecture as implemented

### 2.1 Owner label — least-repetitive mechanism per layer

| Layer | Mechanism | Files |
|---|---|---|
| Portfolio components (kustomize) | `labels:` transformer, `includeSelectors:false`, `includeTemplates:false` — one edit stamps every resource the component renders | `platform-portfolio/components/*/kustomization.yaml` (31) |
| Portfolio stacks (kustomize) | `labels:` transformer stamps the child `pp-*` Applications | `platform-portfolio/stacks/*/kustomization.yaml` (15) |
| Parent stack Application | literal label in the sed template | `platform-portfolio/argocd-bootstrap/stack-app.template.yaml` |
| GitOps operator base | `labels:` transformer — applied **only in install.sh's create branch** (skipped when adopted), so the label lands only when we install GitOps | `platform-portfolio/argocd-bootstrap/operator/kustomization.yaml`, `operator/controller-rbac.yaml` |
| `workshop-config` Helm chart | new `_helpers.tpl` → `workshop-config.ownerLabels`; `{{- include … | nindent 4 }}` on every resource-root `metadata.labels` (260/260 resources render it) | `gitops/workshop-config/templates/_helpers.tpl` + 30 templates |
| Entry-state Helm charts (26) | literal `workshop.redhat.com/owner: ogsr` on every resource-root `metadata.labels` (345 resources) | `gitops/entry-states/m*/templates/*.yaml` (130 files) |
| Entry-state Applications | literal label in the `ws` app renderer | `tools/ws/ws` (`render_app`) |
| Imperative bootstrap objects | `owner_stamp()` pipes each `oc create … -o yaml` through `oc label --local` before apply | `bootstrap/install.sh` (htpasswd, MaaS, gitea creds secrets; `ogsr-system` ns; workshop-config App) |

Verified: `kustomize build --enable-helm` clean on all 47 kustomizations; `helm lint` + `helm template`
clean on all 27 charts; a YAML-parse audit over 521 rendered docs shows **0** owner labels leaked into
any `selector` / `matchLabels` / pod `template` (the label must never touch an immutable selector).

Node labels (`workshop.redhat.com/pool`, `/zone`) and the OAuth IdP list-entry **cannot carry a label**
(a node-label key and a JSON array entry are not label-bearing) — their record lives in the state
ConfigMap instead (§2.2).

### 2.2 Install-time state capture — `ogsr-uninstall-state`

`bootstrap/install.sh` now opens with a `[0/6]` step that creates namespace `ogsr-system` + ConfigMap
`ogsr-uninstall-state` (both owner-labeled) **before any mutation**, and records (all first-write-wins,
so the true prior state survives idempotent re-runs):

| Key | Meaning | Consumed by uninstall to… |
|---|---|---|
| `monitoring_cm_existed`, `monitoring_uwm_prior` | did `cluster-monitoring-config` exist; prior `enableUserWorkload` (`true`/`false`/`absent`) | restore UWM to prior, or delete the CM if we created it |
| `gitops_preexisted` | GitOps operator adopted vs created | remove GitOps only if created |
| `gitops_argocd_controller_resources_b64` | (adopted only) prior `spec.controller.resources` we overwrote | print for manual restore |
| `gatewayclass_preexisted` | `openshift-default` GatewayClass adopted vs created | delete only if created |
| `lightspeed_preinstalled`, `lightspeed_ns_created`, `lightspeed_secret_created` | Lightspeed adoption + whether we made the ns/secret | remove only what we created |
| `oauth_idp_ownedbyus` | did WE append the `workshop-users` IdP | remove that IdP entry only if ours |
| `nodes_batch`, `nodes_zoned` | which nodes we labeled/tainted (documentation; uninstall reverses by selector) | report |
| `installed_stacks` | the stacks install applied | re-derive the operator set from manifests |
| `op_<subscription>` | `created:<ns>` or `adopted:<ns>` per operator the installed stacks carry | remove created operators; preserve adopted |

`snapshot_operators()` derives the operator set from the **component subscription manifests** of the
installed stacks (no brittle hardcoded map): for each stack → child app → `spec.source.path` →
`components/<x>/subscription*.yaml` → `metadata.name`+`namespace` → `oc get subscription` presence.

### 2.3 Non-destructive uninstall — `bootstrap/ogsr-uninstall.sh`

Preflight (cluster-admin check, plan print, `--yes`/interactive gate, `--dry-run`), then 9 ordered steps:

1. **Disable automated sync** on every owner-labeled Application (pass 1) so no app-of-apps re-creates a
   child mid-teardown.
2. **Orphan + delete** every owner-labeled Application (pass 2): remove the resources-finalizer,
   `oc delete --cascade=orphan`. Component resources are orphaned, **never pruned** → an adopted
   operator is never collaterally deleted.
3. **Remove created operators'** Subscription + CSV (covers shared-namespace operators like
   `openshift-operators` whose namespace we never delete). Adopted/unknown → preserved + logged.
4. **Reverse imperative mutations**: remove the `workshop-users` OAuth IdP entry by index (preserving
   all other IdPs); delete `htpasswd-workshop-users`; Lightspeed secret/ns (only if we made them);
   restore `cluster-monitoring-config`; reverse node labels + batch taint by selector.
5. **GatewayClass** — delete only if created.
6. **Cluster-scoped owner-labeled** sweep: ClusterRoles/Bindings, Group, Kueue cluster objects.
7. **Shared-namespace owner-labeled**: `openshift/java-21` ImageStream (specific), AppProjects (labeled,
   across namespaces) — without deleting the shared namespaces.
8. **GitOps operator** — remove operator + `openshift-gitops`/`-operator` namespaces if created; else
   preserve and print the prior controller-resources for manual restore.
9. **Workshop namespaces** by owner label, skipping any **adopted-operator namespace** (from the state
   record) and `openshift-lightspeed` (own guard); then `ogsr-system` last.

Every deletion is dry-run aware, tolerant of already-absent objects, and prints a SKIP reason. Ends with
a commented verification block.

---

## 3. Key architecture friction — REPORT, did not redesign around

**The task's adoption-guard mechanism (FSC Helm `lookup` "skip-if-present" + a static
`ogsr.workshop.redhat.com/created-by-us: "true"` marker) does not fit this repo's kustomize + Argo CD
component architecture.** Two independent reasons:

1. **The ~15 operator components are kustomize, not Helm.** Kustomize has no cluster `lookup` — it cannot
   ask "does this operator already exist?" at render time. The FSC pattern
   (`examples/helm/components/operator/templates/subscription.yaml`) presumes Helm components.
2. **Even converted to Helm, Argo CD would not execute `lookup`.** Argo renders Helm charts with
   `helm template` (client-side), which does **not** perform cluster `lookup` — it returns empty. (The
   task note's assumption that "lookup runs server-side WITH cluster access when Argo renders it" is not
   how Argo CD works; `lookup` only queries the cluster during a real `helm install/upgrade`, which Argo
   does not use.) So a converted skip-if-present guard would render as "not present" every sync and
   still create/collide.

A **static** `created-by-us: "true"` marker on a kustomize operator manifest is also unsafe: because
Argo applies our labeled manifest onto a *pre-existing* (adopted) Subscription of the same name, the
marker (and any owner label) would land on the org's object too — so "adopted operators have no marker"
would be false, breaking the very invariant the marker exists to protect.

**What I implemented instead (same intent, mechanism that fits reality):** the **install-time state
capture** (§2.2) records adopted-vs-created per operator with real cluster knowledge, and the uninstall
treats that record as authoritative. This is strictly more robust than a static marker and is locally
reasoned (no lookup, no render-time cluster dependency). Consequences the PM should note:

- **Install collision is still possible on a shared cluster** if the org already runs one of our
  operators in a *dedicated namespace with its own OperatorGroup*: Argo will apply our OperatorGroup →
  `TooManyOperatorGroups`. Wave 1 **detects and records** this (adoption snapshot) so uninstall is safe,
  but does **not prevent** the collision at sync time. Prevention needs a real guard (below).
- **Label pollution on adopt:** if an operator is adopted, Argo stamps our owner label onto the org's
  Subscription/OG/namespace. Uninstall never *deletes* those (state-record gated), but it does not yet
  *strip* our label from them. See §5 deferred item.

**Recommended proper fix (Wave 2, needs owner blessing):** convert the operator install from
"Argo applies a kustomize Subscription+OG unconditionally" to one of:
(a) an **imperative pre-sync guard** (a small Job or a bootstrap step, cluster-aware) that creates the
Subscription/OG only when absent and stamps `created-by-us` truthfully; or
(b) drive operator installs through the **FSC root Helm chart** rendered by `helm install` (not Argo
`helm template`), where `lookup` genuinely works — the Wave-2 FSC wrapper is the natural home for this.
Until then, the state-record approach keeps uninstall safe and the collision is a documented
first-install caveat on clusters that already run the same operator dedicated-namespace-scoped.

---

## 4. What changed (paths)

- **Owner label:** all `platform-portfolio/components/*/kustomization.yaml` (31) and
  `platform-portfolio/stacks/*/kustomization.yaml` (15); `argocd-bootstrap/stack-app.template.yaml`,
  `argocd-bootstrap/operator/kustomization.yaml`, `argocd-bootstrap/operator/controller-rbac.yaml`;
  `gitops/workshop-config/templates/_helpers.tpl` (new) + 30 workshop-config templates;
  `gitops/entry-states/m*/templates/*.yaml` (130 files); `tools/ws/ws` (`render_app`).
- **State capture + adoption snapshot + imperative owner-stamps:** `bootstrap/install.sh`.
- **Uninstall:** `bootstrap/ogsr-uninstall.sh` (new).
- **Docs:** `README.md` (real install contract + Uninstall); `docs/sa-provisioning-guide.md` (uninstall
  runbook); this file.

---

## 5. Explicitly deferred (out of Wave-1 scope) — with rationale

- **`ogsr-` namespace rename** (`gitea → ogsr-gitea`, per-user namespaces, showroom, etc.). High
  Service-DNS/content/`ws`/verify ripple; attendee-visible names change; must be cluster-verified. The
  **owner label covers enumeration for Wave 1**, which is the immediate need. Owner-gated decision
  (note §7.4).
- **Wave-2 FSC wrapper** (root chart at an RHDP-pointable path, `demo.redhat.com/userinfo` ConfigMap,
  `demo.redhat.com/application` health labels, imperative→GitOps OAuth conversion, `litemaas`/
  `multi_user` value plumbing). Blocked on an RHDP test order + owner decisions (note §7). This is also
  the natural home for real operator-adoption guards (§3).
- **Operator install-collision *prevention*** (vs. the detection Wave 1 does). Needs the Wave-2 guard
  mechanism (§3). Today: documented first-install caveat.
- **Stripping our owner label from *adopted* operator objects on uninstall** (label pollution, §3). Small
  best-effort follow-up; low risk (a stray label is inert), but violates the strict "nothing of theirs
  differs" litmus. Backlog.
- **Auto-restore of the adopted GitOps ArgoCD `controller.resources`** and of a **pre-existing
  `cluster-monitoring-config` that had no `enableUserWorkload` key**. Both are recorded and the uninstall
  *reports* them for manual restore; safe auto-restore of a nested config.yaml block scalar / a jsonpath
  Go-map string without `jq` is fragile — deferred rather than done wrong. The common cases (we created
  the CM; we created GitOps) *are* auto-handled.

---

### Verified on C1 (2026-07-17 pass) — two operational facts the checklist below must respect

- **Two GitOps sources, two propagation paths.** The `pp-*` portfolio apps track **GitHub upstream**
  (auto-poll + selfHeal), while workshop content + entry-states track the **in-cluster Gitea mirror**.
  `ws git-refresh` therefore propagates content/entry-state changes but does NOT drive `pp-*` — those
  pick up pushed commits on their own poll. "Re-sync to propagate" means different things per layer.
- **CRD ambiguity in enumeration commands:** on a cluster with Serverless installed, bare `subscription`
  resolves to `subscriptions.messaging.knative.dev` and returns zero rows — a false negative. Always use
  the full `subscriptions.operators.coreos.com` in owner-label enumeration.

## 6. TODO(verify-on-cluster) — the on-cluster checklist for when tokens return

Local tooling cannot exercise any `oc` path. Verify all of the following on a disposable cluster:

**Install (idempotency + capture):**
1. `bootstrap/install.sh` run twice → `ogsr-uninstall-state` CM keys are stable (first-write-wins holds);
   re-run does not flip an operator's `op_*` from created→adopted.
2. `oc get cm ogsr-uninstall-state -n ogsr-system -o yaml` → sane values for monitoring/gitops/
   gatewayclass/oauth/lightspeed/operators on both a greenfield and an operator-pre-loaded cluster.
3. `owner_stamp` actually labels the 3 secrets + `ogsr-system` ns + workshop-config App
   (`oc get secret htpasswd-workshop-users -n openshift-config --show-labels`).
4. `oc get <kind> -A -l workshop.redhat.com/owner=ogsr` returns the full footprint (spot-check the
   cluster-scoped ones: Group, platform-observer CR/CRB, java-21 IS, Kueue objects, AppProjects).

**Uninstall (the whole script — none of it is locally verifiable):**
5. `ogsr-uninstall.sh --dry-run` plan matches reality on a real install.
6. Orphan-not-prune: after uninstall, an **adopted** operator (pre-load e.g. cert-manager, then install)
   is still `Succeeded`; `oc get csv -A` shows it intact.
7. OAuth IdP: `workshop-users` removed, **all other IdPs preserved** (pre-load a second IdP and confirm).
8. `cluster-monitoring-config` restore across all four cases (cm absent / prior true / false / key-absent).
9. Node labels + batch taint fully gone (`oc get nodes -L workshop.redhat.com/pool,workshop.redhat.com/zone`;
   `oc describe node <batch> | grep Taints`).
10. GitOps + GatewayClass removed when created / preserved when adopted (test both).
11. Namespaces: workshop ns gone; adopted-operator ns preserved; `oc get ns -l …owner=ogsr` empty.
12. Idempotency: run `ogsr-uninstall.sh --yes` twice → clean, all SKIP on the second pass.
13. **shellcheck** `bootstrap/ogsr-uninstall.sh` + `bootstrap/install.sh` (CI runs it; not run locally).

---

## 7. Owner decisions needed

1. **Operator-adoption fix strategy (§3):** bless the Wave-2 direction (imperative pre-sync guard or FSC
   `helm install` path) for real skip-if-present, or accept the documented first-install collision caveat
   for clusters already running our operators dedicated-namespace-scoped.
2. **`ogsr-` namespace rename (§5):** owner-gated; attendee-visible names change. Do we do it, and when?
3. **`created-by-us` marker:** I record adoption in the state ConfigMap (authoritative) instead of a
   static per-operator label, because the static label is unsafe under kustomize+Argo (§3). Confirm this
   substitution is acceptable, or we take the Wave-2 guard that makes a truthful label possible.

---

## 8. Note on CLAUDE.md doc-drift

`README.md` is fixed to the real install contract (`cp vars.example.yaml vars.yaml` → edit →
`./install.sh`; no CLI flags). `CLAUDE.md` line 46 carries the same stale example
(`./bootstrap/install.sh --profiles core[,…] --users N --domain …`). I did **not** edit `CLAUDE.md`
(it is the session operating card / protected config; an agent task does not authorize changing it).
**Applied by the maintainer in commit `4ee4b52`** — the fix that landed:

> `- Stand up a cluster: cp bootstrap/vars.example.yaml bootstrap/vars.yaml`, edit it, then `./bootstrap/install.sh` (reads vars.yaml; no flags). Uninstall: `./bootstrap/ogsr-uninstall.sh`
