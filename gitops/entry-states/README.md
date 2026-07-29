# Entry states — the self-containment engine

Every module declares the world a user needs *before* its first exercise. `ws start mNN --user userN` materializes that world as one Argo CD Application (`entry-mNN-userN`, AppProject `workshop-entries`, platform Argo instance) — see ADR-0001/0002.

## Authoring contract (per module)

```
gitops/entry-states/mNN/
├── Chart.yaml       # name: mNN-entry; description shows in `ws list`
├── values.yaml      # user, clusterDomain (injected by ws) + module defaults
├── ws-meta.yaml     # ws behavior: which namespaces `ws reset` purges of user-created leftovers
└── templates/       # everything the module needs, parameterized by {{ .Values.user }}
```

Rules:

1. **Compose, don't chain** — include everything the module needs directly; never reference another module's entry state. Duplication between charts is intentional.
2. **Namespace ownership**: per-user namespaces (`{user}-dev/stage/prod/cicd`) + quotas + RBAC belong to the *workshop layer* and survive resets. Entry charts own **in-namespace state** (workloads, seeds, module-extra namespaces like `{user}-mesh`).
3. **Reset semantics**: `ws reset` deletes the Application (finalizer prunes chart-owned state), purges user-created leftovers in the namespaces listed in `ws-meta.yaml` (`purgeNamespaces`), then re-materializes. Design your chart so running start twice is a no-op (idempotent templates only).
4. Non-manifest state (seed a Gitea repo, run a first pipeline) = Argo hook Jobs inside the chart (`argocd.argoproj.io/hook: Sync` + `BeforeHookCreation`), same discovery pattern as the portfolio's git-mirror job.
5. Secrets: never in templates. Reference cluster-provided Secrets (workshop layer contracts) by name.
6. Every template carries a one-line comment saying why it exists (style guide §7).
7. **Workshop-built images need `imagePullPolicy: Always`.** Anything under `ogsr-parasol-images/` (and per-user istags this repo builds) is tagged `1.0`/`1.1` and **rebuilt in place**, so the tag is mutable. Kubernetes defaults a non-`:latest` tag to `IfNotPresent`, and a node that has already cached that tag will happily keep serving the old layers — measured on ksls5, 2026-07-29: all three `parasol-claims` tags moved to a new digest, and `oc rollout restart` brought the *old* digest back up. Leave upstream images alone: `:latest` already defaults to `Always`, and anything pinned to a digest or a real version tag (`postgresql:15-el9`, `udi-rhel9:3.29`) should stay `IfNotPresent`. Knative Services are the one exception — Knative resolves the tag to a digest when it creates the Revision, so setting `Always` there only costs a registry round-trip on every scale-from-zero; a rebuild reaches a ksvc through `ws reset` (new Revision), not a pod restart. **Check `_helpers.tpl` too** — a named template that renders a PodSpec is invisible to a `grep` over `templates/*.yaml`, and that is exactly how `config-multienv` was missed twice (this sweep, and the Route-TLS sweep of 2026-07-27).

`platform-orientation/` is the exemplar — deliberately minimal so the *engine* is what gets exercised.
