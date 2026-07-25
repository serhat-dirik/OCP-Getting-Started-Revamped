# Platform Portfolio — standalone GitOps installer

Declarative, composable installer for OpenShift platform capabilities: operators, third-party tools, and platform configuration as **Argo CD app-of-apps stacks**. Replicable on **any OpenShift 4.20+ cluster** with cluster-admin, in one command.

This directory is deliberately **workshop-agnostic and dependency-free** from the rest of the monorepo: nothing user-, story-, or module-specific lives here. Use it alone to stand up a PoC/demo cluster ("give me dev tools + mesh + AI in 30 minutes"), or let a workshop/bootstrap layer consume it.

## Quickstart

```bash
# Everything the installer does is imperative exactly twice:
# (1) install the OpenShift GitOps operator, (2) apply one Application per stack.
# Everything else is Argo CD reconciliation.
./argocd-bootstrap/install.sh --stacks core-devtools

# Add more capability later — same command, more stacks (idempotent):
./argocd-bootstrap/install.sh --stacks core-devtools,ai-assist

# Point at your own fork/revision:
./argocd-bootstrap/install.sh --stacks core-devtools \
  --repo-url https://github.com/you/your-fork --revision my-branch
```

Watch reconciliation: `oc get applications -n openshift-gitops` (or the Argo CD console — route `openshift-gitops-server` in `openshift-gitops`).

## Layout

```
argocd-bootstrap/   # the ONLY imperative step: GitOps operator + controller RBAC + stack Applications
stacks/<stack>/     # one Argo CD Application per component, sync-wave ordered
components/<name>/  # kustomize bases: Subscription + OperatorGroup + config CRs + health
values/             # per-cluster inputs where auto-detection isn't possible (see values/README.md)
hack/               # repo-side checks (no cluster): ./hack/check-teardown-invariants.sh
```

## Stacks

| Stack | Components | Notes |
|---|---|---|
| `core-devtools` | Gitea (in-cluster git) + git-mirror, OpenShift Pipelines, Dev Spaces, Web Terminal, cert-manager, user-workload monitoring | The always-on base for dev-loop work |
| `ai-assist` | OpenShift Lightspeed | Requires the `lightspeed-llm-creds` secret contract (see `components/openshift-lightspeed/README.md`) — kept out of `core-devtools` so core stays green on clusters without an LLM endpoint |
| `trust` | RHACS (Central + SecuredCluster), trust-signing (Tekton Chains cosign key), RHTAS (Securesign) | The M09 Trusted Software Supply Chain prerequisites: scan gate + image signing + keyless demo. See `stacks/trust/README.md`. Optional `trust-demo` adds RHTPA (default off). |
| `observability` | COO, Tempo, OpenTelemetry (+ optional Loki) | M13 tracing/logging — see `stacks/observability/README.md` |
| `batch` | Kueue, KEDA | M06 batch admission + autoscaling |
| `serverless` | OpenShift Serverless (Knative Serving + Eventing) | M20 request-driven compute / scale-to-zero + M21 eventing — see `stacks/serverless/README.md` |
| *(coming)* `portal`, `mesh`, `auth`, `virt`, `resilience`, `modernize`, `ai` | per cluster-profile map | Added wave by wave |

## Design rules

