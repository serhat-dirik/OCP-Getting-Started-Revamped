# stack: appsec

The platform prerequisite for the standing **application-security service** used by **M08 — DevSecOps**.
Installs **SonarQube Community Build** (SAST) as an Argo CD Application. Workshop-agnostic: no users,
no per-user wiring — that is the M08 entry state's job.

```bash
./argocd-bootstrap/install.sh --stacks appsec
# together with the dev-loop + trust bases M08 also leans on:
./argocd-bootstrap/install.sh --stacks core-devtools,trust,appsec
```

## What it installs

| Component | Source | Config |
|---|---|---|
| `sonarqube` | SonarSource Helm chart `sonarqube` **2026.3.1** (kustomize `helmCharts` inflation) | Community Build (`community.enabled=true`), `OpenShift.enabled=true` / `createSCC=false`, external PostgreSQL (`jdbcOverwrite`), 5Gi PVC, edge Route, `sonar.forceAuthentication=false` (anonymous dashboard read), bootstrap hook Job (admin-password change + `GLOBAL_ANALYSIS_TOKEN` mint → `sonar-ci-token`) |

Everything is one self-contained Application (`pp-sonarqube`), wave-ordered internally: Namespace (−2) →
external DB + RBAC (−1) → chart + Route (0) → bootstrap hook (1). This mirrors `pp-rhacs-central`.

### Why the chart is inflated by kustomize (not a native Helm-source app)

The fable-owned `argocd-bootstrap/stack-app.template.yaml` rewrites **every** child Application's
`spec.source.repoURL` to the install `--repo-url`. A native Helm-**chart**-source child (repoURL = the
SonarSource chart repo) would be clobbered by that rewrite. Sourcing this component from the **monorepo
path** and inflating the chart via kustomize `helmCharts` (the Argo instance already runs
`--enable-helm`) keeps the rewrite a harmless no-op and follows the "every component is a kustomize dir"
convention. See the friction note in the M08 handoff — this is worth a look when a stack legitimately
needs an external Helm chart repo.

## Node prereq (HIGH — may need cluster-admin)

SonarQube's embedded Elasticsearch requires `vm.max_map_count >= 262144`. In OpenShift mode the chart's
privileged sysctl initContainer is disabled (restricted-v2 SCC), so the **node** must carry the sysctl.

```bash
oc get nodes -o name | head -1 | xargs -I{} oc debug {} -q -- chroot /host sysctl vm.max_map_count
# if below 262144, apply the shipped Tuned (runtime sysctl, NO node reboot):
oc apply -f platform-portfolio/components/sonarqube/node-tuning/sonarqube-vm-max-map-count.yaml
```

Many clusters already satisfy this (ODF/Ceph nodes ship 262144). The `sonarqube` pod's Elasticsearch
CrashLoops with `vm.max_map_count [65530] is too low` until the node value is raised.

## The token contract (consumed by M08)

The bootstrap Job stores a CI analysis token in `sonarqube/sonar-ci-token` (keys `sonar-token` +
`sonar-host-url = http://sonarqube.sonarqube.svc:9000`). The M08 entry state copies it per-user into
`{user}-cicd/sonar-auth` (the M09 rox-token copy pattern); the `sonar-scan` task reads it there. The
token value is never logged.

## Footprint

- **SonarQube**: 1 web pod (web + embedded Elasticsearch) ~2Gi request / 4Gi limit + a small external
  PostgreSQL (256Mi/512Mi). One 5Gi PVC (Sonar data) + one 5Gi PVC (DB).

## Verify

```bash
oc get application pp-sonarqube -n openshift-gitops                       # Synced / Healthy
oc get deploy sonarqube sonar-db -n sonarqube                            # both Available
oc rollout status deploy/sonarqube -n sonarqube                          # web + ES up
oc get route sonarqube -n sonarqube -o jsonpath='{.spec.host}'; echo     # dashboard URL
oc get secret sonar-ci-token -n sonarqube                                # CI token minted
curl -ks "https://$(oc get route sonarqube -n sonarqube -o jsonpath='{.spec.host}')/api/system/status"
```

## Uninstall

Delete the stack Application (`oc delete application pp-sonarqube -n openshift-gitops`) — prune removes
the component. The two PVCs (`sonar-db`, the chart's data PVC) are left in place; remove manually if
desired.
