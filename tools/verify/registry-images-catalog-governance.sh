#!/usr/bin/env bash
# Verify registry-images-catalog-governance — Registry, Images & Catalog Governance.
#   Entry: {user}-dev holds the seeded parasol-claims ImageStream (only the SEED tag — a pull-through
#          reference to the shared parasol-images build) and a SAMPLE private-registry pull Secret, with
#          NOTHING acted on yet: no promoted tag, no scheduled-import stream, no custom Template, the
#          pull secret unreferenced. Entry marker set.
#   End:   the attendee ran the three namespaced beats — parasol-claims carries the promoted tag
#          (tag/promote), an ext-ubi ImageStream re-imports an external repo on a schedule (scheduled
#          import), a custom Template lives in {user}-dev (namespaced catalog governance), and the sample
#          pull secret is referenced for pull by a workload or ServiceAccount (deploy-from-private-registry).
# Runnable as the ATTENDEE: reads ONLY {user}-dev objects the attendee sees via namespace admin (rule 10).
# The cluster-wide governance surface registry-images-catalog-governance also teaches (image.config, samples Config, ImagePruner, IDMS/
# ITMS, OperatorHub sources) is inspected via platform-observer and exercised by ws-meta smokeCommands, not
# here. The G1 cockpit smoke runs `--entry-only` as {user}.
#
# IMAGE-GAP NOTE: the seed tag resolves against the shared parasol-images build (populated by the workshop
# image-load step). Checks assert the DECLARED spec tags + object presence (immediate, import-independent),
# never that the underlying image finished importing — so a lagging registry pull never red-fails a
# correctly-materialized entry state.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"
IS_NAME="parasol-claims"
SEED_TAG="1.0"
PROMOTE_TAG="prod"
EXT_STREAM="ext-ubi"
PULL_SECRET="parasol-registry-creds"

# --- helpers (oc only) -------------------------------------------------------

# Every read below goes through _lib.sh's oc_read/oc_present/oc_absent rather than `2>/dev/null`, which
# cannot tell "the object is not there" (a gradeable ❌) from "the cluster did not answer" (a ⚠ that is
# never the attendee's fault). Predicates return 1 for both, and oc_read raises VERIFY_INCONCLUSIVE so
# check() picks the right one.

# The seeded ImageStream exists in {user}-dev.
is_present() { oc_present get is "$IS_NAME" -n "$NS" -o name; }

# The DECLARED spec-tag names on the seeded stream, into OC_OUT (space-separated; import-independent).
# rc 0 = the API ANSWERED, and an empty OC_OUT is a real answer: a genuinely missing stream declares no
# tags, which is what the entry negation below wants (its vacuity guard is the NAMESPACE, and the stream's
# own absence is graded by is_present). rc 1 = the API could not be asked.
is_spec_tags() {
  local rc=0
  oc_read get is "$IS_NAME" -n "$NS" -o jsonpath='{.spec.tags[*].name}' || rc=$?
  (( rc != 2 ))
}

# Does the seeded stream declare tag $1? (seed at entry; promoted tag at end.)
has_tag() {
  is_spec_tags || return 1
  printf '%s\n' "$OC_OUT" | tr ' ' '\n' | grep -qx "$1"
}

# The sample private-registry pull Secret exists and is a dockerconfigjson.
pull_secret_present() {
  oc_read get secret "$PULL_SECRET" -n "$NS" -o jsonpath='{.type}' || return 1
  [[ "$OC_OUT" == "kubernetes.io/dockerconfigjson" ]]
}

# The scheduled-import stream exists and declares at least one scheduled tag.
ext_scheduled() {
  oc_present get is "$EXT_STREAM" -n "$NS" -o name || return 1
  oc_read get is "$EXT_STREAM" -n "$NS" -o jsonpath='{.spec.tags[*].importPolicy.scheduled}' || return 1
  printf '%s' "$OC_OUT" | grep -qw true
}

# At least $1 custom Templates exist in {user}-dev (any namespaced Template is attendee-added — stock
# samples live in ns openshift). Outcome-focused: any parasol/custom template the content ships passes.
# A PREDICATE, not a count-printing helper: the count used to be consumed as `"$(custom_template_count)"`
# in a command substitution, and under `set -e` an assignment whose substitution exits non-zero kills the
# script outright — the exact regression the previous conversion pass hit in maas_cfg.
custom_template_min() {  # <n> → at least n namespaced Templates
  oc_read get templates -n "$NS" -o name || return 1
  local n
  n="$(printf '%s\n' "$OC_OUT" | grep -c . || true)"
  [[ "$n" -ge "$1" ]]   # >=, never ==: the lab may legitimately leave more than one Template behind
}

