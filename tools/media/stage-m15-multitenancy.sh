#!/usr/bin/env bash
# Stage multi-tenancy-workload-security ({user}-dev) for the media pass — exercise 1's SCC rejection.
#
# The entry state ships root-demander at replicas: 0 (a 0-replica Deployment is Healthy, so `ws prep`
# converges). Scaling it to 1 is the attendee's own first action and is what produces the admission
# refusal the shot is of. selfHeal is off on the entry app, so the scale sticks.
#
# Does NOT run `ws start` (that PURGES {user}-dev). Idempotent.
# Verified end to end on the capture cluster as user7, 2026-08-01.
set -euo pipefail
USER_ID="${1:?usage: stage-m15-multitenancy.sh <userN>}"
NS="${USER_ID}-dev"

oc scale deploy/root-demander -n "$NS" --replicas=1

# The refusal is emitted by the REPLICASET controller, not the Deployment: the pod is never created,
# so there is no pod object to carry the event. Poll for the FailedCreate rather than sleeping — an
# empty Events tab is a valid screenshot of nothing.
rs=""
for _ in $(seq 1 30); do
  rs=$(oc get rs -n "$NS" -l app=root-demander \
        -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{"\n"}{end}' | head -1)
  if [[ -n "$rs" ]] && oc get events -n "$NS" \
        --field-selector "involvedObject.name=${rs},reason=FailedCreate" -o name | grep -q .; then
    break
  fi
  sleep 2
done
msg=$(oc get events -n "$NS" --field-selector "involvedObject.name=${rs},reason=FailedCreate" \
        -o jsonpath='{.items[0].message}' 2>/dev/null || true)
grep -q "unable to validate against any security context constraint" <<<"$msg" \
  || { echo "no SCC rejection event on rs/${rs:-<none>}: ${msg:-<empty>}" >&2; exit 1; }

echo "staged $NS: root-demander 0/1, rs/$rs carries the restricted-v2 FailedCreate"
echo "shoot the events at /k8s/ns/$NS/replicasets/$rs/events (the Deployment's own Events tab does not own this event)"
