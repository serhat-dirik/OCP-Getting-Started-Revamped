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
```

## Stacks

| Stack | Components | Notes |
|---|---|---|
| `core-devtools` | Gitea (in-cluster git) + git-mirror, OpenShift Pipelines, Dev Spaces, Web Terminal, cert-manager, user-workload monitoring | The always-on base for dev-loop work |
| `ai-assist` | OpenShift Lightspeed | Requires the `lightspeed-llm-creds` secret contract (see `components/openshift-lightspeed/README.md`) — kept out of `core-devtools` so core stays green on clusters without an LLM endpoint |
| *(coming)* `trust`, `portal`, `mesh`, `serverless`, `batch`, `auth`, `virt`, `resilience`, `modernize`, `ai` | per cluster-profile map | Added wave by wave |

## Design rules

1. **Two imperative acts only** — the GitOps operator install and the stack Application(s). If you find yourself writing `oc apply` for anything else, it belongs in a component.
2. **Git-localize pattern**: `core-devtools` deploys Gitea at sync-wave 0 and a mirror job at wave 1 that makes Gitea pull-mirror the upstream repos (Gitea's migrate API — the cluster then re-syncs itself on demand). Downstream layers (e.g. a workshop) point their Argo apps at the local mirror; this portfolio itself keeps sourcing from the upstream repo.
3. **Auto-detect where possible** (cluster domain, default StorageClass); explicit in `values/` where not. Secrets are **contracts** (documented per component), never files in git.
4. **Mine `redhat-cop/gitops-catalog` before writing a component from scratch**; keep component shape compatible (Subscription+OperatorGroup+config).
5. Components declare `argocd.argoproj.io/sync-wave` and health-relevant sync options (`SkipDryRunOnMissingResource=true` on CRs whose CRDs arrive with the operator).

## Uninstall

Delete the stack Applications (`oc delete application pp-<stack> -n openshift-gitops`) — prune removes the components. The GitOps operator itself stays (remove manually if desired).
