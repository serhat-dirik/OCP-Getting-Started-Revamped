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

`platform-orientation/` is the exemplar — deliberately minimal so the *engine* is what gets exercised.
