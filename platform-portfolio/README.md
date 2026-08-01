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

# Point at your own fork/revision (validated before a single Application is created:
# reachable, the revision exists, and the tree actually carries platform-portfolio/):
./argocd-bootstrap/install.sh --stacks core-devtools \
  --repo-url https://github.com/you/your-fork --revision my-branch

# Re-point the stacks at another source without touching the operator (this is how the
# workshop bootstrap flips them to the in-cluster Gitea mirror — see "Two-phase sourcing"):
./argocd-bootstrap/install.sh --stacks core-devtools --stacks-only --skip-repo-check \
  --repo-url https://gitea-ogsr-gitea.<domain>/parasol/ocp-getting-started.git \
  --source-repo https://github.com/you/your-fork
```

Every Application the installer creates lives in the **`ogsr-platform` AppProject**, not the built-in `default` (`--project` renames it). `default` permits every repo, destination and resource kind, and on an adopted Argo CD it is shared with the organisation's own Applications; a dedicated project means a misconfigured Application fails loudly, teardown gets an unambiguous handle on what is ours, and their apps stay untouched. The project is scoped by **namespace pattern** (`ogsr-*`, `openshift-*`, `*-operator`, plus the operand namespaces whose product names match no pattern) rather than by enumerating resource kinds — a project so tight that adding a component means editing it would rot immediately. Consumer layers widen it with `--allow-source-repo` / `--allow-destination`; both lists are unioned with what the live project already permits, so re-running either layer never revokes the other's entries.

Watch reconciliation: `oc get applications -n openshift-gitops` (or the Argo CD console — route `openshift-gitops-server` in `openshift-gitops`).

## Layout

```
argocd-bootstrap/   # the ONLY imperative step: GitOps operator + controller RBAC + stack Applications
stacks/<stack>/     # one Argo CD Application per component, sync-wave ordered
components/<name>/  # kustomize bases: Subscription + OperatorGroup + config CRs + health
values/             # per-cluster inputs where auto-detection isn't possible (see values/README.md)
hack/               # repo-side checks (no cluster): check-teardown-invariants.sh, check-adoption-skip.sh
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
2. **Git-localize pattern, two-phase sourcing**: `core-devtools` deploys Gitea at sync-wave 0 and a mirror job at wave 1 that makes Gitea pull-mirror the configured source repo (Gitea's migrate API). *Phase 1* — bootstrap installs from `--repo-url`; it has to, because that is what builds the mirror. *Phase 2* — once the mirror serves the same commit as origin, the stacks are re-applied against the mirror (`--stacks-only`), and reconciliation becomes cluster-local: no dependency on GitHub availability during a live session, and one content-update path instead of the mirror and the Argo source silently disagreeing. The flip is gated on **HEAD equality, never a timer** (the mirror job itself does not exit until the mirror serves origin's HEAD) and on Argo being able to **verify** the mirror's TLS — the cluster ingress CA is added to `argocd-tls-certs-cm` for that host; verification is never disabled. Failing either gate is not an install failure: the stacks stay on the external repo, which works fine, and the installer says which gate failed. The repo the mirror pulls FROM is `--source-repo` and always stays external — a mirror pointed at itself never sees another commit.
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
- `argocd-bootstrap/install.sh` runs a **read-only preflight** before it applies anything (§ Adoption below). Argo CD has no "create only if absent" primitive, so this decision cannot live in the manifests — it is made once, in the portfolio's single sanctioned imperative step.

## Adoption — when the cluster already runs an operator

*"If a capability is already installed, use it instead of installing or overwriting."* RHDP clusters — the primary target — ship at least three pre-installed operators, so a first install must handle this **without a human**: an installer that stops and asks for a repo edit is not an unattended installer.

`argocd-bootstrap/install.sh` §0 asks two questions per component, before anything is applied.

