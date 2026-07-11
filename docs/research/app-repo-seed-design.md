# Design note — automating app-repo seeding (GitOps-ifying `app-repo-publishing.md`)

**Status:** DRAFT / files-only, disabled by default — awaiting the project owner's go-ahead (2026-07-10, PM).
**Why now:** discovered while closing G4-F11 that the workshop's app repos are published *by hand*
and nothing re-publishes them. That is an imperative install sequence living outside
`platform-portfolio/`, which CLAUDE.md's GitOps-only rule forbids, and it blocks Phase 3 (M07 forks
`parasol-claims`; M11 needs `catalog-info.yaml` in forks).

## The problem, precisely

`platform-portfolio/components/git-mirror` pull-mirrors the **monorepo** into Gitea as
`parasol/ocp-getting-started`. But six repos are standalone, `mirror:false`, no upstream:

| Gitea repo | Monorepo source | Forked by |
|---|---|---|
| `parasol/parasol-claims` | `apps/parasol-claims/` | M02, M03, M04, M07 |
| `parasol/parasol-notifications` | `apps/parasol-notifications/` | M02 |
| `parasol/parasol-web` | `apps/parasol-web/` | M11 (catalog) |
| `parasol/parasol-fraud` | `apps/parasol-fraud/` | M13 |
| `parasol/parasol-service-template` | `apps/parasol-service-template/` | M11 (golden path) |
| `parasol/claims-config-template` | `gitops/promotion/claims-config-template/` | M04 |

They exist only because a human ran `docs/research/app-repo-publishing.md` once. Consequences:

1. **A fresh cluster cannot be rebuilt from `bootstrap/install.sh`.** `ws start m02` forks
   `parasol/parasol-claims`, which will not exist → the whole Foundations+Delivery path breaks.
2. **Changes under `apps/` never reach the workshop.** The M03 `.vscode/` debug files are the live
   example: committed to `apps/parasol-claims/`, invisible to the workshop.

## Two hard constraints (verified live 2026-07-10, read-only)

- **Gitea 1.26.4 has no `sync_fork` API.** Swagger advertises only `mirror-sync` and
  `push_mirrors-sync`. So an *existing* `{user}/parasol-claims` fork cannot be refreshed from its
  upstream via API. A Gitea fork is a clone taken at fork time; it never tracks.
- **`registry.redhat.io/openshift4/ose-cli` has no `git`.** The git-mirror job is curl-only, but
  splitting a monorepo subdir into a standalone repo root genuinely needs `git` (init + push). The
  seed Job needs a git-capable image.

## Design

A **workshop-layer** Sync-hook Job (`gitops/workshop-config/templates/app-repo-seed.yaml`), modelled
exactly on the existing `gitea-user-seed.yaml` (same route + admin-credential discovery, same
`BeforeHookCreation` hook so `ws git-refresh` re-runs it). It:

1. Clones the **in-cluster mirror** `parasol/ocp-getting-started` (fast, no GitHub egress) at the
   configured revision.
2. For each `repo=subdir` in a labeled ConfigMap: ensures `parasol/{repo}` exists (create via API if
   404), then **snapshots** `subdir/` into a fresh git tree and **force-pushes** it to the repo's
   default branch.

**Why snapshot + force-push, not `git subtree split`:** these are *seed* repos that attendees fork;
they want the current state of the source, not tangled monorepo history. Force-push keeps the
canonical repo byte-identical to `apps/{name}/`. Attendee **forks are unaffected** — they do not
auto-track the canonical repo (see constraint 1), which is exactly why force-push here is safe.

**Home = workshop layer, not portfolio.** The mechanism is generic, but the content (parasol apps,
monorepo subdirs) is intrinsically workshop-specific, and this sits naturally beside
`gitea-user-seed`. If we later want it reusable, lift the Job into
`platform-portfolio/components/app-repo-seed` and keep the repo→subdir ConfigMap in the workshop
layer — the same mechanism/config split git-mirror already uses. Noted, not done.

### Disabled by default — this is the important part

The template is guarded by `{{- if .Values.appRepoSeed.enabled }}` with `enabled: false` in
`values.yaml`. **Rationale:** unlike a standalone files-only stack, a template inside `workshop-config`
would be *armed* — the next Argo sync would run it and force-push the app repos, including the M03
`.vscode/` files. That force-push into the shared `parasol/*` seed repos is precisely the action the
permission guard blocked me from doing by hand (2026-07-10), and it is the project owner's call, not mine. The
flag keeps the mechanism reviewable and inert until he flips it.

### Open decisions for the project owner / verify-on-install

- `// TODO(verify-on-install)`: the git image. Draft uses `ubi9` + `dnf install -y git-core` at
  runtime (this cluster has Red Hat CDN egress). A prebuilt git image would remove the egress
  dependency — pick one before a disconnected delivery.
- **Fork staleness is NOT solved here.** This fixes the *canonical* repos, so **fresh** forks (made
  after seeding — the normal delivery order, since workshop-config seeds at bootstrap before any
  `ws start`) are correct. Refreshing an *already-forked* stale repo has no API path; the only
  mechanisms are delete-and-re-fork (**unsafe** for M03/M07, where attendees push to their fork) or a
  per-fork merge Job. Left as a separate, module-aware task.
- Sync ordering: the per-user fork jobs live in *entry-state* Argo apps, not this one, so cross-app
  wave ordering is not guaranteed. It does not need to be — the fork job self-waits and tolerates a
  pre-existing fork; the only requirement is that the seed exists *before a user forks*, which holds
  on a fresh cluster (bootstrap → seed → `ws start` → fork).
