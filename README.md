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

27 active modules in four blocks — **A Foundations** (M01–M05, M23) · **B Delivery & Trust** (M06–M11, M29) · **C Platform & Tenancy** (M12–M15) · **D Advanced Electives** (M16–M28). Any module can be someone's first: entry states are materialized per user by automation (`ws start m09`), never by "please complete the previous module."

Recommended paths: 3-day flagship (`WS-FULL-3D`), 2-day compressed, 1-day developer / DevOps days, and 45-minute demo picks. SAs compose any subset.

## Quickstart

```bash
# 1. Stand up a cluster's platform (any OpenShift 4.20+, cluster-admin)
./bootstrap/install.sh --profiles core --users 5 --domain apps.cluster-x.example.com

# 2. Preview the content locally (builds run from content/ — see docs/authoring-conventions.md)
npm run build:workshop   # or: ./utilities/lab-serve

# 3. Materialize a module for a user
tools/ws/ws start m01 --user user1
```

> Provisioning details, profiles, and sizing: `bootstrap/` · Authoring a module: `docs/module-template/`

## Status

Pre-v1.0, under active build. Progress, phase status, and the module state grid live in the project status page (internal).

## Credits

This workshop reuses and modernizes patterns from earlier Red Hat enablement assets and community workshops — see [CREDITS](CREDITS.md). Deprecated-era technical content is never ported; everything is re-verified against current product docs.
