#!/usr/bin/env bash
# Drive the config-multienv (M04) lab to the exact state ONE screenshot needs, and no further.
#
# WHY A PHASED SCRIPT. All five of that module's manifest rows photograph the SAME namespace at five
# DIFFERENT moments of the same lab: a crash-looping pod, then a healthy one wired to a ConfigMap and
# a Secret, then a Route held at 503, then a quota-refused Deployment, then three environments. They
# are not five independent states — each is reached by continuing the lab from the previous one, so a
# jobs file cannot stage them with one command and cannot stage them in any other order. Every phase
# below therefore assumes its predecessor has run in the same window, which is exactly how
# `jobs-first-block.yaml` sequences them.
#
# The command bodies are copied from content/modules/ROOT/pages/config-multienv/lab.adoc verbatim
# (exercises 1-6) rather than re-derived, so the picture matches what the page tells the attendee to
# type. Anything that differs from the page is a bug in this file.
#
# Usage:  tools/media/stage-config-multienv.sh <user> <phase>
#   break             ex.1  — entry state, readiness probe, bad datasource URL -> CrashLoopBackOff
#   configured        ex.2-3 — bad env removed, claims-config ConfigMap + claims-creds Secret wired
#   readiness-broken  ex.4  — readiness pointed at a typo path -> no endpoints, Route 503
#   quota             ex.5  — readiness restored, requests/limits set, claims-hog refused by quota
#   promote           ex.6  — same image promoted into <user>-stage and <user>-prod
#
# Each phase is idempotent enough to re-run, but the sequence is not resumable from the middle: start
# at `break`, which re-materialises the entry state and purges the namespace.
#
# `break` uses `ws reset`, not `ws start`, and it has to — see the long comment on that phase. The
# underlying platform defect is worth reporting on its own: `ws start config-multienv` cannot
# re-materialise a namespace in which this module's exercise 2 has already run, because the entry
# state's plain-`value` env entries collide by name with the lab's `valueFrom` ones and the patch is
# rejected. That is the same `ws start` an attendee re-prepping the module would run.

set -euo pipefail

USER_SLOT="${1:?usage: stage-config-multienv.sh <user> <phase>}"
PHASE="${2:?usage: stage-config-multienv.sh <user> <phase>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV="${USER_SLOT}-dev"

say() { printf '  [stage:%s] %s\n' "$PHASE" "$*"; }

route_code() {
  local host
  host="$(oc -n "$DEV" get route parasol-claims -o jsonpath='{.spec.host}')"
  curl -s -o /dev/null -w '%{http_code}' "http://${host}/api/claims"
}

