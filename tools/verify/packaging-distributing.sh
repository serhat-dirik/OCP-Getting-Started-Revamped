#!/usr/bin/env bash
# Verify packaging-distributing — Packaging & Distributing Your App (Helm/OLM).
#   Entry: {user}-dev holds the entry marker; the attendee has a Gitea fork {user}/parasol-notifications
#          (the Helm target) and a PREBUILT istag parasol-notifications:1.0 in {user}-dev, so `helm
#          install` has a pullable image. The platform-observer ClusterRole lets the attendee DISSECT a
#          live operator's OLM bundle (CSV/Subscription/InstallPlan/CRD) read-only. Nothing is deployed
#          yet — the attendee runs helm create/install/upgrade/rollback by hand.
#   End:   the notifications app is DEPLOYED to {user}-dev (Deployment parasol-notifications) — the
#          outcome of the Helm install lab.
# Runnable as the ATTENDEE: reads only {user}-dev objects (namespace admin), the attendee's own public
# Gitea fork over HTTPS (URL from the marker), and cluster-scoped OLM metadata via platform-observer
# (no peer-namespace reads). The G1 cockpit smoke runs `--entry-only` as {user}.
#
# BARE-NAME TRAP: fully-qualify subscriptions.operators.coreos.com and packagemanifests.packages.
# operators.coreos.com — bare `oc get subscription`/`packagemanifest` resolve to Knative's Subscription
# and another catalog's channels (live traps this script deliberately avoids).
# HELM + DISSECTION-TARGET are environment facts reported as INFO (never failed): the OCI-capable helm
# client lives in the cockpit image (the ws smoke gate hard-checks 'helm version'), and the recommended
# Pipelines dissection target is a PLATFORM install, not per-user entry state.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- helpers (oc + curl only) ------------------------------------------------

# Every oc read below goes through _lib.sh's oc_read/oc_present/oc_absent rather than `2>/dev/null`,
# which cannot tell "the key/object is not there" (a gradeable ❌) from "the cluster did not answer" (a
# ⚠ that is never the attendee's fault). Predicates return 1 for both, and oc_read raises
# VERIFY_INCONCLUSIVE so check() picks the right one.

# A field from the entry marker (single source of truth for repo URL / image / dissection target).
# THREE outcomes, into OC_OUT — deliberately NOT an echoing helper. Every graded caller below reads
# OC_OUT in ITS OWN shell: `v="$(marker …)"` would be a subshell, and the VERIFY_INCONCLUSIVE oc_read
# raises inside one dies with it, so an unreachable API would land as a hard ❌ on the attendee's work
# instead of a ⚠. rc 0 = the API answered (an empty OC_OUT is a real answer: the key is not set) ·
# 1 = the marker itself is genuinely absent · 2 = could not ask.
marker() { oc_read get cm ws-entry-packaging-distributing -n "$NS" -o jsonpath="{.data.$1}"; }

# The same field for DISPLAY only — check descriptions and INFO lines, where the value is prose and
# there is no verdict to grade. Echo-shaped and always rc 0, because every call site is
# `"$(marker_v …)"` inside a string and, under `set -e`, an assignment or expansion whose command
# substitution fails kills the script outright (measured in a4c632f).
marker_v() { marker "$1" || OC_OUT=""; printf '%s' "$OC_OUT"; }

# The prebuilt notifications istag exists in {user}-dev (helm install has something to pull).
istag_present() {
  local name tag
  marker imageName || return 1; name="$OC_OUT"
  marker imageTag  || return 1; tag="$OC_OUT"
  [[ -n "$name" && -n "$tag" ]] || return 1
  oc_present get istag "${name}:${tag}" -n "$NS" -o name
}

# The attendee's notifications fork is reachable (public repo → anonymous HTTPS GET 200). Net-tolerant.
repo_reachable() {
  local u
  marker notificationsRepo || return 1; u="$OC_OUT"
  [[ -n "$u" ]] || return 1
  curl -ksf --max-time 10 "$u" >/dev/null 2>&1
}

