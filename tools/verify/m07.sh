#!/usr/bin/env bash
# Verify M07 — Pipelines Fundamentals & Task Libraries.
#   Entry: {user}-cicd exists · entry marker CM · claims-db Deployment ready · the
#          parasol-claims-build-test-deploy Pipeline present · Gitea fork answers ·
#          .tekton/pull-request.yaml seeded in the fork · the curated parasol-tasks
#          library is reachable (image-size-report present).
#   End:   parasol-claims Deployment ready (the pipeline built it AND it is wired to
#          claims-db, so it is up — no CrashLoop) · a parasol-claims image was built
#          (ImageStream present).
# End checks are outcome-based (satisfied by an attendee's real pipeline run AND by
# `ws solve`'s launched run) — they assert a running, DB-backed, pipeline-built app.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-cicd"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Gitea host, discovered environment-agnostically (route if readable, else derived from the
# cluster ingress domain — the attendee-safe pattern; attendees can't read the gitea route).
gitea_host() {
  local host domain
  host="$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-gitea.${domain}"
  fi
  echo "$host"
}

# A Gitea repo exists → the (public) repo API answers 2xx anonymously.
gitea_repo_exists() {
  local owner="$1" repo="$2" host
  host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${owner}/${repo}"
}

# A file exists in a (public) Gitea repo → the contents API answers 2xx anonymously.
gitea_file_exists() {
  local owner="$1" repo="$2" path="$3" host
  host="$(gitea_host)"
  [[ -n "$host" ]] || return 1
  curl -ksf -o /dev/null "https://${host}/api/v1/repos/${owner}/${repo}/contents/${path}"
}

# Deployment has at least one ready replica.
deploy_ready() {
  local name="$1" ns="$2" ready
  ready="$(oc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" && "$ready" -ge 1 ]]
}

# --- entry state (what `ws start m07` materializes) --------------------------
check "namespace ${NS} exists"                            oc get ns "$NS"                                    || hint "run: ws start m07 --user ${USER_NAME}"
check "entry marker ws-entry-m07 present"                 oc get cm ws-entry-m07 -n "$NS"                    || hint "entry app not synced — ws start m07 --user ${USER_NAME}"
check "claims-db deployment ready in ${NS}"               deploy_ready claims-db "$NS"                       || hint "the ephemeral DB is entry state — ws reset m07 --user ${USER_NAME}"
check "Pipeline parasol-claims-build-test-deploy present" oc get pipeline parasol-claims-build-test-deploy -n "$NS" || hint "entry app not synced — ws start m07 --user ${USER_NAME}"
check "Gitea fork ${USER_NAME}/parasol-claims answers"    gitea_repo_exists "$USER_NAME" parasol-claims      || hint "fork missing — re-run: ws start m07 --user ${USER_NAME} (fork job)"
check ".tekton/pull-request.yaml seeded in the fork"      gitea_file_exists "$USER_NAME" parasol-claims ".tekton/pull-request.yaml" || hint "re-run the fork/seed job: ws reset m07 --user ${USER_NAME}"
check "curated library task image-size-report reachable"  oc get task image-size-report -n parasol-tasks    || hint "parasol-tasks library missing — sync the workshop-config Argo app"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state (what a completed lab / solve looks like) -------------------
  check "parasol-claims deployment ready in ${NS}"        deploy_ready parasol-claims "$NS"                  || hint "run the pipeline (ws solve m07 --user ${USER_NAME}); it deploys + wires the app to claims-db"
  check "parasol-claims image built (ImageStream present)" oc get imagestream parasol-claims -n "$NS"        || hint "the build-image step pushes here — run the build-test-deploy pipeline"
fi

verify_summary
