#!/usr/bin/env bash
# Workshop bootstrap — the thin layer ON TOP of the workshop-agnostic platform portfolio.
# It does the imperative, workshop-specific things the portfolio must never know about:
#   1. install the mapped portfolio stacks (core-devtools [+ ai-assist])
#   2. create the secret CONTRACTS (htpasswd users, MaaS token, shared Gitea password)
#   3. wait for the in-cluster Gitea mirror (git-localize, D15) to be ready
#   4. materialize the workshop layer (users, RBAC, quotas, AppProject, IdP, Gitea seeding)
#      as ONE Argo CD Application sourced from the LOCAL mirror — the git-localize payoff
#
# All inputs come from vars.yaml (same dir, gitignored). Idempotent: safe to re-run.
#
# Usage: ./install.sh          (reads ./vars.yaml)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS="${SCRIPT_DIR}/vars.yaml"
PORTFOLIO_INSTALL="${SCRIPT_DIR}/../platform-portfolio/argocd-bootstrap/install.sh"
CREDS_FILE="${SCRIPT_DIR}/.credentials.local.txt"
MODULES_YAML="${SCRIPT_DIR}/../modules.yaml"   # SSOT for module order + per-module `stacks:` deps

GITEA_NS="ogsr-gitea"
MIRROR_ORG="parasol"
MIRROR_REPO="ocp-getting-started"
USER_PREFIX="user"

ok()   { echo "✅ $*"; }
err()  { echo "❌ $*" >&2; }
warn() { echo "⚠️  $*" >&2; }   # was CALLED but never defined — under `set -u` an undefined command is
info() { echo "▶ $*"; }         # a 127 exit, so the RHDH branch below aborted the install instead of warning
die()  { err "$*"; exit 1; }

# ── preflight: tooling + vars file ────────────────────────────────────────────
command -v oc >/dev/null || die "oc not found in PATH"
command -v yq >/dev/null || die "yq not found — install it (brew install yq / dnf install yq); mikefarah/go yq v4 syntax expected"
command -v htpasswd >/dev/null || die "htpasswd not found — install it (brew install httpd / dnf install httpd-tools)"
command -v openssl >/dev/null || die "openssl not found — needed to generate/handle passwords"
[[ -f "$VARS" ]] || die "missing ${VARS} — copy vars.example.yaml to vars.yaml and fill it in"
[[ -x "$PORTFOLIO_INSTALL" ]] || die "portfolio installer not found/executable: ${PORTFOLIO_INSTALL}"
[[ -f "$MODULES_YAML" ]] || die "missing ${MODULES_YAML} — the module catalog drives stack selection"

v() { yq "$1" "$VARS" 2>/dev/null || true; }

# ── read inputs (with safe defaults) ──────────────────────────────────────────
USERS="$(v '.users')";           [[ "$USERS" =~ ^[0-9]+$ ]] || USERS=5
# Source repo/revision the portfolio, the in-cluster mirror and the workshop layer all pull from.
# The upstream project is the DEFAULT, not a fact: a fork, an internal GitLab or a customer mirror
# is set here and templated everywhere. `repo_revision` is the documented key; `revision` is still
# honoured so a vars.yaml written before the rename keeps working.
REPO_URL="$(v '.repo_url')";     [[ -n "$REPO_URL" && "$REPO_URL" != "null" ]] || REPO_URL="https://github.com/serhat-dirik/OCP-Getting-Started-Revamped"
REVISION="$(v '.repo_revision')"; [[ -n "$REVISION" && "$REVISION" != "null" ]] || REVISION="$(v '.revision')"
[[ -n "$REVISION" && "$REVISION" != "null" ]] || REVISION="main"
DOMAIN="$(v '.cluster_domain')"
MAAS_KEY="$(v '.maas.api_key')"
MAAS_ENDPOINT="$(v '.maas.endpoint')"
# Model travels WITH the credential (see the secret step below) and is NEVER defaulted to a literal
# name (owner decision 2026-07-25: "we may not know what AI model the installer will bring"). MaaS keys
# are MODEL-SCOPED, so a guessed default that does not match the key is not a cosmetic mismatch — it is
# an HTTP 401 key_model_access_denied the attendee meets inside the AI modules, long after the installer
# said "complete". Empty here means DISCOVER it from the endpoint (discover_maas_model below); a value
# set in vars.yaml is honoured but still validated against what the endpoint actually offers.
MAAS_MODEL="$(v '.maas.model')"; [[ -n "$MAAS_MODEL" && "$MAAS_MODEL" != "null" ]] || MAAS_MODEL=""
WS_PASS="$(v '.workshop_user_password')"
# Console plugins default ON (owner 2026-07-19: mostly console links). Explicit `false` opts out; the
# workshop-config hook stays append-if-absent and skips any name without a matching ConsolePlugin CR.
CONSOLE_PLUGINS="$(v '.console_plugins')"; [[ "$CONSOLE_PLUGINS" == "false" ]] || CONSOLE_PLUGINS="true"

# ── module selection → platform stacks (the deployer interface) ────────────────────────────
# The deployer lists modules_disabled (mNN like m13, or slugs); we install the UNION of stacks the
# ENABLED modules require (modules.yaml `stacks:`), so a stack needed only by disabled modules never
# installs — and therefore never gets an operator-adoption snapshot, so uninstall never touches it.
# The legacy per-stack vars survive as EXPERT ADDITIVE overrides (set one true to force a stack on for
# a PoC with no matching module); to REMOVE a stack, disable its module(s), never flip a var false.
ALL_SLUGS="$(yq -r '.modules[].slug' "$MODULES_YAML" 2>/dev/null || true)"
[[ -n "$ALL_SLUGS" ]] || die "no modules parsed from ${MODULES_YAML}"
MODULE_COUNT="$(printf '%s\n' "$ALL_SLUGS" | grep -c .)"

# Resolve one token (mNN or slug) to a canonical slug: echo the slug + return 0, or return 1 if the
# token is unknown / out of range (the caller turns a 1 into a hard die).
resolve_slug() {
  local tok n slug
  tok="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ -z "$tok" || "$tok" == "null" ]] && return 1
  # Here-strings, not `printf | grep -q`: under `set -o pipefail` a `grep -q`/`-qxF` that matches
  # EARLY can exit before printf finishes writing the rest of $ALL_SLUGS, printf then dies of SIGPIPE,
  # and the pipeline's reported status becomes printf's (141) instead of grep's success — a genuine
  # match reads as a non-match. Reproduced with `bash -c 'set -o pipefail; printf ...| grep -q ...'`
  # on a multi-line producer; ALL_SLUGS is exactly that (one line per module). A `<<<` here-string has
  # no upstream process to kill, so the match can never be lost this way. Same class already fixed in
  # ogsr-check-clean.sh (state_get, ns_has_foreign_csv, csv_matches_adopted) — audited 2026-07-30.
  if grep -qE '^m[0-9]+$' <<< "$tok"; then
    n="${tok#m}"
    # Force base-10: bash arithmetic context treats a leading-zero literal as octal, and "08"/"09"
    # are invalid octal digits — m08/m09 died with "value too great for base" before this guard
    # (reproduced live 2026-07-31). `10#$n` pins the read to decimal regardless of leading zeros.
    (( 10#$n >= 1 )) || return 1                       # m0 (yq index -1 = last) is not a module
    slug="$(yq -r ".modules[$((10#$n - 1))].slug // \"\"" "$MODULES_YAML" 2>/dev/null || true)"
    [[ -n "$slug" && "$slug" != "null" ]] || return 1
    printf '%s' "$slug"; return 0
  fi
  grep -qxF "$tok" <<< "$ALL_SLUGS" || return 1
  printf '%s' "$tok"; return 0
}

# Space-fenced set of disabled slugs (leading + trailing space so membership globs match whole slugs),
# plus a comma-joined CSV for the workshop-config showroom-hiding parameter.
DISABLED_SET=" "
DISABLED_CSV=""
while IFS= read -r tok; do
  # `cond && cmd` written as a statement is the shape that silently skipped five teardown steps on
  # 2026-07-25 (fixed in 8722a79). It is only fatal inside a function called as a bare command, which
  # this is not — these are defensive conversions so the hazard cannot be introduced by a later
  # refactor that moves this code into one.
  if [[ -z "$tok" ]]; then continue; fi
  if ! slug="$(resolve_slug "$tok")"; then
    die "modules_disabled: unknown or out-of-range module '$tok' (use mNN like m13 or a slug from modules.yaml)"
  fi
  case "$DISABLED_SET" in *" $slug "*) continue ;; esac
  DISABLED_SET="${DISABLED_SET}${slug} "
  DISABLED_CSV="${DISABLED_CSV:+$DISABLED_CSV,}${slug}"
done < <(yq -r '.modules_disabled[]?' "$VARS" 2>/dev/null || true)

# Union of stacks required by ENABLED modules (space-fenced set).
REQUIRED_SET=" "
add_required() { case "$REQUIRED_SET" in *" $1 "*) ;; *) REQUIRED_SET="${REQUIRED_SET}$1 " ;; esac; }
while IFS= read -r slug; do
  if [[ -z "$slug" ]]; then continue; fi
  case "$DISABLED_SET" in *" $slug "*) continue ;; esac
  while IFS= read -r st; do
    # Latent, not live — measured, not assumed. Under `set -e` a failing `cond && cmd` only kills the
    # script when it is the last statement of a FUNCTION invoked as a bare command; as a loop body's
    # or top level's last statement bash tolerates it. This code is top-level loop body, so a `null`
    # in a module's `stacks:` list does NOT abort the installer today. Written as `if` anyway: the
    # day someone wraps this block in a function it becomes the exact fault that silently skipped
    # five teardown steps on 2026-07-25, and the shape is not worth keeping for two characters.
    if [[ -n "$st" && "$st" != "null" ]]; then add_required "$st"; fi
  done < <(yq -r ".modules[] | select(.slug == \"$slug\") | .stacks[]?" "$MODULES_YAML" 2>/dev/null || true)
done < <(printf '%s\n' "$ALL_SLUGS")

# Each per-stack toggle = required-by-an-enabled-module OR an explicit expert override (true).
stack_toggle() {  # <stack-name> <vars-key> → true/false
  local name="$1" key="$2" ov
  ov="$(v ".$key")"
  [[ "$ov" == "true" ]] && { echo "true"; return; }
  case "$REQUIRED_SET" in *" $name "*) echo "true" ;; *) echo "false" ;; esac
}
AUTH="$(stack_toggle auth auth)"
RESILIENCE="$(stack_toggle resilience resilience)"
MESH="$(stack_toggle mesh mesh)"
SERVERLESS="$(stack_toggle serverless serverless)"
MTA="$(stack_toggle mta mta)"
OBSERVABILITY="$(stack_toggle observability observability)"
APPSEC="$(stack_toggle appsec appsec)"
PORTAL="$(stack_toggle portal portal)"
TRUST="$(stack_toggle trust trust)"
# trust-demo: expert-override only (RHTPA is a demo-flavor add-on; no module requires it).
TRUST_DEMO="$(v '.trust_demo')"; [[ "$TRUST_DEMO" == "true" ]] || TRUST_DEMO="false"

