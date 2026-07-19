# OpenShift Application Platform — Getting Started

A modern, modular **OpenShift enablement workshop**: 26 self-contained modules that take developers, DevOps engineers, and architects from "I have credentials to a cluster" to "I can develop, deliver, and operate applications on OpenShift — and I know why the platform works this way."

The same content base doubles as a **presenter-led demo kit** for Red Hat Solution Architects: every module renders as an attendee workshop guide, an SA demo guide (talk track + click path), and an instructor runbook — from one AsciiDoc source.

> Working codename: *OCP-Getting-Started-Revamped*. Story universe: **Parasol Insurance** — attendees join Parasol's engineering org and take its claims platform from first deployment to a governed, observable, AI-assisted application platform.

## What's here

| Directory | What it is |
|---|---|
| `content/` | Antora/Showroom content — one source, three renderings (`site-workshop.yml`, `site-demo.yml`, `site-instructor.yml`) |
| `apps/` | Parasol Insurance sample services (Quarkus-primary, deliberate polyglot moments) |
| `platform-portfolio/` | **Standalone GitOps installer** — operators/tools as composable Argo CD stacks, replicable on any OpenShift 4.20+ cluster. Workshop-agnostic; also usable alone for SA PoC/demo clusters. See its [README](platform-portfolio/README.md) |
| `gitops/` | Workshop layer on top of the portfolio: users/RBAC/quotas, Gitea seeding, per-module **entry states**, promotion structures |
| `pipelines/` | Parasol company task library + per-module pipeline definitions |
| `slides/` | Per-module slide outlines (source of truth) + PPTX build tooling |
| `tools/` | `ws` CLI (`ws start\|verify\|reset\|solve <module>`) + per-module verify scripts |
| `bootstrap/` | Cluster installer: portfolio stacks + workshop layer in one command |
| `docs/` | Contributor docs, ADRs, module authoring template |

## Module library

26 active modules today in four blocks — **A Foundations** (M01–M06) · **B Delivery & Trust** (M07–M13) · **C Platform & Tenancy** (M14–M17) · **D Advanced Electives** (M18–M26). The catalog is elastic: modules are split, combined, or added when analysis shows it serves attendees better. Any module can be someone's first: entry states are materialized per user by automation (`ws start m07`), never by "please complete the previous module."

Session composition is a delivery-time choice: recommended enablement paths, module selection, and demo picks live in the [SA provisioning guide](docs/sa-provisioning-guide.md) — attendees see only the modules their session includes.

## Quickstart

```bash
# 1. Configure the install — ALL inputs live in one gitignored vars file (the installer takes no flags)
cp bootstrap/vars.example.yaml bootstrap/vars.yaml
# edit bootstrap/vars.yaml: users, cluster_domain ("" auto-detects), lightspeed + MaaS key, auth/resilience

# 2. Stand up the cluster's platform + workshop layer (any OpenShift 4.20+, cluster-admin)
./bootstrap/install.sh

# 3. Preview the content locally (builds run from content/ — see docs/authoring-conventions.md)
npm run build:workshop   # or: ./utilities/lab-serve

# 4. Materialize a module for a user
tools/ws/ws start m01 --user user1
```

> Provisioning details, profiles, and sizing: `bootstrap/` · Authoring a module: `docs/module-template/`

### Uninstall

The workshop installs onto an existing cluster non-invasively and reverses cleanly — operators, config, and namespaces the org already had are never touched:

```bash
./bootstrap/ogsr-uninstall.sh --dry-run   # preview the WIPE / PRESERVE plan; change nothing
./bootstrap/ogsr-uninstall.sh             # remove the workshop (adopted operators + prior cluster state preserved)
```

Runbook and the non-invasive guarantees: `docs/sa-provisioning-guide.md`.

## Status

**Content-complete.** All 26 modules pass the milestone QA gate and the workshop is deliverable end-to-end on any OpenShift 4.20+ cluster. Remaining work is finishing polish — media capture, the slide deck, contributor-doc cleanup — none of which blocks running a cohort. Progress detail and the module state grid live in the project status page (internal).

## Contributing

Every contribution — a new module, a fix, a diagram — goes through the same door: read the conventions, do the work on a real cluster, show the output you actually captured, keep CI green. Write it by hand or with a coding agent's help; the bar is the same either way.

**First, the private-material convention (everyone).** Create a sibling folder `../Project-Shared/` **outside the repo** for anything private — cluster credentials, notes, your own backlog. It can't be committed by accident because it isn't in the tree. Then copy `vars.example.yaml` → `vars.yaml` (gitignored) and point it at your cluster. Never put credentials, tokens, or live cluster domains in tracked files — CI has a privacy guard, and reviews enforce it.

**The authoring workflow.**
1. Read [docs/authoring-conventions.md](docs/authoring-conventions.md) and the [module template](docs/module-template/README.md) — the template is the contract every module meets (five pages, three renderings, dual-path tabs).
2. Do the work against a live OpenShift cluster: perform each step, capture the real output, measure the timings, ground the console click-paths as you go. Nothing ships from memory.
3. Preview locally — `npm run build:workshop` (also `:demo`, `:instructor`) or `./utilities/lab-serve` — and lint: `vale content/`, `yamllint .`, `shellcheck`.
4. External contributors open a pull request; maintainers push to `main`. CI must be green.

**The quality bar** (identical whether written by hand or with an agent): every command block shows real captured output; every timing is measured; console paths are grounded live; entry states keep each module independent; CI is green.

**Using a coding agent (optional).** This repo was built by its owner working alongside an AI coding agent, and it's laid out so you can do the same with whatever agent you prefer. [CLAUDE.md](CLAUDE.md) is the agent operating card — tool-named for historical reasons, but the rules inside it are agent-agnostic (verify-never-recall, module independence, dual-path tabs, GitOps-only installs). Point your agent at it and the workflow above is unchanged. See [AGENTS.md](AGENTS.md) for the agent-neutral entry point.

## Credits

This workshop reuses and modernizes patterns from earlier Red Hat enablement assets and community workshops — see [CREDITS](CREDITS.md). Deprecated-era technical content is never ported; everything is re-verified against current product docs.
