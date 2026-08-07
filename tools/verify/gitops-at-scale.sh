#!/usr/bin/env bash
# Verify gitops-at-scale — GitOps at Scale & Progressive Delivery.
#   Entry: {user}-gitops workspace ns + entry marker · the student-gitops Argo CD instance is
#          reachable · the attendee's proj-{user} AppProject exists · a per-user Gitea fork of
#          claims-config that ALSO carries the gitops-at-scale source (rollouts/ overlay personalized to
#          {user}-prod + applicationset.yaml) · the per-user analysis prereqs in {user}-prod
#          (claims-analysis SA + gitops-at-scale-canary-control knob) · AND the gitops-fundamentals END STATE materialized:
#          claims runs GitOps-managed in {user}-dev + {user}-stage (gitops-at-scale starts where gitops-fundamentals ended, so
#          gitops-at-scale is independent). Entry leaves {user}-prod WITHOUT the Rollout (converting prod to a
#          Rollout is the lab).
#   End:   the ApplicationSet the attendee creates in exercise 1 templates into proj-{user} (the
#          module's headline beat — see appset_for_user below) AND {user}-prod runs claims as an
#          Argo Rollout (canary), Healthy, DELIVERED FROM GIT BY ARGO (tracking annotation), route
#          answers 200 (also proves the cluster RolloutManager is serving — a Rollout only goes
#          Healthy if the controller processes it).
# End checks grade the DECLARATION the attendee wrote (the ApplicationSet, and the fact that prod's
# Rollout arrived through Argo) and corroborate it with the OBSERVED outcome (Healthy + 200) —
# never the other way round. They pass for BOTH the attendee's own lab result AND `ws solve`'s prod
# Application, which reproduces the same world WITHOUT an ApplicationSet and is detected as such
# rather than silently accepted (solve_built_this_world).
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
GITOPS="${USER_NAME}-gitops"
DEV="${USER_NAME}-dev"
STAGE="${USER_NAME}-stage"
PROD="${USER_NAME}-prod"

# --- helpers (kept dependency-free: oc + curl only) --------------------------

# Every oc read below goes through _lib.sh's oc_read/oc_present/oc_absent rather than `2>/dev/null`,
# which cannot tell "the object is not there" (a gradeable ❌) from "the cluster did not answer" (a ⚠
# that is never the attendee's fault). Predicates return 1 for both, and oc_read raises
# VERIFY_INCONCLUSIVE so check() picks the right one.

# Cluster ingress domain — attendee-readable; used to derive route hosts without a cross-namespace
# route read (attendees cannot read routes in gitea/student-gitops).
#
# GLOBAL, not echo-shaped, and that is the whole point. The old twin of this was
# `d="$(ingress_domain)"`, which runs the oc read inside a SUBSHELL: the VERIFY_INCONCLUSIVE oc_read
# raises in there dies with the subshell, so every caller downstream graded an unreachable cluster as
# a red ❌ on the attendee's work. Signal raised and dropped — the same trap SC2034 names, one costume
# over. Setting INGRESS_DOMAIN in the CALLER's shell is what keeps the flag where check() can see it.
# (It also removes the `set -e` hazard the echo shape was working around: nothing here is assigned
# from a command substitution any more.)
INGRESS_DOMAIN=""
read_ingress_domain() {  # → 0 + INGRESS_DOMAIN set; 1 with the flag raised when the API could not be asked
  oc_read get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' || return 1
  INGRESS_DOMAIN="$OC_OUT"
  [[ -n "$INGRESS_DOMAIN" ]]
}

# Gitea host: route if readable, else derived from the ingress domain (route "gitea" in ns "ogsr-gitea").
# Global for the same reason as above.
GITEA_HOST=""
read_gitea_host() {  # → 0 + GITEA_HOST set; 1 when the host could not be determined
  GITEA_HOST=""
  # oc_read_OPTIONAL, not oc_read: this route read is a best-effort SHORTCUT, and an attendee is
  # EXPECTED to be refused it (rule 10 — routes in ogsr-gitea are not theirs to read). Its refusal
  # must not become this check's verdict, because the ingress-domain fallback below answers the same
  # question perfectly well. See _lib.sh, oc_read_optional — a module clearing the shared flag itself
  # would be inventing a flag-lifecycle rule in the wrong file.
  if oc_read_optional get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' && [[ -n "$OC_OUT" ]]; then
    GITEA_HOST="$OC_OUT"
    return 0
  fi
  read_ingress_domain || return 1
  GITEA_HOST="gitea-ogsr-gitea.${INGRESS_DOMAIN}"
}