# Lightspeed (ai-assist stack): governed by the MaaS credential, NOT module filtering. AUTO-SKIP when
# no LLM endpoint/key is configured (owner req) so a cluster with no LLM needs no `lightspeed: false`.
LIGHTSPEED_REQ="$(v '.lightspeed')"
maas_configured="true"
case "$MAAS_KEY" in ""|null|CHANGEME) maas_configured="false" ;; esac
case "$MAAS_ENDPOINT" in ""|null|*"<your-maas-endpoint>"*|*"<unused"*) maas_configured="false" ;; esac
if [[ "$LIGHTSPEED_REQ" == "false" ]]; then
  LIGHTSPEED="false"
elif [[ "$maas_configured" == "false" ]]; then
  LIGHTSPEED="false"
  info "lightspeed auto-skipped: no MaaS endpoint/key in ${VARS} — set maas.endpoint + maas.api_key to enable OpenShift Lightspeed"
else
  LIGHTSPEED="true"
fi

# Ask the OpenAI-compatible endpoint what it actually serves and resolve MAAS_MODEL from the answer.
# We never guess a model name: the per-user MaaS key is scoped to ONE model, so a name the key does not
# cover returns HTTP 401 key_model_access_denied — inside the AI modules, at workshop time, not here.
# The two clusters this workshop has run on had keys scoped to OPPOSITE models (inverted-scope incident
# 2026-07-19), which is exactly the situation a hardcoded default cannot survive.
# The API key travels in an Authorization header only and is never printed, not even on failure.
discover_maas_model() {
  local base url tmp code ids count
  base="${MAAS_ENDPOINT%/}"
  case "$base" in */v1) url="${base}/models" ;; *) url="${base}/v1/models" ;; esac
  info "discovering available models from ${url}"
  tmp="$(mktemp)"
  code="$(curl -sS --max-time 30 -o "$tmp" -w '%{http_code}' \
            -H "Authorization: Bearer ${MAAS_KEY}" -H 'Accept: application/json' \
            "$url" 2>/dev/null || echo 000)"
  # OpenAI list-models contract: {"object":"list","data":[{"id":"…"},…]}
  ids="$(yq -p=json -r '.data[].id' "$tmp" 2>/dev/null | grep -v '^null$' | grep . || true)"
  rm -f "$tmp"

  if [[ -z "$ids" ]]; then
    err "model discovery failed — GET ${url} returned HTTP ${code} with no model list."
    err "   401/403 → maas.api_key is wrong, expired, or not entitled on this endpoint"
    err "   404     → maas.endpoint is not an OpenAI-compatible base (it should end in /v1)"
    err "   000     → endpoint unreachable from this machine (DNS / proxy / TLS)"
    # How hard this fails depends on what the key is FOR on this cluster. If we are installing
    # Lightspeed ourselves the key is a hard dependency of that install, so abort. If Lightspeed was
    # already here (adopted) the key only feeds the AI *modules*: aborting would deny the operator the
    # other 22 modules over an optional beat. Their entry-state hooks now validate the credential
    # themselves and degrade to an explicit aiPathAvailable=false, so a loud warning is the honest
    # stopping point — the failure is visible here AND recorded per module, not silently swallowed.
    if [[ "$LIGHTSPEED" == "true" && "$LIGHTSPEED_PREINSTALLED" == "false" ]]; then
      die "refusing to guess a model name: MaaS keys are model-scoped, so a guess fails inside the AI modules rather than here. Fix maas.endpoint / maas.api_key in ${VARS}, or set 'lightspeed: false' to install without the AI modules."
    fi
    warn "continuing WITHOUT a usable MaaS credential — the AI beats (agentic-ai, ai-assisted-development,"
    warn "   app-modernization, jobs-batch-kueue) will report 'AI path unavailable'; every other module is unaffected."
    warn "   To enable them: fix maas.endpoint / maas.api_key in ${VARS}, re-run this installer, then"
    warn "   ws reset <module> --user <userN> for each AI module."
    MAAS_KEY=""
    return 0
  fi

  count="$(printf '%s\n' "$ids" | grep -c . | tr -d ' ')"
  if [[ -n "$MAAS_MODEL" ]]; then
    # here-string, not `printf | grep -qxF` — see resolve_slug() for why an early match on a
    # multi-line producer can SIGPIPE the producer and read a real match as a non-match under pipefail.
    if grep -qxF "$MAAS_MODEL" <<< "$ids"; then
      ok "maas.model '${MAAS_MODEL}' confirmed — the endpoint offers it (${count} model(s) available)"
    else
      warn "maas.model '${MAAS_MODEL}' is NOT among the ${count} model(s) ${url} offers — using it anyway because you set it explicitly."
      warn "   endpoint offers: $(printf '%s' "$ids" | tr '\n' ' ')"
      warn "   if the AI modules fail with key_model_access_denied, this is why — pick one of the names above in ${VARS}."
    fi
    return 0
  fi

  MAAS_MODEL="$(printf '%s\n' "$ids" | head -1)"
  if [[ "$count" == "1" ]]; then
    ok "model discovered: ${MAAS_MODEL} (the only model this endpoint offers)"
  else
    ok "model discovered: ${MAAS_MODEL} (first of ${count}: $(printf '%s' "$ids" | tr '\n' ' '))"
    info "   set maas.model in ${VARS} to pin a different one if your key is scoped elsewhere"
  fi
}

echo "▶ Workshop bootstrap"
echo "  users     : ${USER_PREFIX}1..${USER_PREFIX}${USERS}"
echo "  modules   : ${MODULE_COUNT} in catalog · disabled: ${DISABLED_CSV:-none}"
echo "  lightspeed: ${LIGHTSPEED}"
echo "  source    : ${REPO_URL} @ ${REVISION}"

# ── preflight: cluster + cluster-admin ────────────────────────────────────────
info "preflight — cluster access"
oc whoami >/dev/null 2>&1 || die "not logged in — run: oc login …"
oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "need cluster-admin (oc auth can-i '*' '*' failed as $(oc whoami))"
ok "logged in as $(oc whoami) @ $(oc whoami --show-server)"

if [[ -z "$DOMAIN" || "$DOMAIN" == "null" ]]; then
  DOMAIN="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -n "$DOMAIN" ]]; then ok "auto-detected cluster domain: ${DOMAIN}"; else err "could not auto-detect cluster domain — content attributes may be blank"; fi
fi

# Lightspeed pre-installed detection + AI model resolution. Both are READ-ONLY and both run HERE, in
# preflight, deliberately: they are the two inputs whose failure would otherwise surface long after the
# install mutated the cluster (a wrong model only fails inside the AI modules). Detection first, so a
# cluster that already runs Lightspeed against its own LLM never blocks on OUR endpoint being reachable.
# Managed/demo clusters (RHDP) often ship Lightspeed pre-wired; fighting that wiring breaks a working
# assistant (duplicate OperatorGroup → OLM ResolutionFailed; secret/OLSConfig clobbering) — reuse it.
LIGHTSPEED_PREINSTALLED="false"
if oc get olsconfig cluster >/dev/null 2>&1; then
  LIGHTSPEED_PREINSTALLED="true"
  PROVIDER="$(oc get olsconfig cluster -o jsonpath='{.spec.llm.providers[0].type}' 2>/dev/null || echo '?')"
  ok "OpenShift Lightspeed pre-installed (provider: ${PROVIDER}) — reusing it; ai-assist stack skipped"
fi
# Discovery runs whenever a MaaS key is CONFIGURED — not only when we install Lightspeed ourselves.
# An adopted Lightspeed says nothing about OUR key: on cluster ksls5 (adopted, Azure-OpenAI-wired) the
# old condition skipped discovery entirely, nothing validated maas.api_key, and the AI modules sourced
# Lightspeed's Azure AD JWT instead — green install, 401 for every attendee (2026-07-29). If the
# operator put a key in vars.yaml they mean the AI modules to work; prove it here, at the gate.
if [[ "$maas_configured" == "true" ]]; then
  discover_maas_model
fi

# Resolve the shared workshop password (generate if asked / unset / still placeholder).
if [[ -z "$WS_PASS" || "$WS_PASS" == "null" || "$WS_PASS" == "generate" || "$WS_PASS" == "CHANGEME" ]]; then
  [[ "$WS_PASS" == "CHANGEME" ]] && err "workshop_user_password is still CHANGEME — generating a random one instead"
  WS_PASS="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
  [[ -n "$WS_PASS" ]] || die "failed to generate a random password"
  info "generated a random shared workshop password (recorded in ${CREDS_FILE})"
fi

# ── [0/6] uninstall-state capture (non-invasive delivery, Wave 1) ─────────────
# Record the PRIOR state of every shared/default object the install is about to touch, into a
# ConfigMap that bootstrap/ogsr-uninstall.sh reads to RESTORE (not blindly delete). Created FIRST,
# before any mutation, in a workshop-owned namespace. Snapshots are first-write-wins so the TRUE
# prior state survives re-runs (idempotent). Verified live 2026-07-26 on OCP 4.22.5: this block captured
# 37 keys, including the ones teardown actually branches on — gitops_preexisted=true,
# lightspeed_preinstalled=true, og_cert-manager-operator=preexisting:<name>, oauth_idp_ownedbyus,
# console_plugins_added, and a per-operator op_<pkg>=created:<ns> provenance row.
OWNER_LABEL="workshop.redhat.com/owner=ogsr"
STATE_NS="ogsr-system"
STATE_CM="ogsr-uninstall-state"

owner_stamp() { oc label --local --overwrite -f - "$OWNER_LABEL" -o yaml; }  # add the owner label to a piped manifest

record_once() {  # key value — write to the state CM only if the key is unset (true first-install snapshot)
  local k="$1" v="$2" cur
  cur="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o jsonpath="{.data['$k']}" 2>/dev/null || true)"
  [[ -n "$cur" ]] && return 0
  oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge -p "{\"data\":{\"$k\":\"$v\"}}" >/dev/null 2>&1 || true
}

# Record the OperatorGroup(s) an ADOPTED operator's namespace ALREADY had, captured before any of our
# Applications exist. Two things depend on it: protect_adopted_resources() annotates them so a cascade
# delete can never take the org's OperatorGroup down with our app, and assert_single_operatorgroup()
# can tell a namespace WE broke apart from one that arrived with two. A healthy OLM namespace has
# exactly one OperatorGroup; with two, OLM fails every CSV in it (TooManyOperatorGroups).
snapshot_operatorgroups() {
  local ns="$1" ogs
  ogs="$(oc get operatorgroups.operators.coreos.com -n "$ns" \
          -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
  ogs="$(echo "$ogs" | xargs || true)"
  [[ -n "$ogs" ]] || return 0
  record_once "og_${ns}" "preexisting:${ogs// /,}"
}

