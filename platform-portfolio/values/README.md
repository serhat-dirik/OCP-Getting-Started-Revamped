# values/ — per-cluster inputs

The portfolio auto-detects what it can (cluster domain from the ingress config, default StorageClass). What it cannot detect is expressed as **contracts**, not files in git:

### Portfolio contracts

| Contract | Consumed by | Provided how |
|---|---|---|
| `credentials` Secret (ns `openshift-lightspeed`, key `apitoken`) — the MaaS/vLLM API token. The endpoint URL + model are **not** secrets: they're set in git by the `ai-assist` stack's kustomize patch on the `OLSConfig` (`stacks/ai-assist/apps/openshift-lightspeed.yaml`); the component ships generic placeholders. | `ai-assist` stack — `OLSConfig.spec.llm.providers[].credentialsSecretRef` | Created by the consumer layer (e.g. workshop bootstrap from `vars.yaml`) **before** the stack reconciles |
| `rhdh-auth` Secret (ns `rhdh`), OPTIONAL — `APP_CONFIG_*` keys that override Developer Hub's app-config (e.g. OIDC sign-in). Absent = guest sign-in. | `portal` stack — `components/rhdh/backstage.yaml` (`envFrom`, optional) | Any consumer layer; restart the Dev Hub pod after changing it. Shape in `components/rhdh/README.md` |
| Extra mirror repos: ConfigMap in ns `ogsr-gitea`, label `git-mirror.portfolio.redhat.com/repos: "true"`, keys `org`, `repos` (`name=url` per line) | `core-devtools` git-mirror job | Any consumer layer adds its own ConfigMap; the job mirrors the union |

### Workshop-layer contracts

Consumed by the workshop layer (`gitops/workshop-config`), not the portfolio — listed here for the complete secret surface. All created by `bootstrap/install.sh` from `bootstrap/vars.yaml`:

| Contract | Consumed by | Provided how |
|---|---|---|
| `workshop-user-creds` Secret (ns `ogsr-gitea`, key `password`) — shared attendee password | workshop-config seed Jobs (Gitea, cluster sign-in in Keycloak) | `bootstrap/install.sh` |

Sizing tiers and optional per-stack values land here as stacks grow. Rule: **no secrets in this directory, ever** — git holds shapes (`*.example.yaml`), consumers hold values.
