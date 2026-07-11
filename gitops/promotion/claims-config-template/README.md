# claims-config — promote the same image across environments

This repository is the **configuration** for Parasol's claims service across three
environments — `dev`, `stage`, and `prod`. It is deliberately plain Kustomize: one **base**
that describes a claims environment once, and three **overlays** that change only what should
differ per environment.

The claims container **image is identical in every environment**. Promotion means applying a
different overlay — never rebuilding. That is the discipline this repo exists to teach.

## Layout

```
base/                     one claims environment, as code
  claims-configmap.yaml     non-secret config (host, port, db name, APP_ENV, log level)
  claims-creds-secret.yaml  DB username + password (base64 is encoding, not encryption)
  claims-db.yaml            ephemeral PostgreSQL for this environment
  claims-app.yaml           the claims Deployment (same image) + Service + Route,
                            with all three probes and explicit requests/limits
  kustomization.yaml
overlays/
  dev/    1 replica · APP_ENV=dev   · log DEBUG
  stage/  2 replicas · APP_ENV=stage · log INFO
  prod/   3 replicas · APP_ENV=prod  · log WARN
rollouts/                 M10 progressive-delivery form of prod (same artifact, Argo Rollout)
  claims-rollout.yaml       claims as a Rollout (canary) + canary/stable Services
  claims-analysis-template.yaml  job-provider AnalysisTemplate (probes the canary + verdict knob)
  db-migration-job.yaml     wave-ordered pre-app migration hook (db -> migrate -> app)
  kustomization.yaml        reuses base; swaps the Deployment for the Rollout; APP_ENV=prod
applicationset.yaml       M10 beat 1 — ONE ApplicationSet (list generator; prod → rollouts/)
```

The `rollouts/` overlay and `applicationset.yaml` are **M10 (GitOps at Scale & Progressive
Delivery)** material — the base + `overlays/` are unchanged and still serve M04/M09. `rollouts/`
needs the cluster RolloutManager (platform-portfolio `progressive-delivery` stack) plus the
`claims-analysis` SA and `m10-canary-control` knob the M10 entry state creates in `{user}-prod`.

Each overlay pins its **namespace** with the Kustomize namespace transformer. In your fork the
`__user__` placeholder is rewritten to your username, so the commands below land in *your*
namespaces.

## Use it

```sh
# preview what an environment will apply (no cluster changes)
oc kustomize overlays/stage

# promote to stage, then prod
oc apply -k overlays/stage
oc apply -k overlays/prod
```

## What differs per environment (and what does not)

| | image | replicas | APP_ENV | log level |
|---|---|---|---|---|
| dev | `parasol-claims:1.0` | 1 | dev | DEBUG |
| stage | `parasol-claims:1.0` | 2 | stage | INFO |
| prod | `parasol-claims:1.0` | 3 | prod | WARN |

Same image everywhere — only configuration moves. Credentials are the same across environments
here for simplicity; a real deployment would source per-environment secrets from a secret
manager (the External Secrets pattern the module previews).
