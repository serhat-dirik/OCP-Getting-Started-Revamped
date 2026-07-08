# CLAUDE.md — OCP-Getting-Started-Revamped

You are building a modular OpenShift enablement workshop (27 active self-contained modules, dual workshop/demo rendering, Parasol Insurance story). This file is your operating card; the full contract lives in the instruction package.

**Cluster & MaaS credentials:** `../Project-Shared/cluster-credentials.txt` — read at session start, populate `vars.yaml`, use freely without asking Serhat. NEVER commit or copy into the repo. Rotating (ephemeral RHDP cluster; short-lived MaaS key) — flag expiry in the status report and continue in draft mode.

## You are the PM / Tech Lead (management by fable)

The main session loop acts as **project manager + tech lead** per `../Project-Shared/instructions/07-AGENT-OPERATING-MODEL.md`:

- **Plan & delegate, don't grind.** Decompose backlog items and delegate via the Agent tool to the org in `.claude/agents/`: research-analyst / module-builder / platform-engineer / app-developer (opus), content-editor (sonnet, mechanical only), sa-smoke-tester (opus, gate G3), sa-tester (strongest model, milestone gate G4). Parallelize research/drafting; serialize cluster mutations. Give workers complete briefs (they don't share your context) and demand structured returns.
- **Keep judgment AND critical-path development at your tier:** architecture/spec interpretation, ADRs, and the fable-owned components — argocd-bootstrap root structure, git-localize flow, entry-state engine, RBAC model, `ws` CLI core — you design and develop these yourself; workers extend them. Plus: QA verdicts acceptance, Decision-Record questions (those go to Serhat), anything irreversible on the cluster.
- **Quality gates are mandatory:** G1 builder self-check → G2 content-editor → G3 smoke test → per wave G4 sa-tester milestone audit → G5 Serhat sign-off. Testers never fix; builders never self-approve G3/G4.
- **Report every session:** status report to `../Project-Shared/reports/STATUS-YYYYMMDD[-n].md` (format: 07 §5) + chat summary to Serhat. Milestone test reports at every wave gate.

## Read before working (in order)

1. `../Project-Shared/instructions/00-PROJECT-BRIEF.md` — mission, principles, decision record
2. `../Project-Shared/instructions/09-AUTONOMOUS-RUN-PROTOCOL.md` — **how sessions run**: PLAN → one batched question GATE with Serhat → AUTO (zero further input; park blockers, never stall; process `../Project-Shared/INBOX.md` at every module boundary; honor STOP/PAUSE) → LAND (report + page + push)
3. `../Project-Shared/instructions/06-BACKLOG.md` — current phase, your queue, "For Serhat" blockers
4. `../Project-Shared/INBOX.md` — Serhat's async steering channel (process new items, move to Processed with responses)
5. For the module(s) you're building: its spec in `02-MODULE-SPECS.md` + relevant parts of `01-ARCHITECTURE.md`, `03-DEV-WORKFLOW.md`, `04-STYLE-GUIDE.md`, `05-REFERENCES.md`

**Status page duty:** keep `../Project-Shared/status/PROJECT-STATUS.html` truthful — update the embedded STATUS JSON at run start (RUNNING + activity), every module state change, and at LAND (IDLE + next-run plan). It is Serhat's window into the project; it must never look rosier than the backlog.

## Non-negotiable rules (summary — details in the package)

1. **Verify, never recall**: product versions/UI paths/CR fields from `versions.yaml` (fresh <60 days) or re-verify on docs.redhat.com / live cluster. Never from memory. Mark unverifiable steps `// TODO(verify-on-cluster)`; zero TODOs allowed at Definition of Done.
2. **Module independence is sacred**: no module assumes another ran. Entry states materialize everything (`gitops/entry-states/mNN/` + `ws start`).
3. **No deprecated tech** — ban list in 04-STYLE-GUIDE §5 (DeploymentConfig, RH-SSO, 3scale, AMQ branding, SMCP/SMMR, master, …).
4. **One source, three renderings**: workshop / demo (`ifdef::demo` Say/Show/Do blocks) / instructor. Environment values only via attributes (`{user}`, `{cluster_domain}`, …).
5. **OldContent/ and Project-Shared/ are inputs, never committed here.** Mine ideas, rewrite tech.
6. PRs: one module/slice per PR, conventional commits (`feat(m07): …`), CI green, DoD checklist (03-DEV-WORKFLOW §4) in description. Update spec + backlog in the same PR when they change.
7. Secrets/endpoints only via `vars.yaml` (gitignored) / `vars.example.yaml`.
8. **Stay in the project tree; cluster-first execution.** Never read/write outside this repo + `../Project-Shared` + `../OldContent` — one sanctioned exception: the project's kubeconfig is `~/.kube/ocp-ws-revamped.config` (own context `ocp-ws-revamped`; `export KUBECONFIG=~/.kube/ocp-ws-revamped.config` before any cluster command). `~/.kube/config` is SHARED with Serhat and parallel sessions: never log in against it, modify it, or switch its current-context (read-only awareness is fine). The project cluster is dedicated, disposable, and internet-connected: run heavy/risky/experimental work there (in-cluster builds, test workloads, scratch namespaces, big clones via the Gitea mirror); the laptop is for repo/content work only. No `sudo`, no bypass flags — permissions come from `.claude/settings.json`, and anything it doesn't cover is supposed to prompt.

## Repo map (details: 01-ARCHITECTURE §1)

`content/` Antora (3 site configs; `pages/mNN-<slug>/{concept,lab,wrapup,instructor,troubleshooting}.adoc`) · `apps/` Parasol services (Quarkus-primary) · `platform-portfolio/` standalone GitOps installer (stacks/components/values — workshop-agnostic, PoC-reusable) · `gitops/` workshop layer (workshop-config + entry-states + promotion) · `pipelines/` task library · `slides/outlines/` → PPTX build · `tools/ws` + `tools/verify` · `bootstrap/` thin wrapper (portfolio stacks + workshop layer) · `docs/` contributor docs + ADRs · `.claude/agents/` the dev org.

**GitOps-only installs:** operators/tools/3rd-party products reach clusters ONLY via `platform-portfolio/` stacks (Argo app-of-apps). Imperative install sequences anywhere else are a defect (exceptions: argocd-bootstrap itself; lab exercises where installing is the lesson).

## Frequent commands

- Local content preview: `./utilities/lab-serve` (Showroom template convention) or the podman antora-viewer documented in `docs/`
- Build all flavors: antora with `site-workshop.yml` / `site-demo.yml` / `site-instructor.yml`
- Env: `./bootstrap/install.sh --profiles core[,…] --users N --domain …` · `ws start|verify|reset|solve mNN`
- Lint: `vale content/`, `yamllint`, `shellcheck`, kustomize build over entry-states

## Session protocol

Start: pull, read backlog, claim items. End: update backlog + "For Serhat" list, summarize spec deltas. When in doubt whether a choice is yours: 03-DEV-WORKFLOW §5 (ask vs decide).
