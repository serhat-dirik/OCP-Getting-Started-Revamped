# components/external-secrets — External Secrets Operator for Red Hat OpenShift

Installs the **External Secrets Operator** (`openshift-external-secrets-operator`, channel
**`stable-v1`**, AllNamespaces from `external-secrets-operator`), the singleton
**`ExternalSecretsConfig/cluster`** that actually deploys the operand, and **one NetworkPolicy** without
which every `SecretStore` in the workshop fails. Backs the `platform-guardrails` module — an attendee
stores a database password in their own OpenBao and an `ExternalSecret` materialises it as a Kubernetes
`Secret` that was never in Git. Entitlement `[OCP]` (included with an OpenShift subscription).

## What it creates

| Wave | Object | Why |
|---|---|---|
| -2 | Namespace `external-secrets-operator` | operator install namespace; created first, deleted last |
| 0 | OperatorGroup (AllNamespaces, `spec: {}`) | ESO's CRDs and its config CR are cluster-scoped — it cannot be OwnNamespace |
| 0 | Subscription `openshift-external-secrets-operator` | the controller (`redhat-operators`, `stable-v1`) |
| 2 | `ExternalSecretsConfig/cluster` | the operand: creates `external-secrets`, deploys controller + webhook + cert-controller |
| 3 | NetworkPolicy `ogsr-allow-eso-to-secret-store` | egress to TCP 8200 in workshop namespaces — **see below** |

## The NetworkPolicy, and why the error points at the wrong layer

**Read this before debugging a failing `SecretStore`.**

Reconciling `ExternalSecretsConfig` makes ESO harden its own operand namespace: it installs
`eso-sys-deny-all-traffic` in `external-secrets` (podSelector `{}`, policyTypes **Ingress and Egress**)
and allow-lists for exactly two destinations — the API server and `openshift-dns`. NetworkPolicies are
additive-only, so from that moment the ESO core controller can open a TCP connection to nothing else.
A `SecretStore` with a Vault/OpenBao provider needs port **8200** in a *tenant* namespace, and that
connection is dropped.

The failure surfaces on the `SecretStore`'s `Ready` condition (reason `InvalidProviderConfig`) and in
`oc get events -n <user>-dev | grep secretstore`, as:

```
invalid vault credentials: context deadline exceeded
```

That message names the credential layer. **The fault is three layers below it** — the packet never
arrived, and nothing ever read the token it is complaining about. `context deadline exceeded` is the
only tell: a real auth rejection comes back in milliseconds with a 403, while a timeout means the SYN
was dropped. Without this policy the predictable outcome is an hour spent re-issuing vault tokens,
re-checking `tokenSecretRef` keys and re-seeding the KV mount, on a credential path that was correct
the entire time.

`ogsr-allow-eso-to-secret-store` grants exactly that one hole:

- **podSelector** `app.kubernetes.io/name: external-secrets` — the core controller pods only. The
  webhook and cert-controller carry `…/name: external-secrets-webhook` and
  `…/name: external-secrets-cert-controller` (confirmed on the live pods) and neither talks to a
  secret backend, so neither is granted egress.
- **egress to** `namespaceSelector: workshop.redhat.com/owner=ogsr` — every namespace the workshop
  layer creates carries that label, so **one** policy covers a whole cohort rather than one per
  attendee, and a namespace that is not ours gets no grant.
- **ports** `8200/TCP` only. Never a blanket egress.

It is additive: no `eso-sys-*` policy is deleted, patched or replaced, and pruning this one (wave 3 —
first out) restores the operator's shipped posture exactly.

> The operator does offer a native alternative — `spec.controllerConfig.networkPolicies[]` on the
> config CR, which generates `eso-user-<name>` policies. It is **not** used here for two reasons.
> Ownership: an operator-generated policy carries the operator's labels, so it is invisible to
> `oc get networkpolicy -A -l workshop.redhat.com/owner=ogsr` and to `bootstrap/ogsr-uninstall.sh`.
> Adoption: the rule would have to be written into a **cluster-scoped singleton**, so on a cluster
> where the organisation owns ESO we would be editing *their* config object. A standalone policy we
> own is additive, labelled and deletable.

## Two namespaces, and only one of them is ours

| Namespace | Created by | Contains |
|---|---|---|
| `external-secrets-operator` | this component (`namespace.yaml`, wave -2) | OLM: OperatorGroup, Subscription, CSV, the operator pod |
| `external-secrets` | **the operator**, when it reconciles `ExternalSecretsConfig` | the operand: controller / webhook / cert-controller, the `eso-sys-*` policies — and our NetworkPolicy |

The consequence for GitOps: our NetworkPolicy lands in a namespace this component does not create and
must not create. That is why it sits at wave 3 and why the child Application carries a retry backoff —
on a cold cluster the first sync attempts legitimately fail with "namespace not found" until the
operator has finished. It converges by retry, never by a sleep. It also means the AppProject must
permit `external-secrets` as a destination; see `stacks/secrets/README.md` § AppProject destination.

## Package-name trap (do not get this wrong)

Two different operators answer to "external secrets", and a bare package name resolves to either
(measured on cluster-m24jn, 2026-08-23):