# Every HTTP probe below goes through _lib.sh's http_read, which gives curl the same three outcomes
# oc_read gives `oc`: a status code is a graded answer, a transport failure asks the cluster API
# whether it is only this app that is down (❌) or the whole cluster (⚠, never the attendee's fault).

# The per-user promotion fork exists → the Gitea API answers 2xx for {user}/claims-config.
fork_exists() {
  read_gitea_host || return 1
  http_read "https://${GITEA_HOST}/api/v1/repos/${USER_NAME}/claims-config" --max-time 15 || return 1
  # < 400 mirrors the `curl -f` this check used before, to the status code. A 404 — no fork — is the
  # graded ❌ this check exists to produce, and it stays one: a 404 IS the server answering.
  [[ "$HTTP_CODE" -lt 400 ]]
}

# The fork carries a raw file whose contents match a pattern (proves the gitops-at-scale source + personalization).
fork_file_matches() {
  local path="$1" pattern="$2"
  read_gitea_host || return 1
  http_read "https://${GITEA_HOST}/api/v1/repos/${USER_NAME}/claims-config/raw/${path}?ref=main" --max-time 15 || return 1
  [[ "$HTTP_CODE" -lt 400 ]] || return 1
  grep -q "$pattern" <<<"$HTTP_OUT"
}

# The student-gitops Argo CD instance is reachable on its route (derived host; /healthz → 200).
student_argo_up() {
  read_ingress_domain || return 1
  http_read "https://student-gitops-server-student-gitops.${INGRESS_DOMAIN}/healthz" --max-time 15 || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# --- the attendee's Argo CD ACCESS PLANE, not just the objects ---------------
# `/healthz` answers 200 anonymously and the AppProject exists as an object — neither says the
# ATTENDEE can log in and see anything. The real gates are argocd-cm's `accounts.{user}` (the local
# account) and argocd-rbac-cm's policy.csv lines binding it to proj-{user}. Drop either and the
# attendee lands on an EMPTY Argo CD while every object-exists check stays green. Both ConfigMaps are
# cross-namespace for an attendee (measured 2026-07-29), so unreadable => INCONCLUSIVE (⚠), never ❌
# (rule 10 — verify scripts run as the attendee; docs/module-template/README.md).
ARGO_NS="ogsr-student-gitops"

# ASK THE OBJECT, NOT A BARE EXISTENCE PROBE. The guard here used to be
# `oc get cm argocd-rbac-cm >/dev/null 2>&1`, whose failure cannot distinguish "the attendee may not
# read it" (a legitimate ⚠ skip) from "it was DELETED" — and deletion is exactly the failure the two
# checks below exist to catch. Both landed in the ⚠ branch, so a wiped access plane reported as an
# inconclusive skip on a workshop where beat 1's `argocd login` would have been rejected outright.
# Classify the server's answer instead (same pattern as jobs-batch-kueue's ClusterQueue guard):
# Forbidden => not this identity's check; anything else, NotFound included, means the caller CAN ask,
# so a missing ConfigMap falls through and fails loudly where it should.
argo_access_plane_err() { { oc get cm argocd-rbac-cm -n "$ARGO_NS" -o name >/dev/null; } 2>&1 || true; }

argo_account_exists() {
  oc_read get cm argocd-cm -n "$ARGO_NS" -o jsonpath="{.data.accounts\\.${USER_NAME}}" || return 1
  [[ -n "$OC_OUT" ]]
}

argo_rbac_binds_user() {
  oc_read get cm argocd-rbac-cm -n "$ARGO_NS" -o jsonpath='{.data.policy\.csv}' || return 1
  grep -q "proj-${USER_NAME}" <<<"$OC_OUT"
}

# The student server serves its own argocd CLI (gitops-at-scale beat 1 downloads it — Argo 3.4 has no appset UI,
# so the attendee creates the ApplicationSet via the CLI). A byte-range probe, not a ~300MB pull.
cli_download_ready() {  # NOTE: this asks whether beat 1 CAN be done; appset_for_user asks whether it WAS
  read_ingress_domain || return 1
  # -r 0-1 is what keeps this a byte-range probe rather than a ~300MB pull — and, with http_read
  # slurping the body into HTTP_OUT, what keeps that variable two bytes wide.
  http_read "https://student-gitops-server-student-gitops.${INGRESS_DOMAIN}/download/argocd-linux-amd64" \
    --max-time 15 -r 0-1 || return 1
  [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "206" ]]
}

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It classifies the API's
# answer, so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌ on your work.

