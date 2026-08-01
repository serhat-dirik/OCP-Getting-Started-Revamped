# Platform Portfolio

Install OpenShift platform capabilities — operators, tools and their configuration — on any
**OpenShift 4.20+** cluster, in one command. You pick **stacks**; Argo CD installs and then maintains
them.

This directory has no dependency on the rest of this repository. Use it on its own to stand up a demo
or PoC cluster ("give me dev tools, a service mesh and AI in 30 minutes"), or let the workshop's
installer drive it.

**It is safe to run on a cluster that already has things installed.** Operators the cluster already
runs are detected and left alone — never reinstalled, upgraded or reconfigured. See
[Adoption](#adoption--when-the-cluster-already-has-an-operator).

---

## Quickstart

You need `oc`, logged in as **cluster-admin**.

```bash
# Install one or more stacks:
./argocd-bootstrap/install.sh --stacks core-devtools

# Add more later — same command, re-runnable, nothing is duplicated:
./argocd-bootstrap/install.sh --stacks core-devtools,mesh,observability

# See what it would do on this cluster, without changing anything:
./argocd-bootstrap/install.sh --stacks core-devtools --adoption-plan
```

Watch it converge:

```bash
oc get applications -n openshift-gitops
```

...or open the Argo CD console (route `openshift-gitops-server` in `openshift-gitops`).

### Installing from your own fork

```bash
./argocd-bootstrap/install.sh --stacks core-devtools \
  --repo-url https://github.com/you/your-fork --revision my-branch
```

The repository and revision are validated before a single Application is created — reachable, the
revision exists, and the tree actually contains `platform-portfolio/`.

---

## The stacks

Fourteen stacks. Each is a group of components installed and kept in sync together.

| Stack | What you get | Typically for |
|---|---|---|
| `core-devtools` | Gitea (in-cluster Git) + mirror, OpenShift Pipelines (Tekton), Dev Spaces, Web Terminal, cert-manager, Gateway API, user-workload monitoring | The base for any dev-loop work. Start here. |
| `batch` | Kueue, KEDA | Batch job admission and event-driven autoscaling |
| `progressive-delivery` | Argo Rollouts | Canary and blue/green deployments |
| `mesh` | Service Mesh (Istio), Kiali | Traffic management, mTLS, the mesh graph |
| `serverless` | OpenShift Serverless (Knative Serving + Eventing) | Scale-to-zero services and event-driven apps |
| `observability` | Cluster Observability Operator, Tempo, OpenTelemetry, Loki | Metrics, traces and logs |
| `auth` | Red Hat build of Keycloak (operator + instance) | Application login, OIDC, realms |
| `portal` | Red Hat Developer Hub (operator + instance) | Software catalog and golden-path templates |
| `appsec` | SonarQube | Static analysis in a pipeline |
| `trust` | RHACS (Central + SecuredCluster), Trusted Artifact Signer, Tekton Chains signing key | Image scanning, signing, attestation and admission control |
| `mta` | Migration Toolkit for Applications | Legacy application analysis |
| `resilience` | OADP (backup/restore), Service Interconnect | Backup and cross-site connectivity |
| `ai-assist` | OpenShift Lightspeed | In-console AI assistant. Needs a model endpoint — see `components/openshift-lightspeed/README.md` |
| `trust-demo` | RHTPA (Trusted Profile Analyzer) | Optional add-on to `trust`; off by default |

### If you are installing the workshop

You do not choose stacks. `bootstrap/install.sh` derives them from the modules you enable:
`core-devtools`, `batch` and `progressive-delivery` always install, and each remaining stack turns on
only if an enabled module needs it. Disabling modules therefore removes real operators from the
cluster, which is how you make a lean install.

---

## How it works

```
argocd-bootstrap/   the only imperative step: install the GitOps operator, then create one
                    Argo CD Application per stack
stacks/<stack>/     one Application per component, ordered by sync wave
components/<name>/  the actual manifests: Subscription, OperatorGroup, config CRs
values/             per-cluster inputs that cannot be auto-detected (see values/README.md)
hack/               repo-side checks that need no cluster
```

Everything imperative happens exactly twice: install the GitOps operator, and apply the stack
Applications. After that it is all Argo CD reconciliation. If you find yourself writing `oc apply` for
anything else, it belongs in a component.

**Cluster-specific values are auto-detected** where possible (ingress domain, default StorageClass) and
declared in `values/` where not. Secrets are never files in git — each component that needs one
documents the secret it expects.

**Operator versions are not pinned.** Subscriptions omit `spec.channel`, so OLM installs whatever the
package's own default channel offers on your cluster. You get the current supported release rather than
one frozen when this was written. (A version-numbered channel only exists in the catalog it was written
against — `stable-v8.1` had already vanished from a 4.22 catalog and took MTA down on a clean install.)

### Everything lands in its own Argo CD project

Every Application goes into the **`ogsr-platform`** AppProject rather than Argo's built-in `default`.
On a cluster whose Argo CD you are sharing, `default` permits every repo and destination and is where
the organisation's own Applications live. A dedicated project means a misconfigured Application fails
loudly, teardown has an unambiguous handle on what is ours, and their applications are untouched.

### Sync waves control install *and* removal order

Argo CD creates resources in ascending wave order and deletes them in descending order — so a wave
decides both. **Getting deletion order wrong is the expensive half:** an operand CR deleted at the same
time as the operator that reconciles it strands a finalizer with no controller left to run it, and the
namespace hangs in `Terminating` forever.

| Wave | What lives here | Deleted |
|---|---|---|
| `-2` | Namespaces | last — nothing we own can be orphaned inside one |
| `-1` | Prerequisites: Secrets, PVCs, RBAC, databases | after whatever consumes them |
| `0` | The operator: OperatorGroup + Subscription | after every operand |
| `2` | Operand CRs — anything an operator reconciles | **first**, while its operator is still alive to run the finalizer |
| `3` | Work needing a ready operand (`SecuredCluster`, `DataProtectionApplication`) | before the operand |

Wave `1` is free if a component needs a step between prerequisites and the operator.

The same applies to Applications: where an operand ships separately from its operator, the operand's
Application carries the higher wave — `pp-keycloak` (1) over `pp-keycloak-operator` (0).

---

## Adoption — when the cluster already has an operator

**The rule: if a capability is already installed, use it. Never install over it.**

Before applying anything, `argocd-bootstrap/install.sh` runs a read-only preflight that asks, per
component, whether that operator is already on the cluster. It looks at four signals — an existing
OperatorGroup in the target namespace, a previous run's recorded verdict, a Subscription for the same
package that is not ours, and a CSV marker with no Subscription behind it. Our own resources are
excluded by label, which is what makes re-running the installer safe.

The check is **namespace-scoped**: the same operator in a different namespace is not a conflict.

What happens next depends on what the component ships:

| Situation | Result |
|---|---|
| Component installs only an operator, and it is already present | **Skipped.** Install continues; the summary says what was skipped and why. |
| Component also ships configuration, and there is an OperatorGroup conflict | **Refused, loudly.** Installing anyway would break the existing operator (see below). Drop the stack, or ask the cluster owner to remove theirs. |
| Component also ships configuration, no conflict | **Warning.** Argo CD will manage the existing Subscription; the message names the namespace to check. |

Preview any cluster's verdict without touching it:

```bash
./argocd-bootstrap/install.sh --stacks <stack> --adoption-plan
```

### Why an OperatorGroup conflict is refused rather than worked around

**A namespace may hold exactly one OperatorGroup.** With two, OLM marks *every* CSV in that namespace
`TooManyOperatorGroups` and stops managing them — no upgrades, no self-healing — **while the operator's
pods keep running normally.** Nothing looks broken until an upgrade that never arrives.

This happened for real on 25 July 2026: our cert-manager component applied an OperatorGroup into a
namespace an organisation's own cert-manager already occupied, and failed their operator one second
later.

So: never add an OperatorGroup to `openshift-operators` (OpenShift always provides one there), and
never resolve a conflict by deleting somebody else's.

### Known gap

A component that ships **neither** an OperatorGroup nor a Subscription is not classified at all, and
installs unconditionally. That matters if you split a component into an operator half and a
configuration half: on a cluster already running that operator, the operator half is correctly skipped
and then the configuration half applies your CRs to **their** operator, silently.

Until a component can declare which operator it configures, do not use the split-operator-from-config
pattern here. Measured 1 August 2026; a known limitation, not yet fixed.

---

## Uninstall

```bash
oc delete application pp-<stack> -n openshift-gitops   # repeat per stack
oc delete appproject ogsr-platform -n openshift-gitops
```

Pruning removes components in reverse wave order, so operand CRs go before the operators that own their
finalizers. The AppProject is a second, independent handle on everything that belonged to the portfolio.

The GitOps operator itself is left installed — remove it by hand if you want it gone.

---

## Adding or changing a component

1. **Check `redhat-cop/gitops-catalog` first** — reuse rather than write from scratch, and keep the
   same shape (Subscription + OperatorGroup + config).
2. Give every resource a `sync-wave` from the table above, and add
   `SkipDryRunOnMissingResource=true` to CRs whose CRDs arrive with the operator.
3. Name any Namespace manifest `namespace*.yaml`. Teardown finds namespaces by that glob, and
   `<something>-namespace.yaml` is invisible to it.
4. Never add a second OperatorGroup to a namespace, and never add `startingCSV` or a pinned channel.
5. Run both repo-side checks — they need no cluster:

```bash
./hack/check-teardown-invariants.sh   # renders every component, fails on a wave/naming violation
./hack/check-adoption-skip.sh         # proves the adoption skip still works from rendered manifests
```

**A warning about the second check.** Whether a component can be skipped on an adopted cluster is
decided by a *filename* allow-list — `kustomization.yaml`, `namespace*.yaml`, `operatorgroup*.yaml`,
`subscription*.yaml`. Adding any other file, even a ConfigMap, silently changes that component from
"leave the organisation's install alone" to "take over their Subscription", with no error at authoring
time. This already happened once, to `openshift-pipelines`, when it grew a `tekton-config.yaml`. A CI
gate now catches the flip — run it.

---

## Two-phase sourcing (the Git mirror)

`core-devtools` installs Gitea, then a job that makes Gitea mirror your source repository. Once the
mirror serves the same commit as the original, the stacks can be re-pointed at it:

```bash
./argocd-bootstrap/install.sh --stacks core-devtools --stacks-only --skip-repo-check \
  --repo-url https://gitea-ogsr-gitea.<domain>/parasol/ocp-getting-started.git \
  --source-repo https://github.com/you/your-fork
```

Reconciliation then happens entirely inside the cluster: no dependency on GitHub during a live session,
and one content-update path instead of two that can disagree.

The switch is gated on the mirror actually serving the origin's HEAD — never on a timer — and on Argo CD
being able to verify the mirror's TLS certificate (the cluster's ingress CA is added for that host;
verification is never disabled). **Failing either gate is not an install failure:** the stacks stay on
the external repository, which works perfectly well, and the installer tells you which gate failed.

`--source-repo` always stays external. A mirror pointed at itself never sees another commit.