**1. Is this operator already on the cluster?** Four signals, strongest first, all read-only, all namespace-scoped (an operator of the same package in a *different* namespace is not a collision — the org's RHBK in `keycloak` does not stop us installing our own in `sso-workshop`):

| # | Signal | Catches |
|---|---|---|
| 1 | the component's OperatorGroup namespace already holds an OperatorGroup that is not ours | the `TooManyOperatorGroups` case |
| 2 | the workshop layer's `ogsr-uninstall-state` snapshot records `op_<sub>` as `adopted:` | a verdict already reached on an earlier run |
| 3 | a Subscription for the same **package** in that namespace with no `workshop.redhat.com/owner: ogsr` label | `openshift-pipelines` / `web-terminal`, which ship no OperatorGroup at all and would otherwise have Argo silently re-channel the org's Subscription |
| 4 | a CSV carrying OLM's `operators.coreos.com/<package>.<namespace>` marker, with no Subscription of ours | an operator installed without a Subscription we can see |

Ours are excluded by owner label, which is what makes a re-install idempotent: the installer never reads its own previous install as somebody else's operator.

> **Known blind spot — a component that ships no Subscription is never classified at all.** All four signals are driven by two loops in `classify_component()` (`argocd-bootstrap/install.sh`), and both are fed by directory globs: `component_operatorgroup_namespaces()` over `operatorgroup*.yaml`, `component_subscriptions()` over `subscription*.yaml`. A component carrying **neither** file produces zero iterations of both loops, so `CC_VERB` keeps its `ok` default and the preflight's `[[ "$CC_VERB" == "ok" ]] && continue` installs it unconditionally — *including on a cluster where its own operator sibling was correctly skipped as adopted*.
>
> Concretely: split a component into `foo-operator` (Namespace + OperatorGroup + Subscription, so `is_operator_only()` = skippable) and `foo-config` (the operand CRs alone). On a cluster already running foo, `foo-operator` is skipped and the org's operator is left alone — and then `foo-config` applies our operand CRs onto **their** operator instance, at whatever channel and version they run. There is no ❌, no ⚠, no `--adoption-plan` line and nothing in the install summary; the output is identical to a component that had nothing to adopt. That is quieter than the `openshift-pipelines` case below, which at least warns.
>
> This is not one component's problem. "Move the extra resource into its own component" is the remedy the adoption gate itself recommends for a demotion (next paragraph) — and taking that advice is exactly what creates an operand-only component. Until a component can **declare** which operator it configures, the "split operator install from operand config" pattern converts a visible warning into an invisible overwrite, and cannot be used safely anywhere in the portfolio. Measured 2026-08-01 against the real `classify_component()`; an owner decision, not yet fixed.

**2. Can we simply not install ours?** Only if the component is **operator-only** — `is_operator_only()` (`argocd-bootstrap/lib-components.sh`) walks the component's directory and every `resources:`/generator entry its `kustomization.yaml` pulls in, and passes only if every file matches `kustomization.yaml`, `namespace*.yaml`, `operatorgroup*.yaml` or `subscription*.yaml`. Today that is `cert-manager`, `keycloak-operator`, `rhacs-operator`, `rhdh-operator`, `rhtpa`, `service-interconnect`, `web-terminal` — **derived from the directory at runtime, never a hardcoded list**, so a component that grows its first operand stops being skippable automatically.

  The check is a filename allow-list, not a semantic one: adding *any* file outside that set — `tekton-config.yaml`, a ConfigMap, an RBAC object, anything — silently drops the component from the skippable set, with no error at authoring time. `openshift-pipelines` was on this list until it grew `tekton-config.yaml`; it is operator-only no longer, so on a cluster that already has Pipelines, adoption can no longer just skip it (it ships no OperatorGroup, so the collision case never applies either) — it falls to "present, no collision → a warning" below, and Argo takes over the org's existing Subscription so our `tekton-config.yaml` can apply. That is the correct outcome for this component today, but the same silent flip works in reverse on any currently operator-only component: adding a file there — with no error at authoring time — changes it from "leave the org's install alone" to "take over their Subscription" on every adopted cluster. A CI gate now checks this invariant against rendered manifests so that flip can't happen unnoticed.

- **Operator-only + already present → SKIPPED, install continues.** The skip is delivered as a kustomize patch on the parent `pp-<stack>` Application (`$patch: delete` on the child, the same `kustomize.patches` mechanism that rewrites `repoURL` across all 32 children) — **the repo is never edited at install time**. The summary names every skipped component and why.
- **Anything else + an OperatorGroup collision → REFUSED, loudly.** Dropping a component that also ships operand CRs would leave the workshop quietly incomplete, and there is no partial-component surgery. The two ways forward are dropping the stack from `--stacks`, or the org removing their operator — never deleting their OperatorGroup.
- **Anything else, present but with no collision → a warning.** Argo will manage the existing Subscription; the message says which namespace to check.

Preview the verdict on any cluster without touching it: `./argocd-bootstrap/install.sh --stacks <s> --adoption-plan`. The workshop bootstrap layer reads exactly that plan so its uninstall snapshot records a skipped component's operator as **adopted** — one detector, two callers, and teardown leaves an operator we never installed exactly as it found it.

Run `./hack/check-adoption-skip.sh` after touching a component or the skip mechanism. It proves both halves from the *rendered* manifests: every skippable component emits only Namespace/OperatorGroup/Subscription, and a simulated skip removes exactly its own child Application from the stack.

## Uninstall

Delete the stack Applications (`oc delete application pp-<stack> -n openshift-gitops`) — prune removes the components in reverse wave order, so operand CRs go before the operators that own their finalizers. Then delete the `ogsr-platform` AppProject, which is the second, independent handle on what belonged to the portfolio (`oc delete appproject ogsr-platform -n openshift-gitops`). The GitOps operator itself stays (remove manually if desired).
