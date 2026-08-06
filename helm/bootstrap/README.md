# ogsr-bootstrap — Field-Sourced-Content entrypoint

This Helm chart is the one thing Red Hat Demo Platform (RHDP) points at to stand up the
**OpenShift Application Platform: Getting Started** workshop. RHDP's *Field Sourced Content*
workflow applies a single Argo CD `Application` (named `field-content`) that renders this
chart; the chart then does everything else declaratively:

- deploys the in-cluster **Gitea mirror anchor** and mirrors this repo into it (git-localize);
- deploys the **platform-portfolio stacks** and the **workshop-config layer** as child Argo CD
  Applications (app-of-apps), sourced from that in-cluster mirror;
- GitOps-ifies the imperative steps `bootstrap/install.sh` does with `oc` — htpasswd users +
  OAuth IdP, the MaaS secret, node shaping, and the `ogsr-uninstall-state` capture — as
  in-cluster Jobs;
- publishes a `demo.redhat.com/userinfo` ConfigMap so RHDP shows the requester their per-user
  Showroom URLs, the console/Gitea/Argo CD URLs, the roster, and the shared password.

Nothing here is duplicated from the portfolio: the stacks and the workshop layer are **reused**
as child Application sources.

---

## Prerequisites

- OpenShift **4.20+** with cluster-admin.
- **OpenShift GitOps** installed (RHDP installs it before `field-content`; on a BYO cluster
  install it first — `platform-portfolio/argocd-bootstrap/install.sh` does this).
- Internet-reachable cluster (pulls the mirror source, operator catalogs, and Job images).
- A default StorageClass (Gitea + Showroom PVCs).

---

## Option A — Red Hat Demo Platform (recommended)

Order the **Field Sourced Content — OpenShift Base** catalog item and give it three parameters:

| Order parameter    | Value                                                              |
|--------------------|-------------------------------------------------------------------|
| **GitOps Repo URL**  | `https://github.com/serhat-dirik/OCP-Getting-Started-Revamped.git` |
| **GitOps Path**      | `helm/bootstrap`                                                   |
| **GitOps Revision**  | `main`                                                             |

RHDP provisions the cluster, installs OpenShift GitOps, injects `deployer.*` / `gitops.*`
(and `litemaas.*` / `multi_user.*` when provisioned), and creates the `field-content`
Application. It reports **Ready** about a minute later — but the child Applications keep
deploying for roughly **15-25 minutes** after that. Watch them in the Argo CD UI (the
`argocd_url` in the UserInfo panel) or with:

```
oc get applications -n openshift-gitops
```

By default the whole workshop is delivered and every platform stack the modules need is
installed. To run a shorter workshop, set `modulesDisabled` on the order (module numbers or
slugs) — the disabled modules are hidden from the cockpit and any stack needed only by them is
skipped, e.g. `modulesDisabled={m19,m20,m21,m22,m23,m24,m25}`. For the MaaS assistant, set
`litemaas.enabled=true` with `litemaas.apiUrl` + `litemaas.apiKey` (Lightspeed auto-skips when
they are absent). The per-stack `stacks.*` booleans remain only as expert additive overrides.

---

## Option B — Bring Your Own Cluster

Any OpenShift 4.20+ cluster with cluster-admin.

**B1 — the standalone installer (proven path).** Uses the imperative-but-idempotent
`bootstrap/install.sh`, which performs the same work this chart expresses declaratively:

```
cp bootstrap/vars.example.yaml bootstrap/vars.yaml     # edit: users, domain, maas, password
./bootstrap/install.sh                                  # reads vars.yaml; no flags
./bootstrap/ogsr-uninstall.sh                           # non-destructive uninstall
```

