# component: openshift-lightspeed

OpenShift Lightspeed — the in-console AI assistant — subscribed cluster-wide and bound to an
external LLM served via **Models-as-a-Service (MaaS)**, an OpenAI-compatible vLLM endpoint
(`OLSConfig.spec.llm.providers[].type: rhoai_vllm`).

## What's in here

| File | Why |
|---|---|
| `namespace.yaml` | `openshift-lightspeed` — operator + `OLSConfig` + Secret live here |
| `operatorgroup.yaml` | all-namespaces OperatorGroup (no `targetNamespaces`) |
| `subscription.yaml` | `lightspeed-operator`, channel `stable`, `redhat-operators` |
| `olsconfig.yaml` | the `cluster` OLSConfig (CR name **must** be `cluster`), sync-wave 3 |

## Endpoint/model are config; the API token is a secret

The MaaS **endpoint URL and model name are environment-specific but not secret**, so they are
NOT hardcoded here. This component ships generic placeholders (`https://maas.example.com/v1`,
model `example-model`); the **consuming stack** patches in the real values. For this project the
`ai-assist` stack (`platform-portfolio/stacks/ai-assist/apps/openshift-lightspeed.yaml`) applies
a kustomize JSON patch setting the endpoint to the project's MaaS route and the model to
`qwen3-14b`. Point the component elsewhere by editing that stack app (or your own overlay) — the
component itself stays generic and reusable.

The API **token IS secret** and is delivered as a contract, never in git:

## Secret contract — `credentials`

| Field | Value |
|---|---|
| Namespace | `openshift-lightspeed` |
| Name | `credentials` (referenced by `OLSConfig.spec.llm.providers[0].credentialsSecretRef.name`) |
| Key | `apitoken` — the MaaS/vLLM API bearer token |

Created by the consumer layer **before** the OLSConfig reconciles — e.g. the workshop bootstrap
(`bootstrap/install.sh`) creates it from `vars.yaml`. Also recorded in
`platform-portfolio/values/README.md`.

```bash
oc create secret generic credentials \
  --from-literal=apitoken='<MAAS_API_KEY>' \
  -n openshift-lightspeed
```

## Verify

```bash
oc get olsconfig cluster -o jsonpath='{.spec.ols.defaultModel}{"\n"}'   # -> qwen3-14b once patched
oc get pods -n openshift-lightspeed                                     # lightspeed-app-server Running
```