# deploy_ready_min (<deployment> <namespace> <n>) is shared — tools/verify/_lib.sh (>=, never ==).

# --- beat 1: the ApplicationSet — the artefact this module exists to produce -------------------
#
# F-07 (false-pass audit, 2026-08-05). The end state used to grade ONLY "prod runs a Healthy Rollout
# and the route answers 200". Both are OUTCOMES, and `oc apply -k rollouts/` from the clone the lab
# already has the attendee make produces both without an ApplicationSet, without the argocd CLI
# login, without Argo touching prod at all — i.e. the whole "at scale" half of "GitOps at Scale"
# could be skipped under a green banner. Worse, the entry block goes to the trouble of proving the
# ApplicationSet SOURCE is in the fork (line ~"fork carries applicationset.yaml") and that the CLI
# that creates it is downloadable — verifying that beat 1 CAN be done and never that it WAS.
#
# The rule: grade the DECLARATION the attendee wrote, corroborate with the OBSERVATION. The two
# checks below are the declaration; rollout_healthy/route_ready_200 stay as the corroboration.
#
# MATCHED BY PROJECT, NOT BY NAME — deliberately, and not a shortcut. `ws` itself selects an
# attendee's ApplicationSets with exactly `.spec.template.spec.project == proj-{user}` (tools/ws/ws,
# the privileged purge path), which is also the boundary Argo RBAC enforces on the create
# (`applicationsets, create, proj-{user}/*` — student-argocd.yaml). The fork ships the object named
# claims-{user}, but the lab's own Challenge tells the attendee to EDIT that file and nothing stops
# them renaming it. Pinning the name would trade this false ✅ for a false ❌ on a correct attendee,
# which is not a win. A filter expression (not a plain field path) is what keeps an ApplicationSet
# belonging to someone else — or one missing the field — from erroring the read into a false ❌.
read_user_appsets() {  # → 0 + OC_OUT = one name per line (possibly empty); 1 when the ns could not be read
  oc_read get applicationsets.argoproj.io -n "$ARGO_NS" \
    -o jsonpath="{range .items[?(@.spec.template.spec.project==\"proj-${USER_NAME}\")]}{.metadata.name}{\"\n\"}{end}"
}

# ONE READ, TWO WRAPPERS — and that is the point. The exemplar lane that fixed
# deployment-targets-scheduling found a second, worse bug beside the first: its end predicate
# accepted "anti-affinity OR topologySpreadConstraints" while its entry predicate negated
# anti-affinity only, so a TSC-only world was BOTH "complete" in full mode and "a clean slate" in
# entry mode — and `ws prep` reads the entry rc as "is this world already prepared?", so it could
# skip setup or offer to WIPE a finished lab. Two hand-written mirrors drift. These cannot: they are
# `-n` and `-z` over the same bytes.
appset_for_user()    { read_user_appsets || return 1; [[ -n "$OC_OUT" ]]; }
no_appset_for_user() { read_user_appsets || return 1; [[ -z "$OC_OUT" ]]; }

# ASK THE OBJECT, NOT A BARE EXISTENCE PROBE — same classifier as argo_access_plane_err above, and
# for the same reason. An attendee's only k8s read in ogsr-student-gitops is `get appproject
# proj-{user}` BY NAME (student-appprojects.yaml grants exactly that and nothing else), so listing
# ApplicationSets there is Forbidden for them and must be ⚠ "not yours to answer", never ❌ on work
# they may well have done. Anything that is NOT a refusal means the caller CAN ask — so a genuinely
# missing ApplicationSet falls through and fails loudly, which is the whole point of this check.
appset_read_err() { { oc get applicationsets.argoproj.io -n "$ARGO_NS" -o name >/dev/null; } 2>&1 || true; }