**B2 — GitOps-native (this chart, via your own Argo CD).** On a cluster that already has
OpenShift GitOps, apply a `field-content` Application yourself — exactly what RHDP does. This
preserves the chart's sync-wave ordering:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: field-content
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/serhat-dirik/OCP-Getting-Started-Revamped.git
    targetRevision: main
    path: helm/bootstrap
    helm:
      valuesObject:
        deployer:
          domain: apps.CLUSTER.example.com      # your ingress apps domain
          apiUrl: https://api.CLUSTER.example.com:6443
        multi_user:
          num_users: 5
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true]
```

Uninstall (B2) is the same `./bootstrap/ogsr-uninstall.sh` — it reads the `ogsr-uninstall-state`
ConfigMap this chart's capture Job wrote.

It normally deletes `ogsr-system` (and that ConfigMap) at the end. It **keeps** both when it could
not put some prior value back: the ConfigMap is pruned to exactly those values and stamped with
`residue_keys`, because it is the only record of them — delete it and the next install snapshots the
workshop's own leftover as the org's original. The capture Job honours that: `record_once` skips
every key named in `residue_keys`, present or absent. Restore what `residue_notes` lists, then
`oc delete namespace ogsr-system`. Gated by `tools/lint/uninstall-state-lifetime-guard.sh`.

---

## What gets deployed (sync-wave order)

| Wave | Kind         | Name(s)                                  | Purpose |
|-----:|--------------|------------------------------------------|---------|
| -20  | ns/SA/CRB    | `ogsr-system`, `ogsr-bootstrap`          | groundwork the Jobs run as |
| -10  | Job (hook)   | `ogsr-state-capture`                     | records prior state → `ogsr-uninstall-state` |
| -9   | Job (hook)   | `ogsr-adopted-protection`                 | annotates every adopted resource `Prune=false,Delete=false` |
| -9   | Job (hook)   | `ogsr-argocd-health-tuning`               | application-controller sizing + Subscription health check |
| -9   | Job (hook)   | `ogsr-node-shaping`                       | batch pool + synthetic zones (deployment-targets-scheduling / resilience-multicluster-dr) |
| -8   | Job (hook)   | `ogsr-workshop-users` / `ogsr-maas-secret` | htpasswd + OAuth IdP / MaaS secret |
| -1   | ConfigMap    | `ogsr-userinfo`                           | `demo.redhat.com/userinfo` (URLs, roster, password) |
| 0    | Application  | `pp-core-devtools`                        | **mirror anchor**: gitea + git-mirror + dev tooling (from GitHub) |
| 1    | Application  | `pp-batch` (+ `pp-ai-assist`/`pp-auth`/`pp-resilience`) | platform stacks, from the mirror |
| 1    | Job (hook)   | `ogsr-gitea-seed-secret`                  | shared-password secret for Gitea/Showroom seeding |
| 1    | Job (hook)   | `ogsr-rhdh-gitea-secret`                  | RHDH↔Gitea contract, create-or-refresh (portal stack only) |
| 2    | Application  | `workshop-config`                         | attendee users, RBAC, quotas, entry-state AppProject, Showroom, from the mirror |
| Post | Job (hook)   | `ogsr-operatorgroup-gate`                 | **hard gate**: no namespace holds two OperatorGroups |

Ordering that matters: `ogsr-adopted-protection` runs after the capture Job knows who owns what
and before the first child Application exists, so an adopted resource is never
managed-but-unprotected — not even for one sync cycle. `ogsr-operatorgroup-gate` is a PostSync
hook and a real gate: a second OperatorGroup in an adopted operator's namespace stops OLM
reconciling the org's CSV *while its pods keep running*, so it fails the sync rather than let a
silent degradation ship. It only fails when one of the two is ours; a namespace that arrived with
two of the org's own is reported and left alone.

`pp-core-devtools` is sourced from GitHub (not the mirror) because it *contains* the
mirror-builder — you cannot source the thing that builds the mirror from the mirror it builds.
Every wave downstream of it is sourced from the in-cluster mirror.

---

## Values contract

RHDP injects the first four blocks; everything else has a safe default (full list +
comments in `values.yaml`).

| Key | Default | Meaning |
|-----|---------|---------|
| `deployer.domain` / `deployer.apiUrl` | `""` | injected cluster coordinates — never hardcode a domain |
| `gitops.repoURL` / `.revision` / `.path` | this repo / `main` / `helm/bootstrap` | self-reference for child app sources |
| `litemaas.enabled` / `.apiUrl` / `.apiKey` / `.model` | `false` / `""` / `""` / `""` | MaaS LLM; Lightspeed installs only when enabled AND apiUrl + apiKey are set, else auto-skips. **`model` empty = discover** from the endpoint — MaaS keys are model-scoped, so a guessed name is a 401 inside the AI modules. A key the endpoint refuses is never staged |
| `lightspeed` | unset | set `false` to hard-off the assistant while keeping the workshop's own MaaS credential (which four modules' AI beats read). Not the same as `litemaas.enabled=false`, which withholds that credential too |
| `argocd.manageControllerResources` / `.controllerResources` | `true` / 6Gi limit, 2Gi request | raise the application-controller above the operator-default 2Gi. **2Gi is OOMKilled before the workshop layer materializes.** Set `false` only when the Argo CD belongs to your organisation and you will raise it yourself; the prior value is recorded before patching so `ogsr-uninstall.sh` restores it |
| `multi_user.num_users` / `.users` / `.userPrefix` / `.manageHtpasswd` | `5` / `[]` / `user` / `true` | attendee roster; `manageHtpasswd=false` if the base CI provisions userN |
| `workshop_user_password` | `openshift` | shared, throwaway, non-secret console/Gitea password |
| `modulesDisabled` | `[]` | modules to drop (mNN or slugs); hides them + skips stacks only they need. Empty = whole workshop |
| `consolePlugins.enabled` | `true` | merge Pipelines/GitOps/ACS console plugins (append-if-absent; set false to leave the console untouched) |
| `stacks.<name>` | `false` | expert additive overrides only — force a stack on with no matching module (core-devtools/batch/progressive-delivery are always on) |
| `namespaces.gitea` / `.showroom` / `.system` | `ogsr-gitea` / `ogsr-showroom` / `ogsr-system` | parameterized so the `ogsr-` rename is a values flip |
| `gitea.org` / `.repo` | `parasol` / `ocp-getting-started` | in-cluster mirror coordinates |

---

## Known differences from `bootstrap/install.sh`

The two paths must produce the same cluster, so where they still do not, say so rather than let a
field deployment discover it at an event. These are open, not settled:

- **`deployer.domain` has no auto-detect.** The script reads `ingresses.config/cluster` when
  `cluster_domain` is blank; Helm cannot read a cluster at render time. If the domain is not
  injected, the mirror URL renders as `gitea-ogsr-gitea.` and **every wave-1 Application points at
  a repo that does not exist** — with no error at render. Always supply it (RHDP does).
- **No component-adoption plan.** The script asks
  `platform-portfolio/argocd-bootstrap/install.sh --adoption-plan` which components this cluster
  already provides, refuses the ones it cannot make safe, and records `skipped_<comp>`. The
  capture Job instead checks whether a Subscription *of our name* exists, so an organisation that
  named their operator's Subscription differently is recorded `created:` — which teardown reads as
  "we made this namespace". Do not run the FSC path against a cluster with pre-existing operators
  whose Subscriptions are non-standard until this is closed.
- **No mirror-freshness or Argo-TLS gate on the phase-2 flip.** The script only repoints the stacks
  at the in-cluster mirror once the mirror's HEAD equals origin's *and* Argo can verify the
  mirror's certificate (adding the cluster ingress CA to `argocd-tls-certs-cm`), and stays on the
  external repo otherwise. The chart sources wave-1 from the mirror unconditionally, relying on
  Argo's wave gating. On a cluster whose ingress certificate is not publicly trusted, wave 1 will
  fail x509 with nothing here to fix it.
- **No batch-taint Pending-pod gate.** The script's post-install check attributes a Pending pod to
  the batch-pool taint. A PostSync hook fires while the stacks are still deploying and cannot tell
  a transient Pending from a starved one, so porting it would fail good installs. The taint *floor*
  (3-worker minimum, ported in 0.4.0) removes the cause the gate exists to catch.
- **`workshop_user_password` has no `CHANGEME` → generate.** The script mints one and writes
  `.credentials.local.txt`; a Job has no such file to write to, and the value is published through
  the UserInfo ConfigMap, so it must be a values input.

---

## Uninstall

`./bootstrap/ogsr-uninstall.sh` reverses the install non-destructively: it removes only
owner-labeled (`workshop.redhat.com/owner=ogsr`) resources and stacks this install created,
restores shared/default objects (OAuth IdP, monitoring, nodes) from the `ogsr-uninstall-state`
record, and never touches an operator or namespace the cluster already had. Under RHDP,
de-provisioning simply deletes the whole cluster.
