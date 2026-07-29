#!/usr/bin/env bash
# Put M12's alert into the FIRING state, the way the lab does — for the capture harness.
#
# WHY THIS IS A SCRIPT AND NOT A `pre_sh:` ONE-LINER
#
# `oc scale deploy/claims-db --replicas=0` alone does NOT fire this alert, and the jobs files
# claimed it did. Read lab.adoc exercise 3: the 5xx signal is banked in a window of roughly
# THIRTY SECONDS. Before that the database is still draining and requests return 200; about a
# minute in, three failed readiness probes pull the pod from the router and every request becomes
# a 503 from the router itself, which never reaches the app and is never recorded as a 5xx. The
# steady load generator's own traffic is 404s. So with no extra load the rule stays Inactive, the
# capture waits 5 minutes, times out, and the window is gone.
#
# The lab tells the attendee to run a concurrent burst for exactly this reason. This reproduces it.
#
# WHY THE BURST RUNS FROM HERE AND NOT FROM AN IN-CLUSTER POD
#
# The HPA burst in exercise 5 uses `oc run`, and that is fine there because nothing is time-boxed.
# Here it would be fatal: pulling ose-cli and scheduling the pod can take minutes, and by the time
# it starts the readiness probe has already pulled parasol-claims from rotation, so the burst
# collects 503s from the router and banks ZERO 5xx. Curling the public Route from the machine
# running the capture starts within a second of the scale-down, which is the only way to be inside
# the window. The rate is irrelevant — clearing 0.1/s over a 5m window needs ~30 server errors and
# even a slow link banks thousands.
#
# The script FAILS if it did not observe server errors. That is the point: a non-zero exit makes
# capture.py skip the job rather than photograph an Inactive rule captioned "Firing".
#
# Usage: tools/media/stage-m12-alert.sh [user]     (default user1)
set -euo pipefail

USER_N="${1:-user1}"
NS="${USER_N}-dev"
WORKERS=20
BURST_S=90

echo "▶ M12 alert staging for ${NS}"

HOST="$(oc get route parasol-claims -n "${NS}" -o jsonpath='{.spec.host}')"
if [[ -z "${HOST}" ]]; then
  echo "❌ no parasol-claims Route in ${NS} — is the entry state up? (ws start observability-health-scale --user ${USER_N})" >&2
  exit 1
fi
CLAIMS="https://${HOST}"

# The rule itself must be loaded, or there is nothing to fire.
oc get prometheusrule parasol-claims-alerts -n "${NS}" >/dev/null

# Baseline sanity: the app must be serving before we break it, otherwise the "5xx" we measure are
# just a pre-existing outage and the shot would tell a different story than the lab does.
code="$(curl -ks -o /dev/null -w '%{http_code}' "${CLAIMS}/api/claims")"
if [[ "${code}" != "200" ]]; then
  echo "❌ ${CLAIMS}/api/claims answered ${code}, not 200 — the app is not healthy, so this is not the lab's fault to inject" >&2
  exit 1
fi
echo "  baseline GET /api/claims -> 200"

echo "  scaling claims-db to 0 and starting ${WORKERS} workers for ${BURST_S}s"
oc scale deploy/claims-db -n "${NS}" --replicas=0

count_dir="$(mktemp -d)"
trap 'rm -rf "${count_dir}"' EXIT
end=$(( $(date +%s) + BURST_S ))
for w in $(seq 1 "${WORKERS}"); do
  (
    n5xx=0
    while [ "$(date +%s)" -lt "${end}" ]; do
      c="$(curl -ks -o /dev/null -w '%{http_code}' "${CLAIMS}/api/claims" || echo 000)"
      case "${c}" in 5*) n5xx=$(( n5xx + 1 ));; esac
    done
    echo "${n5xx}" > "${count_dir}/w${w}"
  ) &
done
wait

total=0
for f in "${count_dir}"/w*; do
  total=$(( total + $(cat "${f}") ))
done

echo "  banked ${total} server errors in the post-drain window"
if [[ "${total}" -lt 30 ]]; then
  echo "❌ only ${total} 5xx — rate(...[5m]) will not clear 0.1/s, so the alert will never fire." >&2
  echo "   Restore before retrying: oc scale deploy/claims-db -n ${NS} --replicas=1" >&2
  exit 1
fi

echo "✅ fault injected. The rule goes Pending within ~1 min and Firing ~2 min after that;"
echo "   it resolves once the burst falls out of the 5m rate window (~6 min from the scale-down)."
echo "   Shoot inside that window — the job's pre_wait_s is sized for it."
