#!/usr/bin/env bash
# Drive the jobs-batch-kueue (M06) lab to the admission state ONE screenshot needs.
#
# WHY THIS EXISTS. Both of that module's manifest rows photograph a pattern that exists only WHILE
# work is queued — two Workloads Admitted and three Pending, then one of the admitted two flipped to
# Preempted/Requeued. Three capture passes in a row (2026-07-30 ×2, 2026-07-31) found the namespace
# in its resting state instead: every Job Complete, the CronJob suspended, the single Workload
# Admitted+Finished. Nothing was wrong with those passes — the state simply is not there unless
# somebody creates it, and no staging script existed. This is that script.
#
# Usage:  tools/media/stage-jobs-batch-kueue.sh <user> <phase>
#   queued     ex.5 first half  — entry state + five batch-low Jobs -> 2 Admitted / 3 Pending
#   preempted  ex.5 second half — one batch-high Job -> a low Workload Evicted/Preempted/Requeued
#   clean      delete the queued Jobs again (the lab's own cleanup step)
#
# The Job manifests are copied from content/modules/ROOT/pages/jobs-batch-kueue/lab.adoc exercise 5
# with ONE deliberate difference: `sleep 300` becomes `sleep 900`. The lab's five minutes is enough
# for an attendee reading at pace, but a capture can sit behind a login window, and a low-priority
# Job that COMPLETES mid-pass dissolves the very pattern being photographed (the manifest already
# warns about this for the demo cast). Nothing about the sleep length is visible in the frame.
#
# Every wait below fires on the CONDITION, never on a timer: `Admitted` and `Preempted` are what the
# captions promise, so a shot taken before they are true is a valid PNG of the wrong moment.

set -euo pipefail

USER_SLOT="${1:?usage: stage-jobs-batch-kueue.sh <user> <phase>}"
PHASE="${2:?usage: stage-jobs-batch-kueue.sh <user> <phase>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="${USER_SLOT}-batch"

say() { printf '  [stage:%s] %s\n' "$PHASE" "$*"; }

# How many Workloads carry Admitted=True right now.
admitted_count() {
  oc -n "$NS" get workloads \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Admitted")].status}{"\n"}{end}' \
    2>/dev/null | grep -c '^True$' || true
}

workload_total() {
  oc -n "$NS" get workloads --no-headers 2>/dev/null | wc -l | tr -d ' '
}

submit_job() {   # submit_job <name> <priority-class>
  oc -n "$NS" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $1
  labels:
    kueue.x-k8s.io/queue-name: user-queue
    kueue.x-k8s.io/priority-class: $2
spec:
  parallelism: 1
  completions: 1
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: work
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          resources: {requests: {cpu: 200m, memory: 256Mi}, limits: {cpu: 200m, memory: 256Mi}}
          command: ["/bin/sh","-c","echo $1 running; sleep 900"]
EOF
}

case "$PHASE" in

  queued)
    say "materialising the entry state (this purges ${NS})"
    "${REPO_ROOT}/tools/ws/ws" start jobs-batch-kueue --user "$USER_SLOT"
    oc -n "$NS" get localqueue user-queue

    say "submitting five batch-low Jobs"
    for i in 1 2 3 4 5; do submit_job "batch-low-$i" batch-low; done

    # The ClusterQueue quota is about two sample Pods, so the settled pattern is 2 admitted of 5.
    say "waiting for the 2-admitted / 3-pending pattern"
    for _ in $(seq 1 40); do
      a="$(admitted_count)"; t="$(workload_total)"
      if [ "$t" = "5" ] && [ "$a" = "2" ]; then
        say "reached: ${a} admitted of ${t} Workloads"
        oc -n "$NS" get workloads -o custom-columns='WORKLOAD:.metadata.name,PRIORITY:.spec.priority,ADMITTED:.status.conditions[?(@.type=="Admitted")].status'
        exit 0
      fi
      sleep 5
    done
    say "TIMEOUT: settled on $(admitted_count) admitted of $(workload_total) — do not shoot this"
    oc -n "$NS" get workloads
    exit 1
    ;;

  preempted)
    say "submitting one batch-high Job into the full queue"
    submit_job batch-high-1 batch-high

    say "waiting for a low-priority Workload to report Preempted=True"
    for _ in $(seq 1 40); do
      victim="$(oc -n "$NS" get workloads \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Preempted")].status}{"\n"}{end}' \
        | awk '$2=="True"{print $1}' | head -1)"
      if [ -n "$victim" ]; then
        say "preempted Workload: ${victim}"
        oc -n "$NS" get workload "$victim" \
          -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
        exit 0
      fi
      sleep 5
    done
    say "TIMEOUT: nothing was preempted — do not shoot this"
    oc -n "$NS" get workloads
    exit 1
    ;;

  clean)
    oc -n "$NS" delete jobs -l kueue.x-k8s.io/queue-name=user-queue --ignore-not-found
    ;;

  *)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac
