# M04 build note — Config, Secrets & Multi-Environment

Date: 2026-07-09 · Author: research-analyst R5 · Spec: 02-MODULE-SPECS §M04 (lines 60-69)
Method: live build cluster `ocp-ws-revamped` (OCP 4.21.22, k8s 1.34.8), `oc explain`, OLM packagemanifests, repo inspection. versions.yaml (2026-07-08) trusted for versions.

## Verified versions
| Product | Version | Channel | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 | stable-4.21 | `oc version` (live) | 2026-07-09 |
| External Secrets Operator | 1.1.0 | stable-v1 | packagemanifest `openshift-external-secrets-operator` (Red Hat Operators); versions.yaml | 2026-07-09 |

Cluster reality (verified live 2026-07-09):
- Namespaces `user1-{dev,stage,prod,cicd}` EXIST, labeled `workshop.redhat.com/user=user1`; PSA `warn/audit=baseline` (enforce = cluster default restricted). Source: `oc get ns -o jsonpath`.
- ResourceQuota `workshop-quota` (identical in dev+stage; prod assumed same): `limits.cpu 6, limits.memory 12Gi, requests.cpu 3, requests.memory 6Gi, pods 30, persistentvolumeclaims 5`. Source: `oc get quota -n user1-dev/-stage`.
- LimitRange `workshop-limits` (user1-dev), type Container: `default {cpu 500m, memory 1Gi}`, `defaultRequest {cpu 100m, memory 256Mi}` — NO min/max. Source: `oc get limitrange -n user1-dev -o yaml`.
- Probes on 4.21 API (`oc explain pod.spec.containers.{liveness,readiness,startup}Probe`): all three present; handlers `httpGet|tcpSocket|exec|grpc`; fields `initialDelaySeconds|periodSeconds|timeoutSeconds|successThreshold|failureThreshold|terminationGracePeriodSeconds`. Standard k8s — safe to author.
- `parasol-web` config convention (`apps/parasol-web/src/main/resources/application.properties`): Quarkus + health at `/q/health/live` and `/q/health/ready` (comment: "used in M01, M04"). This is the pattern `parasol-claims` will mirror.
- ESO owned CRDs (packagemanifest CSV v1.1.0): `ExternalSecret|SecretStore|ClusterSecretStore` at **v1 (GA)**; operator config `ExternalSecretsConfig` (operator.openshift.io/v1alpha1). Fake provider = SecretStore `spec.provider.fake` (cluster-local, no Vault). NOT installed (no CRDs on cluster).

## Spec deltas
- **App gap:** entry state assumes "claims app + DB running in {user}-dev" but `apps/parasol-claims` DOES NOT EXIST yet (only `parasol-web`, a backend-less frontend). The datasource-config exercise has no target app today. Builder must block on app-developer landing `parasol-claims`, or stand in with a catalog PostgreSQL + parasol-web.
- **ESO downstream home:** spec says ESO/Vault "full story referenced in M07/M09", but M07 = Trusted Supply Chain (ACS/RHTAS/RHTPA) and M09 = GitOps at scale — neither is a secrets-manager module. No module owns the ESO full story. PM decision needed.
- Promotion is pure `oc apply -k` (no Argo / gitops modules) per PM — spec's "preview M08" wording is fine; keep it kustomize-only.

## Approach recommendations
1. Author DB-config exercise against `parasol-claims` Quarkus datasource env levers (`QUARKUS_DATASOURCE_JDBC_URL|USERNAME|PASSWORD|DB_KIND`, MicroProfile dots→UPPER_SNAKE); gate on the app existing (fallback: catalog PostgreSQL + parasol-web).
2. Teach requests/limits by SETTING explicit values and contrasting with the inherited LimitRange defaults (limit 500m/1Gi, request 100m/256Mi) — use them, don't fight them.
3. Promote via one kustomize base + dev/stage/prod overlays seeded in the attendee Gitea repo; `oc apply -k overlays/<env>` into `user-<env>`, same image digest, per-env ConfigMap/Secret.
4. Probe break-fix: flip readiness to a failing path/flag, watch the Service hold traffic; keep timing generous (initialDelay≥5s, period≥10s) to avoid load flakes (spec watchout).
5. ESO: make it `[OPTIONAL][INSTRUCTOR-DEMO]` with a fake-provider `ClusterSecretStore`, contingent on a new `pp-external-secrets` portfolio stack; else concept-only pointer.

## Mining results
- **MAD M3 (multi-env)** → per-env namespace pattern + promotion narrative arc; discard Service Binding/3scale (banned). (05-REFERENCES §1)
- **TL500 config exercises** → ConfigMap/Secret mechanics only, skip dogma (per spec Mine).
- **`apps/parasol-web/.../application.properties`** → config-convention precedent (health path, env override) to mirror in parasol-claims.
- **MAD Roadshow deck** → Business/Dev-challenge rubric for the concept framing.

## Open risks
- `parasol-claims` absent → lab UNVERIFIABLE end-to-end today; datasource env-var names are the Quarkus convention (grounded) but exact keys + intentional flaw must be confirmed against the app README when built.
- No downstream module owns ESO/Vault "full story" (spec points at M07/M09 which don't fit) — PM/Serhat decision.
- ESO hands-on needs a net-new platform component (portfolio stack); if not added this wave, ESO stays concept-only.
- Quota: default 1Gi limit/container across ≤30 pods and 5 PVC/ns — multi-env promote is fine, but instructor watches the pvc=5 cap once DB/ESO are added.

## Builder appendix — overlay sketch (grounded: kustomize v5.7.1, oc 4.21.1 present)
```
parasol-claims-config/            # entry state seeds this into the attendee's Gitea repo
  base/
    kustomization.yaml            # resources: deployment, service, route, configmap
    deployment.yaml               # image: <registry>/parasol-claims:1.0  (SAME across envs)
    configmap.yaml                # non-secret config (log level, feature flags)
  overlays/
    dev/   kustomization.yaml      # namespace: user1-dev  ; DEV values ; replicas 1
    stage/ kustomization.yaml      # namespace: user1-stage; STAGE values; replicas 1
    prod/  kustomization.yaml      # namespace: user1-prod ; PROD values ; replicas 2
# DB creds per-env via secretGenerator (overlay-local, gitignored) or ESO later.
# promote: oc apply -k overlays/stage   (only config differs; image digest unchanged)
```