# Components the portfolio's §0 adoption preflight will SKIP because this cluster already runs that
# operator. Set from the portfolio's own --adoption-plan below — never re-derived here, so the
# install and the teardown can never hold two different opinions about who owns an operator.
SKIPPED_COMPONENTS=""
is_skipped_component() { case " ${SKIPPED_COMPONENTS} " in *" $1 "*) return 0 ;; esac; return 1; }

# Operator adoption snapshot: for each operator the SELECTED stacks will install, record whether it
# already exists (adopted → uninstall NEVER removes it) or will be created by us (created → uninstall
# may remove it). Source of truth is the component subscription manifests — no brittle hardcoded map.
snapshot_operators() {
  local stacks_csv="$1" stack app comp_path comp sub name ns _stacks
  IFS=',' read -ra _stacks <<< "$stacks_csv"
  for stack in "${_stacks[@]}"; do
    stack="$(echo "$stack" | xargs)"
    [[ -d "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps" ]] || continue
    for app in "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps"/*.yaml; do
      [[ -e "$app" ]] || continue
      comp_path="$(yq '.spec.source.path' "$app" 2>/dev/null || true)"
      [[ -n "$comp_path" && "$comp_path" != "null" ]] || continue
      comp="$(basename "$comp_path")"
      for sub in "${SCRIPT_DIR}/../${comp_path}"/subscription*.yaml; do
        [[ -e "$sub" ]] || continue
        name="$(yq '.metadata.name' "$sub" 2>/dev/null || true)"
        ns="$(yq '.metadata.namespace' "$sub" 2>/dev/null || true)"
        [[ -n "$name" && "$name" != "null" ]] || continue
        # A SKIPPED component is never ours, whatever the org happened to call their Subscription.
        # Recording it `created:` because no object of OUR name exists would be catastrophic at
        # teardown: classify_workshop_namespaces() reads created → "installed-stack operator
        # namespace (created by us)" → it DELETES the namespace the org's operator lives in.
        if is_skipped_component "$comp"; then
          record_once "op_${name}" "adopted:${ns}"
          snapshot_operatorgroups "$ns"
        elif oc get subscriptions.operators.coreos.com "$name" -n "$ns" >/dev/null 2>&1; then
          record_once "op_${name}" "adopted:${ns}"
          snapshot_operatorgroups "$ns"
        else
          record_once "op_${name}" "created:${ns}"
        fi
      done
    done
  done
  # gitea-operator comes from an external rhpds OLMDeploy kustomize base (fetched at build time), so
  # the subscription*.yaml glob above can never find it — record it explicitly, gated on core-devtools
  # (the stack carrying the gitea component). Same treatment ogsr-uninstall.sh's enumerate_operators()
  # and helm/bootstrap's job-state-capture give it (c50067d / cf79b0d).
  if [[ ",${stacks_csv}," == *",core-devtools,"* ]]; then
    if oc get subscriptions.operators.coreos.com gitea-operator -n gitea-operator >/dev/null 2>&1; then
      record_once "op_gitea-operator" "adopted:gitea-operator"
      snapshot_operatorgroups gitea-operator
    else
      record_once "op_gitea-operator" "created:gitea-operator"
    fi
  fi
}

# ── adopted-resource protection ───────────────────────────────────────────────
# Uninstall CASCADE-deletes our Argo Applications, so Argo prunes what it installed in dependency
# order. That only stays safe if every ADOPTED resource is individually exempt — protection has to be a
# property of the resource, not a blanket amnesty over the whole teardown (the old --cascade=orphan
# also discarded Argo's ordering, which is what forced an incomplete bash re-implementation and wedged
# 8 namespaces on 2026-07-25). Argo honours both keys in one annotation:
#     argocd.argoproj.io/sync-options: Prune=false,Delete=false
#
# merge_sync_options is a PURE string function (no cluster), which is called out here because it makes
# the function a natural offline-unit-test candidate — no such test exists in tools/verify/ today (a
# prior version of this comment pointed at tools/verify/adopted-protection-selftest.sh, a file that was
# never written; found stale 2026-07-31). The live equivalent that DOES exist and run today is
# ogsr-uninstall.sh's own protection guard (check_adopted / PROT_BAD), which verifies every adopted
# resource against the actual cluster — see its --dry-run output. It preserves any sync options the org
# already set — clobbering their annotation would itself be a mutation of a resource we do not own — and
# re-asserts our two keys authoritatively, because protection must win over a stale Prune=true.
merge_sync_options() {  # <current-annotation-value> → merged value (order-preserving, no duplicates)
  local cur="${1:-}" out="" opt
  local IFS=','
  for opt in $cur; do
    opt="$(echo "$opt" | xargs)"
    [[ -n "$opt" ]] || continue
    case "$opt" in Prune=*|Delete=*) continue ;; esac
    out="${out:+$out,}$opt"
  done
  printf '%s' "${out:+$out,}Prune=false,Delete=false"
}

PROTECTED_COUNT=0
PROTECTED_LIST=""
PROTECT_MISSING=0

oc_scoped() {  # <ns> <oc-args…> — append -n <ns> only when ns is non-empty
  local ns="$1"; shift
  if [[ -n "$ns" ]]; then oc "$@" -n "$ns"; else oc "$@"; fi
}

state_get() {  # <key> — echo a value recorded in the state ConfigMap ("" when unset)
  oc get configmap "$STATE_CM" -n "$STATE_NS" -o jsonpath="{.data.$1}" 2>/dev/null || true
}

protect_one() {  # <kind> <name> [<ns>] — merge our protection into one adopted resource
  # An EMPTY <ns> means cluster-scoped (Namespace, GatewayClass). `oc get namespace foo -n ""` is not
  # the same call as `oc get namespace foo`, so the scope has to branch rather than pass an empty -n.
  local kind="$1" name="$2" ns="${3:-}" cur merged where
  where="${ns:+ in $ns}"; where="${where:- (cluster-scoped)}"
  if ! oc_scoped "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    # A recorded resource that no longer exists is a stale snapshot, not an install failure: warn and
    # keep going. Failing here would block a re-install on a cluster the admin has since tidied up.
    PROTECT_MISSING=$((PROTECT_MISSING + 1))
    warn "adopted ${kind}/${name} recorded in ${STATE_CM} no longer exists${where} — skipped"
    return 0
  fi
  cur="$(oc_scoped "$ns" get "$kind" "$name" \
          -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}' 2>/dev/null || true)"
  merged="$(merge_sync_options "$cur")"
  PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
  if [[ "$cur" == "$merged" ]]; then                       # idempotent: re-running install is a no-op
    PROTECTED_LIST="${PROTECTED_LIST}${PROTECTED_LIST:+$'\n'}   • ${kind%%.*}/${name}${where} (already ${merged})"
    return 0
  fi
  if ! oc_scoped "$ns" annotate "$kind" "$name" \
        "argocd.argoproj.io/sync-options=${merged}" --overwrite >/dev/null 2>&1; then
    PROTECTED_COUNT=$((PROTECTED_COUNT - 1))
    warn "could NOT annotate ${kind}/${name}${where} — a cascade delete could remove an adopted resource. Check RBAC, then re-run."
    return 0
  fi
  PROTECTED_LIST="${PROTECTED_LIST}${PROTECTED_LIST:+$'\n'}   • ${kind%%.*}/${name}${where} → ${merged}"
}

protect_adopted_resources() {
  local cm lines name ns csv og
  cm="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o json 2>/dev/null || true)"
  [[ -n "$cm" ]] || return 0
  lines="$(printf '%s' "$cm" | yq -p=json -r \
    '.data // {} | to_entries | .[] | select(.key | test("^op_")) | select(.value | test("^adopted:"))
     | (.key | sub("^op_";"")) + " " + (.value | sub("^adopted:";""))' 2>/dev/null || true)"
  if [[ -z "$lines" ]]; then
    ok "adopted-resource protection: no pre-existing operators on this cluster — nothing to protect"
    return 0
  fi
  while read -r name ns; do
    [[ -n "$name" && -n "$ns" ]] || continue
    # ALWAYS fully-qualified. The bare name `subscription` is ambiguous — Knative's
    # subscriptions.messaging.knative.dev shadows OLM's — and that ambiguity was a SEV1 here (64eb8da).
    protect_one subscriptions.operators.coreos.com "$name" "$ns"
    csv="$(oc get subscriptions.operators.coreos.com "$name" -n "$ns" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    [[ -n "$csv" ]] && protect_one clusterserviceversions.operators.coreos.com "$csv" "$ns"
    # The OperatorGroup in an adopted operator's namespace is the org's too. Pruning it would strand
    # their CSV with no group to scope it — the same class of silent breakage as adding a second one.
    while IFS= read -r og; do
      [[ -n "$og" ]] || continue
      protect_one operatorgroups.operators.coreos.com "$og" "$ns"
    done < <(oc get operatorgroups.operators.coreos.com -n "$ns" \
              -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    # The operator's NAMESPACE — the single largest residual risk in the cascade design. Our components
    # declare these namespaces (platform-portfolio/components/<c>/namespace.yaml), so Argo ADOPTS a
    # pre-existing one, and deleting a namespace destroys everything inside it regardless of what those
    # contents are annotated with. Prune=false on the Subscription alone does NOT save an adopted
    # operator whose namespace goes. ogsr-uninstall.sh's cascade guard requires this and refuses without it.
    protect_one namespace "$ns" ""
  done <<< "$lines"

  # Two cluster-scoped objects a cascade would prune that no op_* key covers — neither is an operator,
  # so the adoption snapshot never sees them, but both may belong to the org.
  #   • GatewayClass/openshift-default — our gateway-api component declares it, so Argo adopts an
  #     existing one; pruning it tears down the org's Gateway API data plane.
  #   • cluster-monitoring-config — synced ServerSideApply precisely BECAUSE it may pre-exist. A cascade
  #     deletes the whole ConfigMap (retention, alertmanager, remote-write and all), which would make
  #     the uninstall's careful key-level restore of enableUserWorkload moot.
  if [[ "$(state_get gatewayclass_preexisted)" == "true" ]]; then
    protect_one gatewayclasses.gateway.networking.k8s.io openshift-default ""
  fi
  if [[ "$(state_get monitoring_cm_existed)" == "true" ]]; then
    protect_one configmap cluster-monitoring-config openshift-monitoring
  fi

  if [[ "$PROTECTED_COUNT" -eq 0 ]]; then
    warn "adopted-resource protection: ${PROTECT_MISSING} recorded resource(s) missing, 0 protected — a cascade uninstall has nothing to skip"
  else
    ok "adopted-resource protection: ${PROTECTED_COUNT} resource(s) carry Prune=false,Delete=false"
    printf '%s\n' "$PROTECTED_LIST"
    [[ "$PROTECT_MISSING" -gt 0 ]] && info "   (${PROTECT_MISSING} recorded resource(s) no longer exist — skipped, install continues)"
  fi
  return 0
}

# ── OperatorGroup uniqueness gate ─────────────────────────────────────────────
# OLM fails EVERY CSV in a namespace holding more than one OperatorGroup (phase Failed, reason
# TooManyOperatorGroups) and it does so silently: the operator's Deployments keep running, so nothing
# looks broken while reconciliation — upgrades, self-healing — has stopped. Found live 2026-07-25 on a
# cluster with an org-owned cert-manager: our component applied its own OperatorGroup into the ADOPTED
# cert-manager-operator namespace and OLM failed the org's CSV one second later. That is a silent and
# unreversible degradation of somebody else's operator, so this is a hard install failure, not a note.
OG_BASELINE=""   # "<ns> <count>" per namespace, captured BEFORE any of our Applications exist

operatorgroup_counts() {  # → "<ns> <count>" for every namespace holding at least one OperatorGroup
  oc get operatorgroups.operators.coreos.com -A --no-headers 2>/dev/null \
    | awk '{print $1}' | sort | uniq -c | awk '{print $2" "$1}'
}

owning_stack_of_app() {  # <child-app-name> → the stack whose app-of-apps ships it (for the fix hint)
  local app="$1" f
  for f in "${SCRIPT_DIR}/../platform-portfolio/stacks"/*/apps/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(yq -r '.metadata.name // ""' "$f" 2>/dev/null)" == "$app" ]] || continue
    basename "$(dirname "$(dirname "$f")")"; return 0
  done
  echo "<unknown>"
}

assert_single_operatorgroup() {
  local ns count before ours theirs og app stack bad=0
  while read -r ns count; do
    [[ -n "$ns" ]] || continue
    [[ "$count" -gt 1 ]] || continue
    before="$(printf '%s\n' "$OG_BASELINE" | awk -v n="$ns" '$1 == n {print $2}')"
    ours="$(oc get operatorgroups.operators.coreos.com -n "$ns" -l "$OWNER_LABEL" \
             -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null | xargs || true)"
    if [[ -z "$ours" ]]; then
      warn "namespace ${ns} holds ${count} OperatorGroups and none of them is ours (it had ${before:-?} before this install) — pre-existing, left alone"
      continue
    fi
    bad=1
    theirs=""
    while IFS= read -r og; do
      [[ -n "$og" ]] || continue
      case " $ours " in *" $og "*) continue ;; esac      # skip the ones carrying our owner label
      theirs="${theirs:+$theirs }$og"
    done < <(oc get operatorgroups.operators.coreos.com -n "$ns" -o name 2>/dev/null | sed 's|.*/||')
    app="$(oc get operatorgroups.operators.coreos.com "${ours%% *}" -n "$ns" \
            -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null \
            | cut -d: -f1 || true)"
    stack="$(owning_stack_of_app "${app:-none}")"
    err "namespace ${ns}: ${count} OperatorGroups — ours (${ours}) was added next to the org's (${theirs:-?})"
    oc get csv -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.reason}{"\n"}{end}' 2>/dev/null \
      | grep -i 'TooManyOperatorGroups' | while IFS= read -r line; do echo "      OLM: csv ${line}" >&2; done
    echo "      undo (stop the app re-creating it, then remove OURS — never theirs):" >&2
    echo "        oc -n openshift-gitops patch application pp-${stack} --type merge -p '{\"spec\":{\"syncPolicy\":null}}'" >&2
    echo "        oc -n openshift-gitops delete application ${app:-<child-app>} --cascade=orphan" >&2
    echo "        oc -n ${ns} delete operatorgroup ${ours}" >&2
  done < <(operatorgroup_counts)
  [[ "$bad" -eq 0 ]] && { ok "OperatorGroup uniqueness: every namespace holds at most one"; return 0; }
  err "An adopted operator has been degraded: OLM stops reconciling every CSV in a namespace with two"
  err "OperatorGroups, while its pods keep running — so this never surfaces until the org upgrades."
  return 1
}