# platform-observer OLM-dissection reads (fully-qualified — the bare kinds are live traps).
#
# ASK THE OBJECT, NOT `can-i`. These two checks exist to catch a MISSING platform-observer grant, and
# `oc auth can-i` cannot answer that reliably for either of them:
#   · clusterserviceversions is NAMESPACED, and the stock `admin` ClusterRole — which every attendee
#     holds on their own namespaces via a RoleBinding — grants operators.coreos.com/
#     clusterserviceversions get,list,watch outright (verified on-cluster 2026-08-01). So a can-i that
#     lands on the attendee's OWN namespace answers "yes" without the observer grant existing at all.
#   · customresourcedefinitions is CLUSTER-SCOPED, and a namespaced RoleBinding to a ClusterRole
#     carrying a cluster-scoped rule can make can-i report it granted from inside that namespace while
#     the real GET is refused — the trap that showed every attendee a red ❌ on a healthy ClusterQueue
#     (jobs-batch-kueue, 2026-07-31). Measured here 2026-08-01: `admin`'s apiextensions rules are
#     resourceNames-scoped, so THIS cluster happens to answer "no" — but a check must not rest on an
#     accident of which operators aggregate into `admin`.
# So: attempt the real read and classify the server's answer. Forbidden IS the failure these checks
# exist for (platform-observer is meant to grant both, cluster-wide); anything else means the caller
# could not ask, which is inconclusive (⚠), never a ❌.
#
# IDENTITY (unchanged reasoning): `ws verify` run by an instructor/CI is cluster-admin, and an
# unimpersonated read answers for the ADMIN — green while the attendee gets Forbidden. But `--as`
# needs impersonate rights the ATTENDEE does not have (measured 2026-07-29), and `ws` runs these from
# inside the cockpit AS userN, where an unguarded --as errors and produces a false ❌ on a correct
# world. When the caller IS the attendee, their own read is already the attendee answer. Both
# impersonation flags are literal, never an unquoted variable.
# Returns: 0 = readable · 1 = Forbidden · 2 = could not ask (API error / namespace absent / unreachable).
#
# The two probes that PICK the identity go through oc_read too — they are ordinary reads, and the
# tmpfile classification below is only for the read being GRADED (where Forbidden is the failure this
# check exists for, the opposite of oc_read's reading of it).
_attendee_read() {  # _attendee_read <oc get args…>
  local err rc=0 tmp="/tmp/.pkgdist-read.$$" me imp_rc=0
  oc_read whoami || OC_OUT=""
  me="$OC_OUT"
  oc_read auth can-i impersonate users || imp_rc=$?
  if [[ "$me" != "$USER_NAME" && "$imp_rc" -eq 0 ]]; then
    oc get "$@" -o name --as="$USER_NAME" --as-group=workshop-attendees >/dev/null 2>"$tmp" || rc=$?
  else
    oc get "$@" -o name >/dev/null 2>"$tmp" || rc=$?
  fi
  err="$(cat "$tmp" 2>/dev/null || true)"; rm -f "$tmp"
  if (( rc == 0 )); then return 0; fi
  case "$err" in *orbidden*) return 1 ;; *) return 2 ;; esac
}

# Same returns as _attendee_read, plus 3 = the entry marker names NO dissection namespace. A blank
# marker must never fall through to `-n ""`: oc then silently substitutes the CALLER'S context
# namespace, which for an attendee is one of their own — where stock `admin` grants CSV read outright,
# so the check would report the observer grant healthy without ever having looked at it.
observer_reads_csv() {
  local ns rc=0
  # rc 2 (could not ask) is this function's own "could not ask" — the *) warn arm. rc 1 (the marker CM
  # is genuinely gone) leaves OC_OUT empty and falls through to 3, exactly as the old blind read did:
  # the marker's absence is already graded by its own check above, so it must not become a second ⚠.
  marker dissectionOperatorNamespace || rc=$?
  (( rc != 2 )) || return 2
  ns="$OC_OUT"
  [[ -n "$ns" ]] || return 3
  _attendee_read clusterserviceversions.operators.coreos.com -n "$ns"
}
observer_reads_crd() { _attendee_read customresourcedefinitions.apiextensions.k8s.io; }

# Deployment presence in {user}-dev (the notifications app the finished lab leaves running).
# The name guard is new and defensive: `oc get deploy ""` is not a name lookup at all, and a shape that
# can silently widen into "list every Deployment" has no business behind a graded ✅.
deploy_present() {
  local name
  marker imageName || return 1; name="$OC_OUT"
  [[ -n "$name" ]] || return 1
  oc_present get deploy "$name" -n "$NS" -o name
}
# Namespace and a resolved image name are required first — otherwise an empty name / missing
# namespace makes `oc get deploy ""` error and the negation is vacuously true, not evidence of a
# clean, correctly-seeded entry state. oc_absent adds the third case the old `!` could not express:
# an API that never answered no longer certifies the clean slate `ws prep` reads as "already prepared".
no_deploy() {
  local name
  marker imageName || return 1; name="$OC_OUT"
  [[ -n "$name" ]] || return 1
  oc_present get ns "$NS" -o name || return 1
  oc_absent get deploy "$name" -n "$NS" -o name
}

