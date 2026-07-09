# component: loki-logging (OPTIONAL / capacity-gated)

The log-aggregation tier for M11 ("logs across replicas"): the **Loki Operator** + **Red Hat OpenShift
Logging** stand up a shared **LokiStack** log store, a **Vector** `ClusterLogForwarder` that ships
application + infrastructure logs into it, and the **COO Logging UIPlugin** that surfaces them in the
console **Observe -> Logs** view.

**This is the heaviest observability add** (a Vector DaemonSet — one pod per node — plus the LokiStack
pods) and it needs S3-compatible object storage. It is deliberately **left out of the `observability`
stack by default** (commented out in `stacks/observability/kustomization.yaml`). Opt in only on a cluster
with spare capacity and ODF/NooBaa object storage. The always-true log baseline without it is `oc logs` /
the console **Pod -> Logs** tab, so cutting this tier costs the workshop nothing structural.

> Authoring note: none of these operators were installed when this component was written (a QA smoke test
> held the cluster), so CR shapes come from the live catalog alm-examples + docs. Every field that could not
> be `oc explain`-verified carries a `TODO(verify-on-install)` in its manifest. Verify on first install.

## What's in here

| File | Why |
|---|---|
| `namespace-operators-redhat.yaml` | `openshift-operators-redhat` — Loki Operator install namespace (AllNamespaces) |
| `namespace-logging.yaml` | `openshift-logging` — Logging operator + LokiStack + collector + OBC live here |
| `operatorgroup-loki.yaml` / `operatorgroup-logging.yaml` | all-namespaces OperatorGroups |
| `subscription-loki.yaml` | `loki-operator`, channel `stable-6.5`, `redhat-operators` |
| `subscription-logging.yaml` | `cluster-logging`, channel `stable-6.5`, `redhat-operators` |
| `objectbucketclaim.yaml` | requests a NooBaa S3 bucket (`storageClassName: openshift-storage.noobaa.io`) |
| `lokistack.yaml` | `LokiStack` `logging-loki`, size `1x.demo`, wave 2 |
| `collector-serviceaccount.yaml` + `collector-rbac.yaml` | the Vector collector SA + log-read RBAC |
| `clusterlogforwarder.yaml` | `ClusterLogForwarder` (Logging 6.x `observability.openshift.io/v1`) app+infra -> Loki, wave 2 |
| `uiplugin-logging.yaml` | COO Logging console plugin pointed at `logging-loki`, wave 2 |

## Object-storage Secret contract — `logging-loki-s3`

The bucket keys are **not** hardcoded in git. The `ObjectBucketClaim` provisions a bucket and emits its
coordinates as a ConfigMap + Secret (both named `logging-loki-bucket`) in `openshift-logging`; the LokiStack
expects a **single S3 Secret** named `logging-loki-s3` assembled from them. The consumer/bootstrap layer
creates it **before** the LokiStack reconciles (mirrors the Lightspeed `credentials` contract).

| Field | Value |
|---|---|
| Namespace | `openshift-logging` |
| Name | `logging-loki-s3` (referenced by `LokiStack.spec.storage.secret.name`) |
| Keys | `access_key_id`, `access_key_secret`, `bucketnames`, `endpoint` (NooBaa S3, e.g. `https://s3.openshift-storage.svc:443`) |

```bash
# TODO(verify-on-install): confirm the NooBaa OBC output key names + endpoint form against the LokiStack S3 driver.
OBC_CM=logging-loki-bucket; OBC_SECRET=logging-loki-bucket; NS=openshift-logging
BUCKET=$(oc get cm  "$OBC_CM"     -n "$NS" -o jsonpath='{.data.BUCKET_NAME}')
AKID=$(  oc get secret "$OBC_SECRET" -n "$NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}'     | base64 -d)
ASEC=$(  oc get secret "$OBC_SECRET" -n "$NS" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
oc create secret generic logging-loki-s3 -n "$NS" \
  --from-literal=access_key_id="$AKID" \
  --from-literal=access_key_secret="$ASEC" \
  --from-literal=bucketnames="$BUCKET" \
  --from-literal=endpoint="https://s3.openshift-storage.svc:443"
```

## Replicability caveat — the shared OperatorGroup

Some clusters pre-create `openshift-operators-redhat` **with** an AllNamespaces OperatorGroup for other Red
Hat operators. OLM allows only one OperatorGroup per namespace (a second triggers `TooManyOperatorGroups`).
If the target cluster already has one, drop `operatorgroup-loki.yaml` from `kustomization.yaml` and reuse the
existing OG. (On the workshop build cluster this namespace does not exist yet, so the shipped OG is correct there.)

## Verify

```bash
oc get lokistack logging-loki -n openshift-logging               # -> Ready once storage Secret + operator are up
oc get clusterlogforwarder instance -n openshift-logging          # -> condition Ready; Vector pods per node
oc get pods -n openshift-logging                                  # LokiStack + collector pods Running
oc get uiplugin logging                                           # COO Logging console plugin
```
