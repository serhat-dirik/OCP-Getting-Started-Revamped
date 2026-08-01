#!/usr/bin/env bash
# Stage networking-dev-devops ({user}-dev) for the media pass — the exercise-3 default-deny policy.
#
# Shot 01 (the three ClusterIP Services) needs nothing beyond the entry state, so it is shot first,
# BEFORE this script runs: default-deny takes parasol-claims to 0/1 and the Services page is more
# honest with the app healthy.
#
# Does NOT run `ws start` (that PURGES {user}-dev). Idempotent.
# Verified end to end on the capture cluster as user7, 2026-08-01.
set -euo pipefail
USER_ID="${1:?usage: stage-m16-networking.sh <userN>}"
NS="${USER_ID}-dev"

oc apply -n "$NS" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}          # every pod in the namespace
  policyTypes:
    - Ingress
    - Egress
EOF

# Prove the object carries the two lines the shot's caption points at, rather than trusting apply's
# exit code: an empty podSelector serialises as `{}` and both policy types must be present.
types=$(oc get networkpolicy default-deny-all -n "$NS" -o jsonpath='{.spec.policyTypes}')
[[ "$types" == '["Ingress","Egress"]' ]] || { echo "policyTypes=$types, expected Ingress+Egress" >&2; exit 1; }

echo "staged $NS: NetworkPolicy default-deny-all present, policyTypes=$types"