1. **Two imperative acts only** — the GitOps operator install and the stack Application(s). If you find yourself writing `oc apply` for anything else, it belongs in a component.
2. **Git-localize pattern**: `core-devtools` deploys Gitea at sync-wave 0 and a mirror job at wave 1 that makes Gitea pull-mirror the upstream repos (Gitea's migrate API — the cluster then re-syncs itself on demand). Downstream layers (e.g. a workshop) point their Argo apps at the local mirror; this portfolio itself keeps sourcing from the upstream repo.
3. **Auto-detect where possible** (cluster domain, default StorageClass); explicit in `values/` where not. Secrets are **contracts** (documented per component), never files in git.
4. **Mine `redhat-cop/gitops-catalog` before writing a component from scratch**; keep component shape compatible (Subscription+OperatorGroup+config).
5. Components declare `argocd.argoproj.io/sync-wave` and health-relevant sync options (`SkipDryRunOnMissingResource=true` on CRs whose CRDs arrive with the operator).
6. **Operator versions are not pinned.** Subscriptions omit `spec.channel` so OLM resolves the package's own `defaultChannel` on the target cluster. A version-numbered channel is only guaranteed to exist in the catalog snapshot it was written against — `stable-v8.1` was absent from a 4.22 catalog and took MTA (and module 23) down on a clean-cluster install. Omitting it also means somebody installing months from now gets the current supported release instead of one frozen at authoring time. The single exception is `skupper-operator`, where the channel selects a **major line** rather than a version: the default channel installs Skupper v1, whose CRs are incompatible with the v2 API the labs use. Never add a `startingCSV`.
7. **Never add a second OperatorGroup to a namespace** — see below.

## Sync waves

Argo CD applies in ascending wave order and prunes in descending order, so the wave a resource carries decides **both** when it is created and when it is removed. Getting removal wrong is the expensive half: an operand CR deleted at the same time as (or after) the operator that reconciles it strands the CR's finalizer with no controller to run it, and the namespace hangs in `Terminating` forever. On 2026-07-25 that wedged eight namespaces, and `ogsr-observability-workshop` had to be cleared by hand because `TempoMonolithic/traces` still held `tempo.grafana.com/finalizer` after the Tempo operator was gone.

Five waves, used everywhere:

| Wave | What lives here | Deleted |
|---|---|---|
| `-2` | **Namespaces** | last — nothing we own can be orphaned inside one |
| `-1` | **Prerequisites**: Secrets, PVCs, RBAC/ServiceAccounts, buckets, plain databases | after the things that consume them |
| `0` | **The controller**: OperatorGroup + operator Subscription. In a component that installs no operator, its main workload sits here (unannotated = wave 0) | after every operand |
| `2` | **Operand CRs** — anything an operator reconciles | **first**, while its operator is still running to execute the finalizer |
| `3` | **Post-operand work**: Jobs and CRs that need a ready wave-2 operand (`SecuredCluster`, `DataProtectionApplication`) | before the operand |

Wave `1` is free for a component that needs one more step between prerequisites and the operator.

At the **app-of-apps** level the same rule applies to child `Application`s: where an operand CR ships in a different Application from its operator, the operand's Application carries the higher wave — `pp-keycloak` (1) over `pp-keycloak-operator` (0), `pp-rhacs-central` (1) over `pp-rhacs-operator` (0), `pp-kiali` (1) over `pp-service-mesh` (0).

Run `./hack/check-teardown-invariants.sh` after touching any manifest; it renders every component and fails on a violation. It also enforces the naming rule that a Namespace manifest must be called `namespace*.yaml` — `bootstrap/ogsr-uninstall.sh` finds the namespaces a component creates by globbing that pattern, and a file named `<something>-namespace.yaml` is invisible to teardown.

## OperatorGroups

**Exactly one OperatorGroup per namespace, always.** With two, OLM fails *every* CSV in that namespace (`TooManyOperatorGroups`, "can't pick one automatically") and it does so silently — the operator's pods keep running while OLM has stopped managing it: no upgrades, no self-heal. Found live on 2026-07-25, where our `cert-manager` component applied its OperatorGroup into a namespace an organisation's own cert-manager already occupied and failed their CSV one second later.

Rules for any new component:

- **Never ship an OperatorGroup into `openshift-operators`.** OpenShift always provides the cluster-wide `global-operators` group there. Components that install into it (`devspaces`, `openshift-pipelines`, `web-terminal`) correctly ship none.
- Every OperatorGroup carries the `workshop.redhat.com/owner: ogsr` label (the component kustomization stamps it), which is how tooling tells ours from theirs.
- `argocd-bootstrap/install.sh` runs a **read-only preflight** before it applies anything: for every OperatorGroup the requested stacks would create, it checks whether that namespace already holds one that is not ours and refuses the whole install if so, naming the component and the namespace. Argo CD has no "create only if absent" primitive, so this decision cannot live in the manifests — it is made once, in the portfolio's single sanctioned imperative step.
- If the preflight refuses: that cluster already runs the operator. Remove the component's `apps/<name>.yaml` line from the stack kustomization and re-run — do not delete the organisation's OperatorGroup.

## Uninstall

Delete the stack Applications (`oc delete application pp-<stack> -n openshift-gitops`) — prune removes the components in reverse wave order, so operand CRs go before the operators that own their finalizers. The GitOps operator itself stays (remove manually if desired).
