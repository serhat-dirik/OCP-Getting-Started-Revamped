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

To enable optional stacks or the MaaS assistant at order time, set the matching values
(see the contract below) as extra Helm values on the order, e.g. `stacks.auth=true`,
`litemaas.enabled=true` + `stacks.lightspeed=true`.

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

---

## What gets deployed (sync-wave order)

| Wave | Kind         | Name(s)                                  | Purpose |
|-----:|--------------|------------------------------------------|---------|
| -20  | ns/SA/CRB    | `ogsr-system`, `ogsr-bootstrap`          | groundwork the Jobs run as |
| -10  | Job (hook)   | `ogsr-state-capture`                     | records prior state → `ogsr-uninstall-state` |
| -9   | Job (hook)   | `ogsr-node-shaping`                       | batch pool + synthetic zones (M16/M21) |
| -8   | Job (hook)   | `ogsr-workshop-users` / `ogsr-maas-secret` | htpasswd + OAuth IdP / MaaS secret |
| -1   | ConfigMap    | `ogsr-userinfo`                           | `demo.redhat.com/userinfo` (URLs, roster, password) |
| 0    | Application  | `pp-core-devtools`                        | **mirror anchor**: gitea + git-mirror + dev tooling (from GitHub) |
| 1    | Application  | `pp-batch` (+ `pp-ai-assist`/`pp-auth`/`pp-resilience`) | platform stacks, from the mirror |
| 1    | Job (hook)   | `ogsr-gitea-seed-secret`                  | shared-password secret for Gitea/Showroom seeding |
| 2    | Application  | `workshop-config`                         | attendee users, RBAC, quotas, entry-state AppProject, Showroom, from the mirror |

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
| `litemaas.enabled` / `.apiUrl` / `.apiKey` / `.model` | `false` / `""` / `""` / `llama-scout-17b` | MaaS LLM for Lightspeed; enabled only when a key is provisioned |
| `multi_user.num_users` / `.users` / `.userPrefix` / `.manageHtpasswd` | `5` / `[]` / `user` / `true` | attendee roster; `manageHtpasswd=false` if the base CI provisions userN |
| `workshop_user_password` | `openshift` | shared, throwaway, non-secret console/Gitea password |
| `stacks.lightspeed` / `.auth` / `.resilience` | `false` | opt-in stacks (core-devtools + batch are always on) |
| `namespaces.gitea` / `.showroom` / `.system` | `ogsr-gitea` / `ogsr-showroom` / `ogsr-system` | parameterized so the `ogsr-` rename is a values flip |
| `gitea.org` / `.repo` | `parasol` / `ocp-getting-started` | in-cluster mirror coordinates |

---

## Uninstall

`./bootstrap/ogsr-uninstall.sh` reverses the install non-destructively: it removes only
owner-labeled (`workshop.redhat.com/owner=ogsr`) resources and stacks this install created,
restores shared/default objects (OAuth IdP, monitoring, nodes) from the `ogsr-uninstall-state`
record, and never touches an operator or namespace the cluster already had. Under RHDP,
de-provisioning simply deletes the whole cluster.
