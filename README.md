# OpenShift Application Platform — Getting Started

A modern, modular **OpenShift enablement workshop**: 27 self-contained modules that take developers, DevOps engineers, and architects from "I have credentials to a cluster" to "I can develop, deliver, and operate applications on OpenShift — and I know why the platform works this way."

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

27 active modules today in four blocks — **A Foundations** (M01–M06) · **B Delivery & Trust** (M07–M13) · **C Platform & Tenancy** (M14–M17) · **D Advanced Electives** (M18–M27). The catalog is elastic: modules are split, combined, or added when analysis shows it serves attendees better. Any module can be someone's first: entry states are materialized per user by automation (`ws start m07`), never by "please complete the previous module."

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

Pre-v1.0, under active build. Progress, phase status, and the module state grid live in the project status page (internal).

## Contributing

This project is developed **human + AI**: the content and platform were built by the project owner working with Claude (Claude Code) as PM/tech-lead, and the repo is structured so anyone can continue that way — or work entirely by hand.

**First, the private-material convention (everyone):** create a sibling folder `../Project-Shared/` **outside the repo** for anything private — your cluster credentials, notes, personal backlog. It can never be committed by accident because it isn't in the tree. Then copy `vars.example.yaml` → `vars.yaml` (gitignored) and point it at your cluster. Never put credentials, tokens, or live cluster domains in tracked files — CI has a privacy guard, and reviews enforce it.

**Contributing with Claude Code (or another coding agent):**
1. Clone, open the repo in Claude Code. [CLAUDE.md](CLAUDE.md) is the agent's operating card — it encodes the project's rules (verify-never-recall, module independence, dual-path tabs, GitOps-only installs) and the hard-earned session practices.
2. Specialized agent definitions ship in `.claude/agents/` (module-builder, platform-engineer, content-editor, smoke-tester, …) — your session can delegate to them the way the original development did.
3. Ask for a module build or fix; the agent knows to perform on a cluster first and write second. The module contract is [docs/module-template/README.md](docs/module-template/README.md).

**Contributing manually:** read [docs/authoring-conventions.md](docs/authoring-conventions.md) and the [module template](docs/module-template/README.md); preview with `./utilities/lab-serve` or `cd content && npx antora site-workshop.yml`; lint with `vale content/`, `yamllint .`, `shellcheck`.

**Quality bar for every contribution (AI or human):** every command block shows real captured output; timings are measured; console paths are grounded live; entry states keep modules independent; CI green. External contributions arrive as fork + pull request; maintainers work directly on `main`.

## Credits

This workshop reuses and modernizes patterns from earlier Red Hat enablement assets and community workshops — see [CREDITS](CREDITS.md). Deprecated-era technical content is never ported; everything is re-verified against current product docs.