# Did `ws solve` build this world? solve-endstate.yaml stamps this ConfigMap in the attendee's OWN
# {user}-gitops namespace (readable by them) and then creates a SINGLE prod Application —
# claims-prod-{user} — NOT an ApplicationSet. So on a solved world beat 1's artefact is correctly
# absent, and asserting it would be a false ❌ on a world that is exactly what solve promises.
# na(), not warn(): nothing is unknown here and no re-run anywhere answers it differently.
# Read from the CLUSTER as well as from --solve: `ws solve` then a plain `ws verify` is the ordinary
# instructor sequence, and the flag is absent on that second command.
#
# The OWNER LABEL, not just the name. This predicate is the one place where a ✅ is granted without
# beat 1's artefact, so it must key off something the CHART stamps rather than off a name an
# attendee could type: {user}-gitops is the attendee's own namespace and they can create ConfigMaps
# in it. `workshop.redhat.com/owner: ogsr` is set by solve-endstate.yaml on this object. It is not a
# security boundary — someone determined can forge a label too — but it means the exemption cannot
# be tripped by accident or by a same-named leftover, and the ➖ line says out loud which world it
# thinks it is looking at.
solve_built_this_world() {
  oc_read get cm "gitops-at-scale-solve-apps-${USER_NAME}" -n "$GITOPS" \
    -o jsonpath='{.metadata.labels.workshop\.redhat\.com/owner}' || return 1
  [[ "$OC_OUT" == "ogsr" ]]
}

# The object carries Argo CD's tracking annotation → the student instance delivered it FROM GIT.
# Generic over kinds because prod's workload is a Rollout, not a Deployment, and it is the half of
# F-07 that survives the ⚠ above: an attendee CAN read this one (it lives in their own namespace),
# so it grades on an attendee's own run and it is what separates "Argo put this here" from
# `oc apply -k rollouts/`.
#
# NOT a guess about how this Argo CD tracks resources: the student instance sets
# `resourceTrackingMethod: annotation` explicitly (gitops/workshop-config/templates/student-argocd.yaml),
# and the dev-side check further down already grades that same annotation in BOTH modes — so an
# instance that had label tracking instead would be printing a red line there long before it printed
# one here. No new class of false ❌ is created by asking prod the question dev is already asked.
argo_tracked() {  # <kind> <name> <namespace>
  oc_read get "$1" "$2" -n "$3" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' || return 1
  [[ -n "$OC_OUT" ]]
}

# The Deployment carries the Argo CD tracking annotation → it is GitOps-managed by the student instance.
deploy_gitops_managed() { argo_tracked deploy "$1" "$2"; }

# Same question, asked of the prod Rollout.
rollout_gitops_managed() { argo_tracked rollout "$1" "$2"; }

# A named Rollout is present AND Healthy (also proves the cluster RolloutManager is serving it).
rollout_healthy() {
  local name="$1" ns="$2"
  oc_read get rollout "$name" -n "$ns" -o jsonpath='{.status.phase}' || return 1
  [[ "$OC_OUT" == "Healthy" ]]
}

# A named Rollout is ABSENT (entry-only: prod starts without the Rollout — converting it is the lab).
# Namespace must exist first — otherwise "absent" is vacuous, not evidence of a clean entry state.
# oc_absent, never `! oc get … 2>/dev/null`: a negation built on a silenced read certifies a clean slate
# from an API that never answered, and a wrongly-green ENTRY check sends `ws prep` down its
# "already prepared" fast path (_lib.sh, oc_absent's own header).
rollout_absent() {
  oc_present get ns "$2" -o name || return 1
  oc_absent get rollout "$1" -n "$2" -o name
}