case "$PHASE" in

  break)
    # `ws reset`, NOT `ws start` — and the difference is not cosmetic. Measured 2026-08-01 on the
    # build cluster: `ws start config-multienv` does not purge its OWN namespace (it only
    # gc_conflicts OTHER modules), so it re-syncs onto whatever the last run left behind. Once the
    # lab's exercise 2 has run, the live Deployment carries POSTGRESQL_HOST/PORT/DATABASE/USER/
    # PASSWORD as `valueFrom` (configMapKeyRef/secretKeyRef) while the entry state declares the same
    # five NAMES with a plain `value`. A strategic-merge patch merges env by name, so the result has
    # both set and the API rejects the whole Deployment:
    #   Deployment.apps "parasol-claims" is invalid: spec.template.spec.containers[0].env[0]
    #   .valueFrom: Invalid value: "": may not be specified when `value` is not empty
    # The Argo Application then parks at operationState.phase=Failed and NO amount of waiting clears
    # it — `ws start` reported exactly that and the whole five-shot sequence died at job 1.
    # `ws reset` purges the namespace and deletes the Application before re-materialising, which is
    # what this comment always claimed was happening. See the note in this file's header.
    say "materialising the entry state (purge + delete + re-materialize on ${DEV})"
    "${REPO_ROOT}/tools/ws/ws" reset config-multienv --user "$USER_SLOT"
    oc -n "$DEV" rollout status deploy/parasol-claims --timeout=300s

    # lab.adoc ex.1: the readiness probe is what makes the next failure VISIBLE. Without it the
    # broken pod reports 1/1 for the better part of a minute and the screenshot lies.
    say "adding the readiness probe"
    oc -n "$DEV" set probe deploy/parasol-claims --readiness \
      --get-url=http://:8080/q/health/ready --period-seconds=10 --failure-threshold=3
    oc -n "$DEV" rollout status deploy/parasol-claims --timeout=300s

    say "breaking the datasource URL"
    oc -n "$DEV" set env deploy/parasol-claims \
      QUARKUS_DATASOURCE_JDBC_URL=jdbc:postgresql://wrong-db-host:5432/parasol

    # Wait for the pod to be genuinely CrashLoopBackOff, not merely pending. A shot taken while it is
    # still `ContainerCreating` is a valid PNG of nothing: the badge the caption promises is absent.
    say "waiting for CrashLoopBackOff (the badge the shot is FOR)"
    for _ in $(seq 1 60); do
      if oc -n "$DEV" get pods -l app=parasol-claims \
           -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
         | grep -q CrashLoopBackOff; then
        say "CrashLoopBackOff reached"
        oc -n "$DEV" get pods -l app=parasol-claims
        exit 0
      fi
      sleep 5
    done
    say "TIMEOUT: no CrashLoopBackOff after 5 min — do not shoot this state"
    oc -n "$DEV" get pods -l app=parasol-claims
    exit 1
    ;;

  configured)
    say "removing the bad datasource URL"
    oc -n "$DEV" set env deploy/parasol-claims QUARKUS_DATASOURCE_JDBC_URL-
    oc -n "$DEV" rollout status deploy/parasol-claims --timeout=300s

    say "creating claims-config and claims-creds"
    oc -n "$DEV" create configmap claims-config \
      --from-literal=APP_ENV=dev \
      --from-literal=POSTGRESQL_HOST=claims-db \
      --from-literal=POSTGRESQL_PORT=5432 \
      --from-literal=POSTGRESQL_DATABASE=parasol \
      --from-literal=QUARKUS_LOG_LEVEL=INFO \
      --dry-run=client -o yaml | oc -n "$DEV" apply -f -
    # NOTE: these are the lab's fabricated teaching credentials (user/password both `parasol`), not
    # a real secret — see the media-capture conventions rule 1. The Secret is still photographed
    # with "Reveal values" OFF; nothing decodes it in frame.
    oc -n "$DEV" create secret generic claims-creds \
      --from-literal=POSTGRESQL_USER=parasol \
      --from-literal=POSTGRESQL_PASSWORD=parasol \
      --dry-run=client -o yaml | oc -n "$DEV" apply -f -

    oc -n "$DEV" set env deploy/parasol-claims --from=configmap/claims-config
    oc -n "$DEV" set env deploy/parasol-claims --from=secret/claims-creds
    oc -n "$DEV" rollout status deploy/parasol-claims --timeout=300s
    say "Route now answers $(route_code)"
    ;;

  readiness-broken)
    say "adding startup and liveness probes (lab ex.4)"
    oc -n "$DEV" set probe deploy/parasol-claims --startup \
      --get-url=http://:8080/q/health/started --period-seconds=3 --failure-threshold=30
    oc -n "$DEV" set probe deploy/parasol-claims --liveness \
      --get-url=http://:8080/q/health/live --period-seconds=10 --failure-threshold=3
    oc -n "$DEV" rollout status deploy/parasol-claims --timeout=300s

    say "pointing readiness at a path that does not exist"
    oc -n "$DEV" set probe deploy/parasol-claims --readiness --get-url=http://:8080/q/health/typo
    # scale 0 -> 1 so the ONLY pod carries the broken check; otherwise the old ready pod keeps the
    # Service populated and the Route answers 200, which is the opposite of the shot.
    oc -n "$DEV" scale deploy/parasol-claims --replicas=0
    oc -n "$DEV" scale deploy/parasol-claims --replicas=1
    sleep 45
    oc -n "$DEV" get endpoints parasol-claims
    code="$(route_code)"
    say "Route answers ${code} (503 is the state this shot is for)"
    [ "$code" = "503" ] || { say "NOT 503 — do not shoot"; exit 1; }
    ;;

  quota)
    say "restoring readiness"
    oc -n "$DEV" set probe deploy/parasol-claims --readiness --get-url=http://:8080/q/health/ready
    oc -n "$DEV" rollout status deploy/parasol-claims --timeout=300s
    oc -n "$DEV" set resources deploy/parasol-claims \
      --requests=cpu=100m,memory=256Mi --limits=cpu=500m,memory=512Mi
    oc -n "$DEV" rollout status deploy/parasol-claims --timeout=300s

    say "creating the greedy Deployment the quota must refuse"
    cat <<'EOF' | oc -n "$DEV" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: claims-hog
  labels: { app: claims-hog }
spec:
  replicas: 1
  selector: { matchLabels: { app: claims-hog } }
  template:
    metadata: { labels: { app: claims-hog } }
    spec:
      containers:
        - name: hog
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["sleep", "infinity"]
          resources:
            requests: { cpu: "4", memory: 256Mi }
            limits:   { cpu: "4", memory: 256Mi }
EOF
    say "waiting for the ReplicaFailure condition (the shot's subject)"
    for _ in $(seq 1 24); do
      if oc -n "$DEV" get deploy claims-hog \
           -o jsonpath='{range .status.conditions[?(@.type=="ReplicaFailure")]}{.message}{end}' \
         | grep -q 'exceeded quota'; then
        oc -n "$DEV" get deploy claims-hog \
          -o jsonpath='{range .status.conditions[?(@.type=="ReplicaFailure")]}{.reason}: {.message}{"\n"}{end}'
        exit 0
      fi
      sleep 5
    done
    say "TIMEOUT: no ReplicaFailure — the quota may differ on this cluster; do not shoot"
    exit 1
    ;;

  promote)
    tmp="$(mktemp -d)"
    gitea="$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}')"
    say "cloning the claims-config fork from ${gitea}"
    git -c http.sslVerify=false clone "https://${gitea}/${USER_SLOT}/claims-config" "${tmp}/claims-config"
    ( cd "${tmp}/claims-config" && oc apply -k overlays/stage && oc apply -k overlays/prod )
    oc -n "${USER_SLOT}-stage" rollout status deploy/parasol-claims --timeout=300s
    oc -n "${USER_SLOT}-prod"  rollout status deploy/parasol-claims --timeout=300s
    for ns in "$DEV" "${USER_SLOT}-stage" "${USER_SLOT}-prod"; do
      printf '  %-16s replicas=%s\n' "$ns" \
        "$(oc -n "$ns" get deploy parasol-claims -o jsonpath='{.status.readyReplicas}')"
    done
    rm -rf "$tmp"
    ;;

  *)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac
