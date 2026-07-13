#!/usr/bin/env bash
# Verify M17 — Registry, Images & Catalog Governance.
#   Entry: {user}-dev holds the seeded parasol-claims ImageStream (only the SEED tag — a pull-through
#          reference to the shared parasol-images build) and a SAMPLE private-registry pull Secret, with
#          NOTHING acted on yet: no promoted tag, no scheduled-import stream, no custom Template, the
#          pull secret unreferenced. Entry marker set.
#   End:   the attendee ran the three namespaced beats — parasol-claims carries the promoted tag
#          (tag/promote), an ext-ubi ImageStream re-imports an external repo on a schedule (scheduled
#          import), a custom Template lives in {user}-dev (namespaced catalog governance), and the sample
#          pull secret is referenced for pull by a workload or ServiceAccount (deploy-from-private-registry).
# Runnable as the ATTENDEE: reads ONLY {user}-dev objects the attendee sees via namespace admin (rule 10).
# The cluster-wide governance surface M17 also teaches (image.config, samples Config, ImagePruner, IDMS/
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

# The seeded ImageStream exists in {user}-dev.
is_present() { oc get is "$IS_NAME" -n "$NS" >/dev/null 2>&1; }

# The DECLARED spec-tag names on the seeded stream (space-separated; import-independent).
is_spec_tags() { oc get is "$IS_NAME" -n "$NS" -o jsonpath='{.spec.tags[*].name}' 2>/dev/null || true; }

# Does the seeded stream declare tag $1? (seed at entry; promoted tag at end.)
has_tag() { is_spec_tags | tr ' ' '\n' | grep -qx "$1"; }

# The sample private-registry pull Secret exists and is a dockerconfigjson.
pull_secret_present() {
  [[ "$(oc get secret "$PULL_SECRET" -n "$NS" -o jsonpath='{.type}' 2>/dev/null || true)" == "kubernetes.io/dockerconfigjson" ]]
}

# The scheduled-import stream exists and declares at least one scheduled tag.
ext_scheduled() {
  oc get is "$EXT_STREAM" -n "$NS" >/dev/null 2>&1 || return 1
  oc get is "$EXT_STREAM" -n "$NS" -o jsonpath='{.spec.tags[*].importPolicy.scheduled}' 2>/dev/null | grep -qw true
}

# Count of custom Templates in {user}-dev (any namespaced Template is attendee-added — stock samples live
# in ns openshift). Outcome-focused: any parasol/custom template the content ships passes.
custom_template_count() { oc get templates -n "$NS" -o name 2>/dev/null | grep -c . || true; }

# The sample pull secret is wired for pull — either linked to a ServiceAccount's imagePullSecrets OR named
# in a Deployment's pod imagePullSecrets (accept BOTH mechanics the lab may use — rule 14 outcomes).
secret_referenced() {
  oc get sa -n "$NS" -o jsonpath='{range .items[*]}{.imagePullSecrets[*].name}{" "}{end}' 2>/dev/null \
    | grep -qw "$PULL_SECRET" && return 0
  oc get deploy -n "$NS" -o jsonpath='{range .items[*]}{.spec.template.spec.imagePullSecrets[*].name}{" "}{end}' 2>/dev/null \
    | grep -qw "$PULL_SECRET" && return 0
  return 1
}

# Entry clean-slate helpers: return 0 when the lab outcome is ABSENT (attendee has done nothing).
no_promote_tag()    { ! has_tag "$PROMOTE_TAG"; }
no_ext_stream()     { ! oc get is "$EXT_STREAM" -n "$NS" >/dev/null 2>&1; }
no_custom_template(){ [[ "$(custom_template_count)" == "0" ]]; }
secret_unreferenced() { ! secret_referenced; }

# --- shared checks (hold at BOTH entry and end) ------------------------------
check "namespace ${NS} exists"                          oc get ns "$NS"                     || hint "run: ws prep m17 (or ws start m17 --user ${USER_NAME})"
check "entry marker ws-entry-m17 present"               oc get cm ws-entry-m17 -n "$NS"     || hint "entry app not synced — ws reset m17 --user ${USER_NAME}"
check "seeded ImageStream ${IS_NAME} present"           is_present                          || hint "entry app not synced — ws reset m17 --user ${USER_NAME}"
check "ImageStream ${IS_NAME} declares the seed tag :${SEED_TAG}" has_tag "$SEED_TAG"       || hint "the seed tag is missing — ws reset m17 --user ${USER_NAME}"
check "sample private-registry pull Secret ${PULL_SECRET} present" pull_secret_present      || hint "entry app not synced — ws reset m17 --user ${USER_NAME}"

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # --- entry state: clean slate — the attendee has acted on NOTHING yet ---------------------------------
  check "no promoted :${PROMOTE_TAG} tag yet (attendee tags/promotes it)"    no_promote_tag      || hint "entry ships only :${SEED_TAG}; if :${PROMOTE_TAG} exists the lab already started — ws reset m17 --user ${USER_NAME}"
  check "no ${EXT_STREAM} scheduled-import stream yet (attendee imports it)" no_ext_stream       || hint "entry ships no ${EXT_STREAM}; if it exists the lab already started — ws reset m17 --user ${USER_NAME}"
  check "no custom Template in ${NS} yet (attendee adds one)"                no_custom_template  || hint "entry ships no namespaced Template; if one exists the lab already started — ws reset m17 --user ${USER_NAME}"
  check "sample pull Secret is NOT referenced yet (attendee links/uses it)"  secret_unreferenced || hint "entry ships it unreferenced; if a SA/Deployment uses it the lab already started — ws reset m17 --user ${USER_NAME}"
else
  # --- end state: the lab's OUTCOMES — promote + scheduled import + catalog Template + pull-secret use ---
  # Assert OUTCOMES (a promoted tag exists; a scheduled stream exists; a custom Template exists; the pull
  # secret is referenced), never the exact mechanism, so any correct solution stays green (rule 14).
  check "parasol-claims carries the promoted :${PROMOTE_TAG} tag (tag/promote)" has_tag "$PROMOTE_TAG" \
    || hint "promote it: oc tag ${NS}/${IS_NAME}:${SEED_TAG} ${NS}/${IS_NAME}:${PROMOTE_TAG}"
  check "${EXT_STREAM} ImageStream re-imports on a schedule (scheduled import)" ext_scheduled \
    || hint "oc import-image ${NS}/${EXT_STREAM} --from=registry.access.redhat.com/ubi9/ubi:latest --scheduled --confirm"
  check "a custom Template exists in ${NS} (namespaced catalog governance)" test "$(custom_template_count)" -ge 1 \
    || hint "add a namespaced Template to ${NS}: oc apply -f <your-template>.yaml -n ${NS} (see the lab)"
  check "sample pull Secret ${PULL_SECRET} is referenced for pull (private-registry deploy)" secret_referenced \
    || hint "link it: oc secrets link deployer ${PULL_SECRET} --for=pull -n ${NS} (or name it in a pod's imagePullSecrets)"
fi

verify_summary