# The pull-secret names referenced by every ServiceAccount in {user}-dev (mechanic A), into OC_OUT…
sa_pull_refs() {
  oc_read get sa -n "$NS" -o jsonpath='{range .items[*]}{.imagePullSecrets[*].name}{" "}{end}'
}
# …and by every Deployment's pod template (mechanic B), into OC_OUT.
deploy_pull_refs() {
  oc_read get deploy -n "$NS" -o jsonpath='{range .items[*]}{.spec.template.spec.imagePullSecrets[*].name}{" "}{end}'
}

# The sample pull secret is wired for pull — either linked to a ServiceAccount's imagePullSecrets OR named
# in a Deployment's pod imagePullSecrets (accept BOTH mechanics the lab may use — rule 14 outcomes).
secret_referenced() {
  sa_pull_refs || return 1
  if printf '%s' "$OC_OUT" | grep -qw "$PULL_SECRET"; then return 0; fi
  deploy_pull_refs || return 1
  printf '%s' "$OC_OUT" | grep -qw "$PULL_SECRET"
}

# Any Deployment that NAMES the pull secret must actually be running.
#
# secret_referenced() above accepts either mechanic and short-circuits on the ServiceAccount link, so
# once mechanic A is done it returns 0 without ever looking at mechanic B's workload. That is how this
# script reported 9/9 green over an exercise-4 pod sitting in ImagePullBackOff for the whole lab
# (found by the registry-images cold-start smoke, 2026-07-31) — while the lab's own checkpoint and the
# troubleshooting page independently certified the same non-event. Three safety nets, one blind spot.
#
# Rule 14 says assert the OUTCOME, not the mechanism — and the outcome of exercise 4 is not "a
# reference exists somewhere", it is "the workload carrying that reference runs". Naming a pull secret
# on a pod template REPLACES the ServiceAccount's injected default-dockercfg-*, so getting this wrong
# is a live failure mode rather than a theoretical one: it is exactly what happened.
pull_secret_deploy_ready() {
  local names name
  # shellcheck disable=SC2016  # {{$n}} and {{"\n"}} are GO-TEMPLATE syntax evaluated by oc, not shell
  # expansions — single quotes are required here. Only "$PULL_SECRET" is deliberately shell-expanded,
  # by closing and reopening the quoting around it.
  oc_read get deploy -n "$NS" -o go-template='{{range .items}}{{$n := .metadata.name}}{{range .spec.template.spec.imagePullSecrets}}{{if eq .name "'"$PULL_SECRET"'"}}{{$n}}{{"\n"}}{{end}}{{end}}{{end}}' || return 1
  names="$OC_OUT"
  # No such Deployment means exercise 4's mechanic B was never done — not a pass. The lab creates one.
  [[ -n "$names" ]] || return 1
  while read -r name; do
    [[ -n "$name" ]] || continue
    # deploy_ready is the SHARED _lib.sh helper, not a local copy — a re-definition here would shadow it
    # for this one caller, the drift the read guard's detector [2] exists to catch.
    deploy_ready "$name" "$NS" || return 1
  done <<< "$names"
  return 0
}

