#!/usr/bin/env bash
# Stage deployment-targets-scheduling ({user}-dev) for the media pass.
#
# Runs the lab's exercise 2 (required podAntiAffinity) and exercise 5 (scale to 3 + the
# PodDisruptionBudget) so shots 02 and 04 have their subject on the page. Does NOT run `ws start`
# — the jobs file does that once in the module's first row, because `ws start` PURGES {user}-dev.
#
# Shot 03 (statement-batch Pending on an untolerated taint) is deliberately NOT staged here: it
# needs a batch-pool node carrying the NoSchedule taint, which bootstrap only applies once the
# worker pool has 3+ nodes. On a sub-floor cluster the nodeSelector-only patch schedules cleanly
# and there is nothing to photograph — see the lab's own IMPORTANT block in exercise 4.
#
# Idempotent. Verified end to end on the capture cluster as user7, 2026-08-01.
set -euo pipefail
USER_ID="${1:?usage: stage-m17-scheduling.sh <userN>}"
NS="${USER_ID}-dev"

# Exercise 2 — required anti-affinity on kubernetes.io/hostname (the subject of shot 02).
oc patch deploy parasol-claims -n "$NS" --type=merge \
  -p '{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchLabels":{"app":"parasol-claims"}},"topologyKey":"kubernetes.io/hostname"}]}}}}}}'

# Exercise 5 — three healthy replicas, so minAvailable:1 leaves ALLOWED DISRUPTIONS = 2. Shooting
# the PDB at 2 replicas would render 1 and quietly contradict the lab's own expected output.
oc scale deploy/parasol-claims -n "$NS" --replicas=3
oc rollout status deploy/parasol-claims -n "$NS" --timeout=180s

oc apply -n "$NS" -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: parasol-claims
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: parasol-claims
EOF

# The PDB controller needs a moment to compute disruptionsAllowed; poll rather than sleep-and-hope,
# because a shot taken while it still reads 0 is a valid PNG of the wrong number.
for _ in $(seq 1 30); do
  allowed=$(oc get pdb parasol-claims -n "$NS" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || true)
  [[ "$allowed" == "2" ]] && break
  sleep 2
done
[[ "$allowed" == "2" ]] || { echo "PDB disruptionsAllowed=$allowed, expected 2" >&2; exit 1; }

nodes=$(oc get pods -n "$NS" -l app=parasol-claims -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')
[[ "$nodes" == "3" ]] || { echo "claims replicas share nodes ($nodes distinct), anti-affinity not in effect" >&2; exit 1; }

echo "staged $NS: parasol-claims 3 replicas on $nodes distinct nodes, PDB allowed disruptions=$allowed"