# Post-install check for the exact failure diagnosed 2026-07-30: the batch-pool taint (if applied above)
# starving an unrelated pod's scheduling.
#
# ATTRIBUTION IS THE HARD PART, and the scheduler will not do it for us. Measured on OCP 4.22
# (2026-07-31, single-node CRC): the FailedScheduling message names the COUNT of tainted nodes but never
# the taint KEY —
#     "0/1 nodes are available: 1 node(s) had untolerated taint(s). no new claims to deallocate, ..."
# and on the 5-node RHDP cluster the same day, "0/5 nodes are available: 1 Insufficient memory,
# 1 node(s) had untolerated taint(s), 3 Insufficient cpu". So a grep for "untolerated taint" alone
# CANNOT tell our taint apart from node.kubernetes.io/disk-pressure, /not-ready, or anything else —
# and the CRC node carries exactly such a disk-pressure taint, which would have made this gate blame
# our taint and fail an install for something that is not ours.
#
# So we decide attribution from the NODE, not the message: if our taint is the only NoSchedule/NoExecute
# taint on the batch node, "untolerated taint" can only mean ours and we hard-fail. If the node carries
# other blocking taints too, the pod is stuck whether or not our taint exists — we report it in full and
# name the competing taints, but we do NOT fail the install for it.
#
# Pods that DO tolerate our key are out of scope: they are meant to be eligible for the batch node, so a
# crunch there is a capacity question, not a defect of this taint. Must report what it inspected even
# when the scope is empty (zero Pending pods is a real, reportable outcome, not a silent pass).
assert_no_batch_taint_pending() {
  if [[ "${BATCH_TAINTED:-false}" != "true" ]]; then
    info "batch-taint Pending-pod check: skipped — no taint was applied this run (pool was below the ${MIN_BATCH_POOL_FOR_TAINT}-worker floor, or shaping found no node)"
    return 0
  fi
  # Other NoSchedule/NoExecute taints on the batch node — the competing explanations for the message.
  local other_taints="" _tkey _teffect
  while IFS='=' read -r _tkey _teffect; do
    [[ -n "$_tkey" ]] || continue
    [[ "$_tkey" != "$POOL_LABEL_KEY" ]] || continue
    [[ "$_teffect" == "NoSchedule" || "$_teffect" == "NoExecute" ]] || continue
    other_taints+="${_tkey}:${_teffect} "
  done < <(oc get node "$BATCH_NODE" -o jsonpath='{range .spec.taints[*]}{.key}{"="}{.effect}{"\n"}{end}' 2>/dev/null)

  local total=0 flagged=0 ambiguous=0 ns pod evt
  while read -r ns pod; do
    [[ -n "$pod" ]] || continue
    total=$((total + 1))
    if oc get pod "$pod" -n "$ns" -o jsonpath='{.spec.tolerations[*].key}' 2>/dev/null | grep -q "$POOL_LABEL_KEY"; then
      continue   # this pod opted in to the batch node; not this check's concern
    fi
    evt="$(oc get events -n "$ns" --field-selector "involvedObject.name=${pod},reason=FailedScheduling" \
            -o jsonpath='{.items[-1:].message}' 2>/dev/null || true)"
    grep -qi 'untolerated taint' <<<"$evt" || continue
    if [[ -n "$other_taints" ]]; then
      ambiguous=$((ambiguous + 1))
      warn "  ${ns}/${pod} is Pending citing an untolerated taint, but ${BATCH_NODE} also carries ${other_taints}— not attributable to ${POOL_LABEL_KEY}: ${evt}"
    else
      flagged=$((flagged + 1))
      err "  ${ns}/${pod} is Pending and ${POOL_LABEL_KEY} is the ONLY blocking taint on ${BATCH_NODE} (pod does not tolerate it): ${evt}"
    fi
  done < <(oc get pods -A --field-selector=status.phase=Pending \
             -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  if [[ "$total" -eq 0 ]]; then
    ok "batch-taint Pending-pod check: inspected 0 Pending pods cluster-wide — nothing to flag"
    return 0
  fi
  if [[ "$flagged" -eq 0 ]]; then
    # NB: not "${ambiguous:+...}" — ambiguous holds a NUMBER, and the string "0" is non-empty, so :+
    # would expand on a clean run and report "(0 cited a taint...)". Test the value, not the emptiness.
    local amb_note=""
    [[ "$ambiguous" -gt 0 ]] && amb_note=" (${ambiguous} cited a taint, but ${BATCH_NODE} carries other blocking taints — see warnings above)"
    ok "batch-taint Pending-pod check: inspected ${total} Pending pod(s) cluster-wide, none blocked by the ${POOL_LABEL_KEY} taint on ${BATCH_NODE}${amb_note}"
    return 0
  fi
  err "batch-taint Pending-pod check: ${flagged}/${total} Pending pod(s) inspected are blocked by the ${POOL_LABEL_KEY} taint this install added to ${BATCH_NODE}"
  err "  this is the exact failure mode diagnosed 2026-07-30 (RHACS central-db Pending behind this same taint on a 2-worker cluster, Central crashlooping, ACS scans failing) — free capacity on the other worker(s), or reduce load until the ${MIN_BATCH_POOL_FOR_TAINT}-worker floor would skip the taint on a re-install"
  return 1
}

info "[0/6] capturing uninstall-state (prior cluster state for a non-destructive uninstall)"
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${STATE_NS}
  labels:
    workshop.redhat.com/owner: ogsr
EOF
oc get configmap "$STATE_CM" -n "$STATE_NS" >/dev/null 2>&1 \
  || oc create configmap "$STATE_CM" -n "$STATE_NS" --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null

# cluster-monitoring-config: the portfolio flips enableUserWorkload=true — remember its prior value.
if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
  record_once monitoring_cm_existed true
  UWM_NOW="$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
  # here-string, not `echo | grep -q` — same SIGPIPE-under-pipefail trap as resolve_slug(): this
  # ConfigMap's config.yaml can be multi-line, and a mid-file match could otherwise read as absent,
  # which would misrecord the prior monitoring state ogsr-uninstall.sh restores from.
  if grep -qE 'enableUserWorkload:[[:space:]]*true' <<< "$UWM_NOW"; then
    record_once monitoring_uwm_prior true
  elif grep -qE 'enableUserWorkload:[[:space:]]*false' <<< "$UWM_NOW"; then
    record_once monitoring_uwm_prior false
  else
    record_once monitoring_uwm_prior absent
  fi
else
  record_once monitoring_cm_existed false
  record_once monitoring_uwm_prior absent
fi

# GitOps operator: adopted (pre-existing) or created by us? Recorded first-write-wins, so a RE-install
# still knows we were the original installer.
#
# The controller.resources snapshot is the RESTORE SOURCE, not just evidence: on an ADOPTED instance
# the portfolio's argocd-bootstrap asks the admin for consent to raise the controller memory, and if
# they say yes it records argocd_controller_resources_changed_by_us=true alongside this same key.
# ogsr-uninstall.sh's restore_argocd_controller_resources() reads BOTH and puts the CR back — writing
# the recorded block back, or REMOVING .spec.controller.resources when this key is absent (absence is
# how "the CR carried no explicit resources" is encoded; that is why the write below is skipped when
# ARGO_RES_PRIOR is empty, and why nothing may start writing an empty value here).
# One key for the prior value, one for the consent, one restore path — see that function's header.
if oc get subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator >/dev/null 2>&1; then
  record_once gitops_preexisted true
  ARGO_RES_PRIOR="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.controller.resources}' 2>/dev/null | base64 | tr -d '\n' || true)"
  # `if`, not `cond && cmd`: measured harmless here (top level, so `set -e` does not fire), but this
  # is the line the empty-means-absent contract rests on and it must survive being wrapped in a
  # function by a later refactor.
  if [[ -n "$ARGO_RES_PRIOR" ]]; then
    record_once gitops_argocd_controller_resources_b64 "$ARGO_RES_PRIOR"
  fi
else
  record_once gitops_preexisted false
fi
# The portfolio bootstrap raises the Argo controller memory; it must do that ONLY on an instance we
# installed. Pass the RECORDED verdict (not a fresh live check): on a re-install the subscription
# always exists, and only the first-write-wins snapshot still knows who created it.
GITOPS_PREEXISTED="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o jsonpath='{.data.gitops_preexisted}' 2>/dev/null || true)"
export GITOPS_PREEXISTED="${GITOPS_PREEXISTED:-false}"

# Gateway API: did the openshift-default GatewayClass already exist (activates a cluster istiod)?
if oc get gatewayclass openshift-default >/dev/null 2>&1; then
  record_once gatewayclass_preexisted true
else
  record_once gatewayclass_preexisted false
fi

# ── workshop node substrate (M16 scheduling / M21 resilience) ─────────────────
# Cluster-scoped, one-time, idempotent node shaping the per-user entry charts must NOT own (ADR-0001
# Rule 13 — entry charts never own cluster policy). Two pieces, both workshop-specific substrate:
#   • a dedicated BATCH POOL: one worker labeled+tainted workshop.redhat.com/pool=batch so M16's
#     toleration+nodeSelector beat is real (a toleration only PERMITS the tainted node; the nodeSelector
#     ATTRACTS the pod — you need both). NoSchedule evicts nothing; it only blocks NEW untolerated pods.
#   • synthetic FAILURE-DOMAIN labels workshop.redhat.com/zone={a,b,c} for M16's optional zone-spread
#     narrative and M21's chaos drill. Deliberately workshop-namespaced — NOT the well-known
#     topology.kubernetes.io/zone, which volume/scheduler controllers would treat as a real cloud AZ on
#     this single-AZ bare-metal cluster. Inert metadata: nothing keys on it unless a workload's
#     topologySpreadConstraints opts in.
# Idempotent: --overwrite makes a re-run a no-op. This is bootstrap (not the portfolio) because node
# objects can't be cleanly GitOps-reconciled and this is workshop substrate, not an operator install.
info "shaping workshop node substrate (M16 batch pool + M16/M21 synthetic zones)"
POOL_LABEL="workshop.redhat.com/pool=batch"
POOL_LABEL_KEY="${POOL_LABEL%%=*}"
ZONE_KEY="workshop.redhat.com/zone"
# Pick a real worker (worker role, NOT also control-plane) as the batch pool node; deterministic (first
# by name). Fall back to any node if a cluster has no pure-worker split (so the beat always has a target).
# This same pool is also the capacity floor below: it is exactly the set of nodes that would lose one
# member to the taint, so its size is what decides whether tainting is affordable.
BATCH_POOL_RAW="$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
[[ -n "$(echo "$BATCH_POOL_RAW" | xargs || true)" ]] || BATCH_POOL_RAW="$(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
read -ra BATCH_POOL_NODES <<<"$BATCH_POOL_RAW"
BATCH_POOL_COUNT=${#BATCH_POOL_NODES[@]}
# Guard the expansion on the count: under `set -u`, "${arr[@]}" on an EMPTY array is an "unbound
# variable" fatal on bash < 4.4 — and macOS still ships 3.2, which is what `env bash` resolves to on a
# stock admin laptop (measured 2026-07-31). Without this guard an unreachable cluster (oc fails, both
# node queries return empty) kills the installer with a cryptic `BATCH_POOL_NODES[@]: unbound variable`
# instead of reaching the `err "no nodes found..."` branch below that exists to explain exactly that.
BATCH_NODE=""
if [[ "$BATCH_POOL_COUNT" -gt 0 ]]; then
  BATCH_NODE="$(printf '%s\n' "${BATCH_POOL_NODES[@]}" | sort | head -1)"
fi
# Taint floor. Diagnosed live on a 2-worker cluster (2026-07-30): tainting one of two workers left the
# survivor at 99% memory requests, RHACS central-db (8Gi + 4 CPU) Pending for 3h+, Central crashlooping
# on a DB that never came up, and the trusted-supply-chain module's scan gate dead — with the install
# reporting every Argo app Healthy throughout. 3 is the smallest pool that can give up a worker and still
# leave TWO general-purpose schedulable workers standing (2 workers, taint one → 1 left, the catastrophic
# case above; 3 workers, taint one → 2 left, real spare capacity remains). Below the floor we still LABEL
# the node — a label alone never removes scheduling capacity, so the nodeSelector half of the lesson is
# free — but we withhold the taint.
MIN_BATCH_POOL_FOR_TAINT=3
BATCH_TAINTED=false
if [[ -n "$BATCH_NODE" ]]; then
  oc label node "$BATCH_NODE" "$POOL_LABEL" --overwrite >/dev/null
  if [[ "$BATCH_POOL_COUNT" -ge "$MIN_BATCH_POOL_FOR_TAINT" ]]; then
    oc adm taint nodes "$BATCH_NODE" "${POOL_LABEL}:NoSchedule" --overwrite >/dev/null
    BATCH_TAINTED=true
    ok "batch pool: worker ${BATCH_NODE} labeled+tainted ${POOL_LABEL}:NoSchedule (${BATCH_POOL_COUNT} workers in pool, floor is ${MIN_BATCH_POOL_FOR_TAINT})"
  else
    # Idempotent re-run safety: if an EARLIER install tainted this node while the pool was still at/above
    # the floor, and the cluster has since shrunk below it, clear the stale taint instead of leaving a
    # silent landmine — the whole point of the floor is that a too-small pool must never carry this taint.
    oc adm taint nodes "$BATCH_NODE" "${POOL_LABEL}:NoSchedule-" >/dev/null 2>&1 || true
    warn "batch pool taint SKIPPED: only ${BATCH_POOL_COUNT} worker(s) available (need ${MIN_BATCH_POOL_FOR_TAINT}+ to spare one without starving the rest of the cluster — see 2026-07-30 incident: 2 workers, 1 tainted, RHACS central-db Pending 3h+, trusted-supply-chain's scan gate dead)"
    warn "  worker ${BATCH_NODE} is labeled ${POOL_LABEL} but left fully schedulable — no taint was applied"
    warn "  consequence for M16: the nodeSelector half of the batch-pool beat still works (pods requesting the label land on ${BATCH_NODE}); the TOLERATION half degrades to label-only — there is no tainted node left on this cluster to demonstrate 'an untolerated pod is refused, a tolerating pod is admitted' against"
  fi
else
  err "no nodes found to shape a batch pool — M16's dedicated-pool beat will have no target"
fi
# Synthesize zones a/b/c round-robin across all nodes (idempotent --overwrite).
read -ra SHAPE_NODES <<<"$(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
ZONES=(a b c)
zi=0
# Same empty-array/`set -u` guard as BATCH_POOL_NODES above — on bash 3.2 an unreachable cluster would
# die here on "SHAPE_NODES[@]: unbound variable" rather than reporting "0 node(s)".
for n in ${SHAPE_NODES[@]+"${SHAPE_NODES[@]}"}; do
  oc label node "$n" "${ZONE_KEY}=${ZONES[zi % 3]}" --overwrite >/dev/null
  zi=$((zi + 1))
done
ok "synthetic ${ZONE_KEY} labels applied across ${#SHAPE_NODES[@]} node(s) (a/b/c round-robin)"
# Record the node mutations for the uninstall report. (Uninstall reverses by label selector, so this
# is documentation — it removes pool/zone labels + the batch taint from ANY node still carrying them.)
record_once nodes_batch "${BATCH_NODE:-}"
record_once nodes_batch_tainted "${BATCH_TAINTED}"
record_once nodes_zoned "${SHAPE_NODES[*]:-}"

# ── 1. portfolio stacks ───────────────────────────────────────────────────────
# LIGHTSPEED_PREINSTALLED was resolved in preflight (above) so a wrong MaaS model fails before we
# mutate anything; the stack decision below just consumes it.
# batch stack (Kueue + KEDA) is a HARD baseline dependency, NOT optional: the workshop-config
# layer below unconditionally ships per-user Kueue queues (kueue-queues + per-user-batch). Omit
# batch and workshop-config's sync dies on missing kueue.x-k8s.io CRDs — which also aborts the
# in-app Gitea/Argo seed hooks riding the same Application, blocking the whole workshop. M06 also
# teaches Kueue. Verified: a clean bootstrap without it broke cluster-km7vw's seed (2026-07-12).
# progressive-delivery (Argo Rollouts via RolloutManager) is BASELINE, not opt-in: M11
# gitops-at-scale is core catalog (flagship Day-2 path) and its canary/rollback exercises are
# dead without the controller. The Rollouts CRDs ship with GitOps, which HID the gap — the CR
# applies cleanly and then nothing reconciles it (QA gate, 2026-07-18: greenfield installs
# shipped a dead M11 on both install paths).
STACKS="core-devtools,batch,progressive-delivery"
[[ "$LIGHTSPEED" == "true" && "$LIGHTSPEED_PREINSTALLED" == "false" ]] && STACKS="${STACKS},ai-assist"
# auth stack (Red Hat build of Keycloak) for M13. Workshop-agnostic; per-user realms are seeded by the
# workshop layer below (sso.enabled). Its own OwnNamespace operator never touches a cluster login IdP.
[[ "$AUTH" == "true" ]] && STACKS="${STACKS},auth"
# resilience stack (OADP/Velero + in-cluster NooBaa S3) for M21. Opt-in; PREREQ ODF/MCG for the S3 target.
# The RHSI (Skupper v2) add-on stays commented out in the stack unless the catalog offers channel stable-2.
[[ "$RESILIENCE" == "true" ]] && STACKS="${STACKS},resilience"
# Elective stacks for the D-block / DevSecOps modules. Each is a plain portfolio stack; prereqs
# (if any) are documented in the stack's own kustomization. Without these, the matching modules
# are simply absent from the cluster (module independence holds — nothing else breaks).
[[ "$MESH" == "true" ]] && STACKS="${STACKS},mesh"
[[ "$SERVERLESS" == "true" ]] && STACKS="${STACKS},serverless"
[[ "$MTA" == "true" ]] && STACKS="${STACKS},mta"
[[ "$OBSERVABILITY" == "true" ]] && STACKS="${STACKS},observability"
[[ "$APPSEC" == "true" ]] && STACKS="${STACKS},appsec"
[[ "$PORTAL" == "true" ]] && STACKS="${STACKS},portal"
[[ "$TRUST" == "true" ]] && STACKS="${STACKS},trust"
[[ "$TRUST_DEMO" == "true" ]] && STACKS="${STACKS},trust-demo"
# ── component adoption plan (read-only) ───────────────────────────────────────
# Ask the portfolio installer — which OWNS the detection — which components it will skip because
# this cluster already runs that operator, and which it cannot make safe at all. One detector, two
# callers: it decides, we record. Everything downstream (protection, teardown classification) keys
# off the adopted/created records this produces, so a skipped component's operator AND its namespace
# are preserved even when the org named their Subscription something else entirely.
info "[0/6] asking the portfolio which components this cluster already provides"
ADOPTION_PLAN="$("$PORTFOLIO_INSTALL" --stacks "$STACKS" --adoption-plan)" \
  || die "component adoption preflight failed — re-run by hand: ${PORTFOLIO_INSTALL} --stacks ${STACKS} --adoption-plan"

# Refusals first: fail HERE, before the state ConfigMap grows records and before we annotate a single
# resource of the org's. The portfolio prints the full explanation and the options.
# here-string, never `printf | grep -q`: ADOPTION_PLAN is one line per component across every
# selected stack, so a '^refuse' match that is not the LAST line can SIGPIPE the printf mid-write —
# under pipefail the pipeline then reports printf's death (141), not grep's match, and this gate
# would silently read a genuine refusal as "clean", letting the install proceed against a component
# it explicitly cannot make safe. Confirmed with `bash -c 'set -o pipefail; printf ... | grep -q ...'`
# on a multi-line producer (see resolve_slug() above for the same class, first found 2026-07-30).
if grep -q '^refuse' <<< "$ADOPTION_PLAN"; then
  err "this cluster already runs component(s) the portfolio cannot safely skip:"
  printf '%s\n' "$ADOPTION_PLAN" \
    | awk -F'\t' '$1 == "refuse" { printf "      • %s (stack %s): %s\n", $3, $2, $7 }'
  err "those components ship operand CRs as well as the operator, so dropping them would leave the"
  err "workshop quietly incomplete. Full explanation and the two ways forward:"
  die "  ${PORTFOLIO_INSTALL} --stacks ${STACKS}"
fi

while IFS=$'\t' read -r _verb _stack _comp _child _ns _subs _reason; do
  [[ "$_verb" == "skip" ]] || continue
  : "$_stack" "$_child"
  SKIPPED_COMPONENTS="${SKIPPED_COMPONENTS} ${_comp}"
  record_once "skipped_${_comp}" "adopted:${_ns}"
  ok "adopting this cluster's ${_comp} — ours will not be installed (${_reason})"
  # The org's OWN Subscription objects, under THEIR names. Recorded adopted so
  # protect_adopted_resources() annotates them (and their CSVs, OperatorGroups and namespace)
  # Prune=false,Delete=false, and so ogsr-uninstall.sh preserves rather than removes them.
  [[ -n "$_subs" && "$_subs" != "-" ]] || continue
  IFS=',' read -ra _sub_pairs <<< "$_subs"
  for _pair in "${_sub_pairs[@]}"; do
    [[ -n "$_pair" ]] || continue
    record_once "op_${_pair%@*}" "adopted:${_pair#*@}"
    snapshot_operatorgroups "${_pair#*@}"
  done
done <<< "$ADOPTION_PLAN"

# Snapshot operator adoption BEFORE Argo installs anything (created vs adopted → safe uninstall).
record_once lightspeed_preinstalled "$LIGHTSPEED_PREINSTALLED"
record_once installed_stacks "$STACKS"
if [[ -n "$(echo "${SKIPPED_COMPONENTS}" | xargs || true)" ]]; then
  record_once skipped_components "$(echo "${SKIPPED_COMPONENTS}" | xargs)"
fi
snapshot_operators "$STACKS"
# Baseline of OperatorGroups-per-namespace, taken while the cluster is still exactly as we found it, so
# the post-install gate can tell a namespace WE gave a second OperatorGroup from one that already had
# two. Must be read before the portfolio Applications exist.
OG_BASELINE="$(operatorgroup_counts || true)"
# Protection runs HERE — after the snapshot, before a single Application exists — so an adopted
# resource is never managed-but-unprotected, not even for a sync cycle.
protect_adopted_resources
info "[1/6] installing portfolio stacks: ${STACKS}"
# The workshop layer rides the portfolio's AppProject (ogsr-platform) rather than the built-in
# `default`, so nothing of ours shares a project with the organisation's own Applications and
# teardown gets one handle on the lot. The portfolio project is workshop-agnostic by design, so the
# two namespace families only the WORKSHOP deploys into are declared here, from this side:
#   user* — per-user namespaces (userN-dev, userN-cicd, …) that workshop-config materializes
#   openshift — the shared ImageStream namespace the Java 21 stream lands in
# Both are unioned into the live project by the portfolio installer, so re-running either layer in
# any order never revokes the other's destinations.
PORTFOLIO_DESTS=(--allow-destination 'user*' --allow-destination openshift)
"$PORTFOLIO_INSTALL" --stacks "$STACKS" --repo-url "$REPO_URL" --revision "$REVISION" \
  "${PORTFOLIO_DESTS[@]}"

# ── 2. secret contracts (imperative by design; never in git) ──────────────────
info "[2/6] creating secret contracts"

# 2a. htpasswd secret for the console/CLI IdP. Secret key MUST be 'htpasswd' (OpenShift contract).
HTP_FILE="$(mktemp)"; trap 'rm -f "$HTP_FILE"' EXIT
htpasswd -B -b -c "$HTP_FILE" "${USER_PREFIX}1" "$WS_PASS" >/dev/null 2>&1
i=2
while [[ "$i" -le "$USERS" ]]; do
  htpasswd -B -b "$HTP_FILE" "${USER_PREFIX}${i}" "$WS_PASS" >/dev/null 2>&1
  i=$((i + 1))
done
oc create secret generic htpasswd-workshop-users \
  --from-file=htpasswd="$HTP_FILE" -n openshift-config \
  --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
ok "htpasswd-workshop-users (openshift-config) — ${USERS} users"

# 2a'. Merge the workshop IdP into the OAuth SINGLETON imperatively (append-if-absent).
# Deliberately NOT GitOps-managed: clusters arrive with pre-existing IdPs (this RHDP cluster
# has an 'rhbk' OpenID provider backing the admin login) and a forced server-side apply from
# Argo would replace the atomic identityProviders list — locking everyone out.
# Captured first, then matched via here-string — never `oc get ... | grep -qw`: with more than one
# existing IdP this list is not guaranteed to be one short line forever, and the same
# SIGPIPE-under-pipefail trap documented in resolve_slug() applies to any producer piped into an
# early-exiting grep -q.
_idp_names="$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null || true)"
if grep -qw "workshop-users" <<< "$_idp_names"; then
  # first-write-wins: only records false if WE did not already claim ownership on an earlier run.
  record_once oauth_idp_ownedbyus false
  ok "OAuth IdP 'workshop-users' already present"
else
  IDP_JSON='{"name":"workshop-users","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpasswd-workshop-users"}}}'
  if [[ -z "$(oc get oauth cluster -o jsonpath='{.spec.identityProviders}')" ]]; then
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders\",\"value\":[${IDP_JSON}]}]" >/dev/null
  else
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${IDP_JSON}}]" >/dev/null
  fi
  # WE appended it — uninstall removes exactly this entry (preserving any other IdPs).
  record_once oauth_idp_ownedbyus true
  ok "OAuth IdP 'workshop-users' appended (existing IdPs preserved)"
fi

# 2b. MaaS token for OpenShift Lightspeed (only when WE install it — a pre-installed
# Lightspeed brings its own provider secret, which we must never overwrite).
if [[ "$LIGHTSPEED" == "true" && "$LIGHTSPEED_PREINSTALLED" == "false" ]]; then
  [[ -n "$MAAS_KEY" && "$MAAS_KEY" != "null" && "$MAAS_KEY" != "CHANGEME" ]] \
    || die "lightspeed: true but maas.api_key is unset/CHANGEME in ${VARS}"
  # Remember whether the namespace pre-existed — uninstall deletes it ONLY if WE created it.
  if oc get namespace openshift-lightspeed >/dev/null 2>&1; then record_once lightspeed_ns_created false; else record_once lightspeed_ns_created true; fi
  oc create namespace openshift-lightspeed --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
  # Model travels WITH the credential: the per-user MaaS key is model-scoped, and the two clusters' keys
  # are scoped to OPPOSITE models (llama-scout-17b vs qwen3-14b — inverted-scope incident 2026-07-19), so
  # ANY hardcoded chart default breaks one cluster. Write model alongside apitoken; the entry-states'
  # converge Jobs prefer this key over their chart fallback. create-or-refresh (dry-run | apply).
  oc create secret generic credentials \
    --from-literal=apitoken="$MAAS_KEY" --from-literal=model="$MAAS_MODEL" -n openshift-lightspeed \
    --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
  record_once lightspeed_secret_created true
  ok "credentials (openshift-lightspeed/apitoken + model=${MAAS_MODEL}) — MaaS token + model"
fi

# 2b'. The WORKSHOP'S OWN MaaS credential, in OUR namespace, written whenever vars.yaml carries one —
# independent of whether Lightspeed is ours, adopted, or absent. This is the secret the AI entry states
# PREFER, and it exists precisely because the block above does not run on an adopted-Lightspeed cluster:
# there the modules had only Lightspeed's provider secret to read, and on an Azure-OpenAI wiring that
# is an Azure AD JWT for a different provider — it staged green and returned 401 for every attendee
# (cluster ksls5, 2026-07-29). endpoint travels WITH key+model so the entry states never pair a
# credential from one source with an endpoint from another. Torn down with ogsr-system by the uninstall.
# MAAS_KEY is blanked by discover_maas_model when the endpoint refused it on an adopted-Lightspeed
# cluster, so a key that failed its gate is NEVER staged — that is the whole point of this change.
if [[ "$maas_configured" == "true" && -n "$MAAS_KEY" ]]; then
  oc create secret generic ogsr-maas-credentials \
    --from-literal=apitoken="$MAAS_KEY" \
    --from-literal=model="$MAAS_MODEL" \
    --from-literal=endpoint="$MAAS_ENDPOINT" \
    -n "$STATE_NS" --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
  ok "ogsr-maas-credentials (${STATE_NS}) — the workshop's own MaaS key + model ${MAAS_MODEL} (the AI entry states prefer this over any adopted Lightspeed secret)"
elif [[ "$maas_configured" == "true" ]]; then
  warn "MaaS key configured but rejected by ${MAAS_ENDPOINT} — NOT staging it; the AI beats will report 'AI path unavailable' rather than fail at workshop time"
else
  info "no MaaS key in ${VARS} — the AI beats degrade to an explicit 'AI path unavailable' state (set maas.api_key + maas.endpoint to enable them)"
fi