# --- what a red Rollout check tells the attendee to RUN -----------------------
#
# THERE IS NO ARGO ROLLOUTS CLI PLUGIN IN THE COCKPIT TERMINAL, and two hints below used to send
# the attendee to `oc argo rollouts get rollout …` anyway. Measured 2026-08-07 in the real ttyd
# terminal as user7: `kubectl argo rollouts` answers `error: unknown command "argo"`, `command -v
# kubectl-argo-rollouts` finds nothing, and `oc plugin list` reports no kubectl plugins on PATH at
# all. That last one is what makes this a property of the TERMINAL rather than of one binary — oc
# and kubectl resolve `<cmd> <word>` through the same kubectl-<word> plugin lookup, so neither form
# can work with no plugin installed. What the `oc` spelling prints was never captured (only the
# kubectl form was), so nothing here quotes an error text for it; the module's troubleshooting page
# does assert one, which is unmeasured and flagged upstream rather than copied.
#
# A hint naming a command the attendee cannot run is worse than no hint: it turns one red check
# into a second dead end, on the exact step where they are already stuck. Both hints therefore ask
# the OBJECT, which is the same information the plugin would have formatted — and it is quoted into
# a variable here rather than retyped per site precisely because it was wrong in two places at once.
ROLLOUT_INSPECT="oc get rollout parasol-claims -n ${PROD} -o jsonpath='phase={.status.phase} step={.status.currentStepIndex} paused={.status.pauseConditions[*].reason} active={.status.blueGreen.activeSelector}{\"\n\"}'"
# Clearing a blue-green pause is a STATUS-SUBRESOURCE patch, and BOTH of its lookalikes report
# success while promoting nothing (measured 2026-08-07, both ways round; lab.adoc and
# troubleshooting.adoc document the same trap in the same words, and this hint must keep agreeing
# with them). The trap is in the hint rather than left to the page because an attendee who reaches
# for the obvious `spec.paused` is told `patched` and gets no promotion, with nothing to say why.
ROLLOUT_PROMOTE_HINT="clear the condition ON THE STATUS SUBRESOURCE — oc patch rollout <name> -n ${PROD} --subresource status --type merge -p '{\"status\":{\"pauseConditions\":null}}'. Both lookalikes lie: the SAME patch without --subresource status prints 'patched (no change)', and -p '{\"spec\":{\"paused\":false}}' prints 'patched'. Neither promotes anything"

# The claims Route answers HTTP 200 on the readiness endpoint (also proves DB connectivity).
route_ready_200() {
  local ns="$1" host
  oc_read get route parasol-claims -n "$ns" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  http_read "http://${host}/q/health/ready" --max-time 15 || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# --- entry state (what `ws start gitops-at-scale` materializes) --------------------------
check "namespace ${GITOPS} exists"                       oc get ns "$GITOPS"                                 || hint "workshop layer not applied — run bootstrap/install.sh"
check "entry marker ws-entry-gitops-at-scale in ${GITOPS}"           oc get cm ws-entry-gitops-at-scale -n "$GITOPS"                 || hint "entry app not synced — ws start gitops-at-scale --user ${USER_NAME}"
check "student-gitops Argo CD instance reachable"        student_argo_up                                     || hint "student instance missing — sync workshop-config (student-argocd.yaml)"
check "argocd CLI served for the appset-create beat"     cli_download_ready                                   || hint "server not serving /download/argocd-linux-amd64 — check the student-gitops server route"
check "AppProject proj-${USER_NAME} exists"              oc get appproject "proj-${USER_NAME}" -n ogsr-student-gitops || hint "per-user AppProject missing — sync workshop-config (student-appprojects.yaml)"
# The object above is not the outcome — the attendee logging in AND being able to create the
# ApplicationSet into proj-{user} is (this module's whole beat 1).
case "$(argo_access_plane_err)" in
  *orbidden*)
    warn "Argo CD access plane (account + RBAC policy) not readable as this identity"
    hint "argocd-cm/argocd-rbac-cm live in ogsr-student-gitops, which attendees cannot read — run this check as the instructor/CI identity, or confirm by running the beat-1 argocd login as ${USER_NAME}"
    ;;
  *)
    check "Argo CD account accounts.${USER_NAME} exists (attendee can log in)"  argo_account_exists  || hint "no local Argo account for ${USER_NAME} — the argocd CLI login in beat 1 is rejected; sync workshop-config (student-argocd.yaml, .spec.extraConfig accounts.${USER_NAME}: login)"
    check "Argo CD RBAC binds ${USER_NAME} to proj-${USER_NAME}"                argo_rbac_binds_user || hint "argocd-rbac-cm policy.csv has no proj-${USER_NAME} lines (or the ConfigMap is gone) — the ApplicationSet create is denied and the UI is empty; sync workshop-config (student-argocd.yaml rbac.policy)"
    ;;