# --- the HELM half of a Helm module (false-pass audit F-10, 2026-08-05) -------------------------
#
# The only completion check used to be "a Deployment named parasol-notifications exists in
# {user}-dev". `oc create deployment parasol-notifications --image=…` satisfies that exactly as well
# as the six-exercise chart lab does: the whole reason the module exists — scaffold a chart, template
# it, install it as a RELEASE, upgrade it, break it, roll it back — could be skipped and still print
# green. That is not a check that passes on an untouched world (the Deployment IS attendee work), it
# is a check that grades the OUTCOME and never the DECLARATION the attendee wrote.
#
# So: keep the Deployment as the outcome, and grade the artefact Helm itself leaves. Helm 3's default
# storage driver records every REVISION of every release as its own Secret in the release's namespace,
# named sh.helm.release.v1.<release>.v<N>. The entry state installs no chart at all, so any such
# Secret in {user}-dev is attendee work, and N is the revision counter exercise 4 walks.
#
# READ BY NAME, not by label or field selector, and this is a deliberate narrowing of what has to be
# TRUE for the check to be right. Helm also labels those Secrets (owner/name/status/version) and types
# them helm.sh/release.v1, and either would have been a tidier query — but every extra assumption
# about someone else's storage format is another way to red-line an attendee who did the lab
# correctly, and this file may not be re-grounded against a live release before the next workshop.
# The name is the storage KEY: Helm looks releases up by it, so it is the one part that cannot drift
# without breaking Helm itself. `-o name` also prints names only — no Secret values are ever read.
#
# DELIBERATELY NOT PINNED to the release name either. The lab says `helm install
# parasol-notifications`, but a release the attendee named otherwise is still a correct solution
# (rule 14), and trading a false ✅ for a false ❌ on someone who did the lab right is not a win.

# WHO BUILT THIS WORLD. `ws solve` renders the finished Deployment/Service/Route straight from this
# module's chart through Argo (templates/solve-endstate.yaml) — there is no `helm install` anywhere in
# that path, so a solved world has NO Helm release and correctly never will. Grading the two Helm
# assertions there would red-line a correct instructor/CI run, which is the same trust bug pointed the
# other way. Detected from the object's own chart label rather than from --solve, so `ws solve`
# followed by a plain `ws verify` (no flag) is classified identically — the flag is not the fact.
solve_rendered_deploy() {
  oc_present get deploy -n "$NS" \
    -l workshop.redhat.com/module=packaging-distributing,workshop.redhat.com/owner=ogsr -o name
}

# The namespace's release Secrets, into a global — the caller reads it in ITS OWN shell, because
# `$(…)` would be a subshell and the VERIFY_INCONCLUSIVE oc_read raises inside one dies with it,
# landing an unreachable API as a hard ❌ instead of a ⚠ (same argument as marker() above).
HELM_RELEASE_SECRETS=""
helm_release_secrets() {  # 0 = the API answered (0+ lines) · 1 = genuinely absent or could not ask
  HELM_RELEASE_SECRETS=""
  oc_read get secret -n "$NS" -o name || return 1
  HELM_RELEASE_SECRETS="$(grep -E '(^|/)sh\.helm\.release\.v1\..+\.v[0-9]+$' <<<"$OC_OUT" || true)"
  return 0
}

# A Helm release — any release, any name — is recorded in {user}-dev.
helm_release_present() {
  helm_release_secrets || return 1
  [[ -n "$HELM_RELEASE_SECRETS" ]]
}

# Exercise 4 — upgrade, break it on purpose, roll back — left nothing graded at all before this.
# `helm install` alone records revision 1; the lab's upgrade (2) → broken-probe upgrade (3) →
# `helm rollback` (4) walks it to 4, and every one of those is its own release Secret.
# `>=`, never `==`: revisions only accumulate, and an attendee who upgrades more times is not wrong.
HELM_MAX_REV=0
helm_max_revision() {  # 0 = the API answered (HELM_MAX_REV set, 0 when there is no release) · 1 = could not ask
  local n v
  HELM_MAX_REV=0
  helm_release_secrets || return 1
  # `${n##*.v}` takes the text after the LAST ".v", so a release whose own name contains ".v"
  # (…v1.my.v9.v2) still yields the revision, not the release's own suffix.
  # if/then inside the loop, never `[[ … ]] && …` — the AND-list form returns 1 from the enclosing
  # function when the test is false, which under this script's `set -e` kills it outright.
  while read -r n; do
    v="${n##*.v}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v > HELM_MAX_REV )); then HELM_MAX_REV="$v"; fi
  done <<<"$HELM_RELEASE_SECRETS"
  return 0
}
helm_release_upgraded() {
  helm_max_revision || return 1
  (( HELM_MAX_REV >= 2 ))
}