# ── 3. wait for the in-cluster Gitea mirror (git-localize) ────────────────────
info "[3/6] waiting for the in-cluster Gitea mirror (up to 15m)…"
GITEA_HOST=""
MIRROR_API=""
for _ in $(seq 1 90); do
  GITEA_HOST="$(oc get route gitea -n "$GITEA_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$GITEA_HOST" ]]; then
    MIRROR_API="https://${GITEA_HOST}/api/v1/repos/${MIRROR_ORG}/${MIRROR_REPO}"
    curl -ksf "$MIRROR_API" >/dev/null 2>&1 && break
  fi
  printf '.'; sleep 10
done
echo
[[ -n "$GITEA_HOST" ]] || die "gitea route not found after 15m — check: oc get pods -n ${GITEA_NS}"
curl -ksf "$MIRROR_API" >/dev/null 2>&1 \
  || die "mirror repo ${MIRROR_ORG}/${MIRROR_REPO} absent after 15m — check the mirror job: oc get jobs -n ${GITEA_NS}"
ok "Gitea mirror ready: https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}"

# Freshness: the workshop chart must actually be IN the mirror at the target revision
# (mirrors pull on interval — force a sync so a just-pushed chart is served now).
info "refreshing the mirror and confirming the workshop chart is present…"
ADMIN_PASS="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.status.adminPassword}' 2>/dev/null || true)"
if [[ -n "$ADMIN_PASS" ]]; then
  curl -ksf -u "gitea-admin:${ADMIN_PASS}" -X POST \
    "https://${GITEA_HOST}/api/v1/repos/${MIRROR_ORG}/${MIRROR_REPO}/mirror-sync" >/dev/null 2>&1 || true
fi
CHART_RAW="https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}/raw/branch/${REVISION}/gitops/workshop-config/Chart.yaml"
for _ in $(seq 1 30); do
  curl -ksf "$CHART_RAW" >/dev/null 2>&1 && break
  printf '.'; sleep 5
done
echo
curl -ksf "$CHART_RAW" >/dev/null 2>&1 \
  || die "workshop chart not in the mirror at revision ${REVISION} — push it upstream, then re-run (or: ws git-refresh)"
ok "mirror serves gitops/workshop-config@${REVISION}"

# ── 3b. phase 2: repoint the platform stacks at the in-cluster mirror ──────────
# Phase 1 (above) had to come from the external repo — it is what builds the mirror. From here on
# reconciliation should be cluster-local: thirty Applications re-reading GitHub every three minutes
# is fragile (a live session then depends on GitHub availability) and `ws git-refresh` becomes the
# single content-update path instead of the mirror and the Argo source silently disagreeing.
#
# Two gates, both hard. Neither is a timer:
#   1. the mirror's HEAD on ${REVISION} equals origin's — a mirror one commit behind is a whole
#      cohort reading stale content, the same rule already learned for restarting cockpits;
#   2. Argo can verify the mirror's TLS. Never by disabling verification — by teaching Argo the
#      cluster's ingress CA through argocd-tls-certs-cm, its documented per-host trust store.
# Failing either gate is NOT an install failure: the stacks simply stay on the external repo,
# which is a working configuration. We say why, and move on.
ARGO_NS="openshift-gitops"
MIRROR_REPO_URL="https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}.git"

# HEAD of a repo at a ref, read from git's smart-HTTP ref advertisement — the handshake `git clone`
# starts with. Works against GitHub/GitLab/Gitea alike and needs no git binary on this box.
remote_head() {  # <repo-url> <ref> [curl-opt…] → 40-hex sha, or empty
  local url="${1%.git}" ref="$2"; shift 2
  curl -sf --max-time 30 "$@" "${url}.git/info/refs?service=git-upload-pack" 2>/dev/null \
    | tr -d '\000' \
    | sed -nE "s#^.*([0-9a-f]{40}) refs/(heads|tags)/${ref}\$#\\1#p" \
    | head -1 || true
}

# Teach Argo CD to VERIFY the mirror's certificate. argocd-tls-certs-cm is keyed by hostname and is
# the supported way to add a CA for one git host; `insecure: true` on a Repository would skip
# verification entirely and is not an option. Additive by construction — any host key the org
# already put there is preserved, and we record ours so teardown can remove exactly that key.
ensure_argo_trusts_mirror() {  # <host> → 0 when Argo can verify it, 1 when it cannot
  local host="$1" ca ca_file cm_yaml
  if curl -sSf --max-time 15 "https://${host}/api/v1/version" >/dev/null 2>&1; then
    ok "mirror TLS verifies against the system trust store — Argo needs no extra CA"
    return 0
  fi
  ca="$(oc get configmap default-ingress-cert -n openshift-config-managed \
          -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)"
  if [[ -z "$ca" ]]; then
    warn "mirror cert is not publicly trusted and openshift-config-managed/default-ingress-cert is unreadable"
    return 1
  fi
  ca_file="$(mktemp)"
  printf '%s\n' "$ca" > "$ca_file"
  # Prove the CA actually validates THIS host before installing it — pushing a CA that does not
  # verify would leave Argo failing with the same x509 error and a new object to explain it.
  if ! curl -sSf --max-time 15 --cacert "$ca_file" "https://${host}/api/v1/version" >/dev/null 2>&1; then
    rm -f "$ca_file"
    warn "the cluster ingress CA does not validate https://${host} — a custom serving cert is in play"
    return 1
  fi
  oc get configmap argocd-tls-certs-cm -n "$ARGO_NS" >/dev/null 2>&1 \
    || oc create configmap argocd-tls-certs-cm -n "$ARGO_NS" >/dev/null 2>&1 || true
  cm_yaml="$(oc get configmap argocd-tls-certs-cm -n "$ARGO_NS" -o yaml 2>/dev/null \
              | yq "del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields) | .data[\"${host}\"] = load_str(\"${ca_file}\")" \
              2>/dev/null || true)"
  rm -f "$ca_file"
  if [[ -z "$cm_yaml" ]]; then
    warn "could not compose the argocd-tls-certs-cm update — leaving Argo's trust store untouched"
    return 1
  fi
  printf '%s\n' "$cm_yaml" | oc apply -f - >/dev/null 2>&1 || {
    warn "could not update argocd-tls-certs-cm in ${ARGO_NS}"
    return 1
  }
  record_once argo_tls_cert_host "$host"
  ok "cluster ingress CA added to argocd-tls-certs-cm for ${host} (verification ON, not skipped)"
  # The repo-server reads the ConfigMap from a mounted volume and kubelet propagation is not
  # instant; the post-flip comparison poll below covers whatever is left of the sync period.
  sleep 30
  return 0
}

apply_stacks_from() {  # <repo-url> <mirror-source-repo> — (re-)apply the stack apps against a source
  "$PORTFOLIO_INSTALL" --stacks "$STACKS" --repo-url "$1" --revision "$REVISION" \
    --source-repo "$2" "${PORTFOLIO_DESTS[@]}" --stacks-only --skip-repo-check
}

stacks_compare_against() {  # <expected repoURL> → 0 once every stack app has COMPARED against it
  # Emptiness is not success: right after a re-apply an Application has no conditions yet, so
  # "no error condition" would pass before Argo has even tried the new source. The proof is
  # .status.sync.comparedTo.source.repoURL — Argo only writes it after fetching and rendering
  # that repo — plus the absence of an error condition once it has.
  local want="$1" waited=0 stack app pending types
  while (( waited < 180 )); do
    pending=""
    for stack in "${STACK_LIST[@]}"; do
      app="pp-$(echo "$stack" | xargs)"
      if [[ "$(oc get application "$app" -n "$ARGO_NS" \
                -o jsonpath='{.status.sync.comparedTo.source.repoURL}' 2>/dev/null || true)" != "$want" ]]; then
        pending="${pending} ${app}"; continue
      fi
      types="$(oc get application "$app" -n "$ARGO_NS" \
                -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || true)"
      case "$types" in *ComparisonError*|*InvalidSpecError*|*UnknownError*) pending="${pending} ${app}(error)" ;; esac
    done
    [[ -z "$pending" ]] && return 0
    sleep 10; waited=$((waited + 10))
  done
  err "after 3m these stack Applications had not cleanly compared against ${want}:${pending}"
  return 1
}

mirror_caught_up() {  # → 0 once the mirror serves origin's HEAD on ${REVISION}
  # Bounded POLL, not a sleep: the mirror-sync POSTed above is asynchronous, so a single read here
  # would almost always miss. The gate is still equality — the bound only limits how long we wait
  # for it before deciding to stay on the external repo.
  local waited=0 dots=0
  [[ -n "$ORIGIN_HEAD" ]] || return 1
  while (( waited < 180 )); do
    MIRROR_HEAD="$(remote_head "https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}" "$REVISION" -k)"
    if [[ "$MIRROR_HEAD" == "$ORIGIN_HEAD" ]]; then
      (( dots > 0 )) && echo
      return 0
    fi
    printf '.'; dots=$((dots + 1)); sleep 10; waited=$((waited + 10))
  done
  echo
  return 1
}

IFS=',' read -ra STACK_LIST <<< "$STACKS"
info "[3b/6] phase 2 — repointing platform stacks at the in-cluster mirror"
ORIGIN_HEAD="$(remote_head "$REPO_URL" "$REVISION")"
MIRROR_HEAD=""
FLIPPED="false"
if [[ -z "$ORIGIN_HEAD" ]]; then
  warn "cannot read origin HEAD for ${REVISION} at ${REPO_URL} — stacks stay on the external repo"
elif ! mirror_caught_up; then
  warn "mirror serves ${MIRROR_HEAD:-<no ${REVISION} branch>}, origin is at ${ORIGIN_HEAD} — stacks stay on the external repo"
  warn "   the mirror pulls on its own interval; re-run this installer (or 'ws git-refresh') to flip once it catches up"
elif ! ensure_argo_trusts_mirror "$GITEA_HOST"; then
  warn "Argo CD cannot verify the mirror's TLS — stacks stay on the external repo (verification is never disabled)"
else
  ok "mirror HEAD == origin HEAD (${ORIGIN_HEAD:0:8}) and Argo trusts it — flipping stack sources"
  apply_stacks_from "$MIRROR_REPO_URL" "$REPO_URL"
  # Force a fresh comparison rather than waiting out the 3-minute reconcile before judging the flip.
  for _s in "${STACK_LIST[@]}"; do
    oc annotate application "pp-$(echo "$_s" | xargs)" -n "$ARGO_NS" \
      argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done
  if stacks_compare_against "$MIRROR_REPO_URL"; then
    FLIPPED="true"
    ok "platform stacks now reconcile from the in-cluster mirror (${MIRROR_REPO_URL})"
  else
    err "the mirror source did not comparison-check clean — reverting the stacks to ${REPO_URL}"
    apply_stacks_from "$REPO_URL" "$REPO_URL"
    stacks_compare_against "$REPO_URL" >/dev/null 2>&1 || true
    err "   reverted. Inspect: oc get application -n ${ARGO_NS} -o wide, then oc describe application pp-core-devtools -n ${ARGO_NS}"
  fi
fi
oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge \
  -p "{\"data\":{\"stack_source\":\"$([[ "$FLIPPED" == "true" ]] && echo mirror || echo external)\"}}" \
  >/dev/null 2>&1 || true

