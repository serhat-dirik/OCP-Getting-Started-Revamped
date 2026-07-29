#!/usr/bin/env bash
# Restore M12 after the alert shot, then drive the HPA to its ceiling — for the capture harness.
#
# TWO THINGS THE OLD `pre_sh:` ONE-LINER GOT WRONG, both of which produced a valid PNG of the
# wrong thing rather than an error:
#
#  1. It scaled claims-db back to 1 and stopped. The claims app holds a POISONED CONNECTION POOL
#     after the database disappears — lab.adoc says so, and jobs-m12-alerts.yaml's own trailer
#     calls the rollout restart "not optional". Without it parasol-claims stays unhealthy and the
#     Topology shot shows a broken app.
#  2. It created the HPA and waited 120s with no load. An idle HPA settles at its FLOOR, so the
#     shot showed two pods while its caption promised the ring growing to four.
#
# It also ran `oc set resources --requests=cpu=100m`, which contradicts the module: the entry
# state deliberately sets 200m and the lab names that number as the HPA's denominator. Changing it
# under the reader is a content bug, so it is gone.
#
# The burst here DOES run in-cluster (`oc run`, exactly the lab's own command) because nothing is
# time-boxed — unlike the alert window, waiting for the pod to schedule costs nothing.
#
# The script FAILS if the deployment never reaches the ceiling, so capture.py skips the job
# instead of photographing a two-pod ring.
#
# Usage: tools/media/stage-m12-hpa.sh [user]     (default user1)
set -euo pipefail

USER_N="${1:-user1}"
NS="${USER_N}-dev"
CEILING=4
DEADLINE_S=420

echo "▶ M12 HPA staging for ${NS}"

echo "  restoring claims-db and recycling the app's connection pool"
oc scale deploy/claims-db -n "${NS}" --replicas=1
oc rollout status deploy/claims-db -n "${NS}" --timeout=180s
oc rollout restart deploy/parasol-claims -n "${NS}"
oc rollout status deploy/parasol-claims -n "${NS}" --timeout=300s

# Idempotent: a re-run must not die on "already exists", and must not silently keep an HPA with
# different bounds from a previous attempt.
oc delete hpa parasol-claims -n "${NS}" --ignore-not-found
oc autoscale deploy/parasol-claims -n "${NS}" --cpu-percent=60 --min=2 --max="${CEILING}"

echo "  starting the in-cluster load burst (lab exercise 5's own command)"
oc delete pod claims-burst -n "${NS}" --ignore-not-found --wait=true
# shellcheck disable=SC2016  # deliberate: $(seq …) must expand INSIDE the pod, not on this machine
oc -n "${NS}" run claims-burst --image=registry.redhat.io/openshift4/ose-cli:latest --restart=Never -- \
  /bin/bash -c 'for i in $(seq 1 20); do ( while true; do \
    curl -s -o /dev/null http://parasol-claims:8080/api/claims/CLM-1001/history; \
    curl -s -o /dev/null http://parasol-claims:8080/api/claims; done ) & done; wait'

echo "  waiting up to ${DEADLINE_S}s for the HPA to reach ${CEILING} ready replicas"
deadline=$(( $(date +%s) + DEADLINE_S ))
ready=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
  ready="$(oc get deploy parasol-claims -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  ready="${ready:-0}"
  if [ "${ready}" -ge "${CEILING}" ]; then
    break
  fi
  sleep 10
done

if [ "${ready}" -lt "${CEILING}" ]; then
  echo "❌ parasol-claims reached only ${ready}/${CEILING} ready replicas — the shot would show a ring that never grew." >&2
  echo "   Inspect: oc get hpa parasol-claims -n ${NS}; oc logs pod/claims-burst -n ${NS}" >&2
  echo "   Clean up: oc delete pod claims-burst -n ${NS} --ignore-not-found" >&2
  exit 1
fi

echo "✅ ${ready}/${CEILING} replicas ready and the burst is still running — shoot now."
echo "   AFTERWARDS: oc delete pod claims-burst -n ${NS} --ignore-not-found"