# CLEAN SLATE, the other direction. no_deploy alone already guarantees that a COMPLETE world cannot
# pass entry mode (the end state is a conjunction — see the entry block). This closes the residue case
# it does not cover: a release whose Deployment was deleted by hand leaves the release Secret behind,
# no_deploy calls the namespace clean, `ws prep` takes its "already prepared" fast path WITHOUT
# purging, and the attendee's first command — `helm install parasol-notifications` — dies with
# "cannot re-use a name that is still in use". The entry state installs no chart, so any release here
# is leftover by definition.
no_helm_release() {
  oc_present get ns "$NS" -o name || return 1
  # helm_release_secrets returns 1 when the API could not be asked, and oc_read has already raised
  # VERIFY_INCONCLUSIVE by then — so silence renders ⚠, never a certified clean slate.
  helm_release_secrets || return 1
  [[ -z "$HELM_RELEASE_SECRETS" ]]
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                 || hint "run: ws prep packaging-distributing (or ws start packaging-distributing --user ${USER_NAME}); ${NS} is workshop-layer (per-user-namespaces)"
check "entry marker ws-entry-packaging-distributing present"               oc get cm ws-entry-packaging-distributing -n "$NS" || hint "entry app not synced — ws reset packaging-distributing --user ${USER_NAME}"
check "Helm target fork parasol-notifications reachable in Gitea" repo_reachable        || hint "the fork {user}/parasol-notifications is missing — check the gitea-fork Job (ws reset packaging-distributing --user ${USER_NAME}); needs parasol/parasol-notifications seeded (workshop-config app-repo-seed)"
check "prebuilt image istag $(marker_v imageName):$(marker_v imageTag) present in ${NS}" istag_present \
  || hint "the notifications image is not built — check the notifications-build Job (ws reset packaging-distributing --user ${USER_NAME}); inspect: oc logs -f bc/$(marker_v imageName) -n ${NS}"
CSV_DESC="platform-observer: attendee can read OLM ClusterServiceVersions (bundle dissection)"
csv_rc=0; observer_reads_csv || csv_rc=$?
case "$csv_rc" in
  0) check "$CSV_DESC" true ;;
  1) check "$CSV_DESC" false \
       || hint "extend platform-observer with operators.coreos.com {clusterserviceversions,subscriptions,installplans,operatorgroups} — gitops/workshop-config/templates/platform-observer-clusterrole.yaml, then sync workshop-config" ;;
  3) check "$CSV_DESC" false \
       || hint "the entry marker carries no dissectionOperatorNamespace, so this check has no target namespace to read — re-materialize the entry state: ws reset packaging-distributing --user ${USER_NAME}" ;;
  *) warn "OLM ClusterServiceVersion read could not be evaluated — the API did not answer, or namespace $(marker_v dissectionOperatorNamespace) does not exist on this cluster"
     hint "re-run from the cockpit terminal as ${USER_NAME}, or check the dissection target: oc get ns $(marker_v dissectionOperatorNamespace)" ;;
esac

CRD_DESC="platform-observer: attendee can read CustomResourceDefinitions"
crd_rc=0; observer_reads_crd || crd_rc=$?
case "$crd_rc" in
  0) check "$CRD_DESC" true ;;
  1) check "$CRD_DESC" false \
       || hint "extend platform-observer with apiextensions.k8s.io/customresourcedefinitions (get,list,watch)" ;;
  *) warn "CustomResourceDefinition read could not be evaluated — the API did not answer"
     hint "re-run from the cockpit terminal as ${USER_NAME}, or check cluster reachability: oc whoami" ;;
esac

# INFO: the OCI-capable helm client (hard-checked by the cockpit smoke gate, not failed here so
# standalone/CI verify on a runner without helm stays green).
if command -v helm >/dev/null 2>&1; then
  info "helm client present: $(helm version --short 2>/dev/null || echo '?') (OCI push/pull needs >= 3.8)"
else
  info "helm not on THIS PATH — the attendee cockpit image ships it (ws smoke hard-checks 'helm version'); not required for standalone verify"
