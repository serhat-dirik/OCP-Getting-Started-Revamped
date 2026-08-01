#!/usr/bin/env bash
# Stage service-mesh-advanced-gateways ({user}-mesh) for the media pass — exercise 1's enrollment.
#
# Adds the per-workload injection label to the three app tiers, which is both the subject of shot 05
# (the label on the pod template) and the precondition for every Kiali shot: an un-enrolled namespace
# draws no sidecars, so the graph has no mesh edges to photograph.
#
# Does NOT run `ws start` (that PURGES {user}-mesh). Idempotent — re-patching an already-labelled
# Deployment is a no-op and triggers no second rollout.
# Verified end to end on the capture cluster as user7, 2026-08-01.
set -euo pipefail
USER_ID="${1:?usage: stage-m19-mesh.sh <userN>}"
NS="${USER_ID}-mesh"

for d in parasol-web parasol-claims parasol-fraud; do
  oc patch deploy "$d" -n "$NS" --type=merge \
    -p '{"spec":{"template":{"metadata":{"labels":{"sidecar.istio.io/inject":"true"}}}}}'
done
for d in parasol-web parasol-claims parasol-fraud; do
  oc rollout status "deploy/$d" -n "$NS" --timeout=180s
done

# Enrollment is only real if a sidecar actually joined: an injection label on a namespace istiod is
# not watching produces a labelled Deployment and 1/1 pods, which looks identical in YAML and is the
# exact failure a "the label is there" check would wave through.
#
# LOOK IN initContainers, NOT containers. Istio 1.28 (OSSM 3) injects a NATIVE sidecar — a Kubernetes
# sidecar container, which is an initContainer carrying restartPolicy: Always. A check that greps
# .spec.containers for istio-proxy finds nothing on a perfectly injected pod and reports the mesh
# broken; it cost a false "injection did not happen" here on 2026-08-01, against pods that were
# already 2/2 and serving. Accept either shape so this keeps working if a future release moves back.
for d in parasol-web parasol-claims parasol-fraud; do
  n=$(oc get pods -n "$NS" -l "app=$d" \
        -o jsonpath='{range .items[*]}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}' \
        | grep -c istio-proxy || true)
  [[ "$n" -ge 1 ]] || { echo "$d has no istio-proxy sidecar — injection did not happen" >&2; exit 1; }
done

echo "staged $NS: parasol-web/claims/fraud carry sidecar.istio.io/inject=true and are running with istio-proxy"