esac
check "Gitea fork ${USER_NAME}/claims-config exists"     fork_exists                                         || hint "fork job didn't run — ws reset gitops-at-scale --user ${USER_NAME} (or check gitea-fork-gitops-at-scale-${USER_NAME} Job in ns gitea)"
check "fork carries rollouts/ overlay (prod-personalized)" fork_file_matches "rollouts/kustomization.yaml" "namespace: ${PROD}" || hint "fork missing gitops-at-scale source — ws reset gitops-at-scale --user ${USER_NAME}"
check "fork carries applicationset.yaml (personalized)"  fork_file_matches "applicationset.yaml" "proj-${USER_NAME}"            || hint "fork missing the ApplicationSet source — ws reset gitops-at-scale --user ${USER_NAME}"
check "analysis SA claims-analysis in ${PROD}"           oc get sa claims-analysis -n "$PROD"                || hint "analysis prereq missing — ws reset gitops-at-scale --user ${USER_NAME}"
check "canary knob gitops-at-scale-canary-control in ${PROD}"        oc get cm gitops-at-scale-canary-control -n "$PROD"             || hint "analysis knob missing — ws reset gitops-at-scale --user ${USER_NAME}"
# gitops-at-scale entry = the gitops-fundamentals END STATE: claims GitOps-managed in dev + stage (gitops-at-scale starts where gitops-fundamentals ended).
check "claims-db ready in ${DEV}"                        deploy_ready claims-db "$DEV"                       || hint "gitops-fundamentals end state not materialized — ws reset gitops-at-scale --user ${USER_NAME}"
check "parasol-claims ready in ${DEV}"                   deploy_ready parasol-claims "$DEV"                  || hint "gitops-fundamentals end state not materialized — ws reset gitops-at-scale --user ${USER_NAME}"
check "dev claims is GitOps-managed (Argo tracking)"     deploy_gitops_managed parasol-claims "$DEV"         || hint "dev claims should be deployed by the student instance — ws reset gitops-at-scale --user ${USER_NAME}"
check "parasol-claims ready in ${STAGE} (>=2 replicas)"  deploy_ready_min parasol-claims "$STAGE" 2          || hint "gitops-fundamentals end state not materialized in stage — ws reset gitops-at-scale --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove {user}-prod does NOT yet run the Rollout (converting prod is the lab).
  check "no parasol-claims Rollout in ${PROD} yet (clean)" rollout_absent parasol-claims "$PROD"             || hint "prod already has the Rollout — ws reset gitops-at-scale --user ${USER_NAME} for a clean entry"
  # …and that beat 1's artefact is not there either — the EXACT negation of the end-state check
  # below, by construction (both wrap read_user_appsets). Not cosmetic symmetry: a leftover
  # ApplicationSet REGENERATES the Applications a purge deletes (tools/ws/ws deletes appsets FIRST
  # for exactly this reason), so a world holding one is not a clean slate however empty prod looks —
  # and `ws prep` reads this rc as "already prepared?" and would take its no-purge fast path on it.
  case "$(appset_read_err)" in
    *orbidden*)
      warn "attendee ApplicationSets in ${ARGO_NS} not listable as this identity"
      hint "not yours to fix: an attendee's only k8s read there is their own AppProject by name. Confirm it yourself with the Argo CLI — \`~/argocd appset list -p proj-${USER_NAME}\` should be empty at entry — or re-run this script as the instructor/CI identity"
      ;;
    *)
      check "no ApplicationSet for proj-${USER_NAME} yet (clean)"  no_appset_for_user  || hint "a previous run's ApplicationSet is still in ${ARGO_NS} and will regenerate anything a purge deletes — ws prep gitops-at-scale --user ${USER_NAME} --yes (or \`~/argocd appset delete claims-${USER_NAME}\` as ${USER_NAME})"
      ;;
  esac
