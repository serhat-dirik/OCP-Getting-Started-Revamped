#!/usr/bin/env bash
# Produce M08's FAILED scan run — the build that passed and the gate that refused it.
#
# RUN THIS BEFORE THE CAPTURE WINDOW OPENS. It takes 6–12 minutes of pure cluster time and needs no
# browser at all, so spending the owner's one console login waiting for it would be waste. Start
# it, let it finish, then log in and shoot.
#
# WHAT IT DOES. Exactly what lab.adoc exercise 2 tells the attendee to do: submit a PipelineRun
# against the seeded `seed-vulnerable` branch, targeting a throwaway `:candidate` tag so the
# trusted `:latest` in the registry is untouched. `build-image` goes green and `acs-scan` goes red
# on the seeded Log4Shell — that contrast IS the screenshot.
#
# WHY IT IS NOT A `pre_sh:` LINE. The entry state ships only the warm CLEAN build (`warm-clean-…`,
# Succeeded). Nothing anywhere materialises a failed run, and the jobs file used to point at the
# PipelineRuns LIST page with `wait_text: PipelineRuns` — a string the list page carries whether or
# not the seeded run exists, so it would have written a valid PNG of a list holding one green run.
#
# The `taskRunSpecs` memory overrides are load-bearing and are why the lab says to use Import YAML
# rather than the Pipeline's Start form: the namespace default is 1Gi and the builds are killed
# without them.
#
# Usage: tools/media/stage-m08-scan.sh [user]     (default user1)
set -euo pipefail

USER_N="${1:-user1}"
NS="${USER_N}-cicd"
DEADLINE_S=1500

echo "▶ M08 scan-gate staging in ${NS}"

oc get pipeline parasol-claims-supply-chain -n "${NS}" >/dev/null 2>&1 || {
  echo "❌ no parasol-claims-supply-chain Pipeline in ${NS}." >&2
  echo "   Run: ./tools/ws/ws start trusted-supply-chain --user ${USER_N}   (evicts pipelines-fundamentals)" >&2
  exit 1
}

run="$(oc create -n "${NS}" -o name -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: seed-scan-
spec:
  pipelineRef:
    name: parasol-claims-supply-chain
  params:
    - name: git-revision
      value: seed-vulnerable
    - name: image
      value: image-registry.openshift-image-registry.svc:5000/$(context.pipelineRun.namespace)/parasol-claims:candidate
  taskRunTemplate:
    serviceAccountName: pipeline
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 1Gi
  taskRunSpecs:
    - pipelineTaskName: sbom-report
      computeResources:
        requests: {memory: 1Gi}
        limits: {memory: 1536Mi}
    - pipelineTaskName: build-image
      computeResources:
        requests: {memory: 1536Mi}
        limits: {memory: 2Gi}
EOF
)"
run="${run#pipelinerun.tekton.dev/}"
echo "  submitted ${run} — expect 6–12 minutes (longer on a cold node)"

deadline=$(( $(date +%s) + DEADLINE_S ))
status=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  status="$(oc get pipelinerun "${run}" -n "${NS}" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)"
  if [ "${status}" = "True" ] || [ "${status}" = "False" ]; then
    break
  fi
  sleep 20
done

case "${status}" in
  False)
    echo "✅ ${run} failed at the gate, as designed. Shoot it with:"
    echo "   tools/media/.venv/bin/python tools/media/capture.py --jobs tools/media/jobs-trusted-supply-chain.yaml …"
    ;;
  True)
    echo "❌ ${run} SUCCEEDED — the gate did not refuse the seeded image, so there is nothing to photograph." >&2
    echo "   Check the RHACS 'Block Log4Shell at build' policy and that seed-vulnerable still carries log4j-core 2.14.1." >&2
    exit 1
    ;;
  *)
    echo "❌ ${run} did not finish inside ${DEADLINE_S}s (last status: '${status:-none}')." >&2
    echo "   Inspect: tkn pipelinerun describe ${run} -n ${NS}" >&2
    exit 1
    ;;
esac