# Entry clean-slate helpers: return 0 when the lab outcome is ABSENT (attendee has done nothing).
# Each requires the namespace to actually exist first — otherwise "absent" is vacuous (true on a
# cluster where nothing materialized at all), not evidence of a clean, correctly-seeded entry state.
#
# NONE of these negates a plain predicate any more. `! has_tag …` and `! secret_referenced` returned 0 —
# a PASS — when the API could not be asked, because those helpers report "no" and "could not ask" with
# the same rc. Each negation now reads for itself and bails out on inconclusive, so an unreachable API
# gives ⚠ instead of certifying a clean slate. That matters more here than anywhere else in the script:
# a wrongly-green entry check sends `ws prep` down its "already prepared" fast path.
no_promote_tag() {
  oc_present get ns "$NS" -o name || return 1
  is_spec_tags || return 1
  ! printf '%s\n' "$OC_OUT" | tr ' ' '\n' | grep -qx "$PROMOTE_TAG"
}
no_ext_stream() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent get is "$EXT_STREAM" -n "$NS" -o name
}
no_custom_template() {
  oc_present get ns "$NS" -o name || return 1
  oc_absent get templates -n "$NS" -o name
}
secret_unreferenced() {
  oc_present get ns "$NS" -o name || return 1
  local sa_refs
  sa_pull_refs || return 1
  sa_refs="$OC_OUT"
  deploy_pull_refs || return 1
  ! printf '%s %s' "$sa_refs" "$OC_OUT" | grep -qw "$PULL_SECRET"
}

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                     || hint "run: ws prep registry-images-catalog-governance (or ws start registry-images-catalog-governance --user ${USER_NAME})"
check "entry marker ws-entry-registry-images-catalog-governance present"               oc get cm ws-entry-registry-images-catalog-governance -n "$NS"     || hint "entry app not synced — ws reset registry-images-catalog-governance --user ${USER_NAME}"
check "seeded ImageStream ${IS_NAME} present"           is_present                          || hint "entry app not synced — ws reset registry-images-catalog-governance --user ${USER_NAME}"
check "ImageStream ${IS_NAME} declares the seed tag :${SEED_TAG}" has_tag "$SEED_TAG"       || hint "the seed tag is missing — ws reset registry-images-catalog-governance --user ${USER_NAME}"
check "sample private-registry pull Secret ${PULL_SECRET} present" pull_secret_present      || hint "entry app not synced — ws reset registry-images-catalog-governance --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — the attendee has acted on NOTHING yet ---------------------------------
  check "no promoted :${PROMOTE_TAG} tag yet (attendee tags/promotes it)"    no_promote_tag      || hint "entry ships only :${SEED_TAG}; if :${PROMOTE_TAG} exists the lab already started — ws reset registry-images-catalog-governance --user ${USER_NAME}"
  check "no ${EXT_STREAM} scheduled-import stream yet (attendee imports it)" no_ext_stream       || hint "entry ships no ${EXT_STREAM}; if it exists the lab already started — ws reset registry-images-catalog-governance --user ${USER_NAME}"
  check "no custom Template in ${NS} yet (attendee adds one)"                no_custom_template  || hint "entry ships no namespaced Template; if one exists the lab already started — ws reset registry-images-catalog-governance --user ${USER_NAME}"
  check "sample pull Secret is NOT referenced yet (attendee links/uses it)"  secret_unreferenced || hint "entry ships it unreferenced; if a SA/Deployment uses it the lab already started — ws reset registry-images-catalog-governance --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOMES — promote + scheduled import + catalog Template + pull-secret use ---
  # Assert OUTCOMES (a promoted tag exists; a scheduled stream exists; a custom Template exists; the pull
  # secret is referenced), never the exact mechanism, so any correct solution stays green (rule 14).
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "parasol-claims carries the promoted :${PROMOTE_TAG} tag (tag/promote)" has_tag "$PROMOTE_TAG" \
    || hint "not done yet — the entry state ships only :${SEED_TAG}, and promoting is the lab: oc tag ${NS}/${IS_NAME}:${SEED_TAG} ${NS}/${IS_NAME}:${PROMOTE_TAG}"
  check "${EXT_STREAM} ImageStream re-imports on a schedule (scheduled import)" ext_scheduled \
    || hint "not done yet — the entry state ships no ${EXT_STREAM}, and importing it is the lab: oc import-image ${NS}/${EXT_STREAM} --from=registry.access.redhat.com/ubi9/ubi:latest --scheduled --confirm"
  check "a custom Template exists in ${NS} (namespaced catalog governance)" custom_template_min 1 \
    || hint "not done yet — the entry state ships no namespaced Template; adding one is the lab: oc apply -f <your-template>.yaml -n ${NS} (see the lab)"
  check "sample pull Secret ${PULL_SECRET} is referenced for pull (private-registry deploy)" secret_referenced \
    || hint "not done yet — the entry state ships ${PULL_SECRET} unreferenced on purpose; using it is the lab: oc secrets link deployer ${PULL_SECRET} --for=pull -n ${NS} (or name it in a pod's imagePullSecrets)"
  check "the workload naming ${PULL_SECRET} is actually running (mechanic B)" pull_secret_deploy_ready \
    || hint "not done yet? exercise 4's Deployment does not exist until you create it, so this red is expected before then. If it EXISTS and is short of >=1 ready replica, that one is real — and if it is ImagePullBackOff with 'authentication required', the pod template names a pull secret AND pulls from the internal registry: naming one REPLACES the ServiceAccount's default-dockercfg-*, so use a public image or name both secrets"
fi

verify_summary
