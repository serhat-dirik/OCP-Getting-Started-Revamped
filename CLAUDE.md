# CLAUDE.md — OpenShift Application Platform: Getting Started

You are working on an **established** modular OpenShift enablement workshop: self-contained modules (catalog is elastic — currently ~27 — split/combine when it serves the end-user), a Parasol Insurance story universe, and three renderings (workshop / demo / instructor) from one AsciiDoc source. This file is the operating card for any contributor's coding agent — human newcomers: start at README "Contributing".

## Private material — the `../Project-Shared` convention

Keep EVERYTHING private in a sibling folder **outside this repo**: `../Project-Shared/` (credentials, personal notes, private backlogs). It cannot be committed by accident because it is not in the tree. After cloning, create it:

```
../Project-Shared/cluster-credentials.txt   # your cluster + model-endpoint credentials
../Project-Shared/instructions/             # (optional) your private operating overlay
```

- At session start, load credentials from `../Project-Shared/cluster-credentials.txt` into the gitignored `vars.yaml` (copy `vars.example.yaml`) and use them freely without asking the user.
- **NEVER commit or copy credentials, tokens, private emails, or live cluster domains into the repo.** CI has a privacy guard for known leak patterns, but you are the first line — evidence transcripts in docs must use placeholder domains.
- **If `../Project-Shared/instructions/` exists** (maintainer setup), read `10-SESSION-OPERATING-CARD.md` there FIRST and follow the package — it extends and overrides this card.

## Non-negotiable rules

1. **Verify, never recall.** Product versions / UI paths / CR fields come from `versions.yaml` (fresh <60 days) or get re-verified on docs.redhat.com / a live cluster — never from model memory. Mark unverifiable steps `// TODO(verify-on-cluster)`; zero TODOs at Definition of Done.
2. **Module independence is sacred.** No module assumes another ran. Entry states materialize everything (`gitops/entry-states/mNN/` + `ws start`). Same-namespace modules declare `conflictsWith` in `ws-meta.yaml` (both directions).
3. **Perform first, write second.** Every command block shows output you actually captured; every timing chip is measured; console click-paths are grounded live (labels you can't ground get `[CAPTURE-VERIFY]` + a CLI alternative).
4. **One source, three renderings.** Workshop / demo (`ifdef::demo` Say/Show/Do) / instructor. Environment values ONLY via attributes (`{user}`, `{ocp_console_url}`, …) — a hardcoded URL is a CI failure.
5. **Dual-path CLI|Console tabs are the standard** wherever a step can be done both in the terminal and the OpenShift web console. Labels exactly `Console::` then `CLI::` — site-wide tab sync groups by label text. Single path only where duality is genuinely absent (product UIs like Argo CD/RHDH/Gitea, pure-git steps, IDE-centric modules). Details: `docs/module-template/README.md` rule 12.
6. **No deprecated tech.** Ban list in `docs/authoring-conventions.md` (DeploymentConfig, RH-SSO, 3scale, AMQ branding, SMCP/SMMR, "master", …).
7. **GitOps-only installs.** Operators/tools reach clusters ONLY via `platform-portfolio/` stacks (Argo app-of-apps). Imperative install sequences are a defect (exceptions: argocd-bootstrap itself; lab exercises where installing IS the lesson).
8. **Secrets/endpoints only via gitignored `vars.yaml`** (template: `vars.example.yaml`).

## Session best practices (hard-earned — trust them)

- **Argo sync discipline:** never start a sync while an operation is Running (the patch is silently swallowed). Flow: mirror-sync → hard refresh → ~10s → sync. Stuck op: patch `status.operationState.phase=Terminating`, then a fresh sync. A poisoned manifest cache survives SHA changes and Redis flushes — **bump the chart version** to bust it.
- **In-cluster Gitea mirror setups:** after pushing content, sync the mirror and **wait until the mirror's HEAD equals origin's** before restarting Showroom deployments — cockpits build content at pod-init from the mirror; restarting early serves stale content.
- **`[tabs]` nesting:** a collapsible/NOTE inside a tab needs a 5-`=` delimiter (`=====`); same-length `====` collides ("unterminated open block").
- **Hook Jobs on OpenShift:** `ose-cli` needs ≥512Mi (oc OOMs at 256Mi); no runtime `dnf` under the restricted SCC — use purpose-built images; memory-backed emptyDir for credential handoff between init and main containers.
- **CI lint runs SIX checks** (privacy guard, vale, yamllint, shellcheck, helm, kustomize) — read the failing STEP, not just the job name.
- **Local lint via podman:** the podman machine auto-stops; "connection refused" from a linter means restart it and re-run — treat unrun gates as failed, never as passed.
- **Verify scripts are mode-split:** entry-state checks never run at completion mode; use `>=` not `==` for lab-exceedable outcomes. A false ❌ destroys attendee trust in every other ✅.

## Repo map

`content/` Antora, three site configs; pages at `modules/ROOT/pages/mNN-<slug>/{concept,lab,wrapup,instructor,troubleshooting}.adoc` · `apps/` Parasol services (Quarkus-primary) · `platform-portfolio/` standalone GitOps installer (workshop-agnostic, reusable for PoC clusters) · `gitops/` workshop layer (workshop-config + entry-states) · `pipelines/` Tekton task library · `slides/outlines/` → PPTX build · `tools/ws` CLI + `tools/verify` scripts · `bootstrap/` one-command cluster installer · `helm/bootstrap/` FSC entrypoint chart (RHDP `field-content` target; declarative twin of `bootstrap/install.sh`) · `showroom/` in-cluster cockpit build (its `site.yml` needs the workshop-owned `antora-ext` image — stock antora images fail on it) · `docs/` contributor docs, ADRs, module template, research notes · `.claude/agents/` specialized agent definitions you may delegate to.

## Frequent commands

- Preview content: `./utilities/lab-serve`, or build with `cd content && npx antora site-workshop.yml` (also `site-demo.yml` / `site-instructor.yml`)
- Stand up a cluster: copy `bootstrap/vars.example.yaml` → `bootstrap/vars.yaml`, edit it, then `./bootstrap/install.sh` (reads `vars.yaml`; no CLI flags)
- Tear down (non-invasive, adoption-aware): `./bootstrap/ogsr-uninstall.sh --dry-run` to preview the WIPE/PRESERVE plan, then `./bootstrap/ogsr-uninstall.sh`
- Module lifecycle: `tools/ws/ws start|verify|reset|solve mNN [userN]` (attendee-facing text says `ws prep`)
- Lint locally: `vale content/`, `yamllint .`, `shellcheck`, `helm lint` on charts

## Git flow

- Maintainers commit directly to `main`: one coherent slice per commit, conventional commits (`feat(m07): …`), CI green on every push. External contributors: fork + pull request, same quality bar.
- Update specs/docs in the same slice that changes behavior. Never commit `../Project-Shared` or `OldContent/` material — they are inputs; mine ideas, re-implement, credit via `CREDITS.md`.
- No `sudo`, no permission-bypass flags. Cluster-first execution: heavy or risky work runs on your disposable cluster, not the laptop.
