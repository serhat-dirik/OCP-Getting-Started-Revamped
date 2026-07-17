# pipelines/ — Tekton task library & the parasol-claims build pipeline (pipelines-fundamentals)

The reusable Tekton artifacts for **pipelines-fundamentals — Pipelines Fundamentals & Task Libraries**. Everything here
is `tekton.dev/v1` (GA) and every task is referenced by the **cluster resolver** — the supported
replacement for the removed `ClusterTask` kind. No bundled-Task YAML is ever copied.

## The three reuse layers pipelines-fundamentals teaches

| Layer | Where it lives | Example |
|---|---|---|
| Catalog (shipped) | `openshift-pipelines` namespace | `git-clone`, `buildah`, `openshift-client` — cluster resolver |
| Org library (curated) | `ogsr-parasol-tasks` namespace | `image-size-report`, `maven-jdk21` — cluster resolver |
| App pipeline | `{user}-cicd` namespace | `parasol-claims-build-test-deploy` |

## Contents

```
pipelines/
├── tasks/                         curated org library (installed into the ogsr-parasol-tasks namespace)
│   ├── image-size-report.yaml     reports image pull-size + budget; emits results (flagship example)
│   ├── maven-jdk21.yaml           JDK 21 Maven runner (the shipped maven task is JDK 17)
│   └── kustomization.yaml         `oc apply -k pipelines/tasks`
├── pipeline/
│   └── parasol-claims-build.yaml  fetch -> unit-test -> build-image -> image-report -> deploy
├── pipelinerun/
│   └── parasol-claims-run.yaml    ad-hoc run (the "run it by hand" beat) + workspace/memory shape
├── .tekton/
│   └── parasol-claims-pull-request.yaml   Pipelines-as-Code entrypoint (the git-push beat)
└── rbac/
    └── pipeline-rbac.example.yaml reference for the per-user pipeline SA/workspace the entry state makes
```

## Who owns what (layering)

- **The shared `parasol-tasks` library** (namespace + both Tasks + cluster-resolver read-RBAC for
  every `{user}-cicd` ServiceAccount) is owned by the **workshop layer**, GitOps-installed via
  `gitops/workshop-config/templates/parasol-tasks.yaml`. It is shared and survives `ws reset`. The
  Task bodies there are kept byte-identical to `tasks/*.yaml` by hand (Helm can't read outside its
  chart). It is workshop-layer, not `platform-portfolio/`, because it is Parasol-branded content and
  its RBAC is parameterized by the per-user model — the portfolio stays workshop-agnostic.
- **The per-user pipeline** (the `Pipeline`, a `PipelineRun`/`.tekton` run) is materialized in
  `{user}-cicd` by the **pipelines-fundamentals entry state** (`gitops/entry-states/pipelines-fundamentals/`, built later). The push +
  deploy RBAC is free: the operator pre-creates a `pipeline` SA bound to `edit` + `system:image-builder`
  in every namespace (see `rbac/pipeline-rbac.example.yaml`).

## Run it by hand

```sh
# The shared library + RBAC are already on the cluster (workshop layer). Then, in a -cicd namespace:
oc apply -f pipelines/pipeline/parasol-claims-build.yaml -n <user>-cicd
oc create -f pipelines/pipelinerun/parasol-claims-run.yaml -n <user>-cicd
tkn pipelinerun logs -Lf -n <user>-cicd
```

The `image` target defaults to the run's own namespace, so the same files work in any `-cicd`
namespace. The run builds from the shared `parasol/parasol-claims` repo in the in-cluster Gitea.

## Notes verified on-cluster (OCP 4.21.22 / OpenShift Pipelines 1.22.4)

- **Memory:** the `-cicd` namespace default container limit is sized (2Gi) for the Maven-heavy steps
  (`unit-test`, `build-image`) in `gitops/workshop-config/templates/per-user-limits.yaml`, so a plain
  run — the console *Actions → Start* form, `tkn pipeline start`, or a PaC push — needs no per-task
  `taskRunSpecs` and does not OOMKill. (Historically these steps carried per-run `taskRunSpecs`.)
- **JDK:** the bundled `maven` task is pinned to a JDK 17 image with no image param, so it cannot
  build this JDK 21 app; the curated `maven-jdk21` library Task is why.
- **Deploy target + Route:** the pipeline deploys into its own `-cicd` namespace to stay self-contained,
  and its `deploy` step creates the Service and an edge-terminated Route itself (no hand `oc expose`).
  The parasol-claims prod profile needs a PostgreSQL datasource, so the pipelines-fundamentals entry state must provide a
  `claims-db` in the target namespace (reuse the config-multienv/storage-stateful pattern) for a healthy end state.
- **PaC `pipelineRef` must use the cluster resolver.** `.tekton/pull-request.yaml` resolves the
  in-namespace Pipeline via `resolver: cluster` (kind/name/namespace=`{{ target_namespace }}`), NOT a
  bare `pipelineRef: {name: …}`. PaC resolves a name-only ref from the repo's `.tekton` dir or a
  remote-pipeline annotation, never from the run namespace, so a name-only ref fails the webhook with
  `cannot find referenced pipeline parasol-claims-build-test-deploy` (pipelines-fundamentals-build, 2026-07-10).
- **Gitea PaC needs `git_provider` on the `Repository` CR.** Without it the webhook is rejected with
  `failed to find git_provider details in repository spec`. The pipelines-fundamentals entry state ships `git_provider`
  (type gitea, url, and secret/webhook_secret refs to `gitea-pac-secret`) so the attendee only creates
  the Secret + the Gitea webhook. Gitea webhook signatures are not validated by PaC (webhook-secret is
  still required as the shared trust string).