else
  # --- end state (what a completed lab / solve looks like) -------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  # BEAT 1 FIRST — the declaration, before the outcomes it is supposed to have caused.
  if [[ "$SOLVE_MODE" == "true" ]] || solve_built_this_world; then
    na "ApplicationSet for proj-${USER_NAME} (exercise 1) — this world was built by \`ws solve\`, which reproduces the same END state from a single prod Application (claims-prod-${USER_NAME}) instead of the attendee's ApplicationSet, so beat 1's artefact is correctly absent here; the checks below still grade the outcome it would have produced"
  else
    case "$(appset_read_err)" in
      *orbidden*)
        warn "could not check: an ApplicationSet for proj-${USER_NAME} exists (exercise 1) — ${ARGO_NS} is not listable as this identity"
        hint "not yours to fix and not graded here: an attendee's only k8s read in ${ARGO_NS} is their own AppProject by name. Answer it where it can be answered — \`~/argocd appset list -p proj-${USER_NAME}\` in your own terminal after the beat-1 login, or an instructor/CI run of this script"
        ;;
      *)
        check "an ApplicationSet generates proj-${USER_NAME}'s Applications (exercise 1)" appset_for_user  || hint "not done yet? exercise 1 IS this check: log in with the argocd CLI and run \`~/argocd appset create applicationset.yaml\` from your claims-config clone — the entry state ships the source file in your fork and never creates the object. If you DID create it and this is red, that one is real: \`~/argocd appset list -p proj-${USER_NAME}\` (an appset that generates prod by some other route — oc apply -k rollouts/, or a hand-made Application — is not this exercise)"
        ;;
    esac
  fi
  check "parasol-claims runs as a Rollout in ${PROD} (Healthy)" rollout_healthy parasol-claims "$PROD"       || hint "not done yet? the entry state deliberately leaves ${PROD} WITHOUT a Rollout — converting it (rollouts/ overlay) IS the lab, so this red is expected before you start (ws solve gitops-at-scale --user ${USER_NAME} does the conversion). If you HAVE converted it and it is not Healthy, that one is real. Read the object — ${ROLLOUT_INSPECT} — and start from .status.phase. Progressing with no ready canary pods is usually quota: oc get events -n ${PROD} --sort-by=.lastTimestamp | tail -10. A Rollout that never leaves its initial state at all means no controller is serving it (instructor/admin: oc get rolloutmanager -n openshift-gitops). Paused is not broken — a canary pause step is waiting for YOU, and a blue-green pause is waiting for a promotion: ${ROLLOUT_PROMOTE_HINT}"
  # The outcome above says prod runs a Rollout; this says ARGO put it there. `oc apply -k rollouts/`
  # from the clone the lab already has you make produces an identically Healthy Rollout with no Argo
  # anywhere near it, and that is not this module. Attendee-readable (own namespace), so unlike the
  # ApplicationSet check this one grades on an attendee's own run too.
  check "prod Rollout was delivered by Argo CD (tracking annotation)" rollout_gitops_managed parasol-claims "$PROD" || hint "not done yet? no Rollout in ${PROD} yet means no annotation either — do the check above first. If the Rollout IS there and this is red, that one is real: it was applied by hand rather than generated from git. Delete it and let the ApplicationSet create it — oc get rollout parasol-claims -n ${PROD} -o jsonpath='{.metadata.annotations}'"
  check "route parasol-claims answers 200 in ${PROD}"     route_ready_200 "$PROD"                            || hint "not done yet? until the Rollout above exists there is nothing in ${PROD} to answer, so this red follows from that one and is equally expected. If the Rollout IS Healthy and the Route still does not answer 200, that one is real: oc get pods -n ${PROD}; ${ROLLOUT_INSPECT}; and check the Service the Route targets actually selects the active pods (a blue-green cutover moves that selector) — oc get route parasol-claims -n ${PROD} -o jsonpath='to={.spec.to.name}{\"\n\"}'"
fi

verify_summary