| Package | Catalog | Version | Default channel | |
|---|---|---|---|---|
| `openshift-external-secrets-operator` | `redhat-operators` | 1.2.0 | `stable-v1` | ✅ Red Hat build, ships the `ExternalSecretsConfig` API, supported |
| `external-secrets-operator` | `community-operators` | 0.11.0 | `alpha` | ❌ upstream chart, **no** `ExternalSecretsConfig`, unsupported |

`subscription.yaml` pins both `spec.name` and `spec.source`. The channel is pinned too — unlike
`cert-manager`, which deliberately floats — because this component ships an operand CR on
`operator.openshift.io/v1alpha1`, and a major-channel jump is exactly where that API changes.

## If the organisation already runs ESO

`ExternalSecretsConfig` is a **cluster-scoped singleton** (the CRD rejects any name but `cluster`), so
there is only ever one on a cluster — theirs or ours, never both. Three things keep that safe:

1. **`spec: {}` + `ServerSideApply=true`** (`externalsecretsconfig.yaml`). Argo becomes a field manager
   that owns only the fields it sets; setting none means it removes none of theirs. Under the default
   client-side apply an empty spec would wipe their `logLevel`, `proxy` and `componentConfigs` the
   first time our Application synced.
2. **The OperatorGroup preflight**, `argocd-bootstrap/install.sh` §0. If `external-secrets-operator`
   already carries an OperatorGroup that is not ours, the install **refuses** and applies nothing —
   two OperatorGroups in one namespace fail every CSV in it (`TooManyOperatorGroups`) while the pods
   keep running, so the org's operator would break silently.
3. **The Subscription/CSV signals**, same preflight. A foreign Subscription for this package in
   `external-secrets-operator`, or a CSV for it with no Subscription of ours behind it, marks the
   component `present`.

**What "present" actually does here, stated plainly.** This component is *not* operator-only
(`hack/adoption-skippable.snapshot`: `installs-more`), so §0 cannot drop it. It takes the ⚠ branch:
the install continues and says

> `external-secrets` ships operand CRs as well as the operator, so it is NOT skipped — Argo will
> manage the existing Subscription. Check its channel is one the org expects.

That is the honest cost. The org's Subscription has the same name in the same namespace (it is the
name the console's own install produces), so Argo adopts it and can re-channel it to `stable-v1`. The
deployer is told, in the preflight, before anything is applied, and can drop `secrets` from `--stacks`.

The portfolio's usual remedy — split operator install from operand config — is **not** available yet:
`argocd-bootstrap/install.sh` documents at length why the split is currently *worse*, because the
operand half classifies as `ok` and is applied in silence onto the org's operator with no ❌, no ⚠ and
no line in `--adoption-plan`. One loud component beats two quiet ones until that gap is closed.

**The case none of the three signals sees**, and it is worth knowing: an organisation that installed
ESO globally into `openshift-operators` rather than into `external-secrets-operator`. Every signal is
namespace-scoped, so the preflight reports nothing and our Subscription creates a *second*
AllNamespaces install of the same operator. OLM should catch it — two OperatorGroups cannot both own
`olm.providedAPIs` for the `external-secrets.io` APIs, so the newer CSV fails rather than the org's
breaking — but that is OLM's documented conflict behaviour, **not measured on this cluster** (it would
have required installing a competing operator). Treat it as a known unknown, not as a guarantee.

## Verify

```bash
oc get csv -n external-secrets-operator | grep external-secrets            # Succeeded
oc get externalsecretsconfig cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'   # True
oc get pods -n external-secrets                                            # controller/webhook/cert-controller Running
oc get networkpolicy ogsr-allow-eso-to-secret-store -n external-secrets     # the grant
# the end-to-end assertion — a store in a tenant namespace actually reaching its backend.
# The built-in printer already carries STATUS (Valid) and READY (True):
oc get secretstore -A
```

The last one is the only check that distinguishes "ESO is installed" from "ESO works": it is green
only when the controller completed a TCP round trip to port 8200 in another namespace.

`tools/verify/platform-guardrails.sh` already grades the grant, and grades it **name-agnostically** —
it discovers the operand namespace from the `app.kubernetes.io/name=external-secrets` Deployment and
asks whether *any* NetworkPolicy there permits egress to TCP 8200. This component satisfies that check
as written; renaming the policy would not break it.

## Reusability

`--stacks secrets` on any OCP 4.20+ cluster whose `redhat-operators` catalog carries
`openshift-external-secrets-operator`. No storage class, no sizing input, no vars.

Provenance: every shape here was **captured read-only from a working ESO 1.2.0 / operand 2.5.0 install
on OCP 4.22.8, 2026-08-23** — Subscription, AllNamespaces OperatorGroup, singleton
`ExternalSecretsConfig`, and a NetworkPolicy whose rendered spec is byte-identical to the live one
under which `SecretStore parasol-bao` reports `Valid` / `READY=True`. The manifests render
(`kustomize build`, rc 0) and pass `hack/check-teardown-invariants.sh`, `hack/check-adoption-skip.sh`
and `yamllint`. An unattended `install.sh --stacks secrets` from zero has **not** been run — see
`stacks/secrets/README.md` § AppProject destination for the prerequisite that must land first.
