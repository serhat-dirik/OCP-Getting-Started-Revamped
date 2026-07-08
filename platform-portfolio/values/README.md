# values/ — per-cluster inputs

The portfolio auto-detects what it can (cluster domain from the ingress config, default StorageClass). What it cannot detect is expressed as **contracts**, not files in git:

| Contract | Consumed by | Provided how |
|---|---|---|
| `lightspeed-llm-creds` Secret (ns `openshift-lightspeed`; keys `apitoken`) + endpoint/model set on the `OLSConfig` | `ai-assist` stack | Created by the consumer layer (e.g. workshop bootstrap from its `vars.yaml`) **before** enabling the stack |
| Extra mirror repos: ConfigMap in ns `gitea`, label `git-mirror.portfolio.redhat.com/repos: "true"`, keys `org`, `repos` (`name=url` per line) | `core-devtools` git-mirror job | Any consumer layer adds its own ConfigMap; the job mirrors the union |

Sizing tiers and optional per-stack values land here as stacks grow. Rule: **no secrets in this directory, ever** — git holds shapes (`*.example.yaml`), consumers hold values.
