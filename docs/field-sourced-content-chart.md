# FSC bootstrap chart — design reference (`helm/bootstrap/`)

Maintainer reference for the Field-Sourced-Content (FSC) entrypoint chart. It implements the
Wave-2 wrapper described in `docs/research/field-sourced-content-note.md` §6 and reuses the
Wave-1 non-invasive machinery from `docs/research/delivery-hardening-plan.md`. User-facing
ordering lives in `helm/bootstrap/README.md`; this file documents *how it maps to the existing
install path* and the decisions a future maintainer needs.

## Where it fits

RHDP applies one Argo CD `Application` (`field-content`) at `helm/bootstrap`. The chart renders
child Applications that **reuse** `platform-portfolio/stacks/*` and `gitops/workshop-config`
(no content duplicated) plus in-cluster Jobs that reproduce the imperative `oc` work
`bootstrap/install.sh` does today. The chart is the declarative twin of `install.sh`; the two
paths converge on the same cluster objects, so `bootstrap/ogsr-uninstall.sh` uninstalls either.

## Imperative → declarative map

Every imperative step in `bootstrap/install.sh` is expressed as a chart mechanism:

| `install.sh` step | Chart mechanism |
|---|---|
| `[0/6]` uninstall-state capture (ns + CM + monitoring/gitops/gatewayclass snapshot) | `templates/job-state-capture.yaml` (Sync hook, wave -10) |
| node substrate (batch pool label+taint, synthetic zones) | `templates/job-node-shaping.yaml` (wave -9) |
| `[1/6]` install portfolio stacks | `templates/applications.yaml` — child `pp-*` Applications (waves 0-1) |
| `[2/6]` 2a htpasswd Secret | `templates/job-workshop-users.yaml` init container (httpd image → memory emptyDir) |
| `[2/6]` 2a' OAuth IdP append-if-absent | same Job's `oc` container (records `oauth_idp_ownedbyus`) |
| `[2/6]` 2b MaaS Secret (guarded) | `templates/job-maas-secret.yaml` (wave -8, `if litemaas.enabled`) |
| `[3/6]` wait for the Gitea mirror | sync-wave gating: wave-1 children are created only after `pp-core-devtools` (wave 0, contains git-mirror) is Healthy |
| `[4/6]` shared-password Secret in the gitea ns | `templates/job-gitea-seed-secret.yaml` (wave 1, polls for the ns) |
| `[5/6]` materialize `workshop-config` from the mirror | `templates/applications.yaml` — `workshop-config` Application (wave 2) |
| `[6/6]` wait for Healthy | Argo reconciliation + `demo.redhat.com/application` health labels |

Deliberately left script-only: the GitOps-operator install + controller RBAC/resources
(`platform-portfolio/argocd-bootstrap/`). Under FSC the platform installs GitOps *before*
`field-content`, so the chart assumes Argo CD already exists — it cannot bootstrap the very
controller that renders it. On a BYO cluster, run `argocd-bootstrap/install.sh` (or Option B1)
first.

## Topology: why the anchor is sourced from GitHub

The portfolio bundles `gitea` + `git-mirror` inside the `core-devtools` stack. The mirror
therefore cannot be fully self-hosted at wave 0: you cannot source the mirror-builder from the
mirror it builds. So:

- **wave 0** `pp-core-devtools` is sourced from `gitops.repoURL` (GitHub) — it is the anchor
  (its internal waves deploy gitea, then the git-mirror job).
- **wave 1+** everything else (`pp-batch`, optional stacks, `workshop-config`) is sourced
  **from the in-cluster mirror** — the git-localize payoff.

A cleaner topology (clean top-level `gitea`/`git-mirror` waves with *every* stack sourced from
the mirror) needs the portfolio to extract gitea+git-mirror into their own always-from-GitHub
stack. That is a portfolio change, out of scope for this additive chart — see the backlog note
in the session report.

## Uninstall-state contract

The Jobs write these keys into `ogsr-uninstall-state` (namespace `ogsr-system`), which
`bootstrap/ogsr-uninstall.sh` reads. Keys use first-write-wins so the true prior state survives
idempotent re-syncs: `monitoring_cm_existed`, `monitoring_uwm_prior`, `gitops_preexisted`
(+`gitops_argocd_controller_resources_b64`), `gatewayclass_preexisted`, `lightspeed_preinstalled`,
`lightspeed_ns_created`, `lightspeed_secret_created`, `oauth_idp_ownedbyus`, `nodes_batch`,
`nodes_zoned`, `installed_stacks`.

Not written under FSC: the per-operator `op_<subscription>` adoption snapshot (install.sh's
`snapshot_operators` needs the repo checkout + `yq`, which an in-cluster Job lacks). Missing
`op_*` keys degrade safely — `ogsr-uninstall.sh` treats an operator with no record as `unknown`
and **preserves** it. Consequence: an FSC-then-BYO-uninstall leaves shared-namespace operator
Subscriptions we created (dedicated-namespace ones still go with their namespace). Acceptable
because FSC de-provisioning destroys the whole cluster; flagged as backlog for the BYO case.

## On-cluster validation (TODO(verify-on-cluster))

Nothing below is exercisable off-cluster. On a disposable / scratch cluster:

1. Point a `field-content` Application at `helm/bootstrap` (Option B2 in the README) and confirm
   the wave order actually holds: `ogsr-state-capture` completes before `pp-core-devtools` mutates
   anything; `pp-batch` is not created until the mirror is populated.
2. `oc get cm ogsr-uninstall-state -n ogsr-system -o yaml` → sane keys on both a greenfield and an
   operator-pre-loaded cluster.
3. The `ogsr-workshop-users` init container's `htpasswd` binary path is present on the chosen httpd
   image; the resulting Secret logs users in at the console.
4. `oc get <kind> -A -l workshop.redhat.com/owner=ogsr` returns the full FSC footprint.
5. The `ogsr-bootstrap` ServiceAccount can patch `oauth/cluster` + label nodes on the
   RHDP-provisioned cluster (i.e. the openshift-gitops controller is cluster-admin there).
6. `bootstrap/ogsr-uninstall.sh --dry-run` then a real run: owner-labeled apps orphaned, adopted
   operators intact, `workshop-users` IdP removed while other IdPs are preserved.
7. Run twice (idempotency): re-sync does not flip a recorded prior-state key.