fi
# INFO: the recommended read-only dissection target is a platform install (not per-user entry state).
DTN="$(marker_v dissectionSubscriptionName)"; DTNS="$(marker_v dissectionOperatorNamespace)"
# oc_present rather than a silenced probe. Both arms are INFO, so no verdict changes either way — but
# routing the last raw read in this file through the shared primitive is what keeps the file at zero,
# so the next silenced read added here fails the ratchet outright instead of being absorbed.
# (VERIFY_INCONCLUSIVE raised here cannot leak into a verdict: check() clears it before every assertion.)
if [[ -n "$DTN" ]] && oc_present get subscriptions.operators.coreos.com "$DTN" -n "$DTNS" -o name; then
  info "dissection target readable: subscriptions.operators.coreos.com/${DTN} in ${DTNS} (the 'customer clicked your tile' chain)"
else
  info "dissection target ${DTN:-<unset>} not readable here — content may target another installed operator (GitOps/Serverless/…); dissection is read-only against whatever the cluster runs"
fi

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — the attendee has not installed the chart yet ------------------------
  # no_deploy negates deploy_present on the same read (plus a namespace precondition, which only makes
  # it stricter). `ws prep` reads this mode's rc as "is this world already prepared?", so a gap between
  # the two modes would let it skip setup — or offer to WIPE a finished lab.
  # The end state is a CONJUNCTION — Deployment AND release AND revision>1 — so negating any ONE
  # conjunct already guarantees a completed world can never pass entry mode, and no_deploy negates the
  # first. (The trap to avoid is the opposite shape: had the end state been a DISJUNCTION — "release
  # OR Deployment" — negating one side would leave a world that is both "complete" in full mode and "a
  # clean slate" here, which is how `ws prep` gets talked into skipping setup, or into offering to
  # WIPE a finished lab.) The second check is not that invariant; it is the residue case no_deploy
  # cannot see — a release Secret outliving its Deployment, which blocks the attendee's first command.
  check "no notifications app deployed yet (attendee runs helm install)" no_deploy \
    || hint "parasol-notifications is already deployed; the lab already ran — ws reset packaging-distributing --user ${USER_NAME}"
  check "no Helm release recorded in ${NS} yet" no_helm_release \
    || hint "a release from an earlier run is still recorded here and 'helm install' will refuse the name — ws reset packaging-distributing --user ${USER_NAME} (or, by hand: helm uninstall <name> -n ${NS}; list them with helm list -n ${NS})"
else
  # --- end state: the lab's OUTCOME — the notifications app deployed to {user}-dev --------------------
  # Assert the OUTCOME (a notifications Deployment is running), never the exact mechanism that put it
  # there, so any correct solution (helm install OR ws solve) stays green (rule 14) …
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "notifications app parasol-notifications deployed" deploy_present \
    || hint "not done yet — the entry state deliberately deploys nothing here, because running the chart IS the lab: helm install parasol-notifications ./parasol-notifications -n ${NS} (or: ws solve packaging-distributing --user ${USER_NAME}). Red before that is the expected state, not a broken environment"
  # … and then grade the DECLARATION the attendee wrote, because the outcome alone is satisfied by an
  # `oc create deployment` that skips the entire Helm lesson (F-10). On a world `ws solve` built there
  # is no release to find and there never should be — that is a known, correct absence (na), not an
  # unknown (warn) and not a failure.
  if solve_rendered_deploy; then
    na "Helm release recorded in ${NS} — this world was materialized by ws solve, which renders the finished Deployment from the chart through Argo; no helm install ran, so no release exists or should"
    na "Helm release carries more than one revision (exercise 4) — ws solve materializes the finished world in one shot, so there is no release history to read"
  else
    check "a Helm release is recorded in ${NS} (the chart was installed, not hand-created)" helm_release_present \
      || hint "not done yet — a Deployment on its own is not a release: the lesson is the chart. Scaffold and install it (exercises 1-3): helm create parasol-notifications, shape it, then helm install parasol-notifications ./parasol-notifications -n ${NS}. Already installed? Check it landed in the right namespace — helm list -n ${NS}"
    check "the Helm release carries more than one revision (exercise 4: upgrade -> broken probe -> rollback)" helm_release_upgraded \
      || hint "not done yet — exercise 4 is the release-lifecycle beat, and revision 1 means only the install ran: helm upgrade parasol-notifications ./parasol-notifications -n ${NS} --set replicaCount=2, then the deliberate broken-probe upgrade, then helm rollback. Verify with: helm history parasol-notifications -n ${NS}"
  fi
fi

verify_summary
