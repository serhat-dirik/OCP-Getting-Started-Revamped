# AGENTS.md — operating card for any coding agent

This repo can be worked by hand or with a coding agent. If you're an AI coding agent (any tool — the rules
below are not specific to one), read this first, then treat **[CLAUDE.md](CLAUDE.md)** as the full operating
card: it's tool-named for historical reasons, but everything in it applies to any agent.

Contributors working by hand: you don't need this file — start at the README's **Contributing** section.

## The non-negotiables (short form)

1. **Verify, never recall.** Product versions, UI paths, CR fields, model/endpoint contracts come from
   `versions.yaml` (kept fresh) or get re-verified against current docs / a live cluster — never from memory.
   Mark anything you couldn't verify `// TODO(verify-on-cluster)`.
2. **Perform first, write second.** Every command block shows output you actually captured on a real cluster;
   every timing is measured; console click-paths are grounded live.
3. **Module independence is sacred.** No module assumes another ran. Entry states materialize everything.
4. **One source, three renderings.** Workshop / demo / instructor build from one AsciiDoc source; environment
   values only via attributes (`{user}`, `{ocp_console_url}`, …) — a hardcoded URL fails CI.
5. **GitOps-only installs.** Operators/tools reach clusters only via `platform-portfolio/` stacks, never
   imperative install steps (except where installing *is* the lesson).
6. **Secrets/endpoints only via gitignored `vars.yaml`.** Never commit credentials, tokens, or live cluster
   domains — CI has a privacy guard.

## Where to work

- Content: `content/` (pages at `modules/ROOT/pages/<slug>/…`) — the module contract is
  [docs/module-template/README.md](docs/module-template/README.md); style in
  [docs/authoring-conventions.md](docs/authoring-conventions.md).
- Platform/GitOps: `platform-portfolio/`, `gitops/`, `bootstrap/`, `tools/`.
- Preview: `npm run build:workshop` (`:demo` / `:instructor`) or `./utilities/lab-serve`.
- Lint before you push: `vale content/`, `yamllint .`, `shellcheck`.

The full rules, repo map, and hard-earned session practices — including the ones that cost real debugging
time — live in **[CLAUDE.md](CLAUDE.md)**. Read it before making changes.
