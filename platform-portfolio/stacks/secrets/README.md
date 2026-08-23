# stack: secrets

The platform prerequisite for the **`platform-guardrails`** module (`stacks: [secrets]` in
`/modules.yaml`). Installs the **External Secrets Operator** as an Argo CD app-of-apps — a single
shared, cluster-wide install; per-attendee isolation is the entry state's job, below.

```bash
./argocd-bootstrap/install.sh --stacks secrets
# together with the dev-loop base:
./argocd-bootstrap/install.sh --stacks core-devtools,secrets
```

## What it installs

| Component | Operator (channel) | Config CRs | Wave |
|---|---|---|---|
| `external-secrets` | `openshift-external-secrets-operator` (`stable-v1`) | `ExternalSecretsConfig/cluster` + NetworkPolicy `ogsr-allow-eso-to-secret-store` | 0 |

One child today. The stack exists as its own root rather than as a ninth app in `core-devtools`
because secret management is the prerequisite for exactly one module and carries a real cost on a
cluster that will never teach it: a cluster-scoped singleton CR, 22 CRDs and three long-lived operand
pods. A deployer running a lean event drops `secrets` from `--stacks` and none of that appears.

## No vault here, on purpose

There is **no shared secret backend in this stack**. The `platform-guardrails` entry state gives every
attendee their own OpenBao in `{user}-dev`, seeded and namespaced, with a namespaced `SecretStore`
(never a `ClusterSecretStore` — one cluster-scoped store shared by twelve attendees would let any of
them read every other's vault, and an attendee holds no cluster-scoped rights to own one anyway).

So the split is: **the portfolio ships the controller and the network grant that lets it out of its own
namespace; the workshop layer ships the vault, the store and the secret.** Nothing workshop-specific —
no users, no quotas, no seeded data — lives in this stack.

## The one thing this stack exists to fix

ESO firewalls its own operand namespace on install (`eso-sys-deny-all-traffic`, Ingress **and**
Egress, with allow-lists for the API server and DNS only), so its controller cannot reach a secret
store on port 8200 in any tenant namespace. The `SecretStore` then reports
`invalid vault credentials: context deadline exceeded` — which reads as a bad token and is a blocked
TCP connection. `components/external-secrets/README.md` has the full account; the short version is
that this stack is the only place that grant can live, because the ESO operand namespace is
platform-layer state and sits outside every entry-state AppProject's destinations.

Before this stack existed the grant was a NetworkPolicy applied **by hand** and recorded in no
repository, which meant a fresh install of the workshop came up with a broken `platform-guardrails`
module presenting as an authentication error. That is the reproducibility gap this stack closes.

## AppProject destination

**Required for a one-command install.** The NetworkPolicy targets namespace `external-secrets` — the
operand namespace ESO creates for itself. That name matches none of the patterns in
`argocd-bootstrap/appproject.template.yaml` (`ogsr-*`, `openshift-*`, `*-operator`, `istio-*`,
`knative-*`, `trust*`, `sso-*`, or the handful of literals). Argo validates the project **twice** —
once against the Application's `spec.destination` and again against **each resource's namespace at
sync time** (measured on-cluster, recorded in
`gitops/workshop-config/templates/appproject-entries-per-user.yaml`), so the parent Application syncs
and then this one resource fails:

```
NetworkPolicy/ogsr-allow-eso-to-secret-store ns=external-secrets SyncFailed:
  namespace external-secrets is not permitted in project 'ogsr-platform'
```

Note the shape of that failure: the operator installs, the operand comes up, the stack looks
installed — and only the grant is missing, which lands the deployer straight back on the
`invalid vault credentials` false trail above. Either the template gains

```yaml
    - server: https://kubernetes.default.svc
      namespace: external-secrets   # ESO operand namespace (the operator creates it, not us)
```

or every install has to remember `--allow-destination external-secrets` — and a stack that only works
when you remember a flag is not the "one command, any cluster" contract the portfolio makes.

## Footprint

Four pods, no PVC, no object storage. Measured on the live install (2026-08-23): the operator
Deployment requests **100m CPU / 1Gi**; the three operand Deployments — `external-secrets`,
`external-secrets-webhook`, `external-secrets-cert-controller`, one replica each — declare **no
requests at all** (BestEffort), so the scheduled footprint of the whole stack is that single 100m/1Gi
reservation. Negligible on any workshop cluster; the per-attendee OpenBao pods come from the entry
state, not from here.

## The entry-state seam (NOT installed here)

This stack is workshop-agnostic. The per-user wiring is
`gitops/entry-states/platform-guardrails/`: the OpenBao Deployment + Service (`:8200`) and seeded KV
mount, the `openbao-token` Secret, the namespaced `SecretStore parasol-bao`, and the `ExternalSecret`
that materialises `claims-creds` for the Parasol claims database. None of that belongs in a portfolio
stack — it is user- and story-specific.

## Verify

```bash
oc get applications -n openshift-gitops -l portfolio.redhat.com/component=external-secrets
oc get csv -n external-secrets-operator | grep external-secrets        # Succeeded
oc get externalsecretsconfig cluster                                    # READY True (built-in printer)
oc get pods -n external-secrets                                         # 3 operand pods Running
oc get networkpolicy ogsr-allow-eso-to-secret-store -n external-secrets  # the grant exists
oc get secretstore -A                                                   # READY=True once a module is started
```

`oc get secretstore -A` is the only line that proves the *network* path rather than the install; it
goes green only after the controller has completed a TCP round trip to 8200 in another namespace.

## Reusability

`--stacks secrets` needs no domain, no storage class, no sizing tier and no vars-file entry — only a
cluster whose `redhat-operators` catalog carries `openshift-external-secrets-operator`.

Provenance, stated exactly: every shape in these manifests was **captured read-only from a working
ESO 1.2.0 / operand 2.5.0 install on OCP 4.22.8 (cluster-m24jn, 2026-08-23)** — the Subscription,
the AllNamespaces OperatorGroup, the singleton `ExternalSecretsConfig`, and a NetworkPolicy whose
rendered spec is byte-identical to the live one that makes `SecretStore parasol-bao` report
`Valid`/`READY=True`. The manifests render (`kustomize build`, rc 0) and pass
`hack/check-teardown-invariants.sh`, `hack/check-adoption-skip.sh` and `yamllint`. What has **not**
been done is an unattended `install.sh --stacks secrets` from zero — see § AppProject destination
for the one thing that must land first.