# ── 4. shared workshop password for Gitea seeding (ogsr-gitea ns now exists) ───────
info "[4/6] recording the shared workshop password (secret workshop-user-creds)"
oc create secret generic workshop-user-creds \
  --from-literal=password="$WS_PASS" -n "$GITEA_NS" \
  --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
ok "workshop-user-creds (ogsr-gitea/password)"

# ── 4b. RHDH Gitea contract (portal only) — CREATE-OR-REFRESH, never create-only ─────
# The rhdh-gitea secret is the portal stack's documented contract (components/rhdh/README.md).
# It must be REFRESHED on every install, not preserved: the Gitea operator regenerates its admin
# password on reinstall, and a preserved secret fossilizes → RHDH reads 401 on every catalog
# Location and the whole cohort sees an empty catalog (M12 G3 FAIL, 2026-07-19 — found live).
if [[ "$PORTAL" == "true" ]]; then
  info "[4b/6] RHDH Gitea contract (secret rhdh-gitea) — create-or-refresh from the gitea CR"
  RHDH_GITEA_USER=""; RHDH_GITEA_PASS=""
  for _i in $(seq 1 30); do
    RHDH_GITEA_USER="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.spec.giteaAdminUser}' 2>/dev/null || true)"
    RHDH_GITEA_PASS="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.status.adminPassword}' 2>/dev/null || true)"
    [[ -n "$RHDH_GITEA_USER" && -n "$RHDH_GITEA_PASS" ]] && break
    sleep 10
  done
  if [[ -n "$RHDH_GITEA_USER" && -n "$RHDH_GITEA_PASS" ]]; then
    RHDH_GITEA_ROUTE="$(oc get route -n "$GITEA_NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
    # Owner-stamp it on creation: a namespace without workshop.redhat.com/owner is invisible to
    # bootstrap/ogsr-uninstall.sh and survives a "complete" teardown unseen (defect 5, 2026-07-25).
    oc get ns rhdh >/dev/null 2>&1 \
      || oc create namespace rhdh --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null 2>&1 \
      || true
    oc create secret generic rhdh-gitea -n rhdh \
      --from-literal=GITEA_USERNAME="$RHDH_GITEA_USER" \
      --from-literal=GITEA_PASSWORD="$RHDH_GITEA_PASS" \
      --from-literal=GITEA_BASEURL="https://$RHDH_GITEA_ROUTE" \
      --from-literal=GITEA_HOST="$RHDH_GITEA_ROUTE" \
      --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
    ok "rhdh-gitea (rhdh) refreshed from the live gitea CR"
  else
    warn "gitea CR admin credential not readable after 5m — rhdh-gitea NOT refreshed (RHDH catalog may 401)"
  fi
fi

# ── 5. materialize the workshop layer from the LOCAL mirror ───────────────────
info "[5/6] materializing the workshop layer (Argo Application workshop-config)"
cat <<EOF | oc apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: workshop-config
  namespace: openshift-gitops
  labels:
    workshop.redhat.com/layer: workshop-config
    workshop.redhat.com/owner: ogsr
spec:
  # Same project as the platform stacks: nothing of ours sits in the built-in \`default\` alongside
  # the organisation's Applications, and teardown has one handle on the whole footprint. The
  # user*/openshift destinations this layer needs were unioned into the project above.
  project: ogsr-platform
  source:
    repoURL: https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}.git
    targetRevision: ${REVISION}
    path: gitops/workshop-config
    helm:
      parameters:
        - name: userCount
          value: "${USERS}"
        - name: clusterDomain
          value: "${DOMAIN}"
        # Seed per-user realm-{user} imports only when the auth stack is installed (M13).
        - name: sso.enabled
          value: "${AUTH}"
        # Console plugins (backlog #24) — ON by default; vars.yaml console_plugins: false opts out.
        - name: consolePlugins.enabled
          value: "${CONSOLE_PLUGINS}"
        # Modules hidden from the attendee showroom nav/library (comma-joined slugs; "" = show all).
        - name: modulesDisabledCSV
          value: "${DISABLED_CSV}"
        # The two in-cluster BuildConfigs (Parasol images, showroom antora-ext) clone the workshop
        # source directly, so they follow repo_url too — otherwise a fork install would quietly
        # build its cockpit and app images from the upstream project. Scalars only: Argo's
        # helm.parameters cannot carry list values reliably.
        - name: parasolImages.build.repoUrl
          value: "${REPO_URL%.git}.git"
        - name: parasolImages.build.revision
          value: "${REVISION}"
        - name: showroom.build.repoUrl
          value: "${REPO_URL%.git}.git"
        - name: showroom.build.revision
          value: "${REVISION}"
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff: {duration: 15s, factor: 2, maxDuration: 3m}
EOF
ok "workshop-config Application applied (source: local mirror)"

# ── 6. wait for the workshop layer to be Healthy ──────────────────────────────
info "[6/6] waiting for workshop-config to become Healthy (up to 10m)…"
HEALTH=""; SYNC=""
for _ in $(seq 1 60); do
  HEALTH="$(oc get application workshop-config -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  SYNC="$(oc get application workshop-config -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [[ "$HEALTH" == "Healthy" && "$SYNC" == "Synced" ]] && break
  printf '.'; sleep 10
done
echo
if [[ "$HEALTH" == "Healthy" && "$SYNC" == "Synced" ]]; then
  ok "workshop-config is Synced/Healthy"
else
  err "workshop-config not ready yet (health=${HEALTH:-?} sync=${SYNC:-?}) — selfHeal continues; inspect: oc describe application workshop-config -n openshift-gitops"
  # …and REMEMBER it. This used to print the ❌ above and then fall straight through to
  # "✅ workshop bootstrap complete" with exit 0, so a run whose entire workshop layer never
  # materialized reported success — 3 namespaces instead of ~70 and zero cockpit pods, while the
  # closing banner still printed the console URL, the Gitea URL and "users user1 … user8" as though
  # they were ready. Measured on a clean cluster (tb7fj, 2026-07-31), where a duplicate Namespace in
  # the chart made Argo refuse to sync at all. Anything scripting this installer — CI, the RHDP
  # catalog item, an SA in a hurry — reads the exit code, and the exit code said fine.
  WORKSHOP_LAYER_OK=false
fi

# ── credentials summary + next steps ──────────────────────────────────────────
CONSOLE_URL="$(oc whoami --show-console 2>/dev/null || true)"
{
  echo "# Workshop credentials — generated $(date -u +%FT%TZ). DO NOT COMMIT (gitignored)."
  echo "console : ${CONSOLE_URL:-<oc whoami --show-console>}"
  echo "gitea   : https://${GITEA_HOST}"
  echo "users   : ${USER_PREFIX}1 .. ${USER_PREFIX}${USERS}"
  echo "# shared password — console/CLI login AND Gitea. Bare value on its own line:"
  echo "# an inline comment here poisons every naive parser (two QA agents read"
  echo "# 'password + comment' as the literal secret and reported 401s — 2026-07-09)."
  echo "password: ${WS_PASS}"
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

# ── adopted-resource report ───────────────────────────────────────────────────
# Surfaced in the summary on purpose: uninstall CASCADE-deletes our Applications, and a wrong adoption
# snapshot combined with cascade delete would remove an org's operator. These annotations are the only
# thing standing between the two, so the operator running the install gets to see the actual list.
echo
# Components this cluster already provided, so the portfolio never installed ours. Said plainly here
# because an operator silently absent from the portfolio is the kind of surprise that surfaces three
# modules later — and because teardown will leave every one of them exactly as it found it.
if [[ -n "$(echo "${SKIPPED_COMPONENTS}" | xargs || true)" ]]; then
  ok "components adopted from this cluster (ours never installed):"
  read -ra _skipped_list <<< "$SKIPPED_COMPONENTS"
  for _c in "${_skipped_list[@]}"; do
    echo "   • ${_c}: already installed by this cluster's owner — using theirs, our component skipped"
  done
  echo "   uninstall will not touch them (recorded adopted in ${STATE_NS}/${STATE_CM})"
fi
if [[ "$PROTECTED_COUNT" -gt 0 ]]; then
  ok "adopted resources protected from teardown: ${PROTECTED_COUNT}"
  printf '%s\n' "$PROTECTED_LIST"
  echo "   re-check any time: ./bootstrap/ogsr-uninstall.sh --dry-run  (verifies every adopted resource"
  echo "   against the live cluster and refuses to cascade if any of them is unprotected)"
else
  info "adopted resources protected from teardown: none (nothing pre-existing was adopted)"
fi

# ── hard gate: OperatorGroup uniqueness ───────────────────────────────────────
# Last thing before declaring success. A second OperatorGroup in an adopted operator's namespace stops
# OLM reconciling the org's CSV without stopping its pods — invisible at runtime, and only discovered
# when they later try to upgrade. Credentials are written above first, so a failure here still leaves
# the admin everything they need.
echo
if ! assert_single_operatorgroup; then
  err "install did NOT complete cleanly — fix the OperatorGroup collision above before running the workshop"
  exit 1
fi

# ── hard gate: batch-pool taint did not starve unrelated scheduling ───────────
# Same spirit as the OperatorGroup gate above: the batch-pool taint is workshop substrate we chose to
# add, so if it is quietly starving something (RHACS central-db was Pending 3h+ behind it on a
# 2-worker cluster, 2026-07-30, with every Argo app reporting Healthy the whole time) that is OUR defect
# to catch before handing the cluster to attendees, not something to discover three modules later.
echo
if ! assert_no_batch_taint_pending; then
  err "install did NOT complete cleanly — the batch-pool taint above is starving a pod's scheduling; fix capacity or re-run once the ${MIN_BATCH_POOL_FOR_TAINT}-worker floor would skip the taint"
  exit 1
fi

echo
if [[ "${WORKSHOP_LAYER_OK:-true}" != "true" ]]; then
  err "workshop bootstrap INCOMPLETE — the platform installed but the workshop layer did not"
  echo "   what is missing: the workshop-config Application never reached Synced/Healthy, so the"
  echo "     per-user namespaces, quotas, RBAC, Gitea seeding and cockpits were NOT created."
  echo "   attendees CANNOT use this cluster yet. Do not hand out links."
  echo "   diagnose : oc get application workshop-config -n ${ARGO_NS:-openshift-gitops} -o yaml"
  echo "              a RepeatedResourceWarning condition means the chart renders one object twice —"
  echo "              Argo refuses to sync at all in that case and records no operation."
  echo "   re-run   : this installer is idempotent; fix the cause and run it again."
  exit 1
fi
ok "workshop bootstrap complete"
echo "   console : ${CONSOLE_URL:-<run: oc whoami --show-console>}"
echo "   gitea   : https://${GITEA_HOST}"
echo "   users   : ${USER_PREFIX}1 … ${USER_PREFIX}${USERS} (shared password)"
echo "   creds   : ${CREDS_FILE} (gitignored)"
echo "   next    : ws doctor   ·   ws start m01 --user ${USER_PREFIX}1"
